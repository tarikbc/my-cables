@testable import CableLabCore
import XCTest

final class ControlCLITests: XCTestCase {
    func testParsesTestWithDeviceAndWait() {
        let p = ControlCLI.request(["test", "ltt-usb-c-cable", "--device", "disk:/Volumes/Time Machine", "--wait"])
        XCTAssertNil(p.error)
        XCTAssertTrue(p.wait)
        XCTAssertEqual(p.request?["cmd"] as? String, "test")
        let args = p.request?["args"] as? [String: Any]
        XCTAssertEqual(args?["cable"] as? String, "ltt-usb-c-cable")
        XCTAssertEqual(args?["device"] as? String, "disk:/Volumes/Time Machine")
    }

    func testParsesAddFields() {
        let p = ControlCLI.request(["add", "--name", "Anker 100 W", "--rated-power", "100 W", "--looks", "grey braid"])
        let fields = (p.request?["args"] as? [String: Any])?["fields"] as? [String: String]
        XCTAssertEqual(fields, ["name": "Anker 100 W", "rated_power": "100 W", "looks": "grey braid"])
    }

    func testRejectsBadUsage() {
        XCTAssertNotNil(ControlCLI.request(["add"]).error)
        XCTAssertNotNil(ControlCLI.request(["edit"]).error)
        XCTAssertNotNil(ControlCLI.request(["remove-result", "x", "y"]).error)
        XCTAssertNotNil(ControlCLI.request(["add", "--name", "x", "--colour", "red"]).error)
        XCTAssertNotNil(ControlCLI.request(["frobnicate"]).error)
        XCTAssertNotNil(ControlCLI.request([]).error)
    }

    func testRemoveResultIndexIsAnInt() {
        let args = ControlCLI.request(["remove-result", "x", "2"]).request?["args"] as? [String: Any]
        XCTAssertEqual(args?["index"] as? Int, 2)
    }

    func testServerAndClientRoundTrip() throws {
        // Uses the real socket path, so skip when the app is running and owns it.
        if (try? ControlClient.send(["cmd": "job"])) != nil { throw XCTSkip("Cable Lab is running.") }
        let server = ControlServer { request in ["ok": true, "data": ["echo": request["cmd"] ?? ""]] }
        try server.start()
        defer { server.stop() }
        let response = try ControlClient.send(["cmd": "ping"])
        XCTAssertEqual((response["data"] as? [String: Any])?["echo"] as? String, "ping")
    }
}
