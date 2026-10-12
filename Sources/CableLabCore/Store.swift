import Foundation

/// One measured run of one cable against one device.
public struct CableResult: Codable, Hashable, Sendable {
    public var date: String
    public var endpoint: String
    /// "disk" (write / read) or "adb" (push / pull).
    public var kind: String
    public var linkBps: Int64?
    public var host: String
    public var bytes: Int64
    public var writeS: Double
    public var readS: Double

    public init(date: String, endpoint: String, kind: String, linkBps: Int64?, host: String,
                bytes: Int64, writeS: Double, readS: Double) {
        self.date = date
        self.endpoint = endpoint
        self.kind = kind
        self.linkBps = linkBps
        self.host = host
        self.bytes = bytes
        self.writeS = writeS
        self.readS = readS
    }

    public var writeMBps: Double { Self.rate(bytes, writeS) }
    public var readMBps: Double { Self.rate(bytes, readS) }

    /// MB/s, or 0 for a run with no bytes or no valid time (a hand-edited data file can hold anything).
    static func rate(_ bytes: Int64, _ seconds: Double) -> Double {
        guard bytes > 0, seconds.isFinite, seconds > 0 else { return 0 }
        let value = Double(bytes) / seconds / 1e6
        return value.isFinite ? value : 0
    }
}

public extension Double {
    /// Round to an Int without trapping: NaN and infinity give 0, and huge values are clamped.
    var safeRoundedInt: Int {
        guard isFinite else { return 0 }
        let r = rounded()
        if r >= Double(Int.max) { return Int.max }
        if r <= Double(Int.min) { return Int.min }
        return Int(r)
    }
}

public struct Cable: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var brand = ""
    public var ratedData = ""
    public var ratedPower = ""
    public var length = ""
    public var ends = ""
    public var looks = ""
    public var notes = ""
    /// What the cable's e-marker chip reported, when it has one.
    public var emarker: CableIdentity?
    public var results: [CableResult] = []

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var bestLink: Int64? { results.compactMap(\.linkBps).max() }
}

/// The editable text fields of a cable, without its id and results.
public struct CableFields: Equatable, Sendable {
    public var name = "", brand = "", ratedData = "", ratedPower = ""
    public var length = "", ends = "USB-C to USB-C", looks = "", notes = ""

    public init() {}

    public init(_ cable: Cable) {
        name = cable.name; brand = cable.brand; ratedData = cable.ratedData; ratedPower = cable.ratedPower
        length = cable.length; ends = cable.ends; looks = cable.looks; notes = cable.notes
    }

    func trimmed() -> CableFields {
        var f = self
        for path in [\CableFields.name, \.brand, \.ratedData, \.ratedPower, \.length, \.ends, \.looks, \.notes] {
            f[keyPath: path] = f[keyPath: path].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        f.length = Self.normalizeLength(f.length)
        return f
    }

    // MARK: Automatic name

    /// "Anker 40 Gb/s 240 W cable", built from brand and ratings.
    public var autoName: String {
        let parts = [brand, ratedData, ratedPower].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "New cable" : parts.joined(separator: " ") + " cable"
    }

    /// True when the name is one Cable Lab made, so it may keep following brand and ratings.
    public func nameIsAutomatic(before previous: CableFields) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == previous.autoName || n == autoName || n.hasPrefix("New ")
    }

    /// Call after brand or ratings change: an automatic name is rebuilt, a typed one is kept.
    public mutating func refreshAutoName(previous: CableFields) {
        if nameIsAutomatic(before: previous) { name = autoName }
    }

    /// "1M" -> "1 m", "50cm" -> "50 cm", "about 2 m" -> "2 m". Anything else stays as typed.
    public static func normalizeLength(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["about ", "approx. ", "approx ", "~"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let digits = s.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard !digits.isEmpty else { return s }
        let unit = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        let units = ["m": "m", "cm": "cm", "mm": "mm", "ft": "ft", "in": "in",
                     "meter": "m", "meters": "m", "metre": "m", "metres": "m"]
        guard let u = units[unit] else { return s }
        return "\(digits.replacingOccurrences(of: ",", with: ".")) \(u)"
    }
}

/// Cable brands that put their own USB vendor ID in the e-marker. Many cables report 0 or the chip maker
/// instead, so this only fills the brand when it is sure.
public enum CableVendors {
    static let brands: [Int: String] = [
        0x05AC: "Apple", 0x291A: "Anker", 0x050D: "Belkin", 0x04E8: "Samsung",
        0x18D1: "Google", 0x17EF: "Lenovo", 0x413C: "Dell", 0x045E: "Microsoft",
    ]

    public static func brand(for vendorID: Int) -> String? { brands[vendorID] }
}

public enum StoreError: LocalizedError, Equatable {
    case missingName
    case unknownCable(String)
    case unknownResult

    public var errorDescription: String? {
        switch self {
        case .missingName: return "A cable needs a name."
        case .unknownCable(let id): return "There is no cable with the id “\(id)”."
        case .unknownResult: return "That result does not exist."
        }
    }
}

/// The whole data file. All edits are plain value mutations, so they are easy to test.
public struct CableData: Codable, Equatable, Sendable {
    public var cables: [Cable]

    public init(cables: [Cable] = []) {
        self.cables = cables
    }

    public static func slugify(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
        var slug = ""
        var dash = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                dash = false
            } else if !dash && !slug.isEmpty {
                slug.append("-")
                dash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "cable" : slug
    }

    public func index(of id: String) -> Int? {
        cables.firstIndex { $0.id == id }
    }

    /// Create a cable (id == nil) or update one. Returns the cable id.
    @discardableResult
    public mutating func upsert(id: String?, fields: CableFields) throws -> String {
        let f = fields.trimmed()
        guard !f.name.isEmpty else { throw StoreError.missingName }
        let i: Int
        if let id {
            guard let found = index(of: id) else { throw StoreError.unknownCable(id) }
            i = found
        } else {
            let base = Self.slugify(f.name)
            let taken = Set(cables.map(\.id))
            var candidate = base, n = 2
            while taken.contains(candidate) { candidate = "\(base)-\(n)"; n += 1 }
            cables.append(Cable(id: candidate, name: f.name))
            i = cables.count - 1
        }
        cables[i].name = f.name; cables[i].brand = f.brand
        cables[i].ratedData = f.ratedData; cables[i].ratedPower = f.ratedPower
        cables[i].length = f.length; cables[i].ends = f.ends
        cables[i].looks = f.looks; cables[i].notes = f.notes
        return cables[i].id
    }

    public mutating func addResult(_ result: CableResult, to id: String) throws {
        guard let i = index(of: id) else { throw StoreError.unknownCable(id) }
        cables[i].results.append(result)
    }

    public mutating func deleteResult(at offset: Int, of id: String) throws {
        guard let i = index(of: id) else { throw StoreError.unknownCable(id) }
        guard cables[i].results.indices.contains(offset) else { throw StoreError.unknownResult }
        cables[i].results.remove(at: offset)
    }

    public mutating func deleteCable(_ id: String) {
        cables.removeAll { $0.id == id }
    }

    /// The saved cable whose e-marker matches, if any. Same model cables match the same entry.
    public func cable(matching identity: CableIdentity) -> Cable? {
        cables.first { $0.emarker?.fingerprint == identity.fingerprint }
    }

    /// Store an e-marker on a cable and fill its empty rated fields from it.
    public mutating func link(_ identity: CableIdentity, to id: String) throws {
        guard let i = index(of: id) else { throw StoreError.unknownCable(id) }
        cables[i].emarker = identity
        if cables[i].ratedData.isEmpty { cables[i].ratedData = identity.ratedData }
        if cables[i].ratedPower.isEmpty { cables[i].ratedPower = identity.ratedPower }
        if cables[i].length.isEmpty { cables[i].length = identity.lengthValue }
    }

    /// Add a cable for an e-marker nobody has seen yet, with everything the chip tells us filled in and an
    /// automatic name. The user only types the brand when the chip does not give it. Returns the new id.
    public mutating func addDetected(_ identity: CableIdentity, date: String) throws -> String {
        var fields = CableFields()
        fields.brand = CableVendors.brand(for: identity.vendorId) ?? ""
        fields.ratedData = identity.ratedData
        fields.ratedPower = identity.ratedPower
        fields.length = identity.lengthValue
        fields.name = fields.autoName
        let id = try upsert(id: nil, fields: fields)
        try link(identity, to: id)
        return id
    }

    // MARK: File I/O

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static func load(from url: URL) throws -> CableData {
        guard FileManager.default.fileExists(atPath: url.path) else { return CableData() }
        return try decoder.decode(CableData.self, from: Data(contentsOf: url))
    }

    public func encoded() throws -> Data {
        var data = try Self.encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}
