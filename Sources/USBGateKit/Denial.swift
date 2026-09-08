public import Foundation  // both entries expose a Date

/// Something refused that cannot be authorised: non-USB storage, or a USB drive
/// with no serial number.
///
/// Kept so an incident review can see what was tried, not so anyone can act on it.
public struct Denial: LedgerEntry {
    /// How it was attached: thunderbolt, firewire, usb, and so on.
    public let kind: String
    /// Whatever the device calls itself, for display.
    public let name: String
    /// Why it was refused.
    public let reason: String
    /// When it was last refused.
    public let last: Date
    /// How many times it has been refused.
    public let count: Int

    var key: String { "\(kind)/\(name)" }

    init(kind: String, name: String, reason: String, last: Date = Date(), count: Int = 1) {
        self.kind = kind
        self.name = name
        self.reason = reason
        self.last = last
        self.count = count
    }

    init?(row: [String: Any]) {
        guard let attachment = row[Key.Refusal.kind] as? String else { return nil }
        self.init(
            kind: attachment,
            name: row[Key.Device.label] as? String ?? Key.unnamedDevice,
            reason: row[Key.Refusal.reason] as? String ?? "refused",
            last: row[Key.Refusal.last] as? Date ?? .distantPast,
            count: row[Key.Refusal.count] as? Int ?? 1)
    }

    var row: [String: Any] {
        [
            Key.Refusal.kind: kind,
            Key.Device.label: name,
            Key.Refusal.reason: reason,
            Key.Refusal.last: last,
            Key.Refusal.count: count,
        ]
    }

    func seenAgain(at date: Date, count: Int) -> Self {
        Self(kind: kind, name: name, reason: reason, last: date, count: count)
    }
}
