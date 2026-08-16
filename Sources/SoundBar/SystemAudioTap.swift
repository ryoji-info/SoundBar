import CoreAudio
import Foundation

/// Captures the system audio mix so SoundBar can visualise it.
///
/// This is the reason merging the two apps is an upgrade rather than just a tidy-up. AVTouchBar
/// captured audio by building an aggregate device and **making it the system default output**, which
/// is what killed the volume keys and broke its own slide gesture. A CoreAudio *process tap*
/// (macOS 14.2+) listens to the same mix without touching the user's audio configuration at all:
///
///  * the tap is global, so it hears every app;
///  * the aggregate device that carries it is created with `kAudioAggregateDeviceIsPrivateKey`, so it
///    never appears in Sound settings and can never become anyone's default;
///  * `CATapMuteBehavior.unmuted` means playback is unaffected — we only listen.
///
/// No BlackHole, no loopback, no device switching.
final class SystemAudioTap {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID: UUID?

    /// The tap description is retained for as long as the tap lives. Letting it deallocate when
    /// `start()` returns leaves the tap object present but silent — the IOProc is simply never
    /// invoked. Measured: 0 callbacks when it is a local, ~93/s when it is held here.
    private var tapDescription: CATapDescription?

    let analyzer: SpectrumAnalyzer

    private(set) var isRunning = false

    /// Set when the last start failed because macOS refused the tap, which in practice means the
    /// user has not granted audio recording.
    private(set) var lastError: String?

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    deinit { stop() }

    // MARK: - Start / stop

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        // A global tap, excluding nothing: we want the whole mix.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SoundBar Visualiser Tap"
        description.uuid = UUID()
        description.muteBehavior = .unmuted      // listen only; do not alter playback
        // Do NOT touch `isExclusive`. `initStereoGlobalTapButExcludeProcesses` sets it true, which is
        // what makes `processes` an *exclude* list — i.e. "tap everything". Setting it false inverts
        // the meaning to "tap only the listed processes", and with an empty list that is nothing at
        // all: the tap is created, the aggregate reports 2 input channels, and every sample is zero.
        //
        // Nor mark the tap itself private: the aggregate resolves the tap by UID and cannot find a
        // private one. Privacy belongs on the aggregate (kAudioAggregateDeviceIsPrivateKey).
        tapUUID = description.uuid
        tapDescription = description

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            lastError = "AudioHardwareCreateProcessTap failed (\(Self.describe(status)))"
            Log.error("tap", lastError!)
            return false
        }

        guard let format = tapStreamFormat() else {
            lastError = "could not read the tap's stream format"
            Log.error("tap", lastError!)
            stop()
            return false
        }
        Log.info("tap", "tap format: \(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, "
                      + "flags \(format.mFormatFlags)")
        // The analyser turns FFT bins into frequencies, so it needs the real rate.
        analyzer.sampleRate = format.mSampleRate

        guard createPrivateAggregate(carrying: description) else {
            stop()
            return false
        }

        let channels = Int(format.mChannelsPerFrame)
        // The queue MUST be nil so the block runs on CoreAudio's own IO thread. Passing an explicit
        // dispatch queue here is accepted and returns noErr, but the block is then never invoked —
        // measured: 0 callbacks over 12 s with a queue, ~93/s with nil.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.consume(inputData, channels: channels)
        }
        guard status == noErr, ioProcID != nil else {
            lastError = "AudioDeviceCreateIOProcIDWithBlock failed (\(Self.describe(status)))"
            Log.error("tap", lastError!)
            stop()
            return false
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            lastError = "AudioDeviceStart failed (\(Self.describe(status)))"
            Log.error("tap", lastError!)
            stop()
            return false
        }

        isRunning = true
        let inCh = VolumeController.inputChannelCount(aggregateID)
        let outCh = VolumeController.outputChannelCount(aggregateID)
        Log.info("tap", "system audio tap running (private aggregate \(aggregateID), "
                      + "in=\(inCh)ch out=\(outCh)ch)")
        return true
    }

    func stop() {
        if let ioProcID {
            if aggregateID != AudioObjectID(kAudioObjectUnknown) {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapUUID = nil
        tapDescription = nil
        if isRunning {
            isRunning = false
            // Otherwise the analyser keeps its last frame and a mixed display would blend it in.
            analyzer.reset()
            Log.info("tap", "system audio tap stopped and torn down")
        }
    }

    // MARK: - Audio thread

    private func consume(_ bufferList: UnsafePointer<AudioBufferList>, channels: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        for buffer in buffers {
            guard let raw = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let channelsInBuffer = max(1, Int(buffer.mNumberChannels))
            analyzer.append(samples: raw.assumingMemoryBound(to: Float.self),
                            count: count, channels: channelsInBuffer)
        }
    }

    // MARK: - Setup helpers

    private func tapStreamFormat() -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else {
            return nil
        }
        return format
    }

    /// Builds a private aggregate device that carries our tap, and nothing else.
    ///
    /// `kAudioAggregateDeviceIsPrivateKey` is what makes this safe: the device is invisible to other
    /// apps and to Sound settings, so it can never become anyone's default output. That is the whole
    /// difference from AVTouchBar's approach, which published its aggregate and made it the default.
    ///
    /// A *public* aggregate carrying the same tap reports 0 input channels and delivers silence, so
    /// the private flag is load-bearing rather than cosmetic.
    private func createPrivateAggregate(carrying description: CATapDescription) -> Bool {
        let uid = "com.ryoji.SoundBar.tap.\(UUID().uuidString)"
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundBar Visualiser",
            kAudioAggregateDeviceUIDKey: uid,
            // Private: never shown in Sound settings, never selectable, never a default device.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // No sub-devices at all. Measured: a tap-only private aggregate delivers input fine
            // (~93 callbacks/s), and leaving the real output device out means SoundBar neither
            // depends on which device is current nor has to rebuild when the user switches output.
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        let status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            lastError = "AudioHardwareCreateAggregateDevice failed (\(Self.describe(status)))"
            Log.error("tap", lastError!)
            return false
        }
        Log.debug("tap", "private tap-only aggregate \(aggregateID) created")
        return true
    }

    /// UID of the device the user is actually listening through.
    static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &deviceID) == noErr,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return VolumeController.uid(of: deviceID)
    }

    /// OSStatus values come back as four-character codes more often than as numbers.
    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                     UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
           let text = String(bytes: bytes, encoding: .ascii) {
            return "'\(text)' / \(status)"
        }
        return "\(status)"
    }
}
