import SwiftUI
import UIKit

/// The MyCanvas view: renders a PaintCanvas and turns touches into strokes, fills,
/// eyedropper picks and two-finger zooming/moving (onTouchEvent + ScaleGestureDetector).
struct CanvasRepresentable: UIViewRepresentable {
    let canvas: PaintCanvas
    var eyeDropper: ((UInt32) -> Void)?

    func makeUIView(context: Context) -> CanvasUIView {
        let v = CanvasUIView()
        v.canvas = canvas
        return v
    }

    func updateUIView(_ v: CanvasUIView, context: Context) {
        v.canvas = canvas
        v.eyeDropper = eyeDropper
    }
}

final class CanvasUIView: UIView {
    var canvas: PaintCanvas? {
        didSet {
            guard canvas !== oldValue else { return }
            canvas?.onInvalidate = { [weak self] in self?.setNeedsDisplay() }
            setNeedsDisplay()
        }
    }
    var eyeDropper: ((UInt32) -> Void)?

    private static let touchSlop: CGFloat = 8

    private var active: [UITouch] = []
    private var startPoint = CGPoint.zero
    private var wasMultitouch = false
    private var ignoreTouches = false
    private var wasScaling = false
    private var wasMoving = false
    private var lastCentroid = CGPoint.zero
    private var lastDistance: CGFloat = 0

    private var cache: (revision: Int, size: CGSize, image: CGImage)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if canvas?.viewSize != bounds.size { canvas?.viewSize = bounds.size }
    }

    // MARK: drawing

    override func draw(_ rect: CGRect) {
        guard let canvas, let ctx = UIGraphicsGetCurrentContext() else { return }
        if cache?.revision != canvas.revision || cache?.size != bounds.size {
            let format = UIGraphicsImageRendererFormat()
            format.scale = window?.screen.scale ?? UIScreen.main.scale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { r in
                canvas.render(in: r.cgContext, includePending: false)
            }
            cache = image.cgImage.map { (canvas.revision, bounds.size, $0) }
        }
        if let cache {
            ctx.drawUpright(cache.image, in: bounds)
        }
        canvas.renderPending(in: ctx, transformed: true)
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let canvas else { return }
        active.append(contentsOf: touches)
        if let eyeDropper {
            pick(eyeDropper)
            return
        }
        if active.count == 1 {
            let p = touches.first!.location(in: self)
            wasMultitouch = false
            wasScaling = false
            wasMoving = false
            ignoreTouches = false
            startPoint = p
            canvas.actionDown(canvas.toCanvas(p))
        } else if canvas.allowMovingZooming {
            if !wasMultitouch {
                wasMultitouch = true
                // mTouchSloppedBeforeMultitouch: a stroke that barely started is the first finger of a pinch.
                if let first = active.first, first.location(in: self).distance(to: startPoint) <= Self.touchSlop {
                    canvas.resetPath()
                }
            }
            lastCentroid = centroid()
            lastDistance = spread()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let canvas else { return }
        if let eyeDropper {
            pick(eyeDropper)
            return
        }
        if ignoreTouches { return }
        if active.count == 1 || !canvas.allowMovingZooming {
            if !canvas.isBucketFillOn && (!canvas.allowMovingZooming || !wasMultitouch), let first = active.first {
                canvas.actionMove(canvas.toCanvas(first.location(in: self)))
            }
            return
        }
        let c = centroid(), d = spread()
        if lastDistance > 0, d > 0 {
            if !wasScaling && abs(d / lastDistance - 1) > 0.001 { canvas.resetPath() }
            if canvas.zoom(by: d / lastDistance) { wasScaling = true }
        }
        canvas.pan(by: CGPoint(x: c.x - lastCentroid.x, y: c.y - lastCentroid.y))
        if c != lastCentroid { wasMoving = true }
        lastCentroid = c
        lastDistance = d
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let canvas else { return }
        let wasActive = active.count
        active.removeAll { touches.contains($0) }
        if eyeDropper != nil {
            return
        }
        if active.isEmpty {
            defer { ignoreTouches = false; wasScaling = false; wasMoving = false }
            if ignoreTouches { return }
            let p = touches.first!.location(in: self)
            let inside = bounds.contains(p)
            canvas.actionUp(forceLineDraw: false, wasMultitouch: wasMultitouch,
                            fillPoint: !wasMultitouch && inside ? canvas.toCanvas(p) : nil)
        } else if wasActive >= 2 && canvas.allowMovingZooming && !ignoreTouches {
            // ACTION_POINTER_UP: the gesture ends here; the remaining finger is ignored.
            ignoreTouches = true
            canvas.actionUp(forceLineDraw: !wasScaling && !wasMoving, wasMultitouch: true, fillPoint: nil)
        } else {
            lastCentroid = centroid()
            lastDistance = spread()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        active.removeAll { touches.contains($0) }
        ignoreTouches = false
        wasMultitouch = false
        wasScaling = false
        wasMoving = false
        canvas?.resetPath()
    }

    private func pick(_ callback: (UInt32) -> Void) {
        guard let p = active.last?.location(in: self), let color = canvas?.colorAt(viewPoint: p) else { return }
        callback(color)
    }

    private func centroid() -> CGPoint {
        let pts = active.prefix(2).map { $0.location(in: self) }
        guard !pts.isEmpty else { return .zero }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    private func spread() -> CGFloat {
        let pts = active.prefix(2).map { $0.location(in: self) }
        return pts.count == 2 ? pts[0].distance(to: pts[1]) : 0
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}
