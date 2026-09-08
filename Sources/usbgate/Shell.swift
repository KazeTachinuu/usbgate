import Foundation

/// Talking to the terminal and to the process: exits, prompts, privilege.

/// Prints to stderr and stops.
///
/// Exit 1 for a refusal, 2 for a usage mistake.
func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(Term.no) \(message)\n".utf8))
    exit(code)
}

/// Says what is happening before anything that can pause.
///
/// Flushed at once: a command that sits silent looks like it has hung.
func progress(_ text: String) {
    print("  \(Term.dim(text))")
    unsafe fflush(stdout)
}

/// Argument mistakes are reported before this, so nobody types a password only to
/// be told the command was wrong.
func requireRoot(_ action: String) {
    guard getuid() == 0 else { fail("\(action) needs sudo") }
}

/// How many rows a list should print.
func rowCount(_ argument: String?) -> Int {
    switch argument {
    case nil: return defaultRows
    case "all": return .max
    case .some(let text):
        guard let rows = Int(text), rows > 0 else {
            fail("'\(text)' is not a number or 'all'", code: 2)
        }
        return rows
    }
}

/// Runs a command that changes state, reporting the reason if it fails.
func apply(_ reason: String?, _ success: String) -> Never {
    if let reason { fail(reason) }
    print("  \(Term.ok) \(success)")
    exit(0)
}
