import SwiftUI
import Observation

struct ActivityBanner: Equatable {
    var title: String
    var subtitle: String = ""
    var tone: Tone
    var symbol: String
    /// Set while something with known progress runs: the banner becomes a progress bar.
    var progress: Double? = nil
}

/// Extension points other features (e.g. reboot-to-fastboot) can plug into the Control Plane.
@Observable
@MainActor
final class ControlPlaneHooks {
    /// Reboots the phone to fastboot; returns a short result. nil = feature not available.
    var rebootToFastboot: (@MainActor () async -> String)?
    /// Reboots iOS into Bergamota fastboot (`sweetreboot bergamota`).
    var rebootToBergamota: (@MainActor () async -> String)?
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%d:%02d", s / 60, s % 60)
}

extension AppModel {
    static let bootTimeout: TimeInterval = 300

    /// The most recent successfully sent queue item (a boot in flight until iOS comes up or the timeout).
    var lastSent: QueueItem? { queue.items.filter { $0.status == .sent && $0.sentAt != nil && $0.hasBoot }.max { $0.sentAt! < $1.sentAt! } }
    var lastFailed: QueueItem? { queue.items.filter { $0.status == .failed && $0.sentAt != nil }.max { $0.sentAt! < $1.sentAt! } }

    /// What the app is doing or seeing right now, as one high-contrast banner.
    func activityBanner(now: Date = Date()) -> ActivityBanner {
        let st = monitor.state
        // kernel log: panic
        if let at = logs.lastPanicAt, now.timeIntervalSince(at) < 600, !(st == .ios && monitor.stateSince > at) {
            return ActivityBanner(title: "PANIC", subtitle: String((logs.lastPanicLine ?? "").prefix(160)), tone: .alert, symbol: "exclamationmark.octagon.fill")
        }
        if let n = tools.installing { return ActivityBanner(title: n.hasPrefix("uninstall") ? "REMOVING \(n.dropFirst(10).uppercased())" : "INSTALLING \(n.uppercased())", subtitle: "sideloading over SSH", tone: .ink, symbol: "square.and.arrow.down.fill") }
        if let n = tools.uploadingCount { return ActivityBanner(title: "UPLOADING \(n) FILE\(n == 1 ? "" : "S")", subtitle: "to the phone over SSH", tone: .ink, symbol: "arrow.up.circle.fill") }
        if build.building { return ActivityBanner(title: "BUILDING \(build.imageName.uppercased())", subtitle: "mkpayload + build.sh", tone: .ink, symbol: "hammer.fill") }
        if queue.flasher.active {
            let f = queue.flasher
            let frac = f.fraction(now: now)
            let pct = frac.map { " \(Int($0 * 100))%" } ?? (f.total > 0 ? " \(f.progressText)" : "")
            let detail = f.progressDetail(now: now) ?? (f.route == .bergamota ? "\(f.phaseLabel)..." : (f.total > 0 ? "chunk \(f.progressText), measuring speed" : "starting"))
            let title = f.route == .bergamota && f.phase != "send" && !f.phase.isEmpty ? f.phaseLabel.uppercased() : "FLASHING \(f.partition.uppercased())"
            return ActivityBanner(title: title + pct,
                                  subtitle: "\(detail)  |  \(f.fileName)  |  do not unplug", tone: .alert,
                                  symbol: "externaldrive.fill.badge.exclamationmark", progress: frac ?? (f.total > 0 ? 0 : nil))
        }
        if let l = queue.flasher.last, now.timeIntervalSince(l.at) < 300, queue.sending == nil, (lastSent?.sentAt ?? .distantPast) < l.at, st.isFastboot || !l.ok {
            return l.ok ? ActivityBanner(title: "FLASHED", subtitle: "\(queue.flasher.partition) \(queue.flasher.fileName). Boot the image or reboot.", tone: .leaf, symbol: "checkmark.seal.fill")
                        : ActivityBanner(title: "FAILED", subtitle: "\(queue.flasher.partition) flash failed. See the Flash page output.", tone: .alert, symbol: "xmark.octagon.fill")
        }
        if let s = queue.sending { return ActivityBanner(title: "SENDING \(s.name.uppercased())", subtitle: "fastboot boot, do not unplug", tone: .amber, symbol: "paperplane.fill") }

        if tools.enteringBergamota { return ActivityBanner(title: "ENTERING BERGAMOTA FASTBOOT", subtitle: "fastboot boot bergamota-fastboot.img, do not unplug", tone: .lime, symbol: "leaf.circle.fill") }
        if let n = tools.rebooting { return ActivityBanner(title: "REBOOTING TO \(n.uppercased())", subtitle: "sweetreboot over SSH", tone: n == "bergamota" ? .lime : .amber, symbol: "arrow.triangle.2.circlepath") }

        if let sent = lastSent, let at = sent.sentAt {
            let el = now.timeIntervalSince(at)
            let up = st == .ios && monitor.stateSince > at
            if !up && el < Self.bootTimeout {
                var hint = "elapsed \(formatElapsed(el))"
                if let l = logs.lastSweetLine, let t = logs.lastSweetAt, now.timeIntervalSince(t) < 20 { hint += "  |  " + String(l.prefix(110)) }
                if st.isFastboot && el > 20 {
                    return ActivityBanner(title: "STILL IN \(st.title.uppercased())", subtitle: "\(sent.name) did not start (\(formatElapsed(el)) after send). Re-enter fastboot.", tone: .amber, symbol: "exclamationmark.triangle.fill")
                }
                if st != .recovery { return ActivityBanner(title: "BOOTING \(sent.name.uppercased())", subtitle: hint, tone: .amber, symbol: "hourglass") }
            }
        }
        if st.isFastboot, queue.armed, !queue.pending.isEmpty {
            return ActivityBanner(title: "IN \(st.title.uppercased())", subtitle: "queue armed: sending next boot", tone: stateTone(st), symbol: st.symbol)
        }
        if queue.armed, !queue.pending.isEmpty, !st.isFastboot {
            return ActivityBanner(title: "WAITING FOR FASTBOOT", subtitle: "hold Power + Volume Down (ABL)  |  next: \(queue.pending[0].name)", tone: .amber, symbol: "bolt.horizontal.circle")
        }
        switch st {
        case .ios:
            var sub = "seen up \(formatUptime(now.timeIntervalSince(monitor.stateSince)))"
            if let i = monitor.info, let b = i.batteryPercent { sub = "battery \(b)%" + (i.isCharging == true ? ", charging" : "") + "  ·  " + sub }
            return ActivityBanner(title: "iOS UP", subtitle: sub, tone: .leaf, symbol: "apple.logo")
        case .fastboot: return ActivityBanner(title: "ABL FASTBOOT", subtitle: "Qualcomm ABL (serial \(monitor.fastbootSerial ?? "?")): fastboot boot and flash (fallback route)", tone: .amber, symbol: st.symbol)
        case .bergamotaFastboot: return ActivityBanner(title: "BERGAMOTA FASTBOOT", subtitle: "Enxerto (\(monitor.fastbootVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "serial \(monitor.fastbootSerial ?? "?")")): fastboot boot and flash userdata/boot/logo (main flash route)", tone: .lime, symbol: st.symbol)
        case .recovery: return ActivityBanner(title: "IN ORANGEFOX", subtitle: "recovery over adb", tone: .ink, symbol: "wrench.and.screwdriver.fill")
        case .android: return ActivityBanner(title: "ANDROID", subtitle: "adb device", tone: .ink, symbol: "android.fill")
        case .iosBooting: return ActivityBanner(title: "iOS BOOTING", subtitle: monitor.sshPortOpen ? "USB network up, SSH port open but the server does not answer yet" : "USB network is up, waiting for SSH", tone: .amber, symbol: "hourglass")
        case .unknown: return ActivityBanner(title: "CHECKING...", tone: .quiet, symbol: "ellipsis.circle")
        case .offline: return ActivityBanner(title: "OFFLINE", subtitle: "no device on USB (charging or powered off)", tone: .quiet, symbol: "bolt.slash")
        }
    }
}
