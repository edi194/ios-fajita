import Foundation
import Observation

struct QueueItem: Identifiable, Hashable, Codable {
    enum Status: String, Hashable, Codable { case pending, sending, sent, failed }
    var id = UUID()
    var imagePath: String
    var label: String = ""
    var size: Int64 = 0
    var status: Status = .pending
    var sentAt: Date?
    var output = ""
    /// The auto-reboot into fastboot was tried for this item (at most once per item).
    var autoRebootTried = false
    /// The auto-reboot did not end in fastboot within 90 s (or could not be sent): enter fastboot by hand.
    var needsManualFastboot = false
    /// Optional userdata root image flashed (`fastboot flash userdata`, the app's one flash exception) BEFORE the boot, in the same fastboot session.
    /// `imagePath` may then be empty: flash only, no boot.
    var userdataImage: String?
    var userdataSize: Int64 = 0
    /// Partition `userdataImage` is flashed to (nil = userdata; boot or logo allowed, see UserdataFlash.partitions).
    var flashPartition: String?
    var flashTarget: String { flashPartition ?? "userdata" }
    /// Per-item overrides of the flash route (auto/abl/bergamota) and the userdata mode (delta/full); nil = the Settings values.
    var flashVia: String?
    var flashMode: String?
    var hasBoot: Bool { !imagePath.isEmpty }
    var flashesUserdata: Bool { userdataImage != nil }
    /// "flash userdata X, then boot Y" (or only the first half).
    var autoLabel: String {
        var parts: [String] = []
        if let u = userdataImage { parts.append("flash \(flashTarget) \((u as NSString).lastPathComponent)") }
        if hasBoot { parts.append((userdataImage != nil ? "then boot " : "") + (imagePath as NSString).lastPathComponent) }
        return parts.joined(separator: ", ")
    }
    var name: String { label.isEmpty ? autoLabel : label }
    var isLarge: Bool { hasBoot && size > BootQueue.largeImageBytes }
    var fileName: String { hasBoot ? (imagePath as NSString).lastPathComponent : autoLabel }
}

/// Sends exactly ONE `fastboot boot <img>` per fastboot appearance. A failed send is never retried:
/// the phone has to leave fastboot (user re-enters it) before the next item is armed.
@Observable
@MainActor
final class BootQueue {
    /// ABL silently failed to start a 206 MB boot image; warn above this size.
    nonisolated static let largeImageBytes: Int64 = 64 << 20
    static let largeWarning = "large boot image: ABL may not start it"
    /// Bergamota fastboot takes 1 GiB downloads, so the 64 MiB warning only applies when the target is ABL fastboot.
    var targetsBergamota: Bool {
        switch monitor.state {
        case .bergamotaFastboot: true
        case .fastboot: false
        default:
            (pending.first?.flashesUserdata == true ? effectiveVia(pending[0]) != .abl : settings.preferBergamotaFastboot) && tools.bergamotaSupported == true
        }
    }
    func largeWarns(_ size: Int64) -> Bool { size > Self.largeImageBytes && !targetsBergamota }
    func largeWarns(_ item: QueueItem) -> Bool { item.hasBoot && largeWarns(item.size) }
    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    var items: [QueueItem] = [] { didSet { save() } }
    var armed = false { didSet { if armed != oldValue { save() } } }
    var waitingForLeave = false
    /// A flash is moving the phone into Bergamota fastboot (enter + wait for re-enumeration): nothing else is sent meanwhile.
    var preparingFlash = false
    var lastSendFailed = false
    var recoveryRebootSent = false
    var note: String?
    /// Auto-reboot (iOS -> fastboot) bookkeeping, see `autoRebootStep`.
    var rebootWatch: (id: UUID, at: Date)?
    var autoRebootBusy = false
    /// After a failed auto-reboot no further one is attempted until fastboot is seen, the queue is re-armed or the toggle is cycled.
    var autoSuspended = false
    static let autoMinIOSSeconds: TimeInterval = 30
    static let autoFastbootWaitSeconds: TimeInterval = 90

    @ObservationIgnored private var fastbootStreak = 0
    @ObservationIgnored private var nonFastbootStreak = 0
    @ObservationIgnored private var sentSession: String?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor: PhoneMonitor
    @ObservationIgnored private let tools: PhoneTools
    let flasher: UserdataFlasher

    init(settings: AppSettings, monitor: PhoneMonitor, tools: PhoneTools, flasher: UserdataFlasher) {
        self.settings = settings
        self.monitor = monitor
        self.tools = tools
        self.flasher = flasher
        monitor.observers.append { [weak self] old, new in self?.handle(old: old, new: new) }
        load()
    }

    // MARK: persistence (a Bergamota restart used to drop the queue)

    private struct Saved: Codable { var items: [QueueItem]; var armed: Bool }
    @ObservationIgnored private var loading = false
    private static var storeURL: URL {
        if DesignPreview.active { return DesignPreview.queueURL }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bergamota")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    private func save() {
        guard !loading, let data = try? JSONEncoder().encode(Saved(items: items, armed: armed)) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL), var saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        // A send interrupted by the restart may or may not have reached ABL: never resend it automatically.
        for i in saved.items.indices where saved.items[i].status == .sending {
            saved.items[i].status = .failed
            saved.items[i].output += "\nBergamota restarted during the send"
        }
        loading = true
        items = saved.items
        armed = saved.armed
        loading = false
    }

    func effectiveVia(_ it: QueueItem) -> UserdataFlash.Via { it.flashVia.flatMap(UserdataFlash.Via.init) ?? settings.flashViaValue }
    func effectiveMode(_ it: QueueItem) -> UserdataFlash.Mode { it.flashMode.flatMap(UserdataFlash.Mode.init) ?? settings.flashModeValue }

    var pending: [QueueItem] { items.filter { $0.status == .pending } }
    var sending: QueueItem? { items.first { $0.status == .sending } }

    func add(_ path: String, label: String = "") { items.append(QueueItem(imagePath: path, label: label, size: Self.fileSize(path))) }
    /// Item that flashes `userdata` (already validated) and then, if `bootPath` is non-empty, boots `bootPath`.
    func addFlash(userdata: UserdataFlash.Info, bootPath: String = "", label: String = "",
                  via: UserdataFlash.Via? = nil, mode: UserdataFlash.Mode? = nil) {
        items.append(QueueItem(imagePath: bootPath, label: label, size: bootPath.isEmpty ? 0 : Self.fileSize(bootPath),
                               userdataImage: userdata.path, userdataSize: userdata.size,
                               flashPartition: userdata.partition == "userdata" ? nil : userdata.partition,
                               flashVia: via?.rawValue, flashMode: mode?.rawValue))
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id && $0.status != .sending } }
    func clearFinished() { items.removeAll { $0.status == .sent || $0.status == .failed } }
    func move(_ id: UUID, by d: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard items.indices.contains(j), items[i].status == .pending, items[j].status == .pending else { return }
        items.swapAt(i, j)
    }

    func arm() {
        armed = true
        note = nil
        autoSuspended = false
        if settings.notifyOnBoot || settings.notifyOnIOS { Notifier.requestAuthorization() }
    }
    func disarm() { armed = false; rebootWatch = nil }

    /// Everything that sends to the phone is blocked while a userdata flash runs.
    var flashing: Bool { flasher.active }

    var statusText: String {
        if !armed { return pending.isEmpty ? "Queue is empty." : "Queue stopped. Press Start to arm it." }
        if flasher.active { return "Flashing \(flasher.partition) via \(flasher.route == .bergamota ? "Bergamota fastboot" : "ABL fastboot") (\(flasher.progressText)). Do not unplug." }
        if let s = sending { return "Sending \(s.name) ..." }
        if pending.isEmpty { return "Queue is empty." }
        if waitingForLeave {
            return lastSendFailed
                ? "Send failed. ABL may be hung: re-enter fastboot (hold Power + Volume Down). Next item arms once the phone leaves fastboot or re-enumerates."
                : "Boot sent. Waiting for the phone to leave fastboot (or re-enumerate) before arming the next item."
        }
        switch monitor.state {
        case .fastboot, .bergamotaFastboot: return "Phone is in \(monitor.state.title). Confirming, then sending exactly one boot."
        case .recovery:
            return settings.rebootFromRecovery ? "In OrangeFox. Rebooting to bootloader (once)."
                : "Phone is in OrangeFox. Reboot to bootloader, or hold Power + Volume Down."
        case .ios, .iosBooting, .android: return autoStatusText ?? "Waiting for fastboot. Hold Power + Volume Down."
        default: return "Waiting for fastboot. Hold Power + Volume Down."
        }
    }

    /// State of the auto-reboot into fastboot, for the queue header (nil: feature off or nothing to say).
    var autoStatusText: String? {
        guard settings.autoRebootToFastboot, armed, let next = pending.first else { return nil }
        if next.needsManualFastboot {
            return "Needs manual fastboot: the automatic reboot of iOS did not reach fastboot. Hold Power + Volume Down."
        }
        if rebootWatch != nil || autoRebootBusy {
            return "Rebooting iOS into fastboot (waiting up to \(Int(Self.autoFastbootWaitSeconds)) s)."
        }
        if autoSuspended { return "Auto-reboot paused after a failed attempt. Enter fastboot by hand." }
        if monitor.state == .ios {
            let left = Int(Self.autoMinIOSSeconds - Date().timeIntervalSince(monitor.stateSince))
            return left > 0 ? "iOS is up. Auto-reboot into fastboot in about \(left) s." : "iOS is up. Rebooting into fastboot now."
        }
        return nil
    }

    var autoRebootBadge: String? {
        guard settings.autoRebootToFastboot else { return nil }
        return autoSuspended || pending.first?.needsManualFastboot == true ? "auto-reboot: manual fastboot needed" : "auto-reboot to fastboot on"
    }

    /// Reboots iOS into fastboot when the queue is armed, the next item is pending and the phone has been in iOS for
    /// >= 30 s; at most once per item. 90 s after the command without fastboot: the item is marked "needs manual fastboot".
    private func autoRebootStep(new: PhoneState) {
        if !settings.autoRebootToFastboot { autoSuspended = false }
        if new.isFastboot { autoSuspended = false; rebootWatch = nil }
        guard armed, sending == nil, let idx = items.firstIndex(where: { $0.status == .pending }) else { rebootWatch = nil; return }
        if let w = rebootWatch {
            guard let wi = items.firstIndex(where: { $0.id == w.id && $0.status == .pending }) else { rebootWatch = nil; return }
            if !new.isFastboot, Date().timeIntervalSince(w.at) >= Self.autoFastbootWaitSeconds {
                rebootWatch = nil
                markNeedsManual(wi, "iOS reboot did not reach fastboot within \(Int(Self.autoFastbootWaitSeconds)) s")
            }
            return
        }
        guard settings.autoRebootToFastboot, new == .ios, !autoRebootBusy, !autoSuspended, !waitingForLeave,
              !items[idx].autoRebootTried, !items[idx].needsManualFastboot, tools.rebooting == nil, !tools.busy,
              Date().timeIntervalSince(monitor.stateSince) >= Self.autoMinIOSSeconds else { return }
        let id = items[idx].id
        items[idx].autoRebootTried = true
        autoRebootBusy = true
        note = "Auto-reboot: iOS -> fastboot for \(items[idx].name)."
        DebugLog.write("auto-reboot to fastboot for \(items[idx].name)")
        if settings.notifyOnBoot { Notifier.post("Bergamota", "Rebooting iOS into fastboot for \(items[idx].name).") }
        Task {
            let flashItem = items.first { $0.id == id }.flatMap { $0.flashesUserdata ? $0 : nil }
            let (ok, msg, target) = await tools.rebootIOSToFastboot(preferBergamota: flashItem.map { effectiveVia($0) != .abl })
            autoRebootBusy = false
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            if ok { rebootWatch = (id, Date()); note = "Auto-reboot sent (\(target == "bergamota" ? "Bergamota" : "ABL") fastboot). Waiting for fastboot." }
            else { markNeedsManual(i, msg) }
        }
    }

    private func markNeedsManual(_ i: Int, _ why: String) {
        items[i].needsManualFastboot = true
        autoSuspended = true
        note = "Needs manual fastboot (\(items[i].name)): \(why)"
        DebugLog.write("auto-reboot failed: \(why)")
        if settings.notifyOnBoot { Notifier.post("Bergamota", "Needs manual fastboot: \(why)") }
    }

    private func handle(old: PhoneState, new: PhoneState) {
        if new.isFastboot { fastbootStreak = (old.isFastboot && old != new) ? 1 : fastbootStreak + 1; nonFastbootStreak = 0 }
        else {
            fastbootStreak = 0; nonFastbootStreak += 1
            // One poll away from fastboot is enough: a bad image leaves ABL in fastboot, so the absence can be short.
            if waitingForLeave && nonFastbootStreak >= 1 { waitingForLeave = false; lastSendFailed = false }
        }
        // Still in fastboot but re-enumerated on USB (force restart into fastboot between two polls): a new appearance.
        if new.isFastboot, waitingForLeave, let s = monitor.fastbootSession, let old = sentSession, s != old {
            waitingForLeave = false; lastSendFailed = false; fastbootStreak = 1
        }
        if new != .recovery { recoveryRebootSent = false }
        if settings.notifyOnIOS && new == .ios && old != .ios && old != .unknown { Notifier.post("Bergamota", "iOS is up on the Poco F1.") }

        autoRebootStep(new: new)
        guard armed, sending == nil, !flasher.active, !preparingFlash, !tools.enteringBergamota, !pending.isEmpty else { return }

        if new == .recovery, settings.rebootFromRecovery, !recoveryRebootSent {
            recoveryRebootSent = true
            Task { await rebootToBootloader() }
            return
        }
        if new.isFastboot, !waitingForLeave, fastbootStreak >= 2 { Task { await sendNext() } }
    }

    private func rebootToBootloader() async {
        guard let adb = settings.adb else { note = "adb not found"; return }
        var args: [String] = []
        if let s = monitor.adbSerial { args += ["-s", s] }
        args += ["reboot", "bootloader"]
        let r = await Shell.run(adb, args, timeout: 15)
        note = "adb reboot bootloader: " + (r.ok ? "sent" : "failed (\(r.combined.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }

    /// Manual send of the next pending item, ignoring the leave-fastboot latch. Only while the phone is in fastboot.
    /// Returns a short result for the caller (UI or remote request).
    func sendNow() async -> String {
        guard monitor.state.isFastboot else { return "phone is not in fastboot" }
        guard !tools.enteringBergamota else { return "entering Bergamota fastboot" }
        guard !flasher.active else { return "a userdata flash is running" }
        guard sending == nil else { return "a send is already in progress" }
        guard !pending.isEmpty else { return "queue has nothing pending" }
        let id = pending[0].id
        await sendNext(force: true)
        let r = items.first { $0.id == id && ($0.status == .sent || $0.status == .failed) }
        return r.map { "\($0.status == .sent ? "sent" : "FAILED"): \($0.name)" } ?? "not sent"
    }

    private func sendNext(force: Bool = false) async {
        guard sending == nil, !flasher.active, !preparingFlash, !tools.enteringBergamota, force || !waitingForLeave, let idx = items.firstIndex(where: { $0.status == .pending }) else { return }
        guard let fb = settings.fastboot else { note = "fastboot not found"; return }
        // Latch first: whatever happens, no second send until the phone leaves fastboot.
        waitingForLeave = true
        sentSession = monitor.fastbootSession
        lastSendFailed = false
        items[idx].status = .sending
        let path = items[idx].imagePath
        let id = items[idx].id
        var out = ""
        // Optional flash first (userdata/boot/logo only), then exactly one `fastboot boot`. The flash goes through Bergamota
        // fastboot (the main path), entered from ABL on the way; ABL fastboot flashing is the fallback.
        if let ud = items[idx].userdataImage {
            switch UserdataFlash.validate(ud, partition: items[idx].flashTarget) {
            case .failure(let e): finish(id, ok: false, output: "\(items[idx].flashTarget) flash refused: \(e.message)"); return
            case .success(let info):
                var log = ""
                guard let route = await prepareFlashRoute(via: effectiveVia(items[idx]), log: &log) else {
                    finish(id, ok: false, output: log + "could not reach a fastboot that can flash"); return
                }
                let (ok, msg) = await flasher.flash(info, route: route, mode: effectiveMode(items[idx]))
                out = log + flasher.output
                // Whatever fastboot kind we flashed in, no second send until the phone leaves it.
                waitingForLeave = true
                sentSession = monitor.fastbootSession
                if !ok { finish(id, ok: false, output: out + msg); return }
                if path.isEmpty { finish(id, ok: true, output: out); return }
                out += "\n"
            }
        }
        var args: [String] = []
        if let s = monitor.fastbootSerial { args += ["-s", s] }
        args += ["boot", path]
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            finish(id, ok: false, output: out + "image not found: \(path)")
            return
        }
        let r = await Shell.run(fb, args, timeout: 180)
        out += "$ fastboot " + args.map(shellQuote).joined(separator: " ") + "\n" + r.combined
        if r.timedOut { out += "\n[timed out]" }
        if let e = r.launchError { out += "\n\(e)" }
        finish(id, ok: r.ok, output: out)
    }

    /// Puts the phone into the fastboot kind this flash should use and returns the route, or nil (phone unusable). Notes go to `log`.
    /// ABL fastboot + via auto/bergamota: `fastboot boot` the Bergamota fastboot image and wait for the re-enumeration; if that
    /// fails, auto falls back to ABL flashing (when the phone is still in ABL fastboot), bergamota gives up.
    private func prepareFlashRoute(via: UserdataFlash.Via, log: inout String) async -> UserdataFlash.Route? {
        switch monitor.state {
        case .bergamotaFastboot:
            if settings.flashTool == nil { log += "\(UserdataFlash.toolName) not found: can not flash through Bergamota fastboot\n"; return nil }
            if via == .abl { log += "phone is in Bergamota fastboot: flashing there (ABL is not reachable from here)\n" }
            // The read-only build (bergamota-fastboot.img) has no `bergamota-flash` variable: back to ABL, then the flash build.
            if let fb = settings.fastboot, let serial = monitor.fastbootSerial {
                let g = await Shell.run(fb, ["-s", serial, "getvar", "bergamota-flash"], timeout: 5)
                if g.combined.contains("unknown variable") {
                    log += "Bergamota fastboot is the read-only build: rebooting to ABL for the flash build\n"
                    _ = await Shell.run(fb, ["-s", serial, "reboot", "bootloader"], timeout: 10)
                    for _ in 0..<90 {
                        if monitor.state == .fastboot { return await prepareFlashRoute(via: via, log: &log) }
                        try? await Task.sleep(for: .seconds(1))
                    }
                    log += "ABL fastboot did not appear within 90 s\n"
                    return nil
                }
            }
            return .bergamota
        case .fastboot:
            if via == .abl { return .abl }
            if settings.flashTool == nil {
                log += "\(UserdataFlash.toolName) not found; "
                if via == .bergamota { log += "route bergamota requested\n"; return nil }
                log += "falling back to ABL fastboot flashing\n"; return .abl
            }
            preparingFlash = true
            defer { preparingFlash = false }
            note = "Entering Bergamota fastboot for the flash."
            let (ok, msg) = await tools.enterBergamota(forFlash: true)
            log += "enter Bergamota fastboot: \(msg)\n"
            if ok {
                for _ in 0..<60 {
                    if monitor.state == .bergamotaFastboot { note = nil; return .bergamota }
                    try? await Task.sleep(for: .seconds(1))
                }
                log += "Bergamota fastboot did not appear within 60 s\n"
            }
            note = nil
            if via == .bergamota { return nil }
            if monitor.state == .fastboot { log += "FALLBACK: flashing through ABL fastboot\n"; return .abl }
            if monitor.state == .bergamotaFastboot { return .bergamota }
            return nil
        default:
            log += "phone is not in fastboot (state: \(monitor.state.title))\n"
            return nil
        }
    }

    /// Manual "Flash" action (Boot page / Control Plane): in either fastboot kind (ABL: enters Bergamota fastboot first unless
    /// the route is abl), never while the queue sends, and the queue stays latched until the phone leaves fastboot so no boot
    /// follows by itself. `via` / `mode` default to the Settings values.
    func flashUserdataNow(_ info: UserdataFlash.Info, via: UserdataFlash.Via? = nil, mode: UserdataFlash.Mode? = nil) async -> String {
        guard monitor.state.isFastboot else { return "phone is not in fastboot" }
        guard !flasher.active, !preparingFlash else { return "a flash is already running" }
        guard sending == nil else { return "a queue send is in progress" }
        guard monitor.fastbootSerial != nil else { return "no fastboot serial" }
        waitingForLeave = true
        sentSession = monitor.fastbootSession
        var log = ""
        guard let route = await prepareFlashRoute(via: via ?? settings.flashViaValue, log: &log) else {
            flasher.output = log
            flasher.last = (false, Date(), "FAILED: " + (log.split(separator: "\n").last.map(String.init) ?? "no fastboot"))
            return flasher.last?.message ?? "failed"
        }
        waitingForLeave = true
        sentSession = monitor.fastbootSession
        let (_, msg) = await flasher.flash(info, route: route, mode: mode ?? settings.flashModeValue)
        if !log.isEmpty { flasher.output = log + flasher.output }
        nonFastbootStreak = 0
        if settings.notifyOnBoot { Notifier.post("Bergamota", msg) }
        return msg
    }

    private func finish(_ id: UUID, ok: Bool, output: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].status = ok ? .sent : .failed
            items[i].sentAt = Date()
            items[i].output = output
            lastSendFailed = !ok
            if settings.notifyOnBoot {
                Notifier.post("Bergamota", ok ? (items[i].hasBoot ? "fastboot boot sent: \(items[i].name)" : "userdata flashed: \(items[i].name)") : "fastboot boot FAILED: \(items[i].name). Re-enter fastboot.")
            }
        }
        nonFastbootStreak = 0
        if pending.isEmpty { armed = false }
    }
}
