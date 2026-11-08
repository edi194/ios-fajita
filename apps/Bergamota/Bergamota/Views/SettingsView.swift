import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        VStack(alignment: .leading, spacing: 0) {
        PageHeader("Settings", subtitle: "Paths, the phone, the queue's automation and the flash route.")
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 4)
        Form {
            Section("Repository") {
                HStack {
                    TextField("Repo path", text: $s.repoPath)
                    Button("Choose...") { chooseRepo() }
                }
                Label(s.repoValid ? "Repo found" : "tools/mkpayload.py not found here",
                      systemImage: s.repoValid ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(s.repoValid ? Color.leafText : Color.amberText)
                TextField("GitHub repo", text: $s.ghRepo)
            }
            Section("Phone") {
                TextField("Phone IP", text: $s.phoneIP)
                Text("USB Ethernet is found by MAC \(PhoneMonitor.usbMAC); SSH as root@IP (key only).").font(.caption).foregroundStyle(Color.muted)
                Toggle("Read the GPU INFO selector (opens a SweetAdreno630 user client every 2 s)", isOn: $s.metricsGPUInfo)
                Text("Live metrics run /usr/local/bin/sweetmetrics over SSH every ~2 s while iOS is up. Off (default): read-only registry/sysctl sources only, no GPU client is opened.").font(.caption).foregroundStyle(Color.muted)
            }
            Section("Tools (leave empty to resolve via PATH, /opt/homebrew/bin, /usr/local/bin)") {
                toolRow("fastboot", $s.fastbootPath, s.fastboot)
                toolRow("adb", $s.adbPath, s.adb)
                toolRow("gh", $s.ghPath, s.gh)
                toolRow("python3", $s.pythonPath, s.python)
                toolRow("ssh", $s.sshPath, s.ssh)
            }
            Section("Control Plane") {
                Toggle("Open the Control Plane window at launch", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "openControlPlane") }, set: { UserDefaults.standard.set($0, forKey: "openControlPlane") }))
                Text("Window > Control Plane (Shift+Cmd+C). Its Display menu moves it to another screen and can make it full screen; the choice is remembered.").font(.caption).foregroundStyle(Color.muted)
            }
            Section("Live log") {
                Toggle("Always save the live log to logs/usb-<timestamp>.txt", isOn: $s.autoSaveLog)
            }
            Section("Remote control") {
                Toggle("Allow remote requests to start the queue", isOn: $s.allowRemoteStart)
                Text("Requests are JSON files dropped in ~/Library/Application Support/Bergamota/inbox (see scripts/bergamota). Status: status.json next to it.")
                    .font(.caption).foregroundStyle(Color.muted)
            }
            Section("Boot queue") {
                Toggle("If in OrangeFox, run `adb reboot bootloader` first", isOn: $s.rebootFromRecovery)
                Toggle("Notify when a boot is sent", isOn: $s.notifyOnBoot)
                Toggle("Notify when iOS comes up", isOn: $s.notifyOnIOS)
                Toggle("Auto-reboot iOS into fastboot when a queued image is waiting", isOn: $s.autoRebootToFastboot)
                Toggle("Prefer Bergamota fastboot for the auto-reboot", isOn: $s.preferBergamotaFastboot)
                Text("Uses `sweetreboot bergamota` (kernel patch 0140); falls back to ABL fastboot if it fails. The 64 MiB large-image warning only applies to ABL fastboot. Phone's sweetreboot supports bergamota: \(model.monitor.sweetrebootBergamota.map { $0 ? "yes" : "no" } ?? "not checked yet (needs iOS up)").")
                    .font(.caption).foregroundStyle(Color.muted)
                TextField("Bergamota fastboot image", text: $s.bergamotaImagePath, prompt: Text(AppSettings.defaultBergamotaImage))
                HStack(spacing: 4) {
                    let ok = FileManager.default.fileExists(atPath: (s.bergamotaImagePath as NSString).expandingTildeInPath)
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? Color.leafText : Color.alertText)
                    Text(ok ? "found (used by \"Enter Bergamota fastboot\")" : "missing: Enter Bergamota fastboot will refuse until it exists").font(.caption).foregroundStyle(Color.muted)
                }
                Picker("Flash route", selection: $s.flashVia) {
                    Text("Bergamota fastboot (ABL as fallback)").tag("auto")
                    Text("ABL fastboot only").tag("abl")
                }
                Picker("Userdata flash mode", selection: $s.flashMode) {
                    Text("Delta (only changed blocks)").tag("delta")
                    Text("Full image").tag("full")
                }
                TextField("tools/bergamota-flash.py", text: $s.flashToolPath, prompt: Text("(found in the repo)"))
                HStack(spacing: 4) {
                    let ok = s.flashTool != nil
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? Color.leafText : Color.alertText)
                    Text(ok ? "found: \(s.flashTool ?? "")" : "missing: flashing through Bergamota fastboot is unavailable (ABL fallback is used)").font(.caption).foregroundStyle(Color.muted)
                }
                Text("Flashing goes through Bergamota fastboot (Enxerto writes UFS itself; needs python3). Userdata is sent as a delta against what the phone holds, boot and logo in full. Only userdata, boot and logo can be written.")
                    .font(.caption).foregroundStyle(Color.muted)
                Text("Only while the queue is armed and the next item is pending, after iOS has been up for 30 s, once per queue item (SSH: /usr/local/bin/sweetreboot fastboot). If the phone is not in fastboot 90 s later the item is marked \"needs manual fastboot\" and auto-rebooting pauses.")
                    .font(.caption).foregroundStyle(Color.muted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        }
        .page("Settings")
    }

    @ViewBuilder private func toolRow(_ name: String, _ path: Binding<String>, _ resolved: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(name, text: path, prompt: Text("auto"))
            HStack(spacing: 4) {
                Image(systemName: resolved != nil ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(resolved != nil ? Color.leafText : Color.alertText)
                Text(resolved ?? "not found").font(BFont.mono(11)).foregroundStyle(Color.muted)
            }
        }
    }

    private func chooseRepo() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = model.settings.repoURL
        if p.runModal() == .OK, let u = p.url { model.settings.repoPath = u.path; model.build.rescan() }
    }
}
