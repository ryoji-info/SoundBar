import Accelerate
import Foundation

/// Turns raw audio into the per-bar levels the Touch Bar draws.
///
/// Sized for the job rather than for accuracy: a 1024-point FFT at 48 kHz gives ~47 Hz bins, which is
/// plenty of resolution for 44 log-spaced bars on a 30 pt tall strip, and costs microseconds. The
/// analysis runs on the audio thread; `levels()` is read from the render loop, so the handoff is a
/// small lock.
final class SpectrumAnalyzer {

    private let fftSize: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?

    private var window: [Float]
    private var scratchReal: [Float]
    private var scratchImag: [Float]
    private var windowed: [Float]
    private var magnitudes: [Float]

    /// Samples waiting to be analysed, with an index for the first unconsumed one.
    ///
    /// Consuming by index rather than `removeFirst` matters at 4096 points: shifting the buffer on
    /// every hop was an O(n) memmove 47 times a second, and slicing out an `Array` per FFT allocated
    /// 16 KB just as often.
    private var pending: [Float]
    private var pendingStart = 0

    private let lock = NSLock()
    private var smoothed: [Float]
    private var barCount: Int

    // MARK: - VU state
    //
    // A real VU meter is an averaging instrument, not a peak one: the needle takes about 300 ms to
    // reach 99 % of a step. That slowness is the whole character of it, so the ballistics are modelled
    // rather than reusing the spectrum's fast attack.
    private var vuLeft: Float = 0
    private var vuRight: Float = 0
    private var peakLeft: Float = 0
    private var peakRight: Float = 0
    private var peakLeftAge: Double = 0
    private var peakRightAge: Double = 0

    /// VU maps this dB window onto 0...1. -40 dBFS is a sensible bottom for music.
    private let vuFloorDB: Float = -42
    private let vuCeilingDB: Float = -3

    /// Peaks sit still this long before they start sliding back down.
    private let peakHoldSeconds: Double = 1.1
    private let peakFallPerSecond: Float = 0.55

    // MARK: - Waveform state

    /// A ring of recent mono samples for the oscilloscope style.
    private var waveRing = [Float](repeating: 0, count: 4096)
    private var waveWrite = 0

    /// Attack is fast so transients pop; decay is slower so the bars fall like a real meter.
    private let attack: Float = 0.55
    private let decay: Float = 0.16

    /// dB window mapped onto the bar height. -60 dB reads as silence, 0 dB as full height.
    private let floorDB: Float = -60
    private let ceilingDB: Float = -6

    /// Sample rate of whatever is feeding us, set from the tap's own format. Only used to turn FFT
    /// bins into frequencies, so a wrong value would skew the band edges rather than break anything.
    var sampleRate: Double = 48_000 {
        didSet { if sampleRate != oldValue { lock.lock(); bandRangesCache = nil; lock.unlock() } }
    }

    /// The range the bands span. 20 Hz is the bottom of hearing and the reason the FFT is 4096 points:
    /// at 48 kHz that is an 11.7 Hz bin, where 1024 points would give 46.9 Hz and simply have no data
    /// below ~47 Hz at all.
    private let minFrequency = 20.0
    private let maxFrequency = 20_000.0

    /// The frequency the spectral tilt rotates about — bands here are untouched whatever the tilt.
    private let tiltPivotHz = 1_000.0

    private var _tiltDBPerOctave: Float = 0

    /// dB added per octave above `tiltPivotHz` (and subtracted per octave below it) before a band
    /// becomes a bar height. `0` leaves the spectrum alone; `+6` is exactly `level × frequency`.
    ///
    /// Written from the main thread and read on the audio thread, hence the locked accessor.
    var tiltDBPerOctave: Float {
        get { lock.lock(); defer { lock.unlock() }; return _tiltDBPerOctave }
        set { lock.lock(); _tiltDBPerOctave = newValue; lock.unlock() }
    }

    init(fftSize: Int = 4096, barCount: Int = 44) {
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.scratchReal = [Float](repeating: 0, count: halfSize)
        self.scratchImag = [Float](repeating: 0, count: halfSize)
        self.magnitudes = [Float](repeating: 0, count: halfSize)
        self.pending = []
        self.pending.reserveCapacity(fftSize * 4)
        self.barCount = max(4, barCount)
        self.smoothed = [Float](repeating: 0, count: self.barCount)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func setBarCount(_ count: Int) {
        let count = max(4, count)
        lock.lock()
        if count != barCount {
            barCount = count
            smoothed = [Float](repeating: 0, count: count)
            bandRangesCache = nil
        }
        lock.unlock()
    }

    /// Feed interleaved or mono float samples. Called from the audio thread.
    func append(samples: UnsafePointer<Float>, count: Int, channels: Int) {
        guard count > 0, channels > 0 else { return }
        // Mix to mono. Averaging is fine here; we only need an envelope, not a faithful downmix.
        var mono = [Float](repeating: 0, count: count / channels)
        if channels == 1 {
            let frames = mono.count
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: samples, count: frames)
            }
        } else {
            for frame in 0..<mono.count {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                mono[frame] = sum / Float(channels)
            }
        }

        // Per-channel RMS for the VU meter, taken before the mono mixdown so left and right stay
        // distinguishable.
        updateVU(samples: samples, count: count, channels: channels)

        // Keep a ring of recent samples for the oscilloscope.
        lock.lock()
        for value in mono {
            waveRing[waveWrite] = value
            waveWrite = (waveWrite + 1) % waveRing.count
        }
        lock.unlock()

        pending.append(contentsOf: mono)

        // A half-window hop gives a new spectrum every ~43 ms, which is ahead of the 20 fps render at
        // 50 ms, so nothing is lost by not going finer.
        let hop = max(fftSize / 2, 1)
        while pending.count - pendingStart >= fftSize {
            analyse(from: pendingStart)
            pendingStart += hop
        }

        // Compact occasionally rather than on every hop.
        if pendingStart >= fftSize * 2 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
    }

    /// Zero everything, so a stopped source contributes nothing.
    ///
    /// Precondition: the caller must already have destroyed its IOProc. `pending`/`pendingStart` are
    /// not lock-protected — they rely on the audio thread being the only writer — so resetting them
    /// while a capture is still live would race.
    ///
    /// Levels only ever change inside `analyse`, so an analyser whose capture has stopped keeps its
    /// last frame forever. That was invisible while exactly one source was ever read, but a mixed
    /// display would blend live audio with a frozen ghost of whatever stopped — so both captures
    /// reset on stop.
    func reset() {
        lock.lock()
        smoothed = [Float](repeating: 0, count: smoothed.count)
        vuLeft = 0
        vuRight = 0
        peakLeft = 0
        peakRight = 0
        peakLeftAge = 0
        peakRightAge = 0
        waveRing = [Float](repeating: 0, count: waveRing.count)
        waveWrite = 0
        lock.unlock()
        pending.removeAll(keepingCapacity: true)
        pendingStart = 0
    }

    /// Feed a silence frame, so the bars decay when a stream stops rather than freezing.
    func appendSilence() {
        lock.lock()
        for index in smoothed.indices {
            smoothed[index] *= (1 - decay)
        }
        vuLeft *= 0.85
        vuRight *= 0.85
        lock.unlock()
    }

    private func updateVU(samples: UnsafePointer<Float>, count: Int, channels: Int) {
        let frames = count / channels
        guard frames > 0 else { return }

        var sumL: Float = 0
        var sumR: Float = 0
        if channels == 1 {
            vDSP_measqv(samples, 1, &sumL, vDSP_Length(frames))
            sumR = sumL
        } else {
            vDSP_measqv(samples, vDSP_Stride(channels), &sumL, vDSP_Length(frames))
            vDSP_measqv(samples + 1, vDSP_Stride(channels), &sumR, vDSP_Length(frames))
        }

        func normalised(_ meanSquare: Float) -> Float {
            let rms = sqrt(max(meanSquare, 0))
            let db = 20 * log10(max(rms, 1e-9))
            return min(1, max(0, (db - vuFloorDB) / (vuCeilingDB - vuFloorDB)))
        }
        let targetL = normalised(sumL)
        let targetR = normalised(sumR)

        // 300 ms to settle, expressed against this buffer's real duration.
        let dt = Double(frames) / 48_000.0
        let coefficient = Float(1 - exp(-dt / 0.13))

        lock.lock()
        vuLeft += (targetL - vuLeft) * coefficient
        vuRight += (targetR - vuRight) * coefficient

        /// Rise instantly to a new peak, hold it still, then let it slide back down.
        func advancePeak(_ value: Float, _ peak: inout Float, _ age: inout Double) {
            if value >= peak {
                peak = value
                age = 0
            } else {
                age += dt
                if age > peakHoldSeconds {
                    peak = max(value, peak - peakFallPerSecond * Float(dt))
                }
            }
        }
        advancePeak(vuLeft, &peakLeft, &peakLeftAge)
        advancePeak(vuRight, &peakRight, &peakRightAge)
        lock.unlock()
    }

    /// Left/right VU levels and their held peaks, all 0...1.
    func vuLevels() -> (left: Float, right: Float, peakLeft: Float, peakRight: Float) {
        lock.lock()
        let result = (vuLeft, vuRight, peakLeft, peakRight)
        lock.unlock()
        return result
    }

    /// The most recent `count` samples, oldest first, for the oscilloscope.
    func waveform(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let span = min(count, waveRing.count)
        var out = [Float](repeating: 0, count: span)
        // Decimate across a window several times longer than the output, so the trace shows a
        // recognisable wave rather than a few hundred microseconds of it.
        let window = min(waveRing.count, span * 8)
        let step = Double(window) / Double(span)
        for i in 0..<span {
            let offset = Int(Double(i) * step)
            let index = (waveWrite - window + offset + waveRing.count * 2) % waveRing.count
            out[i] = waveRing[index]
        }
        return out
    }

    /// Windows `fftSize` samples starting at `offset` in `pending`, straight into the scratch buffer.
    private func analyse(from offset: Int) {
        guard let fftSetup, offset + fftSize <= pending.count else { return }

        pending.withUnsafeBufferPointer { source in
            vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        }

        // Pack the real signal into split-complex form, which is what the real-to-complex FFT wants.
        windowed.withUnsafeBufferPointer { input in
            input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
                scratchReal.withUnsafeMutableBufferPointer { realPtr in
                    scratchImag.withUnsafeMutableBufferPointer { imagPtr in
                        var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                                    imagp: imagPtr.baseAddress!)
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
                    }
                }
            }
        }

        // vDSP's real FFT is scaled by 2N; normalise so levels do not depend on the FFT size.
        var scale = 1.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))

        let ranges = bandRanges()
        let tilt = tiltDBPerOctave                       // read once; locked accessor
        let binWidth = Float(sampleRate) / Float(fftSize)
        var frameLevels = [Float](repeating: 0, count: ranges.count)
        for (index, range) in ranges.enumerated() {
            var peak: Float = 0
            for bin in range where bin < halfSize {
                peak = max(peak, magnitudes[bin])
            }
            // dBFS, then mapped onto 0...1 across the display window.
            var db = 20 * log10(max(peak, 1e-9))
            if tilt != 0 {
                // Spectral tilt, pivoting at 1 kHz so mids are left where they are: bands above the
                // pivot are lifted, bands below are cut. Music is heavily bass-weighted, so an untilted
                // display leans left; this evens it out.
                //
                // The scale is dB per octave, and +6 is exactly `level × frequency` — doubling the
                // frequency doubles the amplitude, since 20·log10(2) ≈ 6.02 dB.
                let centre = (Float(range.lowerBound) + Float(range.upperBound)) * 0.5 * binWidth
                db += tilt * log2(max(centre, 1) / Float(tiltPivotHz))
            }
            frameLevels[index] = min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
        }

        lock.lock()
        if smoothed.count != frameLevels.count {
            smoothed = frameLevels
        } else {
            for index in smoothed.indices {
                let target = frameLevels[index]
                // Rise quickly, fall slowly.
                let coefficient = target > smoothed[index] ? attack : decay
                smoothed[index] += (target - smoothed[index]) * coefficient
            }
        }
        lock.unlock()
    }

    private var bandRangesCache: [Range<Int>]?

    /// Log-spaced bands from 20 Hz to 20 kHz, so bass does not get one bar and treble forty.
    ///
    /// Band edges are computed as frequencies and then converted to bins, rather than log-spacing the
    /// bin indices directly — that is what makes the range mean something in Hz.
    ///
    /// At the bottom the maths asks for finer resolution than the FFT has: the first few bands are
    /// each under one bin wide. They are clamped to advance by at least one bin, so the lowest bands
    /// step 11.7 Hz at a time instead of following the log curve exactly. Every analyser has to do
    /// this; you cannot resolve 20 Hz from 23 Hz without a much longer window.
    private func bandRanges() -> [Range<Int>] {
        // Locked: this runs on the audio thread (from `analyse`, which does not hold the lock at that
        // point), and both `bandRangesCache` and `barCount` are written from the main thread by
        // `setBarCount` — which happens for real whenever a ×2 pattern is selected while audio plays.
        // `bandStartFrequencies` reads the cache directly rather than calling this, so no recursion.
        lock.lock()
        defer { lock.unlock() }

        if let bandRangesCache, bandRangesCache.count == barCount { return bandRangesCache }
        let count = barCount
        let binWidth = sampleRate / Double(fftSize)
        let topBin = halfSize - 1
        // Stay just below Nyquist in case the device runs slower than 44.1 kHz.
        let topFrequency = min(maxFrequency, sampleRate / 2 * 0.98)

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(count)
        // Start at the bin that *contains* 20 Hz, not the one below it: bin 1 is centred at 11.7 Hz,
        // which is subsonic, and rumble and DC leakage there would keep the first bar permanently lit.
        var previous = max(1, Int((minFrequency / binWidth).rounded()))
        for index in 0..<count {
            let t = Double(index + 1) / Double(count)
            let frequency = minFrequency * pow(topFrequency / minFrequency, t)
            var upper = Int((frequency / binWidth).rounded())
            upper = min(max(upper, previous + 1), topBin)
            ranges.append(previous..<upper)
            previous = upper
            if previous >= topBin { break }
        }
        // If the clamping ran out of bins, pad so the renderer always gets `count` bands.
        while ranges.count < count {
            ranges.append((topBin - 1)..<topBin)
        }
        bandRangesCache = ranges
        return ranges
    }

    /// The frequency each band starts at, for logging and for sanity-checking the range.
    func bandStartFrequencies() -> [Double] {
        let binWidth = sampleRate / Double(fftSize)
        lock.lock()
        let ranges = bandRangesCache ?? []
        lock.unlock()
        return ranges.map { Double($0.lowerBound) * binWidth }
    }

    /// Current smoothed levels, 0...1, for the renderer.
    func levels() -> [Float] {
        lock.lock()
        let copy = smoothed
        lock.unlock()
        return copy
    }
}
