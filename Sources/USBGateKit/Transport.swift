import DiskArbitration
import IOKit
import IOKit.storage

/// How a volume is attached, which decides whether usbgate has any business with it.
///
/// The strings come from Apple's `IOStorageProtocolCharacteristics.h`, not from
/// literals, so they track the SDK.
public enum Transport: Equatable, Sendable {
    /// USB storage: identifiable, and therefore allowlistable.
    case usb
    /// External storage that is not USB: Thunderbolt, PCIe, FireWire, SD, eSATA.
    case otherExternal(String)
    /// A disk image. Not removable media at all.
    case virtual
    /// A network volume. Nothing physical leaves the building.
    case network
    /// A built-in disk.
    case internalDisk

    /// One word for logs and `usbgate list`.
    public var name: String {
        switch self {
        case .usb: "usb"
        case .otherExternal(let kind): kind.isEmpty ? "external" : kind.lowercased()
        case .virtual: "disk image"
        case .network: "network"
        case .internalDisk: "internal"
        }
    }

    /// Whether usbgate has any business with this volume at all.
    ///
    /// False for internal disks, disk images and network volumes: no decision is
    /// taken, nothing is logged, and nothing is recorded.
    public var isGoverned: Bool {
        switch self {
        case .usb, .otherExternal: true
        case .virtual, .network, .internalDisk: false
        }
    }

    /// Classifies a Disk Arbitration description.
    ///
    /// `isBehindUSB` comes from the IOKit topology and is an independent second
    /// opinion, so one signal failing cannot drop a USB drive out of scope.
    public static func of(_ description: [String: Any], isBehindUSB: Bool) -> Self {
        let key = kDADiskDescriptionDeviceProtocolKey as String
        let protocolName = description[key] as? String

        if protocolName == kIOPropertyPhysicalInterconnectTypeUSB || isBehindUSB { return .usb }
        if description[kDADiskDescriptionVolumeNetworkKey as String] as? Bool == true {
            return .network
        }
        if protocolName == kIOPropertyPhysicalInterconnectTypeVirtual { return .virtual }
        if description[kDADiskDescriptionDeviceInternalKey as String] as? Bool == true {
            return .internalDisk
        }
        // Unknown transports are treated as external, so the fallback is the
        // stricter branch rather than the permissive one.
        return .otherExternal(protocolName ?? "")
    }
}
