import Foundation

public struct BenchNumbers: Codable, Sendable {
    public var bytes: Int64
    public var writeS: Double
    public var readS: Double
}

struct POSIXFailure: Error, CustomStringConvertible {
    let operation: String
    let code: Int32

    init(_ operation: String) {
        self.operation = operation
        code = errno
    }

    var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// Sequential write then read of one test file, with the page cache off.
///
/// The app runs this in a child copy of itself (`CableLab --bench-disk <path> <bytes>`), as root through
/// sudo when the volume's top folder is not writable. The child prints one JSON line and always deletes
/// the test file.
public enum DiskBench {
    static let block = 8 * 1024 * 1024

    public static func run(path: String, bytes: Int64) throws -> BenchNumbers {
        var buffer = [UInt8](repeating: 0, count: block)
        arc4random_buf(&buffer, block)

        let wfd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard wfd >= 0 else { throw POSIXFailure("open") }
        defer { unlink(path) }

        var written: Int64 = 0
        let writeStart = DispatchTime.now()
        do {
            defer { close(wfd) }
            _ = fcntl(wfd, F_NOCACHE, 1)
            while written < bytes {
                let n = buffer.withUnsafeBytes { write(wfd, $0.baseAddress, block) }
                guard n > 0 else { throw POSIXFailure("write") }
                written += Int64(n)
            }
            guard fcntl(wfd, F_FULLFSYNC) == 0 else { throw POSIXFailure("fsync") }
        }
        let writeS = seconds(since: writeStart)

        let rfd = open(path, O_RDONLY)
        guard rfd >= 0 else { throw POSIXFailure("open") }
        defer { close(rfd) }
        _ = fcntl(rfd, F_NOCACHE, 1)
        var read: Int64 = 0
        let readStart = DispatchTime.now()
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(rfd, $0.baseAddress, block) }
            guard n >= 0 else { throw POSIXFailure("read") }
            if n == 0 { break }
            read += Int64(n)
        }
        let readS = seconds(since: readStart)
        return BenchNumbers(bytes: written, writeS: writeS, readS: readS)
    }

    static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    /// Entry point for `--bench-disk <path> <bytes>`. Returns the process exit code.
    public static func commandLine(_ args: [String]) -> Int32 {
        guard args.count == 2, let bytes = Int64(args[1]), bytes > 0 else {
            FileHandle.standardError.write(Data("usage: CableLab --bench-disk <path> <bytes>\n".utf8))
            return 64
        }
        do {
            let numbers = try run(path: args[0], bytes: bytes)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            FileHandle.standardOutput.write(try encoder.encode(numbers) + Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 2
        }
    }
}
