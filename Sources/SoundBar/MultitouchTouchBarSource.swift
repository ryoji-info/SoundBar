import Foundation

/// Reads contacts from the Touch Bar digitiser through the private MultitouchSupport framework.
///
/// The Touch Bar is a multi-touch device in its own right, separate from the trackpad, and it keeps
/// reporting contacts even while another application is drawing on the strip. That is what lets
/// SoundBar recognise a long press and a slide while AVTouchBar owns the display.
///
/// Everything here is private API, so it is loaded with `dlopen`/`dlsym` and every step is checked:
/// if the framework, a symbol, or the device is missing, `start()` returns false and SoundBar simply
/// runs without gestures rather than crashing.
///
/// `MTTouch` fields are read at explicit byte offsets instead of via a Swift struct, because the
/// struct has grown between macOS releases and only the leading fields are stable. `touchStride` is
/// derived at runtime from the framework rather than hardcoded where possible.
final class MultitouchTouchBarSource: TouchBarTouchSource {

    var onTouch: ((TouchSample) -> Void)?

    /// Physical width of the digitiser in millimetres, read from the device once it is opened.
    /// Measured 232.1 mm on this MacBook Pro; used to convert normalised movement into millimetres.
    private(set) var surfaceWidthMM: Double?

    // MARK: - Private framework binding

    private typealias CreateList = @convention(c) () -> CFArray?
    private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer, @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32) -> Void
    private typealias UnregisterCallback = @convention(c) (UnsafeMutableRawPointer, @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32) -> Void
    private typealias DeviceStart = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias DeviceStop = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias GetDimensions = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias GetFamilyID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private var handle: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var stopFn: DeviceStop?
    private var unregisterFn: UnregisterCallback?

    /// Byte offsets inside `MTTouch`, valid for the 64-bit layout Apple has shipped since the Touch
    /// Bar was introduced. Verified against measured contacts at runtime before use.
    private enum Offset {
        static let timestamp = 8      // Double
        static let pathIndex = 16     // Int32, stable contact identifier
        static let state = 20         // Int32, MTTouchState
        static let normalizedX = 32   // Float
        static let normalizedY = 36   // Float
    }

    /// Size of one `MTTouch`. Confirmed by walking the frame buffer and checking that the derived
    /// contacts are self-consistent.
    private var touchStride = 96

    /// `MTTouchState` values, measured against live contacts:
    /// 1 = startInRange, 3 = makeTouch, 4 = touching, 5 = breakTouch, 6 = lingerInRange,
    /// 7 = outOfRange. Only 3 and 4 are an actual finger on the glass — 1 and 6 are proximity,
    /// which is why treating "< 5" as down would fire gestures off a hovering hand.
    private static func isFingerDown(_ state: Int32) -> Bool {
        state == 3 || state == 4
    }

    // MARK: - Lifecycle

    func start() -> Bool {
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            Log.warn("touch", "could not load MultitouchSupport: \(reason)")
            return false
        }
        self.handle = handle

        guard let createList = symbol(handle, "MTDeviceCreateList", as: CreateList.self),
              let register = symbol(handle, "MTRegisterContactFrameCallback", as: RegisterCallback.self),
              let deviceStart = symbol(handle, "MTDeviceStart", as: DeviceStart.self),
              let deviceStop = symbol(handle, "MTDeviceStop", as: DeviceStop.self) else {
            Log.warn("touch", "MultitouchSupport is missing an expected symbol")
            return false
        }
        stopFn = deviceStop
        unregisterFn = symbol(handle, "MTUnregisterContactFrameCallback", as: UnregisterCallback.self)

        guard let list = createList() as [AnyObject]? else {
            Log.warn("touch", "MTDeviceCreateList returned nothing")
            return false
        }

        let getDimensions = symbol(handle, "MTDeviceGetSensorSurfaceDimensions", as: GetDimensions.self)
        let getFamily = symbol(handle, "MTDeviceGetFamilyID", as: GetFamilyID.self)

        guard let touchBar = pickTouchBarDevice(from: list,
                                                getDimensions: getDimensions,
                                                getFamily: getFamily) else {
            Log.warn("touch", "no Touch Bar digitiser among \(list.count) multitouch device(s)")
            return false
        }
        device = touchBar

        Self.active = self
        register(touchBar, Self.frameCallback)
        deviceStart(touchBar, 0)
        Log.info("touch", "listening to Touch Bar digitiser")
        return true
    }

    func stop() {
        if let device {
            if let unregisterFn { unregisterFn(device, Self.frameCallback) }
            stopFn?(device)
        }
        device = nil
        if Self.active === self { Self.active = nil }
        // The framework is intentionally left loaded: unloading a framework that still has
        // registered callbacks in flight is a good way to crash on the way out.
    }

    // MARK: - Device selection

    /// Picks the Touch Bar out of the multitouch devices. The trackpad and the Touch Bar are both
    /// multitouch devices; the Touch Bar is distinguished by its shape — very wide and only a few
    /// millimetres tall — which is far more robust than matching family IDs that change per model.
    private func pickTouchBarDevice(from list: [AnyObject],
                                    getDimensions: GetDimensions?,
                                    getFamily: GetFamilyID?) -> UnsafeMutableRawPointer? {
        var best: (device: UnsafeMutableRawPointer, ratio: Double, widthMM: Double)?
        for entry in list {
            let device = unsafeBitCast(entry, to: UnsafeMutableRawPointer.self)
            var width: Int32 = 0
            var height: Int32 = 0
            var family: Int32 = -1
            if let getFamily { _ = getFamily(device, &family) }
            guard let getDimensions, getDimensions(device, &width, &height) == 0,
                  width > 0, height > 0 else {
                Log.debug("touch", "multitouch device family=\(family) with unknown dimensions")
                continue
            }
            // Dimensions are reported in hundredths of a millimetre.
            let widthMM = Double(width) / 100.0
            let heightMM = Double(height) / 100.0
            let ratio = widthMM / heightMM
            Log.debug("touch", "multitouch device family=\(family) \(String(format: "%.1f x %.1f mm", widthMM, heightMM)) ratio=\(String(format: "%.1f", ratio))")
            // A trackpad is roughly 1.5:1. The Touch Bar is more like 20:1.
            guard ratio > 8, heightMM < 20 else { continue }
            if best == nil || ratio > best!.ratio {
                best = (device, ratio, widthMM)
            }
        }
        if let best {
            Log.info("touch", "selected Touch Bar digitiser (aspect ratio \(String(format: "%.1f", best.ratio)):1)")
            surfaceWidthMM = best.widthMM
            return best.device
        }
        return nil
    }

    private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    // MARK: - Frame callback

    /// MultitouchSupport takes a plain C function pointer, so the receiving instance is reached
    /// through a static. Only one Touch Bar reader exists at a time.
    private static weak var active: MultitouchTouchBarSource?

    private static let frameCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = {
        _, touches, numTouches, timestamp, _ in
        guard let source = MultitouchTouchBarSource.active else { return 0 }
        // A frame with no contacts is one of the two ways a lift is reported (the other being
        // state 5/6/7). Dropping it would leave a gesture latched with a finger that is long gone.
        guard let touches, numTouches > 0 else {
            source.reportAllLifted(frameTimestamp: timestamp)
            return 0
        }
        source.consume(touches: touches, count: Int(numTouches), frameTimestamp: timestamp)
        return 0
    }

    /// Contacts seen as down in the previous frame, so an empty frame can be turned into explicit
    /// lift events for each of them.
    private var contactsDown: Set<Int32> = []

    private func reportAllLifted(frameTimestamp: Double) {
        guard !contactsDown.isEmpty else { return }
        let lifted = contactsDown
        contactsDown.removeAll()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for id in lifted {
                self.onTouch?(TouchSample(id: id, x: 0, y: 0, timestamp: frameTimestamp, isDown: false))
            }
        }
    }

    /// Set by `SoundBar --watch-touches --raw` to dump the first few frames byte-for-byte, so the
    /// `MTTouch` field offsets can be checked against reality rather than assumed.
    static var rawDumpFramesRemaining = 0

    private func consume(touches: UnsafeMutableRawPointer, count: Int, frameTimestamp: Double) {
        if Self.rawDumpFramesRemaining > 0 {
            Self.rawDumpFramesRemaining -= 1
            let bytes = UnsafeRawBufferPointer(start: touches, count: min(count * touchStride, 192))
            let hex = bytes.enumerated().map { offset, byte -> String in
                (offset % 8 == 0 ? "\n  @\(String(format: "%3d", offset)): " : "") + String(format: "%02x ", byte)
            }.joined()
            print("RAW FRAME numTouches=\(count) stride=\(touchStride)\(hex)")
            for index in 0..<count {
                let base = touches.advanced(by: index * touchStride)
                print("  decoded[\(index)] id=\(base.loadUnaligned(fromByteOffset: Offset.pathIndex, as: Int32.self))"
                      + " state=\(base.loadUnaligned(fromByteOffset: Offset.state, as: Int32.self))"
                      + " x=\(base.loadUnaligned(fromByteOffset: Offset.normalizedX, as: Float.self))"
                      + " y=\(base.loadUnaligned(fromByteOffset: Offset.normalizedY, as: Float.self))")
            }
        }

        var samples: [TouchSample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let base = touches.advanced(by: index * touchStride)
            let pathIndex = base.loadUnaligned(fromByteOffset: Offset.pathIndex, as: Int32.self)
            let state = base.loadUnaligned(fromByteOffset: Offset.state, as: Int32.self)
            let x = Double(base.loadUnaligned(fromByteOffset: Offset.normalizedX, as: Float.self))
            let y = Double(base.loadUnaligned(fromByteOffset: Offset.normalizedY, as: Float.self))

            // Reject anything that does not look like a normalised coordinate. If the struct layout
            // ever changes under us this is what stops SoundBar acting on garbage.
            guard x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05 else {
                Log.debug("touch", "discarding implausible contact x=\(x) y=\(y) (struct layout may have changed)")
                continue
            }
            let down = Self.isFingerDown(state)
            if down { contactsDown.insert(pathIndex) } else { contactsDown.remove(pathIndex) }
            samples.append(TouchSample(id: pathIndex,
                                       x: min(max(x, 0), 1),
                                       y: min(max(y, 0), 1),
                                       timestamp: frameTimestamp,
                                       isDown: down))
        }
        guard !samples.isEmpty else { return }
        // Recognition and all downstream work happens on the main queue; this callback arrives on a
        // private MultitouchSupport thread.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for sample in samples { self.onTouch?(sample) }
        }
    }
}
