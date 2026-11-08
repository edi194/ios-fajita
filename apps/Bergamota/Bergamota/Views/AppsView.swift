import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppsView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var message: String?
    @State private var messageOK = true
    @State private var confirmRemove: InstalledApp?

    var body: some View {
        let t = model.tools
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader("Apps", subtitle: "Sideload decrypted .ipa files over SSH: tools/sweet-install-ipa.sh re-signs ad hoc, copies to /Applications and registers.")
                if let r = t.disabledReason { Notice(text: r) }
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 12) {
                        VStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 30, weight: .light)).foregroundStyle(Color.text)
                            Text("Drop an .ipa here").font(BFont.display(18))
                            Text("Decrypted iOS 16 arm64 only.").font(.caption).foregroundStyle(Color.muted)
                            Button("Choose IPA...") { chooseIPA() }.buttonStyle(.borderedProminent).tint(.leaf).disabled(!t.iosUp || t.busy)
                        }
                        .frame(maxWidth: .infinity).padding(24)
                        .dropZone(targeted)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let u = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { show(false, "Not an .ipa"); return false }
                            install(u.path); return true
                        } isTargeted: { targeted = $0 }
                        if let m = message { Notice(text: m, symbol: messageOK ? "checkmark.circle.fill" : "xmark.octagon.fill", color: messageOK ? .leafText : .alertText) }
                        if let n = t.installing { HStack { ProgressView().controlSize(.small); Text(n).font(BFont.mono(12)) } }
                    }
                    .frame(width: 340)
                    Panel(title: "Installed in /Applications", symbol: "square.grid.3x3") {
                        HStack {
                            Text("\(t.installed.count) apps").font(BFont.mono(11)).foregroundStyle(Color.muted)
                            Spacer()
                            if t.listing { ProgressView().controlSize(.small) }
                            Button { Task { await t.refreshInstalled() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!t.iosUp || t.listing)
                        }
                        if let e = t.listError, t.installed.isEmpty { Notice(text: e) }
                        List(t.installed) { app in
                            HStack(spacing: 10) {
                                Image(systemName: app.ours ? "person.crop.square.fill" : "apple.logo").foregroundStyle(app.ours ? Color.leafText : Color.muted)
                                Text(app.name).foregroundStyle(Color.text)
                                if app.ours { Pill(text: app.recorded ? "sideloaded" : "third-party?", tone: .leaf, size: 9) }
                                else { Text("system").font(BFont.mono(10.5)).foregroundStyle(Color.muted) }
                                Spacer()
                                if app.ours { Button("Uninstall") { confirmRemove = app }.controlSize(.small).disabled(!t.iosUp || t.busy) }
                            }
                            .listRowSeparatorTint(Color.rule)
                        }
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 160, maxHeight: 360)
                        .overlay { if t.installed.isEmpty && !t.listing { EmptyStage(title: "No list yet", text: "Refresh once iOS is up to read /Applications over SSH.", symbol: "square.grid.3x3") } }
                    }
                }
            }
            .padding(28)
            if !t.output.isEmpty { ConsolePane(text: t.output, placeholder: "").frame(height: 180) }
        }
        .page("Apps")
        .task { if model.tools.iosUp && model.tools.installed.isEmpty { await model.tools.refreshInstalled() } }
        .confirmationDialog("Uninstall \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Uninstall", role: .destructive) { if let a = confirmRemove { Task { let r = await t.uninstall(a); show(r.0, r.1) } } }
        }
    }

    private func show(_ ok: Bool, _ m: String) { messageOK = ok; message = m }
    private func install(_ path: String) { Task { let r = await model.tools.installIPA(path); show(r.0, r.1) } }
    private func chooseIPA() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        if p.runModal() == .OK, let u = p.url { install(u.path) }
    }
}
