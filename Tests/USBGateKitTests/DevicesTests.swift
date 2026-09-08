import Testing

@testable import USBGateKit

/// IOKit probing.
///
/// These run against whatever is plugged into the build machine, so
/// they assert invariants rather than specific hardware.
@Suite("Devices")
struct DevicesTests {
    @Test("an unknown BSD name yields no device rather than a wrong one")
    func unknownBSDNameIsNil() {
        #expect(Devices.identify(bsdName: "disk9999") == nil)
        #expect(Devices.identify(bsdName: "") == nil)
    }

    @Test("the boot volume is not behind USB")
    func internalDiskIsNotUSB() {
        #expect(Devices.identify(bsdName: "disk0") == nil)
    }

    @Test("mounted volumes are reported as bare BSD names")
    func mountedVolumesAreBareNames() {
        let volumes = Devices.mountedVolumes()
        #expect(!volumes.isEmpty)
        #expect(volumes.allSatisfy { !$0.hasPrefix("/dev/") && !$0.isEmpty })
    }

    /// Whatever it finds must be fully identified: the enrolment output is only.
    ///
    /// usable if all three fields are present.
    @Test("every reported storage device carries vendor, product, serial and class 08")
    func attachedStorageIsFullyIdentified() {
        for attached in Devices.attachedStorage() {
            #expect(!attached.device.serial.isEmpty)
            #expect(!attached.name.isEmpty)
            #expect(attached.interfaces.contains(USBClass.massStorage))
        }
    }

    /// Name and serial come from two different IOKit properties.
    ///
    /// Reading both from the same one would leave every device identified by its model name,
    /// which is a silent loss of the only field that distinguishes two identical
    /// drives, and no other assertion here would notice.
    @Test("name and serial come from different properties")
    func nameAndSerialAreDistinctProperties() {
        for attached in Devices.attachedStorage() {
            #expect(
                attached.name != attached.device.serial,
                "\(attached.name) reports the same string as its name and its serial")
        }
    }

    @Test("probing is stable across calls")
    func probingIsStable() {
        let first = Devices.attachedStorage().map(\.device)
        let second = Devices.attachedStorage().map(\.device)
        #expect(first == second)
    }
}
