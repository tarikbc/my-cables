import DiskArbitration
import Foundation

/// A device on the other end of the cable: an external USB volume or an adb device.
public struct Endpoint: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case disk, adb }

    public var id: String
    public var kind: Kind
    public var label: String
    public var detail: String
    public var linkBps: Int64?
    // Disk only.
    public var mount: String?
    public var volume: String?
    public var freeBytes: Int64?
    public var isTimeMachine = false
    // adb only.
    public var serial: String?
    /// The Mac's USB-C port, and the cable's e-marker identity when it has one.
    public var port: Int? = nil
    public var cable: CableIdentity? = nil
}

public enum Discovery {
    /// Devices to test against, plus every USB-C port with the cable plugged into it.
    public static func scan() -> (endpoints: [Endpoint], ports: [USBCPort]) {
        let usb = USBRegistry.devices()
        let ports = ports()
        var endpoints = disks(usb) + adbDevices(usb)
        for i in endpoints.indices {
            endpoints[i].cable = ports.first { $0.number == endpoints[i].port }?.cable
        }
        return (endpoints, ports)
    }

    public static func endpoints() -> [Endpoint] {
        scan().endpoints
    }

    public static func deviceLabel(vendor: String, product: String) -> String {
        let v = vendor.trimmingCharacters(in: .whitespaces), p = product.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty && !p.lowercased().hasPrefix(v.lowercased()) { return "\(v) \(p)" }
        return p
    }

    public static func adbLabel(manufacturer: String, model: String) -> String {
        let m = model.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        let maker = manufacturer.trimmingCharacters(in: .whitespaces)
        if !maker.isEmpty && !m.lowercased().hasPrefix(maker.lowercased()) { return "\(maker) \(m)" }
        return m.isEmpty ? (maker.isEmpty ? "Android device" : maker) : m
    }

    // MARK: Disks

    static func disks(_ usb: [USBDevice]) -> [Endpoint] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let tm = timeMachineMounts()
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        var found: [Endpoint] = []
        for url in urls where url.path.hasPrefix("/Volumes/") {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let desc = DADiskCopyDescription(disk) as? [String: Any] else { continue }
            let isInternal = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true
            let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String
            guard !isInternal, proto == "USB",
                  let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
                  let dev = usb.device(forBSD: bsd) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? url.lastPathComponent
            let free = Int64(values?.volumeAvailableCapacity ?? 0)
            let isTM = tm.contains(url.path)
            found.append(Endpoint(
                id: "disk:\(url.path)", kind: .disk,
                label: deviceLabel(vendor: dev.vendor, product: dev.product),
                detail: "Volume “\(name)”, \(free / 1_000_000_000) GB free" + (isTM ? ", Time Machine disk" : ""),
                linkBps: dev.linkBps, mount: url.path, volume: name, freeBytes: free, isTimeMachine: isTM,
                port: dev.usbCPort))
        }
        return found.sorted { $0.label < $1.label }
    }

    public static func timeMachineMounts() -> Set<String> {
        guard let out = try? Shell.run("/usr/bin/tmutil", ["destinationinfo"], timeout: 15) else { return [] }
        var mounts = Set<String>()
        for line in out.out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Mount Point" {
                mounts.insert(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return mounts
    }

    public static func timeMachineRunning() -> Bool {
        guard let out = try? Shell.run("/usr/bin/tmutil", ["status"], timeout: 15) else { return false }
        return out.out.split(separator: "\n").contains { $0.replacingOccurrences(of: " ", with: "") == "Running=1;" }
    }

    // MARK: adb

    static func adbDevices(_ usb: [USBDevice]) -> [Endpoint] {
        guard let adb = Shell.find("adb"),
              let out = try? Shell.run(adb, ["devices"], timeout: 15) else { return [] }
        var found: [Endpoint] = []
        for line in out.out.split(separator: "\n").dropFirst() {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[1] == "device" else { continue }
            let serial = String(parts[0])
            let props = (try? Shell.run(adb, ["-s", serial, "shell",
                                              "getprop ro.product.manufacturer; getprop ro.product.model"],
                                        timeout: 15))?.out ?? ""
            let lines = props.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) + ["", ""]
            let dev = usb.device(forSerial: serial)
            found.append(Endpoint(
                id: "adb:\(serial)", kind: .adb,
                label: adbLabel(manufacturer: lines[0], model: lines[1]),
                detail: "Android over adb, push and pull to /sdcard" + (dev == nil ? " (link speed not found)" : ""),
                linkBps: dev?.linkBps, serial: serial, port: dev?.usbCPort))
        }
        return found
    }
}
