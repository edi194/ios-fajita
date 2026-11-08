import SwiftUI

struct CIView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false

    var body: some View {
        let ci = model.ci
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "CI", subtitle: "xnu.yml on " + CIModel.branches.joined(separator: ", ") + (ci.lastRefresh.map { ", updated " + $0.formatted(date: .omitted, time: .standard) } ?? "")) {
                HStack(spacing: 8) {
                    if ci.loading { ProgressView().controlSize(.small) }
                    Button { Task { await ci.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(ci.loading)
                }
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 14)
            if let e = ci.error { Notice(text: e).padding(.horizontal, 28).padding(.bottom, 10) }
            List(ci.runs) { run in
                HStack(spacing: 14) {
                    statusIcon(run).font(.system(size: 15)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Text(run.headBranch).font(BFont.mono(13, 700)).foregroundStyle(Color.text)
                            Text(run.shortSha).font(BFont.mono(12)).foregroundStyle(Color.muted)
                        }
                        Text(run.displayTitle).font(.callout).foregroundStyle(Color.muted).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(run.createdAt.formatted(.relative(presentation: .named))).font(.callout).foregroundStyle(Color.text)
                        Text(run.duration.map { formatUptime($0) } ?? "-").font(BFont.mono(11)).foregroundStyle(Color.muted)
                    }
                    downloadControl(run)
                    if let u = run.url, let url = URL(string: u) { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open on GitHub") }
                }
                .padding(.vertical, 5)
                .listRowSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .overlay { if ci.runs.isEmpty && !ci.loading { EmptyStage(title: "No runs loaded", text: "Refresh runs gh run list for xnu.yml (needs gh auth login).", symbol: "hammer") } }
            DisclosureGroup(isExpanded: $showLog) {
                ConsolePane(text: ci.downloadLog, placeholder: "Kernel downloads print here.").frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 10))
            } label: { Label12(text: "Download log") }
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .page("CI")
        .task { if model.ci.runs.isEmpty { await model.ci.refresh() } }
    }

    @ViewBuilder private func statusIcon(_ r: CIRun) -> some View {
        if !r.isDone { Image(systemName: "circle.dotted").foregroundStyle(Color.amberText).symbolEffect(.pulse) }
        else if r.conclusion == "success" { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.leafText) }
        else if r.conclusion == "cancelled" || r.conclusion == "skipped" { Image(systemName: "slash.circle").foregroundStyle(Color.muted) }
        else { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.alertText) }
    }

    @ViewBuilder private func downloadControl(_ r: CIRun) -> some View {
        let ci = model.ci
        switch ci.downloads[r.id] {
        case .running: ProgressView().controlSize(.small).frame(width: 156)
        case .done(let d): Label("Saved", systemImage: "checkmark").foregroundStyle(Color.leafText).help(d).frame(width: 156)
        case .failed(let e): Button("Retry download") { Task { await ci.downloadKernel(r); model.build.rescan() } }.help(e).foregroundStyle(Color.alertText).frame(width: 156)
        case nil:
            if ci.isDownloaded(r) { Label("Downloaded", systemImage: "checkmark.circle").foregroundStyle(Color.muted).frame(width: 156) }
            else {
                Button { Task { await ci.downloadKernel(r); model.build.rescan() } } label: { Label("Download kernel", systemImage: "arrow.down.circle") }
                    .disabled(r.conclusion != "success").frame(width: 156)
            }
        }
    }
}
