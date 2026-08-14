import AppKit

/// The Touch Bar surface. Draws whichever `VisualStyle` is current.
///
/// One `draw(_:)` per frame into a 1085 x 30 pt view — about 33,000 points at 30 fps, which is far
/// cheaper than the layer tree it replaced would have been once six different styles needed different
/// geometry. Nothing is allocated per frame except the small level arrays the analyser already owns.
final class VisualizerView: NSView {

    var style: VisualStyle = .bars {
        didSet {
            guard style != oldValue else { return }
            VisualRenderer.reset()
            needsDisplay = true
        }
    }

    /// Pulled once per frame by the render loop.
    var frameProvider: (() -> VisualFrameData)?

    private var palette: Palette
    private var paletteName: String

    override init(frame frameRect: NSRect) {
        paletteName = Settings.shared.paletteName
        palette = PaletteLibrary.palette(named: paletteName)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true

    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    /// True while the last frame drawn was completely flat, so a second flat frame can be skipped.
    private var lastFrameWasSilent = false

    /// Called by the render loop; redraws only when there is something new to show.
    ///
    /// Redisplay is the expensive part (measured per-frame, not per-pixel), so a frame that would look
    /// identical to the previous one is skipped entirely. That covers quiet passages and the few
    /// seconds the visualiser lingers after the music stops.
    func refresh() {
        // Picking up a palette change costs a dictionary lookup, so only do it when the name moves.
        let currentName = Settings.shared.paletteName
        if currentName != paletteName {
            paletteName = currentName
            palette = PaletteLibrary.palette(named: currentName)
            needsDisplay = true
            return
        }

        let data = frameProvider?() ?? emptyVisualFrameData
        let silent = (data.levels.max() ?? 0) < 0.004
            && max(data.vu.left, data.vu.right) < 0.004
            && (data.waveform.map { abs($0) }.max() ?? 0) < 0.002
        if silent && lastFrameWasSilent { return }
        lastFrameWasSilent = silent
        needsDisplay = true
    }

    /// Logged once per presentation: the width AppKit actually gives us on the Touch Bar may not be
    /// the width we asked for, and anything drawn past it is silently clipped.
    private var loggedBounds = NSRect.zero

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if bounds != loggedBounds {
            loggedBounds = bounds
            Log.info("visualizer", "view bounds \(Int(bounds.width)) x \(Int(bounds.height)) pt "
                                 + "(asked for \(Int(frame.width)) x \(Int(frame.height)))")
        }
        let data = frameProvider?() ?? emptyVisualFrameData

        // Draw into the part of the strip that is actually visible. The view is 1085 pt wide, but the
        // Touch Bar clips the right-hand end; drawing to the full width silently loses the top
        // frequency bars, the end of the right meter, and any peak marker near full scale.
        let visible = CGRect(x: 0, y: 0,
                             width: min(bounds.width, Settings.shared.usableWidth),
                             height: bounds.height)
        if visible.width < bounds.width {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)
        }
        let frame = VisualFrame(levels: data.levels,
                                waveform: data.waveform,
                                vu: data.vu,
                                palette: palette,
                                bounds: visible)
        VisualRenderer.draw(style, frame, in: context)
    }
}
