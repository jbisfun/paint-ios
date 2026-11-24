import CoreGraphics
import Foundation

/// models/Svg.kt: the drawing as an SVG file, and back.
enum Svg {
    /// writeSvg(): the history as plain paths over a background rect, in canvas coordinates.
    /// Eraser strokes are written in the background color and tagged so they load back as eraser.
    static func write(operations: [Operation], backgroundColor: UInt32, width: Int, height: Int, viewport: CGRect) -> String {
        func n(_ v: CGFloat) -> String { "\(Float(v))" }
        var s = "<svg width=\"\(width)\" height=\"\(height)\" "
        s += "viewBox=\"\(n(viewport.minX)) \(n(viewport.minY)) \(n(viewport.width)) \(n(viewport.height))\" "
        s += "xmlns=\"http://www.w3.org/2000/svg\">"
        s += "<rect x=\"\(n(viewport.minX))\" y=\"\(n(viewport.minY))\" "
        s += "width=\"\(n(viewport.width))\" height=\"\(n(viewport.height))\" "
        s += "fill=\"\(colorString(backgroundColor))\"/>"
        for op in operations {
            let o = op.options
            s += "<path d=\"\(op.path.svgData) \""
            if o.isFill {
                s += " fill=\"\(colorString(o.color))\" fill-rule=\"evenodd\" stroke=\"none\""
            } else {
                let color = colorString(o.isEraser ? backgroundColor : o.color)
                s += " fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(Float(o.strokeWidth))\""
                s += " stroke-linecap=\"round\" stroke-linejoin=\"round\""
                if o.isEraser { s += " data-eraser=\"true\"" }
            }
            s += "/>"
        }
        s += "</svg>"
        return s
    }

    static func colorString(_ color: UInt32) -> String { String(format: "#%06x", color & 0xFFFFFF) }

    struct Drawing {
        var backgroundColor: UInt32 = 0xFFFFFFFF
        var viewport = CGRect.zero
        var paths: [(MyPath, PaintOptions)] = []
    }

    /// parseSvg(): reads files written by this app and by Fossify Paint for Android.
    static func parse(_ data: Data) throws -> Drawing {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), delegate.error == nil else { throw delegate.error ?? SvgError.invalid }
        let v = delegate.drawing.viewport
        guard [v.minX, v.minY, v.width, v.height].allSatisfy(\.isFinite), v.width > 0, v.height > 0 else { throw SvgError.invalid }
        return delegate.drawing
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var drawing = Drawing()
        var error: Error?
        private var stack: [String] = []
        private var historyGroup = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String] = [:]) {
            defer { stack.append(name) }
            do {
                switch (stack, name) {
                case ([], "svg"):
                    if let viewBox = a["viewBox"] {
                        let v = viewBox.split(whereSeparator: { $0 == " " || $0 == "," || $0.isWhitespace }).compactMap { Double($0) }
                        guard v.count == 4 else { throw SvgError.invalid }
                        drawing.viewport = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                    } else {
                        guard let w = a["width"].flatMap(Double.init), let h = a["height"].flatMap(Double.init) else { throw SvgError.invalid }
                        drawing.viewport = CGRect(x: 0, y: 0, width: w, height: h)
                    }
                case (["svg"], "rect"):
                    if let fill = a["fill"], let c = parseColor(fill) { drawing.backgroundColor = c }
                case (["svg"], "path"):
                    try readPath(a)
                case (["svg", "defs"], "g"):
                    historyGroup = a["id"] == "paint-history"
                case (["svg", "defs", "g"], "path"):
                    if historyGroup { try readPath(a) }
                default: break
                }
            } catch let e {
                error = e
                parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        private func readPath(_ a: [String: String]) throws {
            let fill = a["fill"] ?? "none"
            let stroke = a["stroke"] ?? "none"
            let isFill = fill != "none"
            let isEraser = !isFill && (stroke == "none" || a["data-eraser"] == "true")
            let color: UInt32 = isEraser ? 0 : (parseColor(isFill ? fill : stroke) ?? 0xFF000000)
            // Android's inverse fills start with the viewport rectangle; with the even-odd
            // rule that frame plus the contours draws the same region.
            let path = try MyPath(pathData: a["d"] ?? "")
            let width = a["stroke-width"].flatMap(Double.init) ?? 0
            drawing.paths.append((path, PaintOptions(color: color, strokeWidth: width, isEraser: isEraser, isFill: isFill)))
        }
    }

    /// Color.parseColor(): #RRGGBB, #AARRGGBB and the basic color names.
    static func parseColor(_ s: String) -> UInt32? {
        let names: [String: UInt32] = ["black": 0xFF000000, "white": 0xFFFFFFFF, "red": 0xFFFF0000, "green": 0xFF00FF00,
                                       "blue": 0xFF0000FF, "yellow": 0xFFFFFF00, "cyan": 0xFF00FFFF, "magenta": 0xFFFF00FF,
                                       "gray": 0xFF888888, "grey": 0xFF888888]
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let c = names[t] { return c }
        guard t.hasPrefix("#"), let v = UInt32(t.dropFirst(), radix: 16) else { return nil }
        switch t.count {
        case 7: return 0xFF000000 | v
        case 9: return v
        case 4:
            let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
            return 0xFF000000 | (r * 17) << 16 | (g * 17) << 8 | b * 17
        default: return nil
        }
    }
}
