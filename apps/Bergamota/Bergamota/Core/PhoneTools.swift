import Foundation
import Observation

struct InstalledApp: Identifiable, Hashable {
    var name: String            // Foo.app
    var recorded: Bool          // installed through Bergamota / sweet-install-ipa.sh
    var apple: Bool             // looks like a system app (bundle id com.apple.*)
    var id: String { name }
    var ours: Bool { recorded || !apple }
}

struct UploadRecord: Identifiable {
    let id = UUID()
    var date = Date()
    var name: String
    var dest: String
    var ok: Bool
    var message: String
}

/// Sideloading (tools/sweet-install-ipa.sh) and file/photo upload (tools/sweet-push-photo.sh, scp) over the phone's SSH.
@Observable
@MainActor
final class PhoneTools {
    static let defaultDownloads = "/private/var/mobile/Media/Downloads"
    static let allowedDestPrefixes = ["/private/var/mobile/", "/var/mobile/", "/private/var/tmp/", "/tmp/"]

    var installing: String?                 // app/ipa name while an install or uninstall runs
    var uploadingCount: Int?                // files in the running upload
    var output = ""
    var installed: [InstalledApp] = []
    var listing = false
    var listError: String?
    var uploads: [UploadRecord] = []
    var uploadOutput = ""

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor: PhoneMonitor
    init(settings: AppSettings, monitor: PhoneMonitor) { self.settings = settings; self.monitor = monitor }

    var iosUp: Bool { monitor.state == .ios }
    var disabledReason: String? { iosUp ? nil : "iOS is not up (state: \(monitor.state.title)). SSH actions are disabled." }
    var busy: Bool { installing != nil || uploadingCount != nil }
    var rebooting: String?                  // "fastboot" / "bergamota" / "recovery" while the reboot command runs
    var enteringBergamota = false           // `fastboot boot bergamota-fastboot.img` from ABL fastboot is running
    var bergamotaSupported: Bool? { monitor.sweetrebootBergamota }
    static let rebootTool = "/usr/local/bin/sweetreboot"

    // MARK: plumbing

    private var host: String { "root@\(settings.phoneIP)" }

    /// ssh/scp wrappers adding Shell.sshOptions, put first on PATH for the repo scripts.
    private func environment() -> [String: String] {
        let dir = RemoteControl.baseURL.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, real) in [("ssh", "/usr/bin/ssh"), ("scp", "/usr/bin/scp")] {
            let p = dir.appendingPathComponent(n)
            let opts = Shell.sshOptions.map { "'\($0)'" }.joined(separator: " ")
            let body = "#!/bin/sh\nexec \(real) \(opts) \"$@\"\n"
            if (try? String(contentsOf: p, encoding: .utf8)) != body {
                try? body.write(to: p, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
            }
        }
        return ["PATH": dir.path + ":" + Shell.childPath, "SWEET_HOST": host]
    }

    private func sshArgs(_ remote: String) -> [String] { Shell.sshOptions + [host, remote] }

    private func log(_ s: String) { output += s }

    // MARK: reboot

    /// `sweetreboot fastboot|recovery` over SSH (tools/sweetnet/sweetreboot.c, kernel patch 0137): sets
    /// kern.sweet_reboot_mode and reboots. The SSH connection dies with the phone, so success is judged
    /// by the tool's "next reboot mode" line, not by the exit status.
    func rebootIOS(to target: String) async -> (Bool, String) {
        guard iosUp else { return (false, disabledReason ?? "iOS is not up") }
        guard target == "fastboot" || target == "recovery" || target == "bergamota" else { return (false, "unknown reboot target \"\(target)\" (fastboot, bergamota or recovery)") }
        guard !busy, rebooting == nil else { return (false, "another install/upload/reboot is running") }
        guard let ssh = settings.ssh else { return (false, "ssh not found") }
        rebooting = target
        defer { rebooting = nil }
        log("\n$ ssh \(host) \(Self.rebootTool) \(target)\n")
        let r = await Shell.run(ssh, sshArgs("\(Self.rebootTool) \(target)"), timeout: 20)
        let out = r.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        log(out + "\n")
        DebugLog.write("reboot to \(target): status=\(r.status) timedOut=\(r.timedOut) \(out)")
        if out.contains("next reboot mode") { return (true, "reboot to \(target) sent") }
        if r.status == 127 || out.contains("not found") || out.contains("No such file") {
            return (false, "\(Self.rebootTool) is not on the phone: scp research/sweetnet/sweetreboot \(host):\(Self.rebootTool)")
        }
        if let e = r.launchError { return (false, e) }
        return (false, r.timedOut ? "ssh timed out" : (out.isEmpty ? "exit \(r.status)" : out))
    }

    /// Automatic reboot for queued boots: Bergamota fastboot when preferred (and the phone's sweetreboot is not known to lack it),
    /// ABL fastboot when not or when `sweetreboot bergamota` fails. Returns the target that was sent.
    /// `preferBergamota` overrides the setting (a queue item that flashes always wants Bergamota fastboot, its main flash path).
    func rebootIOSToFastboot(preferBergamota: Bool? = nil) async -> (ok: Bool, msg: String, target: String) {
        if preferBergamota ?? settings.preferBergamotaFastboot, bergamotaSupported != false {
            let r = await rebootIOS(to: "bergamota")
            if r.0 { return (true, r.1, "bergamota") }
            DebugLog.write("sweetreboot bergamota failed (\(r.1)), falling back to ABL fastboot")
            guard iosUp else { return (false, r.1, "bergamota") }
            let f = await rebootIOS(to: "fastboot")
            return (f.0, f.0 ? "bergamota failed (\(r.1)); " + f.1 : f.1, "fastboot")
        }
        let f = await rebootIOS(to: "fastboot")
        return (f.0, f.1, "fastboot")
    }

    /// ABL fastboot -> Bergamota fastboot: `fastboot -s <serial> boot <bergamota-fastboot.img>`. Only from ABL fastboot.
    /// `forFlash`: prefer the flash-capable build `bergamota-fastboot-flash.img` (next to the configured image, in shim/out or enxerto/out).
    static let flashImageName = "bergamota-fastboot-flash.img"
    func bergamotaImage(forFlash: Bool) -> String {
        var path = (settings.bergamotaImagePath as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path), path == AppSettings.defaultBergamotaImage { path = AppSettings.legacyBergamotaImage }
        if forFlash {
            let dirs = [(path as NSString).deletingLastPathComponent, settings.repoFile("shim/out"), settings.repoFile("enxerto/out")]
            for d in dirs {
                let c = d + "/" + Self.flashImageName
                if FileManager.default.fileExists(atPath: c) { return c }
            }
        }
        return path
    }

    func enterBergamota(forFlash: Bool = false) async -> (Bool, String) {
        guard monitor.state == .fastboot else { return (false, "phone is not in ABL fastboot (state: \(monitor.state.title))") }
        guard !enteringBergamota else { return (false, "already entering Bergamota fastboot") }
        let path = bergamotaImage(forFlash: forFlash)
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, "Bergamota fastboot image not found: \(path). Build it with Enxerto (enxerto/out/bergamota-fastboot.img) or set the path in Settings.")
        }
        guard let fb = settings.fastboot else { return (false, "fastboot not found") }
        guard let serial = monitor.fastbootSerial, !serial.isEmpty else { return (false, "no fastboot serial") }
        enteringBergamota = true
        defer { enteringBergamota = false }
        let args = ["-s", serial, "boot", path]
        log("\n$ fastboot " + args.map(shellQuote).joined(separator: " ") + "\n")
        let r = await Shell.run(fb, args, timeout: 120)
        log(r.combined + "\n")
        DebugLog.write("enter bergamota: status=\(r.status) timedOut=\(r.timedOut) \(r.combined)")
        if let e = r.launchError { return (false, e) }
        if r.timedOut { return (false, "fastboot boot timed out") }
        return r.ok ? (true, "booted \((path as NSString).lastPathComponent); waiting for Bergamota fastboot") : (false, r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: apps

    private var recordURL: URL { RemoteControl.baseURL.appendingPathComponent("sideloaded.json") }
    private func loadRecord() -> [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: recordURL))) ?? [] }
    private func saveRecord(_ r: [String]) {
        try? FileManager.default.createDirectory(at: RemoteControl.baseURL, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(Set(r)).sorted()).write(to: recordURL)
    }

    func refreshInstalled() async {
        guard !listing, !DesignPreview.active else { return }
        guard iosUp, let ssh = settings.ssh else { listError = disabledReason ?? "ssh not found"; return }
        listing = true
        defer { listing = false }
        let cmd = "cd /Applications && for a in *.app; do [ -d \"$a\" ] || continue; if grep -aq 'com\\.apple\\.' \"$a/Info.plist\" 2>/dev/null; then echo \"$a apple\"; else echo \"$a other\"; fi; done"
        let r = await Shell.run(ssh, sshArgs(cmd), timeout: 15)
        guard r.ok else { listError = r.launchError ?? (r.timedOut ? "ssh timed out" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)); return }
        listError = nil
        let rec = Set(loadRecord())
        installed = r.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count == 2 else { return nil }
            return InstalledApp(name: String(f[0]), recorded: rec.contains(String(f[0])), apple: f[1] == "apple")
        }.sorted { ($0.ours ? 0 : 1, $0.name) < ($1.ours ? 0 : 1, $1.name) }
    }

    /// Runs tools/sweet-install-ipa.sh. Returns (ok, message).
    func installIPA(_ path: String) async -> (Bool, String) {
        guard iosUp else { return (false, disabledReason ?? "iOS is not up") }
        guard !busy else { return (false, "another install/upload is running") }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.lowercased().hasSuffix(".ipa"), FileManager.default.fileExists(atPath: expanded) else { return (false, "\(path) is not an existing .ipa") }
        let script = settings.repoFile("tools/sweet-install-ipa.sh")
        guard FileManager.default.fileExists(atPath: script) else { return (false, "tools/sweet-install-ipa.sh not found in the repo") }
        let name = (expanded as NSString).lastPathComponent
        installing = name
        defer { installing = nil }
        log("\n$ tools/sweet-install-ipa.sh \(shellQuote(expanded))\n")
        let r = await Shell.run("/bin/sh", [script, expanded], cwd: settings.repoURL.path, env: environment(), timeout: 900) { [weak self] s in
            Task { @MainActor in self?.output += s }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        if r.ok {
            if let m = r.combined.firstMatch(of: /re-signed (\S+\.app)/) { saveRecord(loadRecord() + [String(m.1)]) }
            log("[install finished]\n")
            await refreshInstalled()
            return (true, "installed \(name)")
        }
        let tail = r.combined.split(separator: "\n").last.map(String.init) ?? "exit \(r.status)"
        log("[install FAILED: \(tail)]\n")
        return (false, r.timedOut ? "install timed out" : tail)
    }

    func uninstall(_ app: InstalledApp) async -> (Bool, String) {
        guard iosUp else { return (false, disabledReason ?? "iOS is not up") }
        guard app.ours, !app.apple || app.recorded else { return (false, "refusing to remove \(app.name): looks like a system app") }
        guard !busy else { return (false, "another install/upload is running") }
        guard app.name.hasSuffix(".app"), app.name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return (false, "unsafe app name") }
        installing = "uninstall \(app.name)"
        defer { installing = nil }
        let script = settings.repoFile("tools/sweet-install-ipa.sh")
        log("\n$ tools/sweet-install-ipa.sh -u \(app.name)\n")
        let r = await Shell.run("/bin/sh", [script, "-u", app.name], cwd: settings.repoURL.path, env: environment(), timeout: 60)
        log(r.combined + "\n")
        if r.ok { saveRecord(loadRecord().filter { $0 != app.name }); await refreshInstalled(); return (true, "removed \(app.name)") }
        return (false, r.combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: uploads

    nonisolated static func isImage(_ p: String) -> Bool { ["jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "bmp", "webp"].contains((p as NSString).pathExtension.lowercased()) }
    nonisolated static func isVideo(_ p: String) -> Bool { ["mov", "mp4", "m4v"].contains((p as NSString).pathExtension.lowercased()) }

    static func validDest(_ d: String) -> Bool {
        d.hasPrefix("/") && !d.contains("..") && d.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/_.-".contains($0)) }
            && allowedDestPrefixes.contains { d.hasPrefix($0) || d + "/" == $0 }
    }

    private func record(_ name: String, _ dest: String, _ ok: Bool, _ msg: String) {
        uploads.insert(UploadRecord(name: name, dest: dest, ok: ok, message: msg), at: 0)
        if uploads.count > 50 { uploads.removeLast(uploads.count - 50) }
    }

    /// dest: "photos" (images via sweet-push-photo.sh, videos to DCIM) or an absolute phone folder.
    func upload(_ paths: [String], dest: String) async -> (Bool, String) {
        guard iosUp else { return (false, disabledReason ?? "iOS is not up") }
        guard !busy else { return (false, "another install/upload is running") }
        let files = paths.map { ($0 as NSString).expandingTildeInPath }
        for f in files {
            var d: ObjCBool = false
            guard FileManager.default.fileExists(atPath: f, isDirectory: &d), !d.boolValue, f.hasPrefix("/") else { return (false, "\(f) is not an existing file (absolute path needed)") }
        }
        guard !files.isEmpty else { return (false, "no files") }
        let photos = dest == "photos"
        if !photos && !Self.validDest(dest) { return (false, "destination must be an absolute path under \(Self.allowedDestPrefixes.joined(separator: ", ")) (letters, digits, / _ . - only)") }
        guard let ssh = settings.ssh, let scp = Shell.resolve("scp") else { return (false, "ssh/scp not found") }
        uploadingCount = files.count
        defer { uploadingCount = nil }
        let env = environment()
        var okCount = 0, lastError = ""
        let dcim = "/private/var/mobile/Media/DCIM/100APPLE"
        let images = files.filter { photos && Self.isImage($0) }
        let videos = files.filter { photos && Self.isVideo($0) }
        let others = files.filter { f in !(photos && (Self.isImage(f) || Self.isVideo(f))) }
        if !images.isEmpty {
            let script = settings.repoFile("tools/sweet-push-photo.sh")
            let r = await Shell.run("/bin/sh", [script] + images, cwd: settings.repoURL.path, env: env, timeout: 300)
            uploadOutput += r.combined
            for f in images { record((f as NSString).lastPathComponent, "Camera Roll", r.ok, r.ok ? "converted to JPEG in DCIM/100APPLE" : r.combined.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if r.ok { okCount += images.count } else { lastError = r.combined.split(separator: "\n").last.map(String.init) ?? "photo push failed" }
        }
        func send(_ f: String, to folder: String, as name: String, label: String) async {
            let mk = await Shell.run(ssh, sshArgs("mkdir -p \(folder)"), timeout: 15)
            guard mk.ok else { let e = mk.stderr.trimmingCharacters(in: .whitespacesAndNewlines); record(name, label, false, e); lastError = e; return }
            let r = await Shell.run(scp, ["-O"] + Shell.sshOptions + [f, "\(host):\(folder)/\(name)"], timeout: 1800)
            uploadOutput += "\(f) -> \(folder)/\(name)\n" + r.combined
            if r.ok {
                _ = await Shell.run(ssh, sshArgs("chown 501:501 \(folder)/\(name)"), timeout: 15)
                okCount += 1; record(name, label, true, "\(folder)/\(name)")
            }
            else { let e = r.combined.trimmingCharacters(in: .whitespacesAndNewlines); record(name, label, false, e); lastError = e }
        }
        func safeName(_ f: String) -> String {
            String(((f as NSString).lastPathComponent).map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
        }
        for f in videos { await send(f, to: dcim, as: "VID_" + safeName(f), label: "Camera Roll") }
        if !videos.isEmpty { _ = await Shell.run(ssh, sshArgs("chown -R 501:501 /private/var/mobile/Media/DCIM"), timeout: 15) }
        for f in others { await send(f, to: photos ? PhoneTools.defaultDownloads : dest, as: safeName(f), label: photos ? PhoneTools.defaultDownloads : dest) }
        let total = files.count
        return okCount == total ? (true, "uploaded \(total) file(s)") : (false, "\(okCount)/\(total) uploaded" + (lastError.isEmpty ? "" : ": \(lastError)"))
    }
}
