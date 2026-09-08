import Foundation

/// Terminal styling.
///
/// Every colour is dropped when stdout is not a terminal, so piped output stays
/// plain text.
enum Term {
    static let isTTY = isatty(STDOUT_FILENO) == 1

    private static func paint(_ code: String, _ text: String) -> String {
        isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    // Status tags.
    static var ok: String { paint("32", "[+]") }
    static var no: String { paint("31", "[-]") }
    static var info: String { paint("34", "[*]") }
    static var warn: String { paint("33", "[!]") }

    static func dim(_ text: String) -> String { paint("2", text) }
    static func bold(_ text: String) -> String { paint("1", text) }
    /// Section header, bold and underlined.
    static func heading(_ text: String) -> String { paint("1;4", text) }
    /// A literal you type.
    static func command(_ text: String) -> String { paint("36", text) }
    /// A placeholder you replace.
    static func argument(_ text: String) -> String { paint("2;36", text) }
}
