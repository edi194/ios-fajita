import Foundation
import Observation

enum PhoneState: String, Sendable {
    /// `fastboot` = Qualcomm ABL fastboot; `bergamotaFastboot` = the fastboot Enxerto (our bootloader) speaks (serial `bergamota*`, version-bootloader `bergamota-N`).
    case unknown, offline, fastboot, bergamotaFastboot, recovery, android, iosBooting, ios

    /// Either kind of fastboot (`fastboot boot` works on both).
    var isFastboot: Bool { self == .fastboot || self == .bergamotaFastboot }

    var title: String {
        switch self {
        case .unknown: "Checking..."
        case .offline: "Offline"
        case .fastboot: "ABL Fastboot"
        case .bergamotaFastboot: "Bergamota Fastboot"
        case .recovery: "OrangeFox / Recovery"
        case .android: "Android (adb)"
        case .iosBooting: "iOS booting"
        case .ios: "iOS"
        }
    }
    var symbol: String {
        switch self {
        case .unknown: "ellipsis.circle"
        case .offline: "bolt.slash"
        case .fastboot: "bolt.horizontal.circle.fill"
        case .bergamotaFastboot: "leaf.circle.fill"
        case .recovery: "wrench.and.screwdriver.fill"
        case .android: "android.fill"
        case .iosBooting: "hourglass"
        case .ios: "apple.logo"
        }
    }
}

struct IOSInfo: Equatable, Sendable {
    var uname = ""
    var bootDate: Date?
    var uptime: TimeInterval?
    var batteryPercent: Int?
    var isCharging: Bool?
    var powerSource: String?
    var sweetrebootBergamota: Bool?
    var fetched = Date()
}

private struct Probe: Sendable {
    var fastbootSerial: String?
    var fastbootSession: String?
    var fastbootKind: (key: String, bergamota: Bool, version: String)?
    var adbSerial: String?
    var adbState: String?
    var iface: String?
    var ifaceUp = false
    var ping = false
    var ssh = false
    /// TCP 22 accepts connections (may be true while ssh is false: server stalled).
    var sshPort = false
    var ifaceHasIP = false
    var inferred = false
    var macHidden = false
    var ifconfigLen = 0
    var ifconfigOK = false
    var pingErr = ""
    var tcpErr: Int32 = 0
    var nat: String?
    var errors: [String] = []
}

@Observable
@MainActor
final class PhoneMonitor {
    nonisolated static let usbMAC = "02:00:5e:77:ee:01"

    var state: PhoneState = .unknown
    var stateSince = Date()
    var fastbootSerial: String?
    /// USB enumeration identity of the fastboot device; changes when the phone re-enumerates (e.g. force restart back into fastboot).
    var fastbootSession: String?
    /// The fastboot device is Bergamota fastboot (Enxerto), not Qualcomm ABL.
    var fastbootIsBergamota = false
    var fastbootVersion: String?
    var adbSerial: String?
    var adbState: String?
    var ifaceName: String?
    var ifaceUp = false
    var pingOK = false
    var sshOpen = false
    var sshPortOpen = false
    var ifaceHasIP = false
    var ifaceInferred = false   // found by subnet because the MAC was not visible
    var macHidden = false       // macOS zeroes MAC addresses without Local Network permission
    var noRoute = false   // iface has an IP but connects fail with EHOSTUNREACH (maybe Local Network privacy)
    var natForwarding: String?
    var info: IOSInfo?
    /// Whether the phone's `sweetreboot` lists `bergamota` (kept after iOS goes away; nil = never checked).
    var sweetrebootBergamota: Bool?
    var infoError: String?
    /// Latest `sweetmetrics` sample (iOS up only) and the last ~2 minutes of them for the sparklines.
    var metrics: PhoneMetrics?
    var metricsError: String?
    var metricsHistory = MetricsHistory()
    var toolWarnings: [String] = []
    var lastPoll: Date?

    /// Called on the main actor after every poll with (previous, new) state.
    @ObservationIgnored var observers: [(PhoneState, PhoneState) -> Void] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var infoInFlight = false
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var metricsInFlight = false
    /// `sweetmetrics` is not installed on the phone: ask again only every 15 s.
    @ObservationIgnored private var metricsMissingAt: Date?
    @ObservationIgnored private var lastSig = ""
    @ObservationIgnored private var primed = false
    @ObservationIgnored private let settings: AppSettings
    /// `getvar version-bootloader` result per fastboot device identity (serial + USB session): asked once, not every poll.
    @ObservationIgnored private var fbKind: (key: String, bergamota: Bool, version: String)?

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let began = Date()
                await self?.pollOnce()
                let elapsed = Date().timeIntervalSince(began)
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, 2.0 - elapsed) * 1e9))
            }
        }
        // Metrics run on their own loop: a slow SSH call must not hold up the detection polls above.
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                let began = Date()
                await self?.refreshMetrics()
                let elapsed = Date().timeIntervalSince(began)
                try? await Task.sleep(nanoseconds: UInt64(max(0.3, 2.0 - elapsed) * 1e9))
            }
        }
    }

    func pollOnce() async {
        if !primed {
            primed = true
            let ip = settings.phoneIP
            Task.detached { _ = Shell.tcpProbe(host: ip, port: 22, timeout: 1.0) }   // touches the local network -> permission prompt
        }
        let fb = settings.fastboot, adb = settings.adb, ip = settings.phoneIP
        let known = fbKind
        let probe = await Self.probe(fastboot: fb, adb: adb, ip: ip, known: known)
        if let k = probe.fastbootKind { fbKind = k } else if probe.fastbootSerial == nil { fbKind = nil }
        apply(probe)
        if state == .ios { await refreshInfoIfNeeded() }
    }

    private func apply(_ p: Probe) {
        var warnings: [String] = []
        if settings.fastboot == nil { warnings.append("fastboot not found (set it in Settings)") }
        if settings.adb == nil { warnings.append("adb not found (set it in Settings)") }
        toolWarnings = warnings
        fastbootSerial = p.fastbootSerial
        fastbootSession = p.fastbootSession
        fastbootIsBergamota = p.fastbootKind?.bergamota ?? false
        fastbootVersion = p.fastbootKind?.version
        adbSerial = p.adbSerial
        adbState = p.adbState
        ifaceName = p.iface
        ifaceUp = p.ifaceUp
        ifaceHasIP = p.ifaceHasIP
        ifaceInferred = p.inferred
        macHidden = p.macHidden
        noRoute = p.iface != nil && p.ifaceHasIP && !p.ping && !p.ssh && (p.tcpErr == EHOSTUNREACH || p.pingErr.contains("No route"))
        pingOK = p.ping
        sshOpen = p.ssh
        sshPortOpen = p.sshPort
        natForwarding = p.nat
        lastPoll = Date()

        let new: PhoneState
        if p.fastbootSerial != nil { new = (p.fastbootKind?.bergamota ?? false) ? .bergamotaFastboot : .fastboot }
        else if let s = p.adbState, s == "recovery" || s == "sideload" { new = .recovery }
        else if p.iface != nil && p.ping && p.ssh { new = .ios }
        else if p.adbState == "device" { new = .android }
        else if p.iface != nil { new = .iosBooting }
        else { new = .offline }

        let old = state
        let sig = "\(p.macHidden)|\(new.rawValue)|\(p.iface ?? "-")|\(p.ifaceUp)|\(p.ifaceHasIP)|\(p.ping)|\(p.ssh)"
        if sig != lastSig {
            lastSig = sig
            DebugLog.write("state=\(new.rawValue) fastboot=\(p.fastbootSerial ?? "-") adb=\(p.adbState ?? "-") ifconfigLen=\(p.ifconfigLen) ifconfigOK=\(p.ifconfigOK) iface=\(p.iface ?? "none") inferred=\(p.inferred) macHidden=\(p.macHidden) up=\(p.ifaceUp) inet=\(p.ifaceHasIP) ping=\(p.ping) tcp22=\(p.ssh) tcpErr=\(p.tcpErr) pingErr=\(p.pingErr) \(p.errors.joined(separator: "; "))")
        }
        if new != old {
            state = new
            stateSince = Date()
            if new != .ios { info = nil; infoError = nil; metrics = nil; metricsError = nil; metricsHistory.clear(); metricsMissingAt = nil }
        }
        for o in observers { o(old, new) }
    }

    // MARK: probing

    private nonisolated static func probe(fastboot: String?, adb: String?, ip: String, known: (key: String, bergamota: Bool, version: String)?) async -> Probe {
        async let fbR: ShellResult? = fastboot != nil ? Shell.run(fastboot!, ["devices"], timeout: 3) : nil
        async let adbR: ShellResult? = adb != nil ? Shell.run(adb!, ["devices"], timeout: 4) : nil
        async let ifR = Shell.run("/sbin/ifconfig", ["-a"], timeout: 3)
        async let natR = Shell.run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"], timeout: 2)
        var p = Probe()
        if let r = await fbR, r.ok {
            for line in r.stdout.split(whereSeparator: \.isNewline) {
                let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if f.count >= 2, f[1] == "fastboot" || f[1] == "fastbootd" { p.fastbootSerial = String(f[0]); break }
            }
        }
        if let serial = p.fastbootSerial {
            let io = await Shell.run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0"], timeout: 3)
            if io.ok { p.fastbootSession = usbSession(io.stdout, serial: serial) }
            // ABL or Bergamota fastboot: serial `bergamota*`, else `getvar version-bootloader` starting with `bergamota` (read-only, once per appearance).
            let key = serial + "/" + (p.fastbootSession ?? "")
            if let k = known, k.key == key {
                p.fastbootKind = k
            } else if serial.lowercased().hasPrefix("bergamota") {
                p.fastbootKind = (key, true, "")
            } else if let fb = fastboot {
                let g = await Shell.run(fb, ["-s", serial, "getvar", "version-bootloader"], timeout: 3)
                if let v = parseVersionBootloader(g.combined) {
                    p.fastbootKind = (key, v.lowercased().hasPrefix("bergamota"), v)
                }
            }
        }
        if let r = await adbR, r.ok {
            for line in r.stdout.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("*") || line.hasPrefix("List of") { continue }
                let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if f.count >= 2 { p.adbSerial = String(f[0]); p.adbState = String(f[1]); break }
            }
        }
        let ifr = await ifR
        p.ifconfigLen = ifr.stdout.count
        p.ifconfigOK = ifr.ok
        p.macHidden = ifr.stdout.contains("ether 02:00:00:00:00:00")
        if let (name, up, hasIP, inferred) = parseInterface(ifr.stdout, mac: usbMAC, phoneIP: ip) { p.iface = name; p.ifaceUp = up; p.ifaceHasIP = hasIP; p.inferred = inferred }
        if !ifr.ok { p.errors.append("ifconfig failed: \(ifr.launchError ?? ifr.stderr)") }
        let nat = await natR
        if nat.ok { p.nat = nat.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Probe whenever the interface exists, even if macOS does not flag it UP yet.
        if p.iface != nil {
            async let pingR = Shell.run("/sbin/ping", ["-c", "1", "-t", "1", ip], timeout: 4)
            async let sshR = Task.detached { Shell.tcpProbe(host: ip, port: 22, timeout: 1.5) }.value
            async let bannerR = Task.detached { Shell.sshBanner(host: ip, timeout: 3) }.value
            let pr = await pingR
            p.ping = pr.ok
            p.pingErr = (pr.launchError ?? pr.stderr + pr.stdout.split(separator: "\n").filter { $0.contains("No route") }.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
            let t = await sshR
            p.sshPort = t.open
            let banner = await bannerR
            p.ssh = t.open && banner	// iOS UP only when the SSH server answers, not just the TCP port
            p.tcpErr = t.err
        }
        return p
    }

    /// `version-bootloader: bergamota-1` (fastboot prints getvar results on stderr).
    nonisolated static func parseVersionBootloader(_ out: String) -> String? {
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("version-bootloader:") {
            let v = line.dropFirst("version-bootloader:".count).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
    }

    /// Best effort: find the IOUSB entry of the fastboot device (by serial, else Google/Qualcomm VID 0x18d1)
    /// and join its registry id, sessionID and locationID. A new enumeration changes at least the registry id.
    nonisolated static func usbSession(_ text: String, serial: String) -> String? {
        var blocks: [[Substring]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.contains("+-o ") { blocks.append([line]) } else if !blocks.isEmpty { blocks[blocks.count - 1].append(line) }
        }
        func value(_ key: String, _ b: [Substring]) -> String? {
            for l in b { if let r = l.range(of: "\"\(key)\" = ") { return String(l[r.upperBound...]).trimmingCharacters(in: .whitespaces) } }
            return nil
        }
        let hit = blocks.first { b in b.contains { $0.contains("\"USB Serial Number\" = \"\(serial)\"") } }
            ?? blocks.first { b in value("idVendor", b) == "6353" }
        guard let b = hit else { return nil }
        let parts = [value("IORegistryEntryID", b), value("sessionID", b), value("locationID", b)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    nonisolated static func parseInterface(_ text: String, mac: String, phoneIP: String = "") -> (String, Bool, Bool, Bool)? {
        var blocks: [[String]] = []
        for line in text.split(separator: "\n") {
            if let f = line.first, !f.isWhitespace { blocks.append([String(line)]) }
            else if !blocks.isEmpty { blocks[blocks.count - 1].append(String(line)) }
        }
        let needle = "ether \(mac.lowercased())"
        func describe(_ b: [String], inferred: Bool) -> (String, Bool, Bool, Bool) {
            let head = b[0]
            let name = String(head.prefix(while: { $0 != ":" }))
            var flagsUp = false
            if let lt = head.firstIndex(of: "<"), let gt = head.firstIndex(of: ">"), lt < gt {
                flagsUp = head[head.index(after: lt)..<gt].split(separator: ",").contains("UP")
            }
            var active = true
            if let st = b.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("status:") }) {
                active = st.contains(" active")
            }
            let hasIP = b.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("inet ") }
            return (name, flagsUp && active, hasIP, inferred)
        }
        if let b = blocks.first(where: { $0.contains(where: { $0.lowercased().contains(needle) }) }) { return describe(b, inferred: false) }
        // Fallback: without Local Network permission macOS reports 02:00:00:00:00:00 for every MAC,
        // so find the phone's interface by its subnet (the host side is x.x.x.1 of the phone's /24).
        let parts = phoneIP.split(separator: ".")
        if parts.count == 4 {
            let prefix = "inet \(parts[0]).\(parts[1]).\(parts[2])."
            if let b = blocks.first(where: { $0[0].hasPrefix("en") && $0.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }) }) {
                return describe(b, inferred: true)
            }
        }
        return nil
    }

    // MARK: iOS info over SSH

    func refreshInfoIfNeeded(force: Bool = false) async {
        guard state == .ios, !infoInFlight else { return }
        if !force, let i = info, Date().timeIntervalSince(i.fetched) < 10 { return }
        guard let ssh = settings.ssh else { infoError = "ssh not found"; return }
        infoInFlight = true
        defer { infoInFlight = false }
        let ip = settings.phoneIP
        let remote = "uname -a; echo '@@BOOT'; sysctl -n kern.boottime 2>/dev/null; echo '@@ETIME'; ps -o etime= -p 1 2>/dev/null; echo '@@NOW'; date +%s; echo '@@PS'; /usr/local/bin/sweetps; echo '@@SRB'; /usr/local/bin/sweetreboot 2>&1 </dev/null"
        let r = await Shell.run(ssh, Shell.sshOptions + ["root@\(ip)", remote], timeout: 10)
        if r.launchError != nil || r.timedOut || (r.status != 0 && r.stdout.isEmpty) {
            infoError = r.timedOut ? "ssh timed out" : (r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ssh failed (exit \(r.status))" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        infoError = nil
        info = Self.parseInfo(r.stdout)
        if let b = info?.sweetrebootBergamota { sweetrebootBergamota = b }
    }

    /// One `sweetmetrics` run over SSH (read-only, ~0.3 s on the phone). Never blocks the main thread: Shell.run waits off it.
    func refreshMetrics() async {
        guard state == .ios, !metricsInFlight else { return }
        if let at = metricsMissingAt, Date().timeIntervalSince(at) < 15 { return }
        guard let ssh = settings.ssh else { metricsError = "ssh not found"; return }
        metricsInFlight = true
        defer { metricsInFlight = false }
        let ip = settings.phoneIP
        let remote = "/usr/local/bin/sweetmetrics" + (settings.metricsGPUInfo ? " --gpu-info" : "")
        let r = await Shell.run(ssh, Shell.sshOptions + ["root@\(ip)", remote], timeout: 6)
        guard state == .ios else { return }      // the phone went away while we waited
        if r.launchError != nil || r.timedOut || (r.status != 0 && PhoneMetrics.extractJSON(r.stdout) == nil) {
            let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status == 127 || err.contains("not found") || err.contains("No such file") {
                metricsMissingAt = Date()
                metricsError = "sweetmetrics is not on the phone (/usr/local/bin): renegade update, or scp it (docs/BERGAMOTA_METRICS.md)"
            } else {
                metricsError = r.timedOut ? "sweetmetrics timed out" : (err.isEmpty ? "sweetmetrics failed (exit \(r.status))" : err)
            }
            return
        }
        guard let m = PhoneMetrics.parse(r.stdout) else {
            metricsError = "sweetmetrics printed no JSON: " + String(r.stdout.prefix(120))
            return
        }
        metricsMissingAt = nil
        metricsError = nil
        metrics = m
        metricsHistory.add(m)
    }

    nonisolated static func parseInfo(_ out: String) -> IOSInfo {
        var parts: [String: String] = [:]
        var key = "UNAME"
        var buf: [String] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                parts[key] = buf.joined(separator: "\n"); key = String(line.dropFirst(2)); buf = []
            } else { buf.append(String(line)) }
        }
        parts[key] = buf.joined(separator: "\n")
        var i = IOSInfo()
        i.uname = (parts["UNAME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Double((parts["NOW"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date().timeIntervalSince1970
        let boot = parts["BOOT"] ?? ""
        if let m = boot.firstMatch(of: /sec\s*=\s*(\d+)/), let sec = Double(m.1) {
            i.bootDate = Date(timeIntervalSince1970: sec)
            i.uptime = max(0, now - sec)
        } else if let up = parseEtime(parts["ETIME"] ?? ""), up < 366 * 86400 {
            // The phone has no sysctl; `ps -o etime= -p 1` works only when its clock was not stepped after boot.
            i.uptime = up
            i.bootDate = Date(timeIntervalSince1970: now - up)
        }
        let ps = parts["PS"] ?? ""
        if let v = psValue("Current Capacity", in: ps), let n = Int(v.replacingOccurrences(of: "+", with: "")) { i.batteryPercent = n }
        if let v = psValue("Is Charging", in: ps) { i.isCharging = ["1", "true", "yes"].contains(v.lowercased()) }
        if let v = psValue("Power Source State", in: ps) { i.powerSource = v }
        // `sweetreboot` without arguments prints its usage (no side effects); newer builds list `bergamota`.
        if let u = parts["SRB"], !u.isEmpty { i.sweetrebootBergamota = u.contains("bergamota") }
        return i
    }

    /// Value of a CFDictionary-description key, e.g. `"Current Capacity"} = <CFNumber ..>{value = +87, ...}` or `Is Charging = Yes;`.
    nonisolated static func psValue(_ key: String, in text: String) -> String? {
        let k = NSRegularExpression.escapedPattern(for: key)
        let pat = "\"?" + k + "\"?\\}?\\s*=\\s*(?:<CF[A-Za-z]+ [^>]*>\\{(?:value|contents) = \"?([^,}\"]+)|\"?([^\";\\n,]+))"
        guard let re = try? NSRegularExpression(pattern: pat), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for g in 1...2 {
            if let r = Range(m.range(at: g), in: text) { return String(text[r]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// ps etime: [[dd-]hh:]mm:ss
    nonisolated static func parseEtime(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var days = 0.0, rest = t
        if let dash = t.firstIndex(of: "-") { days = Double(t[..<dash]) ?? .nan; rest = String(t[t.index(after: dash)...]) }
        let p = rest.split(separator: ":").map { Double($0) ?? .nan }
        guard !days.isNaN, (2...3).contains(p.count), !p.contains(where: \.isNaN) else { return nil }
        let secs = p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : p[0] * 60 + p[1]
        return days * 86400 + secs
    }
}
