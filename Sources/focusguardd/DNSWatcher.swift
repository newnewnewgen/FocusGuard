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
    /// The interface set last asked for, opened or not: an interface that refuses to open must
    /// not make every path event tear down and reopen the ones that did.
    private var lastWanted: [String] = []
    /// Packets handled per read event before yielding the main queue to ticks and signals.
    private static let drainBatch = 256

    init(log: ReconcilerLog) {
        self.log = log
    }

    deinit { stop() }

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
        // A path update queued before stop() must not open captures after it.
        guard monitor != nil else { return }
        let wanted = Self.activeInterfaces()
        guard wanted != lastWanted else { return }
        closeAll()
        for name in wanted { open(name) }
        lastWanted = wanted
        updateState(wanted: wanted)
        log.info("keyword watch: \(state)")
    }

    /// No interface at all is not an error (the Mac is offline); interfaces that all refused to
    /// open is. The app's Status tab shows anything but `watching` as "not yet", not as a fault.
    private func updateState(wanted: [String]) {
        let watching = captures.map(\.interface)
        if !watching.isEmpty {
            state = "watching " + watching.joined(separator: ", ")
        } else if wanted.isEmpty {
            state = "waiting for network"
        } else {
            state = "error: no interface could be opened"
        }
    }

    /// Cancelling a source closes its handle in the cancel handler (the file-descriptor source
    /// contract: the descriptor outlives the source until then).
    private func closeAll() {
        for c in captures { c.source.cancel() }
        captures = []
        lastWanted = []
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
        pcap_set_buffer_size(handle, 64 * 1024)  // DNS questions are tiny; the default is 512 KB per handle
        let activated = pcap_activate(handle)
        guard activated >= 0 else {
            log.error("keyword watch: activate \(interface): \(String(cString: pcap_geterr(handle)))")
            pcap_close(handle)
            return
        }
        if activated > 0 {
            log.info("keyword watch: activate \(interface) warned: \(String(cString: pcap_geterr(handle)))")
        }
        var program = bpf_program()
        guard pcap_compile(handle, &program, "udp and dst port 53", 1, PCAP_NETMASK_UNKNOWN) == 0 else {
            log.error("keyword watch: filter \(interface): \(String(cString: pcap_geterr(handle)))")
            pcap_close(handle)
            return
        }
        let filtered = pcap_setfilter(handle, &program)
        pcap_freecode(&program)
        guard filtered == 0 else {
            log.error("keyword watch: filter \(interface): \(String(cString: pcap_geterr(handle)))")
            pcap_close(handle)
            return
        }
        if pcap_setnonblock(handle, 1, &errbuf) != 0 {
            log.error("keyword watch: nonblock \(interface): \(String(cString: errbuf))")
        }
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
        source.setCancelHandler { pcap_close(handle) }
        source.resume()
        captures.append(Capture(interface: interface, handle: handle, source: source, link: link))
    }

    /// Read the packets the kernel has queued, parse, hand names up. At most `drainBatch` per
    /// call; past that the rest is taken on a later turn of the main queue so ticks and signals
    /// get in between (libpcap buffers the remainder in userland, so the descriptor may not
    /// report readable again on its own).
    private func drain(_ handle: OpaquePointer, link: DNSQuestion.LinkType) {
        var header: UnsafeMutablePointer<pcap_pkthdr>?
        var data: UnsafePointer<UInt8>?
        var n = 0
        var rc: Int32 = 1
        while n < Self.drainBatch {
            rc = pcap_next_ex(handle, &header, &data)
            guard rc == 1 else { break }
            n += 1
            guard let h = header?.pointee, let d = data else { continue }
            let frame = Array(UnsafeBufferPointer(start: d, count: Int(h.caplen)))
            for name in DNSQuestion.names(in: frame, link: link) { onName?(name) }
        }
        if rc == PCAP_ERROR {
            // The handle is dead (the interface went away under it, say): a dead handle left in
            // `captures` would keep the state at "watching" with nothing being watched.
            dropDead(handle)
            return
        }
        if n == Self.drainBatch {
            DispatchQueue.main.async { [weak self] in
                // Only if this handle is still one of ours.
                guard let self, self.captures.contains(where: { $0.handle == handle }) else { return }
                self.drain(handle, link: link)
            }
        }
    }

    /// `pcap_next_ex` returned PCAP_ERROR for this handle: log it, close it (cancelling the source
    /// closes the handle), recompute the state, and forget the wanted set so the next path event
    /// reopens everything rather than being skipped as unchanged.
    private func dropDead(_ handle: OpaquePointer) {
        guard let i = captures.firstIndex(where: { $0.handle == handle }) else { return }
        let dead = captures.remove(at: i)
        log.error("keyword watch: \(dead.interface): \(String(cString: pcap_geterr(handle))); closed")
        dead.source.cancel()
        lastWanted = []
        updateState(wanted: [dead.interface])
        log.info("keyword watch: \(state)")
    }
}
