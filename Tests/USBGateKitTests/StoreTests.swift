import Foundation
import Testing

@testable import USBGateKit

/// The allowlist file: what makes it trustworthy, and that it round-trips.
@Suite("Store")
struct StoreTests {
    static let system = Paths.system

    // MARK: Trust

    @Test("a root-owned file only root can write is accepted")
    func rootOwnedFileAccepted() {
        #expect(Self.system.rejection(ownerID: 0, permissions: 0o644) == nil)
        #expect(Self.system.rejection(ownerID: 0, permissions: 0o600) == nil)
    }

    @Test("a file owned by anyone but root is rejected", arguments: [501, 1, 99])
    func nonRootOwnerRejected(_ owner: Int) {
        #expect(Self.system.rejection(ownerID: owner, permissions: 0o644) == "not owned by root")
    }

    @Test(
        "a file others can write is rejected even when root owns it",
        arguments: [0o646, 0o664, 0o666, 0o777])
    func writableByOthersRejected(_ permissions: Int) {
        #expect(
            Self.system.rejection(ownerID: 0, permissions: permissions)
                == "writable by group or others")
    }

    // MARK: Round trip

    static var sample: Policy {
        var policy = Policy()
        let stick = Device(vendor: 0x0951, product: 0x1665, serial: "ABC123")
        policy.allowed = [stick]
        policy.labels = [stick.id: "IronKey"]
        return policy
    }

    @Test("a saved allowlist loads back identically")
    func roundTrip() {
        let restored = Store.policy(from: Store.fields(from: Self.sample))
        #expect(restored.allowed == Self.sample.allowed)
        #expect(restored.labels == Self.sample.labels)
        #expect(restored.interfaceClasses == Self.sample.interfaceClasses)
    }

    @Test("labels are cosmetic and never affect the decision")
    func labelsDoNotAffectDecision() {
        var relabelled = Self.sample
        relabelled.labels = [:]
        let stick = Attached(
            device: Device(vendor: 0x0951, product: 0x1665, serial: "ABC123"),
            name: "anything at all", interfaces: [USBClass.massStorage])
        #expect(decide(stick, policy: relabelled) == .allow)
    }

    // MARK: Unusable files

    @Test("a missing file yields an empty policy that is not usable")
    func missingFileIsNotUsable() {
        let (policy, status) = Store.load(.sandbox(NSTemporaryDirectory() + "usbgate-absent"))
        #expect(status == .missing)
        #expect(!status.isUsable)
        #expect(policy.allowed.isEmpty)
    }

    @Test("a file that is not a plist is malformed, not silently empty")
    func garbageFileIsMalformed() throws {
        let paths = Paths.sandbox(NSTemporaryDirectory() + "usbgate-garbage-\(UUID().uuidString)")
        paths.ensureDirectory()
        defer { try? FileManager.default.removeItem(atPath: paths.directory) }
        try "not a plist".write(toFile: paths.allowlist, atomically: true, encoding: .utf8)

        let (policy, status) = Store.load(paths)
        #expect(status == .malformed)
        #expect(!status.isUsable)
        #expect(policy.allowed.isEmpty)
    }

    @Test("no status other than loaded permits a mount")
    func onlyLoadedIsUsable() {
        #expect(Store.Status.loaded(3).isUsable)
        #expect(!Store.Status.missing.isUsable)
        #expect(!Store.Status.malformed.isUsable)
        #expect(!Store.Status.untrusted("whatever").isUsable)
    }
}

/// The on-disk format, pinned.
///
/// The round-trip test cannot catch a renamed key, because save and load share the
/// same constant and stay consistent with each other while silently breaking every
/// allowlist file already installed. These assertions pin the literal names.
@Suite("On-disk format")
struct FormatTests {
    @Test("allowlist keys are exactly what an installed file already contains")
    func allowlistKeysArePinned() {
        #expect(Key.Allowlist.devices == "AllowedDevices")
        #expect(Key.Allowlist.interfaceClasses == "AllowedInterfaceClasses")
        #expect(Key.Allowlist.otherStorage == "AllowOtherStorage")
        #expect(Key.Allowlist.message == "Message")
    }

    @Test("device keys are exactly what an installed file already contains")
    func deviceKeysArePinned() {
        #expect(Key.Device.label == "Label")
        #expect(Key.Device.vendor == "VendorID")
        #expect(Key.Device.product == "ProductID")
        #expect(Key.Device.serial == "SerialNumber")
    }

    @Test("refusal-list keys are pinned")
    func refusalKeysArePinned() {
        #expect(Key.Refusal.reason == "Reason")
        #expect(Key.Refusal.last == "Last")
        #expect(Key.Refusal.count == "Count")
        #expect(Key.Refusal.kind == "Kind")
    }

    /// A written file must contain those keys, not merely define them.
    @Test("a saved allowlist really does use those key names")
    func savedFileUsesPinnedKeys() throws {
        var policy = Policy()
        let stick = Device(vendor: 0x0951, product: 0x1665, serial: "ABC123")
        policy.allowed = [stick]
        policy.labels = [stick.id: "IronKey"]

        let fields = Store.fields(from: policy)
        #expect(fields["AllowedDevices"] != nil)

        let entry = try #require((fields["AllowedDevices"] as? [[String: Any]])?.first)
        #expect(entry["VendorID"] as? String == "0x0951")
        #expect(entry["ProductID"] as? String == "0x1665")
        #expect(entry["SerialNumber"] as? String == "ABC123")
        #expect(entry["Label"] as? String == "IronKey")
    }
}
