import Foundation

/// The daemon owns exactly one marked region in /etc/hosts and never touches anything else.
public enum HostsRegion {
    public static let startMarker = "# FOCUSGUARD START"
    public static let endMarker = "# FOCUSGUARD END"

    /// Public DNS-over-HTTPS resolvers. Sinkholed whenever any block is active so Chrome
    /// (automatic secure DNS) and Firefox (default TRR mode) fall back to the system resolver,
    /// which honours this file. Zero runtime cost; replaces the need for a browser tab watcher.
    public static let dohEndpoints: [String] = [
        "dns.google", "cloudflare-dns.com", "mozilla.cloudflare-dns.com",
        "dns.quad9.net", "doh.opendns.com", "dns.nextdns.io",
    ]

    /// Body of the region: both A (0.0.0.0) and AAAA (::) sinks for each domain and its www. form,
    /// followed by the DoH endpoints.
    public static func render(domains: Set<String>) -> String {
        var lines: [String] = []
        for d in domains.sorted() {
            lines += ["0.0.0.0 \(d)", "0.0.0.0 www.\(d)", ":: \(d)", ":: www.\(d)"]
        }
        if !domains.isEmpty {
            for d in dohEndpoints { lines += ["0.0.0.0 \(d)", ":: \(d)"] }
        }
        return lines.joined(separator: "\n")
    }

    /// Returns `contents` with the region replaced (or removed when `domains` is empty).
    public static func apply(domains: Set<String>, to contents: String) -> String {
        let stripped = strip(contents)
        if domains.isEmpty { return stripped }
        let region = [startMarker, render(domains: domains), endMarker].joined(separator: "\n")
        let base = (stripped.isEmpty || stripped.hasSuffix("\n")) ? stripped : stripped + "\n"
        return base + region + "\n"
    }


    /// Removes the marked region. A missing end marker strips to end of file. A file with no
    /// region is returned unchanged.
    public static func strip(_ contents: String) -> String {
        var kept: [Substring] = []
        var inRegion = false
        var sawRegion = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == startMarker { inRegion = true; sawRegion = true; continue }
            if trimmed == endMarker, inRegion { inRegion = false; continue }
            if !inRegion { kept.append(line) }
        }
        guard sawRegion else { return contents }
        if inRegion, !kept.isEmpty { kept.append("") }  // unterminated region: keep the preceding line's newline
        return kept.joined(separator: "\n")
    }
}
