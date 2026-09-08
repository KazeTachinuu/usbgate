import Foundation
import USBGateKit

/// The help text.
enum Usage {
    /// One row of the command table.
    private struct Command {
        let name: String
        let argument: String
        let help: String

        /// Width of the typed part, used to align the help column.
        var width: Int { argument.isEmpty ? name.count : name.count + argument.count + 1 }

        func rendered(to width: Int) -> String {
            let typed =
                argument.isEmpty
                ? Term.command(name)
                : "\(Term.command(name)) \(Term.argument(argument))"
            let padding = String(repeating: " ", count: max(0, width - self.width))
            return "  \(typed)\(padding)   \(help)"
        }
    }

    private static let commands = [
        Command(
            name: "rejected", argument: "[n|all]", help: "drives that were refused, newest first"),
        Command(name: "allow", argument: "", help: "authorise one of them"),
        Command(name: "dismiss", argument: "", help: "drop one from that list"),
        Command(
            name: "allow", argument: "all", help: "authorise every attached drive, after confirming"
        ),
        Command(name: "revoke", argument: "", help: "pick an authorised drive and remove it"),
        Command(name: "status", argument: "", help: "what is authorised, and what is plugged in"),
        Command(
            name: "other", argument: "on|off", help: "allow or refuse non-USB external storage"),
        Command(name: "watch", argument: "", help: "stream decisions as they happen"),
        Command(name: "log", argument: "[since]", help: "past decisions, 7d by default"),
        Command(name: "version", argument: "", help: "print the version"),
    ]

    /// clap-style help: bold headings, the words you type in colour, aligned.
    /// clap-style help: bold headings, the words you type in colour, aligned.
    static func text() -> String {
        let width = commands.map(\.width).max() ?? 0
        let rows = commands.map { $0.rendered(to: width) }.joined(separator: "\n")
        return """
            \(Term.bold("usbgate")) \(Gate.version)
            USB storage allowlist for macOS

            \(Term.heading("Usage:")) \(Term.command("usbgate")) \(Term.argument("<command>"))

            \(Term.heading("Commands:"))
            \(rows)

            \(Term.dim("allow, revoke, dismiss and other need sudo."))
            \(Term.dim("The daemon applies changes immediately; no restart, no reload."))
            """
    }
}
