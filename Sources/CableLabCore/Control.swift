import Foundation

/// The control channel: a Unix socket that only this user can open. One JSON request per connection,
/// one JSON response back. The running app serves it; `CableLab ctl ...` (and ./cablectl) is the client.
///
/// Passwords never travel over this channel. A test that needs root still asks in the app's own sheet.
public enum Control {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("my-cables")
    }

    public static var socketPath: String { directory.appendingPathComponent("control.sock").path }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }

    static func readAll(_ fd: Int32, limit: Int = 8 << 20) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// Encode any Encodable value into a JSON object tree with snake_case keys.
    public static func object<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }
}

// MARK: Server

public final class ControlServer {
    public typealias Handler = ([String: Any]) -> [String: Any]

    private let handler: Handler
    private var listener: Int32 = -1

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: Control.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = Control.socketPath
        unlink(path)
        guard var addr = Control.address(path) else { throw BenchError.failed("Socket path is too long.") }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXFailure("socket") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw POSIXFailure("bind") }
        chmod(path, 0o600)
        guard listen(listener, 16) == 0 else { throw POSIXFailure("listen") }
        let fd = listener
        Thread.detachNewThread { [handler] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                DispatchQueue.global().async {
                    defer { close(client) }
                    let request = Control.readAll(client)
                    let response: [String: Any]
                    if let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any] {
                        response = handler(object)
                    } else {
                        response = ["ok": false, "error": "The request is not a JSON object."]
                    }
                    let data = (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes]))
                        ?? Data(#"{"ok":false,"error":"Could not encode the response."}"#.utf8)
                    Control.writeAll(client, data)
                }
            }
        }
    }

    public func stop() {
        if listener >= 0 { close(listener) }
        unlink(Control.socketPath)
    }
}

// MARK: Client

public enum ControlClient {
    public static func send(_ request: [String: Any]) throws -> [String: Any] {
        guard var addr = Control.address(Control.socketPath) else { throw BenchError.failed("Socket path is too long.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXFailure("socket") }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw BenchError.failed("Cable Lab is not running. Open it first (./cable-lab or open \"build/Cable Lab.app\").")
        }
        Control.writeAll(fd, try JSONSerialization.data(withJSONObject: request))
        shutdown(fd, SHUT_WR)
        let data = Control.readAll(fd)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BenchError.failed("Cable Lab sent an answer that is not JSON.")
        }
        return response
    }
}

// MARK: Command line

/// `CableLab ctl <command> ...`. Prints JSON to stdout. Exit code 0 on success, 1 on error, 64 on bad usage.
public enum ControlCLI {
    public static let usage = """
    usage: cablectl <command> [options]

      state                         Devices, cables and the current job, in one answer
      devices                       Connected devices with their USB link (read again now)
      cables                        Every cable with every result
      add --name NAME [fields]      Add a cable
      edit CABLE [fields]           Change only the given fields of a cable
      test CABLE [--device DEVICE] [--wait]
                                    Start a test. With one device connected, --device is optional.
                                    A root test shows the password sheet in the app.
      job [--wait]                  The current job. --wait blocks until it ends (up to 30 min)
      show CABLE|map                Show a cable, or the cable map, in the window
      remove-result CABLE INDEX     Delete one result (INDEX starts at 0)
      ports                         Every USB-C port, with the e-marker of the cable plugged in
      link CABLE --port N           Store the e-marker of the cable on port N on a saved cable
      accept                        Add the suggested (unsaved, e-marked) cable
      ignore                        Dismiss the cable banner
      forget-password               Delete the Mac password saved in the Keychain

    fields: --brand --rated-data --rated-power --length --ends --looks --notes
    """

    static let fieldFlags = ["--name": "name", "--brand": "brand", "--rated-data": "rated_data",
                             "--rated-power": "rated_power", "--length": "length", "--ends": "ends",
                             "--looks": "looks", "--notes": "notes"]

    /// Turn argv into a request. Returns nil and an error text for bad usage.
    public static func request(_ argv: [String]) -> (request: [String: Any]?, wait: Bool, error: String?) {
        guard let cmd = argv.first else { return (nil, false, usage) }
        var positional: [String] = []
        var options: [String: String] = [:]
        var wait = false
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--wait" {
                wait = true
            } else if arg.hasPrefix("--") {
                guard i + 1 < argv.count else { return (nil, false, "\(arg) needs a value.") }
                options[arg] = argv[i + 1]
                i += 1
            } else {
                positional.append(arg)
            }
            i += 1
        }
        var fields: [String: String] = [:]
        for (flag, value) in options {
            if let key = fieldFlags[flag] { fields[key] = value }
            else if flag != "--device" && flag != "--port" { return (nil, false, "Unknown option \(flag).") }
        }

        switch cmd {
        case "state", "devices", "cables", "ports", "forget-password", "accept", "ignore":
            return (["cmd": cmd], false, nil)
        case "link":
            guard positional.count == 1, let port = options["--port"].flatMap({ Int($0) }) else {
                return (nil, false, "usage: cablectl link CABLE --port N")
            }
            return (["cmd": "link", "args": ["cable": positional[0], "port": port]], false, nil)
        case "job":
            return (["cmd": "job"], wait, nil)
        case "add":
            guard fields["name"] != nil else { return (nil, false, "add needs --name.") }
            return (["cmd": "add", "args": ["fields": fields]], false, nil)
        case "edit":
            guard positional.count == 1 else { return (nil, false, "usage: cablectl edit CABLE [fields]") }
            return (["cmd": "edit", "args": ["cable": positional[0], "fields": fields]], false, nil)
        case "test":
            guard positional.count == 1 else { return (nil, false, "usage: cablectl test CABLE [--device DEVICE] [--wait]") }
            var args: [String: Any] = ["cable": positional[0]]
            if let device = options["--device"] { args["device"] = device }
            return (["cmd": "test", "args": args], wait, nil)
        case "show":
            guard positional.count == 1 else { return (nil, false, "usage: cablectl show CABLE|map") }
            return (["cmd": "show", "args": ["target": positional[0]]], false, nil)
        case "remove-result":
            guard positional.count == 2, let index = Int(positional[1]) else {
                return (nil, false, "usage: cablectl remove-result CABLE INDEX")
            }
            return (["cmd": "remove-result", "args": ["cable": positional[0], "index": index]], false, nil)
        case "help", "-h", "--help":
            return (nil, false, usage)
        default:
            return (nil, false, "Unknown command \(cmd).\n\n\(usage)")
        }
    }

    public static func run(_ argv: [String]) -> Int32 {
        let parsed = request(argv)
        guard let request = parsed.request else {
            FileHandle.standardError.write(Data(((parsed.error ?? usage) + "\n").utf8))
            return 64
        }
        do {
            var response = try ControlClient.send(request)
            if parsed.wait, response["ok"] as? Bool == true {
                let deadline = Date().addingTimeInterval(1800)
                while Date() < deadline {
                    let state = ((response["data"] as? [String: Any])?["state"] as? String) ?? ""
                    if state != "running" && state != "waiting_for_password" { break }
                    Thread.sleep(forTimeInterval: 1)
                    response = try ControlClient.send(["cmd": "job"])
                }
            }
            let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return response["ok"] as? Bool == true ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
