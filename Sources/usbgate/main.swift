import Foundation
import USBGateKit

// MARK: - Dispatch

let gate = Gate()
let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "version", "--version":
    print("usbgate \(Gate.version)")

case "help", "--help", "-h":
    print(Usage.text())

case "status":
    gate.reload()
    status(gate)

case "rejected":
    let rows = rowCount(arguments.dropFirst().first)
    gate.reload()
    rejected(gate, rows: rows)

case "dismiss":
    requireRoot("dismiss")
    gate.reload()
    dismissOne(gate, arguments.dropFirst().first)

case "allow":
    requireRoot("allow")
    gate.reload()
    let target = arguments.dropFirst().first
    if target == "all" { allowAll(gate) } else { allowOne(gate, target) }

case "revoke":
    requireRoot("revoke")
    gate.reload()
    revokeOne(gate, arguments.dropFirst().first)

case "other":
    guard let mode = arguments.dropFirst().first, mode == "on" || mode == "off" else {
        fail("usage: usbgate other on|off   (non-USB external storage)")
    }
    requireRoot("other")
    gate.reload()
    setOtherStorage(gate, mode == "on")

case "watch":
    Log.show(live: true, since: "")

case "log":
    Log.show(live: false, since: arguments.dropFirst().first ?? "7d")

case .some(let unknown):
    fail("unknown command '\(unknown)'\n\n\(Usage.text())", code: 2)

case nil:
    guard getuid() == 0 else {
        print(Usage.text())
        exit(0)
    }
    gate.run()
}
