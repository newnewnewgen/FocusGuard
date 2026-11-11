import Foundation

/// Turns pasted or imported free text into site names or keywords, for adding many at once.
public enum BulkInput {
    public struct Sites: Equatable {
        /// Normalized, unique, in input order.
        public var accepted: [String]
        /// The original tokens that did not normalize, unique, in input order.
        public var rejected: [String]
        public init(accepted: [String], rejected: [String]) {
            self.accepted = accepted
            self.rejected = rejected
        }
    }

    public struct Keywords: Equatable {
        public var accepted: [String]
        public var rejected: [String]
        public init(accepted: [String], rejected: [String]) {
            self.accepted = accepted
            self.rejected = rejected
        }
    }

    public struct ChromeURLs: Equatable {
        public var accepted: [String]
        public var rejected: [String]
        public init(accepted: [String], rejected: [String]) {
            self.accepted = accepted
            self.rejected = rejected
        }
    }

    /// Splits free text into site names. Separators: newlines, commas, semicolons, tabs, spaces.
    /// A hosts-file style line ("0.0.0.0 example.com", "127.0.0.1 a.com b.com", "::1 x.org") yields
    /// the names after the address; lines starting with "#" (after trimming) are comments and
    /// ignored; a trailing "# comment" on a line is dropped. Each token goes through
    /// `DomainNormalizer.normalize`; empty results are rejected, and so are bare IP addresses —
    /// they are not sites.
    public static func sites(from text: String) -> Sites {
        var accepted: [String] = []
        var rejected: [String] = []
        var seenAccepted = Set<String>()
        var seenRejected = Set<String>()
        for line in lines(of: text) {
            var tokens = split(line)
            if tokens.count > 1, isIPAddress(tokens[0]) { tokens.removeFirst() }
            for token in tokens {
                let host = DomainNormalizer.normalize(token)
                if host.isEmpty || isIPAddress(host) {
                    if seenRejected.insert(token).inserted { rejected.append(token) }
                } else if seenAccepted.insert(host).inserted {
                    accepted.append(host)
                }
            }
        }
        return Sites(accepted: accepted, rejected: rejected)
    }

    /// Same splitting and comment handling (no hosts-file handling), each token through
    /// `KeywordRule.normalize`.
    public static func keywords(from text: String) -> Keywords {
        var accepted: [String] = []
        var rejected: [String] = []
        var seenAccepted = Set<String>()
        var seenRejected = Set<String>()
        for line in lines(of: text) {
            for token in split(line) {
                if let word = KeywordRule.normalize(token) {
                    if seenAccepted.insert(word).inserted { accepted.append(word) }
                } else if seenRejected.insert(token).inserted {
                    rejected.append(token)
                }
            }
        }
        return Keywords(accepted: accepted, rejected: rejected)
    }

    /// Same splitting and comment handling (no hosts-file handling), each token through
    /// `ChromeURLPattern.normalize`. A pattern never needs a `#` (Chrome ignores fragments), so
    /// the comment rule costs nothing.
    public static func chromeURLs(from text: String) -> ChromeURLs {
        var accepted: [String] = []
        var rejected: [String] = []
        var seenAccepted = Set<String>()
        var seenRejected = Set<String>()
        for line in lines(of: text) {
            for token in split(line) {
                if let pattern = ChromeURLPattern.normalize(token) {
                    if seenAccepted.insert(pattern).inserted { accepted.append(pattern) }
                } else if seenRejected.insert(token).inserted {
                    rejected.append(token)
                }
            }
        }
        return ChromeURLs(accepted: accepted, rejected: rejected)
    }

    // MARK: - Pieces

    /// Non-empty, non-comment lines with any trailing "# …" removed and whitespace trimmed.
    static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { raw in
            var line = Substring(raw)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static let separators = CharacterSet(charactersIn: ",;\t ")

    static func split(_ line: String) -> [String] {
        line.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// An IPv4 dotted quad, or something with the shape of an IPv6 address.
    static func isIPAddress(_ s: String) -> Bool {
        let s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if s.contains(":") {
            // Hex digits, colons, and dots (for IPv4-mapped forms); at least two colons.
            return s.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } && s.filter({ $0 == ":" }).count >= 2
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && Int($0).map { $0 <= 255 } == true }
    }
}
