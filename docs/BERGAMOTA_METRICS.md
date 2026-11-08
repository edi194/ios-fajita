# Bergamota live device metrics (`sweetmetrics`)

`/usr/local/bin/sweetmetrics` prints **one JSON object** with the phone's live metrics. Bergamota (apps/Bergamota) runs it over SSH about every 2 s while iOS is up, shows it (Dashboard "Performance" card, Control Plane strip, 2-minute sparklines) and republishes it in `status.json` as `phone.metrics`; `scripts/bergamota metrics [--json]` prints it.

Source: `tools/sweetnet/sweetmetrics.c` (plain C, arm64e, `tools/sweetnet/build.sh` -> `research/sweetnet/ios18/sweetmetrics`, then `tools/renegade/renegade strip --sign`). Installed by Renegade (`tools/renegade/root_tweaks18.py`, `sweetmetrics()`); on a running phone: `scp` it to `/usr/local/bin/sweetmetrics` and verify the sha256.
It is read-only and takes about 0.3 s (the CPU load window). Flags: `--gpu-info` (also open a SweetAdreno630 user client and read INFO, see GPU), `--no-load`, `--interval MS` (load window, default 250), and the host-test hooks `--parse-cpufreq STR` / `--parse-gpu STR`.

## Contract (schema 1)

Rules: every member except `schema` may be **missing or null**; null means "not reported by this kernel", never 0. Readers must ignore unknown members and unknown `mode`/`state` strings. A new incompatible layout bumps `schema`. `errors` lists the sources that were unavailable (human text).

```json
{
  "schema": 1,
  "t": 1792781636.697,                      // phone clock, unix seconds
  "cpu": {
    "source": "sysctl kern.sweet_cpufreq",  // or "none"
    "freqKnown": true,                      // false: no frequency source at all (fixed by the bootloader)
    "loadPct": [31,22,18,40,3,0,1,0],       // per CPU, host_processor_info deltas over the window
    "clusters": [
      { "id": 0, "name": "A55", "cpus": [0,1,2,3],
        "curKhz": 1209600, "minKhz": null, "maxKhz": null,
        "mode": "static",                   // unknown | off | pending | skipped | static | governor
        "governor": null,                   // name when mode = governor
        "capPercent": 40,                   // static cap of kern.sweet_cpufreq (patch 0190)
        "perfState": 3, "perfStates": 12,   // LUT index / entries (patch 0190)
        "loadPct": 28 },                    // mean of the cluster's CPUs
      { "id": 1, "name": "A75", "cpus": [4,5,6,7], "...": "..." }
    ]
  },
  "gpu": {
    "present": true,                        // the SweetAdreno630 IOService exists
    "source": "sysctl kern.sweet_gpu",      // | "SweetAdreno630 INFO" | "none"
    "state": "on",                          // on | slumber | off | lost | unknown | absent
    "level": 3, "levels": 8, "mhz": 427, "minMhz": 257, "maxMhz": 710, "busyPct": 41,
    "clients": 1                            // open SweetAdrenoUserClient instances
  },
  "renderer": {
    "mode": "fd630",                        // cpu | softpipe | fd630  (the truth, see below)
    "label": "FD630 (GPU)",                 // "CPU (CoreAnimation software)" | "softpipe" | "FD630 (GPU)"
    "requested": "1",                       // off | soft | 1   (boot-arg bglrender, else the marker)
    "requestedBy": "bootarg",               // bootarg | marker | none
    "backboarddPid": 87, "injected": true,  // injected: DYLD_INSERT_LIBRARIES with bergamota-gl in backboardd's environment
    "gpuClientOpen": true,                  // backboardd holds a SweetAdrenoUserClient
    "gpuClients": [ { "pid": 87, "name": "backboardd.real" } ],
    "registryRead": true,                   // false: no SweetAdreno630 service, so no client can exist
    "logLast": null                         // last line of /private/var/tmp/bgl-backboardd.log
  },
  "battery": {
    "present": true, "percent": 87, "charging": true, "external": true, "full": false,
    "source": "AC Power",                   // IOPS "Power Source State"
    "currentMa": 1020,                      // positive = charging, negative = discharging (kernel SweetBattery)
    "voltageMv": 4120
  },
  "thermal": { "batteryC": 31.5 },          // ONLY when measured; absent today (see below)
  "errors": ["kern.sweet_gpu: absent (GPU DCVS interface not in this kernel)"]
}
```

## How each field is derived

| Field | Source | Notes |
|---|---|---|
| CPU cur kHz, mode, cap | sysctl `kern.sweet_cpufreq` **v1** (patch 0190 governor): lines separated by `\n`; line 1 `sweet_cpufreq v1 mode=<gov\|fixed\|off> period_ms=N`; then `cluster0` / `cluster1` lines of `key=value` words (`name cpus state mode idx cur_khz min_khz max_khz cap_khz lut_n load changes lut_khz=a,b,.. tis_ms=khz:ms,..`) | `cur_khz`/`idx` are 0 unless `state=applied`: then `curKhz` is null (never 0). `mode=gov` -> `mode:"governor"`, `governor:"gov"`; `mode=fixed` -> `static`; `state=off\|pending\|skipped` -> that mode. `capPercent` = cap_khz / max_khz. Also emitted: `capKhz`, `kernelLoadPct` (the governor's busiest-CPU load), `changes`, `lutKhz`; `tis_ms` is not forwarded. The string is several hundred bytes: it is read with a size query. Absent sysctl = `freqKnown:false`, `mode:"unknown"`. Older strings (`domain0 A55 applied: state 3/12 1209600 kHz ...`) and `min`/`max`/`governor` words still parse |
| CPU load | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, two samples 250 ms apart | cluster 0 = CPU 0-3 (A55), cluster 1 = CPU 4-7 (A75) |
| GPU | sysctl `kern.sweet_gpu` (patch 0186, docs/GPU_KERNEL.md section 11): `key=value` words, one or two lines: `state=on\|slumber\|off\|lost level=L mhz=M max_level=N freq=gov\|fixed busy_pct=P clients=C pids=a,b submitted completed suspends resumes recoveries hangs ...`; with `--gpu-info` also the INFO selector `0x70` of `SweetAdreno630` (`sweet_adreno_abi.h`, ready/lost only) when there is no sysctl state | `level`/`mhz` are 0 in slumber (reported as 0); `levels` = `max_level`, `minMhz` 257, `maxMhz` from the kernel's level table (1 257, 2 342, 3 414, 4 520, 5 596, 6 675, 7 710); `busyPct` is shown as 0 in slumber (the kernel's value is stale then); also `freqMode`, `pids`, `suspends`, `recoveries`, `hangs`. `--gpu-info` opens (and closes) a user client every call, so Bergamota only passes it when Settings > Phone > "Read the GPU INFO selector" is on (default off) |
| Renderer | boot-arg `bglrender=` (`kern.bootargs`), else marker `/private/var/run/bglrender` (`MODE UUID [debug]`, honoured only when UUID = `kern.bootsessionuuid`, same rule as `bgl-launch`); backboardd pid from `KERN_PROC_ALL` (`backboardd` / `backboardd.real`); `injected` from its `KERN_PROCARGS2` environment; clients = children of the `SweetAdreno630` registry entry (service plane) with `IOUserClientCreator = "pid N, name"` | **Mode is the truth, not the request**: `fd630` only when backboardd itself holds a SweetAdrenoUserClient; `softpipe` only when the shim is injected into backboardd and `bgl-backboardd.log` shows softpipe; otherwise `cpu`. (Today the render server never creates an EAGLContext, so even `requested:"1", injected:true` reads `cpu`.) Reading the registry does not open a client |
| Battery | `IOPSCopyPowerSourcesInfo` (as `sweetps`: Current Capacity, Is Charging, Power Source State) plus the `IOPMPowerSource` registry entry (`InstantAmperage`/`Amperage`, `Voltage`, `ExternalConnected`, `FullyCharged`) | mA outside +-20000 is dropped (null) |
| Thermal | none | The SoC temperature is not exposed by the kernel. The battery `Temperature` property is a placeholder (2500, `SweetBatteryTemperatureEstimated`), so `thermal` is omitted unless that flag is gone |

## Bergamota

- Polling: `PhoneMonitor.refreshMetrics()` on its own 2 s loop (not the detection loop, never on the main thread), `ssh root@phone /usr/local/bin/sweetmetrics`, 6 s timeout. A missing tool (exit 127) is retried every 15 s with a message; samples are cleared when iOS goes away.
- UI: Dashboard "Performance" card (cluster bars with load and mode, GPU bar/state, renderer badge, battery draw, sparklines of CPU kHz per cluster, GPU MHz and battery mA over the last 2 minutes, a list of what is still waiting on the kernel); Control Plane strip below the PHONE/BATTERY/LAST BOOT tiles (shown while iOS is up).
- `status.json` `phone.metrics` = the object above plus `fetched` (ISO time at the Mac); `phone.metricsError` when the last poll failed. CLI: `scripts/bergamota metrics [--json]`.
- Tests: `apps/Bergamota/Tests/run-metrics-tests.sh` (Swift parser on recorded samples in `Tests/metrics-samples/`), `tools/sweetnet/test-sweetmetrics.sh` (C text parsers).

## Waiting on the kernel

- **SoC temperature**: nothing exposed; the battery temperature is a placeholder, so `thermal` is omitted.
- **GPU level/MHz/busy** and **CPU frequency, min/max, governor** are provided by `kern.sweet_gpu` / `kern.sweet_cpufreq` v1 on the develop kernel (verified on the phone, 2026-10-23). The GPU levels are the kernel's perf-table indexes: whether the GMU really applies index N is unverified on the kernel side.
- **Renderer**: needs nothing from the kernel; it becomes `fd630` the moment backboardd opens the GPU client, and `softpipe` once the render server uses the shim.
