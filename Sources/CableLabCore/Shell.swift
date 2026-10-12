import Foundation

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var out: String { String(decoding: stdout, as: UTF8.self) }
    public var err: String { String(decoding: stderr, as: UTF8.self) }
}

public enum Shell {
    /// Run a program to the end. `input` goes to its stdin; stdin is always a pipe, never the app's own.
    public static func run(_ path: String, _ args: [String], input: Data? = nil,
                           timeout: TimeInterval = 120) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        try process.run()

        if let input { inPipe.fileHandleForWriting.write(input) }
        try? inPipe.fileHandleForWriting.close()

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        group.wait()
        killer.cancel()
        return ProcessOutput(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// GUI apps do not get the shell PATH, so look in the usual places.
    public static func find(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                    "\(home)/Library/Android/sdk/platform-tools"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

public enum HostInfo {
    /// The Mac model identifier, for example "Mac15,9". Never the serial number.
    public static func model() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
