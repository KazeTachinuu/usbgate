public import Foundation  // both entries expose a Date

/// A USB drive that was refused and could be authorised.
///
/// Shown numbered by `usbgate rejected`, and `usbgate allow` acts on it.
public struct Rejection: LedgerEntry {
    /// Identity, ready to be added to the allowlist.
    public let device: Device
    /// `USB Product Name`, for display.
    public let name: String
    /// Why it was refused, the last time it was tried.
    public let reason: String
    /// When it was last refused.
    public let last: Date
    /// How many times it has been refused.
    public let count: Int

    var key: String { device.id }

    init(device: Device, name: String, reason: String, last: Date = Date(), count: Int = 1) {
        self.device = device
        self.name = name
        self.reason = reason
        self.last = last
        self.count = count
    }

    init?(row: [String: Any]) {
        guard let vendor = parseNumber(row[Key.Device.vendor]),
            let product = parseNumber(row[Key.Device.product]),
            let serial = row[Key.Device.serial] as? String, !serial.isEmpty
        else { return nil }

        self.init(
            device: Device(vendor: vendor, product: product, serial: serial),
            name: row[Key.Device.label] as? String ?? Key.unnamedDevice,
            reason: row[Key.Refusal.reason] as? String ?? "refused",
            last: row[Key.Refusal.last] as? Date ?? .distantPast,
            count: row[Key.Refusal.count] as? Int ?? 1)
    }

    var row: [String: Any] {
        var fields = device.entry
        fields[Key.Device.label] = name
        fields[Key.Refusal.reason] = reason
        fields[Key.Refusal.last] = last
        fields[Key.Refusal.count] = count
        return fields
    }

    func seenAgain(at date: Date, count: Int) -> Self {
        Self(device: device, name: name, reason: reason, last: date, count: count)
    }
}
