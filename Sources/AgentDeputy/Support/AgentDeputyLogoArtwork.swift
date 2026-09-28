import CoreGraphics
import Foundation

/// Reads only the path commands and circles used by our bundled monochrome SVG.
/// This is not a general SVG renderer; unsupported artwork fails explicitly.
struct AgentDeputyLogoArtwork {
    struct Element {
        let id: String
        let path: CGPath
        let lineWidth: CGFloat
        let isFilled: Bool
    }

    let viewBox: CGRect
    let elements: [Element]

    static func loadBundled() throws -> Self {
        guard let url = AgentDeputyResourceBundle.bundle.url(forResource: "logo-template", withExtension: "svg") else {
            throw ArtworkError.invalid("Bundled logo-template.svg is missing")
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> Self {
        let reader = SVGReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.error == nil else {
            throw reader.error ?? parser.parserError ?? ArtworkError.invalid("Malformed logo SVG")
        }
        guard let viewBox = reader.viewBox, viewBox.width > 0, viewBox.height > 0 else {
            throw ArtworkError.invalid("Logo SVG has no valid viewBox")
        }
        for id in ["outer", "inner", "mark", "circle"] {
            guard reader.elements.filter({ $0.id == id }).count == 1 else {
                throw ArtworkError.invalid("Logo SVG requires exactly one \(id) element")
            }
        }
        return Self(viewBox: viewBox, elements: reader.elements)
    }

    enum ArtworkError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return reason
            }
        }
    }

    private final class SVGReader: NSObject, XMLParserDelegate {
        var viewBox: CGRect?
        var elements: [Element] = []
        var error: Error?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            do {
                switch name {
                case "svg":
                    let scanner = Scanner(string: try attribute("viewBox", in: attributes))
                    let x = try number(scanner), y = try number(scanner)
                    let width = try number(scanner), height = try number(scanner)
                    viewBox = CGRect(x: x, y: y, width: width, height: height)
                case "path", "circle":
                    let id = try attribute("id", in: attributes)
                    let path: CGPath
                    if name == "path" {
                        path = try readPath(attribute("d", in: attributes))
                    } else {
                        let x = try number(Scanner(string: attribute("cx", in: attributes)))
                        let y = try number(Scanner(string: attribute("cy", in: attributes)))
                        let radius = try number(Scanner(string: attribute("r", in: attributes)))
                        guard radius > 0 else { throw ArtworkError.invalid("Invalid circle radius") }
                        path = CGPath(ellipseIn: CGRect(x: x - radius, y: y - radius,
                            width: radius * 2, height: radius * 2), transform: nil)
                    }
                    let width = try attributes["stroke-width"].map { try number(Scanner(string: $0)) } ?? 0
                    elements.append(Element(id: id, path: path, lineWidth: width,
                                            isFilled: attributes["fill"] != "none"))
                default: break // Accessibility metadata does not affect geometry.
                }
            } catch {
                self.error = error
                parser.abortParsing()
            }
        }

        private func attribute(_ name: String, in attributes: [String: String]) throws -> String {
            guard let value = attributes[name] else {
                throw ArtworkError.invalid("Logo SVG is missing attribute \(name)")
            }
            return value
        }

        private func number(_ scanner: Scanner) throws -> CGFloat {
            guard let value = scanner.scanDouble(), value.isFinite else {
                throw ArtworkError.invalid("Invalid number in logo SVG")
            }
            return CGFloat(value)
        }

        private func readPath(_ source: String) throws -> CGPath {
            let scanner = Scanner(string: source)
            scanner.charactersToBeSkipped = .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
            let path = CGMutablePath()
            var command: String?
            while !scanner.isAtEnd {
                if let next = scanner.scanCharacters(from: .letters) { command = next }
                if path.isEmpty && command != "M" {
                    throw ArtworkError.invalid("Logo path must begin with M")
                }
                switch command {
                case "M":
                    path.move(to: CGPoint(x: try number(scanner), y: try number(scanner)))
                    command = "L"
                case "L": path.addLine(to: CGPoint(x: try number(scanner), y: try number(scanner)))
                case "H": path.addLine(to: CGPoint(x: try number(scanner), y: path.currentPoint.y))
                case "V": path.addLine(to: CGPoint(x: path.currentPoint.x, y: try number(scanner)))
                case "C":
                    let c1 = CGPoint(x: try number(scanner), y: try number(scanner))
                    let c2 = CGPoint(x: try number(scanner), y: try number(scanner))
                    path.addCurve(to: CGPoint(x: try number(scanner), y: try number(scanner)),
                                  control1: c1, control2: c2)
                case "Z": path.closeSubpath(); command = nil
                default: throw ArtworkError.invalid("Unsupported logo path command: \(command ?? "none")")
                }
            }
            guard !path.isEmpty else { throw ArtworkError.invalid("Empty logo path") }
            return path
        }
    }
}
