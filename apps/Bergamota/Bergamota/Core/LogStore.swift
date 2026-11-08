import Foundation
import Observation
import Darwin

enum LogTag: String, CaseIterable, Identifiable, Sendable {
    case usb = "SWEET USB", gpu = "SWEET GPU", wlan = "SWEET WLAN", fb = "SWEET FB", crash = "CRASH"
    var id: String { rawValue }
    var bit: UInt8 { 1 << UInt8(LogTag.allCases.firstIndex(of: self)!) }

    static func classify(_ s: String) -> UInt8 {
        var m: UInt8 = 0
        if s.contains("SWEET USB") { m |= LogTag.usb.bit }
        if s.contains("SWEET GPU") { m |= LogTag.gpu.bit }
        if s.contains("SWEET WLAN") { m |= LogTag.wlan.bit }
        if s.contains("SWEET FB") { m |= LogTag.fb.bit }
        if s.range(of: "panic", options: .caseInsensitive) != nil || s.range(of: "crash", options: .caseInsensitive) != nil
            || s.range(of: "fatal", options: .caseInsensitive) != nil || s.contains("Data Abort")
            || s.range(of: "assertion failed", options: .caseInsensitive) != nil { m |= LogTag.crash.bit }
        return m
    }
}

struct LogLine: Identifiable, Sendable {
    let id: Int
    let text: String
    let tags: UInt8
}

/// Lines handed from the receiver thread to the main actor.
private final class PendingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, UInt8)] = []
    private(set) var datagrams = 0
    func add(_ l: [(String, UInt8)]) { lock.lock(); items.append(contentsOf: l); datagrams += 1; lock.unlock() }
    func drain() -> [(String, UInt8)] { lock.lock(); defer { lock.unlock() }; let r = items; items.removeAll(keepingCapacity: true); return r }
}

/// UDP receiver on a dedicated thread (BSD socket; cheap at high datagram rates).
private final class UDPReceiver: @unchecked Sendable {
    private var fd: Int32 = -1
    private let stopFlag = NSLock()
    private var stopped = false
    private let pending: PendingBox
    init(pending: PendingBox) { self.pending = pending }

    func start(port: UInt16) -> String? {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return "socket(): \(String(cString: strerror(errno)))" }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var rcv: Int32 = 4 << 20
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 { let e = String(cString: strerror(errno)); close(s); return "bind udp/\(port): \(e)" }
        fd = s
        let sock = s
        Thread.detachNewThread { [self] in loop(sock) }
        return nil
    }

    func stop() {
        stopFlag.lock(); stopped = true; stopFlag.unlock()
    }
    private var isStopped: Bool { stopFlag.lock(); defer { stopFlag.unlock() }; return stopped }

    private func loop(_ sock: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var partial = Data()
        while !isStopped {
            let n = buf.withUnsafeMutableBytes { recv(sock, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue } else { break } }
            if n == 0 { continue }
            partial.append(contentsOf: buf[0..<n])
            var lines: [(String, UInt8)] = []
            while let nl = partial.firstIndex(of: 0x0A) {
                var lineData = partial[partial.startIndex..<nl]
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                let s = String(decoding: lineData, as: UTF8.self)
                lines.append((s, LogTag.classify(s)))
                partial = Data(partial[(nl + 1)...])
            }
            if partial.count > 8192 {   // runaway line without newline
                let s = String(decoding: partial, as: UTF8.self)
                lines.append((s, LogTag.classify(s))); partial = Data()
            }
            if !lines.isEmpty { pending.add(lines) }
        }
        close(sock)
    }
}

@Observable
@MainActor
final class LogStore {
    nonisolated static let port: UInt16 = 5140
    nonisolated static let capacity = 300_000
    nonisolated static let maxVisible = 4000

    var visible: [LogLine] = []
    var totalReceived = 0
    var bufferedCount = 0
    var linesPerSecond = 0
    var listening = false
    var listenError: String?
    var searchText = "" { didSet { scheduleFilter() } }
    var activeTags: Set<LogTag> = [] { didSet { scheduleFilter() } }
    var follow = true
    var paused = false
    var recording = false
    var recordPath: String?
    var statusMessage: String?
    /// Kernel-log hints for the activity banner.
    var lastPanicLine: String?
    var lastPanicAt: Date?
    var lastSweetLine: String?
    var lastSweetAt: Date?

    @ObservationIgnored private var ring: [LogLine] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let pending = PendingBox()
    @ObservationIgnored private var receiver: UDPReceiver?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var rateWindow: [(Date, Int)] = []
    @ObservationIgnored private var filterRunning = false
    @ObservationIgnored private var filterDirty = false
    @ObservationIgnored private var recordHandle: FileHandle?
    @ObservationIgnored private var autoSuspended = false
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        guard receiver == nil else { return }
        let r = UDPReceiver(pending: pending)
        if let err = r.start(port: Self.port) { listenError = err; listening = false; return }
        receiver = r
        listening = true
        listenError = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func stop() {
        receiver?.stop(); receiver = nil
        timer?.invalidate(); timer = nil
        listening = false
        stopRecording()
    }

    func restart() { stop(); start() }

    /// Design preview: sample lines without a listener.
    func injectPreview(_ lines: [String]) {
        pending.add(lines.map { ($0, LogTag.classify($0)) })
        flush()
    }

    func clear() {
        ring.removeAll(); visible = []; bufferedCount = 0
    }

    private func flush() {
        let new = pending.drain()
        guard !new.isEmpty else {
            if !rateWindow.isEmpty { updateRate(0) }
            return
        }
        totalReceived += new.count
        if settings.autoSaveLog && !recording && !autoSuspended && !DesignPreview.active { startRecording() }
        updateRate(new.count)
        var batch: [LogLine] = []
        batch.reserveCapacity(new.count)
        for (t, tags) in new {
            batch.append(LogLine(id: nextID, text: t, tags: tags)); nextID += 1
            if tags & LogTag.crash.bit != 0, t.contains("panic(") || t.contains("Kernel panic") || t.contains("panicked") { lastPanicLine = t; lastPanicAt = Date() }
            if t.contains("SWEET ") { lastSweetLine = t; lastSweetAt = Date() }
        }
        ring.append(contentsOf: batch)
        if ring.count > Self.capacity + 30_000 { ring.removeFirst(ring.count - Self.capacity) }
        bufferedCount = ring.count
        if let h = recordHandle {
            let data = Data((new.map(\.0).joined(separator: "\n") + "\n").utf8)
            try? h.write(contentsOf: data)
        }
        if !paused { scheduleFilter() }
    }

    private func updateRate(_ n: Int) {
        let now = Date()
        rateWindow.append((now, n))
        rateWindow.removeAll { now.timeIntervalSince($0.0) > 2 }
        linesPerSecond = rateWindow.reduce(0) { $0 + $1.1 } / 2
    }

    private func scheduleFilter() {
        if searchText.isEmpty && activeTags.isEmpty {
            visible = Array(ring.suffix(Self.maxVisible))
            return
        }
        if filterRunning { filterDirty = true; return }
        filterRunning = true
        let snapshot = ring
        let needle = searchText
        let mask = activeTags.reduce(UInt8(0)) { $0 | $1.bit }
        let limit = Self.maxVisible
        Task.detached(priority: .userInitiated) { [weak self] in
            var out: [LogLine] = []
            var i = snapshot.count - 1
            while i >= 0 && out.count < limit {
                let l = snapshot[i]
                if (mask == 0 || l.tags & mask != 0)
                    && (needle.isEmpty || l.text.range(of: needle, options: .caseInsensitive) != nil) { out.append(l) }
                i -= 1
            }
            out.reverse()
            let result = out
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.visible = result
                self.filterRunning = false
                if self.filterDirty { self.filterDirty = false; self.scheduleFilter() }
            }
        }
    }

    /// Last `count` buffered lines matching any of `tags` (all lines if empty). Cheap: scans backwards.
    func tail(_ count: Int, tags: Set<LogTag> = []) -> [LogLine] {
        let mask = tags.reduce(UInt8(0)) { $0 | $1.bit }
        if mask == 0 { return Array(ring.suffix(count)) }
        var out: [LogLine] = []
        var i = ring.count - 1
        while i >= 0 && out.count < count { if ring[i].tags & mask != 0 { out.append(ring[i]) }; i -= 1 }
        return out.reversed()
    }

    // MARK: saving

    private func newLogPath() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = settings.repoFile("logs")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/usb-\(f.string(from: Date())).txt"
    }

    func saveBuffer() {
        let path = newLogPath()
        let text = ring.map(\.text).joined(separator: "\n") + "\n"
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            statusMessage = "Saved \(ring.count) lines to \(path)"
        } catch { statusMessage = "Save failed: \(error.localizedDescription)" }
    }

    func startRecording() {
        let path = newLogPath()
        guard FileManager.default.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else {
            statusMessage = "Cannot create \(path)"; return
        }
        recordHandle = h; recordPath = path; recording = true; autoSuspended = false
        statusMessage = "Recording to \(path)"
    }

    /// User-initiated stop: auto-save stays off until the app restarts or it is turned back on.
    func userStopRecording() { autoSuspended = true; stopRecording() }

    func stopRecording() {
        try? recordHandle?.close(); recordHandle = nil
        if recording { statusMessage = "Stopped recording (\(recordPath ?? ""))" }
        recording = false
    }
}
