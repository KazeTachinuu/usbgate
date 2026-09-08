/// Every key written to or read from a file on disk, in one place.
///
/// Kept together so the on-disk format can be reviewed at a glance and so no key
/// is spelled two different ways in two different files.
enum Key {
    /// Keys in the allowlist file.
    enum Allowlist {
        static let devices = "AllowedDevices"
        static let interfaceClasses = "AllowedInterfaceClasses"
        static let otherStorage = "AllowOtherStorage"
        static let message = "Message"
    }

    /// Keys describing one device, shared by the allowlist and the refused queue.
    enum Device {
        static let label = "Label"
        static let vendor = "VendorID"
        static let product = "ProductID"
        static let serial = "SerialNumber"
    }

    /// Extra keys shared by both refusal lists.
    enum Refusal {
        static let reason = "Reason"
        static let last = "Last"
        static let count = "Count"
        static let kind = "Kind"
    }

    /// Shown when a device reports no product name.
    static let unnamedDevice = "USB device"
}
