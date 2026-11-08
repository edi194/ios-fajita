import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    static let defaultRepo = "/Users/zesmoi/git/iAndroid/ios-beryllium"
    @ObservationIgnored private let d = UserDefaults.standard

    var repoPath: String { didSet { d.set(repoPath, forKey: "repoPath") } }
    var phoneIP: String { didSet { d.set(phoneIP, forKey: "phoneIP") } }
    var fastbootPath: String { didSet { d.set(fastbootPath, forKey: "fastbootPath") } }
    var adbPath: String { didSet { d.set(adbPath, forKey: "adbPath") } }
    var ghPath: String { didSet { d.set(ghPath, forKey: "ghPath") } }
    var pythonPath: String { didSet { d.set(pythonPath, forKey: "pythonPath") } }
    var sshPath: String { didSet { d.set(sshPath, forKey: "sshPath") } }
    var ghRepo: String { didSet { d.set(ghRepo, forKey: "ghRepo") } }
    var rebootFromRecovery: Bool { didSet { d.set(rebootFromRecovery, forKey: "rebootFromRecovery") } }
    var notifyOnBoot: Bool { didSet { d.set(notifyOnBoot, forKey: "notifyOnBoot") } }
    var allowRemoteStart: Bool { didSet { d.set(allowRemoteStart, forKey: "allowRemoteStart") } }
    var autoSaveLog: Bool { didSet { d.set(autoSaveLog, forKey: "autoSaveLog") } }
    var notifyOnIOS: Bool { didSet { d.set(notifyOnIOS, forKey: "notifyOnIOS") } }
    /// Reboot the phone from iOS into fastboot (SSH `sweetreboot fastboot`) when a queued image is waiting.
    var autoRebootToFastboot: Bool { didSet { d.set(autoRebootToFastboot, forKey: "autoRebootToFastboot") } }

    /// Prefer Bergamota fastboot (Enxerto's) over ABL fastboot for the automatic reboot of queued boots; falls back to ABL when `sweetreboot bergamota` fails.
    var preferBergamotaFastboot: Bool { didSet { d.set(preferBergamotaFastboot, forKey: "preferBergamotaFastboot") } }
    /// Flash route: "auto" = Bergamota fastboot (Enxerto's, tools/bergamota-flash.py), ABL fastboot as the fallback; "abl" = ABL only.
    var flashVia: String { didSet { d.set(flashVia, forKey: "flashVia") } }
    /// Userdata flash mode through Bergamota fastboot: "delta" (only the blocks that differ, default) or "full".
    var flashMode: String { didSet { d.set(flashMode, forKey: "flashMode") } }
    /// Optional explicit path of tools/bergamota-flash.py (empty = find it in the repo / sibling worktrees).
    var flashToolPath: String { didSet { d.set(flashToolPath, forKey: "flashToolPath") } }
    /// Let `sweetmetrics --gpu-info` open a SweetAdreno630 user client every poll to read the INFO selector (ready/lost). Off by default:
    /// a client on the GPU service can interfere with GPU tests and with the idle slumber of the DCVS governor.
    var metricsGPUInfo: Bool { didSet { d.set(metricsGPUInfo, forKey: "metricsGPUInfo") } }
    /// Image `fastboot boot`ed from ABL fastboot by "Enter Bergamota fastboot".
    var bergamotaImagePath: String { didSet { d.set(bergamotaImagePath, forKey: "bergamotaImagePath") } }
    static let defaultBergamotaImage = "/Users/zesmoi/git/iAndroid/ios-beryllium-ios18/enxerto/out/bergamota-fastboot.img"
    /// Pre-rebrand location, used while the configured image does not exist.
    static let legacyBergamotaImage = "/Users/zesmoi/git/iAndroid/ios-beryllium-ios18/shim/out/bergamota-fastboot.img"

    init() {
        let d = UserDefaults.standard
        repoPath = d.string(forKey: "repoPath") ?? Self.defaultRepo
        phoneIP = d.string(forKey: "phoneIP") ?? "192.168.7.2"
        fastbootPath = d.string(forKey: "fastbootPath") ?? ""
        adbPath = d.string(forKey: "adbPath") ?? ""
        ghPath = d.string(forKey: "ghPath") ?? ""
        pythonPath = d.string(forKey: "pythonPath") ?? ""
        sshPath = d.string(forKey: "sshPath") ?? ""
        ghRepo = d.string(forKey: "ghRepo") ?? "ry-diffusion/Bergamota"
        rebootFromRecovery = d.bool(forKey: "rebootFromRecovery")
        notifyOnBoot = d.object(forKey: "notifyOnBoot") as? Bool ?? true
        allowRemoteStart = d.object(forKey: "allowRemoteStart") as? Bool ?? true
        autoSaveLog = d.object(forKey: "autoSaveLog") as? Bool ?? true
        notifyOnIOS = d.object(forKey: "notifyOnIOS") as? Bool ?? true
        preferBergamotaFastboot = d.object(forKey: "preferBergamotaFastboot") as? Bool ?? true
        bergamotaImagePath = d.string(forKey: "bergamotaImagePath") ?? Self.defaultBergamotaImage
        metricsGPUInfo = d.bool(forKey: "metricsGPUInfo")
        flashVia = d.string(forKey: "flashVia") ?? "auto"
        flashMode = d.string(forKey: "flashMode") ?? "delta"
        flashToolPath = d.string(forKey: "flashToolPath") ?? ""
        autoRebootToFastboot = d.object(forKey: "autoRebootToFastboot") as? Bool ?? true
    }

    var repoURL: URL { URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath) }
    func repoFile(_ rel: String) -> String { repoURL.appendingPathComponent(rel).path }
    /// Enxerto (the bootloader) source dir in the repo: `enxerto/` since the rebrand, `shim/` in older checkouts.
    var bootDir: String { FileManager.default.fileExists(atPath: repoFile("enxerto/build.sh")) ? "enxerto" : "shim" }
    /// Name build.sh gives the boot image in `<bootDir>/out/`.
    var bootImageBase: String { bootDir == "enxerto" ? "enxerto-boot" : "shim-boot" }
    /// Every folder that may hold boot images and ADTs (new and pre-rebrand ones), the current one first.
    var bootOutDirs: [String] { [bootDir + "/out"] + (bootDir == "enxerto" ? ["shim/out"] : []) }
    var flashViaValue: UserdataFlash.Via { UserdataFlash.Via(rawValue: flashVia) ?? .auto }
    var flashModeValue: UserdataFlash.Mode { UserdataFlash.Mode(rawValue: flashMode) ?? .delta }
    /// tools/bergamota-flash.py: the Settings path, else this repo, else sibling worktrees of it.
    var flashTool: String? {
        let fm = FileManager.default
        var cands: [String] = []
        if !flashToolPath.isEmpty { cands = [(flashToolPath as NSString).expandingTildeInPath] }
        else {
            cands = [repoFile("tools/" + UserdataFlash.toolName)]
            for sib in ["ios-beryllium-enxerto-flash", "ios-beryllium-ios18", "ios-beryllium-rebrand"] {
                cands.append(repoURL.deletingLastPathComponent().appendingPathComponent(sib + "/tools/" + UserdataFlash.toolName).path)
            }
        }
        return cands.first { fm.fileExists(atPath: $0) }
    }
    var repoValid: Bool { FileManager.default.fileExists(atPath: repoFile("tools/mkpayload.py")) }

    var fastboot: String? { Shell.resolve("fastboot", override: fastbootPath) }
    var adb: String? { Shell.resolve("adb", override: adbPath) }
    var gh: String? { Shell.resolve("gh", override: ghPath) }
    var python: String? { Shell.resolve("python3", override: pythonPath) }
    var ssh: String? { Shell.resolve("ssh", override: sshPath) }
}
