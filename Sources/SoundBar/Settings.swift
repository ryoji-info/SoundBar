import CoreGraphics
import Foundation

/// How a live microphone is reflected on the strip.
///
/// The distinction matters because a call app holds an *output* stream open the whole time — so on a
/// Zoom call both input and output read as active, and "show the mic only when nothing is playing"
/// never fires. These modes decide what happens when both are live at once.
enum InputMode: String, CaseIterable {
    /// Never show the microphone; always the system output.
    case off
    /// Microphone only when nothing is playing to the output.
    case auto
    /// Blend the two whenever both are live.
    case mix
    /// Microphone wins whenever it is live, even over playback.
    case input

    var displayName: String {
        switch self {
        case .off: return "Off (output only)"
        case .auto: return "Only When Nothing Is Playing"
        case .mix: return "Mix Input and Output"
        case .input: return "Input Takes Priority"
        }
    }

    /// Whether the microphone should be captured and drawn, given what the output is doing.
    func usesInput(outputActive: Bool) -> Bool {
        switch self {
        case .off: return false
        case .auto: return !outputActive
        case .mix, .input: return true
        }
    }

    /// Whether the output tap should be captured and drawn, given what the input is doing.
    func usesOutput(inputActive: Bool) -> Bool {
        switch self {
        case .off, .auto, .mix: return true
        case .input: return !inputActive
        }
    }
}

/// Every tunable lives in `com.ryoji.SoundBar` so the user can adjust SoundBar without a rebuild:
///
///     defaults write com.ryoji.SoundBar stopDelay -float 5
///     defaults write com.ryoji.SoundBar verboseLogging -bool YES
///
/// SoundBar re-reads these whenever the defaults change, so most edits take effect immediately.
final class Settings {
    static let shared = Settings()

    /// `UserDefaults.standard` already reads and writes the `com.ryoji.SoundBar` domain, because that
    /// is SoundBar's own bundle identifier — so `defaults write com.ryoji.SoundBar …` lands here.
    /// (Passing the app's own identifier as a *suite* name is explicitly unsupported.)
    let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.watchOutput: true,
            Key.watchInput: true,
            Key.fullscreen: true,
            Key.startDelay: 0.7,
            Key.stopDelay: 3.0,
            Key.minOnDuration: 2.0,
            Key.ignoreSystemSounds: true,
            Key.longPressStopsATB: true,
            Key.longPressDuration: 0.45,
            Key.longPressMaxDrift: 4.0,
            Key.slideVolume: true,
            Key.checkBTTAfterStop: true,
            Key.verboseLogging: false,
            Key.barCount: 44,
            Key.barWidthFraction: 0.62,
            Key.fineBarWidthFraction: 0.88,
            Key.paletteName: "Rainbow",
            Key.style: "bars",
            Key.tapCyclesStyle: true,
            Key.doubleTapMutes: true,
            Key.keepTouchBarAwake: false,
            Key.frequencyTilt: 0.0,
            Key.frameRate: 20.0,
            Key.usableWidth: 1000.0,
            Key.showMenuBarItem: true,
            Key.inputMode: InputMode.mix.rawValue,
            Key.inputGain: 1.0,
        ])
        Log.verbose = verboseLogging
    }

    enum Key {
        static let enabled = "enabled"
        static let watchOutput = "watchOutput"
        static let watchInput = "watchInput"
        static let fullscreen = "fullscreen"
        static let startDelay = "startDelay"
        static let stopDelay = "stopDelay"
        static let minOnDuration = "minOnDuration"
        static let ignoreSystemSounds = "ignoreSystemSounds"
        static let longPressStopsATB = "longPressStopsATB"
        static let longPressDuration = "longPressDuration"
        static let longPressMaxDrift = "longPressMaxDrift"
        static let slideVolume = "slideVolume"
        static let checkBTTAfterStop = "checkBTTAfterStop"
        static let verboseLogging = "verboseLogging"
        static let extraExcludedBundleIDs = "extraExcludedBundleIDs"
        static let extraExcludedDeviceNames = "extraExcludedDeviceNames"
        static let barCount = "barCount"
        static let barWidthFraction = "barWidthFraction"
        static let fineBarWidthFraction = "fineBarWidthFraction"
        static let paletteName = "paletteName"
        static let style = "style"
        static let tapCyclesStyle = "tapCyclesStyle"
        static let doubleTapMutes = "doubleTapMutes"
        static let keepTouchBarAwake = "keepTouchBarAwake"
        static let frequencyTilt = "frequencyTilt"
        static let frameRate = "frameRate"
        static let usableWidth = "usableWidth"
        static let showMenuBarItem = "showMenuBarItem"
        static let visualiseMicrophone = "visualiseMicrophone"
        static let inputMode = "inputMode"
        static let inputGain = "inputGain"
    }

    /// Master switch; when false SoundBar stays running but does nothing.
    var enabled: Bool { defaults.bool(forKey: Key.enabled) }
    var watchOutput: Bool { defaults.bool(forKey: Key.watchOutput) }
    var watchInput: Bool { defaults.bool(forKey: Key.watchInput) }
    var fullscreen: Bool { defaults.bool(forKey: Key.fullscreen) }

    /// Wait this long after audio appears before starting ATB, so a 100 ms notification blip
    /// does not flash the visualiser onto the Touch Bar.
    var startDelay: TimeInterval { defaults.double(forKey: Key.startDelay) }

    /// Wait this long after audio disappears before stopping ATB, so gaps between tracks,
    /// seeking, and buffer underruns do not tear the Touch Bar down and rebuild it.
    var stopDelay: TimeInterval { defaults.double(forKey: Key.stopDelay) }

    /// Once the visualiser is up, keep it up at least this long. Prevents a one-second sound from
    /// making the Touch Bar flash the visualiser and immediately tear it down again.
    var minOnDuration: TimeInterval { defaults.double(forKey: Key.minOnDuration) }

    var ignoreSystemSounds: Bool { defaults.bool(forKey: Key.ignoreSystemSounds) }
    /// Long press on the Touch Bar stops the visualiser. The key keeps its original name so an
    /// existing `defaults write` still applies after the AVTouchBar-driving version.
    var longPressStopsATB: Bool { defaults.bool(forKey: Key.longPressStopsATB) }
    var longPressDuration: TimeInterval { defaults.double(forKey: Key.longPressDuration) }

    /// Maximum sideways movement, in millimetres, still counted as a stationary long press.
    /// Measured: a deliberate press jitters under 4 mm, while a slide clears it immediately.
    var longPressMaxDrift: Double { defaults.double(forKey: Key.longPressMaxDrift) }

    var slideVolume: Bool { defaults.bool(forKey: Key.slideVolume) }
    var checkBTTAfterStop: Bool { defaults.bool(forKey: Key.checkBTTAfterStop) }

    var verboseLogging: Bool { defaults.bool(forKey: Key.verboseLogging) }

    // MARK: - Appearance

    /// Number of bars across the strip. 44 across 1085 pt is ~24 pt per bar, which reads well.
    var barCount: Int { max(4, min(160, defaults.integer(forKey: Key.barCount))) }

    /// Fraction of each bar's slot that is filled, i.e. bar width versus gap.
    var barWidthFraction: Double { min(1.0, max(0.1, defaults.double(forKey: Key.barWidthFraction))) }

    /// Slot fill for the ×2 patterns. At 88 bands across ~1000 pt each slot is only 11 pt, so the gap
    /// has to be a much smaller fraction of it to stay a gap rather than most of the bar.
    var fineBarWidthFraction: Double {
        min(1.0, max(0.1, defaults.double(forKey: Key.fineBarWidthFraction)))
    }

    /// Passed through `PaletteLibrary.canonicalName` so a name saved before a palette was renamed
    /// (e.g. "Cyberpunk 2077" -> "Cyberpunk") still resolves to the right palette instead of silently
    /// falling back to the first built-in.
    var paletteName: String { PaletteLibrary.canonicalName(defaults.string(forKey: Key.paletteName) ?? "Rainbow") }

    /// Which visual pattern is showing. Changed by tapping the Touch Bar, and persisted so it
    /// survives a restart.
    var style: VisualStyle {
        get { VisualStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .bars }
        set { defaults.set(newValue.rawValue, forKey: Key.style) }
    }

    /// Touch Bar taps change the colour (one finger) and the pattern (two fingers).
    var tapCyclesStyle: Bool { defaults.bool(forKey: Key.tapCyclesStyle) }

    /// A one-finger double tap mutes and unmutes the output.
    var doubleTapMutes: Bool { defaults.bool(forKey: Key.doubleTapMutes) }

    /// Attempt to keep the Touch Bar from idle-dimming while visualising.
    ///
    /// Off by default because it does not currently work: macOS dims the strip on *input* idle and
    /// ignores synthetic activity from a background agent (see the keep-awake note in
    /// TouchBarVisualizer for the full set of approaches tried). Left as a switch so it takes effect
    /// with no rebuild if a future OS honours the attempt; it has no side effects when it fails.
    var keepTouchBarAwake: Bool { defaults.bool(forKey: Key.keepTouchBarAwake) }

    /// Spectral tilt in dB per octave, pivoting at 1 kHz, applied before a band becomes a bar height.
    ///
    /// `0` (the default) shows the spectrum as measured, which leans left because music carries most
    /// of its energy in the bass. `+6` is `level × frequency` — each doubling of frequency doubles the
    /// amplitude — and makes the treble end genuinely active. Clamped to ±12, beyond which the display
    /// is all floor or all ceiling.
    var frequencyTilt: Double { min(12, max(-12, defaults.double(forKey: Key.frequencyTilt))) }

    /// Redraw rate while visualising.
    ///
    /// Measured cost on this machine: 30 fps ≈ 4.9 % CPU, 20 fps ≈ 2.7 %, 12 fps ≈ 2.1 %. The cost is
    /// per-frame in AppKit's redisplay path rather than in the drawing itself (halving the backing
    /// scale changed nothing), so frame rate is the only real lever. 20 looks smooth on a 30 pt strip.
    var frameRate: Double { min(60, max(10, defaults.double(forKey: Key.frameRate))) }

    /// How much of the Touch Bar is actually visible, in points.
    ///
    /// AppKit hands the item a 1085 pt view — the full 2170 x 60 px panel at 2x — and reports that
    /// width back, but the strip only shows about the first 1005 pt of it. Anything drawn past that is
    /// invisible.
    ///
    /// Measured with `--ruler`: the "1000" label starts at x = 1002, and only the left half of its
    /// first digit is visible, which puts the edge at roughly 1005. 1000 is the round number safely
    /// inside that.
    var usableWidth: CGFloat {
        let value = defaults.double(forKey: Key.usableWidth)
        return value > 100 ? CGFloat(value) : 1000
    }

    /// The menu bar item carries the pattern and colour pickers and the on/off switch.
    var showMenuBarItem: Bool { defaults.bool(forKey: Key.showMenuBarItem) }

    /// How a live microphone is reflected on the strip.
    ///
    /// Supersedes the old `visualiseMicrophone` boolean: if that was explicitly turned off before this
    /// setting existed, it still wins and resolves to `.off`, so an existing preference is not
    /// silently reversed by the upgrade.
    var inputMode: InputMode {
        if defaults.object(forKey: Key.visualiseMicrophone) != nil,
           !defaults.bool(forKey: Key.visualiseMicrophone) {
            return .off
        }
        return InputMode(rawValue: defaults.string(forKey: Key.inputMode) ?? "") ?? .mix
    }

    func setInputMode(_ mode: InputMode) {
        defaults.set(mode.rawValue, forKey: Key.inputMode)
        // Clear the superseded boolean so it cannot keep forcing `.off`.
        defaults.removeObject(forKey: Key.visualiseMicrophone)
    }

    /// Multiplies the microphone's contribution before it is mixed or drawn.
    ///
    /// A voice at a normal distance sits well below music in level, so in `mix` it can read as a
    /// sliver next to playback. This is the knob to even that up; 1.0 leaves it untouched.
    var inputGain: Double { min(8.0, max(0.1, defaults.double(forKey: Key.inputGain))) }

    /// Audio coming from these bundle identifiers never counts as "something is playing".
    ///
    /// AVTouchBar stays on the list even though SoundBar no longer uses it: if it is ever launched by
    /// hand it captures the loopback device, which would otherwise read as permanent activity.
    var excludedBundleIDs: Set<String> {
        var ids: Set<String> = [
            "com.jakefishman.TouchBarVisualizer", // AVTouchBar, if the user still has it
            "com.ryoji.SoundBar",                 // ourselves
        ]
        if let extra = defaults.array(forKey: Key.extraExcludedBundleIDs) as? [String] {
            ids.formUnion(extra)
        }
        return ids
    }

    /// Loopback / aggregate plumbing that exists only so ATB can see audio. Activity on these
    /// devices is never treated as real playback or real microphone use.
    var excludedDeviceNames: Set<String> {
        var names: Set<String> = [
            "BlackHole 2ch",
            "AVTouchBar",
            "AVTouchBar Aggregate Device",
            "Soundflower (2ch)",
        ]
        if let extra = defaults.array(forKey: Key.extraExcludedDeviceNames) as? [String] {
            names.formUnion(extra)
        }
        return names
    }

    /// Observe external `defaults write` edits so tuning does not require a restart.
    func onChange(_ handler: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { _ in
            Log.verbose = self.verboseLogging
            handler()
        }
    }
}
