import Foundation
import USBGateKit

/// Reading decisions back out of the unified log.
enum Log {
    /// What happened to a drive, plus daemon start and policy changes.
    ///
    /// Everything else the daemon writes is reload bookkeeping, which `usbgate
    /// status` shows as current state instead.
    static let events: Set<String> = [
        "allow", "block", "sweep", "active", "authorised", "revoked", "setting",
    ]

    /// One decision, as read back from the unified log.
    struct Entry {
        let time: String
        let message: String
    }

    /// Splits one compact `log` line into the time and the message.
    ///
    /// A compact line looks like:
    ///   2026-09-08 18:00:22.214 Df usbgate[123:abc] [<subsystem>:policy] block ...
    /// Everything before the subsystem tag is machine detail nobody reads. Lines
    /// without that tag are the tool's own header and are dropped.
    static func decision(from line: String) -> Entry? {
        guard let tag = line.range(of: "[\(Gate.domain):policy] ") else { return nil }
        let message = line[tag.upperBound...].trimmingCharacters(in: .whitespaces)
        guard events.contains(String(message.prefix { $0 != " " })) else { return nil }

        // Characters 11..<19 of the fixed timestamp are HH:MM:SS.
        let time = line.dropFirst(11).prefix(8)
        return Entry(time: time.contains(":") ? String(time) : "", message: message)
    }

    /// Whether a string is a window `log show --last` understands: 30m, 24h, 7d.
    static func isWindow(_ text: String) -> Bool {
        let digits = text.prefix(while: \.isNumber)
        return !digits.isEmpty
            && ["s", "m", "h", "d", ""].contains(String(text.dropFirst(digits.count)))
    }

    private static func reader(live: Bool, window: String) -> (Process, FileHandle) {
        let unified = Process()
        unified.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        unified.arguments =
            (live ? ["stream"] : ["show", "--last", window])
            + ["--predicate", "subsystem == \"\(Gate.domain)\"", "--style", "compact"]

        let pipe = Pipe()
        unified.standardOutput = pipe
        unified.standardError = FileHandle.nullDevice
        return (unified, pipe.fileHandleForReading)
    }

    /// Feeds whole lines to `handle`, trimming the buffer once per chunk.
    ///
    /// Trimming per line instead would copy the remainder every time, which turns
    /// reading a long history into quadratic work.
    private static func eachLine(from handle: FileHandle, _ body: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)

            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                if let line = String(bytes: buffer[start..<newline], encoding: .utf8) {
                    body(line)
                }
                start = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<start)
        }
    }

    /// Hands the unified log to the user, one readable line per decision.
    static func show(live: Bool, since window: String) -> Never {
        if !live, !isWindow(window) {
            fail("'\(window)' is not a time window; try 30m, 24h or 7d", code: 2)
        }
        let (unified, handle) = reader(live: live, window: window)

        print("")
        progress(live ? "streaming decisions, ctrl-c to stop" : "reading the last \(window)")
        print("")
        do { try unified.run() } catch { fail("cannot run /usr/bin/log: \(error)") }

        var repeats = Repeats(collapsing: !live)
        eachLine(from: handle) { repeats.take($0) }
        repeats.flush()
        unified.waitUntilExit()

        guard unified.terminationStatus == 0 else { fail("/usr/bin/log failed") }
        if !live, repeats.isEmpty { print("  \(Term.dim("nothing in that window"))") }
        print("")
        exit(0)
    }

    /// Collapses runs of the same message into one line with a count.
    struct Repeats {
        /// Live output prints each line as it arrives.
        ///
        /// Holding one back to see whether the next is identical would mean the
        /// first event of a `watch` never appears until a second, different one does.
        let collapsing: Bool
        private var pending: (entry: Entry, count: Int)?
        private(set) var isEmpty = true

        init(collapsing: Bool) { self.collapsing = collapsing }

        mutating func take(_ line: String) {
            guard let entry = decision(from: line) else { return }
            isEmpty = false

            if var held = pending, collapsing, held.entry.message == entry.message {
                held.count += 1
                pending = held
                return
            }
            flush()
            pending = (entry, 1)
            guard !collapsing else { return }
            flush()
            // Piped output is block buffered, so `usbgate watch | grep` would show
            // nothing until the buffer filled or the process ended.
            unsafe fflush(stdout)
        }

        mutating func flush() {
            guard let held = pending else { return }
            pending = nil
            let repeated = held.count > 1 ? Term.dim("  x\(held.count)") : ""
            print("  \(Term.dim(held.entry.time))  \(paint(held.entry.message))\(repeated)")
        }

        /// Colour by the first word: what happened.
        private func paint(_ message: String) -> String {
            let verb = message.prefix { $0 != " " }
            let rest = message.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
            let tag =
                switch verb {
                case "allow", "authorised": Term.ok
                case "block", "sweep", "revoked": Term.warn
                default: Term.info
                }
            return "\(tag) \(Term.bold(String(verb))) \(rest)"
        }
    }
}
