import Foundation

public enum BenchError: LocalizedError, Equatable {
    case failed(String)
    case wrongPassword
    case backupRunning
    /// macOS privacy protection (TCC) stopped the write, even as root.
    case blockedByPrivacy

    public var errorDescription: String? {
        switch self {
        case .failed(let text): return text
        case .wrongPassword: return "That password was not accepted."
        case .backupRunning: return "A Time Machine backup is running. Wait for it to finish, then test again."
        case .blockedByPrivacy:
            return "macOS blocked the write, even as root. Give Cable Lab Full Disk Access in System Settings, "
                + "then run the test again."
        }
    }
}

public enum Bench {
    public static let gib: Int64 = 1 << 30
    public static let testFileName = ".my-cables-bench.tmp"
    public static let adbRemotePath = "/sdcard/Download/.my-cables-bench.bin"

    /// 4 GiB on 5 Gb/s links and up. 1 GiB on slower links, so a USB 2.0 run stays under a minute.
    public static func diskTestSize(link: Int64?) -> Int64 {
        (link ?? 0) >= 5_000_000_000 ? 4 * gib : gib
    }

    /// adb tops out near 500 MB/s, so 1 GiB is enough on every link.
    public static let adbTestSize: Int64 = gib

    /// True when this user cannot create a file in the volume's top folder.
    public static func diskNeedsRoot(_ ep: Endpoint) -> Bool {
        guard let mount = ep.mount else { return false }
        let probe = (mount as NSString).appendingPathComponent(testFileName + ".probe")
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { return errno == EACCES || errno == EPERM }
        close(fd)
        unlink(probe)
        return false
    }

    // MARK: Disk

    /// Root only ever runs these two Apple tools from the sealed system volume, never Cable Lab's own
    /// binary (which lives in a folder the user can write). The benchmark itself always runs as the user.
    static let rootCreate = "/usr/bin/install"
    static let rootRemove = "/bin/rm"

    /// Runs the benchmark as the current user. When `password` is given, sudo first creates an empty
    /// test file owned by the user in the root-owned top folder, and removes it at the end.
    public static func runDisk(_ ep: Endpoint, password: String?,
                               say: (String) -> Void) throws -> BenchNumbers {
        guard let mount = ep.mount, let volume = ep.volume else { throw BenchError.failed("This is not a disk.") }
        let size = diskTestSize(link: ep.linkBps)
        let free = (try? URL(fileURLWithPath: mount).resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity ?? 0
        guard Int64(free) > size + 5 * gib else {
            throw BenchError.failed("Not enough free space on “\(volume)” for a \(size / gib) GiB test.")
        }
        if ep.isTimeMachine && Discovery.timeMachineRunning() {
            throw BenchError.backupRunning
        }
        let path = (mount as NSString).appendingPathComponent(testFileName)
        guard let password else {
            say("Writing then reading \(size / gib) GiB on “\(volume)”.")
            return try runBench(path: path, bytes: size, existing: false)
        }
        say("sudo creates an empty test file on “\(volume)” for you. Then Cable Lab writes and reads \(size / gib) GiB.")
        try sudo(password, [rootCreate, "-o", String(getuid()), "-m", "600", "/dev/null", path])
        defer { _ = try? sudo(password, [rootRemove, "-f", "--", path]) }
        return try runBench(path: path, bytes: size, existing: true)
    }

    static func runBench(path: String, bytes: Int64, existing: Bool) throws -> BenchNumbers {
        do {
            return try DiskBench.run(path: path, bytes: bytes, existing: existing)
        } catch let failure as POSIXFailure where failure.code == EPERM {
            throw BenchError.blockedByPrivacy
        }
    }

    /// Run one fixed system command as root. The password goes to sudo on stdin, never on the command line.
    static func sudo(_ password: String, _ command: [String]) throws {
        let out = try Shell.run("/usr/bin/sudo", ["-S", "-k", "-p", ""] + command,
                                input: Data((password + "\n").utf8), timeout: 120)
        guard out.status == 0 else { throw classify(out.err) }
    }

    static func classify(_ stderr: String) -> BenchError {
        if stderr.contains("incorrect password") || stderr.contains("Sorry, try again")
            || stderr.contains("no password was provided") {
            return .wrongPassword
        }
        if stderr.contains("Operation not permitted") { return .blockedByPrivacy }
        let last = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return .failed(last.isEmpty ? "The disk test failed." : last)
    }

    // MARK: adb

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("my-cables")
    }

    static func randomFile(size: Int64, say: (String) -> Void) throws -> URL {
        let url = cacheDir.appendingPathComponent("random-\(size / gib)GiB.bin")
        let current = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        if current == size { return url }
        say("Making a \(size / gib) GiB random file. This happens once.")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let part = url.appendingPathExtension("part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        let chunk = 8 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        for _ in 0..<(size / Int64(chunk)) {
            arc4random_buf(&buffer, chunk)
            try handle.write(contentsOf: buffer)
        }
        try handle.close()
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: part, to: url)
        return url
    }

    static func timed(_ path: String, _ args: [String]) throws -> Double {
        let start = DispatchTime.now()
        let out = try Shell.run(path, args, timeout: 1800)
        guard out.status == 0 else {
            let text = (out.err.isEmpty ? out.out : out.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BenchError.failed(text.isEmpty ? "adb failed." : String(text.suffix(300)))
        }
        return DiskBench.seconds(since: start)
    }

    public static func runADB(_ ep: Endpoint, say: (String) -> Void) throws -> BenchNumbers {
        guard let serial = ep.serial else { throw BenchError.failed("This is not an adb device.") }
        guard let adb = Shell.find("adb") else { throw BenchError.failed("adb is not installed.") }
        let size = adbTestSize
        let source = try randomFile(size: size, say: say)
        let pulled = cacheDir.appendingPathComponent("pulled.bin")
        let base = ["-s", serial]
        defer {
            _ = try? Shell.run(adb, base + ["shell", "rm", "-f", adbRemotePath], timeout: 30)
            _ = try? FileManager.default.removeItem(at: pulled)
        }
        say("Pushing \(size / gib) GiB of random data to \(ep.label).")
        let writeS = try timed(adb, base + ["push", source.path, adbRemotePath])
        say("Pulling it back from \(ep.label).")
        let readS = try timed(adb, base + ["pull", adbRemotePath, pulled.path])
        return BenchNumbers(bytes: size, writeS: writeS, readS: readS)
    }
}
