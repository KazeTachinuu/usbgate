import DiskArbitration
import Foundation
import IOKit
import os

/// The daemon: owns the allowlist, answers Disk Arbitration mount approvals, and
/// converges volumes that mounted before it started.
public final class Gate: @unchecked Sendable {
    /// Subsystem for the unified log, and the LaunchDaemon label.
    public static let domain = "io.github.kazetachinuu.usbgate"
    /// Reported by `usbgate version` and written to the log at startup.
    public static let version = "1.0.0"

    /// Most refusals either list keeps before dropping the oldest.
    public static let listLimit = Ledger.limit

    private let log = Logger(subsystem: Gate.domain, category: "policy")
    private let lock = NSLock()
    private var stored = Policy()
    private var storedStatus = Store.Status.missing

    /// Only the running daemon writes to the log.
    ///
    /// Every CLI command reloads the policy to read it; without this, `usbgate
    /// status` and the test suite would each write a line into the audit trail.
    private(set) var announces = false

    /// Last refusal shown to the user, to avoid repeating one notification.
    private var lastAnnounced: (identity: String, at: Date)?

    /// Confined to `queue` from the moment `DASessionSetDispatchQueue` is called.
    ///
    /// That confinement is what makes the `@unchecked Sendable` on this class sound.
    private var session: DASession?
    private var watcher: (any DispatchSourceFileSystemObject)?

    /// Creates a gate that refuses everything until `reload()` reads the allowlist.
    ///
    /// Where state lives. Defaults to the root-owned system location.
    public let paths: Paths

    /// - Parameter paths: where state lives; defaults to the root-owned location.
    public init(paths: Paths = .system) {
        self.paths = paths
    }

    /// The allowlist currently in force.
    public var policy: Policy {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Where that allowlist came from, or why there isn't one.
    public var status: Store.Status {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    // MARK: - Policy

    /// Replaces the allowlist wholesale from the file.
    public func reload() {
        let (next, state) = Store.load(paths)
        lock.lock()
        // An atomic save fires more than one file-system event, so the watcher
        // reloads several times for one change. Only say so when it differs.
        let previous = stored
        let changed = next != stored || state != storedStatus
        stored = next
        storedStatus = state
        lock.unlock()

        guard announces, changed else { return }
        guard state.isUsable else {
            log.fault("\(state.text, privacy: .public), refusing all removable storage")
            return
        }
        announceChanges(from: previous, to: next)
    }

    /// USB drives refused so far that could be authorised, newest first.
    public var rejected: [Rejection] { Ledger.load(paths.rejected, paths) }

    /// Refusals nobody can act on: non-USB storage, or a drive with no serial.
    public var denied: [Denial] { Ledger.load(paths.denied, paths) }

    /// Adds devices to the allowlist and saves.
    ///
    /// Returns a reason on failure.
    public func allow(_ devices: [Attached]) -> String? {
        var next = policy
        for attached in devices {
            next.allowed.insert(attached.device)
            next.labels[attached.device.id] = attached.name
        }
        if let why = commit(next) { return why }
        for attached in devices { Ledger.forget(rejection: attached.device.id, paths) }
        return nil
    }

    /// Authorises one device by identity, with a label for display.
    public func allow(_ device: Device, named name: String) -> String? {
        allow([Attached(device: device, name: name, interfaces: [])])
    }

    /// Drops a device from the rejected queue without authorising it.
    public func dismiss(_ rejection: Rejection) {
        Ledger.forget(rejection: rejection.device.id, paths)
    }

    /// Removes a device by its `vvvv:pppp/serial` id.
    ///
    /// Returns a reason on failure.
    public func revoke(id: String) -> String? {
        var next = policy
        guard let victim = next.allowed.first(where: { $0.id == id }) else {
            return "\(id) is not in the allowlist"
        }
        next.allowed.remove(victim)
        next.labels.removeValue(forKey: id)
        return commit(next)
    }

    /// Allows or refuses non-USB external storage, which cannot be allowlisted.
    ///
    /// Returns a reason on failure.
    public func setAllowOtherStorage(_ allowed: Bool) -> String? {
        var next = policy
        next.allowOtherStorage = allowed
        return commit(next)
    }

    private func commit(_ next: Policy) -> String? {
        if let why = Store.save(next, paths) { return why }
        reload()
        return nil
    }

    // MARK: - Approval

    private func dissenter(_ text: String) -> Unmanaged<DADissenter> {
        Unmanaged.passRetained(
            DADissenterCreate(
                kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), text as CFString))
    }

    fileprivate func approve(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        let current = policy
        let usable = status.isUsable
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return dissenter(current.message)
        }
        let bsd = description[kDADiskDescriptionMediaBSDNameKey as String] as? String ?? "?"
        let transport = Transport.of(description, isBehindUSB: Devices.isBehindUSB(bsdName: bsd))

        // Internal disks, disk images and network volumes are not ours. Returning
        // here keeps them out of the log, which would otherwise carry a line for
        // every dmg and every network mount on the machine.
        guard transport.isGoverned else { return nil }

        let attached = transport == .usb ? Devices.identify(bsdName: bsd) : nil
        // Name first: the log is read by a person, and a serial identifies nothing
        // to them. The id follows so it can still be matched to an allowlist entry.
        let identity =
            attached.map { "\($0.name) \($0.device.id)" }
            ?? (description[kDADiskDescriptionDeviceModelKey as String] as? String) ?? bsd

        switch decide(attached, policy: current, transport: transport, usable: usable) {
        case .allow:
            record("allow", identity, "[\(bsd)]")
            return nil
        case .blocked(let reason):
            record(
                "block", identity,
                "[\(bsd) \(transport.name)] \(reason.text)")
            note(
                attached, transport: transport, description: description, reason: reason,
                message: current.message)
            return dissenter(current.message)
        }
    }

    /// Writes what an admin actually changed, not just the new totals.
    ///
    /// "policy 3 allowed" tells nobody which drive was authorised or revoked. The
    /// audit trail needs the device, so the difference is logged instead.
    private func announceChanges(from previous: Policy, to next: Policy) {
        for device in next.allowed.subtracting(previous.allowed).sorted(by: { $0.id < $1.id }) {
            record("authorised", next.label(for: device), device.id)
        }
        for device in previous.allowed.subtracting(next.allowed).sorted(by: { $0.id < $1.id }) {
            record("revoked", previous.label(for: device), device.id)
        }
        if previous.allowOtherStorage != next.allowOtherStorage {
            record(
                "setting", "non-usb external storage",
                next.allowOtherStorage ? "allowed" : "refused")
        }
        if previous.interfaceClasses != next.interfaceClasses {
            let classes = next.interfaceClasses.sorted().map(\.name).joined(separator: ",")
            record("setting", "interface classes", classes)
        }
    }

    /// Tells the user a drive was refused, in the site's own words.
    ///
    /// Two fields and no tool name: the drive they just plugged in, and the site's
    /// own `ContactMessage`, which is the same sentence the mount dialog shows.
    /// Both reach osascript as arguments, never as script text, because the name
    /// comes from the device.
    private func announce(_ name: String, _ identity: String, _ message: String) {
        var console = stat()
        guard stat("/dev/console", &console) == 0, console.st_uid != 0 else { return }

        // Disk Arbitration can ask about the same disk more than once.
        let repeated = lastAnnounced.map {
            $0.identity == identity && Date().timeIntervalSince($0.at) < 5
        }
        guard repeated != true else { return }
        lastAnnounced = (identity, Date())

        let notification = Process()
        notification.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        notification.arguments = [
            "asuser", String(console.st_uid), "/usr/bin/osascript",
            "-e", "on run argv",
            "-e",
            "display notification (item 1 of argv) with title (item 2 of argv)",
            "-e", "end run",
            "--", message, name,
        ]
        try? notification.run()
    }

    /// Files the refusal in the list an admin can act on, or the one they cannot.
    func note(
        _ attached: Attached?, transport: Transport, description: [String: Any], reason: Reason,
        message: String = Policy.defaultMessage
    ) {
        if let attached, transport == .usb {
            Ledger.record(
                Rejection(device: attached.device, name: attached.name, reason: reason.text),
                paths.rejected, paths)
            announce(attached.name, attached.device.id, message)
            return
        }
        let model = description[kDADiskDescriptionDeviceModelKey as String] as? String
        let media = description[kDADiskDescriptionMediaNameKey as String] as? String
        // Calling a Thunderbolt drive a "USB device" in the notification would be
        // a lie, so the fallback names the transport it actually arrived on.
        let unnamed = transport == .usb ? Key.unnamedDevice : "\(transport.name) drive"
        let name = [model, media].compactMap(\.self).first { !$0.isEmpty } ?? unnamed
        Ledger.record(
            Denial(kind: transport.name, name: name, reason: reason.text), paths.denied, paths)
        announce(name, "\(transport.name)/\(name)", message)
    }

    /// Single os.Log interpolation site.
    ///
    /// Everything is marked public because this log is the audit trail and
    /// redaction would defeat it.
    private func record(_ verdict: String, _ identity: String, _ detail: String) {
        log.notice(
            "\(verdict, privacy: .public) \(identity, privacy: .public) \(detail, privacy: .public)"
        )
    }

    // MARK: - Sweep

    /// Converges volumes that mounted before the daemon started and so never saw the
    /// approval callback.
    ///
    /// Only valid once the session is scheduled: an unscheduled session drops the
    /// unmount request instead of sending it.
    func sweep(_ session: DASession) {
        let current = policy
        let usable = status.isUsable
        for bsd in Devices.mountedVolumes() {
            guard let partition = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                let description = DADiskCopyDescription(partition) as? [String: Any],
                Transport.of(description, isBehindUSB: Devices.isBehindUSB(bsdName: bsd))
                    .isGoverned,
                decide(
                    Devices.identify(bsdName: bsd), policy: current,
                    transport: .of(description, isBehindUSB: Devices.isBehindUSB(bsdName: bsd)),
                    usable: usable
                ).isBlocked
            else { continue }

            // kDADiskUnmountOptionWhole is rejected on a partition object; ask Disk
            // Arbitration for the whole disk so every partition goes at once.
            guard let whole = DADiskCopyWholeDisk(partition) else { continue }
            record("sweep", bsd, "unmount")
            DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), nil, nil)
        }
    }

    // MARK: - Run

    /// Registers the approval callback, schedules the session, sweeps, and serves.
    ///
    /// Never returns.
    public func run() -> Never {
        announces = true
        let queue = DispatchQueue(label: Self.domain)
        guard let created = DASessionCreate(kCFAllocatorDefault) else {
            log.fault("DASessionCreate failed")
            exit(1)
        }
        session = created
        queue.sync { reload() }

        watchAllowlist(on: queue)

        signal(SIGHUP, SIG_IGN)
        let hangup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: queue)
        hangup.setEventHandler { [weak self] in self?.reload() }
        hangup.resume()

        DARegisterDiskMountApprovalCallback(
            created, nil, approvalCallback, Unmanaged.passUnretained(self).toOpaque())
        DASessionSetDispatchQueue(created, queue)

        // Sweep only after scheduling: an unscheduled session drops the request.
        // The session is queue-confined from here on, so it never crosses an
        // isolation boundary.
        queue.async { [self] in
            guard let scheduled = session else { return }
            sweep(scheduled)
        }

        let current = policy
        record(
            "active", "usbgate \(Self.version)",
            "\(current.allowed.count) authorised")
        dispatchMain()
    }
}

extension Gate {
    /// Reloads when the allowlist file changes, so `usbgate allow` takes effect at once.
    ///
    /// The directory is watched rather than the file, because an atomic save replaces
    /// the inode and a watch on the old file would not survive it.
    fileprivate func watchAllowlist(on queue: DispatchQueue) {
        paths.ensureDirectory()
        let descriptor = open(paths.directory, O_EVTONLY)
        guard descriptor >= 0 else {
            log.error("cannot watch the allowlist directory, reload needs SIGHUP")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}

/// A C function pointer cannot capture, so the gate arrives through the context.
///
/// A missing context is an internal error and must still fail closed.
private let approvalCallback: DADiskMountApprovalCallback = { disk, context in
    guard let gate = context else {
        return Unmanaged.passRetained(
            DADissenterCreate(
                kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted),
                Policy.defaultMessage as CFString))
    }
    return Unmanaged<Gate>.fromOpaque(gate).takeUnretainedValue().approve(disk)
}
