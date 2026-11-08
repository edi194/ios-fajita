# A Linux kernel compatibility layer ("KCL") for XNU: feasibility study

Date 2026-10-20. Research only: no code was changed, nothing was run on the phone.

Tags: **[V]** verified in this session (I read the cited source tree, header or page; commands are reproducible),
**[V-doc]** verified only as "a document in this repo says so", **[U]** unverified (memory, inference, or a
secondary source such as a search summary or a forum mirror).

Trees read (shallow, blob-filtered clones in the scratchpad, so every line count below is real):

| Tree | Revision |
|---|---|
| FreeBSD `freebsd-src` main (`sys/compat/linuxkpi`, `sys/contrib/dev/athk`, `sys/modules`) | e48eb1c5c47f, 2026-10-20 |
| `freebsd/drm-kmod` | 2026-10-08 |
| Linux `torvalds/linux` master (Makefile says 7.3-dev) | f47d223627f8, 2026-10-19 |
| OpenBSD / NetBSD | GitHub contents API listings only (file names and sizes) |

## 0. Verdict

1. **A full LinuxKPI-style layer is feasible in principle but is the wrong first investment for this project.**
   The OS-independent half (locks, lists, workqueues, kmalloc, completions, idr/xarray) maps cleanly onto XNU and
   would take a few person-weeks. The expensive half is not the "kernel API" at all, it is the **SoC
   frameworks** the Qualcomm drivers sit on (OF/DT, clk, regulator, pinctrl, interconnect, genpd, iommu/io-pgtable,
   SCM, rpmsg/remoteproc/QMI/QRTR), and **LinuxKPI deliberately does not provide any of them** [V, section 2].
   Measured against the Linux tree, those frameworks plus the Qualcomm providers for SDM845 are roughly 100k+
   lines of GPL code; our hand-written equivalents are about 1.5k lines [V counts, section 4].
2. **No other BSD solved this for a Qualcomm SoC either.** FreeBSD's ath10k is PCI-only (`snoc.c` and `qmi.c` are
   imported but not built), OpenBSD's `clk.h` is a 12-line stub, FreeBSD's `of.h` is a 33-line stub that includes
   `kobject.h` [V]. Nobody has hosted drivers/gpu/drm/msm on a BSD LinuxKPI (it is not in drm-kmod; NetBSD's
   drm2 tree has no msm directory either) [V].
3. **Licensing blocks the "just link it in" model for most of what we want.** msm, btqca/hci_qca, sound/soc/qcom,
   drivers/soc/qcom, clk/interconnect/iommu are GPL-2.0 (only). ath10k is ISC (permissive). The FSF says APSL 2.0 is
   incompatible with the GPL [V, gnu.org]. So a single XNU binary that statically contains GPL-only drivers is not
   something we can claim is clean. Not legal advice (section 5).
4. **Recommendation: do not build a general KCL now.** Keep hand-porting, but (a) use Linux sources as the
   register/sequence reference and generate register headers from the MIT-licensed Adreno XML, (b) factor the
   things we keep re-writing into a small set of reusable in-tree "provider" primitives with Linux-shaped names
   (clk/regulator/icc/pd votes, firmware read, QMI/QRTR, SMEM/GLINK), and (c) only start a mini-shim if we
   decide to host the ISC-licensed ath10k core. Effort numbers are in section 7.

## 1. What LinuxKPI actually is

### 1.1 Size and layout [V]

`sys/compat/linuxkpi` in FreeBSD main: **74,031 lines** of `.c`/`.h` (33,395 in `common/src`, 40,636 in
`common/include`), plus `dummy/` with empty header stubs so `#include <linux/x.h>` succeeds. Largest files:
`linux_80211.c` 10,309, `linux_compat.c` 3,125, `linux_pci.c` 2,544, `linux_hdmi.c` 1,953, `linux_usb.c` 1,720,
`linux_80211_macops.c` 1,041. So the 802.11 emulation is **about 15 % of the layer**, and everything else is ~62k
lines (the headers dominate). URL: https://github.com/freebsd/freebsd-src/tree/main/sys/compat/linuxkpi

drm-kmod is a separate tree that carries a pinned copy of the Linux DRM stack (`drivers/gpu/drm`,
`include/drm`, amd/i915/radeon, ttm, `drivers/dma-buf`) plus a small `linuxkpi/gplv2` shim: **about 6.46 million lines
of `.c`/`.h`** [V], and its own tiny `linuxkpi/gplv2/include/linux` (`dma-buf.h`, `dma-fence-unwrap.h`,
`sync_file.h`, 2,773 header lines in all `linuxkpi/`). https://github.com/freebsd/drm-kmod

### 1.2 Subsystem coverage (what the headers/sources contain) [V, file listing of `common/src` and `common/include/linux`]

| Area | Provided | Notes |
|---|---|---|
| Memory | `slab.h` (318 lines), `gfp.h`, `vmalloc.h`, `mm.h`, `page.h`, `linux_page.c` (830) | `GFP_ATOMIC = M_NOWAIT\|M_USE_RESERVE`, `GFP_KERNEL`-class maps to `M_WAITOK`; pages via `vm_page_alloc_noobj[_contig]` |
| Locking | `spinlock.h`, `mutex.h`, `rwsem.h`, `seqlock.h`, `ww_mutex.h`, `completion.h`, `semaphore.h`, `linux_lock.c` | **`spin_lock` is `mtx_init(... MTX_DEF ...)`, a sleepable mutex; `spin_lock_irqsave` just sets `flags = 0` and takes it** [V `spinlock.h` l.118-147] |
| Wait queues | `wait.h`, `wait_bit.h`, `linux_schedule.c` | |
| Deferred work | `workqueue.h` (268), `linux_work.c` (821, on `taskqueue` + `callout`), `linux_tasklet.c` (277), `timer.h`, `hrtimer.h`, `linux_hrtimer.c`, `irq_work` | |
| IRQ | `interrupt.h` (196), `linux_interrupt.c` (251) | `request_irq` -> `bus_setup_intr(... INTR_TYPE_NET\|INTR_MPSAFE ...)` i.e. handlers run in FreeBSD ithreads [V] |
| Threads | `kthread.h`, `linux_kthread.c`, `linux_current.c` (fake `current`/`task_struct` attached to each `struct thread`) | |
| RCU | `rcupdate.h`, `srcu.h`, `linux_rcu.c` (461) on ck_epoch | real grace periods |
| DMA | `dma-mapping.h` (504), `scatterlist.h` (698), `dmapool.h`, busdma underneath | `dma_map_sg_attrs` -> `linux_dma_map_sg_attrs` |
| PCI | `pci.h`, `linux_pci.c` (2,544) | Linux `pci_driver` on FreeBSD newbus |
| Firmware | `firmware.h`, `linux_firmware.c` (244) | on `firmware(9)` |
| Device model | `device.h`, `device/driver.h`, `devres.h`, `linux_devres.c`, `platform_device.h` (97), `kobject.h`, `kref.h`, `sysfs.h`, `linux_kobject.c`, `miscdevice.h`, `cdev.h` | "sysfs-lite": enough for attribute groups, no real tree |
| Containers | `list.h`, `llist.h`, `rbtree.h`, `idr.h` (`linux_idr.c` 820), `xarray.h`, `radix-tree.h` (`linux_radix.c` 593), `hashtable.h`, `kfifo.h`, `interval_tree.h` | BSD-2-Clause re-implementations |
| Atomics/bitops/time | `atomic.h`, `asm/atomic*.h`, `bitops.h`, `bitmap.h`, `ktime.h`, `jiffies.h`, `delay.h`, `time.h` | |
| i2c | `i2c.h`, `linux_i2c.c`, `linux_i2cbb.c`, `i2c-algo-bit.h` | |
| Other buses | `usb.h` + `linux_usb.c` (1,720), `mhi.h` + `linux_mhi.c` | USB conflicts with the native stack per the 2026 report [V] |
| Networking | `skbuff.h`, `linux_skbuff.c`, `netdevice.h`, `linux_netdev.c`, **802.11**: `linux_80211.c`, `linux_80211_macops.c`, `net/mac80211.h`, `net/cfg80211.h` | the mac80211/cfg80211 emulation, built on FreeBSD's native `net80211` (a hard prerequisite) |
| PM | `pm_runtime.h` (164), `pm.h`, `pm_qos.h`, `suspend.h` | thin |
| Qualcomm | `linux/soc/qcom/qmi.h` (173, BSD-2) | **type/enum definitions only; no `qmi_*` function exists in `common/src`**; `linux/qrtr.h` is a 41-line stub [V] |

### 1.3 What it does NOT provide [V]

* **Device tree / OF**: `of.h` is 33 lines and only includes `kobject.h`; there is no `of_property_read_*`,
  `of_address`, `of_irq`, `of_platform` (a few are empty `dummy/` headers).
* **clk**: there is no `linux/clk.h` in `common/include` at all (grep for `clk_get`/`struct clk` finds nothing).
* **regulator**: `regulator/consumer.h` is 15 lines (`err.h` + `suspend.h`, copyright 2025-2026, dumbbell). No
  `regulator_get/enable`.
* **pinctrl, gpio descriptors, interconnect, genpd/`pm_domain.h`, iommu/io-pgtable, nvmem, devfreq, pm_opp, remoteproc,
  rpmsg/glink, qcom_scm, mdt_loader**: absent, or empty dummy headers (`iommu.h` is 29 lines).
* **dma-buf / dma-fence / dma-resv**: not in LinuxKPI; they come from drm-kmod (GPL copies of `drivers/dma-buf`) [V
  drm-kmod tree].
* **A specific Linux version.** The FreeBSD wiki says LinuxKPI "does not officially target compatibility with any
  specific Linux kernel version"; subsystems declare their own targets [V search summary of
  https://wiki.freebsd.org/LinuxKPI]. In practice: wireless drivers were all moved to Linux **6.19** in 2026 [V
  https://www.freebsd.org/status/report-2026-01-2026-03/lkpi-wireless/], drm-kmod had Linux 4.9 in 2018 [V
  https://www.phoronix.com/news/DRM-Next-KMOD-On-FreeBSD-11], and `LINUXKPI_VERSION_NUMBER` in drm-kmod is
  61400 (a FreeBSD `__FreeBSD_version`-style number, not a Linux version) [V].

Why the gap exists: FreeBSD already has native `ofw`/`clk`/`regulator`/`hwreset`/`pinctrl` frameworks
(`sys/dev/ofw`, `sys/dev/clk`; I saw `clk_get_by_name`, `clk_get_by_ofw_index` in `sys/dev/clk/clk.h` [V]) and every
LinuxKPI user so far is a PCI/USB/ACPI device that does not need them. On FreeBSD/arm64 the Linux-style SoC drivers
are rewritten natively, not hosted.

### 1.4 How the other BSDs do it [V names/sizes via GitHub API]

* **OpenBSD** `sys/dev/pci/drm/include/linux`: 275 entries, ~294 KB of headers. `clk.h` is
  `struct clk { uint32_t freq; }; clk_get_rate(); devm_clk_get();` and a no-op `devm_clk_put` macro, "Public domain".
  amd/i915/radeon only. https://github.com/openbsd/src/tree/master/sys/dev/pci/drm/include/linux
* **NetBSD** `sys/external/bsd/drm2/linux`: 32 `.c` files (~295 KB: `linux_dma_fence*.c`, `linux_dma_resv.c`,
  `linux_idr.c`, `linux_xa.c`, `linux_ww_mutex.c`, `linux_kthread.c`, `linux_pci.c`, `linux_sgt.c`, ...) and
  `drm2/include/linux` with 178 headers (~400 KB) that **do** include `clk.h`, `pinctrl/`, `regulator/`, `reset.h`,
  `pm_domain.h`, `platform_device.h`, `of_device.h` mapped onto NetBSD's FDT frameworks (for Tegra/i.MX/Allwinner
  display). No msm in `drm2/dist/drm` (list includes amd, i915, nouveau, radeon, ttm, vmwgfx...).
  https://github.com/NetBSD/src/tree/trunk/sys/external/bsd/drm2/linux

So the two designs in the wild are: (i) FreeBSD, a big generic layer for PCI/USB hardware, and (ii) OpenBSD/NetBSD,
a **headers-and-stubs** layer sized for one driver family, with SoC frameworks mapped onto the host's native
ones where they exist. We have no native FDT/clk/regulator frameworks to map onto, which is the crux.

### 1.5 Maintenance model and cost [V unless marked]

* FreeBSD imports Linux driver trees as `sys/contrib/dev/...` with a few `#ifdef __FreeBSD__` hunks: ath10k has 248
  such hunks in 88,167 lines, iwlwifi 103 in 143,774, rtw88 66 in 162,756 [V]. That is the achievable "minimal
  delta" once a mature layer exists (0.1-0.3 % of lines touched).
* They are updated per Linux release, with real regressions: the 2026 Q1 report lists a 6-second auth delay on
  rtw88 8821c/8822b, chandef emulation needing rework, "the LinuxKPI IDR implementation is insufficient for mt76
  and needs a full rework", USB conflicts with the native stack [V].
* The wireless side is one named developer (Bjoern Zeeb) with Foundation sponsorship, working since ~2021 (rtw88
  appeared in 13.2, iwlwifi later; ath10k is "mostly working in station mode" on PCI and still on the to-do list)
  [V https://www.freebsd.org/status/report-2026-01-2026-03/lkpi-wireless/]. Even on a mature BSD, bringing one Wi-Fi
  family up through LinuxKPI took years of part-time work.

## 2. Mapping Linux primitives onto XNU, and the hard mismatches

XNU facts I checked: `osfmk/kern/locks.h` (xnu-8796.101.5) declares `lck_spin_*`, `lck_mtx_*`, `lck_rw_*`,
sleep-with-inheritor and gate APIs; wake-with-inheritor "cannot be called from interrupt context" [V
https://github.com/apple-oss-distributions/xnu/blob/xnu-8796.101.5/osfmk/kern/locks.h]. In `osfmk/arm/locks_arm.c`
the `lck_spin_*` wrappers go to `hw_lock_*` or `lck_ticket_*` and never touch DAIF (they do not mask interrupts);
preemption is maintained inside the hw_lock layer [V]; preemption-disable timeouts can panic under
`SCHED_HYGIENE_DEBUG` [V]. Our own patches already use `lck_mtx_lock/unlock` (12 calls), `kalloc_data` (7),
`kernel_thread_start` (16), `assert_wait_deadline` + `thread_block`, `kmem_alloc_contig` (5), `ml_io_map` (53),
`pmap_find_phys` (12), `IOWorkLoop`+`IOTimerEventSource`, `IOMemoryDescriptor` (19) [V grep of `xnu/patches`].

| Linux primitive | XNU mapping | Difficulty / mismatch |
|---|---|---|
| `kmalloc/kzalloc/kfree/kvmalloc` | `kalloc_data(size, Z_WAITOK\|Z_ZERO)`, `kfree_data`; `GFP_ATOMIC/NOWAIT` -> `Z_NOWAIT`; big buffers `kmem_alloc` | easy. Linux code often relies on `ksize`/`krealloc`: need a size header [U]. `kalloc_type` is irrelevant |
| `dma_alloc_coherent`, `dma_map_*`, `sg_table` | `kmem_alloc_contig` + `pmap_set_cache_attributes` (both used in `sweet_a630.c`) or `ml_io_map` for device-owned memory; DMA address = `pmap_find_phys` when the SMMU context is bypass | easy for the identity case; **real IOMMU domains** (`iommu_map`, io-pgtable) need our own SMMU driver (we have `sweet_smmu.c`, 239 lines: context banks only) |
| `spin_lock`, `_irqsave`, `_bh` | **Follow LinuxKPI: make them all `lck_mtx`** and run IRQ bottom halves, timers, tasklets in kernel threads. `lck_spin_lock` is not IRQ-masking, so a true IRQ-safe spinlock would need `ml_set_interrupts_enabled(false)` + `lck_spin` and debug-mode preemption-timeout panics [V/U] | the central design decision. Threaded-everything costs latency (GMU/HFI and CE interrupts are fine; DPU vblank would suffer) but removes the "sleep in atomic" class of panics |
| `mutex`, `rwsem`, `completion` | `lck_mtx` / `lck_rw` / mutex+`assert_wait`+`thread_wakeup` | easy. `mutex_lock_interruptible` and signal semantics: ignore signals |
| `wait_event*`, `wake_up` | `assert_wait_deadline` + `thread_block` with re-check loop under a lock, `thread_wakeup_prim` | easy; `wait_event_timeout` jiffies -> `mach_absolute_time` deadlines |
| `workqueue`, `delayed_work` | one `kernel_thread_start` worker per workqueue (work items sleep: `thread_call` threads are a shared pool and should not block for long [U]); `thread_call_enter_delayed` to arm delayed work | medium (ordering, `flush_work`, `cancel_work_sync`, `alloc_ordered_workqueue` semantics). FreeBSD needed 821+277 lines |
| `timer_list`, `hrtimer`, `msleep`, `usleep_range`, `udelay` | `thread_call` (thread context), `IOSleep`, `delay` (57 uses already) | easy |
| `request_irq/threaded_irq` | needs **SPI routing**. In our tree only PPI/SGI enable code exists (`GICR_ISENABLER0` for vtimer and IPI SGI; no SPI `ISENABLER<n>`/dispatch found by grep) and every device so far is polled (touch via the TLMM latch, UFS, USB) [V-doc/grep, not exhaustive]. Needs a GICv3 SPI dispatcher in `sleh_irq` + a per-IRQ thread | medium (400-800 lines [U]); required for CE/GMU/SMMU-fault IRQs, not for first bring-up |
| `kthread_*`, `current`, `task_struct` | `kernel_thread_start`, `current_thread()`; fake `task_struct` per thread like `linux_current.c` | easy-medium |
| **RCU** | XNU has no RCU. Cheap correct shim: global `lck_rw` (`rcu_read_lock` = shared, `synchronize_rcu` = exclusive lock/unlock, `call_rcu` = deferred to a worker). Alternatives: XNU's SMR (introduced around xnu-8792 [U]) | easy but readers must not sleep and must not run in true IRQ context (fine with threaded IRQs) |
| `atomic_*`, `bitops`, barriers, `READ_ONCE` | clang builtins / `os_atomic_*`, `__builtin_arm_dmb` | trivial |
| `kref`, `refcount_t`, `kobject` | `os_ref` or `OSIncrementAtomic` | trivial. `kobject`/sysfs: stub to nothing |
| `idr`, `xarray`, `radix_tree`, `rbtree`, `list`, `hashtable` | **copy FreeBSD's BSD-2 versions** (`linux_idr.c`, `linux_radix.c`, xarray) or write ~1.5k lines | easy; pure C |
| `ktime_get`, `jiffies`, `HZ` | `mach_absolute_time` + `absolutetime_to_nanoseconds`; make `jiffies` a function | easy |
| `request_firmware` | read from our partition readers (FAT `bluetooth`, `modem:image/`) or `/usr/standalone/firmware/sweet/` over the rootfs; already exists in ad-hoc form | easy |
| `platform_device`/`of_*` | **no counterpart**: XNU has the Apple Device Tree (ADT) only (`DTLookupEntry`/`DTGetProperty`), synthesized by `tools/mkadt.py`. Options: embed the stock Linux FDT and implement `of_*` over libfdt (dual GPL/BSD), or generate ADT nodes with Linux property names (ADT property names are limited to 32 bytes [U]) | medium: `of_*` subset for one driver is ~1.5k lines; "all of OF" (graph, phandle args, reserved-mem, overlays, `of_platform_populate`, ranges translation) is what drivers/of is (~15k lines [U]) |
| `pm_runtime_*`, genpd | counting stubs that call our existing GDSC/clock votes | easy to stub, but the semantics (autosuspend, parent/child domain, `pm_domain_attach`) are what the GPU/GMU actually depend on for power sequencing |
| `struct device` + driver model + devres | do **not** map to IOKit. Provide a small C `device`/`driver`/`bus` with devres (FreeBSD's `linux_devres.c` is the template). Bridge to IOKit only at the top via a thin C++ `IOService` per exposed interface that never includes Linux headers (this is Genode's rule, section 6) | the central mismatch. IOKit matching is by `IONameMatch`/personalities and class instantiation; Linux is `of_match_table` + `probe()` + `-EPROBE_DEFER` re-ordering. Needing `EPROBE_DEFER` re-probe means a deferred-probe worklist, ~200 lines |
| `printk` formats (`%pe`, `%pS`, `%pOF`, `%*ph`, `%pV`) | custom `vsnprintf` front end over `kprintf` | easy but widespread; Linux uses them in thousands of messages |
| `struct page`, `PAGE_SIZE` | **mismatch: XNU arm64 page size is 16 KiB here** (README: 16K pages); Linux drivers and firmware layouts assume 4 KiB `PAGE_SIZE` in many places (GMU buffers, io-pgtable granule, `shmem` BOs). Define `PAGE_SIZE 4096` in the compat layer and carve 4K "pages" out of 16K XNU pages | medium and error-prone, a major source of subtle bugs [U] |
| GCC extensions, `asm goto`, initcalls, `__percpu` | Apple clang accepts statement expressions, `typeof`, designated init, zero-length arrays, `asm goto` (arm64 jump labels can be compiled out with `static_branch_*` -> atomic). Initcalls: Mach-O needs `__attribute__((section("__DATA,__lkinit")))` (segment,section form) or an explicit table. `__init/__exit/EXPORT_SYMBOL/MODULE_*` -> no-ops. `DEFINE_PER_CPU` -> arrays indexed by `cpu_number()` | easy per construct; XNU builds with `-Werror` and strict warnings, so foreign files need per-file `-Wno-*` overrides (we already do this for the imported HFS, pthread and BearSSL files in `bsd/conf/files` [V-doc]) |
| Name collisions | XNU headers define `queue_t`, `thread_t`, `wait_queue_t`, `lck_*`, `kmem_*`, `struct device`-ish names, `PAGE_SIZE`, `ktime`-ish helpers; Linux files must never see XNU headers and vice versa. Needs the strict C/C++ separation (and a separate include path per translation unit) | the cost is paid in every shim header, 2-3 weeks of whack-a-mole [U] |
| Kernel stack | XNU kernel stacks are 16 KiB [U] vs Linux's 16 KiB, but Linux DRM code puts big structs on stack | low risk |

Summary of the mismatches that actually hurt: (1) no DT/OF, (2) driver model vs IOKit, (3) spinlock/IRQ context
semantics (solvable by "everything is a thread"), (4) 16K page size, (5) no SPI interrupt infrastructure yet, (6)
header namespace collisions. The pure primitives (memory, locks, waits, lists, atomics) are the easy part and are
what LinuxKPI mostly consists of.

## 3. The Qualcomm gap, measured

Line counts from the Linux tree above (`wc -l`, so they include comments):

| Layer the drivers need | Linux implementation (lines) | What we have today | Verdict |
|---|---|---|---|
| OF/DT (`drivers/of`) | ~15k [U, not checked out] | ADT nodes made by `mkadt.py`; `shim` reads the FDT | must be shimmed |
| Common clk framework | `drivers/clk/clk.c` 5,682 | none | shim with a flat provider table |
| Qualcomm clk drivers for SDM845 | gcc-sdm845 + gpucc + rcg2 + branch + gdsc + alpha-pll + rpmh + common ... 12,745 | `sweet_*` GCC votes, RCG programming, GDSC poke (in `sweet_a630.c`, `sweet_usb.c`, `beryllium_wlan.c`) | the whole 12.7k is mostly tables; a data-driven re-implementation is ~2-3k |
| Regulator core + rpmh-regulator | core 6,909 + qcom-rpmh-regulator + of_regulator (10,054 together) | `sweet_rpmh.c` 464: ACTIVE-TCS votes of enable/voltage/mode by cmd-db name | shim: `regulator_get/enable/set_voltage` -> `sweet_rpmh` |
| RPMh + cmd-db + SMEM + SCM + mdt_loader + llcc + QMI + smp2p | 15,435 (incl. `qcom_scm.c`, `qmi_interface.c` 854) | rpmh/cmd-db in `sweet_rpmh.c`; SCM PAS for the zap in `sweet_a630_pas.c` 342; SMEM/SMP2P/GLINK/QRTR/QMI in `beryllium_wlan.c` draft (2,323 lines, never run) | hand versions exist; QMI and QRTR are the ones ath10k needs |
| pinctrl core + msm pinctrl + sdm845 tables | core ~3.9k, msm 3,042 | TLMM pinmux pokes | shim over a table |
| genpd + rpmhpd | core 4,160, rpmhpd [U, not counted] | GDSC/RPMh votes by hand | shim |
| interconnect core + rpmh + BCM voter + sdm845 | 3,856 + core 1,273 | `bcm votes` in `sweet_rpmh.c`/`sweet_a630.c` (cmd-db BCMs MC0/ACV/SH0/SH2/CN0 found) | shim |
| IOMMU: iommu core + arm-smmu(+qcom) + io-pgtable-arm | 9,322 + core 4,265 | `sweet_smmu.c` 239 (context banks, identity) | io-pgtable-arm (1,301, GPL-2.0-only) is the one self-contained piece worth lifting/rewriting if per-process GPU page tables are needed |
| rpmsg/glink + remoteproc (q6v5 MSS) + QRTR | 12,130 | MBA/MSS boot designed in `WIFI_BT_PLAN.md` §1.2, not yet run | needed by Wi-Fi regardless of approach |
| devfreq, pm_opp, nvmem, devcoredump | n/a | n/a | stub |

Totals: roughly **100-110k lines** of upstream infrastructure for the full chain vs **under 2k lines** hand-written
today for the few paths we exercise. A KCL that runs the real frameworks (Genode's strategy, section 6) buys
correctness for free but links ~100k lines of GPL-2.0-only code into the kernel binary (section 5). A KCL that
shims them keeps the code small but ends up reimplementing exactly the subset the hand ports already have. In both
cases the first question is not "how do I call `spin_lock`" but "what does `clk_set_rate(gmu_clk, 200000000)` do on a
kernel with no clk framework", and the existing hand code is the answer.

Driver-side dependency footprints (distinct `#include <linux/...>` headers):

* `hci_qca.c` + `btqca.c` + `hci_ldisc.c`: 35 headers, but also the **entire Linux Bluetooth core**
  (`net/bluetooth`: 72,900 lines, `hci_core.h`, `hci_cmd_sync`, skb) and `serdev`/tty. hci_qca.c is 2,851 lines,
  btqca.c 1,030.
* `ath10k` snoc+qmi+core+ce+mac: 37 headers incl. `net/mac80211.h`, `net/cfg80211.h`, `net/sock.h` (QRTR runs on
  AF_QIPCRTR sockets), `remoteproc/qcom_rproc.h`, `qcom_scm`, `iommu`, `of_reserved_mem`, `nvmem`, `regulator`, `clk`
  (snoc.c lines 1033-1061, 1362-1367, 1589-1720 show regulator_bulk, clk_bulk, of_property_read, iommu domain for the
  firmware MSA). ath10k is 85,419 lines total; `mac.c` alone is 10,380 of mac80211 glue.
* `msm` a6xx GPU core (`a6xx_gpu.c`, `a6xx_gmu.c`, `a6xx_hfi.c`, `adreno_gpu.c`, `msm_gpu.c`, `msm_gem*.c`,
  `msm_iommu.c`, `msm_ringbuffer.c`, `msm_submitqueue.c`): 14,094 lines, 39 distinct `linux/` headers (clk,
  interconnect, pm_opp, pm_domain, iommu io-pgtable, nvmem, devfreq, qcom_scm, qcom_pas, llcc, mdt_loader,
  devcoredump, dma-buf, sync_file, of_reserved_mem ...) plus the DRM core pieces it calls: `drm_gem.c` 1,768,
  `drm_gpuvm.c` 3,206, `drm_syncobj.c` 1,721, `drm/scheduler` 5,396, `dma-fence.c`+`dma-resv.c` 2,039, with all of
  `msm` being 116,246 lines (adreno 26,461; disp 49,062; dsi 10,678; dp 9,185; hdmi 5,781).

## 4. Where Linux code is actually most valuable to us

The hand port reached **GMU boot, HFI, GX power** on 2026-10-20 in about one day of hardware cycles (NOTES.md
"boot 0118g4/g5"), with `sweet_a630.c` at 2,350 lines. What remains is mostly `a6xx_hw_init` register programming
(`a6xx_gpu.c` has 136 `gpu_write/rmw` calls, `a6xx_gmu.c` 93), CP/SQE firmware load, ring buffer submission, and a
userspace-visible interface. Those are tables and sequences: copy them as **facts** (register offsets, order) into
our own code. For register definitions use the generator: `drivers/gpu/drm/msm/registers/gen_header.py` is
`SPDX: MIT`, and the XML files (`a6xx.xml` 5,109 lines, `a6xx_gmu.xml` 271, `adreno_pm4.xml` 2,447) carry the
freedreno MIT-style license text in `freedreno_copyright.xml` [V]. Generating headers from them removes a class
of typo bugs at zero license risk.

## 5. Licensing facts (not legal advice)

SPDX/MODULE_LICENSE scan of the Linux tree above (`.c`/`.h`):

| Directory | SPDX | MODULE_LICENSE |
|---|---|---|
| `drivers/gpu/drm/msm` | 221 `GPL-2.0-only`, 24 `GPL-2.0`, 1 `BSD-3-Clause`, 1 `GPL-2.0-only OR BSD-2-Clause`; **0 files without SPDX** | `"GPL"` |
| `drivers/gpu/drm/msm/registers` | `gen_header.py` MIT; XML license text MIT-style | n/a |
| DRM core (`drm_gem.c`, `drm_syncobj.c`, `scheduler/sched_main.c`) | MIT license text (no SPDX in the first lines) | n/a; `drm_gpuvm.c` is `GPL-2.0-only OR MIT` |
| `drivers/dma-buf/dma-fence.c` | `GPL-2.0-only` | |
| `drivers/net/wireless/ath/ath10k` | **62 files, all `ISC`** | `"Dual BSD/GPL"` (5 files) |
| `drivers/bluetooth/btqca.c`, `btqca.h`, `hci_qca.c` | `GPL-2.0-only` | `"GPL"` |
| `hci_ldisc.c`, `hci_uart.h` | `GPL-2.0-or-later` | `"GPL"` |
| `sound/soc/qcom` | 42 `GPL-2.0`, 15 `GPL-2.0-only` | GPL |
| `drivers/soc/qcom` (smem, rpmh, cmd-db, qmi_interface ...) | 23 `GPL-2.0-only`, 22 `GPL-2.0` | GPL |
| `net/qrtr` | 5 GPL-2.0(-only), `ns.c` is `GPL-2.0 OR BSD-3-Clause` | mostly "GPL v2" |
| `drivers/remoteproc` | mostly GPL-2.0-only/GPL-2.0, one `BSD-3-Clause`, one `GPL-2.0-only OR BSD-3-Clause` | |
| `drivers/clk/qcom` | 184 `GPL-2.0-only`, 55 `GPL-2.0`, 5 `GPL-2.0-only OR BSD-2-Clause` | GPL |
| `drivers/interconnect/qcom`, `drivers/iommu/arm` | GPL-2.0(-only) | GPL |

What follows from it:

* **Only ath10k (ISC) and the MIT register database are permissively licensed.** ISC is APSL-compatible in the
  sense that its notice-preservation terms can sit next to APSL files in one binary. This also explains why FreeBSD
  could import ath10k and rtw88 (the Realtek and Intel drivers are dual licensed) into a BSD tree: the BSD kernel
  stays BSD. Linux's mac80211/cfg80211/qmi helpers are GPL, which is why FreeBSD wrote its own BSD-2 802.11
  emulation instead of copying them (the FreeBSD wiki says developers "cannot derive code directly from Linux
  source" [V search summary of wiki.freebsd.org/LinuxKPI]).
* **Everything else we want (msm adreno core, hci_qca/btqca, sound/soc/qcom, soc/qcom, clk, interconnect,
  arm-smmu, remoteproc) is GPL-2.0, mostly "only".**
* **APSL 2.0 vs GPL**: the FSF's own page says APSL 2.0 is a free-software license but "is incompatible with the
  GPL" and is not a true copyleft [V https://www.gnu.org/philosophy/apsl.html, fetched]. GPLv2 section 2(b)
  requires the combined work as distributed to be licensed as a whole under the GPL; APSL terms cannot be satisfied
  at the same time. Consequence for us: **a single XNU kernel binary containing GPL-2.0-only driver code
  (statically linked, as we do: no kexts) is a combined work we cannot distribute under either license cleanly.**
  Publishing source on GitHub with a GPL driver file next to APSL files is aggregation and is a different question
  from shipping the linked kernel Mach-O (we ship `kernel.development.sweet` in CI artifacts [V-doc]).
* FreeBSD's model (drm-kmod): the BSD kernel is permissive and GPL-compatible, GPL-only drivers are separate kmods
  that users build and load. XNU is not GPL-compatible, so that trick does not transfer cleanly even if we built
  the Linux code as a separate kernel collection / kext: the kext still links against APSL kernel symbols and
  our shim.
* Practical options, from safest: (1) **re-implement from behavior and register facts** (what we already do, and
  what the topaz/ath10k notes in `WIFI_BT_PLAN.md` call "re-implementation with attribution"); register layouts and
  sequences are facts, code is not; (2) **vendor only permissive files** (ath10k core, MIT DRM bits, the MIT
  register headers); (3) distribute GPL driver sources as a separate, user-built patch set and publish no linked
  binary containing them (the "drm-kmod" posture, with the caveat above); (4) ask an actual lawyer before choosing
  (3). Linux-firmware blobs (`a630_gmu.bin`, `a630_sqe.fw`, WCN3990 `board-2.bin`/`wlanmdsp.mbn`) have their own
  redistribution terms [U]; we load them from the phone's own partitions, which is the safest route.

## 6. Prior art

On FreeBSD/OpenBSD/NetBSD, see section 1. Beyond the BSDs:

* **Genode `dde_linux` (the most instructive).** Genode first built a hand-tailored `lx_emul.h` per driver. Their
  21.08 release notes say that did not scale: the i.MX8 graphics port "took us two months", updating to newer
  kernels was costly, and the needed skill mix was rare. The redesign runs **unmodified Linux C code**, with a
  generic `lx_emul` ABI layer, a small C++ `lx_kit` (user-level task scheduler), `genode_c_api` wrappers, **C++
  never includes Linux headers**, a `create_dummies` tool that auto-generates stubs for unused functions, and
  `extract_initcall_order`; drivers: i.MX8MQ framebuffer + SD, Allwinner A64 net + PinePhone framebuffer; "no single
  line of Linux code had to be changed"; cost: ~1.5 MiB binary for a framebuffer driver [V
  https://genode.org/documentation/release-notes/21.08]. Lesson for SoC drivers: **compile the real Linux
  frameworks (of, clk, regulator, device core) rather than shim them, and generate dummies automatically.** That
  maximizes fidelity and minimizes per-driver labor, and it is exactly the opposite of a per-driver mini-shim.
  It also maximizes the GPL surface (section 5).
* **LKL (Linux Kernel Library)**: Linux compiled as an architecture port so applications link kernel code (POSIX
  and Windows hosts); experimental [V search summaries, https://github.com/libos-nuse/lkl-linux,
  https://events19.lfasiallc.com/wp-content/uploads/2017/11/LKL_-Another-Way-to-Reuse-the-Linux-Kernel_Yu-Li.pdf].
  Relevant as the third architecture: host the whole Linux core in a sandbox and give it a few host hooks (threads,
  memory, MMIO, IRQs). With a DT-driven Linux it would give us clk/regulator/pinctrl/icc/genpd/rpmh/smmu for free,
  at the price of a second scheduler and a second MM running inside XNU.
* **macOS/Hackintosh**: itlwm/AirportItlwm ports **OpenBSD's** `iwm`, not Linux, and presents an `IOEthernet`
  device instead of IO80211 (AirportItlwm uses IO80211 but is less stable and needs a build per macOS release)
  [U, secondary summaries: https://github.com/OpenIntelWireless/itlwm; GPL-2.0 per Gitee mirrors]. The "present as
  Ethernet" trick is the same one this repo uses for Wi-Fi (`ue0`/`en0` plan in `WIFI_BT_PLAN.md` §4).
  LucyRTL8125Ethernet is a macOS kext published under GPLv2 [V README via search summary; its Linux
  lineage is not stated there]. A June 2026 r/hackintosh post describes "Feixiao", Linux **rtw88** on macOS with a
  LinuxKPI-style translation layer, partly AI-written, scanning and joining open 2.4 GHz networks [U, community
  post mirrored at reddit.sentinel-team.org; I could not find the original or a repo].
* **Apple's own porting guide** ("Introduction to Porting Drivers to OS X") assumes BSD-style drivers rewritten to
  IOKit; there is no supported Linux-driver route [V search].
* **iOS-on-Android-hardware projects in this repo's docs**: UniXNU (`NativeAdreno` kext, Turnip backend) and
  ios-topaz (WLAN WPA2-PSK station with data path on SM6225) are hand-written XNU drivers with no Linux compat
  layer [V-doc: GPU_RESEARCH.md, NOTES.md]. They are the direct competition and the direct proof that
  hand-porting reaches the goal.
* **Searched and not found**: any published LinuxKPI-equivalent for XNU/Darwin hosting amdgpu, iwlwifi, ath10k
  or msm. Absence of search hits is weak evidence [U].

Lessons (each tied to evidence above): (1) the 802.11 layer is the single biggest piece after the core, and it still
leaves 11n/ac and scan problems on the best-funded BSD; (2) ath10k on FreeBSD stayed PCI-only for years, so
"hosted via LinuxKPI" does not mean "SNOC works"; (3) per-driver headers do not scale across SoCs (Genode); (4)
version pinning is a continuing cost (FreeBSD re-ports every Linux release and ships regressions); (5) every
successful macOS Wi-Fi project avoided IO80211 by emulating Ethernet.

## 6a. The three architectures, compared

| | A. LinuxKPI-style layer | B. Genode-style (real Linux subsystems + dummies) | C. Targeted mini-shims or continue hand ports |
|---|---|---|---|
| Idea | Reimplement the Linux API on XNU (BSD-2 code) and host unmodified drivers | Compile Linux core subsystems (of, clk, regulator, driver core, genpd, icc) with a thin arch layer and run unmodified drivers | Per driver, supply only the 20-60 symbols it needs, or transcribe the logic |
| Fits Qualcomm frameworks | no (does not provide them) | yes, by compiling them | by our own provider tables |
| Kernel binary size/GPL surface | small shim (permissive) + GPL drivers | ~100k+ lines GPL | smallest GPL exposure (re-implementation) |
| Upgrade path | per-release pinning | per-release pinning, tooling helps | manual |
| First useful result | slowest | slowest (framework bring-up) | fastest |

## 7. Recommendation, order, effort, risks

**Decision: continue hand ports now (option C), with deliberate reuse; revisit B only if the project grows to many
Qualcomm peripherals (audio DSP, camera, modem data) where the framework count explodes. Do not build A as such.**

Concrete actions:

1. Add a small in-tree "providers" file set (not named KCL, no Linux headers): `sweet_clk` (rate/enable by SoC clock
   id), `sweet_vreg` (names to RPMh VRM votes, wrapping `sweet_rpmh.c`), `sweet_icc` (BCM votes), `sweet_pd`
   (GDSC/RPMhPD), `sweet_fw` (firmware read from partitions/rootfs), `sweet_qmi`/`sweet_qrtr`/`sweet_glink`/`sweet_smem`
   (needed by Wi-Fi no matter what). These are the Qualcomm gaps from section 3, written once, used by BT, GPU and
   Wi-Fi.
2. Generate register headers from Linux's MIT XML (`gen_header.py`) for a6xx and GMU.
3. Keep Linux as the executable specification: when a sequence is wrong, read the Linux function, port the sequence.

If we nevertheless build a mini hosting layer (to host ath10k only, the one permissively licensed target), do it in
this order and size it as below. Person-weeks assume one experienced engineer who knows this repo, with the existing
build/boot loop (CI build 4-5 min, phone flash/boot cycle) and **no JTAG**; they are order-of-magnitude [U].

| Step | Scope | pw [U] | Notes |
|---|---|---|---|
| KCL-0 core | headers (types, compiler, kernel, err, list, bitops, atomic, slab, mutex, spinlock-as-mutex, completion, wait, workqueue/thread, timer/thread_call, kthread, ktime/jiffies, delay, devres, device/platform/driver with EPROBE_DEFER, printk, firmware), borrow BSD-2 `idr/xarray/radix/kref/list` from FreeBSD | 4-6 | 6-8k new lines; includes the per-file warning overrides and namespace separation; first test: compile a trivial Linux file and a `kunit`-style self-test |
| (a) btqca / hci_qca | do **not** host `hci_qca`+Linux BT core (72,900 lines). Compile only `btqca.c` (1,030 lines TLV/NVM download) against a ~300-line fake `hci_dev`/`skb`/`hci_cmd_sync`, and our polled GENI UART as the "serdev" | 1-2 on top of KCL-0 (3 standalone via copy-the-logic) | **ROI is negative**: patch 0124 (`0124-beryllium-bt-firmware.patch`, by its name; I did not read it) already targets BT firmware download by hand. The real work is the iOS HCI transport (bluetoothd/IOBluetooth), which no Linux code covers. Use it only as the first smoke test of KCL-0 |
| (b) ath10k + QMI/QRTR | host the ISC core (`core, hw, bmi, ce, htc, htt*, txrx, wmi*, snoc, qmi, qmi_wlfw_v01`), **skip `mac.c`** and mac80211: provide our own thin ops that map to an Ethernet-like interface; reimplement `qmi_interface` (854 GPL lines) and QRTR over GLINK/SMEM (ours); `of_*` subset, regulator/clk/iommu/scm stubs onto section 3 providers; GIC SPI for CE IRQs (or poll) | 6-10 for the layer + ath10k bring-up, plus 6-10 for MSS/MBA boot, SMEM/GLINK/QRTR/pd-mapper/tqftpserv/rmtfs (needed by any approach) | topaz-style hand protocol port: 8-12 total (HTC/WMI/HTT are SoC-independent, ~60-70 % logic reuse per `WIFI_BT_PLAN.md`). The layer saves little because ath10k's hard parts (modem boot, MSA hyp-assign, QMI WLFW sequence) are *not* ath10k code. Full mac80211 emulation (FreeBSD's 10-11k lines + native net80211) would add 12-20 pw and has no iOS consumer anyway |
| (c) msm a6xx GPU, no DPU/KMS | host `a6xx_gpu/gmu/hfi`, `adreno_gpu`, `msm_gpu`, `msm_gem*`, `msm_iommu` | 12-20 for KCL-0 + DRM core subset (`drm_gem`, `drm_gpuvm`, `drm/scheduler`, `drm_syncobj`, `dma-fence/resv`, io-pgtable-arm) + clk/genpd/icc/regulator/pm_opp/devfreq/nvmem/scm/llcc/mdt_loader providers | **worse than hand-porting what's left**: we already have GMU+HFI+GX in 2.4k lines and have measured hardware behavior that differs from the Linux constants (e.g. PDC `gfx.lvl` 0x30050 vs Linux a630). All of this code is GPL-2.0-only (section 5), so hosting it creates the binary-distribution problem for the most valuable driver. Hand-port the remaining CP init/ring/submission: ~3-6 pw [U] |

Order if we ever do it: KCL-0 + btqca smoke test (a) -> ath10k core (b) -> (c) last or never.

Risks:

* **License (highest)**: GPL-2.0-only code in a static XNU binary with APSL code (section 5). Mitigation: only ISC/MIT
  files, or re-implementation, or ask counsel.
* **Debuggability**: no serial, no JTAG, a hung Linux framework (probe defer loop, workqueue deadlock) looks like
  a silent boot hang; we can only recover through UDP log + persistent ring. A generic layer multiplies the places
  a hang can hide.
* **Threaded-everything semantics**: Linux code that assumes IRQ-off/atomic context (`spin_lock_irqsave` protecting
  hardware state shared with an IRQ handler, `in_interrupt()`) may be racy when everything is a mutex; FreeBSD
  accepted this, but its drivers are PCI NICs/GPUs with good locking, not SoC power sequencers.
* **16K vs 4K pages**: subtle corruption risk in GPU/GMU/SMMU buffer handling.
* **Namespace collisions** between XNU and Linux headers require strict C/C++/Linux/XNU include separation.
* **Version drift**: every Linux import is a snapshot; FreeBSD updates per release. The Qualcomm drivers change fast
  (the tree I read is 7.3-dev; ath10k and msm are rarely stable across 6.x for out-of-tree users).
* **Binary size/boot**: Genode's "~1.5 MiB for a framebuffer driver" shows the overhead of hosting real frameworks.
* **Opportunity cost**: the userspace-facing work (IOAccelerator/Metal plugin discovery, Wi-Fi interface for configd,
  Bluetooth HCI for bluetoothd) is where the project is blocked next, and Linux code does not help there.

## 8. Sources

* FreeBSD LinuxKPI: https://github.com/freebsd/freebsd-src/tree/main/sys/compat/linuxkpi ; wiki https://wiki.freebsd.org/LinuxKPI
* FreeBSD ath10k: https://github.com/freebsd/freebsd-src/tree/main/sys/contrib/dev/athk/ath10k ; module Makefile `sys/modules/ath10k/Makefile` (PCI only, `ATH10K_USB=0`)
* drm-kmod: https://github.com/freebsd/drm-kmod ; Phoronix 2018 http://www.phoronix.com/news/DRM-Next-KMOD-On-FreeBSD-11
* FreeBSD wireless status 2026 Q1: https://www.freebsd.org/status/report-2026-01-2026-03/lkpi-wireless/ ; rtw88 2022: https://www.freebsd.org/status/report-2022-01-2022-03/rtw88/
* OpenBSD DRM compat headers: https://github.com/openbsd/src/tree/master/sys/dev/pci/drm/include/linux
* NetBSD drm2 linux: https://github.com/NetBSD/src/tree/trunk/sys/external/bsd/drm2/linux and `.../drm2/include/linux`
* Linux msm / ath10k / hci_qca / soc/qcom: https://github.com/torvalds/linux (paths as cited)
* XNU `locks.h` / `locks_arm.c`: https://github.com/apple-oss-distributions/xnu/tree/xnu-8796.101.5/osfmk
* FSF on APSL 2.0: https://www.gnu.org/philosophy/apsl.html
* Genode DDE-Linux redesign: https://genode.org/documentation/release-notes/21.08
* LKL: https://github.com/libos-nuse/lkl-linux
* itlwm: https://github.com/OpenIntelWireless/itlwm ; LucyRTL8125Ethernet: https://github.com/Mieze/LucyRTL8125Ethernet
* Apple porting guide: https://developer.apple.com/library/archive/documentation/Porting/Conceptual/PortingDrivers/intro/intro.html
* Repo docs: `README.md`, `NOTES.md`, `docs/GPU_RESEARCH.md`, `docs/GPU_A630_BRINGUP.md`, `docs/WIFI_BT_PLAN.md`
