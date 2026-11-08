import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let flashSizeFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()

/// What the confirmation sheet will do once `userdata` is typed.
enum FlashMode: Identifiable {
    case now
    case queue(boot: String)
    var id: String { switch self { case .now: "now"; case .queue(let b): "queue:" + b } }
}

struct FlashRequest: Identifiable {
    var info: UserdataFlash.Info
    var mode: FlashMode
    var id: String { info.path + mode.id }
}

/// Image selection (path field, file picker, drop, presets) with size/name validation. Never asks for a partition.
struct FlashImagePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var path: String
    @State private var targeted = false

    private var presets: [UserdataFlash.Info] {
        var out: [UserdataFlash.Info] = [], seen = Set<String>()
        for dir in ["research/ipsw-x", ""] {
            let d = model.settings.repoFile(dir)
            for f in ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).sorted() where f.hasSuffix(".simg") || f.hasSuffix(".img") {
                if case .success(let i) = UserdataFlash.validate(d + "/" + f), seen.insert(i.path).inserted { out.append(i) }
            }
        }
        return out
    }

    var validation: Result<UserdataFlash.Info, UserdataFlashError>? {
        path.trimmingCharacters(in: .whitespaces).isEmpty ? nil : UserdataFlash.validate(path.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Image path (.simg or .img)", text: $path).textFieldStyle(.roundedBorder).font(BFont.mono(12))
                Button("Choose...") {
                    let p = NSOpenPanel()
                    p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
                    if p.runModal() == .OK, let u = p.url { path = u.path }
                }
                Menu("Presets") {
                    let ps = presets
                    if ps.isEmpty { Text("none found") }
                    ForEach(ps, id: \.path) { i in Button("\(i.name)  (\(flashSizeFmt.string(fromByteCount: i.size)))") { path = i.path } }
                }
            }
            Text("Drop a .simg / .img here").foregroundStyle(Color.muted).frame(maxWidth: .infinity).frame(height: 40).dropZone(targeted)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in path = u.path } } }
                    return true
                }
            switch validation {
            case .none: EmptyView()
            case .some(.success(let i)):
                Label("\(i.name)  ·  \(flashSizeFmt.string(fromByteCount: i.size)) (\(i.size) bytes)", systemImage: "checkmark.circle").foregroundStyle(Color.leafText).font(.callout)
            case .some(.failure(let e)):
                Label(e.message, systemImage: "xmark.octagon.fill").foregroundStyle(Color.alertText).font(.callout)
            }
        }
    }
}

/// Confirmation: replaces the iOS install; shows name, size, SHA-256; the Flash button needs the word `userdata`.
struct FlashConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let req: FlashRequest
    @State private var typed = ""
    @State private var sha: String?
    @State private var result: String?
    @State private var via: UserdataFlash.Via?
    @State private var diffMode: UserdataFlash.Mode?

    private var isNow: Bool { if case .now = req.mode { return true }; return false }

    var body: some View {
        let q = model.queue, i = req.info
        let ready = typed == UserdataFlash.confirmWord
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(isNow ? "Flash \(i.partition)" : "Queue: flash \(i.partition)").font(BFont.display(26)) } icon: { Image(systemName: "exclamationmark.triangle.fill") }.foregroundStyle(Color.alertText)
            Text("This ERASES and REPLACES the iOS install on the phone: the whole userdata partition is overwritten with this image. It cannot be undone.").fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { Text("File").foregroundStyle(Color.muted); Text(i.name).bold() }
                GridRow { Text("Path").foregroundStyle(Color.muted); Text(i.path).font(BFont.mono(11.5)).textSelection(.enabled) }
                GridRow { Text("Size").foregroundStyle(Color.muted); Text("\(flashSizeFmt.string(fromByteCount: i.size)) (\(i.size) bytes)") }
                GridRow { Text("SHA-256").foregroundStyle(Color.muted)
                    if let sha { Text(sha).font(BFont.mono(11.5)).textSelection(.enabled) }
                    else { HStack { ProgressView().controlSize(.small); Text("computing...") } } }
                if case .queue(let b) = req.mode, !b.isEmpty {
                    GridRow { Text("Then").foregroundStyle(Color.muted); Text("fastboot boot \((b as NSString).lastPathComponent)") }
                }
                GridRow { Text("Command").foregroundStyle(Color.muted)
                    Text((via ?? model.settings.flashViaValue) == .abl ? "fastboot -s <serial> -S 512M flash \(i.partition) <file>"
                         : "python3 tools/bergamota-flash.py flash \(i.partition) <file> \(i.partition == "userdata" && (diffMode ?? model.settings.flashModeValue) == .delta ? "--delta" : "--full")")
                        .font(BFont.mono(11.5)) }
            }
            HStack(spacing: 16) {
                Picker("Route", selection: Binding(get: { via ?? model.settings.flashViaValue }, set: { via = $0 })) {
                    Text("Bergamota fastboot (ABL fallback)").tag(UserdataFlash.Via.auto)
                    Text("ABL fastboot only").tag(UserdataFlash.Via.abl)
                }.frame(maxWidth: 300)
                if i.partition == "userdata" {
                    Picker("Mode", selection: Binding(get: { diffMode ?? model.settings.flashModeValue }, set: { diffMode = $0 })) {
                        Text("Delta").tag(UserdataFlash.Mode.delta)
                        Text("Full").tag(UserdataFlash.Mode.full)
                    }.frame(maxWidth: 160)
                }
            }
            Text("Bergamota fastboot writes the phone's UFS itself. Delta compares the phone's real contents block by block and sends only what differs. Only userdata, boot and logo can be written.")
                .font(.caption).foregroundStyle(Color.muted)
            Text("Type \(UserdataFlash.confirmWord) to enable the button:").foregroundStyle(Color.muted)
            TextField(UserdataFlash.confirmWord, text: $typed).textFieldStyle(.roundedBorder).frame(width: 220)
            if isNow, !model.monitor.state.isFastboot { Text("The phone is not in fastboot.").foregroundStyle(Color.amberText) }
            if let r = result { Text(r).foregroundStyle(Color.muted) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNow ? "Flash userdata" : "Add to queue") {
                    if case .queue(let b) = req.mode {
                        q.addFlash(userdata: i, bootPath: b, via: via, mode: diffMode)
                        dismiss()
                    } else {
                        dismiss()
                        Task { _ = await q.flashUserdataNow(i, via: via, mode: diffMode) }
                    }
                }
                .buttonStyle(.borderedProminent).tint(.alert)
                .disabled(!ready || (isNow && (!model.monitor.state.isFastboot || q.sending != nil || q.flashing || q.preparingFlash)))
            }
        }
        .padding(20).frame(width: 600)
        .task { sha = await UserdataFlash.sha256(i.path) }
    }
}

/// Boot page "Flash" tab.
struct FlashPane: View {
    @Environment(AppModel.self) private var model
    @State private var path = ""
    @State private var thenBoot = ""
    @State private var request: FlashRequest?

    var body: some View {
        let q = model.queue, f = model.flasher
        let inFastboot = model.monitor.state.isFastboot
        let info: UserdataFlash.Info? = { if case .success(let i) = UserdataFlash.validate(path.trimmingCharacters(in: .whitespaces)) { return i }; return nil }()
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Flash userdata (the iOS root image)") {
                    Label("Flashes userdata through Bergamota fastboot (delta by default; ABL fastboot is the fallback). It replaces the iOS install on the phone.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.amberText).font(.callout)
                    FlashImagePicker(path: $path)
                    HStack {
                        Button { if let info { request = FlashRequest(info: info, mode: .now) } } label: { Label("Flash userdata...", systemImage: "externaldrive.fill.badge.exclamationmark") }
                            .buttonStyle(.borderedProminent).tint(.alert)
                            .disabled(info == nil || !inFastboot || q.sending != nil || f.active)
                        if !inFastboot { Text("Only available while the phone is in fastboot.").font(.caption).foregroundStyle(Color.muted) }
                    }
                }
                Section("Queue: flash, then boot (same fastboot session)") {
                    Picker("Then boot", selection: $thenBoot) {
                        Text("(no boot, flash only)").tag("")
                        ForEach(model.build.images) { Text($0.name).tag($0.path) }
                    }
                    Button("Add to queue...") { if let info { request = FlashRequest(info: info, mode: .queue(boot: thenBoot)) } }.disabled(info == nil || f.active)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).frame(maxHeight: 330)
            HStack {
                Label12(text: "Output")
                if f.active {
                    if f.route == .bergamota { ProgressView(value: f.fraction() ?? 0).frame(width: 160) }
                    else { ProgressView(value: f.total > 0 ? Double(f.current) : 0, total: Double(max(f.total, 1))).frame(width: 160) }
                    Text(f.progressText).monospacedDigit()
                }
                else if let l = f.last { Pill(text: l.ok ? "flashed" : "failed", tone: l.ok ? .leaf : .alert) }
                Spacer()
            }.padding(.horizontal, 28).padding(.vertical, 10)
            ConsolePane(text: f.output, placeholder: "bergamota-flash.py (or fastboot flash) prints here.")
        }
        .sheet(item: $request) { FlashConfirmSheet(req: $0) }
    }
}

/// Control Plane: pick an image, then the same confirmation sheet.
struct FlashPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var request: FlashRequest?

    var body: some View {
        let info: UserdataFlash.Info? = { if case .success(let i) = UserdataFlash.validate(path.trimmingCharacters(in: .whitespaces)) { return i }; return nil }()
        VStack(alignment: .leading, spacing: 12) {
            Text("Flash userdata").font(BFont.display(26))
            Text("Replaces the iOS install on the phone. Only userdata, boot and logo can be written.").foregroundStyle(Color.muted)
            FlashImagePicker(path: $path)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue...") { if let info { request = FlashRequest(info: info, mode: .now) } }.buttonStyle(.borderedProminent).tint(.alert).disabled(info == nil)
            }
        }
        .padding(20).frame(width: 600)
        .sheet(item: $request, onDismiss: { dismiss() }) { FlashConfirmSheet(req: $0) }
    }
}
