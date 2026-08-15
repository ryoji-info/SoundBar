import Foundation

/// Why the visualiser is (or was) wanted. Used for logging and the menu.
struct ActivityReason: Equatable, CustomStringConvertible {
    var output: Bool
    var input: Bool

    var isActive: Bool { output || input }

    var description: String {
        switch (output, input) {
        case (true, true): return "playback + microphone"
        case (true, false): return "playback"
        case (false, true): return "microphone"
        case (false, false): return "idle"
        }
    }
}

/// Decides when SoundBar's visualiser should be on the Touch Bar.
///
/// The audio monitor pushes raw state in; this class debounces it, applies the manual override, and
/// drives the visualiser, the audio tap and the BetterTouchTool hand-back check. Everything runs on
/// the main queue, so there is one serialisation point and no locking.
final class Coordinator {
    private let visualizer: TouchBarVisualizer
    private let tap: SystemAudioTap
    private let microphone: MicrophoneCapture
    private let btt: BTTController
    private let audio: AudioActivityMonitor
    private let settings = Settings.shared

    private var reason = ActivityReason(output: false, input: false)
    private var visualisingSince: Date?

    /// Start and stop are debounced separately: starting is quick so the visualiser feels responsive,
    /// stopping is lazy so gaps between tracks do not tear the Touch Bar down and rebuild it.
    private var startTimer: DispatchSourceTimer?
    private var stopTimer: DispatchSourceTimer?

    private var visualising = false

    /// Set when the user stops the visualiser by hand (Touch Bar long press, or the menu).
    ///
    /// Without it, a long press while music is still playing would stop the visualiser and then
    /// SoundBar would immediately restart it. Cleared as soon as audio genuinely goes idle, so the
    /// next track re-arms automatic behaviour.
    private var manualOverride = false

    /// Result of the most recent hand-back check, shown in the menu.
    private(set) var lastBTTState: BTTController.TouchBarState?

    init(visualizer: TouchBarVisualizer,
         tap: SystemAudioTap,
         microphone: MicrophoneCapture,
         btt: BTTController,
         audio: AudioActivityMonitor) {
        self.visualizer = visualizer
        self.tap = tap
        self.microphone = microphone
        self.btt = btt
        self.audio = audio

        applyBandCount()

        // The renderer pulls whichever source — or blend of sources — is live.
        visualizer.frameProvider = { [weak self] in
            self?.currentFrame() ?? emptyVisualFrameData
        }
    }

    var isVisualising: Bool { visualising }

    /// Whether microphone capture is usable, for the menu's permission hint.
    var microphoneAvailable: Bool { microphone.lastError == nil }
    var currentReason: ActivityReason { reason }
    var isOverridden: Bool { manualOverride }

    // MARK: - Level source

    /// The frame to draw, from whichever sources the current input mode wants.
    ///
    /// Both are gated on `isRunning` as well as the mode, so a source that failed to start (a denied
    /// microphone, say) contributes nothing rather than a flat line dragged into the blend.
    private func currentFrame() -> VisualFrameData {
        let mode = settings.inputMode
        let wantsInput = mode.usesInput(outputActive: reason.output) && microphone.isRunning
        let wantsOutput = mode.usesOutput(inputActive: reason.input) && tap.isRunning

        switch (wantsOutput, wantsInput) {
        case (true, true):
            return blend(frame(from: tap.analyzer),
                         amplify(frame(from: microphone.analyzer), by: Float(settings.inputGain)))
        case (false, true):
            return amplify(frame(from: microphone.analyzer), by: Float(settings.inputGain))
        default:
            return frame(from: tap.analyzer)
        }
    }

    /// Whether an activity picture contains anything the current mode would actually draw.
    ///
    /// Not the same as "audio is happening": with the input meter `off`, a recording app with no
    /// playback is active but has no drawable source, and presenting then would take the Touch Bar
    /// away from BetterTouchTool to show a dead black strip for the whole recording.
    private func hasDrawableSource(output: Bool, input: Bool) -> Bool {
        let mode = settings.inputMode
        return (output && mode.usesOutput(inputActive: input))
            || (input && mode.usesInput(outputActive: output))
    }

    private func frame(from analyzer: SpectrumAnalyzer) -> VisualFrameData {
        (levels: analyzer.levels(),
         waveform: analyzer.waveform(count: 220),
         vu: analyzer.vuLevels())
    }

    /// Scales a frame's levels, for `inputGain`. A no-op at 1.0.
    private func amplify(_ f: VisualFrameData, by gain: Float) -> VisualFrameData {
        guard gain != 1 else { return f }
        func clamp(_ v: Float) -> Float { min(1, max(0, v * gain)) }
        return (levels: f.levels.map(clamp),
                waveform: f.waveform.map { min(1, max(-1, $0 * gain)) },
                vu: (left: clamp(f.vu.left), right: clamp(f.vu.right),
                     peakLeft: clamp(f.vu.peakLeft), peakRight: clamp(f.vu.peakRight)))
    }

    /// Combines two frames into one display.
    ///
    /// Spectrum bands and meter levels take the *louder* of the two rather than a sum: both are
    /// already normalised 0...1, so adding them would peg the display any time both sources were
    /// merely present. The waveform is genuinely summed, because that is what mixing two signals
    /// does, then clamped.
    private func blend(_ a: VisualFrameData, _ b: VisualFrameData) -> VisualFrameData {
        func louder(_ x: [Float], _ y: [Float]) -> [Float] {
            let count = max(x.count, y.count)
            guard count > 0 else { return [] }
            return (0..<count).map { i in
                max(i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            }
        }
        let waveCount = max(a.waveform.count, b.waveform.count)
        let waveform = waveCount == 0 ? [] : (0..<waveCount).map { i -> Float in
            let x = i < a.waveform.count ? a.waveform[i] : 0
            let y = i < b.waveform.count ? b.waveform[i] : 0
            return min(1, max(-1, x + y))
        }
        return (levels: louder(a.levels, b.levels),
                waveform: waveform,
                vu: (left: max(a.vu.left, b.vu.left),
                     right: max(a.vu.right, b.vu.right),
                     peakLeft: max(a.vu.peakLeft, b.vu.peakLeft),
                     peakRight: max(a.vu.peakRight, b.vu.peakRight)))
    }

    // MARK: - Input from the audio monitor

    func updateActivity(output: Bool, input: Bool) {
        let new = ActivityReason(output: output && settings.watchOutput,
                                 input: input && settings.watchInput)
        guard new != reason else { return }
        let old = reason
        reason = new
        Log.info("coordinator", "activity \(old) -> \(new)")
        // Only re-sync while there is still something to draw. On the way to idle the captures are
        // deliberately left running so the analyser keeps receiving real silence and the bars decay
        // over the stop debounce — stopping here instead would reset them and blank the strip for
        // three seconds after every pause, and rebuild the whole tap if playback resumed.
        if visualising, hasDrawableSource(output: new.output, input: new.input) {
            syncCaptureSources()
        }
        evaluate()
    }

    // MARK: - Touch Bar gestures

    /// Long press: stop the visualiser and stand down until audio restarts.
    func handleLongPress() {
        guard settings.longPressStopsATB else { return }
        guard visualising else {
            Log.debug("coordinator", "long press ignored, not visualising")
            return
        }
        Log.info("coordinator", "long press -> stopping visualiser (manual override armed)")
        manualOverride = true
        cancelTimers()
        stopNow()
    }

    /// Choose a specific pattern (from the menu, or by two-finger tap).
    func setStyle(_ style: VisualStyle) {
        visualizer.style = style
        settings.style = style
        applyBandCount()
        Log.info("coordinator", "visual style set to '\(style.displayName)'")
    }

    /// The ×2 patterns want twice as many analysis bands, so the band count follows the pattern
    /// rather than being fixed. Both analysers are kept in step, since either can be the live one.
    private func applyBandCount() {
        let count = settings.barCount * visualizer.style.bandMultiplier
        tap.analyzer.setBarCount(count)
        microphone.analyzer.setBarCount(count)
        let tilt = Float(settings.frequencyTilt)
        tap.analyzer.tiltDBPerOctave = tilt
        microphone.analyzer.tiltDBPerOctave = tilt
        let boost = Float(settings.levelBoost)
        tap.analyzer.levelBoostDB = boost
        microphone.analyzer.levelBoostDB = boost
        Log.debug("coordinator", "analysis bands: \(count) for '\(visualizer.style.displayName)'")
    }

    /// One-finger tap: next colour ramp.
    func handleSingleTap() {
        guard settings.tapCyclesStyle else { return }
        let names = PaletteLibrary.names
        guard !names.isEmpty else { return }
        let current = names.firstIndex { $0.caseInsensitiveCompare(settings.paletteName) == .orderedSame } ?? -1
        let next = names[(current + 1) % names.count]
        settings.defaults.set(next, forKey: Settings.Key.paletteName)
        Log.info("coordinator", "single tap -> colour '\(next)'")
    }

    /// Two-finger tap: next visual pattern. Works whether or not the visualiser is currently up, so the
    /// choice can be changed and then seen on the next track.
    func handleTwoFingerTap() {
        guard settings.tapCyclesStyle else { return }
        setStyle(visualizer.style.next)
    }

    /// Double tap: mute or unmute the output.
    func handleDoubleTap() {
        guard settings.doubleTapMutes else { return }
        let muted = VolumeController.toggleMute()
        Log.info("coordinator", "double tap -> \(muted ? "muted" : "unmuted")")
    }

    /// Turn SoundBar's automatic behaviour on or off, from the menu.
    func setEnabled(_ enabled: Bool) {
        settings.defaults.set(enabled, forKey: Settings.Key.enabled)
        if enabled {
            // Clear a long-press override so switching back on takes effect straight away.
            manualOverride = false
        }
        Log.info("coordinator", "SoundBar \(enabled ? "enabled" : "disabled")")
        evaluate()
    }

    // MARK: - Menu

    func toggleManually() {
        if visualising {
            manualOverride = true
            cancelTimers()
            stopNow()
        } else {
            manualOverride = false
            cancelTimers()
            startNow()
        }
    }

    func settingsChanged() {
        Log.debug("coordinator", "settings changed, re-evaluating")
        applyBandCount()
        // Picking a different input mode has to take effect on the strip immediately, not at the
        // next track change. The drawable check is the same guard `updateActivity` uses: between the
        // idle edge and `stopDelay` expiring we are still visualising but `reason` is already empty,
        // and syncing there would tear the tap down mid-fade.
        if visualising, hasDrawableSource(output: reason.output, input: reason.input) {
            syncCaptureSources()
        }
        // Toggling "Keep Touch Bar Awake" has to reach the strip now rather than at the next
        // present, so that unchecking it really does stop the ticker.
        visualizer.refreshKeepAwake()
        evaluate()
    }

    /// At launch, make sure nothing is left on the Touch Bar from a previous run.
    func reconcileAtStartup() {
        guard !hasDrawableSource(output: reason.output, input: reason.input),
              visualizer.isPresenting else { return }
        Log.info("coordinator", "idle at startup but still presenting; standing down")
        stopNow()
    }

    // MARK: - Decision

    private func evaluate() {
        guard settings.enabled else {
            if visualising { cancelTimers(); stopNow() }
            return
        }

        if hasDrawableSource(output: reason.output, input: reason.input) {
            cancelStopTimer()
            guard !manualOverride else {
                Log.debug("coordinator", "audio active but manual override is armed")
                return
            }
            guard !visualising, startTimer == nil else { return }
            startTimer = schedule(after: settings.startDelay) { [weak self] in
                guard let self else { return }
                self.startTimer = nil
                // Re-read CoreAudio rather than trusting the edge that scheduled this: the audio may
                // have stopped again during the debounce, and property listeners are not ordered.
                let now = self.audio.snapshot()
                guard self.hasDrawableSource(output: now.output, input: now.input) else {
                    Log.debug("coordinator", "start cancelled, nothing to draw at fire time")
                    return
                }
                self.startNow()
            }
        } else {
            if manualOverride {
                Log.debug("coordinator", "audio idle, clearing manual override")
                manualOverride = false
            }
            cancelStartTimer()
            guard visualising, stopTimer == nil else { return }
            // Honour the minimum on-time so a brief sound cannot make the Touch Bar flash.
            let elapsed = visualisingSince.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let delay = max(settings.stopDelay, settings.minOnDuration - elapsed)
            stopTimer = schedule(after: delay) { [weak self] in
                guard let self else { return }
                self.stopTimer = nil
                let now = self.audio.snapshot()
                guard !self.hasDrawableSource(output: now.output, input: now.input) else {
                    Log.debug("coordinator", "stop cancelled, audio active again at fire time")
                    return
                }
                self.stopNow()
            }
        }
    }

    private func startNow() {
        guard !visualising else { return }
        Log.info("coordinator", "starting visualiser (\(reason), fullscreen=\(settings.fullscreen))")

        syncCaptureSources()

        guard visualizer.present(fullscreen: settings.fullscreen) else {
            Log.error("coordinator", "could not present on the Touch Bar; standing down")
            stopCaptureSources()
            return
        }
        visualising = true
        visualisingSince = Date()
    }

    private func stopNow() {
        guard visualising || visualizer.isPresenting else { return }
        visualising = false
        visualisingSince = nil
        Log.info("coordinator", "stopping visualiser")

        visualizer.dismiss()
        stopCaptureSources()

        guard settings.checkBTTAfterStop else { return }
        // Requirement 3: having released the strip, confirm BetterTouchTool actually gets it back.
        btt.waitForTouchBarHandback { [weak self] state in
            if state.isHealthy {
                Log.info("btt", "Touch Bar handed back: \(state)")
            } else {
                Log.warn("btt", "Touch Bar not handed back: \(state)")
            }
            self?.lastBTTState = state
        }
    }

    // MARK: - Capture

    /// Only run the capture that is actually needed: the system tap for playback, the microphone only
    /// when a microphone is the reason we are up. Keeps the idle and common cases cheap.
    /// Runs exactly the captures the current mode needs, and stops the ones it does not.
    private func syncCaptureSources() {
        let mode = settings.inputMode
        var wantOutput = reason.output && mode.usesOutput(inputActive: reason.input)
        let wantInput = reason.input && mode.usesInput(outputActive: reason.output)

        if wantInput {
            if !microphone.isRunning { microphone.start() }
        } else if microphone.isRunning {
            microphone.stop()
        }

        // If the microphone was wanted but could not start, fall back to the output so the strip is
        // not a flat line — even in a mode that would normally have handed the display to the mic.
        if wantInput, !microphone.isRunning, reason.output {
            wantOutput = true
        }

        if wantOutput {
            if !tap.isRunning { tap.start() }
        } else if tap.isRunning {
            tap.stop()
        }
    }

    private func stopCaptureSources() {
        tap.stop()
        microphone.stop()
    }

    // MARK: - Timers

    private func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, seconds))
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }

    private func cancelTimers() {
        cancelStartTimer()
        cancelStopTimer()
    }

    private func cancelStartTimer() {
        startTimer?.cancel()
        startTimer = nil
    }

    private func cancelStopTimer() {
        stopTimer?.cancel()
        stopTimer = nil
    }
}
