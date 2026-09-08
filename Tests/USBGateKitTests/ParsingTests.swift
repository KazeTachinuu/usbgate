import Foundation
import Testing

@testable import USBGateKit

/// Policy parsing.
///
/// A malformed entry must be dropped and reported, never widened.
@Suite("Parsing")
struct ParsingTests {
    static var valid: [String: Any] {
        [
            Key.Device.label: "IronKey", Key.Device.vendor: "0x0951", Key.Device.product: "0x1665",
            Key.Device.serial: "ABC123",
        ]
    }

    @Test(
        "ids parse from hex and decimal strings",
        arguments: [("0x0951", 0x0951), ("0X0951", 0x0951), ("2385", 2385), ("0", 0)])
    func numberParsesFromString(_ input: String, _ expected: Int) {
        #expect(parseNumber(input) == expected)
    }

    @Test
    func numberParsesFromNSNumber() {
        #expect(parseNumber(NSNumber(value: 8)) == 8)
    }

    @Test(
        "unparseable ids are rejected rather than defaulted", arguments: ["", "zz", "0xZZ", "0x"])
    func numberRejectsGarbage(_ input: String) {
        #expect(parseNumber(input) == nil)
    }

    @Test
    func numberRejectsMissingValue() {
        #expect(parseNumber(nil) == nil)
    }

    @Test
    func wellFormedEntryParses() {
        #expect(
            parseDevices([Self.valid]) == [
                Device(vendor: 0x0951, product: 0x1665, serial: "ABC123")
            ])
    }

    /// Vendor, product and serial are all mandatory: dropping any one must remove the.
    ///
    /// entry, not produce a rule that matches a whole model.
    @Test(
        "an entry missing any field is dropped, never widened",
        arguments: [Key.Device.vendor, Key.Device.product, Key.Device.serial])
    func missingFieldDropsEntry(_ field: String) {
        var entry = Self.valid
        entry.removeValue(forKey: field)

        var dropped: [String] = []
        #expect(parseDevices([entry]) { dropped.append($0) }.isEmpty)
        #expect(dropped == ["IronKey"])
    }

    @Test("a blank or whitespace-only serial is not a serial", arguments: ["", "   ", "\t\n"])
    func blankSerialDropsEntry(_ serial: String) {
        var entry = Self.valid
        entry[Key.Device.serial] = serial
        #expect(parseDevices([entry]).isEmpty)
    }

    @Test
    func serialIsTrimmed() {
        var entry = Self.valid
        entry[Key.Device.serial] = "  ABC123\n"
        #expect(parseDevices([entry]).first?.serial == "ABC123")
    }

    @Test
    func unlabelledDropIsStillReported() {
        var dropped: [String] = []
        _ = parseDevices([[Key.Device.vendor: "0x1"]]) { dropped.append($0) }
        #expect(dropped == ["<unlabelled>"])
    }

    @Test("one malformed entry does not discard the rest of the allowlist")
    func malformedEntryDoesNotPoisonTheBatch() {
        #expect(parseDevices([Self.valid, [Key.Device.label: "broken"]]).count == 1)
    }

    /// The allowlist file may name a class the USB-IF way, or give the code in hex
    /// or decimal.
    ///
    /// All three must land on the same class.
    @Test
    func interfaceClassesParse() {
        #expect(parseInterfaceClasses([8, "0x03"]) == [.massStorage, .humanInterface])
        #expect(parseInterfaceClasses(["mass-storage"]) == [.massStorage])
        #expect(parseInterfaceClasses(["MASS-STORAGE", "hid"]) == [.massStorage, .humanInterface])
    }

    @Test("a class the USB-IF list does not name is represented, not dropped")
    func unknownClassIsKept() {
        #expect(parseInterfaceClasses(["0x42"]) == [USBClass(rawValue: 0x42)])
        #expect(USBClass(rawValue: 0x42).name == "0x42")
    }

    @Test("known classes render with their USB-IF name")
    func knownClassesAreNamed() {
        #expect(USBClass.massStorage.name == "mass-storage")
        #expect(USBClass.humanInterface.name == "hid")
        #expect(USBClass(rawValue: 0xFF).name == "vendor-specific")
    }

    /// nil means "keep the default", never "allow every class".
    @Test("an absent, empty or malformed class list falls back to the default")
    func interfaceClassesFallBack() {
        #expect(parseInterfaceClasses(nil) == nil)
        #expect(parseInterfaceClasses([]) == nil)
        #expect(parseInterfaceClasses("not a list") == nil)
        #expect(parseInterfaceClasses(["zz"]) == nil)
    }
}
