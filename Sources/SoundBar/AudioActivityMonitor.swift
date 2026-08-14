import Foundation
import CoreAudio

/// Watches CoreAudio and reports, event-driven, whether real audio is playing and whether a real
/// microphone is capturing.
///
/// Built on the per-process audio objects (`kAudioHardwarePropertyProcessObjectList`, macOS 14.4+),
/// which is what makes the two hard requirements possible:
///
///  * **Ignore system sounds.** Every alert, notification and UI sound on macOS is rendered by a
///    single helper, `systemsoundserverd`, which appears in the process list only for as long as the
///    sound lasts. Excluding that one process removes all of them exactly, with no duration
///    guessing. (Device-level detection cannot do this: the default output and the default *system*
///    output are the same device here, so alerts and music are indistinguishable at that level.)
///  * **Ignore AVTouchBar itself.** ATB captures the BlackHole loopback in order to visualise, so it
///    permanently reads as "microphone in use". Without excluding it, SoundBar would latch on and
///    never stop.
///
/// Two non-obvious behaviours of the API shape this class, both established by measurement:
///
///  1. Property listeners on `kAudioProcessPropertyIsRunningOutput` / `…IsRunningInput` **never
///     fire**. The events arrive on `kAudioProcessPropertyIsRunning` (output) and on
///     `kAudioProcessPropertyDevices` with input scope (input). Those are used as tripwires, and the
///     real flags are read afterwards — they are already correct by the time the tripwire fires.
///  2. Output must *not* be filtered by device, but input *must* be. An app playing only into
///     BlackHole (so that ATB can visualise it) is still real playback; whereas an app *capturing*
///     BlackHole is just loopback plumbing, not a microphone.
final class AudioActivityMonitor {

    /// Called on the main queue whenever the picture changes.
    var onChange: ((_ output: Bool, _ input: Bool) -> Void)?

    private let settings = Settings.shared
    private let queue = DispatchQueue.main

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    /// Retained so they can be handed back to `AudioObjectRemovePropertyListenerBlock`, which
    /// matches on block identity.
    private var systemListeners: [Listener] = []
    private var objectListeners: [Listener] = []

    /// Input devices that are actual microphones rather than loopback or aggregate plumbing.
    private var realMicDevices: Set<AudioObjectID> = []

    private var lastOutput = false
    private var lastInput = false

    // MARK: - Lifecycle

    func start() {
        observeSystem(kAudioHardwarePropertyProcessObjectList)
        observeSystem(kAudioHardwarePropertyDevices)
        rebuildRealMicDevices()
        rebuildObjectListeners()
        recompute(force: true)
        Log.info("audio", "monitor started; real microphones: \(realMicDevices.map { Self.name($0) ?? "?" })")
    }

    func stop() {
        for listener in systemListeners + objectListeners {
            var addr = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &addr, queue, listener.block)
        }
        systemListeners.removeAll()
        objectListeners.removeAll()
    }

    // MARK: - Observation wiring

    private func observeSystem(_ selector: AudioObjectPropertySelector) {
        guard let listener = makeListener(on: AudioObjectID(kAudioObjectSystemObject),
                                         selector: selector,
                                         scope: kAudioObjectPropertyScopeGlobal,
                                         handler: { [weak self] in
                                             guard let self else { return }
                                             Log.debug("audio", "system \(Self.fourCC(selector)) changed")
                                             if selector == kAudioHardwarePropertyDevices {
                                                 self.rebuildRealMicDevices()
                                             }
                                             self.rebuildObjectListeners()
                                             self.recompute(force: false)
                                         }) else { return }
        systemListeners.append(listener)
    }

    /// Reinstalls the per-process and per-device listeners. Called whenever the process list or the
    /// device list changes — audio object IDs are recycled, so stale registrations are dropped
    /// wholesale rather than diffed.
    private func rebuildObjectListeners() {
        for listener in objectListeners {
            var addr = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &addr, queue, listener.block)
        }
        objectListeners.removeAll()

        let handler: () -> Void = { [weak self] in self?.recompute(force: false) }

        for process in Self.processObjects() {
            // Output tripwire.
            if let l = makeListener(on: process, selector: kAudioProcessPropertyIsRunning,
                                    scope: kAudioObjectPropertyScopeGlobal, handler: handler) {
                objectListeners.append(l)
            }
            // Input tripwire. This is the only address that reports microphone start/stop.
            if let l = makeListener(on: process, selector: kAudioProcessPropertyDevices,
                                    scope: kAudioObjectPropertyScopeInput, handler: handler) {
                objectListeners.append(l)
            }
        }

        // Belt and braces: a real microphone starting also shows up here, and this catches the case
        // where a capture begins without the process list changing.
        for device in realMicDevices {
            if let l = makeListener(on: device, selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                    scope: kAudioObjectPropertyScopeGlobal, handler: handler) {
                objectListeners.append(l)
            }
        }
    }

    private func makeListener(on object: AudioObjectID,
                              selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope,
                              handler: @escaping () -> Void) -> Listener? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        guard status == noErr else {
            Log.debug("audio", "cannot observe \(Self.fourCC(selector)) on \(object): \(status)")
            return nil
        }
        return Listener(object: object, address: addr, block: block)
    }

    /// A device counts as a real microphone if it can capture and is not virtual (`virt`, e.g.
    /// BlackHole) or an aggregate (`grup`, e.g. the device AVTouchBar builds).
    private func rebuildRealMicDevices() {
        var mics: Set<AudioObjectID> = []
        let excludedNames = settings.excludedDeviceNames
        for device in Self.allDevices() {
            guard VolumeController.inputChannelCount(device) > 0 else { continue }
            let transport = VolumeController.transportType(device)
            guard transport != kAudioDeviceTransportTypeVirtual,
                  transport != kAudioDeviceTransportTypeAggregate else { continue }
            if let name = Self.name(device), excludedNames.contains(name) { continue }
            mics.insert(device)
        }
        if mics != realMicDevices {
            realMicDevices = mics
            Log.debug("audio", "real microphones: \(mics.map { Self.name($0) ?? "?" })")
        }
    }

    // MARK: - The predicate

    private func recompute(force: Bool) {
        let output = isOutputActive()
        let input = isInputActive()
        guard force || output != lastOutput || input != lastInput else { return }
        lastOutput = output
        lastInput = input
        onChange?(output, input)
    }

    /// Re-read from scratch, for the debounce timers to confirm an edge before acting on it.
    func snapshot() -> (output: Bool, input: Bool) {
        (isOutputActive(), isInputActive())
    }

    /// Real playback: any non-excluded process is running output. Deliberately not filtered by
    /// device — playing into the loopback still counts.
    private func isOutputActive() -> Bool {
        for process in Self.processObjects() {
            guard !isExcluded(process) else { continue }
            guard Self.flag(process, kAudioProcessPropertyIsRunningOutput) else { continue }
            return true
        }
        return false
    }

    /// A real microphone is capturing: some non-excluded process is running input *and* at least one
    /// of the devices it is capturing from is a real microphone.
    ///
    /// The device check is load-bearing. Both AVTouchBar and any other loopback consumer report
    /// `IsRunningInput`, so without it SoundBar would treat its own visualiser as a live microphone.
    private func isInputActive() -> Bool {
        guard !realMicDevices.isEmpty else { return false }
        for process in Self.processObjects() {
            guard !isExcluded(process) else { continue }
            guard Self.flag(process, kAudioProcessPropertyIsRunningInput) else { continue }
            let captured = Set(Self.processDevices(process, scope: kAudioObjectPropertyScopeInput))
            guard !captured.isDisjoint(with: realMicDevices) else { continue }
            Log.debug("audio", "microphone in use by \(Self.bundleID(process) ?? "pid \(Self.pid(process))")")
            return true
        }
        return false
    }

    private func isExcluded(_ process: AudioObjectID) -> Bool {
        let pid = Self.pid(process)
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        guard let bundle = Self.bundleID(process), !bundle.isEmpty else { return false }
        if settings.excludedBundleIDs.contains(bundle) { return true }
        if settings.ignoreSystemSounds, Self.systemSoundBundleIDs.contains(bundle) { return true }
        return false
    }

    /// Bundle identifiers currently counted as real playback, for the menu's diagnostic list.
    func currentOutputSources() -> [String] {
        var sources: [String] = []
        for process in Self.processObjects() {
            guard !isExcluded(process), Self.flag(process, kAudioProcessPropertyIsRunningOutput) else { continue }
            let label = Self.bundleID(process).flatMap { $0.isEmpty ? nil : $0 } ?? "pid \(Self.pid(process))"
            if !sources.contains(label) { sources.append(label) }
        }
        return sources
    }

    /// Every alert, notification and UI sound on macOS is rendered by `systemsoundserverd`, never by
    /// the process that asked for it. Measured on this machine:
    ///
    ///     0.09s OUT={com.apple.Music}
    ///     1.14s OUT={com.apple.Music, systemsoundserverd}   <- `beep`
    ///     1.42s OUT={com.apple.Music}
    static let systemSoundBundleIDs: Set<String> = [
        "systemsoundserverd",
        "com.apple.PowerChime",
    ]

    // MARK: - CoreAudio reads

    static func processObjects() -> [AudioObjectID] {
        objectIDs(AudioObjectID(kAudioObjectSystemObject),
                  kAudioHardwarePropertyProcessObjectList,
                  kAudioObjectPropertyScopeGlobal)
    }

    static func allDevices() -> [AudioObjectID] {
        objectIDs(AudioObjectID(kAudioObjectSystemObject),
                  kAudioHardwarePropertyDevices,
                  kAudioObjectPropertyScopeGlobal)
    }

    /// The devices a process is using, in the given scope.
    static func processDevices(_ process: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        objectIDs(process, kAudioProcessPropertyDevices, scope)
    }

    private static func objectIDs(_ object: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector,
                                 _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &addr) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func pid(_ process: AudioObjectID) -> Int32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(process, &addr) else { return -1 }
        var value: Int32 = -1
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }

    static func bundleID(_ process: AudioObjectID) -> String? {
        string(process, kAudioProcessPropertyBundleID)
    }

    static func name(_ device: AudioObjectID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}
