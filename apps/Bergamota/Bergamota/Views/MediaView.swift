import SwiftUI
import AppKit

struct MediaView: View {
    @Environment(AppModel.self) private var model
    @State private var toPhotos = true
    @State private var folder = PhoneTools.defaultDownloads
    @State private var targeted = false
    @State private var message: String?
    @State private var messageOK = true

    private var dest: String { toPhotos ? "photos" : folder }
    private var destValid: Bool { toPhotos || PhoneTools.validDest(folder) }

    var body: some View {
        let t = model.tools
        VStack(alignment: .leading, spacing: 16) {
            PageHeader("Media", subtitle: "Send pictures, videos and files to the phone over SSH.")
            if let r = t.disabledReason { Notice(text: r) }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Destination", selection: $toPhotos) {
                        Text("Camera Roll").tag(true)
                        Text("Phone folder").tag(false)
                    }.pickerStyle(.segmented)
                    if toPhotos {
                        Text("Images are converted to JPEG (sips) into DCIM/100APPLE via tools/sweet-push-photo.sh; videos are copied as VID_*. Other files go to \(PhoneTools.defaultDownloads).")
                            .font(.caption).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        TextField("Folder on the phone", text: $folder).textFieldStyle(.roundedBorder).font(BFont.mono(12))
                        if !destValid { Text("Absolute path under /private/var/mobile/, /var/mobile/, /private/var/tmp/ or /tmp/ (letters, digits, / _ . - only).").font(.caption).foregroundStyle(Color.alertText) }
                    }
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.arrow.down").font(.system(size: 30, weight: .light)).foregroundStyle(Color.text)
                        Text("Drop images, videos or files").font(BFont.display(18))
                        Button("Choose files...") { chooseFiles() }.buttonStyle(.borderedProminent).tint(.leaf).disabled(!t.iosUp || t.busy || !destValid)
                    }
                    .frame(maxWidth: .infinity).padding(28)
                    .dropZone(targeted)
                    .dropDestination(for: URL.self) { urls, _ in
                        let files = urls.filter(\.isFileURL).map(\.path)
                        guard !files.isEmpty, destValid else { return false }
                        send(files); return true
                    } isTargeted: { targeted = $0 }
                    if let n = t.uploadingCount { HStack { ProgressView().controlSize(.small); Text("Uploading \(n) file(s)...").font(BFont.mono(12)) } }
                    if let m = message { Notice(text: m, symbol: messageOK ? "checkmark.circle.fill" : "xmark.octagon.fill", color: messageOK ? .leafText : .alertText) }
                    Label("Photos may need a relaunch (or a reboot) to show new pictures.", systemImage: "info.circle").font(.caption).foregroundStyle(Color.muted)
                }
                .frame(width: 380)
                Panel(title: "Recent uploads", symbol: "tray.and.arrow.up") {
                    List(t.uploads) { u in
                        HStack(spacing: 10) {
                            Image(systemName: u.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(u.ok ? Color.leafText : Color.alertText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.name).font(BFont.mono(12, 600)).foregroundStyle(Color.text)
                                Text(u.message).font(.caption).foregroundStyle(Color.muted).lineLimit(2)
                            }
                            Spacer()
                            Text(u.date.formatted(date: .omitted, time: .standard)).font(BFont.mono(11)).foregroundStyle(Color.muted)
                        }
                        .listRowSeparatorTint(Color.rule)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .overlay { if t.uploads.isEmpty { EmptyStage(title: "No uploads yet", text: "Files you send appear here with their result.", symbol: "tray.and.arrow.up") } }
                }
            }
        }
        .padding(28)
        .page("Media")
    }

    private func send(_ files: [String]) {
        let d = dest
        Task { let r = await model.tools.upload(files, dest: d); messageOK = r.0; message = r.1 }
    }
    private func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { send(p.urls.map(\.path)) }
    }
}
