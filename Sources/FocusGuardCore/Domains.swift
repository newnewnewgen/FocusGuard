import Foundation

public enum DomainNormalizer {
    /// "https://www.Reddit.com/r/x" → "reddit.com". Returns "" for input with no host.
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        if let i = s.firstIndex(of: ":") { s = String(s[..<i]) }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }

    /// True when `host` equals `domain` or is a subdomain of it. Both must already be normalized.
    public static func host(_ host: String, isUnder domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
