import Foundation

/// Live device metrics of the phone: the JSON printed by `/usr/local/bin/sweetmetrics` (docs/BERGAMOTA_METRICS.md, schema 1).
/// Every field except `schema` may be missing or null (a kernel interface that is not there yet): the UI shows "unknown", never 0.
struct ClusterMetrics: Equatable, Sendable {
    var id: Int
    var name: String
    var cpus: [Int] = []
    var curKhz: Int?
    var minKhz: Int?
    var maxKhz: Int?
    /// unknown (sysctl absent: fixed by the bootloader) | off | pending | skipped | static (a fixed cap) | governor
    var mode = "unknown"
    var governor: String?
    var capPercent: Int?
    /// The governor's ceiling in kHz (cap_khz of the v1 sysctl) and its own load figure (busiest CPU of the cluster), LUT and number of state writes.
    var capKhz: Int?
    var kernelLoadPct: Int?
    var changes: Int?
    var lutKhz: [Int] = []
    var loadPct: Double?

    /// SDM845 top states, used for the bar scale only while the kernel does not report `maxKhz`.
    var nominalMaxKhz: Int { id == 0 ? 1_785_600 : 2_803_200 }

    var modeText: String {
        switch mode {
        case "governor":
            var t = (governor == nil || governor == "gov") ? "governor" : "governor " + governor!
            if let cap = capKhz, let mx = maxKhz, cap > 0, cap < mx { t += ", cap \(formatKhz(cap))" }
            return t
        case "static": return capPercent.map { "capped at \($0)%" } ?? "fixed"
        case "off": return "cpufreq off (bootloader state)"
        case "pending": return "cpufreq starting"
        case "skipped": return "cpufreq skipped"
        default: return "unknown (fixed by bootloader)"
        }
    }
}

struct GPUMetrics: Equatable, Sendable {
    var present = false
    /// on | slumber | off | lost | unknown (a driver, no state source) | absent (no SweetAdreno630 service)
    var state = "absent"
    var level: Int?
    var levels: Int?
    var mhz: Double?
    var minMhz: Double?
    var maxMhz: Double?
    var busyPct: Double?
    var clients = 0
    var source: String?
    /// gov | fixed
    var freqMode: String?
    var pids: [Int] = []
    var suspends: Int?
    var recoveries: Int?
    var hangs: Int?

    var hasDCVS: Bool { mhz != nil || level != nil || busyPct != nil }
}

struct RendererMetrics: Equatable, Sendable {
    /// cpu | softpipe | fd630: derived from the facts below, not from the marker alone
    var mode = "cpu"
    var label = "CPU (CoreAnimation software)"
    /// off | soft | 1 (boot-arg or marker)
    var requested = "off"
    var injected: Bool?
    var gpuClientOpen = false
    var backboarddPid: Int?
    var logLast: String?
}

struct BatteryMetrics: Equatable, Sendable {
    var present = false
    var percent: Double?
    var charging: Bool?
    var external: Bool?
    /// Positive while charging, negative while discharging (kernel SweetBattery).
    var currentMa: Double?
    var voltageMv: Double?
    var source: String?
}

struct PhoneMetrics: Equatable, Sendable {
    var schema = 1
    /// The phone's clock when it sampled.
    var t: Date
    /// When Bergamota received it.
    var fetched = Date()
    var freqKnown = false
    var clusters: [ClusterMetrics] = []
    var cpuLoad: [Double] = []
    var gpu = GPUMetrics()
    var renderer = RendererMetrics()
    var battery = BatteryMetrics()
    var batteryTempC: Double?
    var errors: [String] = []
    /// The object exactly as printed by sweetmetrics (re-published in status.json `phone.metrics`).
    var json = ""

    /// The JSON object in `out`: the last line that starts with `{` (an SSH banner or motd may come first).
    nonisolated static func extractJSON(_ out: String) -> String? {
        for line in out.split(whereSeparator: \.isNewline).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("{"), t.hasSuffix("}") { return t }
        }
        return nil
    }

    nonisolated static func parse(_ out: String, now: Date = Date()) -> PhoneMetrics? {
        guard let text = extractJSON(out), let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func num(_ d: [String: Any]?, _ k: String) -> Double? {
            guard let v = d?[k], !(v is NSNull) else { return nil }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }   // 0 and 1 bridge to Bool: test the CF type
            return n.doubleValue
        }
        func int(_ d: [String: Any]?, _ k: String) -> Int? { num(d, k).flatMap { $0.isFinite ? Int($0) : nil } }
        func str(_ d: [String: Any]?, _ k: String) -> String? { d?[k] as? String }
        func bool(_ d: [String: Any]?, _ k: String) -> Bool? { (d?[k] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } }

        var m = PhoneMetrics(t: num(o, "t").map { Date(timeIntervalSince1970: $0) } ?? now, fetched: now)
        m.schema = int(o, "schema") ?? 1
        m.json = text

        if let cpu = o["cpu"] as? [String: Any] {
            m.freqKnown = bool(cpu, "freqKnown") ?? false
            m.cpuLoad = (cpu["loadPct"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            for case let c as [String: Any] in (cpu["clusters"] as? [Any]) ?? [] {
                var k = ClusterMetrics(id: int(c, "id") ?? m.clusters.count, name: str(c, "name") ?? "cluster")
                k.cpus = (c["cpus"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                k.curKhz = int(c, "curKhz")
                k.minKhz = int(c, "minKhz")
                k.maxKhz = int(c, "maxKhz")
                k.mode = str(c, "mode") ?? "unknown"
                k.governor = str(c, "governor")
                k.capPercent = int(c, "capPercent")
                k.capKhz = int(c, "capKhz")
                k.kernelLoadPct = int(c, "kernelLoadPct")
                k.changes = int(c, "changes")
                k.lutKhz = (c["lutKhz"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                k.loadPct = num(c, "loadPct")
                m.clusters.append(k)
            }
        }
        if let g = o["gpu"] as? [String: Any] {
            m.gpu.present = bool(g, "present") ?? false
            m.gpu.state = str(g, "state") ?? "unknown"
            m.gpu.level = int(g, "level")
            m.gpu.levels = int(g, "levels")
            m.gpu.mhz = num(g, "mhz")
            m.gpu.minMhz = num(g, "minMhz")
            m.gpu.maxMhz = num(g, "maxMhz")
            m.gpu.busyPct = num(g, "busyPct")
            m.gpu.clients = int(g, "clients") ?? 0
            m.gpu.source = str(g, "source")
            m.gpu.freqMode = str(g, "freqMode")
            m.gpu.pids = (g["pids"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            m.gpu.suspends = int(g, "suspends")
            m.gpu.recoveries = int(g, "recoveries")
            m.gpu.hangs = int(g, "hangs")
        }
        if let r = o["renderer"] as? [String: Any] {
            m.renderer.mode = str(r, "mode") ?? "cpu"
            m.renderer.label = str(r, "label") ?? m.renderer.label
            m.renderer.requested = str(r, "requested") ?? "off"
            m.renderer.injected = bool(r, "injected")
            m.renderer.gpuClientOpen = bool(r, "gpuClientOpen") ?? false
            m.renderer.backboarddPid = int(r, "backboarddPid")
            m.renderer.logLast = str(r, "logLast")
        }
        if let b = o["battery"] as? [String: Any] {
            m.battery.present = bool(b, "present") ?? false
            m.battery.percent = num(b, "percent")
            m.battery.charging = bool(b, "charging")
            m.battery.external = bool(b, "external")
            m.battery.currentMa = num(b, "currentMa")
            m.battery.voltageMv = num(b, "voltageMv")
            m.battery.source = str(b, "source")
        }
        m.batteryTempC = num(o["thermal"] as? [String: Any], "batteryC")
        m.errors = (o["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
        return m
    }
}

/// One point of the sparklines.
struct MetricSample: Sendable {
    var t: Date
    /// CPU kHz per cluster index (nil = not reported)
    var cpuKhz: [Int?]
    var cpuLoad: [Double?]
    var gpuMhz: Double?
    var gpuBusy: Double?
    var batteryMa: Double?
}

/// The last ~2 minutes of samples (one per ~2 s).
struct MetricsHistory: Sendable {
    static let window: TimeInterval = 120
    private(set) var samples: [MetricSample] = []

    mutating func add(_ m: PhoneMetrics) {
        let now = m.fetched
        samples.append(MetricSample(t: now,
                                    cpuKhz: m.clusters.map { $0.curKhz },
                                    cpuLoad: m.clusters.map { $0.loadPct },
                                    gpuMhz: m.gpu.mhz, gpuBusy: m.gpu.busyPct, batteryMa: m.battery.currentMa))
        samples.removeAll { now.timeIntervalSince($0.t) > Self.window + 5 }
    }
    mutating func clear() { samples = [] }

    func cpu(_ cluster: Int) -> [(Date, Double)] {
        samples.compactMap { s in cluster < s.cpuKhz.count ? s.cpuKhz[cluster].map { (s.t, Double($0)) } : nil }
    }
    var gpu: [(Date, Double)] { samples.compactMap { s in s.gpuMhz.map { (s.t, $0) } } }
    var battery: [(Date, Double)] { samples.compactMap { s in s.batteryMa.map { (s.t, $0) } } }
    /// Highest CPU frequency seen on a cluster (bar scale when the kernel reports no maximum).
    func peakKhz(_ cluster: Int) -> Int { Int(cpu(cluster).map(\.1).max() ?? 0) }
}

func formatKhz(_ khz: Int) -> String {
    khz >= 1_000_000 ? String(format: "%.2f GHz", Double(khz) / 1_000_000) : String(format: "%d MHz", Int((Double(khz) / 1000).rounded()))
}

func formatMa(_ ma: Double) -> String { String(format: "%+.0f mA", ma) }

/// "waiting on" lines shared by both views: which kernel interface is not there yet.
func metricsWaiting(_ m: PhoneMetrics) -> [String] {
    var w: [String] = []
    if !m.freqKnown { w.append("CPU frequency: kern.sweet_cpufreq missing (kernel without the cpufreq patch)") }
    if m.clusters.contains(where: { $0.mode == "static" }) && m.clusters.allSatisfy({ $0.minKhz == nil && $0.maxKhz == nil }) {
        w.append("CPU governor: the sysctl reports a fixed state only (no min/max/governor yet)")
    }
    if !m.gpu.hasDCVS { w.append(m.gpu.state == "absent" ? "GPU: no SweetAdreno630 service (kernel without the GPU driver)" : "GPU level/MHz/busy: waiting on kern.sweet_gpu (DCVS governor)") }
    return w
}
