import Foundation

/// Extracts the question names from a captured DNS query frame (keyword spec §5). Pure: the
/// daemon hands it bytes from libpcap. Anything that is not a plain UDP query to port 53 with
/// uncompressed names yields no names; nothing here trusts the packet.
public enum DNSQuestion {
    public enum LinkType {
        /// 14-byte Ethernet header (Wi-Fi and wired).
        case ethernet
        /// BSD "null" framing: a 4-byte address family in host byte order (loopback, `utun`).
        case null
    }

    private static let maxQuestions = 4

    public static func names(in frame: [UInt8], link: LinkType) -> [String] {
        guard let (ipStart, isV6) = ipStart(of: frame, link: link),
              let udpStart = udpStart(of: frame, at: ipStart, isV6: isV6),
              frame.count >= udpStart + 8 else { return [] }
        let dstPort = UInt16(frame[udpStart + 2]) << 8 | UInt16(frame[udpStart + 3])
        guard dstPort == 53 else { return [] }
        return questions(in: frame, at: udpStart + 8)
    }

    /// Offset of the IP header and whether it is IPv6, from the link-layer framing.
    private static func ipStart(of frame: [UInt8], link: LinkType) -> (Int, Bool)? {
        switch link {
        case .ethernet:
            guard frame.count >= 14 else { return nil }
            let type = UInt16(frame[12]) << 8 | UInt16(frame[13])
            if type == 0x0800 { return (14, false) }
            if type == 0x86DD { return (14, true) }
            return nil
        case .null:
            guard frame.count >= 4 else { return nil }
            // DLT_NULL carries the family in host byte order (little-endian on macOS); DLT_LOOP
            // in network byte order. Accept either. AF_INET = 2, AF_INET6 = 30.
            let le = UInt32(frame[0]) | UInt32(frame[1]) << 8 | UInt32(frame[2]) << 16 | UInt32(frame[3]) << 24
            let be = UInt32(frame[3]) | UInt32(frame[2]) << 8 | UInt32(frame[1]) << 16 | UInt32(frame[0]) << 24
            if le == 2 || be == 2 { return (4, false) }
            if le == 30 || be == 30 { return (4, true) }
            return nil
        }
    }

    /// Offset of the UDP header, or nil when the transport is not UDP (IPv6 extension headers
    /// are not followed; a DNS query never carries them in practice).
    private static func udpStart(of frame: [UInt8], at ip: Int, isV6: Bool) -> Int? {
        if isV6 {
            guard frame.count >= ip + 40, frame[ip] >> 4 == 6, frame[ip + 6] == 17 else { return nil }
            return ip + 40
        }
        guard frame.count >= ip + 20, frame[ip] >> 4 == 4, frame[ip + 9] == 17 else { return nil }
        let headerLen = Int(frame[ip] & 0x0f) * 4
        guard headerLen >= 20 else { return nil }
        return ip + headerLen
    }

    private static func questions(in frame: [UInt8], at dns: Int) -> [String] {
        guard frame.count >= dns + 12, frame[dns + 2] & 0x80 == 0 else { return [] }   // QR = query
        let qdcount = Int(frame[dns + 4]) << 8 | Int(frame[dns + 5])
        guard (1...maxQuestions).contains(qdcount) else { return [] }
        var names: [String] = []
        var i = dns + 12
        for _ in 0..<qdcount {
            var labels: [String] = []
            var total = 0
            while true {
                guard i < frame.count else { return [] }
                let len = Int(frame[i])
                if len == 0 { i += 1; break }
                guard len & 0xC0 == 0 else { return [] }   // compression pointer: not in a query
                guard i + 1 + len <= frame.count else { return [] }
                total += len + 1
                guard total <= 255 else { return [] }
                labels.append(String(decoding: frame[(i + 1)..<(i + 1 + len)], as: UTF8.self))
                i += 1 + len
            }
            guard i + 4 <= frame.count, !labels.isEmpty else { return [] }
            i += 4   // QTYPE, QCLASS
            names.append(labels.joined(separator: ".").lowercased())
        }
        return names
    }
}
