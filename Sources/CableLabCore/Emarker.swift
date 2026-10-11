import Foundation
import IOKit

/// What a cable says about itself through its e-marker chip (USB Power Delivery Discover Identity on SOP').
///
/// Only e-marked cables answer: every 5 A cable and every cable faster than USB 2.0 should have one.
/// Two cables of the same model give the same answer, so this identifies a model, not one cable.
public struct CableIdentity: Codable, Hashable, Sendable {
    public var vendorId: Int
    public var productId: Int
    /// "passive" or "active".
    public var productType: String
    /// USB Highest Speed field: 0 USB 2.0, 1 USB 3.2 Gen 1, 2 Gen 2, 3 USB4 Gen 3, 4 USB4 Gen 4.
    public var speedCode: Int
    public var currentA: Int?
    public var maxVolts: Int
    public var epr: Bool
    /// Cable Latency field: 1 is under 10 ns (about 1 m), each step adds about 1 m.
    public var latencyCode: Int
    public var hwVersion: Int
    public var fwVersion: Int
    /// The raw Discover Identity VDOs, as big-endian hex words.
    public var vdos: [String]

    public var fingerprint: String { vdos.joined(separator: "-") }

    public var speedName: String {
        switch speedCode {
        case 0: return "USB 2.0"
        case 1: return "USB 3.2 Gen 1"
        case 2: return "USB 3.2 Gen 2"
        case 3: return "USB4 Gen 3"
        case 4: return "USB4 Gen 4"
        default: return "unknown speed"
        }
    }

    /// The data rate printed on the box for this speed class.
    public var ratedData: String {
        switch speedCode {
        case 0: return "480 Mb/s"
        case 1: return "5 Gb/s"
        case 2: return "10 Gb/s"
        case 3: return "40 Gb/s"
        case 4: return "80 Gb/s"
        default: return ""
        }
    }

    public var ratedPower: String {
        guard let currentA else { return "" }
        let volts = epr || maxVolts >= 50 ? 48 : min(maxVolts, 20)
        return "\(volts * currentA) W"
    }

    /// The length for the Length field: "1 m", "3 m", "over 7 m".
    public var lengthValue: String {
        switch latencyCode {
        case 1...7: return "\(latencyCode) m"
        case 8: return "over 7 m"
        default: return ""
        }
    }

    public var lengthHint: String {
        switch latencyCode {
        case 1: return "about 1 m"
        case 2...7: return "about \(latencyCode) m"
        case 8: return "over 7 m"
        default: return ""
        }
    }

    public var summary: String {
        var parts = ["\(speedName) (\(ratedData))"]
        if !ratedPower.isEmpty { parts.append("\(ratedPower), \(currentA ?? 0) A") }
        if !lengthHint.isEmpty { parts.append(lengthHint) }
        parts.append(productType)
        return parts.joined(separator: " · ")
    }

    static func word(_ data: Data) -> UInt32 {
        data.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    /// Decode the "Metadata" dictionary of an IOPortTransportComponentCCUSBPDSOPp (SOP') node.
    public static func decode(metadata: [String: Any]) -> CableIdentity? {
        guard let raw = metadata["VDOs"] as? [Data], raw.count >= 4 else { return nil }
        let words = raw.map(word)
        let header = words[0], cable = words[3]
        let type = Int((header >> 27) & 0x7)
        guard type == 3 || type == 4 else { return nil }
        let current: Int?
        switch (cable >> 5) & 0x3 {
        case 1: current = 3
        case 2: current = 5
        default: current = nil
        }
        return CableIdentity(
            vendorId: (metadata["Vendor ID"] as? NSNumber)?.intValue ?? Int(header & 0xFFFF),
            productId: (metadata["Product ID"] as? NSNumber)?.intValue ?? Int(words[2] >> 16),
            productType: type == 3 ? "passive" : "active",
            speedCode: Int(cable & 0x7),
            currentA: current,
            maxVolts: [20, 30, 40, 50][Int((cable >> 9) & 0x3)],
            epr: (cable >> 17) & 0x1 == 1,
            latencyCode: Int((cable >> 13) & 0xF),
            hwVersion: Int((cable >> 28) & 0xF),
            fwVersion: Int((cable >> 24) & 0xF),
            vdos: words.map { String(format: "%08x", $0) })
    }
}

/// One USB-C port of this Mac, with the cable plugged into it when the cable has an e-marker.
public struct USBCPort: Codable, Hashable, Sendable, Identifiable {
    public var number: Int
    public var connected: Bool
    /// Changes on every new plug-in. Used to notice a new connection.
    public var connectionId: String
    public var transports: [String]
    /// The device on the other end, when it says (for example "iPad").
    public var partner: String?
    public var cable: CableIdentity?

    public var id: Int { number }
}

extension Discovery {
    /// USB-C ports, from the AppleHPM port nodes. Each one lists the SOP' (cable) identity below it.
    public static func ports() -> [USBCPort] {
        let matching = ["IOPropertyMatch": ["PortTypeDescription": "USB-C"]] as CFDictionary
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [USBCPort] = []
        while case let port = IOIteratorNext(iterator), port != 0 {
            defer { IOObjectRelease(port) }
            let p = properties(port)
            guard let number = (p["PortNumber"] as? NSNumber)?.intValue else { continue }
            let connected = (p["ConnectionActive"] as? NSNumber)?.boolValue ?? false
            let count = (p["ConnectionCount"] as? NSNumber)?.intValue ?? 0
            found.append(USBCPort(
                number: number,
                connected: connected,
                connectionId: "\(number):" + ((p["ConnectionUUID"] as? String) ?? "\(count)"),
                transports: p["TransportsActive"] as? [String] ?? [],
                partner: connected ? p["SOPMfgString"] as? String : nil,
                cable: connected ? cableIdentity(below: port) : nil))
        }
        return found.sorted { $0.number < $1.number }
    }

    static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return props?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    static func cableIdentity(below port: io_registry_entry_t) -> CableIdentity? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(port, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(child, &name)
            guard String(cString: name) == "SOP'" else { continue }
            if let metadata = properties(child)["Metadata"] as? [String: Any],
               let identity = CableIdentity.decode(metadata: metadata) {
                return identity
            }
        }
        return nil
    }
}
