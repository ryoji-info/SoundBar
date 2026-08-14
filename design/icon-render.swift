import AppKit
import CoreGraphics
import CoreImage

// MARK: - Canvas helpers

func makeRep(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

func withContext(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = makeRep(w, h)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    body(ctx)
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try? data.write(to: URL(fileURLWithPath: path))
}

func drawText(_ ctx: CGContext, _ string: NSAttributedString, at point: CGPoint) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    string.draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Brand gradient
//
// A bespoke "hero" ramp for the icon family — cooler and more saturated than any single in-app
// palette, but built the same way the app's own Palette.color(at:) works, so the icon and the thing
// it represents share a visual grammar.

let heroStops: [(CGFloat, NSColor)] = [
    (0.00, NSColor(srgbRed: 0.16, green: 0.34, blue: 1.00, alpha: 1)),   // blue
    (0.35, NSColor(srgbRed: 0.07, green: 0.85, blue: 0.80, alpha: 1)),   // teal
    (0.70, NSColor(srgbRed: 0.40, green: 1.00, blue: 0.40, alpha: 1)),   // green
    (1.00, NSColor(srgbRed: 0.97, green: 1.00, blue: 0.34, alpha: 1)),   // yellow-green
]
func heroColor(_ t: CGFloat) -> NSColor {
    let t = min(max(t, 0), 1)
    if t <= heroStops[0].0 { return heroStops[0].1 }
    if t >= heroStops.last!.0 { return heroStops.last!.1 }
    for i in 1..<heroStops.count where t <= heroStops[i].0 {
        let lo = heroStops[i - 1], hi = heroStops[i]
        let span = hi.0 - lo.0
        let local = span > 0 ? (t - lo.0) / span : 0
        return lo.1.blended(withFraction: local, of: hi.1) ?? lo.1
    }
    return heroStops.last!.1
}
/// Seamless around a full loop (0 and 1 give the same colour), for radial layouts.
func heroColorLooped(_ t: CGFloat) -> NSColor {
    let t = t.truncatingRemainder(dividingBy: 1)
    let tt = t < 0.5 ? t * 2 : (1 - t) * 2
    return heroColor(tt)
}

// MARK: - Shape helpers

/// A superellipse ("squircle"), which is what macOS app icons are actually shaped like — not a
/// circular-arc rounded rect. Exponent 5 is close to Apple's own curvature.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let path = CGMutablePath()
    let steps = 240
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedBarPath(_ rect: CGRect) -> CGPath {
    let r = min(rect.width, rect.height) / 2
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// MARK: - Glow (Core Image gaussian blur, composited under the crisp shape)

let ciContext = CIContext(options: nil)

/// Renders `draw` into its own transparent layer, blurs it, and returns the blurred image plus the
/// rect (in canvas coordinates) to draw it back into — the blur expands the extent, so this must be
/// tracked rather than assumed to match the original canvas.
func glowLayer(size: Int, radius: CGFloat, draw: (CGContext) -> Void) -> (CGImage, CGRect)? {
    let rep = withContext(size, size) { ctx in draw(ctx) }
    guard let cg = rep.cgImage else { return nil }
    let ci = CIImage(cgImage: cg)
    guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
    filter.setValue(ci, forKey: kCIInputImageKey)
    filter.setValue(radius, forKey: kCIInputRadiusKey)
    guard let output = filter.outputImage else { return nil }
    let extent = ci.extent.insetBy(dx: -radius * 3, dy: -radius * 3)
    guard let cgOut = ciContext.createCGImage(output, from: extent) else { return nil }
    return (cgOut, extent)
}

// MARK: - Base plate (shared chrome across every app-icon concept)

func drawBasePlate(_ ctx: CGContext, size: CGFloat, mask: CGPath) {
    ctx.saveGState()
    ctx.addPath(mask)
    ctx.clip()

    let bg = [NSColor(srgbRed: 0.086, green: 0.094, blue: 0.112, alpha: 1).cgColor,
              NSColor(srgbRed: 0.032, green: 0.036, blue: 0.045, alpha: 1).cgColor] as CFArray
    let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // A soft light source from the top — the one nod to "glass" without full glassmorphism.
    let hl = [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray
    let hlGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hl, locations: [0, 1])!
    ctx.drawLinearGradient(hlGradient, start: CGPoint(x: size / 2, y: size),
                           end: CGPoint(x: size / 2, y: size * 0.42), options: [])

    // A whisper of a rim, so the squircle edge reads as a physical plate rather than a flat cutout.
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.06).cgColor)
    ctx.setLineWidth(size * 0.006)
    ctx.addPath(mask)
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - Bars (shared by concepts 1 and 2)

func drawBars(_ ctx: CGContext, in rect: CGRect, count: Int, mirrored: Bool, gap: CGFloat = 0.30,
             colorFn: (CGFloat) -> NSColor = heroColor) {
    let slot = rect.width / CGFloat(count)
    let barWidth = slot * (1 - gap)
    let inset = (slot - barWidth) / 2
    for i in 0..<count {
        let t = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
        let phase = t * .pi
        let arch = sin(phase)
        let ripple = sin(phase * 3 + 0.6) * 0.16
        let h = min(1, max(0.16, arch * 0.84 + ripple + 0.16))
        let barHeight = rect.height * h
        let x = rect.minX + CGFloat(i) * slot + inset
        let barRect = mirrored
            ? CGRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
            : CGRect(x: x, y: rect.minY, width: barWidth, height: barHeight)
        ctx.setFillColor(colorFn(t).cgColor)
        ctx.addPath(roundedBarPath(barRect))
        ctx.fillPath()
    }
}

/// Same silhouette as `drawBars` (an arch with a ripple), but as dot diameters rather than bar
/// heights — used by the "Dot Row" chip variant.
func drawDotPulse(_ ctx: CGContext, in rect: CGRect, count: Int, colorFn: (CGFloat) -> NSColor = heroColor) {
    let slot = rect.width / CGFloat(count)
    let maxDot = min(slot, rect.height) * 0.92
    for i in 0..<count {
        let t = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
        let phase = t * .pi
        let arch = sin(phase)
        let ripple = sin(phase * 3 + 0.6) * 0.16
        let d = min(1, max(0.22, arch * 0.78 + ripple + 0.22))
        let diameter = maxDot * d
        let cx = rect.minX + slot * (CGFloat(i) + 0.5)
        ctx.setFillColor(colorFn(t).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - diameter / 2, y: rect.midY - diameter / 2,
                                   width: diameter, height: diameter))
    }
}

// MARK: - Concept 1: Spectrum Burst — mirrored EQ bars, the app's own signature move

func renderSpectrumBurst(size: CGFloat) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let full = CGRect(x: 0, y: 0, width: size, height: size)
        let inset = size * 0.02
        let mask = squirclePath(in: full.insetBy(dx: inset, dy: inset))
        drawBasePlate(ctx, size: size, mask: mask)

        let barsRect = full.insetBy(dx: size * 0.17, dy: size * 0.30)
        if let (glow, rect) = glowLayer(size: s, radius: size * 0.028, draw: { gctx in
            drawBars(gctx, in: barsRect, count: 15, mirrored: true, gap: 0.30)
        }) {
            ctx.saveGState()
            ctx.addPath(mask); ctx.clip()
            ctx.setAlpha(0.9)
            ctx.draw(glow, in: rect)
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(mask); ctx.clip()
        drawBars(ctx, in: barsRect, count: 15, mirrored: true, gap: 0.30)
        ctx.restoreGState()
    }
}

// MARK: - Concept 2: Touch Bar Chip — literal, the app's whole reason to exist
//
// Generalised into one function so several variations (bar orientation, colour, proportions,
// content, chrome) can be produced from a single, consistently-built renderer instead of six
// hand-copied ones drifting apart.

func renderChipVariant(size: CGFloat,
                       pillWidthFrac: CGFloat = 0.76, pillHeightFrac: CGFloat = 0.20,
                       count: Int = 11, mirrored: Bool = true,
                       mono: Bool = false, useDots: Bool = false,
                       hardOutline: Bool = true, glowFrac: CGFloat = 0.02) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let full = CGRect(x: 0, y: 0, width: size, height: size)
        let inset = size * 0.02
        let mask = squirclePath(in: full.insetBy(dx: inset, dy: inset))
        drawBasePlate(ctx, size: size, mask: mask)

        let pillW = size * pillWidthFrac, pillH = size * pillHeightFrac
        let pill = CGRect(x: (size - pillW) / 2, y: (size - pillH) / 2, width: pillW, height: pillH)
        let pillPath = roundedBarPath(pill)
        let contentRect = pill.insetBy(dx: pillH * 0.26, dy: pillH * 0.20)
        let colorFn: (CGFloat) -> NSColor = mono ? { _ in NSColor(white: 0.96, alpha: 1) } : heroColor

        func drawContent(_ c: CGContext) {
            c.saveGState()
            c.addPath(pillPath); c.clip()
            if useDots {
                drawDotPulse(c, in: contentRect, count: count, colorFn: colorFn)
            } else {
                drawBars(c, in: contentRect, count: count, mirrored: mirrored, gap: 0.26, colorFn: colorFn)
            }
            c.restoreGState()
        }

        // Glow bleeding from inside the pill outward, as if the content is lit glass.
        if let (glow, rect) = glowLayer(size: s, radius: size * glowFrac, draw: drawContent) {
            ctx.saveGState()
            ctx.addPath(mask); ctx.clip()
            ctx.setAlpha(0.95)
            ctx.draw(glow, in: rect)
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(mask); ctx.clip()
        if hardOutline {
            // Near-black glass with a hairline rim, like the real Touch Bar.
            ctx.setFillColor(NSColor(srgbRed: 0.01, green: 0.012, blue: 0.016, alpha: 1).cgColor)
            ctx.addPath(pillPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.setLineWidth(size * 0.004)
            ctx.addPath(pillPath); ctx.strokePath()
        } else {
            // No rim at all: just enough of a darker panel to imply a surface, so the content
            // still reads as sitting on something rather than floating loose.
            ctx.setFillColor(NSColor(white: 0, alpha: 0.30).cgColor)
            ctx.addPath(pillPath); ctx.fillPath()
        }
        drawContent(ctx)
        ctx.restoreGState()
    }
}

func renderTouchBarChip(size: CGFloat) -> NSBitmapImageRep {
    renderChipVariant(size: size)
}

// MARK: - Concept 3: Retro Dot Wave — LED wall, callback to the Retro Dot LED pattern

func renderDotWave(size: CGFloat) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let full = CGRect(x: 0, y: 0, width: size, height: size)
        let inset = size * 0.02
        let mask = squirclePath(in: full.insetBy(dx: inset, dy: inset))
        drawBasePlate(ctx, size: size, mask: mask)

        let area = full.insetBy(dx: size * 0.14, dy: size * 0.24)
        let cols = 13, rows = 9
        let colPitch = area.width / CGFloat(cols)
        let rowPitch = area.height / CGFloat(rows)
        let dotDiameter = min(colPitch, rowPitch) * 0.66

        func drawDots(_ c: CGContext) {
            for col in 0..<cols {
                let t = CGFloat(col) / CGFloat(cols - 1)
                let waveCenter: CGFloat = 0.5 + 0.32 * sin(t * .pi * 1.7 - 0.25)
                for row in 0..<rows {
                    let rowT = CGFloat(row) / CGFloat(rows - 1)
                    let dist = abs(rowT - waveCenter)
                    let intensity = max(0, 1 - dist * 3.0)
                    let x = area.minX + colPitch * (CGFloat(col) + 0.5)
                    let y = area.minY + rowPitch * (CGFloat(row) + 0.5)
                    let color = intensity > 0.04
                        ? heroColor(t).withAlphaComponent(0.30 + 0.70 * intensity)
                        : NSColor(white: 1, alpha: 0.05)
                    c.setFillColor(color.cgColor)
                    c.fillEllipse(in: CGRect(x: x - dotDiameter / 2, y: y - dotDiameter / 2,
                                             width: dotDiameter, height: dotDiameter))
                }
            }
        }

        if let (glow, rect) = glowLayer(size: s, radius: size * 0.02, draw: drawDots) {
            ctx.saveGState()
            ctx.addPath(mask); ctx.clip()
            ctx.setAlpha(0.85)
            ctx.draw(glow, in: rect)
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(mask); ctx.clip()
        drawDots(ctx)
        ctx.restoreGState()
    }
}

// MARK: - Concept 4: Halo Bars — radial EQ, an emblem that scales beautifully small

func renderHaloBars(size: CGFloat) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let full = CGRect(x: 0, y: 0, width: size, height: size)
        let inset = size * 0.02
        let mask = squirclePath(in: full.insetBy(dx: inset, dy: inset))
        drawBasePlate(ctx, size: size, mask: mask)

        let center = CGPoint(x: size / 2, y: size / 2)
        let innerRadius = size * 0.12
        let maxOuter = size * 0.40
        let count = 40
        let strokeWidth = size * 0.016

        func drawRays(_ c: CGContext) {
            c.setLineCap(.round)
            c.setLineWidth(strokeWidth)
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count)
                let angle = t * 2 * .pi - .pi / 2
                let h1 = sin(angle * 3 + 0.4)
                let h2 = sin(angle * 7 - 1.1) * 0.35
                let amp = min(max(((h1 + h2 + 1) / 2), 0.22), 1)
                let outer = innerRadius + (maxOuter - innerRadius) * amp
                let dx = cos(angle), dy = sin(angle)
                c.setStrokeColor(heroColorLooped(t).cgColor)
                c.beginPath()
                c.move(to: CGPoint(x: center.x + dx * innerRadius, y: center.y + dy * innerRadius))
                c.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
                c.strokePath()
            }
            c.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
            c.fillEllipse(in: CGRect(x: center.x - innerRadius * 0.5, y: center.y - innerRadius * 0.5,
                                     width: innerRadius, height: innerRadius))
        }

        if let (glow, rect) = glowLayer(size: s, radius: size * 0.024, draw: drawRays) {
            ctx.saveGState()
            ctx.addPath(mask); ctx.clip()
            ctx.setAlpha(0.9)
            ctx.draw(glow, in: rect)
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(mask); ctx.clip()
        drawRays(ctx)
        ctx.restoreGState()
    }
}

// MARK: - Menu bar glyphs (template style: pure black shape + alpha, no colour)
//
// macOS recolours template images itself for light/dark menu bars and the click-highlight state, so
// these are drawn in solid black at full alpha with no gradient.

func renderGlyphBars(size: CGFloat, color: NSColor = .black) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let heights: [CGFloat] = [0.44, 0.70, 1.0, 0.70, 0.44]
        let count = heights.count
        let margin = size * 0.10
        let usable = size - margin * 2
        let gap: CGFloat = 0.34
        let slot = usable / CGFloat(count)
        let barWidth = slot * (1 - gap)
        let inset = (slot - barWidth) / 2
        ctx.setFillColor(color.cgColor)
        for (i, h) in heights.enumerated() {
            let barHeight = usable * h
            let x = margin + CGFloat(i) * slot + inset
            let rect = CGRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
            ctx.addPath(roundedBarPath(rect))
            ctx.fillPath()
        }
    }
}

func renderGlyphTouchBar(size: CGFloat, color: NSColor = .black) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let pill = CGRect(x: size * 0.04, y: size * 0.26, width: size * 0.92, height: size * 0.48)
        let pillPath = roundedBarPath(pill)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(size * 0.08)
        ctx.addPath(pillPath); ctx.strokePath()

        // Narrow, clearly-taller-than-wide bars, with more height contrast — at small sizes a bar
        // whose height is close to its width rounds into a dot instead of reading as a bar.
        let heights: [CGFloat] = [0.30, 1.0, 0.55]
        let barsRect = pill.insetBy(dx: size * 0.16, dy: size * 0.045)
        let slot = barsRect.width / CGFloat(heights.count)
        let barWidth = slot * 0.40
        let inset = (slot - barWidth) / 2
        ctx.setFillColor(color.cgColor)
        for (i, h) in heights.enumerated() {
            let barHeight = barsRect.height * h
            let x = barsRect.minX + CGFloat(i) * slot + inset
            let rect = CGRect(x: x, y: barsRect.midY - barHeight / 2, width: barWidth, height: barHeight)
            ctx.addPath(roundedBarPath(rect))
            ctx.fillPath()
        }
    }
}

func renderGlyphDots(size: CGFloat, color: NSColor = .black) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let diameters: [CGFloat] = [0.30, 0.52, 0.78, 1.0, 0.66, 0.40, 0.24]
        let count = diameters.count
        let margin = size * 0.06
        let usable = size - margin * 2
        let slot = usable / CGFloat(count)
        let maxDot = slot * 0.92
        ctx.setFillColor(color.cgColor)
        for (i, d) in diameters.enumerated() {
            let diameter = maxDot * d
            let cx = margin + slot * (CGFloat(i) + 0.5)
            let cy = size / 2
            ctx.fillEllipse(in: CGRect(x: cx - diameter / 2, y: cy - diameter / 2,
                                       width: diameter, height: diameter))
        }
    }
}

func renderGlyphSparkle(size: CGFloat, color: NSColor = .black) -> NSBitmapImageRep {
    let s = Int(size)
    return withContext(s, s) { ctx in
        let center = CGPoint(x: size / 2, y: size / 2)
        let inner = size * 0.10
        let longRay = size * 0.46
        let shortRay = size * 0.30
        let spokes = 8
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.round)
        for i in 0..<spokes {
            let angle = CGFloat(i) / CGFloat(spokes) * 2 * .pi - .pi / 2
            let outer = i % 2 == 0 ? longRay : shortRay
            ctx.setLineWidth(i % 2 == 0 ? size * 0.10 : size * 0.075)
            let dx = cos(angle), dy = sin(angle)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
            ctx.addLine(to: CGPoint(x: center.x + dx * outer, y: center.y + dy * outer))
            ctx.strokePath()
        }
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - inner * 0.55, y: center.y - inner * 0.55,
                                   width: inner * 1.1, height: inner * 1.1))
    }
}

// MARK: - Presentation mockups
//
// These composite the concepts into realistic context — a Dock row, a light menu bar, a dark menu
// bar — so they can be judged the way they will actually be seen, not as a bare square on nothing.
// Nothing here is baked into the deliverable icon/glyph files themselves.

/// Draws `image` centred at `point` scaled so its longest side is `targetSize`, plus a soft
/// contact shadow shaped like the icon's own alpha (a cheap but convincing Dock-style shadow).
func placeDockIcon(_ ctx: CGContext, image: CGImage, center: CGPoint, targetSize: CGFloat) {
    let rect = CGRect(x: center.x - targetSize / 2, y: center.y - targetSize / 2,
                      width: targetSize, height: targetSize)
    // Shadow: the icon's own silhouette, blurred and offset down, tinted black.
    let shadowSize = Int(targetSize)
    let shadowRep = withContext(shadowSize, shadowSize) { sctx in
        sctx.draw(image, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
    }
    if let cg = shadowRep.cgImage {
        let ci = CIImage(cgImage: cg)
        if let tint = CIFilter(name: "CIColorMatrix") {
            tint.setValue(ci, forKey: kCIInputImageKey)
            tint.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            tint.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
            tint.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
            tint.setValue(CIVector(x: 0, y: 0, z: 0, w: 0.55), forKey: "inputAVector")
            if let tinted = tint.outputImage,
               let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(tinted, forKey: kCIInputImageKey)
                blur.setValue(targetSize * 0.045, forKey: kCIInputRadiusKey)
                if let blurred = blur.outputImage {
                    let extent = ci.extent.insetBy(dx: -targetSize * 0.15, dy: -targetSize * 0.15)
                    if let cgShadow = ciContext.createCGImage(blurred, from: extent) {
                        let shadowRect = CGRect(x: center.x - extent.width / 2,
                                                y: center.y - extent.height / 2 - targetSize * 0.045,
                                                width: extent.width, height: extent.height)
                        ctx.draw(cgShadow, in: shadowRect)
                    }
                }
            }
        }
    }
    ctx.draw(image, in: rect)
}

func renderDockMockup(_ items: [(title: String, render: (CGFloat) -> NSBitmapImageRep)],
                      iconSize: CGFloat = 300, gap: CGFloat = 90) -> NSBitmapImageRep {
    let padding: CGFloat = 90
    let labelHeight: CGFloat = 70
    let width = padding * 2 + iconSize * CGFloat(items.count) + gap * CGFloat(items.count - 1)
    let height = padding + iconSize + labelHeight
    let w = Int(width), h = Int(height)

    return withContext(w, h) { ctx in
        // Abstract moody backdrop — soft blobs of colour on near-black, nothing photographic.
        ctx.setFillColor(NSColor(srgbRed: 0.05, green: 0.055, blue: 0.07, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let (glow, rect) = glowLayer(size: max(w, h), radius: 140, draw: { gctx in
            gctx.setFillColor(NSColor(srgbRed: 0.1, green: 0.25, blue: 0.5, alpha: 0.5).cgColor)
            gctx.fillEllipse(in: CGRect(x: width * 0.05, y: height * 0.3, width: 500, height: 500))
            gctx.setFillColor(NSColor(srgbRed: 0.15, green: 0.4, blue: 0.25, alpha: 0.45).cgColor)
            gctx.fillEllipse(in: CGRect(x: width * 0.65, y: height * 0.1, width: 480, height: 480))
        }) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(glow, in: rect)
            ctx.restoreGState()
        }

        for (i, item) in items.enumerated() {
            let cx = padding + iconSize / 2 + CGFloat(i) * (iconSize + gap)
            let cy = labelHeight + iconSize / 2 + (height - labelHeight - iconSize) / 2
            let rep = item.render(1024)
            if let cg = rep.cgImage {
                placeDockIcon(ctx, image: cg, center: CGPoint(x: cx, y: cy), targetSize: iconSize)
            }
            let label = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: NSColor(white: 0.92, alpha: 1),
            ])
            let size = label.size()
            drawText(ctx, label, at: CGPoint(x: cx - size.width / 2, y: 18))
        }
    }
}

func renderMenuBarMockup(_ concepts: [GlyphConcept], dark: Bool) -> NSBitmapImageRep {
    let width: CGFloat = 1400
    let barHeight: CGFloat = 76
    let captionHeight: CGFloat = 54
    let height = barHeight + captionHeight
    let w = Int(width), h = Int(height)
    let barColor = dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                        : NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    let glyphColor: NSColor = dark ? NSColor(white: 0.95, alpha: 0.92) : NSColor(white: 0.15, alpha: 0.92)
    let labelColor: NSColor = dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.45, alpha: 1)
    let backdrop = dark ? NSColor(srgbRed: 0.03, green: 0.03, blue: 0.035, alpha: 1)
                        : NSColor(srgbRed: 0.80, green: 0.81, blue: 0.83, alpha: 1)

    return withContext(w, h) { ctx in
        ctx.setFillColor(backdrop.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let bar = CGRect(x: 0, y: captionHeight, width: width, height: barHeight)
        ctx.setFillColor(barColor.cgColor)
        ctx.fill(bar)
        ctx.setFillColor((dark ? NSColor(white: 0, alpha: 0.5) : NSColor(white: 0, alpha: 0.12)).cgColor)
        ctx.fill(CGRect(x: 0, y: captionHeight, width: width, height: 1))

        // A few generic status-item placeholders on the right, purely as scale reference — not
        // reproductions of any real system icon.
        var cursor = width - 60
        func placeholder(_ draw: (CGContext, CGRect) -> Void) {
            let rect = CGRect(x: cursor - 26, y: captionHeight + barHeight / 2 - 13, width: 26, height: 26)
            draw(ctx, rect)
            cursor -= 46
        }
        placeholder { c, r in // battery-ish
            c.setStrokeColor(glyphColor.withAlphaComponent(0.55).cgColor)
            c.setLineWidth(2)
            let body = r.insetBy(dx: 2, dy: 6)
            c.stroke(CGRect(x: body.minX, y: body.minY, width: body.width - 4, height: body.height))
            c.setFillColor(glyphColor.withAlphaComponent(0.55).cgColor)
            c.fill(CGRect(x: body.minX + 2, y: body.minY + 2, width: (body.width - 8) * 0.6, height: body.height - 4))
        }
        placeholder { c, r in // wifi-ish
            c.setStrokeColor(glyphColor.withAlphaComponent(0.55).cgColor)
            c.setLineWidth(2.2)
            for radius: CGFloat in [4, 8, 12] {
                c.addArc(center: CGPoint(x: r.midX, y: r.minY + 2), radius: radius,
                         startAngle: .pi * 0.22, endAngle: .pi * 0.78, clockwise: false)
                c.strokePath()
            }
        }

        // The candidate glyphs, spaced like real status items, each with a caption underneath.
        let glyphSize: CGFloat = 30
        let slot = (cursor - 24) / CGFloat(concepts.count)
        for (i, concept) in concepts.enumerated() {
            let cx = 24 + slot * (CGFloat(i) + 0.5)
            let rep = concept.render(glyphSize * 3, glyphColor) // over-render, then draw down for crispness
            if let cg = rep.cgImage {
                ctx.draw(cg, in: CGRect(x: cx - glyphSize / 2, y: captionHeight + barHeight / 2 - glyphSize / 2,
                                        width: glyphSize, height: glyphSize))
            }
            let label = NSAttributedString(string: concept.title, attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: labelColor,
            ])
            let size = label.size()
            drawText(ctx, label, at: CGPoint(x: cx - size.width / 2, y: 14))
        }
    }
}

// MARK: - Driver

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

struct AppIconConcept {
    let key: String
    let title: String
    let render: (CGFloat) -> NSBitmapImageRep
}
let appIconConcepts: [AppIconConcept] = [
    AppIconConcept(key: "spectrum-burst", title: "Spectrum Burst", render: renderSpectrumBurst),
    AppIconConcept(key: "touchbar-chip", title: "Touch Bar Chip", render: renderTouchBarChip),
    AppIconConcept(key: "dot-wave", title: "Retro Dot Wave", render: renderDotWave),
    AppIconConcept(key: "halo-bars", title: "Halo Bars", render: renderHaloBars),
]

struct GlyphConcept {
    let key: String
    let title: String
    let render: (CGFloat, NSColor) -> NSBitmapImageRep
}
let glyphConcepts: [GlyphConcept] = [
    GlyphConcept(key: "bars", title: "EQ Bars", render: renderGlyphBars),
    GlyphConcept(key: "touchbar", title: "Touch Bar", render: renderGlyphTouchBar),
    GlyphConcept(key: "dots", title: "Dot Pulse", render: renderGlyphDots),
    GlyphConcept(key: "sparkle", title: "Sparkle", render: renderGlyphSparkle),
]

print("Rendering app icons…")
for concept in appIconConcepts {
    for size: CGFloat in [1024, 512, 256, 128, 64, 32] {
        let rep = concept.render(size)
        save(rep, "\(outDir)/appicon-\(concept.key)-\(Int(size)).png")
    }
    print("  \(concept.title) done")
}

print("Rendering menu bar glyphs…")
for concept in glyphConcepts {
    for size: CGFloat in [512, 128, 44, 36, 22] {
        let rep = concept.render(size, .black)
        save(rep, "\(outDir)/glyph-\(concept.key)-\(Int(size)).png")
    }
    print("  \(concept.title) done")
}

print("Rendering mockups…")
save(renderDockMockup(appIconConcepts.map { ($0.title, $0.render) }), "\(outDir)/mockup-dock.png")
save(renderMenuBarMockup(glyphConcepts, dark: false), "\(outDir)/mockup-menubar-light.png")
save(renderMenuBarMockup(glyphConcepts, dark: true), "\(outDir)/mockup-menubar-dark.png")

// MARK: - Touch Bar Chip variations
//
// Six takes on the concept the user singled out, each changing one or two things: bar direction,
// colour, proportions, content type, and chrome (hard rim vs. soft implied panel).

let chipVariants: [(title: String, render: (CGFloat) -> NSBitmapImageRep)] = [
    ("Original", { size in renderChipVariant(size: size) }),
    ("Grounded Bars", { size in
        renderChipVariant(size: size, mirrored: false)
    }),
    ("Mono Glass", { size in
        renderChipVariant(size: size, mono: true, glowFrac: 0.028)
    }),
    ("Wide & Thin", { size in
        renderChipVariant(size: size, pillWidthFrac: 0.88, pillHeightFrac: 0.13, count: 17)
    }),
    ("Dot Row", { size in
        renderChipVariant(size: size, count: 9, useDots: true)
    }),
    ("Floating Glass", { size in
        renderChipVariant(size: size, count: 13, hardOutline: false, glowFrac: 0.03)
    }),
]

print("Rendering Touch Bar Chip variations…")
for variant in chipVariants {
    let rep = variant.render(1024)
    let key = variant.title.lowercased().replacingOccurrences(of: " & ", with: "-")
                                        .replacingOccurrences(of: " ", with: "-")
    save(rep, "\(outDir)/chip-\(key).png")
}
save(renderDockMockup(chipVariants, iconSize: 260, gap: 60), "\(outDir)/mockup-chip-variants.png")

// MARK: - Export "Dot Row" as a real macOS .iconset
//
// The chosen design, re-rendered natively at every size iconutil requires (rather than downsampled
// from the 1024 master) so the pill's hairline rim and the dot edges stay crisp at small sizes.

print("Exporting Dot Row as SoundBar.iconset…")
let iconsetDir = "\(outDir)/SoundBar.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
let iconsetSizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in iconsetSizes {
    let rep = renderChipVariant(size: size, count: 9, useDots: true)
    save(rep, "\(iconsetDir)/\(name).png")
}
print("  wrote \(iconsetSizes.count) sizes to \(iconsetDir)")

print("Done.")
