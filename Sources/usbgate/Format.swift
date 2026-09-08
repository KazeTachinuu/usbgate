import Foundation

/// Turning values into the words shown to a person.

/// "1 drive", not "1 drives".
func count(_ total: Int, _ singular: String, _ plural: String) -> String {
    "\(total) \(total == 1 ? singular : plural)"
}

/// Compact relative time, so a list reads at a glance.
func ago(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(seconds / 60)m ago"
    case ..<86400: return "\(seconds / 3600)h ago"
    default: return "\(seconds / 86400)d ago"
    }
}

/// The second line under every refusal: when, how often, and why.
func detail(_ last: Date, _ count: Int, _ reason: String) -> String {
    "\(ago(last))\(count > 1 ? " x\(count)" : "") - \(reason)"
}
