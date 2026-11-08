import SwiftUI

func formatUptime(_ t: TimeInterval) -> String {
    let s = Int(t), d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m \(s % 60)s"
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReboot = false
    @State private var confirmRebootBergamota = false
    @State private var confirmEnterBergamota = false
    @State private var rebootResult: (ok: Bool, text: String)?

    @ViewBuilder private var resultLabel: some View {
        if let r = rebootResult {
            Label(r.text, systemImage: r.ok ? "checkmark.circle" : "exclamationmark.triangle").font(.caption)
                .foregroundStyle(r.ok ? Color.leafText : Color.amberText).textSelection(.enabled)
        }
    }

    private var hint: String {
        switch model.monitor.state {
        case .unknown: "Probing the phone..."
        case .offline: "No device seen. Hold Power + Volume Down for fastboot, or plug the phone in."
        case .fastboot: "Phone is in ABL fastboot (serial \(model.monitor.fastbootSerial ?? "?")). Ready for `fastboot boot` and flash userdata."
        case .bergamotaFastboot: "Phone is in Bergamota fastboot (serial \(model.monitor.fastbootSerial ?? "?")). Ready for `fastboot boot` and flashing userdata/boot/logo (main flash route)."
        case .recovery: "OrangeFox / recovery over adb (\(model.monitor.adbSerial ?? "?"))."
        case .android: "Android is up over adb (\(model.monitor.adbSerial ?? "?"))."
        case .iosBooting:
            if !model.monitor.ifaceHasIP { "USB Ethernet is present but has no IP. Run tools/sweet-usbnet.sh (sudo) to assign 192.168.7.1." }
            else if model.monitor.noRoute { "USB Ethernet is up but connections fail with 'No route to host'. If the phone is up, allow Bergamota under System Settings > Privacy & Security > Local Network." }
            else { "USB Ethernet is up but SSH is not answering yet." }
        case .ios: "iOS is up: ping and SSH answer."
        }
    }

    var body: some View {
        let m = model.monitor
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Dashboard", subtitle: hint) {
                    if let l = m.lastPoll { Text("polled " + l.formatted(date: .omitted, time: .standard)).font(BFont.mono(11)).foregroundStyle(Color.muted) }
                }

                if m.macHidden {
                    Notice(text: "macOS is hiding MAC addresses from Bergamota (Local Network permission not granted). Allow it in System Settings > Privacy & Security > Local Network > Bergamota. Using subnet detection meanwhile.", symbol: "network.slash")
                }
                if m.noRoute {
                    Notice(text: "Local Network access may be denied: System Settings > Privacy & Security > Local Network > Bergamota.", symbol: "network.slash")
                }
                ForEach(m.toolWarnings, id: \.self) { Notice(text: $0) }

                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow(alignment: .top) {
                        Panel(title: "Detection", symbol: "dot.radiowaves.left.and.right") {
                            Row(k: "fastboot", v: m.fastbootSerial.map { $0 + " (" + (m.state == .bergamotaFastboot ? "Bergamota" : "ABL") + ")" } ?? "none", ok: m.fastbootSerial != nil)
                            Row(k: "adb", v: m.adbState.map { "\($0) (\(m.adbSerial ?? ""))" } ?? "none", ok: m.adbState != nil)
                            Row(k: "USB Ethernet", v: m.ifaceName.map { $0 + (m.ifaceUp ? " up" : " down") + (m.ifaceHasIP ? "" : ", no IP") + (m.ifaceInferred ? " (by subnet)" : "") } ?? "not found", ok: m.ifaceName != nil)
                            Row(k: "ping \(model.settings.phoneIP)", v: m.pingOK ? "reply" : "no reply", ok: m.pingOK)
                            Row(k: "TCP 22", v: m.sshOpen ? "open" : "closed", ok: m.sshOpen)
                        }
                        Panel(title: "Mac side", symbol: "laptopcomputer") {
                            Row(k: "IP forwarding", v: m.natForwarding.map { $0 == "1" ? "on (NAT shared)" : "off" } ?? "unknown", ok: m.natForwarding == "1")
                            Row(k: "Phone MAC", v: PhoneMonitor.usbMAC)
                            Row(k: "Log listener", v: model.logs.listening ? "udp/5140" : (model.logs.listenError ?? "stopped"), ok: model.logs.listening)
                            Text("Enable NAT with tools/sweet-mac-nat.sh (needs sudo).").font(.caption).foregroundStyle(Color.muted).padding(.top, 4)
                        }
                    }
                }

                if m.state == .fastboot || m.state == .bergamotaFastboot {
                    Panel(title: m.state == .fastboot ? "ABL fastboot" : "Bergamota fastboot", symbol: m.state.symbol) {
                        if m.state == .fastboot {
                            Text("Qualcomm ABL: `fastboot boot` and flash commands. \"Enter Bergamota fastboot\" boots Enxerto's own fastboot (1 GiB downloads, the main flash route; flashing enters it automatically).")
                                .font(.callout).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                Button { confirmEnterBergamota = true } label: { Label("Enter Bergamota fastboot", systemImage: "leaf.circle.fill") }
                                    .buttonStyle(.borderedProminent).tint(.leaf)
                                    .disabled(model.tools.enteringBergamota || model.queue.sending != nil || model.queue.flashing)
                                if model.tools.enteringBergamota { ProgressView().controlSize(.small) }
                                resultLabel
                            }
                        } else {
                            Text("Enxerto's fastboot (\(m.fastbootVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "version-bootloader bergamota-N")): `fastboot boot` up to 1 GiB and flash userdata/boot/logo (delta by default). ABL fastboot stays the fallback.")
                                .font(.callout).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Panel(title: "iOS device", symbol: "iphone") {
                    if m.state != .ios {
                        Text("Available when iOS is up.").foregroundStyle(Color.muted)
                    } else if let i = m.info {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(i.batteryPercent.map { "\($0)%" } ?? "--").font(BFont.display(44))
                                    .foregroundStyle((i.batteryPercent ?? 100) < 20 ? Color.alertText : Color.text)
                                Text("battery").font(BFont.mono(11)).foregroundStyle(Color.muted)
                            }
                            .frame(width: 130, alignment: .leading)
                            VStack(spacing: 6) {
                                Row(k: "Charging", v: i.isCharging.map { $0 ? "yes" : "no" } ?? "unknown")
                                Row(k: "Power source", v: i.powerSource ?? "unknown")
                                Row(k: "Uptime", v: i.uptime.map(formatUptime) ?? "unknown (phone has no sysctl)")
                                Row(k: "Seen up since", v: m.stateSince.formatted(date: .omitted, time: .standard) + " (" + formatUptime(Date().timeIntervalSince(m.stateSince)) + ")")
                                Row(k: "Kernel", v: i.uname)
                            }
                        }
                    } else if let e = m.infoError {
                        Notice(text: e)
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Querying over SSH...").foregroundStyle(Color.muted) }
                    }
                    if m.state == .ios, m.info != nil, let e = m.infoError { Text(e).font(.caption).foregroundStyle(Color.amberText) }
                    if m.state == .ios {
                        HStack(spacing: 10) {
                            Button("Refresh now") { Task { await m.refreshInfoIfNeeded(force: true) } }
                            Button { confirmRebootBergamota = true } label: { Label("Reboot to Bergamota fastboot", systemImage: "leaf.circle.fill") }
                                .buttonStyle(.borderedProminent).tint(.leaf)
                                .disabled(model.tools.rebooting != nil || model.tools.busy)
                            Button { confirmReboot = true } label: { Label("Reboot to ABL fastboot", systemImage: "bolt.horizontal.circle") }
                                .disabled(model.tools.rebooting != nil || model.tools.busy)
                            if let t = model.tools.rebooting { ProgressView().controlSize(.small); Text("rebooting to \(t)...").font(.caption).foregroundStyle(Color.muted) }
                            resultLabel
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .page("Dashboard")
        .confirmationDialog("Reboot the phone into Bergamota fastboot?", isPresented: $confirmRebootBergamota, titleVisibility: .visible) {
            Button("Reboot to Bergamota fastboot", role: .destructive) {
                Task { let r = await model.tools.rebootIOS(to: "bergamota"); rebootResult = (r.0, r.1) }
            }
        } message: {
            Text("Runs /usr/local/bin/sweetreboot bergamota over SSH. iOS is shut down immediately; needs kernel patch 0140, an Enxerto that handles the BERG reboot reason, and the updated tool on the phone (README).")
        }
        .confirmationDialog("Boot Bergamota fastboot from ABL?", isPresented: $confirmEnterBergamota, titleVisibility: .visible) {
            Button("Enter Bergamota fastboot", role: .destructive) {
                Task { let r = await model.tools.enterBergamota(); rebootResult = (r.0, r.1) }
            }
        } message: {
            Text("Runs fastboot -s <serial> boot \(model.settings.bergamotaImagePath)")
        }
        .confirmationDialog("Reboot the phone into fastboot?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot to ABL fastboot", role: .destructive) {
                Task { let r = await model.tools.rebootIOS(to: "fastboot"); rebootResult = (r.0, r.1) }
            }
        } message: {
            Text("Runs /usr/local/bin/sweetreboot fastboot over SSH. iOS is shut down immediately; needs kernel patch 0137 and the tool on the phone (README).")
        }
    }
}
