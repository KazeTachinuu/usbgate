import Foundation

/// Reads and writes the allowlist file.
public enum Store {
    /// Where the running allowlist came from, so `status` is never ambiguous.
    public enum Status: Equatable, Sendable, Error {
        case loaded(Int)
        case missing
        case untrusted(String)
        case malformed

        /// One line describing the state, shown by `usbgate status`.
        public var text: String {
            switch self {
            case .loaded(let count): "\(count) authorised"
            case .missing: "no allowlist yet, nothing is authorised"
            case .untrusted(let why): "allowlist ignored: \(why)"
            case .malformed: "allowlist is not a readable plist"
            }
        }

        /// Only a successfully loaded file lets anything mount.
        public var isUsable: Bool {
            if case .loaded = self { return true }
            return false
        }

        /// True when something is actually wrong, as opposed to not set up yet.
        ///
        /// A missing allowlist on a fresh install is the expected starting state:
        /// it refuses everything, which is correct. A file the wrong person can
        /// write, or one that will not parse, is a fault.
        public var isFault: Bool {
            switch self {
            case .untrusted, .malformed: true
            case .loaded, .missing: false
            }
        }
    }

    static func load(_ paths: Paths) -> (Policy, Status) {
        switch paths.read(paths.allowlist) {
        case .failure(let status):
            return (Policy(), status)
        case .success(let root):
            guard let fields = root as? [String: Any] else { return (Policy(), .malformed) }
            let policy = policy(from: fields)
            return (policy, .loaded(policy.allowed.count))
        }
    }

    static func policy(
        from fields: [String: Any], onDrop: (String) -> Void = { _ in () }
    ) -> Policy {
        var policy = Policy()
        let entries = fields[Key.Allowlist.devices] as? [[String: Any]] ?? []
        policy.allowed = parseDevices(entries, onDrop: onDrop)
        for device in policy.allowed {
            let match = entries.first {
                parseNumber($0[Key.Device.vendor]) == device.vendor
                    && parseNumber($0[Key.Device.product]) == device.product
                    && ($0[Key.Device.serial] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) == device.serial
            }
            policy.labels[device.id] = match?[Key.Device.label] as? String ?? Key.unnamedDevice
        }
        if let classes = parseInterfaceClasses(fields[Key.Allowlist.interfaceClasses]) {
            policy.interfaceClasses = classes
        }
        policy.allowOtherStorage = fields[Key.Allowlist.otherStorage] as? Bool ?? false
        if let text = fields[Key.Allowlist.message] as? String, !text.isEmpty {
            policy.message = text
        }
        return policy
    }

    static func fields(from policy: Policy) -> [String: Any] {
        [
            Key.Allowlist.devices: policy.allowed.sorted { $0.id < $1.id }.map { device in
                var entry = device.entry
                entry[Key.Device.label] = policy.labels[device.id] ?? Key.unnamedDevice
                return entry
            },
            Key.Allowlist.interfaceClasses: policy.interfaceClasses.sorted().map(\.name),
            Key.Allowlist.otherStorage: policy.allowOtherStorage,
            Key.Allowlist.message: policy.message,
        ]
    }

    static func save(_ policy: Policy, _ paths: Paths) -> String? {
        paths.write(fields(from: policy), to: paths.allowlist)
    }
}
