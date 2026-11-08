import Foundation
import Observation

struct BootImage: Identifiable, Hashable, Sendable {
    var path: String
    var size: Int64
    var date: Date
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct CmdlinePreset: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var cmdline: String
}

enum Presets {
    static let defaultCmdline = "debug=0xc serial=3 cpus=8 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweetfb_vsync=1 sweetfb_scale=1 sweetfb_flip=1 sweetusb=2 sweetbattery=1 sweetsample=- sweetnetroute=1 sweetfb_hw=1"
    static var seed: [CmdlinePreset] {
        [CmdlinePreset(name: "default @3x", cmdline: defaultCmdline),
         CmdlinePreset(name: "bluetooth test", cmdline: defaultCmdline + " sweetwlan=2 sweetbtfast=1 sweetbtibs=1"),
         CmdlinePreset(name: "ios18 poc", cmdline: defaultCmdline + " sweetarm64e=1")]
    }
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bergamota")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }
    static func load() -> [CmdlinePreset] {
        if let d = try? Data(contentsOf: fileURL), let p = try? JSONDecoder().decode([CmdlinePreset].self, from: d), !p.isEmpty { return p }
        let s = seed
        save(s)
        return s
    }
    static func save(_ p: [CmdlinePreset]) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(p).write(to: fileURL)
    }
}

@Observable
@MainActor
final class BuildModel {
    var images: [BootImage] = []
    var kernels: [BootImage] = []
    var adts: [BootImage] = []
    var presets: [CmdlinePreset] = Presets.load()

    var kernelPath = ""
    var adtPath = ""
    var cmdline = Presets.defaultCmdline
    var selectedPresetID: UUID?
    var imageName = ""

    var building = false
    var output = ""
    var lastResult: String?
    var lastBuiltImage: String?

    @ObservationIgnored private let settings: AppSettings
    init(settings: AppSettings) {
        self.settings = settings
        selectedPresetID = presets.first?.id
    }

    // MARK: scanning

    func rescan() {
        let fm = FileManager.default
        func scan(_ dir: String, match: (String) -> Bool) -> [BootImage] {
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            return names.filter(match).compactMap { n in
                let p = "\(dir)/\(n)"
                guard let a = try? fm.attributesOfItem(atPath: p) else { return nil }
                return BootImage(path: p, size: (a[.size] as? NSNumber)?.int64Value ?? 0, date: (a[.modificationDate] as? Date) ?? .distantPast)
            }
        }
        let outs = settings.bootOutDirs.map(settings.repoFile)
        images = outs.flatMap { scan($0) { $0.hasSuffix(".img") } }.sorted { $0.date > $1.date }
        adts = outs.flatMap { scan($0) { $0.hasSuffix(".adt") } }.sorted { $0.name < $1.name }
        var ks: [BootImage] = []
        for d in (try? fm.contentsOfDirectory(atPath: settings.repoFile("xnu"))) ?? [] where d.hasPrefix("out-") {
            let p = settings.repoFile("xnu/\(d)/kernel.development.sweet")
            if let a = try? fm.attributesOfItem(atPath: p) {
                ks.append(BootImage(path: p, size: (a[.size] as? NSNumber)?.int64Value ?? 0, date: (a[.modificationDate] as? Date) ?? .distantPast))
            }
        }
        kernels = ks.sorted { $0.date > $1.date }
        if kernelPath.isEmpty || !fm.fileExists(atPath: kernelPath) { kernelPath = kernels.first?.path ?? "" }
        if adtPath.isEmpty || !fm.fileExists(atPath: adtPath) {
            let def = outs.map { $0 + "/beryllium-hi-3x.adt" }.first { fm.fileExists(atPath: $0) }
            adtPath = def ?? (adts.first?.path ?? "")
        }
    }

    func kernelLabel(_ k: BootImage) -> String { (k.path as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? k.name }

    // MARK: presets

    func applyPreset(_ id: UUID?) {
        selectedPresetID = id
        if let p = presets.first(where: { $0.id == id }) { cmdline = p.cmdline }
    }
    func saveCurrentAsPreset(named name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.name == n }) { presets[i].cmdline = cmdline; selectedPresetID = presets[i].id }
        else { let p = CmdlinePreset(name: n, cmdline: cmdline); presets.append(p); selectedPresetID = p.id }
        Presets.save(presets)
    }
    func deleteSelectedPreset() {
        presets.removeAll { $0.id == selectedPresetID }
        Presets.save(presets)
        selectedPresetID = presets.first?.id
    }
    func resetPresets() { presets = Presets.seed; Presets.save(presets); applyPreset(presets.first?.id) }

    // MARK: building

    static func validName(_ n: String) -> Bool {
        !n.isEmpty && n.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) } && !n.hasPrefix(".") && !n.hasPrefix("-")
    }
    var targetImagePath: String { settings.repoFile("\(settings.bootDir)/out/\(settings.bootImageBase)-\(imageName).img") }
    var targetExists: Bool { FileManager.default.fileExists(atPath: targetImagePath) }
    var canBuild: Bool { !building && Self.validName(imageName) && !kernelPath.isEmpty && !adtPath.isEmpty && !cmdline.trimmingCharacters(in: .whitespaces).isEmpty && settings.repoValid }

    func build() { Task { _ = await runBuild() } }

    /// Runs mkpayload + build.sh + copy. Returns the built image path, or nil on failure.
    func runBuild() async -> String? {
        guard canBuild else { lastResult = "Cannot build (check name, kernel, ADT, cmdline, repo)"; return nil }
        guard let python = settings.python else { output = "python3 not found (set it in Settings)\n"; lastResult = "python3 not found"; return nil }
        building = true
        lastResult = nil
        lastBuiltImage = nil
        output = ""
        let name = imageName, kernel = kernelPath, adt = adtPath
        let cmd = cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = settings.repoURL.path
        let dir = settings.bootDir, base = settings.bootImageBase
        let payload = "\(dir)/out/payload-\(name).bin"
        let emit: @Sendable (String) -> Void = { [weak self] s in Task { @MainActor in self?.output += s } }
        func step(_ title: String, _ exe: String, _ args: [String], cwd: String, env: [String: String] = [:]) async -> Bool {
            emit("\n$ " + ([exe] + args).map(shellQuote).joined(separator: " ") + "   (cwd \(cwd))\n")
            let r = await Shell.run(exe, args, cwd: cwd, env: env, timeout: 900, onOutput: emit)
            if let e = r.launchError { emit("launch error: \(e)\n"); return false }
            if r.timedOut { emit("TIMED OUT\n"); return false }
            emit("[\(title): exit \(r.status)]\n")
            return r.ok
        }
        var ok = await step("mkpayload", python, ["tools/mkpayload.py", kernel, adt, payload, "--cmdline", cmd], cwd: repo)
        if ok {
            ok = await step("build.sh", "/bin/bash", ["./build.sh", "out/payload-\(name).bin"], cwd: repo + "/" + dir, env: ["BOARD": "beryllium"])
        }
        var result = "Build failed"
        var built: String?
        if ok {
            let src = repo + "/\(dir)/out/\(base).img", dst = repo + "/\(dir)/out/\(base)-\(name).img"
            do {
                if FileManager.default.fileExists(atPath: dst) { try FileManager.default.removeItem(atPath: dst) }
                try FileManager.default.copyItem(atPath: src, toPath: dst)
                output += "\ncp \(dir)/out/\(base).img -> \(dir)/out/\(base)-\(name).img\n"
                result = "Built \(base)-\(name).img"
                built = dst
            } catch { result = "Copy failed: \(error.localizedDescription)"; output += result + "\n" }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)   // let queued output appends land
        building = false
        lastResult = result
        lastBuiltImage = built
        rescan()
        return built
    }
}
