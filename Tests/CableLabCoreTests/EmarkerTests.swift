@testable import CableLabCore
import XCTest

/// VDOs exactly as macOS reported them on 2026-10-11 (little-endian 4-byte words).
func metadata(_ words: [[UInt8]]) -> [String: Any] {
    ["VDOs": words.map { Data($0) }, "Vendor ID": 0, "Product ID": 0, "Product Type": 3]
}

final class EmarkerTests: XCTestCase {
    // The LTT cable on the T7: <0000601c> <00000000> <00000000> <432e0a11>.
    let ltt = metadata([[0x00, 0x00, 0x60, 0x1c], [0, 0, 0, 0], [0, 0, 0, 0], [0x43, 0x2e, 0x0a, 0x11]])
    // The iPad cable: <00006018> <00000000> <00000000> <40460a00>.
    let ipad = metadata([[0x00, 0x00, 0x60, 0x18], [0, 0, 0, 0], [0, 0, 0, 0], [0x40, 0x46, 0x0a, 0x00]])

    func testDecodesA40GbpsEPRCable() throws {
        let e = try XCTUnwrap(CableIdentity.decode(metadata: ltt))
        XCTAssertEqual(e.productType, "passive")
        XCTAssertEqual(e.speedCode, 3)
        XCTAssertEqual(e.speedName, "USB4 Gen 3")
        XCTAssertEqual(e.ratedData, "40 Gb/s")
        XCTAssertEqual(e.currentA, 5)
        XCTAssertEqual(e.maxVolts, 50)
        XCTAssertTrue(e.epr)
        XCTAssertEqual(e.ratedPower, "240 W")
        XCTAssertEqual(e.lengthHint, "about 1 m")
        XCTAssertEqual(e.vdos, ["1c600000", "00000000", "00000000", "110a2e43"])
    }

    func testDecodesAUSB2Only240WCable() throws {
        let e = try XCTUnwrap(CableIdentity.decode(metadata: ipad))
        XCTAssertEqual(e.ratedData, "480 Mb/s")
        XCTAssertEqual(e.ratedPower, "240 W")
        XCTAssertEqual(e.lengthHint, "about 2 m")
        XCTAssertNotEqual(e.fingerprint, CableIdentity.decode(metadata: ltt)?.fingerprint)
    }

    func testEPRFlagWith20VoltsIs100Watts() throws {
        // The real "Chinese 40 Gb/s" chip: <000a2043> sets EPR (bit 17) but declares 20 V max.
        let e = try XCTUnwrap(CableIdentity.decode(metadata: metadata(
            [[0x38, 0x01, 0x60, 0x18], [0x0d, 0x04, 0, 0], [0, 0, 0, 0], [0x43, 0x20, 0x0a, 0x00]])))
        XCTAssertTrue(e.epr)
        XCTAssertEqual(e.maxVolts, 20)
        XCTAssertEqual(e.ratedData, "40 Gb/s")
        XCTAssertEqual(e.ratedPower, "100 W")
    }

    func testRejectsNonCables() {
        // An ID header with product type 0 (not a cable) and too few VDOs.
        XCTAssertNil(CableIdentity.decode(metadata: metadata([[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])))
        XCTAssertNil(CableIdentity.decode(metadata: ["VDOs": [Data([0, 0, 0, 0])]]))
    }

    func testPowerFor3AAnd20V() throws {
        // Cable VDO with 3 A (bits 6..5 = 01), 20 V (bits 10..9 = 00), Gen 2 (bits 2..0 = 010).
        let word: UInt32 = (1 << 5) | 0b010 | (1 << 13)
        let bytes = (0..<4).map { UInt8((word >> (8 * $0)) & 0xFF) }
        let e = try XCTUnwrap(CableIdentity.decode(metadata: metadata([[0, 0, 0, 0x18], [0, 0, 0, 0], [0, 0, 0, 0], bytes])))
        XCTAssertEqual(e.ratedPower, "60 W")
        XCTAssertEqual(e.ratedData, "10 Gb/s")
    }

    func testLinkAndAddDetected() throws {
        let e = try XCTUnwrap(CableIdentity.decode(metadata: ltt))
        var data = CableData()
        var f = CableFields()
        f.name = "LTT"
        f.ratedPower = "240 W (box)"
        let id = try data.upsert(id: nil, fields: f)
        try data.link(e, to: id)
        XCTAssertEqual(data.cables[0].ratedData, "40 Gb/s")
        XCTAssertEqual(data.cables[0].ratedPower, "240 W (box)", "link must not overwrite what the user typed")
        XCTAssertEqual(data.cable(matching: e)?.id, id)

        let other = try XCTUnwrap(CableIdentity.decode(metadata: ipad))
        let newID = try data.addDetected(other, date: "2026-10-11")
        XCTAssertEqual(data.cable(matching: other)?.id, newID)
        XCTAssertEqual(data.cables.last?.name, "480 Mb/s 240 W cable")
        XCTAssertEqual(data.cables.last?.length, "2 m")
        XCTAssertEqual(data.cables.last?.notes, "")
        let text = String(decoding: try data.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"emarker\""))
        XCTAssertTrue(text.contains("\"speed_code\""))
    }
}
