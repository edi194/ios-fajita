// Parsing tests for Core/Metrics.swift with recorded sweetmetrics output. Run: Tests/run-metrics-tests.sh
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "metrics-samples"
func sample(_ n: String) -> String { (try? String(contentsOfFile: dir + "/" + n, encoding: .utf8)) ?? "" }

// today's kernel: cpufreq cap only, GPU service without DCVS, shim injected but the render server has no GPU client
let t = PhoneMetrics.parse(sample("today.json"))!
check(t.schema == 1 && t.freqKnown, "today: schema 1, frequencies known")
check(t.clusters.count == 2 && t.clusters[0].name == "A55" && t.clusters[1].name == "A75", "today: two clusters A55 / A75")
check(t.clusters[0].curKhz == 1_209_600 && t.clusters[1].curKhz == 2_803_200, "today: cur kHz")
check(t.clusters[0].minKhz == nil && t.clusters[0].maxKhz == nil, "today: min/max unknown (null, not 0)")
check(t.clusters[0].mode == "static" && t.clusters[0].capPercent == 40 && t.clusters[0].modeText == "capped at 40%", "today: static cap 40%")
check(t.clusters[1].nominalMaxKhz == 2_803_200 && t.clusters[0].nominalMaxKhz == 1_785_600, "today: bar scale fallback")
check(t.clusters[1].loadPct == 1, "today: a value of 1 is a number, not a Bool")
check(t.cpuLoad.count == 8 && t.clusters[0].loadPct == 28, "today: 8 per-CPU loads, cluster load")
check(t.gpu.state == "unknown" && !t.gpu.hasDCVS && t.gpu.mhz == nil, "today: GPU state unknown, no level/MHz/busy")
check(t.renderer.mode == "cpu" && t.renderer.requested == "1" && t.renderer.injected == true && !t.renderer.gpuClientOpen, "today: marker says 1 but the truth is CPU")
check(t.renderer.label == "CPU (CoreAnimation software)", "today: renderer label")
check(t.battery.percent == 87 && t.battery.charging == true && t.battery.currentMa == 1020 && t.battery.voltageMv == 4120, "today: battery")
check(t.batteryTempC == nil, "today: no thermal object")
check(metricsWaiting(t).count == 2, "today: waits on governor info and GPU DCVS")

// a future kernel: governor + GPU DCVS + GPU client in backboardd
let f = PhoneMetrics.parse(sample("future.json"))!
check(f.clusters[0].mode == "governor" && f.clusters[0].modeText == "governor schedutil", "future: governor mode")
check(f.clusters[1].minKhz == 825_600 && f.clusters[1].maxKhz == 2_803_200 && f.clusters[1].curKhz == 825_600, "future: min/cur/max")
check(f.gpu.state == "on" && f.gpu.level == 3 && f.gpu.levels == 8 && f.gpu.mhz == 427 && f.gpu.busyPct == 41, "future: GPU level/MHz/busy/state")
check(f.gpu.hasDCVS && metricsWaiting(f).isEmpty, "future: nothing left to wait on")
check(f.renderer.mode == "fd630" && f.renderer.gpuClientOpen && f.renderer.label == "FD630 (GPU)", "future: FD630 only because backboardd has the client")
check(f.battery.currentMa == -640 && f.battery.charging == false && formatMa(-640) == "-640 mA", "future: discharging mA")
check(f.batteryTempC == 31.5, "future: measured battery temperature")

// bare kernel: nothing exposed
let b = PhoneMetrics.parse(sample("bare.json"))!
check(!b.freqKnown && b.clusters.allSatisfy { $0.curKhz == nil && $0.mode == "unknown" }, "bare: frequencies unknown (fixed by bootloader)")
check(b.clusters[0].modeText == "unknown (fixed by bootloader)", "bare: mode text")
check(b.gpu.state == "absent" && !b.gpu.present, "bare: no GPU service")
check(!b.battery.present && b.battery.percent == nil && b.battery.currentMa == nil, "bare: no battery")
check(b.errors.count == 2, "bare: errors carried")

// recorded on the phone (xnu-11215, 2026-10-23, no cpufreq/GPU DCVS in that kernel, backboardd with a live GPU client)
let p = PhoneMetrics.parse(sample("phone-live.json"))!
check(p.cpuLoad.count == 8 && p.clusters[0].loadPct == 69 && p.clusters[0].curKhz == nil && !p.freqKnown, "phone-live: load known, frequency unknown")
check(p.renderer.mode == "fd630" && p.renderer.backboarddPid == 745, "phone-live: FD630 from the real GPU client") 
check(p.battery.percent == 10 && p.battery.currentMa == -140 && p.battery.voltageMv == 3552, "phone-live: battery")

// recorded on the phone with the governor kernel (v1 kern.sweet_cpufreq, kern.sweet_gpu in slumber)
let g = PhoneMetrics.parse(sample("phone-gov.json"))!
check(g.freqKnown && g.clusters[0].curKhz == 902_400 && g.clusters[1].curKhz == 2_803_200, "phone-gov: cur kHz of both clusters")
check(g.clusters[0].minKhz == 300_000 && g.clusters[0].maxKhz == 1_766_400 && g.clusters[0].capKhz == 902_400, "phone-gov: min/max/cap")
check(g.clusters[0].mode == "governor" && g.clusters[0].modeText == "governor, cap 902 MHz" && g.clusters[1].modeText == "governor", "phone-gov: governor mode text (cap shown only below max)")
check(g.clusters[0].lutKhz.count == 18 && g.clusters[1].lutKhz.count == 27 && g.clusters[0].changes == 243 && g.clusters[0].kernelLoadPct == 99, "phone-gov: LUT, changes, kernel load")
check(g.gpu.state == "slumber" && g.gpu.mhz == 0 && g.gpu.level == 0 && g.gpu.levels == 7 && g.gpu.maxMhz == 710 && g.gpu.hasDCVS, "phone-gov: GPU slumber, 0 MHz, DCVS present")
check(g.gpu.freqMode == "gov" && g.gpu.suspends == 9 && g.gpu.pids.isEmpty && g.gpu.busyPct == 0, "phone-gov: GPU governor, suspends, no pids")
check(metricsWaiting(g).isEmpty, "phone-gov: nothing left to wait on")

// SSH noise in front of the JSON, and failure output
check(PhoneMetrics.parse(sample("noisy.txt"))?.battery.percent == 87, "noisy: banner lines before the JSON are skipped")
check(PhoneMetrics.parse(sample("missing.txt")) == nil, "missing tool output: no JSON")
check(PhoneMetrics.parse("") == nil && PhoneMetrics.parse("{not json}") == nil, "garbage: nil")
check(PhoneMetrics.parse("{\"schema\":2,\"future\":{}}")?.schema == 2, "unknown schema 2: parsed tolerantly")
check(PhoneMetrics.parse(sample("today.json"))?.json == sample("today.json").trimmingCharacters(in: .whitespacesAndNewlines), "json kept verbatim for status.json")

// history: ~2 minutes, per-cluster series
var h = MetricsHistory()
let start = Date()
for i in 0..<80 {
    var m = PhoneMetrics.parse(sample("future.json"), now: start.addingTimeInterval(Double(i) * 2))!
    m.clusters[0].curKhz = 300_000 + i * 1000
    m.battery.currentMa = i % 2 == 0 ? -500 : nil
    h.add(m)
}
check(h.samples.count <= 65 && h.samples.count >= 60, "history: pruned to ~2 minutes (\(h.samples.count) samples)")
check(h.cpu(0).count == h.samples.count && h.cpu(1).count == h.samples.count, "history: cpu series per cluster")
check(h.battery.count < h.samples.count && h.gpu.count == h.samples.count, "history: missing values leave gaps, not zeros")
check(h.peakKhz(1) == 825_600, "history: peak kHz")
check(formatKhz(1_209_600) == "1.21 GHz" && formatKhz(825_600) == "826 MHz", "formatKhz")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
