import SwiftUI

/// A line over the last ~2 minutes (x = time, so a gap in the data is a gap in the line). `range` nil = auto from the data.
struct Sparkline: View {
    var points: [(Date, Double)]
    var color: Color
    var range: ClosedRange<Double>? = nil
    var window: TimeInterval = MetricsHistory.window
    var zeroLine = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Canvas { g, size in
                let now = ctx.date
                let pts = points.filter { now.timeIntervalSince($0.0) <= window }
                guard pts.count >= 2 else { return }
                let vals = pts.map(\.1)
                var lo = range?.lowerBound ?? (vals.min() ?? 0), hi = range?.upperBound ?? (vals.max() ?? 1)
                if range == nil {
                    let pad = max((hi - lo) * 0.15, hi == lo ? max(abs(hi) * 0.1, 1) : 0)
                    lo -= pad; hi += pad
                }
                if zeroLine { lo = min(lo, 0); hi = max(hi, 0) }
                func xy(_ p: (Date, Double)) -> CGPoint {
                    CGPoint(x: size.width * (1 - now.timeIntervalSince(p.0) / window),
                            y: size.height * (1 - (min(max(p.1, lo), hi) - lo) / max(hi - lo, 1e-9)))
                }
                if zeroLine, lo < 0, hi > 0 {
                    var z = Path()
                    let y = size.height * (1 - (0 - lo) / (hi - lo))
                    z.move(to: CGPoint(x: 0, y: y)); z.addLine(to: CGPoint(x: size.width, y: y))
                    g.stroke(z, with: .color(color.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                }
                var line = Path()
                var prev: Date?
                for p in pts {
                    if let pd = prev, p.0.timeIntervalSince(pd) > 8 { line.move(to: xy(p)) }     // data gap (> 4 missed polls)
                    else if prev == nil { line.move(to: xy(p)) } else { line.addLine(to: xy(p)) }
                    prev = p.0
                }
                g.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .background(alignment: .bottom) { Rectangle().fill(color.opacity(0.25)).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

/// Frequency bar: the filled part is cur / max.
struct FreqBar: View {
    var fraction: Double?
    var color: Color
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                if let f = fraction {
                    Capsule().fill(color).frame(width: max(height, g.size.width * min(max(f, 0), 1)))
                        .animation(.easeOut(duration: 0.4), value: f)
                }
            }
        }
        .frame(height: height)
    }
}

struct RendererBadge: View {
    var r: RendererMetrics
    var size: CGFloat = 10.5
    static func tone(_ mode: String) -> Tone { mode == "fd630" ? .lime : (mode == "softpipe" ? .amber : .quiet) }
    var body: some View { Pill(text: r.label, tone: Self.tone(r.mode), size: size) }
}

func gpuStateTone(_ s: String) -> Tone {
    switch s {
    case "on": .leaf
    case "slumber": .ink
    case "lost": .alert
    default: .quiet
    }
}

// MARK: Performance page

struct PerformanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mon = model.monitor
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Performance", subtitle: "sweetmetrics over SSH every ~2 s while iOS is up; the plots hold the last 2 minutes.") {
                    if let m = mon.metrics { RendererBadge(r: m.renderer, size: 11) }
                }
                if mon.state != .ios {
                    EmptyStage(title: "Available when iOS is up", text: "The phone is \(mon.state.title.lowercased()). Metrics start with the first sweetmetrics answer over SSH after iOS comes up.", symbol: "gauge.with.dots.needle.0percent")
                } else if let m = mon.metrics {
                    content(m, mon.metricsHistory)
                } else if let e = mon.metricsError {
                    Notice(text: e)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Waiting for the first sweetmetrics sample...").foregroundStyle(Color.muted) }
                }
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .page("Performance")
    }

    /// One measured line: name, bar against its peak, the value, its load, and its last two minutes.
    private func meter(_ name: String, _ sub: String, fraction: Double?, value: String, load: String?, color: Color,
                       points: [(Date, Double)], range: ClosedRange<Double>?, zeroLine: Bool = false, note: String = "") -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(BFont.display(17)).foregroundStyle(Color.text)
                Text(sub).font(BFont.mono(10.5)).foregroundStyle(Color.muted)
            }
            .frame(width: 92, alignment: .leading)
            Text(note).font(.caption).foregroundStyle(Color.muted).lineLimit(1).frame(width: 170, alignment: .leading)
            Text(value).font(BFont.mono(15, 600)).monospacedDigit().foregroundStyle(Color.text).frame(width: 104, alignment: .trailing)
            Text(load ?? "").font(BFont.mono(12)).monospacedDigit().foregroundStyle(Color.muted).frame(width: 44, alignment: .trailing)
            Sparkline(points: points, color: color, range: range, zeroLine: zeroLine).frame(height: 40).frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.rule).frame(height: 1) }
    }

    @ViewBuilder
    private func content(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        Panel(title: "CPU", symbol: "cpu") {
            ForEach(m.clusters, id: \.id) { c in
                let peak = max(c.maxKhz ?? 0, h.peakKhz(c.id), c.nominalMaxKhz)
                meter(c.name, "CPU \(c.cpus.first ?? 0)-\(c.cpus.last ?? 0)", fraction: c.curKhz.map { Double($0) / Double(peak) },
                      value: c.curKhz.map(formatKhz) ?? "unknown", load: c.loadPct.map { String(format: "%.0f%%", $0) } ?? "--",
                      color: .text, points: h.cpu(c.id), range: 0...Double(peak), note: c.modeText)
            }
            if !m.cpuLoad.isEmpty {
                HStack(spacing: 4) {
                    Text("load per core").font(BFont.mono(10.5)).foregroundStyle(Color.muted).frame(width: 108, alignment: .leading)
                    ForEach(Array(m.cpuLoad.enumerated()), id: \.offset) { _, l in FreqBar(fraction: l / 100, color: .leafText, height: 6) }
                }
                .padding(.top, 6)
            }
        }
        Panel(title: "GPU  Adreno 630", symbol: "square.stack.3d.up") {
            HStack(spacing: 8) {
                Pill(text: m.gpu.state, tone: gpuStateTone(m.gpu.state))
                Text(rendererDetail(m.renderer)).font(.callout).foregroundStyle(Color.muted).lineLimit(1).truncationMode(.tail)
            }
            meter("A630", m.gpu.maxMhz.map { String(format: "max %.0f MHz", $0) } ?? "max 710 MHz",
                  fraction: m.gpu.mhz.map { $0 / (m.gpu.maxMhz ?? 710) }, value: m.gpu.mhz.map { String(format: "%.0f MHz", $0) } ?? "unknown",
                  load: m.gpu.busyPct.map { String(format: "%.0f%%", $0) } ?? "--", color: .leafText, points: h.gpu,
                  range: 0...(m.gpu.maxMhz ?? 710), note: gpuLine(m.gpu))
        }
        Panel(title: "Battery", symbol: "battery.75percent") {
            meter(m.battery.percent.map { String(format: "%.0f%%", $0) } ?? "--",
                  m.batteryTempC.map { String(format: "%.1f \u{00B0}C", $0) } ?? "battery",
                  fraction: m.battery.percent.map { $0 / 100 }, value: m.battery.currentMa.map(formatMa) ?? "mA unknown", load: nil,
                  color: (m.battery.percent ?? 100) < 20 ? .alertText : .text, points: h.battery, range: nil, zeroLine: true,
                  note: batteryLine(m.battery))
        }
        let waiting = metricsWaiting(m)
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(waiting, id: \.self) { Label($0, systemImage: "hourglass").font(.caption).foregroundStyle(Color.muted).lineLimit(1) }
            }
        }
        Text("sample \(m.fetched.formatted(date: .omitted, time: .standard))  ·  sweetmetrics schema \(m.schema)")
            .font(BFont.mono(10.5)).foregroundStyle(Color.muted)
        if let e = model.monitor.metricsError { Notice(text: e) }
    }

    private func gpuLine(_ g: GPUMetrics) -> String {
        var p: [String] = []
        if let l = g.level { p.append("level \(l)" + (g.levels.map { "/\($0)" } ?? "")) }
        if let f = g.freqMode { p.append(f == "gov" ? "governor" : f) }
        if g.clients > 0 { p.append("\(g.clients) client\(g.clients == 1 ? "" : "s")") }
        if let r = g.recoveries, r > 0 { p.append("\(r) recover\(r == 1 ? "y" : "ies")") }
        if p.isEmpty { return g.hasDCVS ? "" : (g.state == "absent" ? "no GPU driver" : "level/MHz/busy not reported yet") }
        return p.joined(separator: " | ")
    }
}

func rendererDetail(_ r: RendererMetrics) -> String {
    var p: [String] = []
    p.append("requested " + (r.requested == "off" ? "none" : r.requested))
    if let i = r.injected { p.append(i ? "shim injected" : "not injected") }
    p.append(r.gpuClientOpen ? "backboardd has the GPU open" : "no GPU client in backboardd")
    return p.joined(separator: ", ")
}

func batteryLine(_ b: BatteryMetrics) -> String {
    var p: [String] = []
    if let c = b.charging { p.append(c ? "charging" : (b.external == true ? "plugged, not charging" : "on battery")) }
    if let v = b.voltageMv { p.append(String(format: "%.2f V", v / 1000)) }
    if let s = b.source { p.append(s) }
    return p.isEmpty ? "unknown" : p.joined(separator: " | ")
}

// MARK: Control Plane strip

/// The metrics on the Control Plane's ink, scaled like its tiles (`s` is its layout scale).
struct MetricsStrip: View {
    @Environment(AppModel.self) private var model
    var s: CGFloat

    var body: some View {
        let mon = model.monitor
        if mon.state == .ios {
            HStack(spacing: 18 * s) {
                if let m = mon.metrics {
                    cpuCard(m, mon.metricsHistory)
                    gpuCard(m, mon.metricsHistory)
                    batteryCard(m, mon.metricsHistory)
                } else {
                    CPTile(s: s) {
                        CPLabel(text: "Metrics", s: s)
                        Text(mon.metricsError ?? "waiting for sweetmetrics...").font(BFont.mono(16 * s)).foregroundStyle(Color.amber).lineLimit(2)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cpuCard(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        CPTile(s: s) {
            CPLabel(text: "CPU", s: s)
            ForEach(m.clusters, id: \.id) { c in
                let peak = max(c.maxKhz ?? 0, h.peakKhz(c.id), c.nominalMaxKhz)
                HStack(spacing: 10 * s) {
                    Text(c.name).font(BFont.display(17 * s)).foregroundStyle(Color.paper).frame(width: 62 * s, alignment: .leading)
                    FreqBar(fraction: c.curKhz.map { Double($0) / Double(peak) }, color: .paper, height: 9 * s)
                    Text(c.curKhz.map(formatKhz) ?? "unknown").font(BFont.mono(17 * s, 600)).monospacedDigit().foregroundStyle(Color.paper)
                        .frame(width: 100 * s, alignment: .trailing)
                    Text(c.loadPct.map { String(format: "%.0f%%", $0) } ?? "--").font(BFont.mono(14 * s)).monospacedDigit().foregroundStyle(Color.consoleMuted)
                        .frame(width: 46 * s, alignment: .trailing)
                }
            }
        }
    }

    private func gpuCard(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        CPTile(s: s) {
            HStack(spacing: 8 * s) {
                CPLabel(text: "GPU", s: s)
                Pill(text: m.gpu.state, tone: gpuStateTone(m.gpu.state), size: 11 * s)
                Spacer(minLength: 0)
                RendererBadge(r: m.renderer, size: 11 * s)
            }
            HStack(spacing: 10 * s) {
                FreqBar(fraction: m.gpu.mhz.map { $0 / (m.gpu.maxMhz ?? 710) }, color: .lime, height: 9 * s)
                Text(m.gpu.mhz.map { String(format: "%.0f MHz", $0) } ?? "unknown").font(BFont.mono(17 * s, 600)).monospacedDigit().foregroundStyle(Color.paper)
                    .frame(width: 96 * s, alignment: .trailing)
                Text(m.gpu.busyPct.map { String(format: "%.0f%%", $0) } ?? "--").font(BFont.mono(14 * s)).monospacedDigit().foregroundStyle(Color.consoleMuted)
                    .frame(width: 46 * s, alignment: .trailing)
            }
            Text((m.gpu.hasDCVS ? "" : (m.gpu.state == "absent" ? "no GPU driver in this kernel, " : "level/MHz/busy: waiting on the GPU DCVS interface, ")) + rendererDetail(m.renderer))
                .font(.system(size: 12 * s)).foregroundStyle(Color.consoleMuted).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func batteryCard(_ m: PhoneMetrics, _ h: MetricsHistory) -> some View {
        CPTile(s: s) {
            CPLabel(text: "Battery draw", s: s)
            HStack(spacing: 12 * s) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(m.battery.currentMa.map(formatMa) ?? "mA unknown").font(BFont.mono(18 * s, 600)).monospacedDigit().foregroundStyle(Color.paper)
                    Text(batteryLine(m.battery)).font(.system(size: 12 * s)).foregroundStyle(Color.consoleMuted).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .frame(width: 340 * s)
    }
}

/// A Control Plane tile: a raised ink panel with a console hairline.
struct CPTile<Content: View>: View {
    var s: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) { content }
            .padding(16 * s).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: 0x1d1d1b), in: RoundedRectangle(cornerRadius: 14 * s))
            .overlay(RoundedRectangle(cornerRadius: 14 * s).strokeBorder(Color.consoleLine))
    }
}

/// Section label on the Control Plane: mono capitals, scaled.
struct CPLabel: View {
    let text: String
    var s: CGFloat
    var body: some View { Text(caps(text)).font(BFont.mono(12 * s, 800)).tracking(1.4 * s).foregroundStyle(Color.consoleMuted) }
}
