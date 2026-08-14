import AppKit

/// A colour ramp with stops, sampled to give each bar (or each point along a meter) its colour.
struct Palette {
    let name: String
    /// Sorted by position, each 0...1.
    let stops: [(position: Double, color: NSColor)]

    /// Colour at `t` in 0...1, interpolated between the surrounding stops.
    func color(at t: Double) -> NSColor {
        guard let first = stops.first else { return .white }
        guard stops.count > 1 else { return first.color }
        let t = min(max(t, 0), 1)
        if t <= stops[0].position { return stops[0].color }
        if t >= stops[stops.count - 1].position { return stops[stops.count - 1].color }
        for index in 1..<stops.count where t <= stops[index].position {
            let lower = stops[index - 1]
            let upper = stops[index]
            let span = upper.position - lower.position
            let local = span > 0 ? (t - lower.position) / span : 0
            return lower.color.blended(withFraction: CGFloat(local), of: upper.color) ?? lower.color
        }
        return stops[stops.count - 1].color
    }

    /// A Core Graphics gradient of the whole ramp, for filling meters in one pass.
    /// Slicing a fill into small rectangles instead leaves visible seams where the edges antialias.
    func cgGradient() -> CGGradient? {
        let count = 32
        let colors = (0..<count).map { color(at: Double($0) / Double(count - 1)).cgColor } as CFArray
        let locations = (0..<count).map { CGFloat($0) / CGFloat(count - 1) }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations)
    }

    /// `count` evenly spaced colours across the ramp.
    func colors(count: Int) -> [NSColor] {
        let count = max(1, count)
        return (0..<count).map { color(at: count == 1 ? 0 : Double($0) / Double(count - 1)) }
    }

    /// `count` evenly spaced colours, already bridged to `CGColor` and cached.
    ///
    /// The renderer needs this every frame; building 88 `NSColor`s and bridging each one 20 times a
    /// second is pure waste, since the answer only changes when the palette or the band count does.
    func cgColors(count: Int) -> [CGColor] {
        let count = max(1, count)
        let key = "\(name)|\(count)"
        if let cached = Palette.cgColorCache[key] { return cached }
        let colors = self.colors(count: count).map(\.cgColor)
        if Palette.cgColorCache.count > 64 { Palette.cgColorCache.removeAll() }
        Palette.cgColorCache[key] = colors
        return colors
    }

    /// Keyed by palette name and count. Only ever touched on the main thread, from drawing.
    private static var cgColorCache: [String: [CGColor]] = [:]

    /// Gradients are likewise rebuilt every frame otherwise.
    func cachedGradient() -> CGGradient? {
        if let cached = Palette.gradientCache[name] { return cached }
        guard let gradient = cgGradient() else { return nil }
        if Palette.gradientCache.count > 32 { Palette.gradientCache.removeAll() }
        Palette.gradientCache[name] = gradient
        return gradient
    }

    private static var gradientCache: [String: CGGradient] = [:]
}

/// Loads colour ramps, including the ones exported from AVTouchBar's colour manager.
///
/// AVTouchBar writes each set as JSON: `{name, colors: [{color: [base64], stop: Double}]}`, where the
/// base64 is an `NSKeyedArchiver` blob. Unusually, that archive keeps the colour's components in its
/// `$top` dictionary rather than as an object, so the standard unarchiver returns nothing — the
/// components are read out of `$top["NSRGB"]` directly, which is the sRGB triplet.
enum PaletteLibrary {

    /// Where SoundBar keeps its own copy, so palettes survive a tidy-up of Downloads.
    static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SoundBar/Colors", isDirectory: true)
    }

    /// Also read from AVTouchBar's export folder if it is still there.
    private static var extraDirectories: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/AVTouchBar Custom Colors", isDirectory: true)]
    }

    private static var cache: [Palette]?

    /// Every palette, built-ins first, then the user's own by name.
    static func all() -> [Palette] {
        if let cache { return cache }
        var palettes = builtIns
        var seen = Set(palettes.map(\.name))
        for directory in [userDirectory] + extraDirectories {
            for palette in load(from: directory) where !seen.contains(palette.name) {
                palettes.append(palette)
                seen.insert(palette.name)
            }
        }
        cache = palettes
        return palettes
    }

    static func invalidate() { cache = nil }

    static var names: [String] { all().map(\.name) }

    static func palette(named name: String) -> Palette {
        all().first { $0.name.caseInsensitiveCompare(name) == .orderedSame } ?? builtIns[0]
    }

    /// Copy AVTouchBar's exports into SoundBar's own folder once, so they are not lost if Downloads is
    /// cleared. Never overwrites anything already there.
    static func importExternalPalettesIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        for directory in extraDirectories {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where !file.lastPathComponent.hasPrefix(".") {
                let destination = userDirectory.appendingPathComponent(file.lastPathComponent)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                if (try? fm.copyItem(at: file, to: destination)) != nil {
                    Log.info("palette", "imported colour set '\(file.lastPathComponent)'")
                }
            }
        }
        invalidate()
    }

    // MARK: - Loading

    private struct ColorSetFile: Decodable {
        struct Entry: Decodable {
            let color: [String]
            let stop: Double
        }
        let name: String
        let colors: [Entry]
    }

    private static func load(from directory: URL) -> [Palette] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [Palette] = []
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(ColorSetFile.self, from: data) else { continue }
            var stops: [(Double, NSColor)] = []
            for entry in decoded.colors {
                guard let base64 = entry.color.first, let color = decodeArchivedColor(base64) else { continue }
                stops.append((min(max(entry.stop, 0), 1), color))
            }
            guard stops.count >= 2 else { continue }
            // Applied here rather than editing the user's exported files: the flip and the rename
            // both act on the AVTouchBar name, before any override is applied to it.
            if flippedNames.contains(decoded.name) {
                stops = flipped(stops)
            } else {
                stops.sort { $0.0 < $1.0 }
            }
            result.append(Palette(name: nameOverrides[decoded.name] ?? decoded.name,
                                  stops: stops.map { (position: $0.0, color: $0.1) }))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// AVTouchBar colour sets whose gradient direction reads better reversed. Matched against the
    /// name as AVTouchBar wrote it, before any rename.
    private static let flippedNames: Set<String> = ["Rainbow", "Cotton Candy"]

    /// Renames applied to specific AVTouchBar colour sets.
    private static let nameOverrides: [String: String] = ["Cyberpunk 2077": "Cyberpunk"]

    /// Maps a possibly-old palette name through `nameOverrides`, so a `defaults` value saved before a
    /// rename still resolves to the palette that used to have that name, instead of silently falling
    /// back to the first built-in.
    static func canonicalName(_ name: String) -> String { nameOverrides[name] ?? name }

    /// Reverses a gradient: the colour that was at position `p` moves to `1 - p`, so the ramp reads in
    /// the opposite direction with its internal spacing mirrored rather than just reversing the colour
    /// array (which would be wrong for stops that are not evenly spaced).
    private static func flipped(_ stops: [(Double, NSColor)]) -> [(Double, NSColor)] {
        stops.map { (1 - $0.0, $0.1) }.sorted { $0.0 < $1.0 }
    }

    /// Pulls the sRGB components out of AVTouchBar's archived `NSColor`.
    private static func decodeArchivedColor(_ base64: String) -> NSColor? {
        guard let raw = Data(base64Encoded: base64),
              let plist = try? PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any],
              let top = plist["$top"] as? [String: Any] else { return nil }
        // NSRGB is the sRGB triplet; NSComponents is the same colour in its original space.
        for key in ["NSRGB", "NSComponents"] {
            guard let data = top[key] as? Data,
                  let text = String(data: data, encoding: .ascii) else { continue }
            let parts = text.split(whereSeparator: { $0 == " " || $0 == "\0" || $0 == "\n" })
                            .compactMap { Double($0) }
            if parts.count >= 3 {
                return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2],
                               alpha: parts.count > 3 ? parts[3] : 1)
            }
        }
        return nil
    }

    // MARK: - Built-ins

    private static func ramp(_ name: String, _ colors: [NSColor]) -> Palette {
        let stops = colors.enumerated().map { index, color in
            (position: colors.count == 1 ? 0 : Double(index) / Double(colors.count - 1), color: color)
        }
        return Palette(name: name, stops: stops)
    }

    static let builtIns: [Palette] = [
        ramp("Green", [NSColor(srgbRed: 0.30, green: 1.00, blue: 0.45, alpha: 1),
                       NSColor(srgbRed: 0.05, green: 0.70, blue: 0.35, alpha: 1)]),
        // Reversed (violet-leaning -> red) at the user's request. Reversing the colour array is exact
        // here because these stops are evenly spaced by index, unlike the loaded AVTouchBar sets.
        ramp("Spectrum", Array((0..<7).map { NSColor(hue: CGFloat($0) / 9.0, saturation: 0.9, brightness: 1, alpha: 1) }.reversed())),
        ramp("Ice", [NSColor(srgbRed: 0.35, green: 0.85, blue: 1.00, alpha: 1),
                     NSColor(srgbRed: 0.20, green: 0.35, blue: 1.00, alpha: 1)]),
        ramp("Ember", [NSColor(srgbRed: 1.00, green: 0.85, blue: 0.25, alpha: 1),
                       NSColor(srgbRed: 1.00, green: 0.25, blue: 0.10, alpha: 1)]),
        // A classic meter ramp: green until it is loud, then amber, then red at the top.
        Palette(name: "Meter", stops: [
            (0.00, NSColor(srgbRed: 0.20, green: 0.90, blue: 0.35, alpha: 1)),
            (0.65, NSColor(srgbRed: 0.35, green: 1.00, blue: 0.30, alpha: 1)),
            (0.82, NSColor(srgbRed: 1.00, green: 0.80, blue: 0.15, alpha: 1)),
            (1.00, NSColor(srgbRed: 1.00, green: 0.20, blue: 0.15, alpha: 1)),
        ]),
        ramp("Mono", [NSColor.white, NSColor(white: 0.65, alpha: 1)]),
        // The default palette. Stops match the AVTouchBar "Rainbow" set post-flip (violet-leaning
        // magenta at the quiet end, red at the loud end), so anyone who also imports that set sees
        // no change — the built-in shadows it by name.
        Palette(name: "Rainbow", stops: [
            (0.00, NSColor(srgbRed: 0.985, green: 0.000, blue: 0.921, alpha: 1)),
            (0.11, NSColor(srgbRed: 0.985, green: 0.000, blue: 0.817, alpha: 1)),
            (0.23, NSColor(srgbRed: 0.021, green: 0.278, blue: 0.998, alpha: 1)),
            (0.35, NSColor(srgbRed: 0.129, green: 1.000, blue: 0.980, alpha: 1)),
            (0.46, NSColor(srgbRed: 0.134, green: 1.000, blue: 0.482, alpha: 1)),
            (0.60, NSColor(srgbRed: 0.346, green: 1.000, blue: 0.028, alpha: 1)),
            (0.73, NSColor(srgbRed: 1.000, green: 0.974, blue: 0.041, alpha: 1)),
            (0.87, NSColor(srgbRed: 0.990, green: 0.453, blue: 0.032, alpha: 1)),
            (1.00, NSColor(srgbRed: 0.986, green: 0.000, blue: 0.027, alpha: 1)),
        ]),
        // Matches the AVTouchBar "Sakura" set: white fading through blossom pink to deep magenta.
        Palette(name: "Sakura", stops: [
            (0.00, NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1)),
            (0.71, NSColor(srgbRed: 0.991, green: 0.542, blue: 0.807, alpha: 1)),
            (1.00, NSColor(srgbRed: 0.986, green: 0.000, blue: 0.551, alpha: 1)),
        ]),
        // Matches the AVTouchBar "Fable Computer" set: cyan, green, violet, magenta, amber, red.
        Palette(name: "Fable Computer", stops: [
            (0.00, NSColor(srgbRed: 0.105, green: 0.833, blue: 0.999, alpha: 1)),
            (0.18, NSColor(srgbRed: 0.135, green: 1.000, blue: 0.318, alpha: 1)),
            (0.37, NSColor(srgbRed: 0.542, green: 0.394, blue: 0.999, alpha: 1)),
            (0.53, NSColor(srgbRed: 0.962, green: 0.178, blue: 0.999, alpha: 1)),
            (0.76, NSColor(srgbRed: 0.998, green: 0.896, blue: 0.494, alpha: 1)),
            (1.00, NSColor(srgbRed: 0.986, green: 0.000, blue: 0.365, alpha: 1)),
        ]),
    ]
}
