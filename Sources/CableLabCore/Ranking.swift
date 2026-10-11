import Foundation

/// Orders cables best first. The rules, in order:
/// 1. the fastest link the cable really negotiated,
/// 2. what it can carry (e-marker speed class, else the rated speed typed in),
/// 3. power (e-marker watts, else the rated watts typed in),
/// 4. measured speed, scored against the best cable on the same device (a Thor run never competes with a T7 run),
/// 5. name.
public enum Ranking {
    /// "40 Gb/s", "10Gbps", "480 Mb/s" -> bits per second.
    public static func dataRate(_ text: String) -> Int64? {
        guard let (value, rest) = leadingNumber(text) else { return nil }
        let unit = rest.lowercased()
        if unit.hasPrefix("g") { return Int64(value * 1e9) }
        if unit.hasPrefix("m") { return Int64(value * 1e6) }
        return nil
    }

    /// "240 W", "100W" -> watts.
    public static func watts(_ text: String) -> Int? {
        guard let (value, rest) = leadingNumber(text), rest.lowercased().hasPrefix("w") else { return nil }
        return Int(value)
    }

    static func leadingNumber(_ text: String) -> (Double, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard let value = Double(digits.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (value, trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces))
    }

    public static func capabilityBps(_ cable: Cable) -> Int64 {
        cable.emarker.flatMap { dataRate($0.ratedData) } ?? dataRate(cable.ratedData) ?? 0
    }

    public static func power(_ cable: Cable) -> Int {
        cable.emarker.flatMap { watts($0.ratedPower) } ?? watts(cable.ratedPower) ?? 0
    }

    static func average(_ r: CableResult) -> Double { (r.writeMBps + r.readMBps) / 2 }

    /// 0...1: the cable's best runs, each divided by the best run any cable made on that device, averaged.
    public static func measuredScore(_ cable: Cable, among cables: [Cable]) -> Double {
        let scores = Readme.columns([cable]).compactMap { col -> Double? in
            guard let mine = Readme.best(cable, col).map(average),
                  let top = cables.compactMap({ Readme.best($0, col).map(average) }).max(), top > 0 else { return nil }
            return mine / top
        }
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }

    public static func ranked(_ cables: [Cable]) -> [Cable] {
        let keyed = cables.map { c in
            (cable: c, link: c.bestLink ?? 0, cap: capabilityBps(c), watts: power(c),
             score: measuredScore(c, among: cables))
        }
        return keyed.sorted { a, b in
            if a.link != b.link { return a.link > b.link }
            if a.cap != b.cap { return a.cap > b.cap }
            if a.watts != b.watts { return a.watts > b.watts }
            if a.score != b.score { return a.score > b.score }
            return a.cable.name.lowercased() < b.cable.name.lowercased()
        }.map(\.cable)
    }
}
