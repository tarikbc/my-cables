@testable import CableLabCore
import XCTest

final class AutoNameTests: XCTestCase {
    func testAutoNameFollowsBrandAndRatings() {
        var f = CableFields()
        f.ratedData = "40 Gb/s"
        f.ratedPower = "240 W"
        f.name = f.autoName
        XCTAssertEqual(f.name, "40 Gb/s 240 W cable")

        let before = f
        f.brand = "Anker"
        f.refreshAutoName(previous: before)
        XCTAssertEqual(f.name, "Anker 40 Gb/s 240 W cable")
    }

    func testTypedNameIsKept() {
        var f = CableFields()
        f.name = "LTT USB-C cable"
        let before = f
        f.brand = "LTT Store"
        f.refreshAutoName(previous: before)
        XCTAssertEqual(f.name, "LTT USB-C cable")
    }

    func testOldNewPrefixNamesAreAutomatic() {
        var f = CableFields()
        f.name = "New 40 Gb/s 240 W cable"
        f.ratedData = "40 Gb/s"
        f.ratedPower = "240 W"
        let before = f
        f.brand = "Anker"
        f.refreshAutoName(previous: before)
        XCTAssertEqual(f.name, "Anker 40 Gb/s 240 W cable")
    }

    func testLengthIsCleanedUp() {
        XCTAssertEqual(CableFields.normalizeLength("1M"), "1 m")
        XCTAssertEqual(CableFields.normalizeLength("1m"), "1 m")
        XCTAssertEqual(CableFields.normalizeLength("50cm"), "50 cm")
        XCTAssertEqual(CableFields.normalizeLength("about 2 m"), "2 m")
        XCTAssertEqual(CableFields.normalizeLength("1,5 m"), "1.5 m")
        XCTAssertEqual(CableFields.normalizeLength("6 ft"), "6 ft")
        XCTAssertEqual(CableFields.normalizeLength("over 7 m"), "over 7 m")
        XCTAssertEqual(CableFields.normalizeLength("long"), "long")
        XCTAssertEqual(CableFields.normalizeLength(""), "")
    }

    func testUpsertStoresTheCleanLength() throws {
        var data = CableData()
        var f = CableFields()
        f.name = "x"
        f.length = "50cm"
        let id = try data.upsert(id: nil, fields: f)
        XCTAssertEqual(data.cables.first { $0.id == id }?.length, "50 cm")
    }

    func testDetectedAnkerNeedsNoTyping() throws {
        // The Anker cable's real e-marker: VID 0x291A.
        let anker = try XCTUnwrap(CableIdentity.decode(metadata: [
            "VDOs": [Data([0x1a, 0x29, 0x60, 0x18]), Data([0x9c, 0x21, 0, 0]), Data([0, 0x02, 0x87, 0x84]),
                     Data([0x43, 0x2e, 0x0a, 0x11])],
            "Vendor ID": 10522, "Product ID": 33927,
        ]))
        var data = CableData()
        let id = try data.addDetected(anker, date: "2026-10-11")
        let cable = try XCTUnwrap(data.cables.first { $0.id == id })
        XCTAssertEqual(cable.brand, "Anker")
        XCTAssertEqual(cable.name, "Anker 40 Gb/s 240 W cable")
        XCTAssertEqual(cable.length, "1 m")
        XCTAssertEqual(cable.notes, "")
        XCTAssertEqual(cable.ratedData, "40 Gb/s")
        XCTAssertEqual(cable.ratedPower, "240 W")
    }
}
