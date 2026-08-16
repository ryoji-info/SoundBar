import AppKit
import CoreAudio

/// SoundBar: a single background agent that watches audio activity and draws its own audio visualiser
/// on the Touch Bar.
///
/// Version 2 absorbed AVTouchBar's job. That removes a second menu bar icon and a window that used to
/// flash on screen, and — the real win — it removes the aggregate device that AVTouchBar installed as
/// the system default output. SoundBar captures audio with a *private* CoreAudio process tap, so the
/// user's output device, and therefore the volume keys, are never touched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let audio = AudioActivityMonitor()
    private let btt = BTTController()
    private let gestures = TouchBarGestureReader()

    private let outputAnalyzer = SpectrumAnalyzer(barCount: Settings.shared.barCount)
    private let micAnalyzer = SpectrumAnalyzer(barCount: Settings.shared.barCount)
    private lazy var tap = SystemAudioTap(analyzer: outputAnalyzer)
    private lazy var microphone = MicrophoneCapture(analyzer: micAnalyzer)
    private let visualizer = TouchBarVisualizer()

    private var coordinator: Coordinator!
    private var menuBar: MenuBarController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app", "SoundBar starting (pid \(ProcessInfo.processInfo.processIdentifier))")

        // Take a copy of any AVTouchBar colour sets so they survive Downloads being cleared.
        PaletteLibrary.importExternalPalettesIfNeeded()
        Log.info("app", "palettes available: \(PaletteLibrary.names.joined(separator: ", "))")

        guard TouchBarVisualizer.privateAPIAvailable else {
            Log.error("app", "this macOS no longer exposes the Touch Bar presentation API")
            return
        }

        coordinator = Coordinator(visualizer: visualizer, tap: tap, microphone: microphone,
                                  btt: btt, audio: audio)

        if settings.showMenuBarItem {
            let menu = MenuBarController(coordinator: coordinator, btt: btt, audio: audio)
            menu.install()
            menuBar = menu
        }

        audio.onChange = { [weak self] output, input in
            self?.coordinator.updateActivity(output: output, input: input)
            self?.menuBar?.refreshIcon()
        }
        audio.start()

        gestures.onLongPress = { [weak self] in
            self?.coordinator.handleLongPress()
            self?.menuBar?.refreshIcon()
        }
        gestures.onSingleTap = { [weak self] in
            self?.coordinator.handleSingleTap()
            self?.menuBar?.refreshIcon()
        }
        gestures.onTwoFingerTap = { [weak self] in
            self?.coordinator.handleTwoFingerTap()
            self?.menuBar?.refreshIcon()
        }
        gestures.onDoubleTap = { [weak self] in
            self?.coordinator.handleDoubleTap()
            self?.menuBar?.refreshIcon()
        }
        gestures.start()

        settings.onChange { [weak self] in
            guard let self else { return }
            // The coordinator owns the band count, because it depends on the current pattern.
            self.coordinator.settingsChanged()
            self.gestures.refreshTunables()
            self.menuBar?.refreshIcon()
        }

        installTerminationHandlers()
        standDownAVTouchBarIfRunning()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.coordinator.reconcileAtStartup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("app", "SoundBar stopping")
        shutDownCleanly()
    }

    /// AVTouchBar is no longer needed, and merely running it is enough for it to hold the Touch Bar,
    /// which would fight SoundBar for the strip. If it is running, stand it down.
    private func standDownAVTouchBarIfRunning() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.jakefishman.TouchBarVisualizer")
        guard !running.isEmpty else { return }
        Log.info("app", "AVTouchBar is running; quitting it — SoundBar now draws the Touch Bar itself")
        for app in running where !app.terminate() {
            app.forceTerminate()
        }
    }

    /// launchd sends SIGTERM at logout and when restarting the agent, and NSApplication does not
    /// handle it. Without this the Touch Bar could be left held by a process that is gone.
    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Log.info("app", "received signal \(sig); shutting down cleanly")
                self?.shutDownCleanly()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutDownCleanly() {
        gestures.stop()
        audio.stop()
        visualizer.dismiss()
        tap.stop()
        microphone.stop()
    }
}

// MARK: - Diagnostics
//
// Each flag runs one thing and exits, so the pieces can be checked in isolation.

if CommandLine.arguments.contains("--help") {
    print("""
    SoundBar — audio visualiser for the Touch Bar

    Touch Bar gestures
      one-finger tap        next colour
      two-finger tap        next pattern
      double tap            mute / unmute
      long press            stop the visualiser until audio restarts
      one-finger slide      volume

    Usage
      (no arguments)        run as the background agent
      --selftest            60 s interactive check of the gestures and microphone
      --visualizer-test     put a test pattern on the Touch Bar
                            (--cycle to tour all patterns, --seconds N each, --windowed)
      --list-palettes       list the colour ramps, including imported AVTouchBar sets
      --render-preview P    render every pattern to PNG P (--palette NAME, --ramp, --zoom N)
      --tap-test            capture system audio and print band levels
      --watch-touches       print Touch Bar contacts as they arrive (--raw for hex frames)
      --check-btt           ask whether BetterTouchTool has the Touch Bar
      --ruler               put a measuring ruler on the Touch Bar, to find the visible width
    """)
    exit(0)
}

if CommandLine.arguments.contains("--list-palettes") {
    PaletteLibrary.importExternalPalettesIfNeeded()
    print("palettes:")
    for palette in PaletteLibrary.all() {
        let swatch = palette.colors(count: 6).map { color -> String in
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255),
                          Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        }.joined(separator: " ")
        print(String(format: "  %-22@ %@", palette.name as NSString, swatch as NSString))
    }
    exit(0)
}

// Render every style to a PNG so the layouts can be checked without a Touch Bar.
if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
    PaletteLibrary.importExternalPalettesIfNeeded()
    let outPath = index + 1 < CommandLine.arguments.count
        ? CommandLine.arguments[index + 1] : "/tmp/soundbar-styles.png"
    let paletteName = CommandLine.arguments.firstIndex(of: "--palette").map { i -> String in
        i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "Green"
    } ?? "Green"
    let palette = PaletteLibrary.palette(named: paletteName)

    var zoom = 1
    if let i = CommandLine.arguments.firstIndex(of: "--zoom"), i + 1 < CommandLine.arguments.count,
       let v = Int(CommandLine.arguments[i + 1]) { zoom = max(1, min(8, v)) }
    // Zoom renders a narrower slice of the strip at a larger size, so the geometry can be checked.
    // --zoom-offset slides that window along the strip, e.g. to look at the far right end.
    var zoomOffset: CGFloat = 0
    if let i = CommandLine.arguments.firstIndex(of: "--zoom-offset"), i + 1 < CommandLine.arguments.count,
       let v = Double(CommandLine.arguments[i + 1]) { zoomOffset = CGFloat(v) }
    let stripWidth = zoom > 1 ? 320 : 1085
    let stripHeight = 30 * zoom, gap = 16, labelWidth = 150
    let styles = VisualStyle.allCases
    let totalHeight = (stripHeight + gap) * styles.count + gap
    let totalWidth = stripWidth + labelWidth

    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: totalWidth,
                                        pixelsHigh: totalHeight, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        print("could not create the bitmap"); exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

    // Plausible spectrum: energy falling with frequency, with a couple of peaks.
    let bars = Settings.shared.barCount
    let useRamp = CommandLine.arguments.contains("--ramp")
    // Each pattern gets the band count it would really run at, so the x2 patterns are shown with
    // twice as many bars rather than the same bars drawn wider.
    func makeLevels(count: Int) -> [Float] {
        (0..<count).map { i -> Float in
            let t = Double(i) / Double(count)
            if useRamp { return Float(0.05 + 0.95 * t) }   // orientation check
            let envelope = pow(1 - t, 0.8)
            let peak1 = exp(-pow((t - 0.12) / 0.05, 2)) * 0.5
            let peak2 = exp(-pow((t - 0.42) / 0.08, 2)) * 0.35
            return Float(min(1, max(0.03, envelope * 0.75 + peak1 + peak2)))
        }
    }

    let wave = (0..<220).map { i -> Float in
        let t = Double(i) / 220.0
        return Float(0.30 * sin(t * 21) + 0.12 * sin(t * 53 + 1) + 0.05 * sin(t * 97))
    }
    let vu: (left: Float, right: Float, peakLeft: Float, peakRight: Float) = (0.72, 0.58, 0.86, 0.71)

    for (index, style) in styles.enumerated() {
        let y = totalHeight - gap - (stripHeight + gap) * (index + 1) + gap
        cg.saveGState()
        cg.translateBy(x: CGFloat(labelWidth), y: CGFloat(y))
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(stripWidth), height: CGFloat(stripHeight))
        cg.clip(to: bounds)
        // Draw the full-width strip but shifted, so a zoomed window can sit anywhere along it.
        var drawBounds = bounds
        if zoom > 1 {
            cg.translateBy(x: -zoomOffset * CGFloat(zoom), y: 0)
            drawBounds = CGRect(x: 0, y: 0, width: 1085 * CGFloat(zoom), height: CGFloat(stripHeight))
        }
        VisualRenderer.draw(style, VisualFrame(levels: makeLevels(count: bars * style.bandMultiplier),
                                               waveform: wave, vu: vu,
                                               palette: palette, bounds: drawBounds), in: cg)
        cg.restoreGState()

        let label = NSAttributedString(string: style.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        label.draw(at: CGPoint(x: 8, y: CGFloat(y) + 8))
    }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        print("could not encode PNG"); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)  (palette: \(palette.name))")
    exit(0)
}

// Draw a ruler on the Touch Bar so the genuinely visible width can be read off it. The view reports
// 1085 pt, but anything the strip clips is invisible, and there is no way to screenshot the DFR.
if CommandLine.arguments.contains("--ruler") {
    Log.verbose = true
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    final class RulerView: NSView {
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)

            // A tick every 25 pt; a taller, labelled one every 100.
            for x in stride(from: 0, through: Int(bounds.width), by: 25) {
                let major = x % 100 == 0
                context.setFillColor(NSColor(white: major ? 0.95 : 0.45, alpha: 1).cgColor)
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: major ? 10 : 5))
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for x in stride(from: 0, through: Int(bounds.width), by: 100) {
                NSAttributedString(string: "\(x)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]).draw(at: CGPoint(x: CGFloat(x) + 2, y: 12))
            }
            // Finer labels over the last stretch, where the clipping actually is.
            for x in stride(from: 1000, through: Int(bounds.width), by: 10) {
                NSAttributedString(string: "\(x)", attributes: [
                    .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                    .foregroundColor: NSColor.systemYellow,
                ]).draw(at: CGPoint(x: CGFloat(x) + 1, y: x % 20 == 0 ? 2 : 22))
            }
            // Unmistakable end markers: red at the far right, green at the far left.
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 24, width: 40, height: 6).fill()
            NSColor.systemRed.setFill()
            NSRect(x: bounds.width - 40, y: 24, width: 40, height: 6).fill()
            NSAttributedString(string: "END", attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]).draw(at: CGPoint(x: bounds.width - 30, y: 12))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    final class Runner: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
        let identifier = NSTouchBarItem.Identifier("com.ryoji.SoundBar.ruler")
        var bar: NSTouchBar?
        var width: CGFloat = 1085
        func applicationDidFinishLaunching(_ n: Notification) {
            if let i = CommandLine.arguments.firstIndex(of: "--width"), i + 1 < CommandLine.arguments.count,
               let v = Double(CommandLine.arguments[i + 1]) { width = CGFloat(v) }
            let bar = NSTouchBar()
            bar.delegate = self
            bar.defaultItemIdentifiers = [identifier]
            self.bar = bar
            DFRSystemModalShowsCloseBoxWhenFrontMost(false)
            NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: nil)
            print("ruler presented at \(Int(width)) pt wide — read the largest number you can see")
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                NSTouchBar.dismissSystemModalTouchBar(bar)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
            }
        }
        func touchBar(_ t: NSTouchBar, makeItemForIdentifier i: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
            let item = NSCustomTouchBarItem(identifier: i)
            let view = RulerView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            item.view = view
            return item
        }
    }
    let runner = Runner()
    app.delegate = runner
    app.run()
}

if CommandLine.arguments.contains("--visualizer-test") {
    Log.verbose = true
    PaletteLibrary.importExternalPalettesIfNeeded()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    final class Runner: NSObject, NSApplicationDelegate {
        let visualizer = TouchBarVisualizer()
        var phase = 0.0
        func applicationDidFinishLaunching(_ n: Notification) {
            let fullscreen = !CommandLine.arguments.contains("--windowed")

            // Synthetic but plausible data, so every style has something sensible to draw without
            // needing audio to be playing.
            visualizer.frameProvider = { [weak self] in
                guard let self else { return emptyVisualFrameData }
                self.phase += 0.09
                let bars = Settings.shared.barCount
                let levels = (0..<bars).map { i -> Float in
                    let t = Double(i) / Double(bars)
                    // Falling response with frequency, plus a travelling ripple.
                    let envelope = pow(1 - t, 0.7)
                    return Float(max(0.03, envelope * (0.55 + 0.45 * sin(self.phase + t * 9))))
                }
                let wave = (0..<220).map { i -> Float in
                    let t = Double(i) / 220.0
                    return Float(0.22 * sin(self.phase * 2 + t * 18) + 0.08 * sin(self.phase * 5 + t * 47))
                }
                let l = Float(0.5 + 0.35 * sin(self.phase * 0.7))
                let r = Float(0.5 + 0.35 * sin(self.phase * 0.7 + 0.9))
                return (levels, wave, (l, r, min(1, l + 0.12), min(1, r + 0.12)))
            }

            print("present(fullscreen: \(fullscreen)) -> \(visualizer.present(fullscreen: fullscreen))")

            // Cycle every style so all six can be seen in one run.
            let cycle = CommandLine.arguments.contains("--cycle")
            var perStyle = 4.0
            if let i = CommandLine.arguments.firstIndex(of: "--seconds"),
               i + 1 < CommandLine.arguments.count,
               let v = Double(CommandLine.arguments[i + 1]) { perStyle = v }

            if cycle {
                let styles = VisualStyle.allCases
                for (index, style) in styles.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + perStyle * Double(index)) {
                        self.visualizer.style = style
                        print("  showing: \(style.displayName)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + perStyle * Double(styles.count)) {
                    self.visualizer.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            } else {
                print("  showing: \(visualizer.style.displayName)")
                DispatchQueue.main.asyncAfter(deadline: .now() + perStyle * 3) {
                    self.visualizer.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
                }
            }
        }
    }
    let runner = Runner()
    app.delegate = runner
    app.run()
}

if CommandLine.arguments.contains("--tap-test") {
    Log.verbose = true
    func defaultOutputName() -> String {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return "\(VolumeController.name(of: id) ?? "?") (id \(id))"
    }
    print("default output BEFORE: \(defaultOutputName())")
    let analyzer = SpectrumAnalyzer(barCount: 16)
    let tap = SystemAudioTap(analyzer: analyzer)
    guard tap.start() else {
        print("TAP FAILED: \(tap.lastError ?? "unknown")")
        exit(2)
    }
    print("default output AFTER : \(defaultOutputName())   <- must be identical")
    print("listening 12 s — play something:")
    var withSignal = 0
    for tick in 0..<24 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let levels = analyzer.levels()
        let peak = levels.max() ?? 0
        if peak > 0.01 { withSignal += 1 }
        let blocks = ["·", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let bars = levels.map { blocks[min(blocks.count - 1, Int($0 * Float(blocks.count)))] }.joined()
        print(String(format: "  t=%4.1fs peak=%.3f  %@", Double(tick) * 0.5, peak, bars))
    }
    tap.stop()
    print("default output AT END: \(defaultOutputName())")
    print(withSignal > 0 ? "\nPASS — audio reached the tap (\(withSignal)/24 frames)"
                         : "\nNO SIGNAL — the tap ran but every frame was silent")
    exit(withSignal > 0 ? 0 : 3)
}

if CommandLine.arguments.contains("--watch-touches") {
    Log.verbose = true
    if CommandLine.arguments.contains("--raw") {
        MultitouchTouchBarSource.rawDumpFramesRemaining = 3
    }
    let source = MultitouchTouchBarSource()
    var seen = 0
    source.onTouch = { sample in
        seen += 1
        print(String(format: "contact id=%-3d x=%.4f y=%.4f down=%@",
                     sample.id, sample.x, sample.y, sample.isDown ? "YES" : "no "))
    }
    guard source.start() else {
        print("FAILED to open the Touch Bar digitiser — see the log")
        exit(1)
    }
    print("Listening 25 s. Touch and slide on the Touch Bar now…")
    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    source.stop()
    print("\n\(seen) contact sample(s) received.")
    exit(seen > 0 ? 0 : 2)
}

if CommandLine.arguments.contains("--selftest") {
    Log.verbose = true
    let startVolume = VolumeController.currentVolume()
    var longPresses = 0
    var slideSteps = 0
    var micSeen = false

    var singleTaps = 0, twoFingerTaps = 0, doubleTaps = 0
    let gestures = TouchBarGestureReader()
    gestures.onLongPress = {
        longPresses += 1
        print("  ✓ LONG PRESS detected (\(longPresses))")
    }
    gestures.onSingleTap = {
        singleTaps += 1
        print("  ✓ ONE-FINGER TAP (would switch colour)")
    }
    gestures.onTwoFingerTap = {
        twoFingerTaps += 1
        print("  ✓ TWO-FINGER TAP (would switch pattern)")
    }
    gestures.onDoubleTap = {
        doubleTaps += 1
        print("  ✓ DOUBLE TAP (would mute)")
    }
    gestures.recognizer.onSlide = { steps in
        slideSteps += Int(abs(steps))
        let volume = VolumeController.adjustVolume(by: Float(steps / 16.0))
        print(String(format: "  ✓ SLIDE %+d step(s) -> volume %@", Int(steps),
                     volume.map { String(format: "%.2f", $0) } ?? "unchanged"))
    }
    gestures.start()

    let audio = AudioActivityMonitor()
    audio.onChange = { output, input in
        if input && !micSeen {
            micSeen = true
            print("  ✓ MICROPHONE detected as active")
        }
        print("     (audio: output=\(output) input=\(input))")
    }
    audio.start()

    print("""

    SoundBar self-test — 60 seconds. Nothing here changes any setting.
    Please try these, in any order:
      1. TAP once with one finger.
      2. TAP with two fingers together.
      3. DOUBLE TAP with one finger.
      4. Press and HOLD one finger still for about half a second.
      5. SLIDE one finger left and right.
      6. Turn a microphone on — e.g. open Voice Memos and record, or Photo Booth.

    """)
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    gestures.stop()
    audio.stop()
    if let startVolume {
        VolumeController.setVolume(startVolume)
        print(String(format: "\nvolume restored to %.3f", startVolume))
    }
    print("""

    ===== RESULT =====
    One-finger tap  : \(singleTaps > 0 ? "PASS (\(singleTaps))" : "not seen")
    Two-finger tap  : \(twoFingerTaps > 0 ? "PASS (\(twoFingerTaps))" : "not seen")
    Double tap      : \(doubleTaps > 0 ? "PASS (\(doubleTaps))" : "not seen")
    Long press      : \(longPresses > 0 ? "PASS (\(longPresses))" : "not seen")
    Slide to volume : \(slideSteps > 0 ? "PASS (\(slideSteps) step(s))" : "not seen")
    Microphone      : \(micSeen ? "PASS" : "not seen")
    """)
    exit(0)
}

if CommandLine.arguments.contains("--check-btt") {
    let done = DispatchSemaphore(value: 0)
    BTTController().verifyOwnsTouchBar { state in
        print("BTT state: \(state)")
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// MARK: - Normal launch

// Only one SoundBar should ever run; a second copy would fight the first over the Touch Bar.
let ownBundleID = Bundle.main.bundleIdentifier ?? "com.ryoji.SoundBar"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: ownBundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    Log.warn("app", "another SoundBar instance is already running; exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
