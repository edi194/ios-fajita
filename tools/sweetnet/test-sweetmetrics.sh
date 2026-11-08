#!/bin/sh
# Host test of sweetmetrics' text parsers (no device): kern.sweet_cpufreq / kern.sweet_gpu strings -> JSON.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${TMPDIR:-/tmp}/sweetmetrics-host
clang -O2 -Wall -framework CoreFoundation -framework IOKit "$here/sweetmetrics.c" -o "$bin"
python3 - "$bin" <<'PY'
import json, subprocess, sys
b = sys.argv[1]
def run(*a): return json.loads(subprocess.check_output([b, *a]))
bad = 0
def ck(c, w):
    global bad
    print(("ok   " if c else "FAIL ") + w); bad += (not c)
cf = "domain0 A55 applied: state 3/12 1209600 kHz (requested 3, 40%); domain1 A75 applied: state 11/12 2803200 kHz (requested 11, 100%)"
c = run("--parse-cpufreq", cf)["cpu"]["clusters"]
ck([x["curKhz"] for x in c] == [1209600, 2803200] and c[0]["capPercent"] == 40 and c[0]["mode"] == "static", "patch 0190 string")
c = run("--parse-cpufreq", "domain0 A55 off; domain1 A75 pending")["cpu"]["clusters"]
ck(c[0]["mode"] == "off" and c[1]["mode"] == "pending" and c[0]["curKhz"] is None, "off / pending")
c = run("--parse-cpufreq", "domain0 A55 skipped; domain1 A75 applied: state 2/12 825600 kHz")["cpu"]["clusters"]
ck(c[0]["mode"] == "skipped" and c[1]["curKhz"] == 825600, "skipped + no cap")
c = run("--parse-cpufreq", "cluster0 A55 applied: 1100000 kHz min 300 max 1785600 governor schedutil; cluster1 A75 applied: 2000000 kHz gov=perf")["cpu"]["clusters"]
ck(c[0]["governor"] == "schedutil" and c[0]["minKhz"] == 300000 and c[0]["maxKhz"] == 1785600 and c[0]["mode"] == "governor" and c[1]["governor"] == "perf", "governor build (min/max MHz or kHz)")
ck(run("--parse-cpufreq", "garbage")["cpu"]["clusters"][0]["curKhz"] is None, "garbage gives unknown clusters")
g = run("--parse-gpu", "state slumber level 2/8 freq 342 MHz busy 12% min 257 max 710")["gpu"]
ck((g["state"], g["level"], g["levels"], g["mhz"], g["busyPct"], g["maxMhz"]) == ("slumber", 2, 8, 342, 12, 710), "gpu string")
g = run("--parse-gpu", "state=active level=7 clock=710000000 load=99")["gpu"]
ck((g["state"], g["level"], g["mhz"], g["busyPct"]) == ("on", 7, 710, 99), "gpu alt keys (active, Hz)")
g = run("--parse-gpu", "state lost")["gpu"]
ck(g["state"] == "lost" and g["mhz"] is None, "gpu lost, rest null")
v1 = ("sweet_cpufreq v1 mode=gov period_ms=25\n"
      "cluster0 name=A55 cpus=0-3 state=applied mode=gov idx=7 cur_khz=902400 min_khz=300000 max_khz=1785600 cap_khz=902400 lut_n=3 load=12 changes=41 lut_khz=300000,902400,1785600 tis_ms=300000:100,902400:50,1785600:0\n"
      "cluster1 name=A75 cpus=4-7 state=applied mode=gov idx=2 cur_khz=2803200 min_khz=825600 max_khz=2803200 cap_khz=2803200 lut_n=2 load=97 changes=9 lut_khz=825600,2803200 tis_ms=825600:5,2803200:9\n")
c = run("--parse-cpufreq", v1)["cpu"]["clusters"]
ck([x["curKhz"] for x in c] == [902400, 2803200] and c[0]["minKhz"] == 300000 and c[0]["maxKhz"] == 1785600, "v1: cur/min/max")
ck(c[0]["mode"] == "governor" and c[0]["governor"] == "gov" and c[0]["capPercent"] == 51 and c[1]["capPercent"] == 100, "v1: governor mode, cap percent")
ck(c[0]["perfState"] == 7 and c[0]["capKhz"] == 902400 and c[0]["kernelLoadPct"] == 12 and c[0]["changes"] == 41 and c[0]["lutKhz"] == [300000, 902400, 1785600], "v1: idx, cap, kernel load, changes, LUT")
c = run("--parse-cpufreq", "sweet_cpufreq v1 mode=off period_ms=0\ncluster0 name=A55 cpus=0-3 state=off mode=off idx=0 cur_khz=0 min_khz=300000 max_khz=1785600 cap_khz=0 lut_n=3 load=0 changes=0 lut_khz=300000,902400,1785600\ncluster1 name=A75 cpus=4-7 state=pending mode=gov idx=0 cur_khz=0 min_khz=0 max_khz=0 cap_khz=0 lut_n=0 load=0 changes=0\n")["cpu"]["clusters"]
ck(c[0]["mode"] == "off" and c[0]["curKhz"] is None and c[1]["mode"] == "pending" and c[1]["curKhz"] is None, "v1: off / pending clusters have no cur kHz (the kernel's 0 is not a frequency)")
c = run("--parse-cpufreq", "sweet_cpufreq v1 mode=fixed period_ms=250\ncluster0 name=A55 cpus=0-3 state=applied mode=fixed idx=4 cur_khz=1209600 min_khz=300000 max_khz=1785600 cap_khz=1209600 lut_n=12 load=0 changes=1\n")["cpu"]["clusters"]
ck(c[0]["mode"] == "static" and c[0]["capPercent"] == 68, "v1: fixed mode is static")
g = run("--parse-gpu", "state=on level=3 mhz=414 max_level=7 freq=gov busy_pct=42 clients=2 pids=123,456 submitted=1030 completed=1030 suspends=2 resumes=2 recoveries=0 hangs=0 idle_ms=2000 hwcg=1 total_ms=91000 res_ms=slumber:61000,L1:0")["gpu"]
ck((g["state"], g["level"], g["levels"], g["mhz"], g["busyPct"], g["maxMhz"], g["minMhz"]) == ("on", 3, 7, 414, 42, 710, 257), "gpu v1 line")
ck(g["freqMode"] == "gov" and g["pids"] == [123, 456] and g["suspends"] == 2 and g["recoveries"] == 0 and g["hangs"] == 0, "gpu v1: freq mode, pids, counters")
g = run("--parse-gpu", "state=slumber level=0 mhz=0 max_level=7 freq=gov busy_pct=88 clients=0 pids=- submitted=5 completed=5\nsuspends=1 resumes=1 recoveries=0 hangs=0")["gpu"]
ck(g["state"] == "slumber" and g["mhz"] == 0 and g["busyPct"] == 0 and g["pids"] is None and g["suspends"] == 1, "gpu v1: slumber (0 MHz, stale busy shown as 0), no pids, second line")
g = run("--parse-gpu", "state=on level=1 mhz=257 max_level=1 freq=fixed busy_pct=0 clients=1 pids=1,2,3,")["gpu"]
ck(g["pids"] == [1, 2, 3] and g["maxMhz"] == 257, "gpu v1: pid list cut by the kernel stays valid JSON; max_level 1")
g = run("--parse-gpu", "state=off level=0 mhz=0 max_level=0 freq=fixed busy_pct=0 clients=0 pids=-")["gpu"]
ck(g["state"] == "off" and g["levels"] == 0, "gpu v1: off")
sys.exit(1 if bad else 0)
PY
