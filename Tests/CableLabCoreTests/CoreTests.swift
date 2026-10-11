@testable import CableLabCore
import XCTest

final class USBTests: XCTestCase {
    func testPrefersLinkSpeedInBitsPerSecond() {
        let d = USBDevice(properties: ["USB Product Name": "PSSD T7 Shield", "USB Vendor Name": "Samsung",
                                       "Device Speed": 4, "UsbLinkSpeed": 10_000_000_000],
                          bsdNames: ["disk5s2", "disk4", "disk4"])
        XCTAssertEqual(d.linkBps, 10_000_000_000)
        XCTAssertEqual(d.bsdNames, ["disk4", "disk5s2"])
        XCTAssertEqual(Discovery.deviceLabel(vendor: d.vendor, product: d.product), "Samsung PSSD T7 Shield")
    }

    func testFallsBackToSpeedCode() {
        let d = USBDevice(properties: ["USB Product Name": "Phone", "Device Speed": 2, "USB Serial Number": "abc"],
                          bsdNames: [])
        XCTAssertEqual(d.linkBps, 480_000_000)
        XCTAssertEqual([d].device(forSerial: "abc")?.product, "Phone")
        XCTAssertNil([d].device(forSerial: ""))
        XCTAssertNil([d].device(forBSD: "disk9"))
    }

    func testLinkNames() {
        XCTAssertEqual(USBLink.name(480_000_000), "USB 2.0 (480 Mb/s)")
        XCTAssertEqual(USBLink.name(10_000_000_000), "USB 3.2 Gen 2 (10 Gb/s)")
        XCTAssertEqual(USBLink.name(nil), "unknown")
        XCTAssertEqual(USBLink.short(5_000_000_000), "5 Gb/s")
        XCTAssertEqual(USBLink.short(480_000_000), "480 Mb/s")
        XCTAssertEqual(USBLink.tier(480_000_000), .slow)
        XCTAssertEqual(USBLink.tier(5_000_000_000), .mid)
        XCTAssertEqual(USBLink.tier(20_000_000_000), .fast)
    }

    func testAdbLabels() {
        XCTAssertEqual(Discovery.adbLabel(manufacturer: "AYN", model: "AYN_Thor"), "AYN Thor")
        XCTAssertEqual(Discovery.adbLabel(manufacturer: "Google", model: "Pixel 9"), "Google Pixel 9")
        XCTAssertEqual(Discovery.adbLabel(manufacturer: "", model: ""), "Android device")
    }
}

final class StoreTests: XCTestCase {
    func fields(_ name: String, looks: String = "") -> CableFields {
        var f = CableFields()
        f.name = name
        f.looks = looks
        return f
    }

    func testUpsertMakesUniqueIDsAndUpdates() throws {
        var data = CableData()
        let a = try data.upsert(id: nil, fields: fields("LTT 40 Gb/s"))
        let b = try data.upsert(id: nil, fields: fields("LTT 40 Gb/s"))
        XCTAssertEqual([a, b], ["ltt-40-gb-s", "ltt-40-gb-s-2"])
        try data.upsert(id: a, fields: fields("  LTT  ", looks: "black braid"))
        XCTAssertEqual(data.cables[0].name, "LTT")
        XCTAssertEqual(data.cables[0].looks, "black braid")
        XCTAssertEqual(data.cables.count, 2)
    }

    func testUpsertNeedsANameAndAKnownID() {
        var data = CableData()
        XCTAssertThrowsError(try data.upsert(id: nil, fields: fields("  "))) {
            XCTAssertEqual($0 as? StoreError, .missingName)
        }
        XCTAssertThrowsError(try data.upsert(id: "nope", fields: fields("x")))
    }

    func testSlugify() {
        XCTAssertEqual(CableData.slugify("Café Cable (2 m)"), "cafe-cable-2-m")
        XCTAssertEqual(CableData.slugify("***"), "cable")
    }

    func testResultsAddAndDelete() throws {
        var data = CableData()
        let id = try data.upsert(id: nil, fields: fields("x"))
        try data.addResult(result("T7", "disk", 10_000_000_000, 1, 1), to: id)
        try data.deleteResult(at: 0, of: id)
        XCTAssertTrue(data.cables[0].results.isEmpty)
        XCTAssertThrowsError(try data.deleteResult(at: 0, of: id))
    }

    func testJSONUsesSnakeCaseAndRoundTrips() throws {
        var data = CableData()
        let id = try data.upsert(id: nil, fields: fields("x"))
        try data.addResult(result("AYN Thor", "adb", 480_000_000, 27.234, 24.381), to: id)
        let text = String(decoding: try data.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"link_bps\""))
        XCTAssertTrue(text.contains("\"write_s\""))
        XCTAssertTrue(text.contains("\"rated_data\""))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/data/cables.json")
        try data.save(to: url)
        XCTAssertEqual(try CableData.load(from: url), data)
    }

    func testLoadsTheRepoDataFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/cables.json")
        let data = try CableData.load(from: url)
        XCTAssertFalse(data.cables.isEmpty)
    }
}

func result(_ endpoint: String, _ kind: String, _ link: Int64, _ writeS: Double, _ readS: Double,
            bytes: Int64 = 1_000_000_000) -> CableResult {
    CableResult(date: "2026-10-11", endpoint: endpoint, kind: kind, linkBps: link, host: "Mac15,9",
                bytes: bytes, writeS: writeS, readS: readS)
}

final class ReadmeTests: XCTestCase {
    var data = CableData()

    override func setUp() {
        var slow = Cable(id: "slow", name: "Stock")
        slow.brand = "AYN"
        slow.results = [result("AYN Thor", "adb", 480_000_000, 25, 20)]
        var fast = Cable(id: "fast", name: "LTT")
        fast.ratedData = "40 Gb/s"
        fast.ratedPower = "240 W"
        fast.results = [
            result("AYN Thor", "adb", 10_000_000_000, 2.5, 2.5),
            result("AYN Thor", "adb", 10_000_000_000, 2.0, 2.4),
            result("Samsung T7", "disk", 10_000_000_000, 1.25, 1.25),
        ]
        data = CableData(cables: [slow, fast, Cable(id: "new", name: "Unknown")])
    }

    func testTableOrdersByLinkAndUsesTheBestRun() {
        let lines = Readme.table(data).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("AYN Thor push / pull (MB/s)"))
        XCTAssertTrue(lines[0].contains("Samsung T7 write / read (MB/s)"))
        XCTAssertTrue(lines[2].hasPrefix("| **LTT**"))
        XCTAssertTrue(lines[2].contains("| 500 / 417 |"))
        XCTAssertTrue(lines[2].contains("| 800 / 800 |"))
        XCTAssertTrue(lines[2].contains("40 Gb/s · 240 W"))
        XCTAssertTrue(lines[3].contains("USB 2.0 only"))
        XCTAssertTrue(lines[4].contains("Not tested yet"))
    }

    func testRenderReplacesOnlyBetweenMarkers() throws {
        let text = "intro\n\(Readme.start)\nold\n\(Readme.end)\noutro\n"
        let out = try Readme.render(data, into: text)
        XCTAssertTrue(out.hasPrefix("intro\n\(Readme.start)\n| Cable"))
        XCTAssertTrue(out.hasSuffix("\(Readme.end)\noutro\n"))
        XCTAssertFalse(out.contains("old"))
        XCTAssertThrowsError(try Readme.render(data, into: "no markers"))
    }

    func testVerdicts() {
        XCTAssertEqual(Readme.verdict(data.cables[1]), "Full 10 Gb/s data.")
        var mid = Cable(id: "m", name: "m")
        mid.results = [result("x", "disk", 5_000_000_000, 1, 1)]
        XCTAssertEqual(Readme.verdict(mid), "5 Gb/s data.")
    }
}

final class BenchTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(Bench.diskTestSize(link: 10_000_000_000), 4 << 30)
        XCTAssertEqual(Bench.diskTestSize(link: 480_000_000), 1 << 30)
        XCTAssertEqual(Bench.diskTestSize(link: nil), 1 << 30)
    }

    func testClassifiesSudoAndPrivacyErrors() {
        XCTAssertEqual(Bench.classify("Sorry, try again.\nsudo: 1 incorrect password attempt\n"), .wrongPassword)
        XCTAssertEqual(Bench.classify("error: open: Operation not permitted\n"), .blockedByPrivacy)
        XCTAssertEqual(Bench.classify("error: write: No space left on device\n"),
                       .failed("error: write: No space left on device"))
    }

    func testExistingModeUsesOnlyAnEmptyRegularFileWeOwn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let empty = dir.appendingPathComponent("empty").path
        FileManager.default.createFile(atPath: empty, contents: nil)
        XCTAssertEqual(try DiskBench.run(path: empty, bytes: 8 << 20, existing: true).bytes, 8 << 20)

        let full = dir.appendingPathComponent("full").path
        FileManager.default.createFile(atPath: full, contents: Data([1]))
        XCTAssertThrowsError(try DiskBench.run(path: full, bytes: 8 << 20, existing: true))

        let target = dir.appendingPathComponent("target").path
        FileManager.default.createFile(atPath: target, contents: nil)
        let link = dir.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try DiskBench.run(path: link, bytes: 8 << 20, existing: true), "a symlink must be refused")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target)[.size] as? Int, 0)
    }

    func testRootOnlyRunsFixedSystemTools() {
        XCTAssertEqual(Bench.rootCreate, "/usr/bin/mktemp")
        XCTAssertEqual(Bench.rootChown, "/usr/sbin/chown")
        XCTAssertEqual(Bench.rootRemove, "/bin/rm")
    }

    func testAcceptsOnlyOurMktempPath() {
        let mount = "/Volumes/Time Machine"
        XCTAssertTrue(Bench.isOurTempFile("/Volumes/Time Machine/.my-cables-bench.Ab3dE9xZ", in: mount))
        XCTAssertFalse(Bench.isOurTempFile("/Volumes/Time Machine/.my-cables-bench.Ab3dE9x", in: mount))
        XCTAssertFalse(Bench.isOurTempFile("/Volumes/Time Machine/.my-cables-bench.Ab/../../x", in: mount))
        XCTAssertFalse(Bench.isOurTempFile("/etc/sudoers", in: mount))
        XCTAssertFalse(Bench.isOurTempFile("/Volumes/Time Machine/sub/.my-cables-bench.Ab3dE9xZ", in: mount))
    }

    func testMktempNeverFollowsASymlink() throws {
        // What root runs, tried as the user: a template in a folder never resolves through a symlink.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try Shell.run(Bench.rootCreate, [dir.appendingPathComponent(Bench.rootTemplatePrefix + "XXXXXXXX").path])
        let created = out.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(Bench.isOurTempFile(created, in: dir.path))
        var info = stat()
        XCTAssertEqual(lstat(created, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(info.st_size, 0)
    }

    func testSudoOnlyForRootOwnedFoldersWeCannotWrite() {
        XCTAssertTrue(Bench.rootOnlyFolder("/usr"))
        XCTAssertFalse(Bench.rootOnlyFolder(FileManager.default.temporaryDirectory.path), "a folder we can write")
        XCTAssertFalse(Bench.rootOnlyFolder("/etc"), "/etc is a symlink, so lstat must refuse it")
    }

    func testDiskBenchWritesReadsAndDeletes() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)").path
        let n = try DiskBench.run(path: path, bytes: 32 << 20)
        XCTAssertEqual(n.bytes, 32 << 20)
        XCTAssertGreaterThan(n.writeS, 0)
        XCTAssertGreaterThan(n.readS, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
