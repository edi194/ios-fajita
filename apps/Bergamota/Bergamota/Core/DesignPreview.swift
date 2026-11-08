import Foundation
import AppKit

/// Design preview: `Bergamota.app/Contents/MacOS/Bergamota -designPreview ios|bergamota|offline [-designSection NAME]
/// [-designSnapshot DIR]` runs the UI on sample states, isolated from the real app: no USB/SSH polling, no UDP
/// listener, no inbox, and the queue lives in a temporary file. With -designSnapshot it writes each window as a PNG
/// to DIR and quits. Used to review the interface while the real Bergamota keeps running.
enum DesignPreview {
    static let scenario = UserDefaults.standard.string(forKey: "designPreview")
    static var active: Bool { scenario != nil }
    static let section = UserDefaults.standard.string(forKey: "designSection")
    static let snapshotDir = UserDefaults.standard.string(forKey: "designSnapshot")

    static let queueURL = FileManager.default.temporaryDirectory.appendingPathComponent("bergamota-preview-queue-\(ProcessInfo.processInfo.processIdentifier).json")

    @MainActor
    static func apply(_ app: AppModel) {
        let now = Date()
        let m = app.monitor
        switch UserDefaults.standard.string(forKey: "designAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        try? FileManager.default.removeItem(at: queueURL)
        m.lastPoll = now
        m.natForwarding = "1"
        app.logs.listening = true

        // the queue: two waiting, three done (synthetic names in the project's own naming)
        var items: [QueueItem] = []
        func item(_ name: String, _ size: Int64, _ st: QueueItem.Status, _ ago: TimeInterval?, flash: String? = nil, out: String = "") -> QueueItem {
            var it = QueueItem(imagePath: "/repo/enxerto/out/\(name)", size: size, status: st, sentAt: ago.map { now.addingTimeInterval(-$0) }, output: out)
            if let flash { it.userdataImage = "/repo/research/ios26/\(flash)"; it.flashPartition = nil; if name.isEmpty { it.imagePath = "" } }
            return it
        }
        items.append(item("enxerto-boot-ios26full-boot38-wlan-mpss.img", 17_301_504, .failed, 6200, out: "Sending 'boot.img' (16896 KB)  OKAY [ 0.40s]\nBooting  FAILED (remote: 'no response')"))
        items.append(item("enxerto-boot-ios26full-boot39.img", 17_301_504, .sent, 3900, out: "Sending 'boot.img' (16912 KB)  OKAY [ 0.40s]\nBooting  OKAY [ 0.06s]\nFinished. Total time: 0.465s"))
        items.append(item("enxerto-boot-ios26full-boot43-wlan-events.img", 22_282_240, .pending, nil))
        items.append(item("", 0, .pending, nil, flash: "ios26-root-full.simg"))
        app.queue.items = items
        app.queue.armed = scenario == "bergamota"
        app.tools.installed = [InstalledApp(name: "GlassTest.app", recorded: true, apple: false), InstalledApp(name: "SweetRun.app", recorded: true, apple: false),
                               InstalledApp(name: "MobileSafari.app", recorded: false, apple: true), InstalledApp(name: "Preferences.app", recorded: false, apple: true)]

        // CI
        func run(_ id: Int, _ branch: String, _ sha: String, _ title: String, _ concl: String, _ ago: TimeInterval, done: Bool = true) -> CIRun {
            CIRun(databaseId: id, status: done ? "completed" : "in_progress", conclusion: done ? concl : "", headBranch: branch, headSha: sha,
                  createdAt: now.addingTimeInterval(-ago), startedAt: now.addingTimeInterval(-ago + 20), updatedAt: done ? now.addingTimeInterval(-ago + 1260) : nil,
                  displayTitle: title, url: nil)
        }
        app.ci.runs = [run(5, "ios26", "563b095c", "xnu 0251: GPU zap loader resumes an interrupted SCM call", "", 600, done: false),
                       run(4, "main", "d0c1481a", "Bergamota: SSH accepts the iOS 26 host key too", "success", 7200),
                       run(3, "ios18", "15561f8e", "bt18: HCI over SMD, firmware patch RAM", "failure", 30_000),
                       run(2, "ci-cache", "6c4bba12", "ci: cache the xnu toolchain", "success", 90_000)]
        app.ci.lastRefresh = now

        // kernel log
        app.logs.injectPreview([
            "[   0.000] ENXERTO beryllium, payload 16.9 MiB, MMU on",
            "[   1.204] SWEET USB: dwc3 configured, ncm up 02:00:5e:77:ee:01",
            "[   4.880] SWEET FB: simplefb 1080x2246 handoff",
            "[   9.017] SWEET GPU: A630 zap shader loaded, SCM resume ok",
            "[  11.932] SWEET WLAN: MPSS ready over SMP2P",
            "[  12.044] SWEET WLAN: WLFW up after 7 pd-mapper requests",
            "[  14.311] launchd: backboardd[64] on Chlorophyll",
            "[  21.902] SWEET GPU: fence 0x3f1 signalled in 3.1 ms",
            "[  22.410] SpringBoard: lock screen presented",
        ])

        switch scenario {
        case "bergamota":
            m.state = .bergamotaFastboot
            m.stateSince = now.addingTimeInterval(-212)
            m.fastbootSerial = "bergamota0001"
            m.fastbootVersion = "bergamota-11"
        case "offline":
            m.state = .offline
            m.stateSince = now.addingTimeInterval(-1830)
        default:
            m.state = .ios
            m.stateSince = now.addingTimeInterval(-2540)
            m.ifaceName = "en7"; m.ifaceUp = true; m.ifaceHasIP = true; m.pingOK = true; m.sshOpen = true
            m.info = IOSInfo(uname: "Darwin iPhone 25.0.0 Darwin Kernel Version 25.0.0: Heartwood xnu-12377/RELEASE_ARM64_T8020 arm64",
                             uptime: 2575, batteryPercent: 86, isCharging: true, powerSource: "USB", sweetrebootBergamota: true)
            for k in stride(from: 60, through: 0, by: -1) {
                let t = now.addingTimeInterval(-Double(k) * 2)
                let wave = sin(Double(k) / 6)
                var s = PhoneMetrics(t: t, fetched: t)
                s.freqKnown = true
                var silver = ClusterMetrics(id: 0, name: "Silver", cpus: [0, 1, 2, 3])
                silver.curKhz = 748_800 + Int(400_000 * max(0, wave)); silver.maxKhz = 1_766_400; silver.mode = "governor"; silver.governor = "gov"; silver.loadPct = 22 + 14 * wave
                var gold = ClusterMetrics(id: 1, name: "Gold", cpus: [4, 5, 6, 7])
                gold.curKhz = 1_612_800 + Int(800_000 * max(0, -wave)); gold.maxKhz = 2_803_200; gold.mode = "governor"; gold.governor = "gov"; gold.loadPct = 41 + 30 * max(0, -wave)
                s.clusters = [silver, gold]
                s.cpuLoad = [18, 27, 9, 31, 64, 12, 48, 70].map { $0 + 10 * wave }
                s.gpu = GPUMetrics(present: true, state: "on", level: 3, levels: 6, mhz: 414 + 120 * wave, maxMhz: 710, busyPct: 38 + 20 * wave, clients: 2, freqMode: "gov")
                s.renderer = RendererMetrics(mode: "fd630", label: "A630 (Chlorophyll)", requested: "1", injected: true, gpuClientOpen: true)
                s.battery = BatteryMetrics(present: true, percent: 86, charging: true, external: true, currentMa: 412 - 90 * wave, voltageMv: 4_180, source: "USB")
                s.batteryTempC = 31.4
                m.metricsHistory.add(s)
                if k == 0 { m.metrics = s }
            }
        }
    }

    /// Writes every visible window of the app to `dir` as PNG (the windows' own drawing, no screen capture), then quits.
    @MainActor
    static func snapshotAndQuit(_ name: String) {
        guard let dir = snapshotDir else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                guard let view = w.contentView?.superview ?? w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let file = (dir as NSString).appendingPathComponent("\(name)\(i == 0 ? "" : "-\(i)").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            }
            NSApp.terminate(nil)
        }
    }
}
