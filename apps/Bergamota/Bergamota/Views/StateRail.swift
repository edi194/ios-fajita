import SwiftUI
import AppKit

/// The phone, beside every page (the main window's inspector column): the lime stage with the phone's state, what
/// the app is doing right now, Newton, and at his feet the ink console with the boot queue's next items.
struct StateRail: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSend = false
    @State private var note: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let b = model.activityBanner(now: ctx.date)
            let m = model.monitor
            VStack(spacing: 0) {
                header(b, m)
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 8)
                GeometryReader { g in figure(g.size) }
                    .frame(minHeight: 90)
                console
            }
            .background { HalftoneGround() }
        }
        .confirmationDialog("Send the next image now?", isPresented: $confirmSend, titleVisibility: .visible) {
            Button("Send fastboot boot now", role: .destructive) { Task { note = await model.queue.sendNow() } }
        } message: {
            Text("If the last boot left ABL hung, sending again can hang it further. Press only after re-entering fastboot (hold Power + Volume Down).")
        }
    }

    // MARK: the stage

    @ViewBuilder private func header(_ b: ActivityBanner, _ m: PhoneMonitor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // the phone's state as a pill, unless the activity line below already says it
                if !b.title.lowercased().contains(m.state.title.lowercased()) && !(m.state == .ios && b.title.hasPrefix("iOS")) {
                    Pill(text: m.state.title, tone: stateTone(m.state))
                }
                Spacer(minLength: 0)
                Image(systemName: b.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
            }
            Text(b.title)
                .font(BFont.display(52)).foregroundStyle(Color.ink)
                .lineLimit(3).minimumScaleFactor(0.45)
                .modifier(StateStep(key: b.title + "|" + m.state.rawValue))
            if !b.subtitle.isEmpty {
                Text(b.subtitle).font(BFont.mono(11.5, 500)).foregroundStyle(Color.ink)
                    .lineLimit(4).textSelection(.enabled)
            }
            if let p = b.progress {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.ink.opacity(0.16))
                        Capsule().fill(Color.ink).frame(width: max(8, g.size.width * min(max(p, 0), 1)))
                    }
                }
                .frame(height: 8)
            }
            Text(sinceLine(m)).font(BFont.mono(10.5, 700)).tracking(0.4).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func sinceLine(_ m: PhoneMonitor) -> String {
        var p = ["since " + m.stateSince.formatted(date: .omitted, time: .shortened)]
        if let s = m.fastbootSerial, m.state.isFastboot { p.append(s) }
        return p.joined(separator: "  ·  ")
    }

    /// Newton's head and shoulders standing on the console, his coat dissolving into it.
    private func figure(_ size: CGSize) -> some View {
        // as wide as the rail at least; in a tall rail he grows until his head and shoulders fill it (hair off both edges)
        let w = min(max(size.width * 1.08, size.height / 0.66 * 640 / 900), size.width * 1.7), imgH = w * 900 / 640
        let shown = imgH * 0.66                      // hair to shoulders
        let top = size.height - shown                // where his crown sits; < 0 crops the crown when space is short
        return ZStack(alignment: .top) {
            Image("Newton").resizable().interpolation(.high).frame(width: w, height: imgH)
                .offset(x: (size.width - w) / 2 + size.width * 0.04, y: max(top, -imgH * 0.12))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) { HalftoneDissolve().frame(height: 46) }
        .accessibilityHidden(true)
    }

    // MARK: the console

    private var console: some View {
        let q = model.queue, m = model.monitor
        let next = Array(q.pending.prefix(3))
        let canSend = !q.pending.isEmpty && m.state.isFastboot && q.sending == nil && !q.flashing
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label12(text: "Queue", color: .consoleMuted)
                Pill(text: q.armed ? "armed" : "stopped", tone: q.armed ? .amber : Tone(fill: Color.consoleLine, on: .paper), size: 9.5)
                Spacer(minLength: 0)
                if q.armed {
                    Button("Stop") { q.disarm() }.buttonStyle(CPButtonStyle(fill: .consoleLine, fg: .paper, s: 0.85))
                } else {
                    Button("Start") { q.arm() }.buttonStyle(CPButtonStyle(fill: .lime, fg: .ink, s: 0.85)).disabled(q.pending.isEmpty)
                }
            }
            if next.isEmpty {
                Text("Nothing queued").font(BFont.mono(11.5)).foregroundStyle(Color.consoleMuted)
            }
            ForEach(next) { it in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Image(systemName: queueStatusSymbol(it.status)).font(.system(size: 10)).foregroundStyle(Color.consoleMuted)
                        Text(it.hasBoot ? it.fileName : it.autoLabel).font(BFont.mono(11.5, 600)).foregroundStyle(Color.paper)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if it.flashesUserdata {
                        Text("writes \(it.flashTarget)").font(BFont.mono(10.5, 600)).foregroundStyle(Color.alertOnInk).padding(.leading, 17)
                    }
                }
            }
            if q.pending.count > next.count {
                Text("+ \(q.pending.count - next.count) more").font(BFont.mono(10.5)).foregroundStyle(Color.consoleMuted)
            }
            if canSend {
                Button { confirmSend = true } label: { Label("Send now", systemImage: "paperplane.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(CPButtonStyle(fill: .amber, fg: .ink, s: 0.95))
            }
            if let l = lastBoot { Text(l).font(BFont.mono(10.5)).foregroundStyle(Color.consoleMuted).lineLimit(1).truncationMode(.middle) }
            if let n = note { Text(n).font(BFont.mono(10.5)).foregroundStyle(Color.consoleMuted).lineLimit(2) }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ink)
        .environment(\.colorScheme, .dark)
    }

    private var lastBoot: String? {
        let latest = [model.lastSent, model.lastFailed].compactMap { $0 }.max { ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
        guard let it = latest, let at = it.sentAt else { return nil }
        return "last: \(it.status == .sent ? "sent" : "FAILED") \(at.formatted(date: .omitted, time: .shortened))  \(it.fileName)"
    }
}

/// The signature move: when the state changes, the word steps in over two frames (no eased fade), and an ink
/// underline stays under it until the window is next brought forward or the pointer passes over it, so a change
/// that happened while you were in the terminal is still marked when you look.
struct StateStep: ViewModifier {
    let key: String
    var mark: Color = .ink
    @State private var seen: String?
    @State private var dim = false
    @State private var unseen = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.18 : 1)
            .overlay(alignment: .bottomLeading) {
                if unseen { Rectangle().fill(mark).frame(width: 64, height: 4).offset(y: 7) }
            }
            .onHover { if $0 { unseen = false } }
            .onAppear { seen = key }
            .onChange(of: key) { _, new in
                guard seen != nil, seen != new else { seen = new; return }
                seen = new
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { dim = true; unseen = true }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    withTransaction(t) { dim = false }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                if NSApp.isActive, unseen { Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); unseen = false } }
            }
    }
}
