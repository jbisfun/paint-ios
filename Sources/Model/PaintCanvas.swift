import CoreGraphics
import Foundation
import Observation
import UIKit

/// views/MyCanvas.kt: the drawing history, undo/redo, zoom/pan state and the
/// queue of edits that waits for a running bucket fill.
@MainActor
@Observable
final class PaintCanvas {
    static let maxHistoryCount = 1000
    /// R.dimen.full_brush_size.
    static let fullBrushSize: Double = 40

    private(set) var operations: [Operation] = []
    private var undoneOperations: [Operation] = []
    private var lastOperations: [Operation] = []
    private var lastBackgroundImage: LoadedImage?

    private(set) var backgroundColor: UInt32 = 0xFFFFFFFF
    private(set) var backgroundImage: LoadedImage?

    // Brush (mPaintOptions)
    var color: UInt32 = 0xFF000000
    private(set) var strokeWidth: Double = 5
    private var brushSize: Double = 0
    var isEraserOn = false
    var isBucketFillOn = false
    var allowMovingZooming = true
    var relativeBrushSize = true { didSet { setBrushSize(brushSize) } }

    // Viewport (canvasMatrix)
    private(set) var scale: CGFloat = 1
    private(set) var pos = CGPoint.zero
    var viewSize = CGSize.zero {
        didSet {
            // doOnLayout { applyViewportBounds() } for drawings opened before the first layout.
            if let v = pendingViewport, viewSize.width > 0, viewSize.height > 0 {
                pendingViewport = nil
                applyViewportBounds(v)
            }
        }
    }
    @ObservationIgnored private var pendingViewport: CGRect?

    // The stroke being drawn
    @ObservationIgnored private(set) var currentPath = MyPath()
    @ObservationIgnored private(set) var currentCGPath = CGMutablePath()
    @ObservationIgnored private var curX: Double = 0
    @ObservationIgnored private var curY: Double = 0

    // Pending edits (mPendingEdits)
    private enum Edit {
        case stroke(Operation)
        case fill(CGPoint, UInt32)
        case action(() -> Void)
    }
    @ObservationIgnored private var pending: [Edit] = []
    private(set) var drawingInProgress = false
    private var pendingCount = 0

    /// Bumped whenever the committed drawing changes (invalidates the render cache).
    private(set) var revision = 0
    /// Set by the view to redraw.
    @ObservationIgnored var onInvalidate: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    struct LoadedImage {
        let image: CGImage
        let size: CGSize
    }

    // MARK: listener state (CanvasListener)

    var hasPendingEdits: Bool { drawingInProgress || pendingCount > 0 }
    var canUndo: Bool { !operations.isEmpty || !lastOperations.isEmpty || hasPendingEdits }
    var canRedo: Bool { !undoneOperations.isEmpty && !hasPendingEdits }
    var hasContent: Bool { backgroundImage != nil || !operations.isEmpty || hasPendingEdits }

    func getDrawingHashCode() -> Int {
        guard !operations.isEmpty else { return 0 }
        var h = Hasher()
        operations.forEach { h.combine($0) }
        if let image = backgroundImage?.image { h.combine(ObjectIdentifier(image)) }
        return h.finalize()
    }

    // MARK: transform

    func matrix() -> CGAffineTransform {
        let c = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        return CGAffineTransform(translationX: pos.x + c.x, y: pos.y + c.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -c.x, y: -c.y)
    }

    func toCanvas(_ p: CGPoint) -> CGPoint { p.applying(matrix().inverted()) }

    func viewportBounds() -> CGRect { CGRect(origin: .zero, size: viewSize).applying(matrix().inverted()) }

    func applyViewportBounds(_ b: CGRect) {
        guard b.width > 0, b.height > 0 else { return }
        guard viewSize.width > 0, viewSize.height > 0 else {
            pendingViewport = b
            return
        }
        let s = min(viewSize.width / b.width, viewSize.height / b.height)
        scale = s
        pos = CGPoint(x: (viewSize.width / 2 - b.midX) * s, y: (viewSize.height / 2 - b.midY) * s)
        setBrushSize(brushSize)
        changed()
    }

    /// ScaleListener.onScale().
    func zoom(by factor: CGFloat) -> Bool {
        let newScale = min(max(scale * factor, min(0.1, scale)), max(10, scale))
        guard newScale != scale else { return false }
        let f = newScale / scale
        scale = newScale
        pos = CGPoint(x: pos.x * f, y: pos.y * f)
        setBrushSize(brushSize)
        changed()
        return true
    }

    func pan(by d: CGPoint) {
        pos = CGPoint(x: pos.x + d.x, y: pos.y + d.y)
        changed()
    }

    // MARK: brush

    func setBrushSize(_ size: Double) {
        brushSize = size
        strokeWidth = Self.fullBrushSize * (size / 100)
        if relativeBrushSize { strokeWidth /= Double(scale) }
    }

    var currentOptions: PaintOptions { PaintOptions(color: color, strokeWidth: strokeWidth, isEraser: isEraserOn) }

    // MARK: strokes

    func actionDown(_ p: CGPoint) {
        resetPath()
        currentPath.moveTo(p.x, p.y)
        currentCGPath.move(to: p)
        curX = p.x
        curY = p.y
        onInvalidate?()
    }

    func actionMove(_ p: CGPoint) {
        guard !currentPath.isEmpty else { return }
        let mid = CGPoint(x: (p.x + curX) / 2, y: (p.y + curY) / 2)
        currentPath.quadTo(curX, curY, mid.x, mid.y)
        currentCGPath.addQuadCurve(to: mid, control: CGPoint(x: curX, y: curY))
        curX = p.x
        curY = p.y
        onInvalidate?()
    }

    func actionUp(forceLineDraw: Bool, wasMultitouch: Bool, fillPoint: CGPoint?) {
        if isBucketFillOn {
            if let fillPoint { submit(.fill(fillPoint, color)) }
        } else if (!wasMultitouch || forceLineDraw) && !currentPath.isEmpty {
            // drawADot()
            currentPath.lineTo(curX, curY)
            submit(.stroke(Operation(path: currentPath, options: currentOptions)))
        }
        resetPath()
    }

    func resetPath() {
        currentPath = MyPath()
        currentCGPath = CGMutablePath()
        onInvalidate?()
    }

    // MARK: history

    func undo() { whenDrawingReady { self.applyUndo() } }

    private func applyUndo() {
        if operations.isEmpty && !lastOperations.isEmpty {
            operations = lastOperations
            backgroundImage = lastBackgroundImage
            lastOperations = []
            return
        }
        if let last = operations.popLast() { undoneOperations.append(last) }
    }

    func redo() { whenDrawingReady { self.applyRedo() } }

    private func applyRedo() {
        if let op = undoneOperations.popLast() { record(op, clearRedo: false) }
    }

    func clearCanvas() {
        resetPath()
        whenDrawingReady { self.applyClear() }
    }

    private func applyClear() {
        lastOperations = operations
        lastBackgroundImage = backgroundImage
        backgroundImage = nil
        operations = []
        undoneOperations = []
    }

    func updateBackgroundColor(_ c: UInt32) {
        whenDrawingReady {
            self.backgroundColor = c
            self.backgroundImage = nil
        }
    }

    func setBackgroundImage(_ image: LoadedImage) {
        whenDrawingReady { self.backgroundImage = image }
    }

    /// replaceDrawing(): an opened SVG.
    func replaceDrawing(_ svg: Svg.Drawing) {
        whenDrawingReady {
            self.applyViewportBounds(svg.viewport)
            self.applyClear()
            self.backgroundColor = svg.backgroundColor
            self.backgroundImage = nil
            for (path, options) in svg.paths { self.record(Operation(path: path, options: options)) }
        }
    }

    private func record(_ op: Operation, clearRedo: Bool = true) {
        operations.append(op)
        if clearRedo { undoneOperations = [] }
        if operations.count > Self.maxHistoryCount { operations.removeFirst(operations.count - Self.maxHistoryCount) }
    }

    // MARK: edit queue

    func whenDrawingReady(_ action: @escaping () -> Void) { submit(.action(action)) }

    private func submit(_ e: Edit) {
        pending.append(e)
        pendingCount = pending.count
        process()
        changed()
    }

    private func process() {
        while !drawingInProgress, !pending.isEmpty {
            let e = pending.removeFirst()
            pendingCount = pending.count
            switch e {
            case .stroke(let op): record(op)
            case .action(let a): a()
            case .fill(let p, let c): startFill(at: p, color: c)
            }
        }
    }

    private func startFill(at p: CGPoint, color: UInt32) {
        let s = snapshot()
        drawingInProgress = true
        Task.detached(priority: .userInitiated) {
            let path = BucketFill.fill(s, at: p, color: color)
            await MainActor.run {
                if let path { self.record(Operation(path: path, options: PaintOptions(color: color, isFill: true))) }
                self.drawingInProgress = false
                self.process()
                self.changed()
            }
        }
    }

    /// Strokes submitted while a fill runs, drawn on top until they are recorded.
    var pendingStrokes: [Operation] {
        pending.compactMap { if case .stroke(let op) = $0 { return op } else { return nil } }
    }

    func snapshot() -> DrawingSnapshot {
        DrawingSnapshot(operations: operations, backgroundColor: backgroundColor, image: backgroundImage?.image, imageRect: imageRect)
    }

    /// The image is centered in the view, in canvas coordinates (drawingSnapshot().origin).
    var imageRect: CGRect {
        guard let size = backgroundImage?.size else { return .zero }
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func changed() {
        revision &+= 1
        onInvalidate?()
    }

    // MARK: rendering

    /// drawDrawing(): background, then the drawing under the canvas matrix.
    func render(in ctx: CGContext, includePending: Bool) {
        ctx.setFillColor(CGColor.argb(backgroundColor))
        ctx.fill(CGRect(origin: .zero, size: viewSize))
        ctx.saveGState()
        ctx.concatenate(matrix())
        ctx.draw(snapshot())
        if includePending { renderPending(in: ctx, transformed: false) }
        ctx.restoreGState()
    }

    func renderPending(in ctx: CGContext, transformed: Bool) {
        if transformed {
            ctx.saveGState()
            ctx.concatenate(matrix())
        }
        for op in pendingStrokes { ctx.draw(op, backgroundColor: backgroundColor) }
        if !currentPath.isEmpty { ctx.draw(currentCGPath, currentOptions, backgroundColor: backgroundColor) }
        if transformed { ctx.restoreGState() }
    }

    /// getBitmap(false): the visible canvas as an image.
    func image(scale: CGFloat = UIScreen.main.scale) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let size = CGSize(width: max(1, viewSize.width), height: max(1, viewSize.height))
        return UIGraphicsImageRenderer(size: size, format: format).image { r in
            render(in: r.cgContext, includePending: false)
        }
    }

    /// EyeDropper: the color shown at a view point.
    func colorAt(viewPoint p: CGPoint) -> UInt32? {
        guard p.x >= 1, p.y >= 1, p.x < viewSize.width, p.y < viewSize.height else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0.5 - p.x, y: 0.5 - p.y)
            render(in: ctx, includePending: true)
        }
        return 0xFF000000 | UInt32(px[0]) << 16 | UInt32(px[1]) << 8 | UInt32(px[2])
    }
}
