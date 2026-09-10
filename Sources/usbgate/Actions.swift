import Foundation
import USBGateKit

/// Unmounts a drive that was just revoked.
///
/// Revoking stops the next mount, but a volume already mounted stays mounted, so
/// the drive the admin just removed would still be readable until it is unplugged.
func unmountNow(_ device: Device, named name: String) {
    guard let disk = Devices.diskName(for: device) else { return }
    progress("unmounting \(name)")
    let unmount = Process()
    unmount.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    unmount.arguments = ["unmountDisk", disk]
    unmount.standardOutput = FileHandle.nullDevice
    unmount.standardError = FileHandle.nullDevice
    do { try unmount.run() } catch { return }
    unmount.waitUntilExit()
    if unmount.terminationStatus == 0 {
        print("  \(Term.ok) unmounted \(name)")
    } else {
        print("  \(Term.warn) \(name) is still mounted; eject it or unplug it")
    }
}

/// Mounts a drive that was just authorised.
///
/// Disk Arbitration does not retry a mount it already refused, so without this the
/// user has to unplug and replug to get the drive they just allowed.
func mountNow(_ device: Device, named name: String) {
    guard let disk = Devices.diskName(for: device) else { return }
    progress("mounting \(name)")
    let mount = Process()
    mount.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    mount.arguments = ["mountDisk", disk]
    mount.standardOutput = FileHandle.nullDevice
    mount.standardError = FileHandle.nullDevice
    do { try mount.run() } catch { return }
    mount.waitUntilExit()
    if mount.terminationStatus == 0 {
        print("  \(Term.ok) mounted \(name)")
    } else {
        print("  \(Term.warn) \(name) is authorised; unplug and replug it to mount")
    }
}

/// Shows what is about to be authorised and asks.
///
/// Returns false if the user declined.
func confirm(_ devices: [Attached]) -> Bool {
    let width = devices.map(\.name.count).max() ?? 0
    print("\n  about to authorise \(count(devices.count, "drive", "drives")):\n")
    for device in devices {
        let name = device.name.padding(toLength: width, withPad: " ", startingAt: 0)
        print("  \(Term.warn) \(name)  \(Term.dim(device.device.shortID))")
    }
    guard Term.isTTY else { return true }
    print("\n  proceed? [y/N] ", terminator: "")
    let reply = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return reply == "y" || reply == "yes"
}

/// `allow`: authorise one drive, then mount it.
func allowOne(_ gate: Gate, _ argument: String?) -> Never {
    let entry = pick(gate, argument, "allow")
    if let reason = gate.allow(entry.device, named: entry.name) { fail(reason) }
    print("  \(Term.ok) authorised \(entry.name)  \(Term.dim(entry.device.shortID))")
    mountNow(entry.device, named: entry.name)
    exit(0)
}

/// `revoke`: remove one drive, then unmount it.
func revokeOne(_ gate: Gate, _ argument: String?) -> Never {
    let device = pickAuthorised(gate, argument)
    let name = gate.policy.label(for: device)
    if let reason = gate.revoke(id: device.id) { fail(reason) }
    print("  \(Term.ok) revoked \(name)  \(Term.dim(device.shortID))")
    unmountNow(device, named: name)
    exit(0)
}

/// `dismiss`: drop one refusal without authorising it.
func dismissOne(_ gate: Gate, _ argument: String?) -> Never {
    let entry = pickRefused(gate, argument)
    gate.dismiss(entry)
    apply(nil, "dismissed \(entry.name)  \(entry.device.shortID)")
}

/// `other on|off`: whether non-USB external storage may mount.
func setOtherStorage(_ gate: Gate, _ allowed: Bool) -> Never {
    apply(
        gate.setAllowOtherStorage(allowed),
        "non-USB external storage \(allowed ? "allowed" : "refused")")
}

/// `allow all`: everything attached that is not already authorised.
func allowAll(_ gate: Gate) -> Never {
    let attached = Devices.attachedStorage()
    guard !attached.isEmpty else { fail("no usb storage attached") }

    let policy = gate.policy
    let new = attached.filter { !policy.allowed.contains($0.device) }
    guard !new.isEmpty else {
        print("\(Term.ok) every attached drive is already authorised")
        exit(0)
    }
    guard confirm(new) else { fail("cancelled", code: 0) }
    if let reason = gate.allow(new) { fail(reason) }
    print("\n  \(Term.ok) authorised \(count(new.count, "drive", "drives"))\n")
    for device in new { mountNow(device.device, named: device.name) }
    print("")
    exit(0)
}
