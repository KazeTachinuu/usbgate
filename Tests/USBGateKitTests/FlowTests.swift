import Foundation
import Testing

@testable import USBGateKit

/// The whole product, end to end, in a sandbox directory.
///
/// Plug in an unknown drive, get refused, look at the refused list, authorise one
/// from it, and watch the same drive become allowed. This is the flow the tool
/// exists for, so it is tested as one story rather than as separate units.
@Suite("Flow", .serialized)
struct FlowTests {
    let paths: Paths
    let gate: Gate

    init() {
        paths = .sandbox(NSTemporaryDirectory() + "usbgate-flow-\(UUID().uuidString)")
        gate = Gate(paths: paths)
    }

    private func cleanUp() { try? FileManager.default.removeItem(atPath: paths.directory) }

    static let stick = Attached(
        device: Device(vendor: 0x0951, product: 0x1665, serial: "ABC123"),
        name: "IronKey VP80", interfaces: [USBClass.massStorage])

    static func rejection(
        _ from: Attached = stick, reason: String = "not in allowlist"
    ) -> Rejection {
        Rejection(device: from.device, name: from.name, reason: reason)
    }

    @Test("plug in, get refused, authorise from the list, and it is allowed")
    func endToEnd() throws {
        defer { cleanUp() }

        // 1. Nothing configured yet: the drive is refused.
        gate.reload()
        #expect(gate.status == .missing)
        #expect(
            decide(Self.stick, policy: gate.policy, usable: gate.status.isUsable)
                == .blocked(.noAllowlist))

        // 2. The daemon queues the refusal.
        Ledger.record(Self.rejection(reason: Reason.noAllowlist.text), paths.rejected, paths)
        let queued = try #require(gate.rejected.first)
        #expect(gate.rejected.count == 1)
        #expect(queued.device == Self.stick.device)
        #expect(queued.name == "IronKey VP80")

        // 3. Authorise it straight from that list.
        #expect(gate.allow(queued.device, named: queued.name) == nil)

        // 4. It is now allowed, and the file says so.
        #expect(gate.status == .loaded(1))
        #expect(gate.status.isUsable)
        #expect(decide(Self.stick, policy: gate.policy, usable: true) == .allow)
        #expect(gate.policy.labels[Self.stick.device.id] == "IronKey VP80")

        // 5. It has left the refused queue.
        #expect(gate.rejected.isEmpty)

        // 6. Revoking puts it back to refused.
        #expect(gate.revoke(id: Self.stick.device.id) == nil)
        #expect(decide(Self.stick, policy: gate.policy, usable: gate.status.isUsable).isBlocked)
    }

    @Test("the allowlist survives a reload, which is what the daemon does on file change")
    func survivesReload() {
        defer { cleanUp() }
        gate.reload()
        #expect(gate.allow([Self.stick]) == nil)

        let reopened = Gate(paths: paths)
        reopened.reload()
        #expect(reopened.status == .loaded(1))
        #expect(decide(Self.stick, policy: reopened.policy, usable: true) == .allow)
    }

    // MARK: Refused queue behaviour

    @Test("the same drive refused twice appears once, with a count")
    func repeatedRefusalsAreDeduplicated() {
        defer { cleanUp() }
        let now = Date()
        Ledger.record(Self.rejection(), paths.rejected, paths, now: now)
        Ledger.record(Self.rejection(), paths.rejected, paths, now: now.addingTimeInterval(60))

        #expect(gate.rejected.count == 1)
        #expect(gate.rejected.first?.count == 2)
    }

    @Test("the queue is newest first")
    func queueIsNewestFirst() {
        defer { cleanUp() }
        let other = Attached(
            device: Device(vendor: 0x05AC, product: 0x1234, serial: "ZZZ"),
            name: "Older drive", interfaces: [USBClass.massStorage])
        let now = Date()
        Ledger.record(
            Self.rejection(other), paths.rejected, paths, now: now.addingTimeInterval(-3600))
        Ledger.record(Self.rejection(), paths.rejected, paths, now: now)

        #expect(gate.rejected.map(\.name) == ["IronKey VP80", "Older drive"])
    }

    @Test("the queue is capped so it cannot grow without bound")
    func queueIsCapped() {
        defer { cleanUp() }
        for index in 0..<12 {
            Ledger.record(
                Rejection(
                    device: Device(vendor: 1, product: 2, serial: "S\(index)"),
                    name: "drive \(index)", reason: "not in allowlist"),
                paths.rejected, paths, limit: 5)
        }
        #expect(gate.rejected.count == 5)
    }

    // MARK: Refusals nobody can act on

    @Test("a non-USB refusal is recorded separately, not in the actionable queue")
    func nonUSBRefusalIsRecordedApart() throws {
        defer { cleanUp() }
        Ledger.record(
            Denial(kind: "thunderbolt", name: "Samsung T7", reason: "thunderbolt not permitted"),
            paths.denied, paths)

        #expect(gate.rejected.isEmpty, "it must not appear where allow would offer it")
        let noted = try #require(gate.denied.first)
        #expect(noted.kind == "thunderbolt")
        #expect(noted.name == "Samsung T7")
    }

    @Test("the two lists are independent")
    func listsAreIndependent() {
        defer { cleanUp() }
        Ledger.record(Self.rejection(), paths.rejected, paths)
        Ledger.record(
            Denial(kind: "firewire", name: "LaCie", reason: "firewire not permitted"),
            paths.denied, paths)

        #expect(gate.rejected.count == 1)
        #expect(gate.denied.count == 1)

        gate.reload()
        #expect(gate.allow(gate.rejected[0].device, named: gate.rejected[0].name) == nil)
        #expect(gate.rejected.isEmpty, "authorising clears the queue entry")
        #expect(gate.denied.count == 1, "and leaves the record alone")
    }

    @Test("repeat non-USB attempts collapse into one row with a count")
    func repeatDenialsCollapse() {
        defer { cleanUp() }
        let entry = Denial(kind: "thunderbolt", name: "Samsung T7", reason: "not permitted")
        let now = Date()
        Ledger.record(entry, paths.denied, paths, now: now)
        Ledger.record(entry, paths.denied, paths, now: now.addingTimeInterval(60))

        #expect(gate.denied.count == 1)
        #expect(gate.denied.first?.count == 2)
    }

    /// `prefix(limit)` keeps the head of the list.
    ///
    /// Appending instead would discard the newest refusal once the list is full,
    /// which is the one an admin is looking for.
    @Test("when the list overflows it is the oldest that goes, not the newest")
    func overflowDropsTheOldest() {
        defer { cleanUp() }
        let start = Date()
        for index in 0...5 {
            Ledger.record(
                Rejection(
                    device: Device(vendor: 1, product: 2, serial: "S\(index)"),
                    name: "drive \(index)", reason: "not in allowlist"),
                paths.rejected, paths, now: start.addingTimeInterval(Double(index)), limit: 5)
        }
        let serials = Set(gate.rejected.map(\.device.serial))
        #expect(gate.rejected.count == 5)
        #expect(serials.contains("S5"), "the newest refusal must survive")
        #expect(!serials.contains("S0"), "the oldest must be the one dropped")
    }

    // MARK: Which list a refusal lands in

    static func description(model: String) -> [String: Any] {
        ["DADeviceModel": model]
    }

    @Test("an identifiable USB drive goes to the list allow can act on")
    func usbRefusalIsActionable() {
        defer { cleanUp() }
        gate.note(
            Self.stick, transport: .usb, description: [:], reason: .notAllowlisted)
        #expect(gate.rejected.count == 1)
        #expect(gate.denied.isEmpty)
    }

    @Test("a USB drive with no serial goes to the list nobody can act on")
    func unidentifiableUSBIsNotActionable() {
        defer { cleanUp() }
        gate.note(
            nil, transport: .usb, description: Self.description(model: "Generic Flash"),
            reason: .unidentifiable)
        #expect(gate.rejected.isEmpty)
        #expect(gate.denied.first?.name == "Generic Flash")
    }

    @Test("non-USB storage goes to the list nobody can act on, even if identifiable")
    func nonUSBIsNeverActionable() {
        defer { cleanUp() }
        gate.note(
            Self.stick, transport: .otherExternal("PCI-Express"),
            description: Self.description(model: "Samsung T7"),
            reason: .otherStorageDenied("PCI-Express"))
        #expect(gate.rejected.isEmpty, "it has no USB identity to authorise")
        #expect(gate.denied.first?.kind == "pci-express")
    }

    @Test("the drop is not silent: the count reaches the cap so the caller can say so")
    func capIsObservable() {
        defer { cleanUp() }
        #expect(Gate.listLimit == Ledger.limit)
        #expect(Gate.listLimit >= 1000, "the cap must not bite in normal use")
    }

    /// Authorising must free the row, not just hide it, or a busy machine would
    /// fill the list with drives that are already allowed.
    @Test("authorising removes the row, so it stops counting toward the cap")
    func authorisingFreesTheSlot() {
        defer { cleanUp() }
        gate.reload()
        for index in 0..<5 {
            Ledger.record(
                Rejection(
                    device: Device(vendor: 1, product: 2, serial: "S\(index)"),
                    name: "drive \(index)", reason: "not in allowlist"),
                paths.rejected, paths)
        }
        #expect(gate.rejected.count == 5)

        let chosen = gate.rejected[0]
        #expect(gate.allow(chosen.device, named: chosen.name) == nil)
        #expect(gate.rejected.count == 4, "the row is gone, not merely marked")
        #expect(!gate.rejected.contains { $0.device == chosen.device })
        #expect(gate.policy.allowed.contains(chosen.device))
    }

    @Test("dismissing also frees the row")
    func dismissingFreesTheSlot() {
        defer { cleanUp() }
        Ledger.record(Self.rejection(), paths.rejected, paths)
        #expect(gate.rejected.count == 1)
        gate.dismiss(gate.rejected[0])
        #expect(gate.rejected.isEmpty)
    }

    /// Every CLI command reloads the policy to read it.
    ///
    /// If that logged, `usbgate status` would write a fault line into the audit
    /// trail on every run, and the test suite would fill it with noise.
    @Test("only the running daemon writes to the log")
    func onlyTheDaemonLogs() {
        defer { cleanUp() }
        #expect(!gate.announces, "a gate built for reading must stay silent")
        gate.reload()
        #expect(!gate.announces, "and reloading must not change that")
    }

    @Test("an unnamed non-USB drive is not called a USB device")
    func unnamedNonUSBIsNamedByTransport() throws {
        defer { cleanUp() }
        gate.note(
            nil, transport: .otherExternal("Thunderbolt"), description: [:],
            reason: .otherStorageDenied("Thunderbolt"))
        let noted = try #require(gate.denied.first)
        #expect(noted.name == "thunderbolt drive")
        #expect(!noted.name.contains("USB"))
    }

    @Test("the same model on two transports is two rows, not one")
    func transportIsPartOfTheIdentity() {
        defer { cleanUp() }
        Ledger.record(Denial(kind: "usb", name: "Flash", reason: "x"), paths.denied, paths)
        Ledger.record(Denial(kind: "firewire", name: "Flash", reason: "x"), paths.denied, paths)
        #expect(gate.denied.count == 2)
    }

    @Test("dismissing removes a drive without authorising it")
    func dismissDoesNotAuthorise() throws {
        defer { cleanUp() }
        gate.reload()
        Ledger.record(Self.rejection(), paths.rejected, paths)
        let queued = try #require(gate.rejected.first)

        gate.dismiss(queued)
        #expect(gate.rejected.isEmpty)
        #expect(decide(Self.stick, policy: gate.policy, usable: gate.status.isUsable).isBlocked)
    }
}
