import Foundation

/// Names and tiers for negotiated USB link speeds, in bits per second.
public enum USBLink {
    /// IOUSBHostDevice "Device Speed" codes.
    public static let speedCodeBps: [Int: Int64] = [
        0: 1_500_000,
        1: 12_000_000,
        2: 480_000_000,
        3: 5_000_000_000,
        4: 10_000_000_000,
        5: 20_000_000_000,
    ]

    static let names: [Int64: String] = [
        1_500_000: "USB 1.0 Low Speed (1.5 Mb/s)",
        12_000_000: "USB 1.1 Full Speed (12 Mb/s)",
        480_000_000: "USB 2.0 (480 Mb/s)",
        5_000_000_000: "USB 3.2 Gen 1 (5 Gb/s)",
        10_000_000_000: "USB 3.2 Gen 2 (10 Gb/s)",
        20_000_000_000: "USB 3.2 Gen 2x2 (20 Gb/s)",
    ]

    public enum Tier: Sendable { case unknown, slow, mid, fast }

    public static func name(_ bps: Int64?) -> String {
        guard let bps, bps > 0 else { return "unknown" }
        return names[bps] ?? short(bps)
    }

    public static func short(_ bps: Int64?) -> String {
        guard let bps, bps > 0 else { return "?" }
        if bps >= 1_000_000_000 { return "\(format(Double(bps) / 1e9)) Gb/s" }
        return "\(format(Double(bps) / 1e6)) Mb/s"
    }

    public static func tier(_ bps: Int64?) -> Tier {
        guard let bps, bps > 0 else { return .unknown }
        if bps <= 480_000_000 { return .slow }
        if bps < 10_000_000_000 { return .mid }
        return .fast
    }

    static func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
