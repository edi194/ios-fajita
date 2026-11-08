import Foundation
import Observation

private struct RemoteError: Error { let message: String; init(_ m: String) { message = m } }

/// File-based local API (no network listener): JSON requests in `inbox/`, state in `status.json`.
@Observable
@MainActor
final class RemoteControl {
    nonisolated static var baseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bergamota")
    }
    static var inbox: URL { baseURL.appendingPathComponent("inbox") }
    static var statusURL: URL { baseURL.appendingPathComponent("status.json") }

    var lastRequest: String?
    /// Set by AppModel after init.
    @ObservationIgnored var tools: PhoneTools?
    @ObservationIgnored var bannerProvider: (() -> ActivityBanner)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor: PhoneMonitor
    @ObservationIgnored private let queue: BootQueue
    @ObservationIgnored private let build: BuildModel
    @ObservationIgnored private let logs: LogStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var processing = false
    @ObservationIgnored private var lastStatusData = Data()
    @ObservationIgnored private var lastStatusWrite = Date.distantPast

    init(settings: AppSettings, monitor: PhoneMonitor, queue: BootQueue, build: BuildModel, logs: LogStore) {
        self.settings = settings; self.monitor = monitor; self.queue = queue; self.build = build; self.logs = logs
    }

    func start() {
        guard timer == nil else { return }
        let fm = FileManager.default
        for d in ["inbox", "inbox/done", "inbox/failed"] {
            try? fm.createDirectory(at: Self.baseURL.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        writeStatusIfNeeded()
        if !processing { Task { await processInbox() } }
    }

    // MARK: inbox

    private func processInbox() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: Self.inbox.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for name in names {
            let url = Self.inbox.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let age = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date).flatMap { $0 }.map { Date().timeIntervalSince($0) } ?? 99
                if age < 2 { continue }   // maybe still being written
                finish(url, request: ["raw": String(decoding: data, as: UTF8.self)], result: nil, error: "invalid JSON object")
                continue
            }
            do {
                let detail = try await handle(obj)
                lastRequest = "\(obj["kind"] as? String ?? "?"): \(detail)"
                finish(url, request: obj, result: detail, error: nil)
            } catch let e as RemoteError {
                lastRequest = "\(obj["kind"] as? String ?? "?") failed: \(e.message)"
                finish(url, request: obj, result: nil, error: e.message)
            } catch {
                finish(url, request: obj, result: nil, error: error.localizedDescription)
            }
            writeStatusIfNeeded(force: true)
        }
    }

    private func finish(_ url: URL, request: [String: Any], result: String?, error: String?) {
        var out = request
        out["processedAt"] = ISO8601DateFormatter().string(from: Date())
        if let result { out["result"] = result }
        if let error { out["error"] = error }
        let dir = Self.inbox.appendingPathComponent(error == nil ? "done" : "failed")
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-" + url.lastPathComponent)
        }
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), (try? d.write(to: dest)) != nil {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? FileManager.default.moveItem(at: url, to: dest)
        }
        DebugLog.write("remote \(url.lastPathComponent): \(error.map { "FAILED \($0)" } ?? (result ?? "ok"))")
    }

    // MARK: requests

    private func handle(_ req: [String: Any]) async throws -> String {
        guard let kind = req["kind"] as? String else { throw RemoteError("missing \"kind\"") }
        switch kind {
        case "enqueue":
            guard let image = req["image"] as? String, !image.isEmpty else { throw RemoteError("missing \"image\"") }
            let path = try resolveBoot(image, suffix: ".img")
            queue.add(path, label: (req["label"] as? String) ?? "")
            return "queued \((path as NSString).lastPathComponent)" + largeNote(path) + armNote(req)
        case "build":
            return try await handleBuild(req)
        case "flash_userdata":
            // The app's one flash exception. Requires "confirm":"userdata"; only enqueues (the flash runs in fastboot, armed queue).
            // "partition" defaults to userdata; boot and logo are the only others (UserdataFlash.partitions).
            let part = (req["partition"] as? String) ?? "userdata"
            guard UserdataFlash.partitions.contains(part) else { throw RemoteError("flash rejected: partition \(part) is not allowed") }
            guard (req["confirm"] as? String) == part else {
                throw RemoteError("flash rejected: needs \"confirm\":\"\(part)\"")
            }
            guard let p = req["path"] as? String, !p.isEmpty else { throw RemoteError("missing \"path\"") }
            let info: UserdataFlash.Info
            // Root images live in the repo or in the sibling ios18 worktree's research/ios18/ (the iOS 18 full root).
            let resolved: String
            if let r = try? resolve(p, under: "", suffix: nil) { resolved = r }
            else { resolved = try resolve(p, under: "../ios-beryllium-ios18/research/ios18", suffix: nil) }
            switch UserdataFlash.validate(resolved, partition: part) {
            case .success(let i): info = i
            case .failure(let e): throw RemoteError(e.message)
            }
            var via: UserdataFlash.Via?
            if let v = req["via"] as? String {
                guard let x = UserdataFlash.Via(rawValue: v) else { throw RemoteError("flash rejected: \"via\" must be auto, abl or bergamota") }
                via = x
            } else if req["via"] != nil { throw RemoteError("flash rejected: \"via\" must be a string") }
            var mode: UserdataFlash.Mode?
            if let m = req["mode"] as? String {
                guard let x = UserdataFlash.Mode(rawValue: m) else { throw RemoteError("flash rejected: \"mode\" must be delta or full") }
                mode = x
            } else if req["mode"] != nil { throw RemoteError("flash rejected: \"mode\" must be a string") }
            var boot = ""
            if let b = req["then_boot"] as? String, !b.isEmpty { boot = try resolveBoot(b, suffix: ".img") }
            queue.addFlash(userdata: info, bootPath: boot, label: (req["label"] as? String) ?? "", via: via, mode: mode)
            return "queued flash \(info.partition) \(info.name) (via \((via ?? settings.flashViaValue).rawValue), \(info.partition == "userdata" ? (mode ?? settings.flashModeValue).rawValue : "full"))" + (boot.isEmpty ? "" : ", then boot \((boot as NSString).lastPathComponent)") + largeNote(boot) + armNote(req)
        case "orangefox_reboot":
            guard let en = req["enabled"] as? Bool else { throw RemoteError("missing boolean \"enabled\"") }
            settings.rebootFromRecovery = en
            return "orangefox reboot to bootloader \(en ? "enabled" : "disabled")"
        case "send_now":
            guard settings.allowRemoteStart else { throw RemoteError("remote start is disabled in Settings") }
            guard monitor.state.isFastboot else { throw RemoteError("phone is not in fastboot (state: \(monitor.state.rawValue))") }
            let r = await queue.sendNow()
            if r.hasPrefix("FAILED") || r == "not sent" || r.hasPrefix("a send") || r.hasPrefix("queue") { throw RemoteError(r) }
            return r
        case "install_ipa":
            guard let tools else { throw RemoteError("tools unavailable") }
            guard let path = req["path"] as? String, !path.isEmpty else { throw RemoteError("missing \"path\"") }
            let r = await tools.installIPA(path)
            if !r.0 { throw RemoteError(r.1) }
            return r.1
        case "upload":
            guard let tools else { throw RemoteError("tools unavailable") }
            guard let paths = req["paths"] as? [String], !paths.isEmpty else { throw RemoteError("missing \"paths\" array") }
            let r = await tools.upload(paths, dest: (req["dest"] as? String) ?? "photos")
            if !r.0 { throw RemoteError(r.1) }
            return r.1
        case "reboot":
            // {"kind":"reboot","to":"fastboot|bergamota|recovery"}: iOS -> ABL fastboot / Bergamota fastboot / recovery via SSH sweetreboot
            guard let to = req["to"] as? String, to == "fastboot" || to == "recovery" || to == "bergamota" else { throw RemoteError("\"to\" must be \"fastboot\", \"bergamota\" or \"recovery\"") }
            guard monitor.state == .ios else { throw RemoteError("iOS is not up (state: \(monitor.state.rawValue))") }
            guard let tools else { throw RemoteError("tools unavailable") }
            let (ok, msg) = await tools.rebootIOS(to: to)
            if !ok { throw RemoteError(msg) }
            return msg
        case "enter_bergamota":
            // {"kind":"enter_bergamota"}: ABL fastboot -> Bergamota fastboot (`fastboot boot bergamota-fastboot.img`)
            guard let tools else { throw RemoteError("tools unavailable") }
            let (ok, msg) = await tools.enterBergamota()
            if !ok { throw RemoteError(msg) }
            return msg
        case "stop":
            queue.disarm()
            return "queue disarmed"
        default:
            throw RemoteError("unknown kind \"\(kind)\"")
        }
    }

    private func largeNote(_ path: String) -> String {
        queue.largeWarns(BootQueue.fileSize(path)) ? " (WARNING: \(BootQueue.largeWarning))" : ""
    }

    private func armNote(_ req: [String: Any]) -> String {
        guard (req["arm"] as? Bool) == true else { return "" }
        if settings.allowRemoteStart { queue.arm(); return ", queue armed" }
        return ", NOT armed (remote start is disabled in Settings; press Start)"
    }

    private func handleBuild(_ req: [String: Any]) async throws -> String {
        guard !build.building else { throw RemoteError("a build is already running") }
        guard settings.repoValid else { throw RemoteError("repo path is invalid") }
        guard let name = req["name"] as? String, BuildModel.validName(name) else { throw RemoteError("missing or invalid \"name\" (letters, digits, . _ - only)") }
        guard let k = req["kernel"] as? String else { throw RemoteError("missing \"kernel\"") }
        guard let a = req["adt"] as? String else { throw RemoteError("missing \"adt\"") }
        let kernel = try resolve(k, under: "xnu", suffix: nil)
        let adt = try resolveBoot(a, suffix: ".adt")
        var cmdline = ""
        if let c = req["cmdline"] as? String, !c.trimmingCharacters(in: .whitespaces).isEmpty { cmdline = c }
        else if let pn = req["preset"] as? String {
            guard let p = build.presets.first(where: { $0.name == pn }) else {
                throw RemoteError("unknown preset \"\(pn)\" (have: \(build.presets.map(\.name).joined(separator: ", ")))")
            }
            cmdline = p.cmdline
        } else { throw RemoteError("need \"cmdline\" or \"preset\"") }
        build.kernelPath = kernel; build.adtPath = adt; build.cmdline = cmdline; build.imageName = name
        guard let img = await build.runBuild() else { throw RemoteError(build.lastResult ?? "build failed (see Boot Queue > Build output)") }
        var msg = "built \((img as NSString).lastPathComponent)"
        if (req["enqueue"] as? Bool) ?? true {
            queue.add(img, label: (req["label"] as? String) ?? name)
            msg += ", queued" + largeNote(img) + armNote(req)
        }
        return msg
    }

    /// Absolute or repo-relative path that must exist inside `repo/<under>` (symlinks resolved).
    /// A boot image or ADT under Enxerto's out/ (or the pre-rebrand shim/out/).
    private func resolveBoot(_ input: String, suffix: String) throws -> String {
        var last: Error?
        for dir in settings.bootOutDirs {
            do { return try resolve(input, under: dir, suffix: suffix) } catch { last = error }
        }
        throw last ?? RemoteError("\(input) is not inside \(settings.bootDir)/out/")
    }

    private func resolve(_ input: String, under: String, suffix: String?) throws -> String {
        let under = under.isEmpty ? "." : under
        let expanded = (input as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : settings.repoFile(expanded)
        let url = URL(fileURLWithPath: full).standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: settings.repoFile(under)).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(root) else { throw RemoteError("\(input) is not inside \(under)/") }
        if let suffix, !url.path.hasSuffix(suffix) { throw RemoteError("\(input) must end in \(suffix)") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { throw RemoteError("\(input) does not exist") }
        return url.path
    }

    // MARK: status

    private func iso(_ d: Date?) -> Any { d.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }

    private func snapshot() -> [String: Any] {
        let m = monitor
        var phone: [String: Any] = ["state": m.state.rawValue == "iosBooting" ? "ios-booting" : (m.state == .bergamotaFastboot ? "bergamota-fastboot" : m.state.rawValue),
                                    "since": iso(m.stateSince)]
        if let s = m.fastbootSerial { phone["fastbootSerial"] = s }
        if m.state.isFastboot { phone["fastbootKind"] = m.state == .bergamotaFastboot ? "bergamota" : "abl" }
        if let v = m.fastbootVersion, !v.isEmpty, m.state.isFastboot { phone["fastbootVersion"] = v }
        if let b = m.sweetrebootBergamota { phone["sweetrebootBergamota"] = b }
        if let s = m.adbSerial { phone["adbSerial"] = s }
        if m.state == .ios, let i = m.info {
            var ios: [String: Any] = ["kernel": i.uname]
            if let b = i.batteryPercent { ios["battery"] = b }
            if let c = i.isCharging { ios["charging"] = c }
            if let u = i.uptime { ios["uptime"] = Int(u) }
            if let p = i.powerSource { ios["powerSource"] = p }
            phone["ios"] = ios
        }
        if m.state == .ios {
            // `phone.metrics`: the object sweetmetrics printed (docs/BERGAMOTA_METRICS.md) plus when Bergamota fetched it.
            if let mm = m.metrics, let d = mm.json.data(using: .utf8), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                o["fetched"] = ISO8601DateFormatter().string(from: mm.fetched)
                phone["metrics"] = o
            }
            if let e = m.metricsError { phone["metricsError"] = e }
        }
        let items: [[String: Any]] = queue.items.map { it in
            let st: String
            switch it.status {
            case .pending: st = queue.armed ? "waiting" : "pending"
            case .sending: st = "waiting"
            case .sent: st = "sent"
            case .failed: st = "failed"
            }
            var d: [String: Any] = ["id": it.id.uuidString, "label": it.label.isEmpty ? it.fileName : it.label, "image": it.imagePath,
                    "state": st, "sentAt": iso(it.sentAt), "result": String(it.output.suffix(400)),
                    "sizeBytes": it.size, "warning": queue.largeWarns(it) ? BootQueue.largeWarning : "",
                    "needsManualFastboot": it.needsManualFastboot, "autoRebootTried": it.autoRebootTried]
            if let u = it.userdataImage { d["flashUserdata"] = u; d["flashUserdataBytes"] = it.userdataSize; d["flashPartition"] = it.flashTarget
                d["flashVia"] = queue.effectiveVia(it).rawValue; d["flashMode"] = queue.effectiveMode(it).rawValue }
            return d
        }
        let f = queue.flasher
        var flash: [String: Any] = ["active": f.active, "file": f.fileName, "current": f.current, "total": f.total,
                                    "progress": f.active ? f.progressText : "", "partition": f.partition,
                                    "route": f.route == .bergamota ? "bergamota" : "abl", "mode": f.mode.rawValue,
                                    "phase": f.phase, "phaseDoneBytes": f.phaseDone, "phaseTotalBytes": f.phaseTotal,
                                    "deltaBytes": (f.deltaBytes as Any?) ?? NSNull(), "imageBytes": f.bytes,
                                    "defaultRoute": settings.flashVia, "defaultMode": settings.flashMode]
        if let l = f.last { flash["last"] = ["result": l.ok ? "FLASHED" : "FAILED", "at": iso(l.at), "message": l.message] }
        else { flash["last"] = NSNull() }
        return [
            "phone": phone,
            "queue": ["armed": queue.armed, "status": queue.statusText, "items": items,
                      "orangefoxReboot": settings.rebootFromRecovery, "remoteStartAllowed": settings.allowRemoteStart,
                      "autoRebootToFastboot": settings.autoRebootToFastboot, "preferBergamotaFastboot": settings.preferBergamotaFastboot, "autoRebootStatus": (queue.autoStatusText as Any?) ?? NSNull()],
            "flash": flash,
            "liveLog": ["listening": logs.listening, "savingTo": logs.recording ? ((logs.recordPath as Any?) ?? NSNull()) : NSNull(),
                        "linesPerSecond": logs.linesPerSecond, "totalReceived": logs.totalReceived],
            "build": ["building": build.building, "last": (build.lastResult as Any?) ?? NSNull()],
            "lastRequest": (lastRequest as Any?) ?? NSNull(),
            "activity": bannerProvider.map { ["title": $0().title, "subtitle": $0().subtitle] } ?? [:],
        ]
    }

    private func writeStatusIfNeeded(force: Bool = false) {
        let snap = snapshot()
        guard let sig = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]) else { return }
        let now = Date()
        guard force || sig != lastStatusData || now.timeIntervalSince(lastStatusWrite) >= 5 else { return }
        var full = snap
        full["updated"] = ISO8601DateFormatter().string(from: now)
        guard let data = try? JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Self.baseURL, withIntermediateDirectories: true)
        try? data.write(to: Self.statusURL, options: .atomic)
        lastStatusData = sig
        lastStatusWrite = now
    }
}
