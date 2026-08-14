import AppKit

/// One frame's worth of analysed audio, as handed from the coordinator to the renderer.
typealias VisualFrameData = (levels: [Float],
                             waveform: [Float],
                             vu: (left: Float, right: Float, peakLeft: Float, peakRight: Float))

/// A frame with nothing in it, drawn as a flat line.
let emptyVisualFrameData: VisualFrameData = (levels: [], waveform: [], vu: (0, 0, 0, 0))

/// Everything a style needs to draw one frame.
struct VisualFrame {
    /// Per-band spectrum levels, 0...1.
    let levels: [Float]
    /// Recent time-domain samples, roughly -1...1.
    let waveform: [Float]
    /// VU levels and their held peaks, 0...1.
    let vu: (left: Float, right: Float, peakLeft: Float, peakRight: Float)
    let palette: Palette
    let bounds: NSRect
}

/// The visual patterns, in the order a tap cycles through them.
enum VisualStyle: String, CaseIterable {
    case bars       // classic spectrum analyser
    case barsFine   // the same, at twice the band count and a tighter gap
    case mirror     // spectrum mirrored about the centre line
    case mirrorFine // the same, at twice the band count and a tighter gap
    case blocks     // segmented LED-style spectrum
    case peaks      // slim spectrum with falling peak caps
    case dots       // retro dot-matrix LED panel
    case wave       // oscilloscope
    case vu         // VU meter, left and right, with peak hold
    case vuInward   // VU filling from both edges towards the centre
    case vuOutward  // VU filling from the centre out to both edges

    var displayName: String {
        switch self {
        case .bars: return "Spectrum Bars"
        case .barsFine: return "Spectrum Bars ×2"
        case .mirror: return "Spectrum Mirror"
        case .mirrorFine: return "Spectrum Mirror ×2"
        case .blocks: return "Spectrum Blocks"
        case .peaks: return "Spectrum Peaks"
        case .dots: return "Retro Dot LED"
        case .wave: return "Waveform"
        case .vu: return "VU Meter"
        case .vuInward: return "VU Inward"
        case .vuOutward: return "VU Outward"
        }
    }

    /// How many analysis bands this pattern wants, as a multiple of `barCount`.
    var bandMultiplier: Int {
        switch self {
        case .barsFine, .mirrorFine: return 2
        default: return 1
        }
    }

    /// Fraction of each slot the bar fills. The ×2 patterns pack twice as many bars into the same
    /// width, so they use a much smaller gap — at the normal 0.62 the bars would be hairlines.
    var barWidthFraction: Double {
        switch self {
        case .barsFine, .mirrorFine: return Settings.shared.fineBarWidthFraction
        default: return Settings.shared.barWidthFraction
        }
    }

    var next: VisualStyle {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

private extension CGFloat {
    /// +1 or -1, for mirroring a meter without branching on which side it is.
    func sign() -> CGFloat { self >= 0 ? 1 : -1 }
}

/// Draws a frame in the current style.
///
/// Everything is drawn with Core Graphics into the Touch Bar's 1085 x 30 pt view. That is about
/// 33,000 points at 30 fps, which is trivial, and it keeps every style in one small file rather
/// than needing a different layer tree each.
enum VisualRenderer {

    /// Peak caps for the `peaks` style, held between frames.
    private static var peakCaps: [CGFloat] = []
    private static var peakAges: [Double] = []
    private static var lastDraw = Date()

    static func reset() {
        peakCaps.removeAll()
        peakAges.removeAll()
    }

    static func draw(_ style: VisualStyle, _ frame: VisualFrame, in context: CGContext) {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(frame.bounds)

        switch style {
        case .bars, .barsFine: drawBars(frame, context, mirrored: false, style: style)
        case .mirror, .mirrorFine: drawBars(frame, context, mirrored: true, style: style)
        case .blocks: drawBlocks(frame, context)
        case .peaks: drawPeaks(frame, context)
        case .dots: drawDots(frame, context)
        case .wave: drawWave(frame, context)
        case .vu: drawVU(frame, context)
        case .vuInward: drawSymmetricVU(frame, context, inward: true)
        case .vuOutward: drawSymmetricVU(frame, context, inward: false)
        }
    }

    // MARK: - Spectrum styles

    /// Bars rising from the bottom, or growing from the centre line when mirrored.
    private static func drawBars(_ frame: VisualFrame, _ context: CGContext,
                                 mirrored: Bool, style: VisualStyle) {
        let levels = frame.levels
        guard !levels.isEmpty else { return }
        let bounds = frame.bounds
        let slot = bounds.width / CGFloat(levels.count)
        let width = max(1, slot * CGFloat(style.barWidthFraction))
        let inset = (slot - width) / 2
        let colors = frame.palette.cgColors(count: levels.count)

        for (index, level) in levels.enumerated() {
            let value = CGFloat(min(max(level, 0), 1))
            let x = CGFloat(index) * slot + inset
            context.setFillColor(colors[index])
            if mirrored {
                let half = max(1, value * bounds.height / 2)
                context.fill(CGRect(x: x, y: bounds.midY - half, width: width, height: half * 2))
            } else {
                let height = max(1, value * bounds.height)
                context.fill(CGRect(x: x, y: 0, width: width, height: height))
            }
        }
    }

    /// Segmented bars, like the LED ladders on a hardware analyser.
    private static func drawBlocks(_ frame: VisualFrame, _ context: CGContext) {
        let levels = frame.levels
        guard !levels.isEmpty else { return }
        let bounds = frame.bounds
        let slot = bounds.width / CGFloat(levels.count)
        let width = max(1, slot * CGFloat(Settings.shared.barWidthFraction))
        let inset = (slot - width) / 2

        // Five segments over 30 pt leaves each one about 5 pt tall, which still reads as a ladder.
        // Seven was too fine: the segments and the gaps both landed near 3 pt and the whole strip
        // turned into horizontal stripes.
        let segments = 5
        let gap: CGFloat = 2.0
        let segmentHeight = (bounds.height - gap * CGFloat(segments - 1)) / CGFloat(segments)

        // One colour per segment row, not per bar: the same five colours serve every bar.
        let segmentColors = frame.palette.cgColors(count: segments)
        let segmentDim = segmentColors.map { $0.copy(alpha: 0.055) ?? $0 }

        for (index, level) in levels.enumerated() {
            let value = CGFloat(min(max(level, 0), 1))
            let lit = Int((value * CGFloat(segments)).rounded(.up))
            let x = CGFloat(index) * slot + inset
            for segment in 0..<segments {
                // Colour by height within the bar, so the top segments are the "hot" end of the ramp.
                // Unlit segments are only just visible, so the lit ones carry the shape.
                context.setFillColor(segment < lit ? segmentColors[segment] : segmentDim[segment])
                let y = CGFloat(segment) * (segmentHeight + gap)
                context.fill(CGRect(x: x, y: y, width: width, height: segmentHeight))
            }
        }
    }

    /// Slim bars with a cap that hangs at the recent maximum and then falls.
    private static func drawPeaks(_ frame: VisualFrame, _ context: CGContext) {
        let levels = frame.levels
        guard !levels.isEmpty else { return }
        let bounds = frame.bounds
        let now = Date()
        let dt = min(0.2, now.timeIntervalSince(lastDraw))
        lastDraw = now

        if peakCaps.count != levels.count {
            peakCaps = levels.map { CGFloat($0) }
            peakAges = Array(repeating: 0, count: levels.count)
        }

        let slot = bounds.width / CGFloat(levels.count)
        let width = max(1, slot * CGFloat(Settings.shared.barWidthFraction))
        let inset = (slot - width) / 2
        let colors = frame.palette.cgColors(count: levels.count)
        let capHeight: CGFloat = 2

        for (index, level) in levels.enumerated() {
            let value = CGFloat(min(max(level, 0), 1))
            let x = CGFloat(index) * slot + inset

            if value >= peakCaps[index] {
                peakCaps[index] = value
                peakAges[index] = 0
            } else {
                peakAges[index] += dt
                if peakAges[index] > 0.5 {
                    peakCaps[index] = max(value, peakCaps[index] - CGFloat(dt) * 0.9)
                }
            }

            // The bar itself, dimmed, so the cap is what the eye follows.
            context.setFillColor(colors[index].copy(alpha: 0.45) ?? colors[index])
            context.fill(CGRect(x: x, y: 0, width: width, height: max(1, value * bounds.height)))

            let capY = min(bounds.height - capHeight, peakCaps[index] * bounds.height)
            context.setFillColor(colors[index])
            context.fill(CGRect(x: x, y: capY, width: width, height: capHeight))
        }
    }

    /// A dot-matrix LED panel: a fixed grid of dots, lit from the bottom up.
    ///
    /// The unlit dots are deliberately left faintly visible — that is what makes it read as a physical
    /// LED panel with the lamps off, rather than as floating dots.
    private static func drawDots(_ frame: VisualFrame, _ context: CGContext) {
        let levels = frame.levels
        guard !levels.isEmpty else { return }
        let bounds = frame.bounds

        let rows = 5
        let rowHeight = bounds.height / CGFloat(rows)
        // The grid is square: the column pitch follows the row pitch rather than the bar count, so the
        // dots sit on an even lattice like a real LED panel. Tying columns to `barCount` instead left
        // 25 pt gaps between 4 pt dots, which read as specks rather than a matrix.
        let pitch = rowHeight
        let columns = max(1, Int(bounds.width / pitch))
        let diameter = pitch * 0.70
        let radius = diameter / 2

        let rowColors = frame.palette.cgColors(count: rows)
        let rowDim = rowColors.map { $0.copy(alpha: 0.10) ?? $0 }

        // How many dots are lit in each column.
        var litPerColumn = [Int](repeating: 0, count: columns)
        for column in 0..<columns {
            // Sample the spectrum across the grid, since there are more columns than bands.
            let position = Double(column) / Double(max(1, columns - 1))
            let index = min(levels.count - 1, max(0, Int(position * Double(levels.count - 1))))
            let value = CGFloat(min(max(levels[index], 0), 1))
            litPerColumn[column] = Int((value * CGFloat(rows)).rounded(.up))
        }

        // Square pixels, filled a whole row at a time with `fill(_ rects:)` — ten calls per frame.
        //
        // This shape went through three versions, measured: one `fillEllipse` per dot cost 16 % CPU
        // (835 calls a frame), and batching those ellipses into one path per row was worse still at
        // 41 %, because a path of 167 subpaths is expensive to fill. Square pixels through the batched
        // rect API are cheap, and on a 30 pt strip they read as an LED sign, which is the look anyway.
        var litRects: [CGRect] = []
        var dimRects: [CGRect] = []
        litRects.reserveCapacity(columns)
        dimRects.reserveCapacity(columns)

        for row in 0..<rows {
            let centreY = (CGFloat(row) + 0.5) * rowHeight
            litRects.removeAll(keepingCapacity: true)
            dimRects.removeAll(keepingCapacity: true)

            for column in 0..<columns {
                let centreX = (CGFloat(column) + 0.5) * pitch
                let rect = CGRect(x: centreX - radius, y: centreY - radius,
                                  width: diameter, height: diameter)
                if row < litPerColumn[column] { litRects.append(rect) } else { dimRects.append(rect) }
            }

            if !litRects.isEmpty {
                context.setFillColor(rowColors[row])
                context.fill(litRects)
            }
            if !dimRects.isEmpty {
                context.setFillColor(rowDim[row])
                context.fill(dimRects)
            }
        }
    }

    // MARK: - Waveform

    /// An oscilloscope trace through the middle of the strip.
    private static func drawWave(_ frame: VisualFrame, _ context: CGContext) {
        let samples = frame.waveform
        guard samples.count > 1 else { return }
        let bounds = frame.bounds
        let midY = bounds.midY
        let amplitude = bounds.height / 2 - 1

        // Gain the trace up a little: normal listening levels are well below full scale and would
        // otherwise draw a nearly flat line on a 30 pt strip.
        let gain: CGFloat = 3.2

        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        let step = bounds.width / CGFloat(samples.count - 1)
        // Draw in a few coloured segments so the palette shows along the trace.
        let segments = 24
        let perSegment = max(1, samples.count / segments)
        var index = 0
        while index < samples.count - 1 {
            let end = min(samples.count - 1, index + perSegment)
            let t = Double(index) / Double(max(1, samples.count - 1))
            context.setStrokeColor(frame.palette.color(at: t).cgColor)
            context.beginPath()
            for i in index...end {
                let y = midY + min(amplitude, max(-amplitude, CGFloat(samples[i]) * gain * amplitude))
                let point = CGPoint(x: CGFloat(i) * step, y: y)
                if i == index { context.move(to: point) } else { context.addLine(to: point) }
            }
            context.strokePath()
            index = end
        }
    }

    // MARK: - VU meter

    /// Two horizontal meters, left above right, with a held peak marker and dB ticks.
    private static func drawVU(_ frame: VisualFrame, _ context: CGContext) {
        let bounds = frame.bounds
        let labelWidth: CGFloat = 14
        let trackX = labelWidth
        let trackWidth = bounds.width - labelWidth - 4
        let rowGap: CGFloat = 2
        let rowHeight = (bounds.height - rowGap * 3) / 2

        drawVURow(context, frame: frame,
                  label: "L", value: CGFloat(frame.vu.left), peak: CGFloat(frame.vu.peakLeft),
                  rect: CGRect(x: trackX, y: bounds.height - rowGap - rowHeight,
                               width: trackWidth, height: rowHeight),
                  labelX: 2)
        drawVURow(context, frame: frame,
                  label: "R", value: CGFloat(frame.vu.right), peak: CGFloat(frame.vu.peakRight),
                  rect: CGRect(x: trackX, y: rowGap, width: trackWidth, height: rowHeight),
                  labelX: 2)
    }

    /// A stereo VU split down the middle: the left half *is* the left channel, the right half *is*
    /// the right channel, each using the full height of the strip.
    ///
    /// The centre is the boundary between the two channels, not a shared origin both of them straddle.
    /// `outward` anchors each channel at that boundary and grows towards its own outer edge;
    /// `inward` anchors each at its outer edge and grows towards the boundary, so a loud passage
    /// closes in on the middle.
    private static func drawSymmetricVU(_ frame: VisualFrame, _ context: CGContext, inward: Bool) {
        let bounds = frame.bounds
        let midX = bounds.midX
        let halfWidth = bounds.width / 2
        let inset: CGFloat = 2
        let trackY = inset
        let trackHeight = bounds.height - inset * 2

        // Track across the whole strip.
        context.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: trackY, width: bounds.width, height: trackHeight))

        // No peak markers here — at this size, with two fills already converging on the centre line,
        // a peak tick just added clutter without being easy to read against the moving fill.
        let channels: [(value: CGFloat, isLeft: Bool)] = [
            (CGFloat(frame.vu.left), true),
            (CGFloat(frame.vu.right), false),
        ]

        for channel in channels {
            let value = min(max(channel.value, 0), 1)
            let length = value * halfWidth

            // Where this channel's fill starts, and which way it runs.
            //  outward: starts at the centre boundary, runs to the outer edge
            //  inward:  starts at the outer edge, runs to the centre boundary
            let anchorX: CGFloat   // the zero point for this channel
            let directionX: CGFloat // the far end of this channel's half
            if channel.isLeft {
                anchorX = inward ? 0 : midX
                directionX = inward ? midX : 0
            } else {
                anchorX = inward ? bounds.width : midX
                directionX = inward ? midX : bounds.width
            }

            let fillRect = CGRect(x: min(anchorX, anchorX + (directionX - anchorX).sign() * length),
                                  y: trackY,
                                  width: length,
                                  height: trackHeight)

            if length > 0.5, let gradient = frame.palette.cachedGradient() {
                context.saveGState()
                context.clip(to: fillRect)
                // The ramp always runs from this channel's zero point to its far end, so both
                // channels read identically whichever way they happen to travel.
                context.drawLinearGradient(gradient,
                                           start: CGPoint(x: anchorX, y: trackY),
                                           end: CGPoint(x: directionX, y: trackY),
                                           options: [])
                context.restoreGState()
            }
        }

        // No channel labels: the split at the centre line already says which half is which, and on a
        // 30 pt strip the lettering was clutter sitting on top of the meter.
    }

    private static func drawVURow(_ context: CGContext, frame: VisualFrame,
                                  label: String, value: CGFloat, peak: CGFloat,
                                  rect: CGRect, labelX: CGFloat) {
        // Track.
        context.setFillColor(NSColor(white: 0.14, alpha: 1).cgColor)
        context.fill(rect)

        // One gradient pass clipped to the filled length — slicing leaves antialiased seams.
        let filled = min(max(value, 0), 1) * rect.width
        if filled > 0.5, let gradient = frame.palette.cachedGradient() {
            context.saveGState()
            context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: filled, height: rect.height))
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.minX, y: rect.minY),
                                       end: CGPoint(x: rect.maxX, y: rect.minY),
                                       options: [])
            context.restoreGState()
        }

        // dB ticks at -30, -20, -12, -6, -3 within the meter's -42...-3 window.
        context.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
        for db in [-30.0, -20.0, -12.0, -6.0] {
            let t = (db - (-42.0)) / ((-3.0) - (-42.0))
            let x = rect.minX + CGFloat(t) * rect.width
            context.fill(CGRect(x: x, y: rect.minY, width: 1, height: rect.height))
        }

        // Held peak.
        if peak > 0.01 {
            let x = rect.minX + min(max(peak, 0), 1) * rect.width - 1
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: min(x, rect.maxX - 2), y: rect.minY, width: 2, height: rect.height))
        }

        // Channel label, in the gutter to the left of the track.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: labelX + 4, y: rect.midY - 6))
        NSGraphicsContext.restoreGraphicsState()
    }
}
