import Foundation

public enum DomainNormalizer {
    /// A plausible public hostname exactly as given: ASCII letters, digits, hyphens and dots, at
    /// least one dot, no empty label, no label over 63 characters, at most 253 in all. Used for
    /// names that arrive from the network (learned from DNS questions) and so must be checked
    /// before they can reach /etc/hosts; nothing else about them is trusted.
    public static func isHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, s.contains("."),
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return false }
        return s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0.count <= 63 }
    }

    /// "https://www.Reddit.com/r/x" → "reddit.com". Returns "" for anything that is not a plausible public hostname.
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let i = s.firstIndex(of: ":") { s = String(s[..<i]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if s.hasPrefix("www.") { s.removeFirst(4) }
        // Must look like a hostname: ASCII letters/digits/hyphens/dots, at least one dot, no empty labels.
        let hostnameChars = s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
        guard hostnameChars, s.contains("."), !s.contains("..") else { return "" }
        return s
    }

    /// True when `host` equals `domain` or is a subdomain of it. Both must already be normalized.
    public static func host(_ host: String, isUnder domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
