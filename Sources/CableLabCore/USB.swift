import Foundation
import IOKit

/// One device from the IOUSBHostDevice class in the I/O registry.
public struct USBDevice: Hashable, Sendable {
    public var product: String
    public var vendor: String
    public var serial: String
    public var linkBps: Int64?
    /// Every BSD name below this device: whole disks, partitions and synthesized APFS volumes.
    public var bsdNames: [String]
    /// The Mac's USB-C port this device hangs off (its XHCI port's "usb-c-port-number").
    public var usbCPort: Int?

    public init(properties p: [String: Any], bsdNames: [String], usbCPort: Int? = nil) {
        self.usbCPort = usbCPort
        product = (p["USB Product Name"] ?? p["kUSBProductString"]) as? String ?? "USB device"
        vendor = (p["USB Vendor Name"] ?? p["kUSBVendorString"]) as? String ?? ""
        serial = (p["USB Serial Number"] ?? p["kUSBSerialNumberString"]) as? String ?? ""
        if let bps = (p["UsbLinkSpeed"] as? NSNumber)?.int64Value, bps > 0 {
            linkBps = bps
        } else if let code = (p["Device Speed"] as? NSNumber)?.intValue {
            linkBps = USBLink.speedCodeBps[code]
        } else {
            linkBps = nil
        }
        self.bsdNames = Array(Set(bsdNames)).sorted()
    }
}

public extension Array where Element == USBDevice {
    func device(forBSD name: String) -> USBDevice? {
        first { $0.bsdNames.contains(name) }
    }

    func device(forSerial serial: String) -> USBDevice? {
        guard !serial.isEmpty else { return nil }
        return first { $0.serial == serial }
    }
}

public enum USBRegistry {
    public static func devices() -> [USBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
            == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [USBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            found.append(USBDevice(properties: dict, bsdNames: bsdNames(below: service),
                                   usbCPort: usbCPortNumber(above: service)))
        }
        return found
    }

    /// Walk up the service plane until a node carries "usb-c-port-number" (a 4-byte little-endian number).
    static func usbCPortNumber(above service: io_registry_entry_t) -> Int? {
        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<12 {
            if let data = IORegistryEntryCreateCFProperty(entry, "usb-c-port-number" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data, !data.isEmpty {
                return Int(CableIdentity.word(data))
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }

    static func bsdNames(below service: io_registry_entry_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if let name = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                names.append(name)
            }
        }
        return names
    }
}
