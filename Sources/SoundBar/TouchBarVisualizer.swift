import AppKit
import IOKit

/// Puts SoundBar's own spectrum view on the Touch Bar, replacing AVTouchBar entirely.
///
/// This is the piece that makes SoundBar a single app: it presents a system-modal `NSTouchBar` from a
/// background agent, so there is no second menu bar icon, no Setup window flashing, and — crucially —
/// no aggregate device installed as the system default output, which is what used to kill the volume
/// keys.
///
/// The presentation calls are private AppKit/DFRFoundation (see `Private.h`). Every one is probed
/// before use, and failure is reported rather than crashing.
final class TouchBarVisualizer: NSObject, NSTouchBarDelegate {

    static let itemIdentifier = NSTouchBarItem.Identifier("com.ryoji.SoundBar.visualizer")

    /// Asked for a frame of data each tick.
    var frameProvider: (() -> VisualFrameData)?

    /// The pattern being drawn. Setting it takes effect on the next frame.
    var style: VisualStyle = Settings.shared.style {
        didSet { view?.style = style }
    }

    /// Called when the strip is given up, so the coordinator can check on BetterTouchTool.
    var onDismissed: (() -> Void)?

    private let settings = Settings.shared
    private var touchBar: NSTouchBar?
    private var view: VisualizerView?
    private var renderTimer: DispatchSourceTimer?
    private var keepAwakeTimer: DispatchSourceTimer?
    private var screenObservers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private(set) var isPresenting = false

    /// Width of the strip in points when nothing else is on it. The control-strip-visible width is
    /// about 685; presenting fullscreen gives us the lot.
    private let fullWidth: CGFloat = 1085
    private let stripHeight: CGFloat = 30

    override init() {
        super.init()
        // The keep-awake ticks and the render loop are pointless while the screens are asleep —
        // and the ticks would be worse than pointless, holding the strip lit next to a dark
        // display. Pause both for as long as the screens are.
        let center = NSWorkspace.shared.notificationCenter
        screenObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screensAsleep = true
            self.stopRendering()
            self.stopKeepAwake()
            Log.info("visualizer", "screens asleep; rendering and keep-awake paused")
        })
        screenObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.screensAsleep = false
            guard self.isPresenting else { return }
            self.startRendering()
            self.startKeepAwake()
            Log.info("visualizer", "screens awake; rendering and keep-awake resumed")
        })
    }

    deinit {
        for observer in screenObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Presentation

    /// Take the Touch Bar. `fullscreen` hides the control strip so the visualiser spans the whole strip.
    @discardableResult
    func present(fullscreen: Bool) -> Bool {
        guard Self.privateAPIAvailable else {
            Log.error("visualizer", "the private Touch Bar presentation API is unavailable on this macOS")
            return false
        }
        if isPresenting {
            startRendering()
            return true
        }

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.itemIdentifier]
        touchBar = bar

        // No Esc/close box drawn over our view.
        DFRSystemModalShowsCloseBoxWhenFrontMost(false)

        if fullscreen {
            // nil tray identifier == nothing left in the control strip, i.e. we own the whole strip.
            NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: nil)
        } else {
            // Keep the control strip alongside, with a button that brings us back.
            DFRElementSetControlStripPresenceForIdentifier(Self.itemIdentifier, true)
            NSTouchBar.presentSystemModalTouchBar(bar, placement: 0,
                                                 systemTrayItemIdentifier: Self.itemIdentifier)
        }

        isPresenting = true
        startRendering()
        startKeepAwake()
        Log.info("visualizer", "presented on the Touch Bar (fullscreen=\(fullscreen))")
        return true
    }

    func dismiss() {
        stopRendering()
        stopKeepAwake()
        guard isPresenting, let bar = touchBar else { return }
        isPresenting = false
        NSTouchBar.dismissSystemModalTouchBar(bar)
        DFRElementSetControlStripPresenceForIdentifier(Self.itemIdentifier, false)
        touchBar = nil
        view = nil
        Log.info("visualizer", "dismissed; Touch Bar released")
        onDismissed?()
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let visualizer = VisualizerView(frame: NSRect(x: 0, y: 0, width: fullWidth, height: stripHeight))
        visualizer.translatesAutoresizingMaskIntoConstraints = false
        visualizer.widthAnchor.constraint(equalToConstant: fullWidth).isActive = true
        visualizer.style = style
        visualizer.frameProvider = { [weak self] in
            self?.frameProvider?() ?? emptyVisualFrameData
        }
        item.view = visualizer
        view = visualizer
        Log.debug("visualizer", "touch bar item created")
        return item
    }

    // MARK: - Render loop

    /// Runs only while the visualiser is on screen, so SoundBar costs nothing when idle.
    private func startRendering() {
        stopRendering()
        let interval = 1.0 / settings.frameRate
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self, let view = self.view else { return }
            view.refresh()
            self.logLevelsOccasionally()
        }
        timer.resume()
        renderTimer = timer
        Log.debug("visualizer", "rendering at \(settings.frameRate) fps")
    }

    /// Once a second, while verbose logging is on, record the peak level. This is the only way to see
    /// from the outside whether real audio is reaching the visualiser — a silent tap (for example a
    /// missing audio-capture grant) looks identical to silence otherwise.
    private var lastLevelLog = Date.distantPast
    private func logLevelsOccasionally() {
        guard Log.verbose, Date().timeIntervalSince(lastLevelLog) > 1.0 else { return }
        lastLevelLog = Date()
        let levels = frameProvider?().levels ?? []
        let peak = levels.max() ?? 0
        Log.debug("visualizer", String(format: "style=%@ peak %.3f across %d bars%@",
                                       style.rawValue, peak, levels.count,
                                       peak < 0.001 ? "  (SILENT — check audio-capture permission)" : ""))
    }

    private func stopRendering() {
        renderTimer?.cancel()
        renderTimer = nil
    }

    // MARK: - Keep-awake
    //
    // Goal: stop the Touch Bar from idle-dimming (~60 s) while the visualiser is up. The result of a
    // thorough attempt is that this is NOT achievable from a user-space, ad-hoc-signed agent on this
    // macOS, so the tick below is a harmless best-effort that a future OS might honour — it is
    // deliberately chosen to have no side effects when it fails.
    //
    // What was tried, all measured on this machine, none of which kept the strip lit:
    //   1. DFRFoundationPostEventWithMouseActivity  — Touch-Bar-local synthetic event; strip dims
    //      on schedule regardless.
    //   2. IOHIDPostEvent NX_NULLEVENT  — resets the system HIDIdleTime counter (127 s → 1.5 s,
    //      verified) yet the strip still dims, so TouchBarServer is not gated on that counter.
    //   3. IOHIDPostEvent NX_MOUSEMOVED, and a CGEvent .mouseMoved  — no effect on the strip.
    //   4. DFRSetDimmingStep / DFRDSetDimmingStep (every signature)  — the dimmed bezel brightness
    //      stayed at 0.800; TouchBarServer re-asserts its own dim state.
    //   5. No user-settable dimming preference exists (com.apple.touchbar.agent /
    //      com.apple.TouchBarServer carry no dim / idle keys).
    //
    // TouchBarServer tracks a hardware multitouch/HID activity path (its own state calls it
    // `mtCounterDomain` / `_isUserActive`) that synthetic events from this process do not reach.
    // Defeating it would need SIP disabled, which is out of scope.
    //
    // The tick uses only the Touch-Bar-local DFR post: unlike a system HID event it does NOT reset
    // HIDIdleTime, so — critically — it never keeps the *display* awake or blocks the screensaver.
    // An earlier CGEvent-based version did have that side effect (with no benefit) and was removed.

    private var keepAwakeWarned = false

    private func startKeepAwake() {
        stopKeepAwake()
        guard settings.keepTouchBarAwake else { return }
        keepAwakeWarned = false

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 25)
        timer.setEventHandler { [weak self] in
            self?.keepAwakeTick()
        }
        timer.resume()
        keepAwakeTimer = timer
    }

    private func stopKeepAwake() {
        keepAwakeTimer?.cancel()
        keepAwakeTimer = nil
    }

    private func keepAwakeTick() {
        guard settings.keepTouchBarAwake, isPresenting, !screensAsleep else { return }
        // Harmless best-effort: touch-bar-scoped, no HIDIdleTime reset, no display-sleep side effect.
        DFRFoundationPostEventWithMouseActivity(.mouseMoved, .zero)
        if !keepAwakeWarned {
            keepAwakeWarned = true
            Log.info("visualizer", "keep-awake: the Touch Bar still dims after ~60 s; macOS ignores "
                                 + "synthetic activity from a background agent. See the code note.")
        }
    }

    // MARK: - Availability

    /// Whether every private entry point we need is present.
    static let privateAPIAvailable: Bool = {
        let cls: AnyClass = NSTouchBar.self
        let needed = [
            "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
            "dismissSystemModalTouchBar:",
        ]
        for name in needed where !cls.responds(to: NSSelectorFromString(name)) {
            Log.error("visualizer", "NSTouchBar is missing \(name)")
            return false
        }
        return true
    }()
}
