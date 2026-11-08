import XCTest
@testable import FocusGuardCore

final class DNSQuestionTests: XCTestCase {
    // MARK: fixture builders

    func dnsQuery(_ name: String, id: UInt16 = 0x1234, qr: Bool = false, qdcount: UInt16 = 1) -> [UInt8] {
        var b: [UInt8] = []
        b += [UInt8(id >> 8), UInt8(id & 0xff)]
        b += [qr ? 0x81 : 0x01, 0x00]                 // flags: QR bit, RD set
        b += [UInt8(qdcount >> 8), UInt8(qdcount & 0xff), 0, 0, 0, 0, 0, 0]   // QD, AN, NS, AR
        for label in name.split(separator: ".") {
            b.append(UInt8(label.utf8.count))
            b += Array(label.utf8)
        }
        b.append(0)                                   // root label
        b += [0, 1, 0, 1]                             // QTYPE A, QCLASS IN
        return b
    }

    func udp(dstPort: UInt16 = 53, payload: [UInt8]) -> [UInt8] {
        let len = UInt16(8 + payload.count)
        return [0xc0, 0x00, UInt8(dstPort >> 8), UInt8(dstPort & 0xff), UInt8(len >> 8), UInt8(len & 0xff), 0, 0] + payload
    }

    func ipv4(proto: UInt8 = 17, ihl: UInt8 = 5, payload: [UInt8]) -> [UInt8] {
        let headerLen = Int(ihl) * 4
        let total = UInt16(headerLen + payload.count)
        var h: [UInt8] = [0x40 | ihl, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0, 0, 64, proto, 0, 0,
                          10, 0, 0, 2, 1, 1, 1, 1]
        h += [UInt8](repeating: 0, count: headerLen - 20)   // options, if ihl > 5
        return h + payload
    }

    func ipv6(nextHeader: UInt8 = 17, payload: [UInt8]) -> [UInt8] {
        let len = UInt16(payload.count)
        var h: [UInt8] = [0x60, 0, 0, 0, UInt8(len >> 8), UInt8(len & 0xff), nextHeader, 64]
        h += [UInt8](repeating: 0, count: 32)   // src + dst
        return h + payload
    }

    func ethernet(type: UInt16, payload: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + [UInt8(type >> 8), UInt8(type & 0xff)] + payload
    }

    /// BSD loopback/utun framing: 4-byte address family in host byte order.
    func nullFrame(family: UInt32, payload: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: family) { Array($0) } + payload
    }

    // MARK: tests

    func testEthernetIPv4Query() {
        let frame = ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: dnsQuery("mangadex.org"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .ethernet), ["mangadex.org"])
    }

    func testEthernetIPv6Query() {
        let frame = ethernet(type: 0x86DD, payload: ipv6(payload: udp(payload: dnsQuery("MangaPlus.Shueisha.co.jp"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .ethernet), ["mangaplus.shueisha.co.jp"])
    }

    func testNullLinkIPv4Query() {
        let frame = nullFrame(family: 2, payload: ipv4(payload: udp(payload: dnsQuery("read-manga.net"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .null), ["read-manga.net"])
    }

    func testNullLinkBigEndianFamily() {
        let frame: [UInt8] = [0, 0, 0, 2] + ipv4(payload: udp(payload: dnsQuery("example.com")))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .null), ["example.com"])
    }

    func testNullLinkIPv6Query() {
        let frame = nullFrame(family: 30, payload: ipv6(payload: udp(payload: dnsQuery("example.com"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .null), ["example.com"])
    }

    func testIPv4OptionsAreSkipped() {
        let frame = ethernet(type: 0x0800, payload: ipv4(ihl: 6, payload: udp(payload: dnsQuery("example.com"))))
        XCTAssertEqual(DNSQuestion.names(in: frame, link: .ethernet), ["example.com"])
    }

    func testAnswersAndNonDNSAreIgnored() {
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: dnsQuery("a.com", qr: true)))), link: .ethernet), [])
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(dstPort: 443, payload: dnsQuery("a.com")))), link: .ethernet), [])
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(proto: 6, payload: udp(payload: dnsQuery("a.com")))), link: .ethernet), [], "TCP")
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0806, payload: [0, 1, 2, 3]), link: .ethernet), [], "ARP")
    }

    func testCompressedOrMalformedNamesAreRejected() {
        var compressed = dnsQuery("a.com")
        compressed[12] = 0xC0   // first label byte is a pointer
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: compressed))), link: .ethernet), [])

        let truncated = Array(ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: dnsQuery("example.com")))).dropLast(6))
        XCTAssertEqual(DNSQuestion.names(in: truncated, link: .ethernet), [])

        XCTAssertEqual(DNSQuestion.names(in: [UInt8](repeating: 0, count: 10), link: .ethernet), [])
        XCTAssertEqual(DNSQuestion.names(in: [], link: .null), [])
    }

    func testMultipleQuestions() {
        var two = dnsQuery("a.com", qdcount: 2)
        two += dnsQuery("b.org").dropFirst(12)   // second question only
        XCTAssertEqual(DNSQuestion.names(in: ethernet(type: 0x0800, payload: ipv4(payload: udp(payload: two))), link: .ethernet), ["a.com", "b.org"])
    }
}
