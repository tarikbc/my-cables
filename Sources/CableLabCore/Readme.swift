import Foundation

/// Builds the cable map and writes it into README.md between two marker comments.
public enum Readme {
    public static let start = "<!-- cables:start -->"
    public static let end = "<!-- cables:end -->"

    public struct Column: Hashable, Sendable {
        public let endpoint: String
        public let kind: String

        public var title: String { "\(device) \(Readme.words(kind).joined(separator: " / "))" }
        /// A shorter device name for headings ("Samsung PSSD T7 Shield" -> "Samsung T7 Shield").
        public var device: String { Readme.shortDevice(endpoint) }
    }

    public static func shortDevice(_ label: String) -> String {
        label.replacingOccurrences(of: "PSSD ", with: "")
    }

    public static func words(_ kind: String) -> [String] {
        kind == "adb" ? ["push", "pull"] : ["write", "read"]
    }

    public static func verdict(_ cable: Cable) -> String {
        guard !cable.results.isEmpty else { return "Not tested yet" }
        let top = cable.bestLink ?? 0
        if top <= 480_000_000 { return "USB 2.0 only. Charging and slow data." }
        if top < 10_000_000_000 { return "\(USBLink.short(top)) data." }
        return "Full \(USBLink.short(top)) data."
    }

    /// Best cable first. See Ranking for the rules.
    public static func sorted(_ cables: [Cable]) -> [Cable] {
        Ranking.ranked(cables)
    }

    public static func columns(_ cables: [Cable]) -> [Column] {
        var seen: [Column] = []
        for cable in cables {
            for r in cable.results {
                let col = Column(endpoint: r.endpoint, kind: r.kind)
                if !seen.contains(col) { seen.append(col) }
            }
        }
        return seen
    }

    /// The run with the fastest write (or push) for one cable and one column.
    public static func best(_ cable: Cable, _ column: Column) -> CableResult? {
        cable.results
            .filter { $0.endpoint == column.endpoint && $0.kind == column.kind }
            .max { $0.writeMBps < $1.writeMBps }
    }

    /// Short e-marker text for the map, for example "USB4 Gen 3 · 240 W · about 1 m".
    public static func emarker(_ cable: Cable) -> String {
        guard let e = cable.emarker else { return "" }
        return [e.speedName, e.ratedPower, e.lengthHint].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Anker · 1 m": what tells cables apart in a drawer.
    public static func brandAndLength(_ cable: Cable) -> String {
        [cable.brand, cable.length].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func subline(_ cable: Cable) -> String {
        let text = brandAndLength(cable)
        return text.isEmpty ? "" : "<br>\(cell(text))"
    }

    public static func rated(_ cable: Cable) -> String {
        [cable.ratedData, cable.ratedPower].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func cell(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        return clean.isEmpty ? "–" : clean
    }

    static func number(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    public static func table(_ data: CableData) -> String {
        let cables = sorted(data.cables)
        let cols = columns(cables)
        var head = ["#", "Cable", "Rated", "E-marker says", "Best link"]
        head += cols.map { "\($0.title) (MB/s)" }
        head.append("Verdict")
        var lines = ["| " + head.joined(separator: " | ") + " |",
                     "|" + String(repeating: "---|", count: head.count)]
        for (index, c) in cables.enumerated() {
            var row = [
                "\(index + 1)",
                "**\(cell(c.name))**" + subline(c),
                cell(rated(c)),
                cell(emarker(c)),
                c.results.isEmpty ? "–" : USBLink.short(c.bestLink),
            ]
            for col in cols {
                if let b = best(c, col) {
                    row.append("\(number(b.writeMBps)) / \(number(b.readMBps))")
                } else {
                    row.append("–")
                }
            }
            row.append(verdict(c))
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    public enum RenderError: LocalizedError {
        case missingMarkers

        public var errorDescription: String? {
            "README.md is missing the \(Readme.start) and \(Readme.end) markers."
        }
    }

    /// Replace only the text between the markers. Returns the new README text.
    public static func render(_ data: CableData, into text: String) throws -> String {
        guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else {
            throw RenderError.missingMarkers
        }
        return String(text[..<s.lowerBound]) + start + "\n" + table(data) + "\n" + end + String(text[e.upperBound...])
    }

    public static func render(_ data: CableData, file url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let new = try render(data, into: text)
        if new != text { try new.write(to: url, atomically: true, encoding: .utf8) }
    }
}
