import Foundation
import USBGateKit

func status(_ gate: Gate) {
    let policy = gate.policy
    let state = gate.status
    print("")
    if state.isUsable {
        print("  \(Term.ok) usbgate \(Gate.version) enforcing")
    } else {
        print("  \(state.isFault ? Term.no : Term.warn) usbgate \(Gate.version) enforcing")
        print("  \(state.isFault ? Term.no : Term.warn) \(state.text)")
    }
    let classes = policy.interfaceClasses.sorted().map(\.name).joined(separator: ", ")
    let other = policy.allowOtherStorage ? "allowed" : "refused"
    print("  \(Term.info) usb: \(classes) only")
    print("  \(Term.info) thunderbolt, pcie, firewire, sd: \(other)")
    print("  \(Term.dim(gate.paths.allowlist))")

    let allowed = policy.allowed.sorted { $0.id < $1.id }
    let attached = Devices.attachedStorage()
    let here = Set(attached.map(\.device))
    let unknown = attached.filter { !policy.allowed.contains($0.device) }

    let width = max(
        allowed.map { policy.label(for: $0).count }.max() ?? 0,
        unknown.map(\.name.count).max() ?? 0)

    if allowed.isEmpty {
        if state.isUsable { print("\n  \(Term.dim("nothing authorised yet"))") }
    } else {
        print("\n  \(count(allowed.count, "drive", "drives")) authorised\n")
        for device in allowed {
            let name = policy.label(for: device).padding(
                toLength: width, withPad: " ", startingAt: 0)
            let mark = here.contains(device) ? "  \(Term.dim("attached"))" : ""
            print("  \(Term.ok) \(name)  \(Term.dim(device.shortID))\(mark)")
        }
    }

    if !unknown.isEmpty {
        print("\n  attached, not authorised\n")
        for device in unknown {
            let name = device.name.padding(toLength: width, withPad: " ", startingAt: 0)
            let why = decide(device, policy: policy, usable: state.isUsable)
            // The header already says there is no allowlist; do not repeat it here.
            let reason: String? =
                if case .blocked(let blocked) = why, blocked != .noAllowlist {
                    blocked.text
                } else { nil }
            // Reason on its own line, as in `rejected`: a long serial and a long
            // reason together do not fit one 80-column line.
            print("  \(Term.warn) \(name)  \(Term.dim(device.device.shortID))")
            if let reason { print("      \(Term.dim(reason))") }
        }
        print("\n  \(Term.info) sudo usbgate allow          to authorise one")
    }
    print("")
}

/// Rows printed per section by default; `rejected all` or `rejected <n>` widens it.
let defaultRows = 10

/// Says what was not printed, and whether the stored list itself has overflowed.
func more(_ total: Int, _ rows: Int) {
    if total > rows {
        print("        \(Term.dim("+ \(total - rows) older, see: usbgate rejected all"))")
    }
    if total >= Gate.listLimit {
        let note = "list is full at \(Gate.listLimit); older ones are in: usbgate log"
        print("        \(Term.dim(note))")
    }
}

/// The numbered list, which is what `allow` acts on.
func rejectedList(_ entries: [Rejection], rows: Int = defaultRows) {
    let width = entries.map(\.name.count).max() ?? 0
    for (index, entry) in entries.prefix(rows).enumerated() {
        let name = entry.name.padding(toLength: width, withPad: " ", startingAt: 0)
        print("  \(Term.warn) \(index + 1)  \(name)  \(Term.dim(entry.device.shortID))")
        print("        \(Term.dim(detail(entry.last, entry.count, entry.reason)))")
    }
    more(entries.count, rows)
}

/// Everything that was refused: what you can authorise, then what you cannot.
func rejected(_ gate: Gate, rows: Int) {
    let queue = gate.rejected
    let record = gate.denied

    guard !queue.isEmpty || !record.isEmpty else {
        print("\(Term.ok) nothing has been refused")
        return
    }

    print("")
    if !queue.isEmpty {
        rejectedList(queue, rows: rows)
        print("\n  \(Term.info) sudo usbgate allow          to authorise one")
    }
    if !record.isEmpty {
        if !queue.isEmpty { print("") }
        print("  \(Term.dim("cannot be authorised"))")
        let width = record.map(\.name.count).max() ?? 0
        for entry in record.prefix(rows) {
            let name = entry.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("  \(Term.no)    \(name)  \(Term.dim(entry.kind))")
            print("        \(Term.dim(detail(entry.last, entry.count, entry.reason)))")
        }
        more(record.count, rows)
    }
    print("")
}

/// Resolves "which one?" for any numbered list.
///
/// One place, so every command that picks from a list behaves the same: a number
/// selects, no argument prompts at a terminal with the newest as the default, and
/// a pipe gets the usage instead of a hang. Returns a zero-based index.
func choose(from count: Int, verb: String, argument: String?, showing list: () -> Void) -> Int {
    func resolve(_ reply: String) -> Int {
        guard let number = Int(reply), (1...count).contains(number) else {
            fail("no entry numbered '\(reply)'")
        }
        return number - 1
    }

    if let argument { return resolve(argument) }
    guard Term.isTTY else { fail("usage: usbgate \(verb) <number>") }

    list()
    let range = count == 1 ? "1" : "1-\(count)"
    print("  \(verb) which? [\(range)] \(Term.dim("enter = 1")) ", terminator: "")

    guard let reply = readLine()?.trimmingCharacters(in: .whitespaces) else { fail("cancelled") }
    return reply.isEmpty ? 0 : resolve(reply)
}

/// Attached drives first, since that is almost always the one you mean, then
/// anything refused earlier that is no longer plugged in.
func candidates(_ gate: Gate) -> [Candidate] {
    let policy = gate.policy
    let attached = Devices.attachedStorage().filter { !policy.allowed.contains($0.device) }
    var list = attached.map {
        Candidate(device: $0.device, name: $0.name, note: "attached")
    }
    let present = Set(attached.map(\.device))
    for entry in gate.rejected where !present.contains(entry.device) {
        list.append(
            Candidate(
                device: entry.device, name: entry.name,
                note: detail(entry.last, entry.count, entry.reason)))
    }
    return list
}

func candidateList(_ list: [Candidate]) {
    let width = list.map(\.name.count).max() ?? 0
    print("")
    for (number, item) in list.prefix(defaultRows).enumerated() {
        let name = item.name.padding(toLength: width, withPad: " ", startingAt: 0)
        print("  \(Term.warn) \(number + 1)  \(name)  \(Term.dim(item.device.shortID))")
        print("        \(Term.dim(item.note))")
    }
    more(list.count, defaultRows)
    print("")
}

/// Picks a drive to authorise.
func pick(_ gate: Gate, _ argument: String?, _ verb: String) -> Candidate {
    let list = candidates(gate)
    guard !list.isEmpty else { fail("every attached drive is already authorised", code: 0) }

    if let argument, argument.contains("/") {
        guard let match = list.first(where: { $0.device.id == argument }) else {
            fail("\(argument) is not attached and was not refused")
        }
        return match
    }
    let index = choose(from: list.count, verb: verb, argument: argument) {
        candidateList(list)
    }
    return list[index]
}

/// Picks from the refused list only, for `dismiss`.
func pickRefused(_ gate: Gate, _ argument: String?) -> Rejection {
    let entries = gate.rejected
    guard !entries.isEmpty else { fail("nothing has been refused", code: 0) }
    let index = choose(from: entries.count, verb: "dismiss", argument: argument) {
        print("")
        rejectedList(entries)
        print("")
    }
    return entries[index]
}

/// Picks from the allowlist, by number or by id.
func pickAuthorised(_ gate: Gate, _ argument: String?) -> Device {
    let policy = gate.policy
    let allowed = policy.allowed.sorted { $0.id < $1.id }
    guard !allowed.isEmpty else { fail("nothing is authorised") }

    if let argument, argument.contains("/") {
        guard let match = allowed.first(where: { $0.id == argument }) else {
            fail("\(argument) is not in the allowlist; run: usbgate status")
        }
        return match
    }
    let attached = Set(Devices.attachedStorage().map(\.device))
    let index = choose(from: allowed.count, verb: "revoke", argument: argument) {
        let width = allowed.map { policy.label(for: $0).count }.max() ?? 0
        print("")
        for (number, device) in allowed.enumerated() {
            let name = policy.label(for: device).padding(
                toLength: width, withPad: " ", startingAt: 0)
            let here = attached.contains(device) ? "  \(Term.dim("attached"))" : ""
            print("  \(Term.ok) \(number + 1)  \(name)  \(Term.dim(device.shortID))\(here)")
        }
        print("")
    }
    return allowed[index]
}
