import Foundation
import CoreAudio

/// Sets the system output volume, working around the reason AVTouchBar needs a slide gesture at all.
///
/// AVTouchBar builds an aggregate output device when it visualises system audio. Aggregate devices
/// expose no master volume control, which is why the F11/F12 keys and the menu bar slider go dead
/// while ATB is running — and why ATB ships its own slide-to-change-volume gesture.
///
/// So writing the volume to "the default output device" is exactly the thing that does not work.
/// Instead we resolve the aggregate down to the real hardware sub-device (skipping the loopback
/// device, which is only there to feed ATB) and set the volume on that.
enum VolumeController {

    // MARK: - Public API

    /// Current output volume in 0...1, or nil if no controllable device could be found.
    static func currentVolume() -> Float? {
        guard let device = controllableOutputDevice() else { return nil }
        return volume(of: device)
    }

    /// Set the output volume, clamped to 0...1. Returns true if the write succeeded.
    @discardableResult
    static func setVolume(_ value: Float) -> Bool {
        guard let device = controllableOutputDevice() else {
            Log.warn("volume", "no controllable output device found")
            return false
        }
        let clamped = min(max(value, 0), 1)

        // Raising the volume from zero while muted would otherwise be silent.
        if clamped > 0 { setMuted(false, on: device) }

        if setVolume(clamped, on: device) {
            Log.debug("volume", "set volume \(String(format: "%.3f", clamped)) on device \(name(of: device) ?? "?")")
            return true
        }
        Log.warn("volume", "failed to set volume on device \(name(of: device) ?? "?")")
        return false
    }

    /// Nudge the volume by a delta in 0...1 units. Returns the new volume, if known.
    @discardableResult
    static func adjustVolume(by delta: Float) -> Float? {
        guard let current = currentVolume() else { return nil }
        let target = min(max(current + delta, 0), 1)
        guard setVolume(target) else { return nil }
        return target
    }

    /// Toggle mute on the device that actually has a mute control, returning the new state.
    ///
    /// Some devices expose no mute property at all; there the volume is driven to zero instead and
    /// restored on the way back, so a double tap still does something useful.
    @discardableResult
    static func toggleMute() -> Bool {
        guard let device = controllableOutputDevice() else { return false }
        if deviceHasMute(device) {
            let muted = !isMuted(device)
            setMuted(muted, on: device)
            Log.info("volume", "mute -> \(muted) on \(name(of: device) ?? "?")")
            return muted
        }
        // Fall back to volume: remember what it was so unmuting can restore it.
        if let current = volume(of: device), current > 0.001 {
            volumeBeforeMute = current
            _ = setVolume(0, on: device)
            Log.info("volume", "no mute control; volume driven to 0 (was \(current))")
            return true
        }
        let restored = volumeBeforeMute ?? 0.35
        volumeBeforeMute = nil
        _ = setVolume(restored, on: device)
        Log.info("volume", "restored volume to \(restored)")
        return false
    }

    /// Volume to come back to when unmuting a device that has no mute control.
    private static var volumeBeforeMute: Float?

    private static func deviceHasMute(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    /// Whether the output is currently muted, for the menu.
    static func isOutputMuted() -> Bool {
        guard let device = controllableOutputDevice() else { return false }
        if deviceHasMute(device) { return isMuted(device) }
        return (volume(of: device) ?? 1) < 0.001
    }

    // MARK: - Device resolution

    /// The device whose volume we should actually write to.
    ///
    /// Normally the default output device. If that is an aggregate (ATB's doing), we descend into
    /// its sub-devices and pick the first one that has a real, settable volume control and is not
    /// a loopback/virtual device.
    static func controllableOutputDevice() -> AudioObjectID? {
        guard let defaultOutput = defaultOutputDevice() else { return nil }

        if hasSettableVolume(defaultOutput) {
            return defaultOutput
        }

        // No master volume: either an aggregate, or a device that only exposes per-channel controls
        // we could not write. Try the sub-devices.
        let subs = subDevices(of: defaultOutput)
        if !subs.isEmpty {
            let excluded = Settings.shared.excludedDeviceNames
            // Prefer a real output device that is not the loopback plumbing.
            for sub in subs {
                guard let n = name(of: sub) else { continue }
                if excluded.contains(n) { continue }
                if hasSettableVolume(sub) { return sub }
            }
            // Nothing pristine; accept any sub-device with a volume control.
            for sub in subs where hasSettableVolume(sub) { return sub }
        }

        // Last resort: the built-in output, which always has a volume control.
        if let builtIn = builtInOutputDevice(), hasSettableVolume(builtIn) {
            return builtIn
        }
        return defaultOutput
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return id
    }

    /// Walks all devices looking for the built-in speakers, used as a fallback.
    private static func builtInOutputDevice() -> AudioObjectID? {
        for device in allDevices() {
            guard outputChannelCount(device) > 0 else { continue }
            if transportType(device) == kAudioDeviceTransportTypeBuiltIn { return device }
        }
        return nil
    }

    private static func allDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func subDevices(of device: AudioObjectID) -> [AudioObjectID] {
        for selector in [kAudioAggregateDevicePropertyFullSubDeviceList,
                         kAudioAggregateDevicePropertyActiveSubDeviceList] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { continue }

            if selector == kAudioAggregateDevicePropertyActiveSubDeviceList {
                let count = Int(size) / MemoryLayout<AudioObjectID>.size
                var ids = [AudioObjectID](repeating: 0, count: count)
                if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ids) == noErr {
                    return ids
                }
            } else {
                // FullSubDeviceList is a CFArray of device UID strings.
                var array: CFArray? = nil
                let status = withUnsafeMutablePointer(to: &array) { ptr -> OSStatus in
                    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
                }
                if status == noErr, let uids = array as? [String] {
                    let resolved = uids.compactMap { VolumeController.device(forUID: $0) }
                    if !resolved.isEmpty { return resolved }
                }
            }
        }
        return []
    }

    private static func device(forUID uid: String) -> AudioObjectID? {
        for device in allDevices() where self.uid(of: device) == uid { return device }
        return nil
    }

    // MARK: - Volume primitives

    /// Channels to try, in order: the main element (master control), then the preferred stereo pair,
    /// then channels 1 and 2. Devices differ in which of these actually exist.
    private static func candidateChannels(for device: AudioObjectID) -> [UInt32] {
        var channels: [UInt32] = [kAudioObjectPropertyElementMain]
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var pair: (UInt32, UInt32) = (1, 2)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        if AudioObjectHasProperty(device, &addr),
           AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &pair) == noErr {
            channels.append(pair.0)
            channels.append(pair.1)
        } else {
            channels.append(1)
            channels.append(2)
        }
        return channels
    }

    private static func hasSettableVolume(_ device: AudioObjectID) -> Bool {
        for channel in candidateChannels(for: device) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    private static func volume(of device: AudioObjectID) -> Float? {
        for channel in candidateChannels(for: device) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return Float(value)
            }
        }
        return nil
    }

    /// Writes the volume to every channel that accepts it, so stereo devices stay balanced.
    private static func setVolume(_ value: Float, on device: AudioObjectID) -> Bool {
        var wroteAny = false
        for channel in candidateChannels(for: device) {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel)
            guard AudioObjectHasProperty(device, &addr) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { continue }
            var v = Float32(value)
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(device, &addr, 0, nil, size, &v) == noErr {
                wroteAny = true
                // The main element is a master control; writing it is enough.
                if channel == kAudioObjectPropertyElementMain { break }
            }
        }
        return wroteAny
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func setMuted(_ muted: Bool, on device: AudioObjectID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value)
    }

    // MARK: - Device introspection helpers

    static func name(of device: AudioObjectID) -> String? {
        stringProperty(device, kAudioObjectPropertyName)
    }

    static func uid(of device: AudioObjectID) -> String? {
        stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    static func transportType(_ device: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return 0 }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func outputChannelCount(_ device: AudioObjectID) -> Int {
        channelCount(device, scope: kAudioDevicePropertyScopeOutput)
    }

    static func inputChannelCount(_ device: AudioObjectID) -> Int {
        channelCount(device, scope: kAudioDevicePropertyScopeInput)
    }

    private static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return 0 }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var total = 0
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for buffer in buffers { total += Int(buffer.mNumberChannels) }
        return total
    }
}
