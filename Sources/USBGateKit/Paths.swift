import Foundation

/// Where usbgate keeps its state, and who must own it.
///
/// `/var/db` is `root:wheel 0755`, so an admin cannot slip a file in without
/// `sudo`. The owner is carried here rather than hardcoded so the whole flow can
/// be exercised in a temporary directory without root.
public struct Paths: Sendable {
    /// The real location, owned by root.
    public static let system = Self(directory: "/var/db/usbgate", owner: 0)

    /// A sandbox owned by the current user, for tests.
    public static func sandbox(_ directory: String) -> Self {
        Self(directory: directory, owner: getuid())
    }

    let directory: String
    let owner: uid_t

    /// The allowlist itself.
    public var allowlist: String { directory + "/allowlist.plist" }
    /// The queue of refused USB drives that could be authorised.
    public var rejected: String { directory + "/rejected.plist" }
    /// Refusals nobody can act on, kept for incident review.
    public var denied: String { directory + "/denied.plist" }

    /// Creates the directory if absent.
    ///
    /// Requires the right privileges; harmless otherwise.
    func ensureDirectory() {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755, .ownerAccountID: NSNumber(value: owner)])
    }

    /// Rejects a file anyone but the expected owner could have written.
    ///
    /// Pure, so the rule can be tested without staging files as root.
    func rejection(ownerID: Int, permissions: Int) -> String? {
        if ownerID != Int(owner) { return owner == 0 ? "not owned by root" : "wrong owner" }
        if permissions & 0o022 != 0 { return "writable by group or others" }
        return nil
    }

    /// Writes a plist owned by `owner` and not writable by anyone else.
    func write(_ value: Any, to path: String) -> String? {
        ensureDirectory()
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: value, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644, .ownerAccountID: NSNumber(value: owner)],
                ofItemAtPath: path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Reads a plist, refusing one the wrong person could have written.
    func read(_ path: String) -> Result<Any, Store.Status> {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return .failure(.missing) }
        guard let attributes = try? manager.attributesOfItem(atPath: path),
            let fileOwner = attributes[.ownerAccountID] as? NSNumber,
            let permissions = attributes[.posixPermissions] as? NSNumber
        else { return .failure(.untrusted("cannot read file attributes")) }

        if let why = rejection(ownerID: fileOwner.intValue, permissions: permissions.intValue) {
            return .failure(.untrusted(why))
        }
        guard let data = manager.contents(atPath: path),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return .failure(.malformed) }
        return .success(root)
    }
}
