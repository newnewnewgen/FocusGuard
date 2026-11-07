import CPcap
import Darwin
import FocusGuardCore
import Foundation
import Network

/// Receives the Mac's outbound DNS questions (keyword spec §5). One libpcap handle per active
/// interface (`en*`, `utun*`) with the kernel filter `udp and dst port 53`, so the process is
/// woken for DNS questions only; frames are parsed by `DNSQuestion` and names handed to
/// `onName` on the main queue. Interfaces are re-enumerated when the network path changes
/// (`NWPathMonitor`), never on a timer. Needs root to open BPF devices; the daemon has it.
final class DNSWatcher {
    var onName: ((String) -> Void)?
    /// Human-readable, published in `DaemonStatus.dnsWatch`.
    private(set) var state = "off"
    var isRunning: Bool { monitor != nil }

    private struct Capture {
        let interface: String
        let handle: OpaquePointer
        let source: DispatchSourceRead
        let link: DNSQuestion.LinkType
    }

    private let log: ReconcilerLog
    private var captures: [Capture] = []
    private var monitor: NWPathMonitor?

    init(log: ReconcilerLog) {
        self.log = log
    }

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.reopen() }
        }
        m.start(queue: .main)
        monitor = m
        reopen()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        closeAll()
        state = "off"
    }

    // MARK: Interfaces

    /// Up, running, non-loopback interfaces with an address, named en* or utun*.
    private static func activeInterfaces() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var names = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == AF_INET || addr.pointee.sa_family == AF_INET6
            else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("utun") { names.insert(name) }
        }
        return names.sorted()
    }

    private func reopen() {
        let wanted = Self.activeInterfaces()
        guard wanted != captures.map(\.interface) else { return }
        closeAll()
        for name in wanted { open(name) }
        let watching = captures.map(\.interface)
        state = watching.isEmpty ? "error: no interface could be opened" : "watching " + watching.joined(separator: ", ")
        log.info("keyword watch: \(state)")
    }

    private func closeAll() {
        for c in captures {
            c.source.cancel()
            pcap_close(c.handle)
        }
        captures = []
    }

    private func open(_ interface: String) {
        var errbuf = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        guard let handle = pcap_create(interface, &errbuf) else {
            log.error("keyword watch: pcap_create \(interface): \(String(cString: errbuf))")
            return
        }
        pcap_set_snaplen(handle, 512)            // a DNS question fits; nothing more is read
        pcap_set_promisc(handle, 0)
        pcap_set_timeout(handle, 100)
        pcap_set_immediate_mode(handle, 1)       // deliver each packet as it arrives
        guard pcap_activate(handle) == 0 else {
            log.error("keyword watch: activate \(interface): \(String(cString: pcap_geterr(handle)))")
            pcap_close(handle)
            return
        }
        var program = bpf_program()
        guard pcap_compile(handle, &program, "udp and dst port 53", 1, PCAP_NETMASK_UNKNOWN) == 0,
              pcap_setfilter(handle, &program) == 0 else {
            log.error("keyword watch: filter \(interface): \(String(cString: pcap_geterr(handle)))")
            pcap_close(handle)
            return
        }
        pcap_freecode(&program)
        pcap_setnonblock(handle, 1, &errbuf)
        let link: DNSQuestion.LinkType
        switch pcap_datalink(handle) {
        case DLT_EN10MB: link = .ethernet
        case DLT_NULL, DLT_LOOP: link = .null
        default:
            log.error("keyword watch: \(interface) has link type \(pcap_datalink(handle)); skipped")
            pcap_close(handle)
            return
        }
        let fd = pcap_get_selectable_fd(handle)
        guard fd >= 0 else {
            log.error("keyword watch: \(interface) has no selectable descriptor; skipped")
            pcap_close(handle)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.drain(handle, link: link) }
        source.resume()
        captures.append(Capture(interface: interface, handle: handle, source: source, link: link))
    }

    /// Read every packet the kernel has queued, parse, hand names up.
    private func drain(_ handle: OpaquePointer, link: DNSQuestion.LinkType) {
        var header: UnsafeMutablePointer<pcap_pkthdr>?
        var data: UnsafePointer<UInt8>?
        while pcap_next_ex(handle, &header, &data) == 1 {
            guard let h = header?.pointee, let d = data else { continue }
            let frame = Array(UnsafeBufferPointer(start: d, count: Int(h.caplen)))
            for name in DNSQuestion.names(in: frame, link: link) { onName?(name) }
        }
    }
}
