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

/// Sequential write then read of one test file, with the page cache off. Runs in the app process,
/// as the user, never as root.
public enum DiskBench {
    static let block = 8 * 1024 * 1024

    /// Write then read `bytes` at `path`, always as the current user.
    ///
    /// `existing: false` creates the file (O_EXCL). `existing: true` uses an empty file that root
    /// prepared for us (see Bench.runDisk): it must be a regular file this user owns, and a symlink
    /// at the path is refused, so a swapped path cannot redirect the write.
    public static func run(path: String, bytes: Int64, existing: Bool = false) throws -> BenchNumbers {
        var buffer = [UInt8](repeating: 0, count: block)
        arc4random_buf(&buffer, block)

        let flags = existing ? (O_WRONLY | O_NOFOLLOW) : (O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW)
        let wfd = open(path, flags, 0o600)
        guard wfd >= 0 else { throw POSIXFailure("open") }
        if existing {
            var info = stat()
            guard fstat(wfd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_size == 0 else {
                close(wfd)
                throw BenchError.failed("The prepared test file is not an empty file owned by you. Test stopped.")
            }
        }
        defer { unlink(path) }  // Best effort. In a root-owned folder, Bench.runDisk removes it with sudo.

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
}
