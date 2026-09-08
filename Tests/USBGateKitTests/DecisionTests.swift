import Testing

@testable import USBGateKit

/// The allowlist decision.
///
/// These are the properties the homologation dossier claims,
/// so each one is asserted rather than argued.
@Suite("Decision")
struct DecisionTests {
    static let enrolled = Device(vendor: 0x0951, product: 0x1665, serial: "ABC123")

    /// A policy with one enrolled mass-storage device.
    static func policy(
        allowed: Set<Device> = [enrolled],
        classes: Set<USBClass> = [.massStorage]
    ) -> Policy {
        var policy = Policy()
        policy.allowed = allowed
        policy.interfaceClasses = classes
        return policy
    }

    static func stick(
        _ device: Device = enrolled, interfaces: [USBClass] = [.massStorage]
    ) -> Attached {
        Attached(device: device, name: "IronKey", interfaces: interfaces)
    }

    @Test("an enrolled mass-storage device is allowed")
    func enrolledIsAllowed() {
        #expect(decide(Self.stick(), policy: Self.policy()) == .allow)
    }

    // MARK: Fail closed

    @Test("an unidentifiable device is blocked")
    func unidentifiableIsBlocked() {
        #expect(decide(nil, policy: Self.policy()) == .blocked(.unidentifiable))
    }

    @Test("a device with no readable interfaces is blocked")
    func noInterfacesIsBlocked() {
        #expect(
            decide(Self.stick(interfaces: []), policy: Self.policy()) == .blocked(.noInterfaces))
    }

    @Test("an empty allowlist blocks an otherwise valid device")
    func emptyAllowlistBlocks() {
        #expect(decide(Self.stick(), policy: Self.policy(allowed: [])) == .blocked(.notAllowlisted))
    }

    /// A missing or untrusted allowlist file must mean no mounts, even when a
    /// stale in-memory policy is still in hand.
    @Test("an unusable allowlist blocks everything, loaded policy notwithstanding")
    func unusableAllowlistBlocksEverything() {
        #expect(
            decide(Self.stick(), policy: Self.policy(), usable: false) == .blocked(.noAllowlist))
        #expect(decide(nil, policy: Policy(), usable: false) == .blocked(.noAllowlist))
    }

    // MARK: No wildcards

    @Test(
        "a device differing in any one field is not the enrolled device",
        arguments: [
            Device(vendor: 0x0000, product: 0x1665, serial: "ABC123"),
            Device(vendor: 0x0951, product: 0x0000, serial: "ABC123"),
            Device(vendor: 0x0951, product: 0x1665, serial: "OTHER"),
        ])
    func anyFieldMismatchBlocks(_ other: Device) {
        #expect(decide(Self.stick(other), policy: Self.policy()) == .blocked(.notAllowlisted))
    }

    // MARK: with-interface (USBGuard's BadUSB rule)

    @Test("storage plus HID is blocked even when the serial is enrolled")
    func badUSBIsBlockedDespiteEnrolment() {
        let verdict = decide(
            Self.stick(interfaces: [.massStorage, .humanInterface]), policy: Self.policy())
        #expect(verdict == .blocked(.forbiddenInterfaces([.humanInterface])))
    }

    @Test("the interface check runs before the allowlist check")
    func interfaceCheckPrecedesAllowlist() {
        let unenrolled = Device(vendor: 0x1234, product: 0x5678, serial: "NOPE")
        let verdict = decide(
            Self.stick(unenrolled, interfaces: [.massStorage, .humanInterface]),
            policy: Self.policy())
        #expect(verdict == .blocked(.forbiddenInterfaces([.humanInterface])))
    }

    @Test("every forbidden class is reported, sorted")
    func forbiddenClassesAreReported() {
        let verdict = decide(
            Self.stick(interfaces: [.massStorage, .humanInterface, USBClass(rawValue: 1)]),
            policy: Self.policy())
        #expect(
            verdict == .blocked(.forbiddenInterfaces([USBClass(rawValue: 1), .humanInterface])))
        if case .blocked(let reason) = verdict {
            #expect(reason.text == "publishes audio,hid, not just storage")
        }
    }

    @Test("widening AllowedInterfaceClasses admits the extra class")
    func wideningAdmitsClass() {
        let policy = Self.policy(classes: [.massStorage, .humanInterface])
        #expect(
            decide(Self.stick(interfaces: [.massStorage, .humanInterface]), policy: policy)
                == .allow)
    }
}
