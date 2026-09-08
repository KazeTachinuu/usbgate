import Foundation

/// One row of a refusal list on disk.
protocol LedgerEntry: Hashable, Sendable {
    /// Identity used to collapse repeat sightings into one row.
    var key: String { get }
    /// When it was last refused.
    var last: Date { get }
    /// How many times it has been refused.
    var count: Int { get }
    /// Reads one row back, returning nil if it is malformed.
    init?(row: [String: Any])
    /// The row as written to disk.
    var row: [String: Any] { get }
    /// A copy stamped with a new time and count.
    func seenAgain(at date: Date, count: Int) -> Self
}

/// Storage shared by both refusal lists: newest first, deduplicated, capped.
///
/// One implementation so the two lists cannot drift apart in ordering, dedup or
/// growth behaviour.
enum Ledger {
    /// Most rows either list keeps.
    ///
    /// High enough to be effectively unlimited in normal use, since repeats
    /// collapse into one row. It is a cap and not unbounded because a programmable
    /// device can report a fresh serial on every attach, and this file is written
    /// by root. Anything dropped is still in the unified log.
    static let limit = 1000

    static func load<Entry: LedgerEntry>(_ path: String, _ paths: Paths) -> [Entry] {
        guard case .success(let root) = paths.read(path), let rows = root as? [[String: Any]]
        else { return [] }
        return rows.compactMap(Entry.init(row:)).sorted { $0.last > $1.last }
    }

    @discardableResult
    static func save<Entry: LedgerEntry>(
        _ entries: [Entry], _ path: String, _ paths: Paths
    ) -> String? {
        paths.write(entries.map(\.row), to: path)
    }

    static func record<Entry: LedgerEntry>(
        _ entry: Entry, _ path: String, _ paths: Paths, now: Date = Date(),
        limit: Int = Self.limit
    ) {
        var entries: [Entry] = load(path, paths)
        let seen = entries.first { $0.key == entry.key }?.count ?? 0
        entries.removeAll { $0.key == entry.key }
        entries.insert(entry.seenAgain(at: now, count: seen + 1), at: 0)
        save(Array(entries.prefix(limit)), path, paths)
    }

    /// Drops one drive from the actionable list, once authorised or dismissed.
    ///
    /// Only that list is ever edited: the other one is a record, not a queue.
    static func forget(rejection key: String, _ paths: Paths) {
        let entries: [Rejection] = load(paths.rejected, paths)
        save(entries.filter { $0.key != key }, paths.rejected, paths)
    }
}
