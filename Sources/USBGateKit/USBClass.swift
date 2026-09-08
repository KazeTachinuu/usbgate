import IOKit
import IOKit.usb

/// A USB-IF defined base class code, as published in the Defined Class Codes list.
///
/// A struct rather than an enum so a code this table does not know is still
/// representable, and still refused, instead of failing to parse.
public struct USBClass: RawRepresentable, Hashable, Sendable, Comparable {
    /// The USB-IF base class code.
    public let rawValue: Int

    /// Wraps a raw USB-IF base class code.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Orders by code, so lists render deterministically.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Class 08h, the only class that ever asks for a mount.
    public static let massStorage = Self(rawValue: kUSBMassStorageInterfaceClass)

    /// Class 03h; storage that also claims this is the BadUSB shape.
    public static let humanInterface = Self(rawValue: kUSBHIDInterfaceClass)

    /// USB-IF Defined Class Codes, base classes only.
    static let names: [Int: String] = [
        0x00: "device", 0x01: "audio", 0x02: "communications", 0x03: "hid",
        0x05: "physical", 0x06: "image", 0x07: "printer", 0x08: "mass-storage",
        0x09: "hub", 0x0A: "cdc-data", 0x0B: "smart-card", 0x0D: "content-security",
        0x0E: "video", 0x0F: "personal-healthcare", 0x10: "audio-video",
        0x11: "billboard", 0x12: "type-c-bridge", 0x13: "bulk-display",
        0x14: "mctp", 0x3C: "i3c", 0xDC: "diagnostic", 0xE0: "wireless-controller",
        0xEF: "miscellaneous", 0xFE: "application-specific", 0xFF: "vendor-specific",
    ]

    /// The USB-IF name, or the raw code when the list does not define one.
    public var name: String { Self.names[rawValue] ?? String(format: "0x%02x", rawValue) }

    /// Accepts a USB-IF name, `0x08`, or `8`, so the allowlist file can read either way.
    public static func parse(_ value: Any?) -> Self? {
        if let text = (value as? String)?.lowercased() {
            if let code = names.first(where: { $0.value == text })?.key {
                return Self(rawValue: code)
            }
        }
        return parseNumber(value).map(Self.init(rawValue:))
    }
}
