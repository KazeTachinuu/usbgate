import Foundation

/// A USB device identified by the three fields an allowlist entry must carry.
public struct Device: Hashable, Sendable {
    let vendor: Int
    let product: Int
    let serial: String

    init(vendor: Int, product: Int, serial: String) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
    }

    /// Stable log and display form, `vvvv:pppp/serial`.
    public var id: String { String(format: "%04x:%04x/%@", vendor, product, serial) }

    /// `id` cut to fit one line of a list.
    ///
    /// USB-to-NVMe bridges report serials of 128 characters, which wrap and
    /// break the two-line entry layout.
    ///
    /// Display only. Matching, the audit log and the allowlist keep the full id.
    public var shortID: String {
        let limit = 32
        guard serial.count > limit else { return id }
        return String(format: "%04x:%04x/%@..", vendor, product, String(serial.prefix(limit - 2)))
    }

    /// Plist form, as stored in the allowlist file.
    var entry: [String: Any] {
        [
            Key.Device.vendor: String(format: "0x%04x", vendor),
            Key.Device.product: String(format: "0x%04x", product),
            Key.Device.serial: serial,
        ]
    }
}

/// A device that is physically present, as read from IOKit.
public struct Attached: Hashable, Sendable {
    /// Identity, as it would appear in an allowlist entry.
    public let device: Device
    /// `USB Product Name`, for display only and never matched against policy.
    public let name: String
    /// `bInterfaceClass` of every interface the device publishes.
    let interfaces: [USBClass]

    init(device: Device, name: String, interfaces: [USBClass]) {
        self.device = device
        self.name = name
        self.interfaces = interfaces
    }

    /// A paste-ready `AllowedDevices` entry for this device.
    public var allowlistEntry: String {
        """
            <dict>
                <key>Label</key><string>\(name)</string>
                <key>VendorID</key><string>\(String(format: "0x%04x", device.vendor))</string>
                <key>ProductID</key><string>\(String(format: "0x%04x", device.product))</string>
                <key>SerialNumber</key><string>\(device.serial)</string>
            </dict>
        """
    }
}

/// The policy in force, as delivered by MDM.
public struct Policy: Equatable, Sendable {
    /// Devices permitted to mount, empty meaning nothing mounts.
    public internal(set) var allowed: Set<Device> = []
    /// Human labels keyed by device id, for display and for the saved file only.
    public internal(set) var labels: [String: String] = [:]

    /// The label for a device, falling back to a generic name.
    public func label(for device: Device) -> String {
        labels[device.id] ?? Key.unnamedDevice
    }
    /// Interface classes a device may publish, USBGuard's `with-interface`.
    public internal(set) var interfaceClasses: Set<USBClass> = [.massStorage]
    /// Whether non-USB external storage may mount, deny being the DR posture.
    public internal(set) var allowOtherStorage = false
    /// Shown to the user by the Finder when a volume is refused.
    public internal(set) var message = Self.defaultMessage

    /// Deliberately generic: every site should replace it with its own wording
    /// and a way to reach someone.
    static let defaultMessage = "This drive is not authorised. Contact IT support."
}

private func hexList(_ classes: [USBClass]) -> String {
    classes.map(\.name).joined(separator: ",")
}

/// Why a device was refused, ordered by the sequence the checks run in.
public enum Reason: Hashable, Sendable {
    case noAllowlist
    case unidentifiable
    case noInterfaces
    case forbiddenInterfaces([USBClass])
    case notAllowlisted
    case otherStorageDenied(String)

    /// One-line explanation, written to the log and shown by `list-devices`.
    public var text: String {
        switch self {
        case .noAllowlist: "no usable allowlist"
        case .unidentifiable: "unidentifiable: no USB vendor/product/serial"
        case .noInterfaces: "no USB interfaces readable"
        case .forbiddenInterfaces(let classes): "publishes \(hexList(classes)), not just storage"
        case .notAllowlisted: "not in allowlist"
        case .otherStorageDenied(let kind): "\(kind) storage is not permitted"
        }
    }
}

/// The outcome of a policy evaluation.
public enum Verdict: Hashable, Sendable {
    case allow
    case blocked(Reason)

    /// True when the device would not be permitted to mount.
    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

/// Evaluates one volume against the policy, purely and totally.
///
/// The transport decides which tier applies: USB is allowlisted by identity,
/// other external storage is one yes-or-no switch, and everything else is not
/// ours to touch. This is USBGuard's implicit block target: no path that fails to
/// establish identity can reach an approval.
public func decide(
    _ attached: Attached?, policy: Policy, transport: Transport = .usb, usable: Bool = true
) -> Verdict {
    switch transport {
    case .virtual, .network, .internalDisk:
        return .allow  // not removable media, never ours
    case .otherExternal(let kind):
        guard usable else { return .blocked(.noAllowlist) }
        // No vendor, product or serial to match on, so it is one policy switch.
        return policy.allowOtherStorage ? .allow : .blocked(.otherStorageDenied(kind))
    case .usb:
        break
    }

    guard usable else { return .blocked(.noAllowlist) }
    guard let attached else { return .blocked(.unidentifiable) }
    guard !attached.interfaces.isEmpty else { return .blocked(.noInterfaces) }

    // with-interface is checked before the allowlist: a reflashed stick carrying an
    // enrolled serial must still not get through.
    let extra = Set(attached.interfaces).subtracting(policy.interfaceClasses)
    guard extra.isEmpty else { return .blocked(.forbiddenInterfaces(extra.sorted())) }

    guard policy.allowed.contains(attached.device) else { return .blocked(.notAllowlisted) }
    return .allow
}

/// Parses a vendor or product id, returning nil for anything unrecognised.
///
///
/// Accepts `0x0951`, `"0x0951"` and `"2385"`; nil drops the entry rather than widening it.
func parseNumber(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    guard let text = (value as? String)?.lowercased() else { return nil }
    return text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
}

/// Parses allowlist entries, dropping any that is malformed.
///
///
/// Vendor, product and serial are all mandatory; a dropped entry is reported
/// through `onDrop` and never widened to match a model.
func parseDevices(_ raw: [[String: Any]], onDrop: (String) -> Void = { _ in () }) -> Set<Device> {
    Set(
        raw.compactMap { entry -> Device? in
            guard let vendor = parseNumber(entry[Key.Device.vendor]),
                let product = parseNumber(entry[Key.Device.product]),
                let serial = (entry[Key.Device.serial] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !serial.isEmpty
            else {
                onDrop(entry[Key.Device.label] as? String ?? "<unlabelled>")
                return nil
            }
            return Device(vendor: vendor, product: product, serial: serial)
        })
}

/// Parses the permitted interface classes, nil meaning keep the default.
///
///
///
/// An empty set would mean permit no interface class at all, which is not the
/// same thing and is never what an absent key should imply.
func parseInterfaceClasses(_ raw: Any?) -> Set<USBClass>? {
    guard let list = raw as? [Any] else { return nil }
    let parsed = Set(list.compactMap(USBClass.parse))
    return parsed.isEmpty ? nil : parsed
}
