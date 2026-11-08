import Foundation
import CryptoKit
import Observation

/// The app's flashing, limited to three partitions: userdata (the iOS root image), boot (Enxerto) and logo (splash).
/// Two routes, both with the same hard allowlist (`partitions`): MAIN = Bergamota fastboot (Enxerto's own, via
/// tools/bergamota-flash.py: delta by default for userdata, full for boot/logo), FALLBACK = ABL fastboot
/// (`fastboot -S 512M flash`). Nothing in the app accepts a partition name from a file or free text; the allowlist is
/// checked here, in the argument builders, and again in Enxerto itself. There is no `erase`, `format` or other `oem` anywhere.
enum UserdataFlash {
    /// The only partition this app will ever pass to `fastboot flash`.
    static let partition = "userdata"
    /// Anything smaller is certainly not a root image.
    static let minBytes: Int64 = 64 << 20
    static let confirmWord = "userdata"

    /// The only partitions the app may flash: the iOS root (userdata), Enxerto's boot image (boot) and the
    /// splash (logo). Never bootloaders, recovery, modem, persist, dsp, bluetooth or anything else.
    static let partitions = ["userdata", "boot", "logo"]

    /// The complete argument list of the flash command. Only this function builds it.
    static func flashArguments(serial: String, image: String, partition: String = "userdata") -> [String] {
        precondition(partitions.contains(partition), "refusing to flash \(partition)")
        // Always chunk explicitly: when fastboot could not read ABL's max-download-size it sent a 3 GB
        // userdata image in one transfer and USB failed (usb_write e00002c0). 512 MiB sparse chunks worked.
        return ["-s", serial, "-S", "512M", "flash", partition, image]
    }

    /// Which fastboot flashes: `.bergamota` = Enxerto's fastboot through tools/bergamota-flash.py, `.abl` = Qualcomm ABL.
    enum Route: String { case abl, bergamota }
    /// Delta = send only the blocks that differ from what the phone holds (userdata only); full = the whole image.
    enum Mode: String { case delta, full }
    /// Route preference of a flash request / the setting: auto = Bergamota fastboot, ABL as fallback; abl = never enter
    /// Bergamota fastboot; bergamota = Bergamota fastboot or fail.
    enum Via: String { case auto, abl, bergamota }

    static let toolName = "bergamota-flash.py"

    /// The complete argument list (after `python3`) of a Bergamota fastboot flash. Only this function builds it.
    /// Delta only for userdata; boot and logo are always sent in full.
    static func bergamotaFlashArguments(script: String, serial: String, fastboot: String, image: String,
                                        partition: String, mode: Mode) -> [String] {
        precondition(partitions.contains(partition), "refusing to flash \(partition)")
        let m = (partition == "userdata" && mode == .delta) ? "--delta" : "--full"
        return [script, "-s", serial, "--fastboot", fastboot, "flash", partition, image, m]
    }

    struct Info { var path: String; var name: String; var size: Int64; var partition: String = "userdata" }

    /// Absolute path of an existing regular `.img`/`.simg` file of at least 64 MiB.
    static func validate(_ rawPath: String, partition: String = "userdata") -> Result<Info, UserdataFlashError> {
        guard partitions.contains(partition) else { return .failure(.init("partition \(partition) can not be flashed by Bergamota")) }
        let path = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard rawPath.hasPrefix("/") || rawPath.hasPrefix("~") else { return .failure(.init("image path must be absolute")) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return .failure(.init("\(rawPath) does not exist")) }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "img" || ext == (partition == "userdata" ? "simg" : "img") else { return .failure(.init("\(rawPath) must be a .img\(partition == "userdata" ? " or .simg" : "") file")) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        let name = (path as NSString).lastPathComponent
        switch partition {
        case "boot":
            // Enxerto's boot.img: Android header, fits the 64 MiB boot partition
            guard size >= 1 << 20, size <= 64 << 20 else { return .failure(.init("\(name): a boot image must be 1-64 MiB")) }
            guard let h = FileHandle(forReadingAtPath: path), let magic = try? h.read(upToCount: 8), String(decoding: magic, as: UTF8.self) == "ANDROID!" else {
                return .failure(.init("\(name) is not an Android boot image (no ANDROID! header)"))
            }
        case "logo":
            guard size >= 1 << 20, size <= 32 << 20 else { return .failure(.init("\(name): a logo image must be 1-32 MiB")) }
        default:
            guard size >= minBytes else { return .failure(.init("\(name) is only \(size) bytes (< 64 MiB): not a root image")) }
        }
        return .success(Info(path: path, name: name, size: size, partition: partition))
    }

    /// Streaming SHA-256 (hex), off the main thread.
    static func sha256(_ path: String) async -> String? {
        await Task.detached(priority: .utility) {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            var hasher = SHA256()
            while true {
                guard let d = try? h.read(upToCount: 4 << 20), !d.isEmpty else { break }
                hasher.update(data: d)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Machine-readable lines of tools/bergamota-flash.py.
    enum ToolLine {
        case progress(phase: String, done: Int64, total: Int64)
        case delta(changed: Int64, image: Int64)
        case result(ok: Bool, message: String)
    }

    nonisolated static func parseToolLine(_ line: String) -> ToolLine? {
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard let k = f.first else { return nil }
        switch k {
        case "PROGRESS": if f.count >= 4, let d = Int64(f[2]), let t = Int64(f[3].split(separator: " ")[0]) { return .progress(phase: f[1], done: d, total: t) }
        case "DELTA": if f.count >= 3, let c = Int64(f[1]), let i = Int64(f[2].split(separator: " ")[0]) { return .delta(changed: c, image: i) }
        case "RESULT": if f.count >= 2, f[1] == "OK" || f[1] == "FAIL" { return .result(ok: f[1] == "OK", message: f.dropFirst(2).joined(separator: " ")) }
        default: break
        }
        return nil
    }

    /// Last `Sending sparse 'userdata' n/m` (or `Sending 'userdata'` => 1/1) in fastboot output.
    nonisolated static func progress(in text: String) -> (Int, Int)? {
        guard let re = try? NSRegularExpression(pattern: "Sending sparse '?[A-Za-z_]+'? (\\d+)/(\\d+)") else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let a = Int(ns.substring(with: m.range(at: 1))), let b = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        return (a, b)
    }
}

struct UserdataFlashError: Error { let message: String; init(_ m: String) { message = m } }

/// Runs the flash and publishes progress for the banner, the Boot page and status.json.
@Observable
@MainActor
final class UserdataFlasher {
    var active = false
    var fileName = ""
    /// Partition of the current / last flash (userdata, boot or logo).
    var partition = "userdata"
    var current = 0
    var total = 0
    var output = ""
    /// For the progress bar / ETA: when the flash started, the image size, and when the chunk before
    /// `current` finished (fastboot only reports per sparse chunk, so the bar interpolates inside one).
    var startedAt: Date?
    var bytes: Int64 = 0
    var lastChunkDoneAt: Date?
    /// Route and mode of the current / last flash; phase and byte counters of the Bergamota tool
    /// (hash-phone, hash-image, send, verify). `deltaBytes` = bytes that differ (nil until known).
    var route: UserdataFlash.Route = .abl
    var mode: UserdataFlash.Mode = .full
    var phase = ""
    var phaseDone: Int64 = 0
    var phaseTotal: Int64 = 0
    var phaseStartedAt: Date?
    var deltaBytes: Int64?
    /// Outcome of the last flash (ok, when, message).
    var last: (ok: Bool, at: Date, message: String)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor: PhoneMonitor
    init(settings: AppSettings, monitor: PhoneMonitor) { self.settings = settings; self.monitor = monitor }

    var progressText: String {
        if route == .bergamota, !phase.isEmpty { return phaseLabel }
        return total > 0 ? "\(current)/\(total)" : "starting"
    }

    var phaseLabel: String {
        switch phase {
        case "hash-phone": "Reading the phone"
        case "hash-image": "Comparing with the phone"
        case "send": "Sending"
        case "verify": "Verifying"
        default: "Starting"
        }
    }

    /// 0...1, or nil until a rate is known.
    func fraction(now: Date = Date()) -> Double? {
        guard active else { return nil }
        if route == .bergamota {
            guard phaseTotal > 0 else { return nil }
            return min(1, Double(phaseDone) / Double(phaseTotal))
        }
        guard total > 0, current >= 1, let t0 = startedAt else { return nil }
        let done = Double(current - 1)
        guard done > 0, let last = lastChunkDoneAt else { return nil }
        let perChunk = last.timeIntervalSince(t0) / done
        let inChunk = perChunk > 0 ? min(0.97, now.timeIntervalSince(last) / perChunk) : 0
        return min(1, (done + inChunk) / Double(total))
    }

    /// "37%  |  4.1 of 11.0 GB  |  48 MB/s  |  ETA 3:12", or nil before a rate is known.
    func progressDetail(now: Date = Date()) -> String? {
        guard let f = fraction(now: now), f > 0 else { return nil }
        let gb = { (b: Double) in String(format: "%.1f", b / 1_073_741_824) }
        if route == .bergamota {
            guard let t0 = phaseStartedAt else { return nil }
            let elapsed = max(now.timeIntervalSince(t0), 1)
            let rate = Double(phaseDone) / elapsed / 1_048_576
            let unit = phaseTotal > 4 << 30 ? (gb(Double(phaseDone)) + " of " + gb(Double(phaseTotal)) + " GB")
                                            : String(format: "%.0f of %.0f MB", Double(phaseDone) / 1_048_576, Double(phaseTotal) / 1_048_576)
            var s = "\(phaseLabel) \(Int(f * 100))%  |  \(unit)  |  \(Int(rate)) MB/s  |  ETA \(formatElapsed(elapsed / f - elapsed))"
            if let d = deltaBytes, phase == "send" || phase == "verify" { s += "  |  delta \(String(format: "%.0f", Double(d) / 1_048_576)) MB of \(gb(Double(bytes))) GB" }
            return s
        }
        guard let t0 = startedAt else { return nil }
        let elapsed = now.timeIntervalSince(t0)
        let sent = Double(bytes) * f
        let rate = sent / max(elapsed, 1) / 1_048_576
        return "\(Int(f * 100))%  |  \(gb(sent)) of \(gb(Double(bytes))) GB  |  \(Int(rate)) MB/s  |  ETA \(formatElapsed(elapsed / f - elapsed))"
    }

    private func apply(_ l: UserdataFlash.ToolLine) {
        switch l {
        case .progress(let ph, let d, let t):
            if ph != phase { phase = ph; phaseStartedAt = Date() }
            phaseDone = d; phaseTotal = t
        case .delta(let changed, _): deltaBytes = changed
        case .result: break
        }
    }

    /// ONE flash. `.abl`: `fastboot -s <serial> -S 512M flash <partition> <img>`. `.bergamota`: `python3 tools/bergamota-flash.py ... flash ...`
    /// (delta for userdata when `mode == .delta`). No retry. The caller must have put the phone in the matching fastboot kind
    /// and checked the queue is idle.
    func flash(_ info: UserdataFlash.Info, route: UserdataFlash.Route = .abl, mode: UserdataFlash.Mode = .delta) async -> (ok: Bool, message: String) {
        guard !active else { return (false, "a flash is already running") }
        guard let fb = settings.fastboot else { return (false, "fastboot not found") }
        guard let serial = monitor.fastbootSerial, !serial.isEmpty else { return (false, "no fastboot serial") }
        var exe = fb
        var args: [String]
        if route == .bergamota {
            guard let script = settings.flashTool else {
                return (false, "\(UserdataFlash.toolName) not found (looked in \(settings.repoFile("tools")); set the path in Settings)")
            }
            guard let py = settings.python ?? (FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") ? "/usr/bin/python3" : nil) else { return (false, "python3 not found") }
            exe = py
            args = UserdataFlash.bergamotaFlashArguments(script: script, serial: serial, fastboot: fb, image: info.path, partition: info.partition, mode: mode)
        } else {
            args = UserdataFlash.flashArguments(serial: serial, image: info.path, partition: info.partition)
        }
        active = true
        fileName = info.name; current = 0; total = 0
        startedAt = Date(); bytes = info.size; lastChunkDoneAt = nil
        self.route = route
        self.mode = route == .bergamota && info.partition == "userdata" && mode == .delta ? .delta : .full
        phase = ""; phaseDone = 0; phaseTotal = 0; phaseStartedAt = nil; deltaBytes = nil
        partition = info.partition
        output = "$ " + ([exe] + args).map(shellQuote).joined(separator: " ") + "\n"
        DebugLog.write("FLASH \(info.partition) via \(route.rawValue) (\(self.mode.rawValue)) start \(info.path) (\(info.size) bytes)")
        let box = FlashTail()
        let r = await Shell.run(exe, args, timeout: 7200, onOutput: { [weak self] chunk in
            let (tail, lines, shown) = box.append(chunk, filterTool: route == .bergamota)
            let p = UserdataFlash.progress(in: tail)
            Task { @MainActor in
                guard let self else { return }
                self.output += shown
                if self.output.count > 200_000 { self.output = String(self.output.suffix(100_000)) }
                for l in lines { self.apply(l) }
                if let p {
                    if p.0 != self.current, p.0 > 1 { self.lastChunkDoneAt = Date() }
                    self.current = p.0; self.total = p.1
                }
            }
        })
        var ok = r.ok
        var msg = "FLASHED \(info.partition) (\(info.name)) via \(route == .bergamota ? "Bergamota fastboot (\(self.mode.rawValue))" : "ABL fastboot")"
        if route == .bergamota {
            // The tool's last RESULT line is authoritative.
            for line in r.combined.split(separator: "\n").reversed() {
                if case .result(let rok, let m)? = UserdataFlash.parseToolLine(String(line)) {
                    ok = ok && rok
                    if !rok { msg = "FAILED flashing \(info.partition): \(m)" } else if !m.isEmpty { msg += ": " + m }
                    break
                }
            }
        } else if r.combined.contains("FAILED") { ok = false }
        if !ok, !msg.hasPrefix("FAILED") {
            msg = "FAILED flashing \(info.partition): " + (r.launchError ?? (r.timedOut ? "timed out" : "exit \(r.status)"))
        }
        if let e = r.launchError { output += "\n\(e)" }
        output += "\n" + msg + "\n"
        active = false
        last = (ok, Date(), msg)
        DebugLog.write(msg)
        return (ok, msg)
    }
}

/// Keeps the tail of the output for the `Sending sparse n/m` regex and splits the tool's machine-readable lines
/// (PROGRESS/DELTA, hidden from the log; RESULT stays visible) from the text shown.
private final class FlashTail: @unchecked Sendable {
    private let lock = NSLock()
    private var s = ""
    private var partial = ""
    func append(_ c: String, filterTool: Bool) -> (String, [UserdataFlash.ToolLine], String) {
        lock.lock(); defer { lock.unlock() }
        s += c
        if s.count > 4096 { s = String(s.suffix(2048)) }
        guard filterTool else { return (s, [], c) }
        partial += c
        var events: [UserdataFlash.ToolLine] = []
        var shown = ""
        while let nl = partial.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(partial[partial.startIndex..<nl])
            let term = partial[nl]
            partial.removeSubrange(partial.startIndex...nl)
            if let e = UserdataFlash.parseToolLine(line) {
                events.append(e)
                if case .result = e { shown += line + "\n" }
            } else { shown += line + String(term) }
        }
        return (s, events, shown)
    }
}
