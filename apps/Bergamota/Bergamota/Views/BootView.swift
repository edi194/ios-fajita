import SwiftUI

private enum BootTab: String, CaseIterable, Identifiable {
    case queue = "Queue", images = "Images", build = "Build", flash = "Flash"
    var id: String { rawValue }
}

private let sizeFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()

struct BootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: BootTab = .queue

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Boot Queue", subtitle: "One fastboot boot per fastboot appearance, never retried. Flashes write only userdata, boot and logo.") {
                Picker("", selection: $tab) { ForEach(BootTab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 16)
            Rectangle().fill(Color.rule).frame(height: 1)
            switch tab {
            case .queue: QueuePane()
            case .images: ImagesPane(tab: $tab)
            case .build: BuildPane(tab: $tab)
            case .flash: FlashPane()
            }
        }
        .page("Boot Queue")
        .onAppear { model.build.rescan() }
    }
}

// MARK: queue

private struct QueuePane: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSend = false

    var body: some View {
        @Bindable var settings = model.settings
        let q = model.queue
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: q.armed ? "scope" : "pause.circle").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(q.armed ? Color.amberText : Color.muted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(q.armed ? "Armed" : "Stopped").font(BFont.display(22))
                        if settings.allowRemoteStart {
                            Label("remote control on", systemImage: "antenna.radiowaves.left.and.right").font(BFont.mono(10.5, 600)).foregroundStyle(Color.muted)
                        }
                    }
                    if let b = q.autoRebootBadge {
                        Label(b, systemImage: "arrow.triangle.2.circlepath").font(BFont.mono(10.5, 600)).foregroundStyle(b.contains("manual") ? Color.amberText : Color.muted)
                    }
                    Text(q.statusText).foregroundStyle(Color.muted)
                    if let a = q.autoStatusText, a != q.statusText { Text(a).font(.caption).foregroundStyle(Color.muted) }
                    if let n = q.note { Text(n).font(.caption).foregroundStyle(Color.amberText) }
                }
                Spacer()
                Pill(text: model.monitor.state.title, tone: stateTone(model.monitor.state))
                if q.armed { Button("Stop") { q.disarm() }.controlSize(.large) }
                else { Button("Start") { q.arm() }.buttonStyle(.borderedProminent).tint(.leaf).controlSize(.large).disabled(q.pending.isEmpty) }
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            Rectangle().fill(Color.rule).frame(height: 1)
            HStack {
                Toggle("If in OrangeFox, `adb reboot bootloader` first", isOn: $settings.rebootFromRecovery)
                Spacer()
                Button("Clear finished") { q.clearFinished() }.disabled(!q.items.contains { $0.status == .sent || $0.status == .failed })
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            Rectangle().fill(Color.rule).frame(height: 1)
            List {
                ForEach(q.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            statusIcon(item.status)
                            Text(item.name).font(BFont.mono(13, 600)).foregroundStyle(Color.text).lineLimit(1).truncationMode(.middle)
                            if item.flashesUserdata { Pill(text: "writes \(item.flashTarget)", tone: .alert, size: 9.5).help("flashes \(item.flashTarget) first") }
                            Spacer()
                            if let t = item.sentAt { Text(t.formatted(date: .omitted, time: .standard)).font(BFont.mono(11)).foregroundStyle(Color.muted) }
                            if item.status == .pending, item.id == q.pending.first?.id, model.monitor.state.isFastboot, q.sending == nil, !q.flashing {
                                Button("Send now") { confirmSend = true }.buttonStyle(.borderedProminent).controlSize(.small).tint(.amber).foregroundStyle(Color.ink)
                            }
                            if item.status == .pending {
                                Button { q.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                                Button { q.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                            }
                            if item.status != .sending { Button { q.remove(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
                        }
                        if item.flashesUserdata, item.name != item.autoLabel {
                            Label(item.autoLabel, systemImage: "externaldrive.fill").font(.caption).foregroundStyle(Color.alertText)
                        }
                        if item.needsManualFastboot {
                            Label("needs manual fastboot (hold Power + Volume Down)", systemImage: "hand.tap.fill").font(.caption).foregroundStyle(Color.amberText)
                        } else if item.autoRebootTried, item.status == .pending {
                            Label("auto-reboot to fastboot sent", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(Color.muted)
                        }
                        if q.largeWarns(item) {
                            Label("\(BootQueue.largeWarning) (\(sizeFmt.string(fromByteCount: item.size)))", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(Color.amberText)
                        }
                        if !item.output.isEmpty {
                            Text(item.output).font(BFont.mono(11)).foregroundStyle(Color.muted).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowSeparatorTint(Color.rule)
                }
            }
            .scrollContentBackground(.hidden)
            .confirmationDialog("Send the next image now?", isPresented: $confirmSend, titleVisibility: .visible) {
                Button("Send fastboot boot now", role: .destructive) { Task { _ = await q.sendNow() } }
            } message: {
                Text("If the last boot left ABL hung, sending again can hang it further. Press only after re-entering fastboot (hold Power + Volume Down).")
            }
            .overlay { if q.items.isEmpty { EmptyStage(title: "Queue is empty", text: "Add images from the Images or Build tab, or queue them from an agent with scripts/bergamota enqueue.", symbol: "tray") } }
        }
    }

    @ViewBuilder private func statusIcon(_ s: QueueItem.Status) -> some View {
        switch s {
        case .sending: ProgressView().controlSize(.small)
        default: Image(systemName: queueStatusSymbol(s)).foregroundStyle(queueStatusColor(s))
        }
    }
}

// MARK: images

private struct ImagesPane: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: BootTab

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.settings.bootDir)/out/*.img  ·  \(model.build.images.count) images").font(BFont.mono(12)).foregroundStyle(Color.muted)
                Spacer()
                Button { model.build.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }.padding(.horizontal, 28).padding(.vertical, 10)
            Table(model.build.images) {
                TableColumn("Name") { Text($0.name).font(BFont.mono(12)) }
                TableColumn("Size") { img in
                    HStack(spacing: 4) {
                        Text(sizeFmt.string(fromByteCount: img.size)).font(BFont.mono(12))
                        if model.queue.largeWarns(img.size) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.amberText).help(BootQueue.largeWarning) }
                    }
                }.width(110)
                TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Color.muted) }.width(150)
                TableColumn("") { img in
                    Button("Add to queue") { model.queue.add(img.path); tab = .queue }.controlSize(.small)
                }.width(110)
            }
        }
    }
}

// MARK: build

private struct BuildPane: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: BootTab
    @State private var presetName = ""
    @State private var confirmOverwrite = false

    var body: some View {
        @Bindable var b = model.build
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Inputs") {
                    Picker("Kernel", selection: $b.kernelPath) {
                        if b.kernelPath.isEmpty { Text("(none found)").tag("") }
                        ForEach(b.kernels) { Text("\(b.kernelLabel($0))  \($0.date.formatted(date: .abbreviated, time: .shortened))").tag($0.path) }
                    }
                    Picker("ADT", selection: $b.adtPath) {
                        if b.adtPath.isEmpty { Text("(none found)").tag("") }
                        ForEach(b.adts) { Text($0.name).tag($0.path) }
                    }
                    TextField("Image name", text: $b.imageName, prompt: Text("e.g. 0131"))
                    if !b.imageName.isEmpty && !BuildModel.validName(b.imageName) {
                        Text("Use letters, digits, . _ - only.").font(.caption).foregroundStyle(Color.alertText)
                    }
                    if b.targetExists && !b.imageName.isEmpty {
                        Text("\(model.settings.bootImageBase)-\(b.imageName).img already exists and will be replaced.").font(.caption).foregroundStyle(Color.amberText)
                    }
                }
                Section("Cmdline") {
                    Picker("Preset", selection: Binding(get: { b.selectedPresetID }, set: { b.applyPreset($0) })) {
                        ForEach(b.presets) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextEditor(text: $b.cmdline).font(BFont.mono(11.5)).frame(height: 130)
                    HStack {
                        TextField("Save as preset", text: $presetName).textFieldStyle(.roundedBorder)
                        Button("Save") { b.saveCurrentAsPreset(named: presetName); presetName = "" }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Delete selected") { b.deleteSelectedPreset() }.disabled(b.selectedPresetID == nil)
                    }
                    Text(Presets.fileURL.path).font(BFont.mono(10.5)).foregroundStyle(Color.muted).textSelection(.enabled)
                }
                Section {
                    HStack {
                        Button {
                            if b.targetExists { confirmOverwrite = true } else { b.build() }
                        } label: { Label("Build image", systemImage: "hammer.fill") }
                            .buttonStyle(.borderedProminent).tint(.leaf).disabled(!b.canBuild)
                        if b.building { ProgressView().controlSize(.small) }
                        if let img = b.lastBuiltImage, model.queue.largeWarns(BootQueue.fileSize(img)) {
                            Label(BootQueue.largeWarning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.amberText)
                        }
                        if let r = b.lastResult { Text(r).foregroundStyle(b.lastBuiltImage != nil ? Color.leafText : Color.alertText) }
                        Spacer()
                        if let img = b.lastBuiltImage { Button("Add to queue") { model.queue.add(img); tab = .queue } }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(width: 460)
            ConsolePane(text: b.output, placeholder: "mkpayload.py and build.sh print here.")
        }
        .confirmationDialog("Replace \(model.settings.bootImageBase)-\(b.imageName).img?", isPresented: $confirmOverwrite) {
            Button("Replace and build", role: .destructive) { b.build() }
        }
    }
}
