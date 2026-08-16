import CoreAudio
import Foundation

/// Captures the real microphone, so that when a microphone is what woke SoundBar up the bars show the
/// voice rather than sitting flat.
///
/// The system tap only hears *output*. Microphone input needs an IOProc on the input device itself,
/// which can be installed directly — no aggregate required. This is the one part of SoundBar that
/// needs Microphone permission, and it is entirely optional: if the grant is missing or the device
/// cannot be opened, the visualiser simply runs from the output tap instead.
final class MicrophoneCapture {

    let analyzer: SpectrumAnalyzer

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Fired on the main queue after the captured device disappears (a USB or Bluetooth microphone
    /// unplugged mid-call). The capture has already been torn down; the owner should re-sync so the
    /// surviving microphone is picked up — without this the strip shows a frozen spectrum bound to a
    /// device that no longer exists, for as long as the call lasts.
    var onDeviceDied: (() -> Void)?

    /// Retained so the listener can be removed symmetrically in `stop()`.
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private static var aliveAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        guard let device = Self.firstRealMicrophone() else {
            lastError = "no real microphone found"
            Log.warn("mic", lastError!)
            return false
        }
        deviceID = device

        guard let format = inputFormat(of: device) else {
            lastError = "could not read the microphone's stream format"
            Log.warn("mic", lastError!)
            return false
        }
        let channels = max(1, Int(format.mChannelsPerFrame))
        analyzer.sampleRate = format.mSampleRate

        // nil queue: the block must run on CoreAudio's own IO thread, exactly as for the system tap.
        var status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            for buffer in buffers {
                guard let raw = buffer.mData, buffer.mDataByteSize > 0 else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                self.analyzer.append(samples: raw.assumingMemoryBound(to: Float.self),
                                     count: count,
                                     channels: max(1, Int(buffer.mNumberChannels)))
            }
        }
        guard status == noErr, ioProcID != nil else {
            lastError = "AudioDeviceCreateIOProcIDWithBlock failed (\(SystemAudioTap.describe(status)))"
            Log.warn("mic", lastError!)
            return false
        }

        status = AudioDeviceStart(deviceID, ioProcID)
        guard status == noErr else {
            // Almost always a missing Microphone grant. Not fatal: the caller falls back to the tap.
            lastError = "AudioDeviceStart failed (\(SystemAudioTap.describe(status))) — "
                      + "Microphone permission may not be granted"
            Log.warn("mic", lastError!)
            stop()
            return false
        }

        isRunning = true
        watchDeviceAliveness(of: device)
        Log.info("mic", "capturing \(VolumeController.name(of: device) ?? "microphone") "
                      + "at \(Int(format.mSampleRate)) Hz, \(channels) ch")
        return true
    }

    /// Tears the capture down if the device vanishes, and tells the owner to re-sync.
    ///
    /// macOS moves the *call app* to the surviving microphone automatically when one is unplugged, so
    /// input activity continues — but our IOProc stays bound to the dead device and simply never fires
    /// again, freezing the display. `DeviceIsAlive` is the disconnect signal.
    private func watchDeviceAliveness(of device: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning, self.deviceID == device else { return }
            var alive: UInt32 = 1
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &Self.aliveAddress, 0, nil, &size, &alive)
            guard status != noErr || alive == 0 else { return }
            Log.warn("mic", "captured microphone disappeared; stopping and re-syncing")
            self.stop()
            self.onDeviceDied?()
        }
        aliveListener = listener
        AudioObjectAddPropertyListenerBlock(device, &Self.aliveAddress, .main, listener)
    }

    func stop() {
        if let aliveListener, deviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(deviceID, &Self.aliveAddress, .main, aliveListener)
        }
        aliveListener = nil
        if let ioProcID, deviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if isRunning {
            isRunning = false
            analyzer.reset()
            Log.info("mic", "microphone capture stopped")
        }
    }

    // MARK: - Device selection

    /// The first input device that is a real microphone rather than loopback or aggregate plumbing —
    /// the same rule the activity monitor uses, and the reason BlackHole being the default input does
    /// not confuse this.
    static func firstRealMicrophone() -> AudioObjectID? {
        let excluded = Settings.shared.excludedDeviceNames
        for device in AudioActivityMonitor.allDevices() {
            guard VolumeController.inputChannelCount(device) > 0 else { continue }
            let transport = VolumeController.transportType(device)
            guard transport != kAudioDeviceTransportTypeVirtual,
                  transport != kAudioDeviceTransportTypeAggregate else { continue }
            if let name = VolumeController.name(of: device), excluded.contains(name) { continue }
            return device
        }
        return nil
    }

    private func inputFormat(of device: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format) == noErr else {
            return nil
        }
        return format
    }
}
