import SwiftUI
import AppKit

struct LogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var logs = model.logs
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Live Log", subtitle: "The phone's kernel console on udp/5140.") {
                    HStack(spacing: 8) {
                        Toggle(isOn: $logs.follow) { Label("Follow", systemImage: "arrow.down.to.line") }.toggleStyle(.button)
                        Toggle(isOn: $logs.paused) { Label("Pause", systemImage: "pause") }.toggleStyle(.button)
                        Button { logs.clear() } label: { Label("Clear", systemImage: "trash") }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Search", text: $logs.searchText).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    ForEach(LogTag.allCases) { tag in
                        let on = logs.activeTags.contains(tag)
                        Button {
                            if on { logs.activeTags.remove(tag) } else { logs.activeTags.insert(tag) }
                        } label: {
                            Text(tag.rawValue).font(BFont.mono(10.5, 800)).padding(.horizontal, 9).padding(.vertical, 4)
                                .background(on ? tagColor(tag) : Color.rule, in: Capsule())
                                .foregroundStyle(on ? Color.ink : Color.text)
                        }
                        .buttonStyle(.plain)
                        .help(on ? "Hide \(tag.rawValue) filter" : "Show only \(tag.rawValue) lines")
                    }
                    if !logs.activeTags.isEmpty { Button("All") { logs.activeTags = [] }.buttonStyle(.link) }
                    Spacer()
                    Toggle(isOn: Binding(get: { logs.recording }, set: { $0 ? logs.startRecording() : logs.userStopRecording() })) {
                        Label("Record to logs/", systemImage: "record.circle")
                    }.toggleStyle(.button).tint(.alert)
                    Button { logs.saveBuffer() } label: { Label("Save buffer", systemImage: "square.and.arrow.down") }
                    Button { copyVisible() } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 16)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logs.visible) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(BFont.mono(11.5))
                                .foregroundStyle(line.tags == 0 ? Color.paper.opacity(0.9) : lineColor(line.tags))
                                .fixedSize()
                                .id(line.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.ink)
                .overlay {
                    if logs.visible.isEmpty {
                        Text(logs.listening ? "Waiting for kernel log lines on udp/5140..." : "The listener is stopped.")
                            .font(BFont.mono(12)).foregroundStyle(Color.consoleMuted)
                    }
                }
                .onChange(of: logs.visible.last?.id) { _, id in
                    if logs.follow, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                Circle().fill(logs.listening ? Color.lime : Color.alertOnInk).frame(width: 8, height: 8)
                Text(logs.listening ? "Listening on udp/5140" : (logs.listenError ?? "Not listening")).foregroundStyle(Color.paper)
                if !logs.listening { Button("Retry") { logs.restart() }.controlSize(.small) }
                Spacer()
                if let s = logs.statusMessage { Text(s).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.consoleMuted) }
                Text("\(logs.linesPerSecond) lines/s  ·  showing \(logs.visible.count) of \(logs.bufferedCount)  ·  total \(logs.totalReceived)")
                    .foregroundStyle(Color.consoleMuted).monospacedDigit()
            }
            .font(BFont.mono(11)).padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(hex: 0x1d1d1b))
            .environment(\.colorScheme, .dark)
        }
        .page("Live Log")
    }

    private func copyVisible() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.logs.visible.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

/// Kernel log tags as data series, chosen to read on the ink console.
func tagColor(_ t: LogTag) -> Color {
    switch t {
    case .usb: .lime
    case .gpu: .amber
    case .wlan: Color(hex: 0x9ccf86)     // leaf, lightened for the ink
    case .fb: Color(hex: 0xc6c4ba)       // paper, quieter
    case .crash: .alertOnInk
    }
}

func lineColor(_ tags: UInt8) -> Color {
    if tags & LogTag.crash.bit != 0 { return .alertOnInk }
    for t in LogTag.allCases where tags & t.bit != 0 { return tagColor(t) }
    return .paper
}
