import Foundation
import IOKit
import IOKit.storage
import IOKit.usb

/// IOKit device identity.
///
/// Everything here returns nil rather than guessing.
public enum Devices {
    static func property(_ node: io_service_t, _ key: String) -> Any? {
        unsafe IORegistryEntryCreateCFProperty(node, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// `IORegistryEntryFromBSDName` does not exist; this is the supported route.
    static func node(forBSDName bsd: String) -> io_service_t {
        guard let match = unsafe IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else {
            return IO_OBJECT_NULL
        }
        return IOServiceGetMatchingService(kIOMainPortDefault, match)  // consumes match
    }

    /// Walk toward the root until we reach the `IOUSBHostDevice` this node hangs off.
    ///
    ///
    /// Returns +1, caller releases. `IO_OBJECT_NULL` means "not behind USB".
    static func usbDevice(from node: io_service_t) -> io_service_t {
        var current = node
        IOObjectRetain(current)
        while current != IO_OBJECT_NULL {
            if unsafe IOObjectConformsTo(current, kIOUSBHostDeviceClassName) != 0 { return current }
            var parent: io_service_t = IO_OBJECT_NULL
            let result = unsafe IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard result == KERN_SUCCESS else { return IO_OBJECT_NULL }
            current = parent
        }
        return IO_OBJECT_NULL
    }

    /// USBGuard's `with-interface`: what the device actually claims to be.
    static func interfaceClasses(of device: io_service_t) -> [USBClass] {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard
            unsafe IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var classes: [USBClass] = []
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            guard unsafe IOObjectConformsTo(child, kIOUSBHostInterfaceClassName) != 0,
                let value = property(child, kUSBHostMatchingPropertyInterfaceClass) as? NSNumber
            else { continue }
            classes.append(USBClass(rawValue: value.intValue))
        }
        return classes
    }

    static func describe(_ device: io_service_t) -> Attached? {
        guard
            let vendor = (property(device, kUSBHostMatchingPropertyVendorID) as? NSNumber)?
                .intValue,
            let product = (property(device, kUSBHostMatchingPropertyProductID) as? NSNumber)?
                .intValue,
            let serial = (property(device, kUSBSerialNumberString) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !serial.isEmpty
        else { return nil }

        let label = (property(device, kUSBProductString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Attached(
            device: Device(vendor: vendor, product: product, serial: serial),
            name: label.flatMap { $0.isEmpty ? nil : $0 } ?? Key.unnamedDevice,
            interfaces: interfaceClasses(of: device))
    }

    /// Whether this volume sits behind a USB device at all.
    ///
    /// Answers the scope question from the IOKit topology, independently of what
    /// Disk Arbitration reports, and regardless of whether the device is
    /// identifiable enough to be authorised.
    public static func isBehindUSB(bsdName: String) -> Bool {
        let media = node(forBSDName: bsdName)
        guard media != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(media) }

        let device = usbDevice(from: media)
        guard device != IO_OBJECT_NULL else { return false }
        IOObjectRelease(device)
        return true
    }

    /// Identify the USB device behind a mounted volume's BSD name.
    static func identify(bsdName: String) -> Attached? {
        let media = node(forBSDName: bsdName)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }

        let device = usbDevice(from: media)
        guard device != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(device) }

        return describe(device)
    }

    /// The whole-disk BSD name for a device, if it is attached.
    ///
    /// Needed to mount a drive the moment it is authorised: Disk Arbitration does
    /// not retry a mount it has already refused.
    public static func diskName(for device: Device) -> String? {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard
            unsafe IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(kIOMediaClass), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let media = IOIteratorNext(iterator), media != IO_OBJECT_NULL {
            defer { IOObjectRelease(media) }
            guard (property(media, kIOMediaWholeKey) as? Bool) == true,
                let bsd = property(media, kIOBSDNameKey) as? String,
                identify(bsdName: bsd)?.device == device
            else { continue }
            return bsd
        }
        return nil
    }

    /// Every USB storage device present, mounted or not.
    ///
    /// A refused device never
    /// mounts, so the mount table cannot be the enrolment source once enforcing.
    public static func attachedStorage() -> [Attached] {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard
            unsafe IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(kIOUSBHostDeviceClassName), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Attached] = []
        while case let device = IOIteratorNext(iterator), device != IO_OBJECT_NULL {
            defer { IOObjectRelease(device) }
            guard let attached = describe(device),
                attached.interfaces.contains(.massStorage)
            else { continue }
            found.append(attached)
        }
        return found
    }

    /// BSD names of every mounted volume backed by a device node.
    static func mountedVolumes() -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = unsafe getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let mounts = unsafe buffer else { return [] }
        return (0..<Int(count)).compactMap { index in
            var entry = unsafe mounts[index]
            let path = unsafe withUnsafeBytes(of: &entry.f_mntfromname) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return unsafe String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            return path.hasPrefix("/dev/") ? String(path.dropFirst(5)) : nil
        }
    }
}
