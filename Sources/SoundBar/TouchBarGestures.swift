import Foundation
import IOKit.hid

/// One contact on the Touch Bar surface, in normalised 0...1 coordinates.
struct TouchSample {
    let id: Int32
    let x: Double
    let y: Double
    let timestamp: TimeInterval
    let isDown: Bool
}

/// Turns a stream of Touch Bar contacts into the gestures SoundBar acts on.
///
/// Recognition works on *touch sessions*: a session opens when the first finger lands and closes when
/// the last one lifts. Deciding at the end of a session — rather than per contact — is what makes the
/// one-finger and two-finger taps cleanly separable, because by then the highest number of fingers
/// that were down simultaneously is known.
///
/// The gestures are mutually exclusive by construction:
///
/// | Gesture | Condition | Action |
/// |---|---|---|
/// | One-finger tap | 1 finger, < 300 ms, ≤ 4 mm, no second tap follows | next colour |
/// | One-finger double tap | two such taps within 320 ms | mute |
/// | Two-finger tap | 2 fingers, < 300 ms, ≤ 4 mm | next pattern |
/// | Long press | 1 finger, ≥ 450 ms, ≤ 4 mm | stop the visualiser |
/// | Slide | 1 finger, > 5 mm of travel | volume |
///
/// A single tap is necessarily delayed by the double-tap window: it cannot fire until it is known that
/// no second tap is coming. 320 ms is short enough to feel immediate and long enough to be reachable.
final class TouchBarGestureRecognizer {
    /// One finger, tapped once.
    var onSingleTap: (() -> Void)?
    /// One finger, tapped twice in quick succession.
    var onDoubleTap: (() -> Void)?
    /// Two fingers, tapped together.
    var onTwoFingerTap: (() -> Void)?
    /// One finger held still.
    var onLongPress: (() -> Void)?
    /// Horizontal drag, carrying whole volume steps (positive = rightwards/louder).
    var onSlide: ((Double) -> Void)?

    private let settings = Settings.shared

    /// Only x is tracked. The Touch Bar digitiser has just two sensor rows across 8.1 mm, so its y
    /// value is too coarse to threshold on — any y-based slop test misbehaves.
    private struct Contact {
        let id: Int32
        let startTime: TimeInterval
        var minX: Double
        var maxX: Double
        var lastX: Double
        /// Signed travel not yet converted into a volume step, in millimetres.
        var pendingMM: Double
    }

    /// State for the current touch session, i.e. from first finger down to last finger up.
    private struct Session {
        var startTime: TimeInterval
        var maxFingers: Int = 1
        var maxSpreadMM: Double = 0
        var longPressFired = false
        var committedToSlide = false
        /// The strip was dark when this session began, so the touch is only waking it and must not
        /// also be read as a gesture.
        var wakeOnly = false
    }

    /// Seconds the system had been idle immediately *before* the current touch, or `nil` if unknown.
    ///
    /// It has to be the value from before the touch: a real finger on the Touch Bar resets
    /// `HIDIdleTime` about 67 ms before the contact reaches us (measured), so reading it here would
    /// always report ~0 and never identify a wake.
    var systemIdleBeforeTouch: (() -> Double?)?

    /// Idle seconds past which the strip is assumed dark, so the next touch only wakes it. `0` keeps
    /// every touch a gesture. macOS dims at roughly 75 s — measured wakes landed at 77.5 s idle.
    var wakeTouchIdleThreshold: Double = 70

    private var contacts: [Int32: Contact] = [:]
    private var session: Session?
    private var longPressTimer: DispatchSourceTimer?

    /// A completed single tap waiting to see whether a second one follows.
    private var pendingSingleTap: DispatchSourceTimer?

    /// Touch Bar width in millimetres, replaced with the digitiser's real dimensions when it opens
    /// (232.1 mm on this MacBook Pro); the default is only a fallback.
    var surfaceWidthMM = 232.0

    /// How many steps a full-width sweep is divided into — and therefore how finely the slide can set
    /// the volume, since one step is `1 / volumeSteps` of the range.
    ///
    /// 16 matches the granularity of the volume keys; the default of 32 is deliberately finer, because
    /// the strip is long enough to resolve it (7.3 mm of travel per step at 232 mm) and the keys are
    /// already there for coarse changes.
    var volumeSteps = 32

    /// Millimetres of travel per volume step, derived so that one sweep of the strip is exactly the
    /// full range whatever `volumeSteps` is. Deriving it from the measured surface width rather than
    /// hard-coding a distance also keeps it honest if the digitiser reports something unexpected.
    private var millimetresPerVolumeStep: Double {
        max(1.0, surfaceWidthMM / Double(max(1, volumeSteps)))
    }

    /// Travel beyond this commits the session to being a slide, cancelling every tap and the long press.
    private let slideCommitMM = 5.0

    /// A session shorter than this, that neither slid nor became a long press, is a tap.
    private let tapMaxDuration = 0.30

    /// How long a single tap waits for a possible second tap.
    private let doubleTapWindow = 0.32

    // MARK: - Input

    func handle(_ sample: TouchSample) {
        if sample.isDown {
            handleDown(sample)
        } else {
            handleUp(sample)
        }
    }

    private func handleDown(_ sample: TouchSample) {
        if var existing = contacts[sample.id] {
            existing.minX = min(existing.minX, sample.x)
            existing.maxX = max(existing.maxX, sample.x)
            let dxMM = (sample.x - existing.lastX) * surfaceWidthMM
            existing.lastX = sample.x

            let spreadMM = (existing.maxX - existing.minX) * surfaceWidthMM
            // Mutate a local copy and write it back; Swift forbids overlapping access to `session`
            // while a subscript or another mutation of it is in flight.
            var current = session ?? Session(startTime: sample.timestamp)
            current.maxSpreadMM = max(current.maxSpreadMM, spreadMM)

            // Volume only responds to a single finger; two fingers is a tap gesture, not a drag.
            // A wake touch is skipped entirely, so dragging a finger off the edge of a dark strip
            // cannot move the volume either.
            if contacts.count == 1, settings.slideVolume, !current.wakeOnly {
                existing.pendingMM += dxMM
                if spreadMM > slideCommitMM, !current.committedToSlide {
                    current.committedToSlide = true
                    cancelLongPressTimer()
                }
                if current.committedToSlide {
                    let steps = (existing.pendingMM / millimetresPerVolumeStep).rounded(.towardZero)
                    if steps != 0 {
                        existing.pendingMM -= steps * millimetresPerVolumeStep
                        onSlide?(steps)
                    }
                }
            }
            session = current
            contacts[sample.id] = existing
            return
        }

        // A new finger.
        contacts[sample.id] = Contact(id: sample.id, startTime: sample.timestamp,
                                      minX: sample.x, maxX: sample.x, lastX: sample.x, pendingMM: 0)
        let isNewSession = (session == nil)
        var current = session ?? newSession(startingAt: sample.timestamp)
        current.maxFingers = max(current.maxFingers, contacts.count)
        session = current
        if isNewSession {
            scheduleLongPressCheck()
        }
        // A second finger rules out the long press and any slide.
        if contacts.count > 1 {
            cancelLongPressTimer()
        }
    }

    /// Starts a session, deciding up front whether this touch is only waking a dark strip.
    private func newSession(startingAt time: TimeInterval) -> Session {
        var fresh = Session(startTime: time)
        guard wakeTouchIdleThreshold > 0, let idle = systemIdleBeforeTouch?() else { return fresh }
        if idle >= wakeTouchIdleThreshold {
            fresh.wakeOnly = true
            Log.info("touch", String(format: "strip was dark (%.0f s idle); this touch only wakes it",
                                     idle))
        }
        return fresh
    }

    private func handleUp(_ sample: TouchSample) {
        contacts.removeValue(forKey: sample.id)
        guard contacts.isEmpty, let finished = session else { return }
        session = nil
        cancelLongPressTimer()
        classify(finished, endedAt: sample.timestamp)
    }

    /// Decide what the just-finished session was.
    private func classify(_ session: Session, endedAt: TimeInterval) {
        guard !session.wakeOnly else {
            Log.debug("touch", "session ignored, it only woke the strip")
            return
        }
        guard !session.longPressFired, !session.committedToSlide else { return }
        guard session.maxSpreadMM <= settings.longPressMaxDrift else { return }
        let duration = endedAt - session.startTime
        guard duration >= 0, duration <= tapMaxDuration else { return }

        if session.maxFingers >= 2 {
            // Two fingers never participate in the double-tap window; it fires immediately.
            cancelPendingSingleTap()
            Log.info("touch", String(format: "two-finger tap (%.0f ms)", duration * 1000))
            onTwoFingerTap?()
            return
        }

        if pendingSingleTap != nil {
            cancelPendingSingleTap()
            Log.info("touch", "double tap")
            onDoubleTap?()
            return
        }

        // Hold the single tap until the double-tap window has passed.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + doubleTapWindow)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pendingSingleTap = nil
            Log.info("touch", String(format: "single tap (%.0f ms, %.1f mm)",
                                     duration * 1000, session.maxSpreadMM))
            self.onSingleTap?()
        }
        timer.resume()
        pendingSingleTap = timer
    }

    private func cancelPendingSingleTap() {
        pendingSingleTap?.cancel()
        pendingSingleTap = nil
    }

    /// A long press is decided on a timer rather than on movement events, because a perfectly still
    /// finger generates no movement to react to.
    private func scheduleLongPressCheck() {
        cancelLongPressTimer()
        guard settings.longPressStopsATB else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + settings.longPressDuration)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.longPressTimer = nil
            guard var current = self.session, self.contacts.count == 1 else { return }
            guard !current.wakeOnly else { return }
            guard !current.longPressFired, !current.committedToSlide else { return }
            guard current.maxSpreadMM <= self.settings.longPressMaxDrift else {
                Log.debug("touch", "long press rejected, finger moved "
                                 + String(format: "%.1f", current.maxSpreadMM) + " mm")
                return
            }
            current.longPressFired = true
            self.session = current
            Log.info("touch", "long press recognised (spread "
                            + String(format: "%.1f", current.maxSpreadMM) + " mm)")
            self.onLongPress?()
        }
        timer.resume()
        longPressTimer = timer
    }

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    func reset() {
        contacts.removeAll()
        session = nil
        cancelLongPressTimer()
        cancelPendingSingleTap()
    }
}

/// Reads raw contacts from the Touch Bar digitiser and feeds the recogniser.
final class TouchBarGestureReader {
    let recognizer = TouchBarGestureRecognizer()
    private var backend: TouchBarTouchSource?

    var onSingleTap: (() -> Void)? {
        get { recognizer.onSingleTap }
        set { recognizer.onSingleTap = newValue }
    }
    var onDoubleTap: (() -> Void)? {
        get { recognizer.onDoubleTap }
        set { recognizer.onDoubleTap = newValue }
    }
    var onTwoFingerTap: (() -> Void)? {
        get { recognizer.onTwoFingerTap }
        set { recognizer.onTwoFingerTap = newValue }
    }
    var onLongPress: (() -> Void)? {
        get { recognizer.onLongPress }
        set { recognizer.onLongPress = newValue }
    }

    init() {
        recognizer.onSlide = { [weak self] steps in
            self?.applyVolumeSlide(steps)
        }
    }

    /// `kIOHIDRequestTypeListenEvent` is the Input Monitoring right in Privacy & Security. Reading the
    /// Touch Bar through MultitouchSupport does not actually need it; this is only for diagnostics.
    static func hasInputMonitoringPermission() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoringPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        let settings = Settings.shared
        guard settings.longPressStopsATB || settings.slideVolume || settings.tapCyclesStyle else { return }
        if !Self.hasInputMonitoringPermission() {
            Log.debug("touch", "Input Monitoring is not granted; MultitouchSupport does not need it")
        }
        let source = MultitouchTouchBarSource()
        source.onTouch = { [weak self] sample in
            self?.recognizer.handle(sample)
        }
        if source.start() {
            backend = source
            if let width = source.surfaceWidthMM {
                recognizer.surfaceWidthMM = width
            }
            recognizer.volumeSteps = settings.volumeSteps
            recognizer.wakeTouchIdleThreshold = settings.wakeTouchIdleSeconds
            recognizer.systemIdleBeforeTouch = { [weak self] in self?.consumeRecentIdle() }
            if recognizer.wakeTouchIdleThreshold > 0 { startIdleSampling() }
            Log.info("touch", "Touch Bar gesture reader started (surface \(recognizer.surfaceWidthMM) mm wide, "
                            + "\(recognizer.volumeSteps) volume steps per sweep, wake-touch guard "
                            + (recognizer.wakeTouchIdleThreshold > 0
                               ? "at \(Int(recognizer.wakeTouchIdleThreshold)) s idle" : "off") + ")")
        } else {
            Log.warn("touch", "could not open the Touch Bar digitiser")
        }
    }

    func stop() {
        backend?.stop()
        backend = nil
        idleSampler?.cancel()
        idleSampler = nil
        recognizer.reset()
    }

    // MARK: - System idle sampling
    //
    // Needed because a finger on the Touch Bar resets `HIDIdleTime` ~67 ms before the contact reaches
    // us — measured: reset at 18:40:19.335, first contact 18:40:19.402 — so by the time a gesture
    // could ask, the evidence that the strip was dark is already gone. Sampling ahead of time keeps it.
    //
    // The samples are read as a *maximum over a short window* rather than "the previous sample":
    // idle climbs monotonically until something resets it, so the max over the last few seconds is the
    // pre-touch value whether or not a sample happened to land in the 67 ms gap. That removes the race
    // rather than making it unlikely.

    private var idleSampler: DispatchSourceTimer?
    private var idleSamples: [(at: Date, idle: Double)] = []
    private let idleSampleInterval = 2.0
    private let idleWindow = 6.0

    private func startIdleSampling() {
        idleSampler?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: idleSampleInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let idle = Self.systemIdleSeconds() else { return }
            let now = Date()
            self.idleSamples.append((at: now, idle: idle))
            self.idleSamples.removeAll { now.timeIntervalSince($0.at) > self.idleWindow }
        }
        timer.resume()
        idleSampler = timer
    }

    /// Longest idle seen in the recent window — the state the strip was in just before this touch.
    private func recentIdleSeconds() -> Double? {
        let cutoff = Date().addingTimeInterval(-idleWindow)
        return idleSamples.filter { $0.at >= cutoff }.map(\.idle).max()
    }

    /// The pre-touch idle, forgetting the history if it says the strip was dark.
    ///
    /// Without the reset the same high sample would sit in the window for its full length, so the
    /// *next* touch — the deliberate one the user makes once the strip is lit — would be read as
    /// another wake and swallowed too. Clearing here means exactly one touch is ever absorbed.
    private func consumeRecentIdle() -> Double? {
        let value = recentIdleSeconds()
        let threshold = recognizer.wakeTouchIdleThreshold
        if threshold > 0, let value, value >= threshold {
            idleSamples.removeAll()
        }
        return value
    }

    /// Seconds since the last keyboard, trackpad or Touch Bar input, from `IOHIDSystem`.
    static func systemIdleSeconds() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDSystem"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              let nanoseconds = dictionary["HIDIdleTime"] as? UInt64 else { return nil }
        return Double(nanoseconds) / 1_000_000_000
    }

    /// Make a one-finger slide change the volume.
    ///
    /// AVTouchBar's own version of this could not work while it was visualising, because it wrote the
    /// volume to the *default output device* — which by then was the aggregate it had installed, and an
    /// aggregate exposes no volume control. `VolumeController` resolves through to the real hardware.
    private func applyVolumeSlide(_ steps: Double) {
        // One step is 1/volumeSteps of the range, so this must track the recogniser's own divisor —
        // otherwise a full sweep would no longer land on exactly 0 % or 100 %.
        let delta = Float(steps / Double(max(1, recognizer.volumeSteps)))
        if let newVolume = VolumeController.adjustVolume(by: delta) {
            Log.debug("touch", "slide \(Int(steps)) step(s) -> volume \(String(format: "%.2f", newVolume))")
        } else {
            Log.warn("touch", "slide could not change the volume")
        }
    }
}

/// Anything that can deliver Touch Bar contacts.
protocol TouchBarTouchSource: AnyObject {
    var onTouch: ((TouchSample) -> Void)? { get set }
    /// Physical width of the surface in millimetres, known once `start()` has succeeded.
    var surfaceWidthMM: Double? { get }
    func start() -> Bool
    func stop()
}
