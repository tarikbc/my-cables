@testable import CableLabCore
import XCTest

final class RankingTests: XCTestCase {
    func testParsesTypedRatings() {
        XCTAssertEqual(Ranking.dataRate("40 Gb/s"), 40_000_000_000)
        XCTAssertEqual(Ranking.dataRate("10Gbps"), 10_000_000_000)
        XCTAssertEqual(Ranking.dataRate("480 Mb/s"), 480_000_000)
        XCTAssertNil(Ranking.dataRate("fast"))
        XCTAssertEqual(Ranking.watts("240 W"), 240)
        XCTAssertEqual(Ranking.watts("100W"), 100)
        XCTAssertNil(Ranking.watts("240"))
    }

    func testHostileValuesNeverTrap() {
        XCTAssertNil(Ranking.dataRate("99999999999999999999999 Gb/s"))
        XCTAssertNil(Ranking.dataRate("1e400 Gb/s"))
        XCTAssertNil(Ranking.watts("99999999999999999999 W"))
        var zero = result("T7", "disk", 10_000_000_000, 0, -1)
        XCTAssertEqual(zero.writeMBps, 0)
        XCTAssertEqual(zero.readMBps, 0)
        zero.bytes = 0
        XCTAssertEqual(zero.writeMBps, 0)
        XCTAssertEqual(Double.infinity.safeRoundedInt, 0)
        XCTAssertEqual(Double.nan.safeRoundedInt, 0)
        XCTAssertEqual(1e300.safeRoundedInt, Int.max)
        XCTAssertEqual((-1e300).safeRoundedInt, Int.min)
        XCTAssertEqual(854.6.safeRoundedInt, 855)
        // A cable with a broken run still ranks, after the healthy one.
        var broken = Cable(id: "b", name: "Broken")
        broken.ratedData = "99999999999999999999999 Gb/s"
        broken.results = [result("T7", "disk", 10_000_000_000, 0, 0)]
        var good = Cable(id: "g", name: "Good")
        good.results = [result("T7", "disk", 10_000_000_000, 1, 1)]
        XCTAssertEqual(Ranking.ranked([broken, good]).map(\.name), ["Good", "Broken"])
        XCTAssertFalse(Readme.table(CableData(cables: [broken, good])).isEmpty)
    }

    func emarker(speed: Int) -> CableIdentity {
        CableIdentity(vendorId: 0, productId: 0, productType: "passive", speedCode: speed, currentA: 5,
                      maxVolts: 50, epr: true, latencyCode: 1, hwVersion: 0, fwVersion: 0, vdos: ["\(speed)"])
    }

    func cable(_ name: String, emarker e: CableIdentity? = nil, rated: String = "", results: [CableResult]) -> Cable {
        var c = Cable(id: name.lowercased(), name: name)
        c.emarker = e
        c.ratedData = rated
        c.results = results
        return c
    }

    func t7(_ link: Int64, _ w: Double, _ r: Double) -> CableResult {
        result("Samsung PSSD T7 Shield", "disk", link, 4.294967296 * 1000 / w, 4.294967296 * 1000 / r,
               bytes: 4_294_967_296)
    }

    func thor(_ link: Int64, _ w: Double, _ r: Double) -> CableResult {
        result("AYN Thor", "adb", link, 1073.741824 / w, 1073.741824 / r, bytes: 1_073_741_824)
    }

    /// Today's real cables, in a shuffled order.
    func testRealCablesRankBestFirst() {
        let g10: Int64 = 10_000_000_000, usb2: Int64 = 480_000_000
        let cables = [
            cable("Anker", emarker: emarker(speed: 3), results: [t7(g10, 531, 823)]),
            cable("Thor stock", results: [thor(usb2, 39, 44)]),
            cable("Insta360", results: [thor(g10, 479, 433)]),
            cable("Aohi", emarker: emarker(speed: 0), results: [t7(usb2, 35, 34)]),
            cable("LTT", emarker: emarker(speed: 3), results: [t7(g10, 855, 820), thor(g10, 479, 436)]),
            cable("Untested", results: []),
        ]
        XCTAssertEqual(Ranking.ranked(cables).map(\.name), ["LTT", "Anker", "Insta360", "Aohi", "Thor stock", "Untested"])
    }

    func testTypedRatingCountsWhenThereIsNoEmarker() {
        let g10: Int64 = 10_000_000_000
        let typed = cable("Typed 40G", rated: "40 Gb/s", results: [thor(g10, 400, 400)])
        let plain = cable("Plain", results: [thor(g10, 470, 430)])
        XCTAssertEqual(Ranking.ranked([plain, typed]).map(\.name), ["Typed 40G", "Plain"])
    }

    func testMeasuredScoreOnlyComparesTheSameDevice() {
        let g10: Int64 = 10_000_000_000
        let a = cable("A", results: [thor(g10, 480, 440)])
        let b = cable("B", results: [t7(g10, 850, 820)])
        XCTAssertEqual(Ranking.measuredScore(a, among: [a, b]), 1, accuracy: 0.001)
        XCTAssertEqual(Ranking.measuredScore(b, among: [a, b]), 1, accuracy: 0.001)
    }

    func testShortDeviceName() {
        XCTAssertEqual(Readme.shortDevice("Samsung PSSD T7 Shield"), "Samsung T7 Shield")
        XCTAssertEqual(Readme.shortDevice("AYN Thor"), "AYN Thor")
    }
}
