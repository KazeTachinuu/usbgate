import Testing

@testable import USBGateKit

/// What usbgate touches, and everything it must leave alone.
///
/// The scope rule was wrong twice before. First it was ejectable-or-removable,
/// which put every disk image in scope and refused them. Then it excluded only
/// internal, network and virtual, which put Thunderbolt, FireWire and PCIe card
/// readers in scope and refused those too. It is now a positive classification, so
/// anything untouched is untouched by construction rather than by exclusion list.
@Suite("Scope")
struct ScopeTests {
    static func volume(_ name: String?, net: Bool = false, builtIn: Bool = false) -> [String: Any] {
        var description: [String: Any] = [:]
        if let name { description["DADeviceProtocol"] = name }
        if net { description["DAVolumeNetwork"] = true }
        if builtIn { description["DADeviceInternal"] = true }
        return description
    }

    static func transport(_ name: String?, net: Bool = false, builtIn: Bool = false) -> Transport {
        .of(volume(name, net: net, builtIn: builtIn), isBehindUSB: false)
    }

    // MARK: USB is the allowlisted tier

    @Test("a USB volume is classified as USB")
    func usbIsUSB() {
        #expect(Self.transport("USB") == .usb)
    }

    /// If Disk Arbitration does not name the protocol, the IOKit topology still does.
    @Test("IOKit alone is enough to classify a volume as USB")
    func ioKitAloneIsEnough() {
        #expect(Transport.of([:], isBehindUSB: true) == .usb)
        #expect(Transport.of(Self.volume(nil), isBehindUSB: true) == .usb)
    }

    /// Both signals must fail before a real USB drive escapes the allowlist tier.
    @Test("either signal alone is enough")
    func eitherSignalSuffices() {
        #expect(Transport.of(Self.volume("USB"), isBehindUSB: false) == .usb)
        #expect(Transport.of(Self.volume(nil), isBehindUSB: true) == .usb)
        #expect(Transport.of(Self.volume(nil), isBehindUSB: false) != .usb)
    }

    // MARK: Never touched, whatever the policy says

    @Test("a disk image is never touched")
    func diskImageUntouched() {
        #expect(Self.transport("Virtual Interface") == .virtual)
    }

    @Test("a network volume is never touched")
    func networkUntouched() {
        #expect(Self.transport(nil, net: true) == .network)
        #expect(Self.transport("USB", net: true) == .usb, "USB wins: a USB drive is still ours")
    }

    @Test("an internal disk is never touched")
    func internalUntouched() {
        #expect(Self.transport("Apple Fabric", builtIn: true) == .internalDisk)
    }

    /// The heart of "we do not disturb anything else": for these three, no policy,
    /// however hostile, can produce a refusal.
    @Test(
        "no policy can refuse an internal disk, a disk image or a network volume",
        arguments: [Transport.internalDisk, .virtual, .network])
    func untouchedTiersAreUnconditional(_ transport: Transport) {
        var hostile = Policy()
        hostile.allowed = []
        hostile.interfaceClasses = []
        hostile.allowOtherStorage = false

        #expect(decide(nil, policy: hostile, transport: transport, usable: false) == .allow)
        #expect(decide(nil, policy: hostile, transport: transport, usable: true) == .allow)
    }

    // MARK: Other external storage is the second tier

    @Test(
        "non-USB external transports land in the second tier",
        arguments: [
            "PCI-Express", "Thunderbolt", "SATA", "ATA", "ATAPI", "SAS", "SCSI",
            "Fibre Channel", "FireWire", "Secure Digital", "Unknown", "",
        ])
    func nonUSBExternalIsSecondTier(_ name: String) {
        guard case .otherExternal = Self.transport(name) else {
            Issue.record("\(name) should be second-tier external storage")
            return
        }
    }

    @Test("second-tier storage is refused by default, which is the DR posture")
    func secondTierRefusedByDefault() {
        let verdict = decide(nil, policy: Policy(), transport: .otherExternal("PCI-Express"))
        #expect(verdict == .blocked(.otherStorageDenied("PCI-Express")))
    }

    @Test("second-tier storage mounts when the switch is on")
    func secondTierAllowedBySwitch() {
        var policy = Policy()
        policy.allowOtherStorage = true
        #expect(decide(nil, policy: policy, transport: .otherExternal("Thunderbolt")) == .allow)
    }

    /// The switch must not leak into the USB tier.
    @Test("allowing other storage does not authorise an unknown USB drive")
    func switchDoesNotLeakIntoUSBTier() {
        var policy = Policy()
        policy.allowOtherStorage = true
        let stick = Attached(
            device: Device(vendor: 1, product: 2, serial: "X"), name: "x",
            interfaces: [.massStorage])
        #expect(decide(stick, policy: policy, transport: .usb) == .blocked(.notAllowlisted))
    }

    @Test("second-tier storage is still refused when there is no allowlist file")
    func secondTierFailsClosedWithoutAllowlist() {
        var policy = Policy()
        policy.allowOtherStorage = true
        let verdict = decide(
            nil, policy: policy, transport: .otherExternal("FireWire"), usable: false)
        #expect(verdict == .blocked(.noAllowlist))
    }

    /// Nothing that is not governed may reach a decision, a log line or a list.
    @Test(
        "untouched transports are not governed",
        arguments: [Transport.internalDisk, .virtual, .network])
    func untouchedIsNotGoverned(_ transport: Transport) {
        #expect(!transport.isGoverned)
    }

    @Test("usb and other external storage are governed")
    func storageIsGoverned() {
        #expect(Transport.usb.isGoverned)
        #expect(Transport.otherExternal("PCI-Express").isGoverned)
    }

    // MARK: The other direction

    /// Being in the USB tier must not become a way to get approved.
    @Test("a USB drive that cannot be identified is refused, not waved through")
    func unidentifiableUSBIsRefused() {
        #expect(decide(nil, policy: Policy(), transport: .usb) == .blocked(.unidentifiable))
    }
}
