import CoreGraphics
import Foundation

/// One recorded path command (actions/Move, Line, Quad, Close).
enum PathAction: Hashable {
    case move(Double, Double)
    case line(Double, Double)
    case quad(Double, Double, Double, Double)
    case close

    /// Action.perform(writer): the SVG path data token(s).
    var svg: String {
        func n(_ v: Double) -> String { "\(Float(v))" }
        switch self {
        case .move(let x, let y): return "M\(n(x)),\(n(y))"
        case .line(let x, let y): return "L\(n(x)),\(n(y))"
        case .quad(let x1, let y1, let x2, let y2): return "Q\(n(x1)),\(n(y1)) \(n(x2)),\(n(y2))"
        case .close: return "Z"
        }
    }
}

/// MyPath: a path that remembers its commands so it can be written to SVG.
struct MyPath: Hashable {
    private(set) var actions: [PathAction] = []

    var isEmpty: Bool { actions.isEmpty }

    mutating func moveTo(_ x: Double, _ y: Double) { actions.append(.move(x, y)) }
    mutating func lineTo(_ x: Double, _ y: Double) { actions.append(.line(x, y)) }
    mutating func quadTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) { actions.append(.quad(x1, y1, x2, y2)) }
    mutating func close() { actions.append(.close) }
    mutating func reset() { actions.removeAll() }

    var cgPath: CGPath {
        let p = CGMutablePath()
        for a in actions {
            switch a {
            case .move(let x, let y): p.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y):
                if p.isEmpty { p.move(to: CGPoint(x: x, y: y)) }
                p.addLine(to: CGPoint(x: x, y: y))
            case .quad(let x1, let y1, let x2, let y2):
                if p.isEmpty { p.move(to: CGPoint(x: x1, y: y1)) }
                p.addQuadCurve(to: CGPoint(x: x2, y: y2), control: CGPoint(x: x1, y: y1))
            case .close: if !p.isEmpty { p.closeSubpath() }
            }
        }
        return p
    }

    var svgData: String { actions.map(\.svg).joined(separator: " ") }

    /// MyPath.readPathData(): "M x,y", "L x,y", "Q x1,y1 x2,y2" and "Z" tokens.
    init(pathData: String) throws {
        let tokens = pathData.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func xy(_ s: Substring) throws -> (Double, Double) {
            let parts = s.split(separator: ",")
            guard parts.count >= 2, let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { throw SvgError.invalid }
            return (x, y)
        }
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            switch t.first {
            case "M": let (x, y) = try xy(t.dropFirst()); moveTo(x, y)
            case "L": let (x, y) = try xy(t.dropFirst()); lineTo(x, y)
            case "Z", "z": close()
            case "Q":
                guard i + 1 < tokens.count else { throw SvgError.invalid }
                let (x1, y1) = try xy(t.dropFirst())
                let (x2, y2) = try xy(Substring(tokens[i + 1]))
                quadTo(x1, y1, x2, y2)
                i += 1
            default: break
            }
            i += 1
        }
    }

    init() {}

    /// A CGPath (e.g. a bucket fill outline) as move/line/quad/close commands; cubic
    /// segments are flattened, like upstream approximates fill outlines to polygons.
    init(_ path: CGPath) {
        var acts: [PathAction] = []
        var last = CGPoint.zero
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                last = e.points[0]; acts.append(.move(last.x, last.y))
            case .addLineToPoint:
                last = e.points[0]; acts.append(.line(last.x, last.y))
            case .addQuadCurveToPoint:
                acts.append(.quad(e.points[0].x, e.points[0].y, e.points[1].x, e.points[1].y)); last = e.points[1]
            case .addCurveToPoint:
                let p0 = last, p1 = e.points[0], p2 = e.points[1], p3 = e.points[2]
                let steps = 8
                for s in 1...steps {
                    let t = Double(s) / Double(steps), u = 1 - t
                    let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
                    let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
                    acts.append(.line(x, y))
                }
                last = p3
            case .closeSubpath: acts.append(.close)
            @unknown default: break
            }
        }
        actions = acts
    }
}

/// PaintOptions.
struct PaintOptions: Hashable {
    var color: UInt32 = 0xFF000000
    var strokeWidth: Double = 5
    var isEraser = false
    var isFill = false
}

/// One entry of the drawing history (MyCanvas.mOperations), with its CGPath built once.
final class Operation: Hashable {
    let path: MyPath
    let options: PaintOptions
    let cgPath: CGPath

    init(path: MyPath, options: PaintOptions) {
        self.path = path
        self.options = options
        cgPath = path.cgPath
    }

    static func == (a: Operation, b: Operation) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

enum SvgError: Error { case invalid }
