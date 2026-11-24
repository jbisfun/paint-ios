import CoreGraphics
import Foundation
import UIKit

/// Everything a render or a fill needs, detached from the live canvas (DrawingRenderer.Snapshot).
struct DrawingSnapshot: @unchecked Sendable {
    var operations: [Operation]
    var backgroundColor: UInt32
    var image: CGImage?
    var imageRect: CGRect
}

extension CGColor {
    static func argb(_ c: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((c >> 16) & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255,
                blue: CGFloat(c & 0xFF) / 255, alpha: CGFloat((c >> 24) & 0xFF) / 255)
    }
}

extension CGContext {
    /// Draws an image into a top-left-origin context without flipping it.
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: 0, y: rect.minY * 2 + rect.height)
        scaleBy(x: 1, y: -1)
        draw(image, in: rect)
        restoreGState()
    }

    /// PaintOptions.applyTo() + drawPath(): strokes and fills in history order.
    func draw(_ op: Operation, backgroundColor: UInt32, antialias: Bool = true) {
        draw(op.cgPath, op.options, backgroundColor: backgroundColor, antialias: antialias)
    }

    func draw(_ path: CGPath, _ o: PaintOptions, backgroundColor: UInt32, antialias: Bool = true) {
        let color = CGColor.argb(o.isEraser ? backgroundColor : o.color)
        setShouldAntialias(antialias)
        addPath(path)
        if o.isFill {
            setFillColor(color)
            fillPath(using: .evenOdd)
        } else {
            setStrokeColor(color)
            setLineWidth(o.strokeWidth)
            setLineCap(.round)
            setLineJoin(.round)
            strokePath()
        }
    }

    /// The drawing in canvas coordinates (background, loaded image, history).
    func draw(_ s: DrawingSnapshot, antialias: Bool = true) {
        if let image = s.image { drawUpright(image, in: s.imageRect) }
        for op in s.operations { draw(op, backgroundColor: s.backgroundColor, antialias: antialias) }
    }
}

/// helpers/BucketFill.kt + FillRegion.kt: the fill is a vector region (the connected
/// area of the tapped color), computed with CoreGraphics path boolean operations
/// instead of Clipper2. Upstream's "inverse" (unbounded) regions are a huge frame here.
enum BucketFill {
    static let frame = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
    private static let bitmapTolerance = 24

    static func fill(_ s: DrawingSnapshot, at p: CGPoint, color: UInt32) -> MyPath? {
        let target = sampleColor(s, at: p)
        if target == color { return nil }

        var region = bitmapRegion(s, target: target)
        var pending: [CGPath] = []
        var pendingAdd = false
        func flush() {
            guard let shape = union(pending) else { return }
            region = pendingAdd ? region.union(shape, using: .winding) : region.subtracting(shape, using: .winding)
            pending.removeAll()
        }
        for op in s.operations {
            let o = op.options
            let shape = o.isFill
                ? op.cgPath.normalized(using: .evenOdd)
                : op.cgPath.copy(strokingWithWidth: o.strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
                    .normalized(using: .winding)
            let add = sameColor(target, o.isEraser ? s.backgroundColor : o.color)
            if pendingAdd != add { flush() }
            pendingAdd = add
            pending.append(shape)
        }
        flush()

        guard let component = region.componentsSeparated(using: .winding).first(where: { $0.contains(p, using: .winding) })
        else { return nil }
        return MyPath(component)
    }

    /// Pairwise union, so overlapping strokes with holes (loops) stay correct.
    private static func union(_ paths: [CGPath]) -> CGPath? {
        var level = paths
        while level.count > 1 {
            var next: [CGPath] = []
            var i = 0
            while i < level.count {
                next.append(i + 1 < level.count ? level[i].union(level[i + 1], using: .winding) : level[i])
                i += 2
            }
            level = next
        }
        return level.first
    }

    /// sampleColor(): the aliased color under the tapped point.
    static func sampleColor(_ s: DrawingSnapshot, at p: CGPoint) -> UInt32 {
        var px = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor.argb(s.backgroundColor))
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0.5 - p.x, y: 0.5 - p.y)
            ctx.interpolationQuality = .none
            ctx.draw(s, antialias: false)
        }
        return 0xFF000000 | UInt32(px[0]) << 16 | UInt32(px[1]) << 8 | UInt32(px[2])
    }

    private static func sameColor(_ a: UInt32, _ b: UInt32, tolerance: Int = 1) -> Bool {
        func ch(_ c: UInt32, _ shift: UInt32) -> Int { Int((c >> shift) & 0xFF) }
        return abs(ch(a, 16) - ch(b, 16)) <= tolerance && abs(ch(a, 8) - ch(b, 8)) <= tolerance && abs(ch(a, 0) - ch(b, 0)) <= tolerance
    }

    /// bitmapRegion(): where the loaded image (over the background) has the target color.
    private static func bitmapRegion(_ s: DrawingSnapshot, target: UInt32) -> CGPath {
        guard let image = s.image else {
            return sameColor(target, s.backgroundColor) ? CGPath(rect: frame, transform: nil) : CGMutablePath()
        }
        let inverse = sameColor(target, s.backgroundColor, tolerance: bitmapTolerance)
        let w = max(1, Int(s.imageRect.width.rounded())), h = max(1, Int(s.imageRect.height.rounded()))
        var pixels = [UInt32](repeating: 0, count: w * h)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.setFillColor(CGColor.argb(s.backgroundColor))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // CGContext rows start at the top in memory, matching Android's getPixels().
        let included = pixels.map { sameColor($0 | 0xFF000000, target, tolerance: bitmapTolerance) != inverse }
        let outline = bitmapOutline(edges: bitmapEdges(included, w, h), stride: w + 1, origin: s.imageRect.origin, inverse: inverse)
        return inverse ? CGPath(rect: frame, transform: nil).subtracting(outline, using: .evenOdd) : outline.normalized(using: .evenOdd)
    }

    private static let right = 0, down = 1, left = 2, up = 3

    private static func bitmapEdges(_ included: [Bool], _ width: Int, _ height: Int) -> [UInt8] {
        let stride = width + 1
        var edges = [UInt8](repeating: 0, count: stride * (height + 1))
        func add(_ v: Int, _ d: Int) { edges[v] |= UInt8(1 << d) }
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                guard included[pixel] else { continue }
                let vertex = y * stride + x
                if y == 0 || !included[pixel - width] { add(vertex, right) }
                if x == width - 1 || !included[pixel + 1] { add(vertex + 1, down) }
                if y == height - 1 || !included[pixel + width] { add(vertex + stride + 1, left) }
                if x == 0 || !included[pixel - 1] { add(vertex + stride, up) }
            }
        }
        return edges
    }

    private static func bitmapOutline(edges e: [UInt8], stride: Int, origin: CGPoint, inverse: Bool) -> CGPath {
        let turn = inverse ? 3 : 1
        var edges = e
        let outline = CGMutablePath()
        let steps = [1, stride, -1, -stride]
        func point(_ v: Int) -> CGPoint { CGPoint(x: origin.x + CGFloat(v % stride), y: origin.y + CGFloat(v / stride)) }
        for start in edges.indices {
            while edges[start] != 0 {
                var vertex = start
                var direction = edges[start].trailingZeroBitCount
                outline.move(to: point(vertex))
                while true {
                    edges[vertex] &= ~UInt8(1 << direction)
                    let next = vertex + steps[direction]
                    if next == start {
                        outline.closeSubpath()
                        break
                    }
                    let outgoing = edges[next]
                    if outgoing == 0 { outline.closeSubpath(); break }
                    var nextDirection = (direction + turn) % 4
                    while outgoing & UInt8(1 << nextDirection) == 0 { nextDirection = (nextDirection + 4 - turn) % 4 }
                    if nextDirection != direction { outline.addLine(to: point(next)) }
                    vertex = next
                    direction = nextDirection
                }
            }
        }
        return outline
    }
}
