import SwiftUI
import AppKit

private struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ControlPlaneView: View {
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?
    @State private var tagFilter: Set<LogTag> = []
    @State private var confirmSend = false
    @State private var showFlash = false
    @State private var actionMessage: String?
    @AppStorage("cpScreen") private var savedScreen = ""
    @AppStorage("cpFullScreen") private var wantFullScreen = false

    private let bg = Color.ink
    /// Layout scale from the window size: 1.0 at 1280x880 pt; an iPad as a Sidecar display (1180x820 or
    /// 1366x1024) or a small window shrinks everything proportionally instead of clipping, big displays grow it.
    @State private var s: CGFloat = 1
    private static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return max(0.55, min(1.6, min(size.width / 1280, size.height / 960)))
    }

    var body: some View {
        let m = model.monitor, q = model.queue
        // Rows take their natural height with equal-height cards; the log takes whatever is left.
        VStack(spacing: 18 * s) {
            ActivityBannerView(big: true, scale: s)
            // one status line: phone, battery, last boot, each a value set inline with its name
            CPTile(s: s) {
                HStack(alignment: .firstTextBaseline, spacing: 34 * s) {
                    tile("Phone", caps(m.state.title), sub: "since \(m.stateSince.formatted(date: .omitted, time: .shortened))", color: Self.onInk(m.state))
                    batteryTile
                    lastBootTile
                    Spacer(minLength: 0)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            MetricsStrip(s: s)
            HStack(spacing: 18 * s) {
                queueCard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ciCard.frame(width: 440 * s).frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            logCard.frame(maxHeight: .infinity)
        }
        .padding(24 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom) { controls.padding(.horizontal, 24 * s).padding(.vertical, 12 * s).frame(maxWidth: .infinity).background(bg) }
        .background(bg)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { s = Self.scale(for: g.size) }
                .onChange(of: g.size) { _, n in s = Self.scale(for: n) }
        })
        .preferredColorScheme(.dark)
        .background(WindowAccessor { w in
            guard window == nil else { return }
            window = w
            w.setFrameAutosaveName("BergamotaControlPlane")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { applySavedPlacement() }
        })
        .confirmationDialog("Send the next image now?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send fastboot boot now", role: .destructive) { Task { actionMessage = await q.sendNow() } }
        } message: {
            Text("If the last boot left ABL hung, sending again can hang it further. Press only after re-entering fastboot (hold Power + Volume Down).")
        }
        .sheet(isPresented: $showFlash) { FlashPickerSheet() }
        .task { if model.ci.runs.isEmpty { await model.ci.refresh() }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 120_000_000_000); await model.ci.refresh() } }
    }

    // MARK: tiles

    /// The state's colour on the ink.
    static func onInk(_ st: PhoneState) -> Color {
        switch st {
        case .ios, .bergamotaFastboot: .lime
        case .fastboot, .iosBooting: .amber
        case .recovery, .android: .paper
        case .offline, .unknown: .consoleMuted
        }
    }

    private func tile(_ title: String, _ value: String, sub: String = "", color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * s) {
            CPLabel(text: title, s: s)
            Text(value).font(BFont.display(28 * s)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            if !sub.isEmpty { Text(sub).font(BFont.mono(13 * s)).foregroundStyle(Color.consoleMuted).lineLimit(1).truncationMode(.middle) }
        }
    }

    private var batteryTile: some View {
        let i = model.monitor.state == .ios ? model.monitor.info : nil
        let p = i?.batteryPercent
        return tile("Battery", p.map { "\($0)%" } ?? "--", sub: i.map { ($0.isCharging == true ? "charging" : "on battery") + ($0.powerSource.map { " | \($0)" } ?? "") } ?? "iOS not up",
                    color: (p ?? 100) < 20 ? .alertOnInk : (p == nil ? .consoleMuted : .lime))
    }

    private var lastBootTile: some View {
        let s = model.lastSent, f = model.lastFailed
        let latest = [s, f].compactMap { $0 }.max { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
        guard let it = latest, let at = it.sentAt else { return tile("Last boot", "none", color: .consoleMuted) }
        let ok = it.status == .sent
        return tile("Last boot", ok ? "sent" : "FAILED", sub: "\(it.name)  \(at.formatted(date: .omitted, time: .standard))", color: ok ? .lime : .alertOnInk)
    }

    // MARK: queue

    private var queueCard: some View {
        let q = model.queue
        return CPTile(s: s) {
            HStack(spacing: 10 * s) {
                CPLabel(text: "Queue", s: s)
                Pill(text: q.armed ? "armed" : "stopped", tone: q.armed ? .amber : Tone(fill: .consoleLine, on: .paper), size: 12 * s)
                Spacer()
                if let first = q.pending.first, model.monitor.state.isFastboot, q.sending == nil, !q.flashing {
                    Button("Send now: \(first.name)") { confirmSend = true }.buttonStyle(CPButtonStyle(fill: .amber, fg: .ink, s: s))
                }
            }
            if q.items.isEmpty { Text("empty").font(BFont.mono(20 * s)).foregroundStyle(Color.consoleMuted) }
            ForEach(q.items.suffix(6)) { it in
                HStack(spacing: 10 * s) {
                    Image(systemName: queueStatusSymbol(it.status)).foregroundStyle(it.status == .sent ? Color.lime : it.status == .failed ? Color.alertOnInk : it.status == .sending ? Color.amber : Color.consoleMuted)
                    Text(it.name).font(BFont.mono(19 * s, 600)).foregroundStyle(Color.paper).lineLimit(1).truncationMode(.middle)
                    if q.largeWarns(it) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.amber).help(BootQueue.largeWarning) }
                    Spacer()
                    if let t = it.sentAt { Text(t.formatted(date: .omitted, time: .standard)).font(BFont.mono(14 * s)).foregroundStyle(Color.consoleMuted) }
                }
            }
            Text(q.statusText).font(.system(size: 13 * s)).foregroundStyle(Color.consoleMuted).lineLimit(2)
        }
    }

    // MARK: CI

    private var ciCard: some View {
        CPTile(s: s) {
            CPLabel(text: "CI  xnu.yml", s: s)
            ForEach(CIModel.branches, id: \.self) { b in
                let run = model.ci.runs.first { $0.headBranch == b }
                HStack(spacing: 10 * s) {
                    Image(systemName: ciIcon(run)).foregroundStyle(ciColor(run)).font(.system(size: 22 * s))
                    Text(b).font(BFont.mono(19 * s, 600)).foregroundStyle(Color.paper)
                    Spacer()
                    if let r = run {
                        Text(r.shortSha).font(BFont.mono(14 * s)).foregroundStyle(Color.consoleMuted)
                        Text(r.createdAt.formatted(.relative(presentation: .numeric))).font(.system(size: 14 * s)).foregroundStyle(Color.consoleMuted)
                    } else { Text("--").foregroundStyle(Color.consoleMuted) }
                }
            }
            if let e = model.ci.error { Text(e).font(.caption).foregroundStyle(Color.amber).lineLimit(2) }
        }
    }
    private func ciIcon(_ r: CIRun?) -> String {
        guard let r else { return "questionmark.circle" }
        if !r.isDone { return "circle.dotted" }
        return r.conclusion == "success" ? "checkmark.circle.fill" : (r.conclusion == "cancelled" ? "slash.circle" : "xmark.circle.fill")
    }
    private func ciColor(_ r: CIRun?) -> Color {
        guard let r else { return .consoleMuted }
        if !r.isDone { return .amber }
        return r.conclusion == "success" ? .lime : (r.conclusion == "cancelled" ? .consoleMuted : .alertOnInk)
    }

    // MARK: log

    private var logCard: some View {
        CPTile(s: s) {
            HStack(spacing: 8 * s) {
                CPLabel(text: "Live log", s: s)
                ForEach(LogTag.allCases) { tag in
                    let on = tagFilter.contains(tag)
                    Button { if on { tagFilter.remove(tag) } else { tagFilter.insert(tag) } } label: {
                        Text(tag.rawValue).font(BFont.mono(11 * s, 800)).padding(.horizontal, 8 * s).padding(.vertical, 3 * s)
                            .background(on ? tagColor(tag) : Color.consoleLine, in: Capsule()).foregroundStyle(on ? Color.ink : Color.paper)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("\(model.logs.linesPerSecond) lines/s").font(BFont.mono(13 * s)).foregroundStyle(Color.consoleMuted).monospacedDigit()
            }
            GeometryReader { geo in
                let fit = max(1, Int(geo.size.height / (19 * s)))
                let lines = model.logs.totalReceived >= 0 ? model.logs.tail(fit, tags: tagFilter) : []
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { l in
                        Text(l.text.isEmpty ? " " : l.text).font(BFont.mono(14.5 * s)).lineLimit(1)
                            .foregroundStyle(l.tags != 0 ? lineColor(l.tags) : Color.paper.opacity(0.88))
                    }
                    if lines.isEmpty { Text(model.logs.listening ? "waiting for kernel log on udp/5140..." : "log listener stopped").font(BFont.mono(14 * s)).foregroundStyle(Color.consoleMuted) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 4 * 19 * s)
        }
    }

    // MARK: controls

    private var controls: some View {
        let q = model.queue, m = model.monitor
        return HStack(spacing: 14) {
            if let reboot = model.hooks.rebootToFastboot, [.ios, .recovery, .android].contains(m.state) {
                Button { Task { actionMessage = await reboot() } } label: { Label("Reboot to ABL fastboot", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(CPButtonStyle(fill: .amber, fg: .ink, s: s))
            }
            if let reboot = model.hooks.rebootToBergamota, m.state == .ios {
                Button { Task { actionMessage = await reboot() } } label: { Label("Reboot to Bergamota fastboot", systemImage: "leaf.circle.fill") }
                    .buttonStyle(CPButtonStyle(fill: .lime, fg: .ink, s: s))
            }
            Button { confirmSend = true } label: { Label("Send now", systemImage: "paperplane.fill") }
                .buttonStyle(CPButtonStyle(fill: .amber, fg: .ink, s: s)).disabled(!m.state.isFastboot || q.pending.isEmpty || q.sending != nil || q.flashing)
            if m.state == .fastboot {
                Button { Task { actionMessage = await model.tools.enterBergamota().1 } } label: { Label("Enter Bergamota fastboot", systemImage: "leaf.circle.fill") }
                    .buttonStyle(CPButtonStyle(fill: .lime, fg: .ink, s: s)).disabled(model.tools.enteringBergamota || q.sending != nil || q.flashing)
                Button { showFlash = true } label: { Label("Flash userdata", systemImage: "externaldrive.fill.badge.exclamationmark") }
                    .buttonStyle(CPButtonStyle(fill: .alert, fg: .paper, s: s)).disabled(q.sending != nil || q.flashing)
            }
            Button { q.disarm() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(CPButtonStyle(fill: .alert, fg: .paper, s: s)).disabled(!q.armed)
            if let a = actionMessage { Text(a).font(BFont.mono(13)).foregroundStyle(Color.consoleMuted).lineLimit(1) }
            Spacer()
            Menu {
                ForEach(NSScreen.screens, id: \.localizedName) { s in
                    Button("Move to \(s.localizedName)") { place(on: s, full: wantFullScreen) }
                }
                Divider()
                Toggle("Full screen on that display", isOn: Binding(get: { wantFullScreen }, set: { wantFullScreen = $0; applySavedPlacement(force: true) }))
            } label: { Label("Display", systemImage: "display") }
            .menuStyle(.button).fixedSize()
            Button { window?.toggleFullScreen(nil); wantFullScreen = !(window?.styleMask.contains(.fullScreen) ?? false) } label: {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(CPButtonStyle(fill: .consoleLine, fg: .paper, s: s))
        }
        .controlSize(.large)
    }

    // MARK: placement

    private func screen(named n: String) -> NSScreen? { NSScreen.screens.first { $0.localizedName == n } }

    private func place(on s: NSScreen, full: Bool) {
        guard let w = window else { return }
        savedScreen = s.localizedName
        wantFullScreen = full
        let isFull = w.styleMask.contains(.fullScreen)
        func go() {
            let f = s.visibleFrame.insetBy(dx: 40, dy: 40)
            w.setFrame(f, display: true, animate: false)
            if full && !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        }
        if isFull { w.toggleFullScreen(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { go() } } else { go() }
    }

    private func applySavedPlacement(force: Bool = false) {
        guard let w = window else { return }
        if let s = screen(named: savedScreen) {
            if force || w.screen != s { place(on: s, full: wantFullScreen) }
            else if wantFullScreen && !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        } else if wantFullScreen && !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
    }
}

/// Control Plane buttons: fixed fills that keep their colour when the window is not key (it usually sits on another
/// display, unfocused, where the system's tinted styles turn grey).
struct CPButtonStyle: ButtonStyle {
    var fill: Color
    var fg: Color
    var s: CGFloat
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14 * s, weight: .semibold))
            .padding(.horizontal, 14 * s).padding(.vertical, 8 * s)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9 * s))
            .foregroundStyle(fg)
            .opacity(enabled ? 1 : 0.35)
    }
}
