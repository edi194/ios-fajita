# Static review of the ios-beryllium XNU patches (0082-0101 + touched sweet files)

Scope: research/bt81/xnu (0001-0101 applied), read-only; no phone access. Line numbers are in
research/bt81/xnu. Fixes are in `research/review-fixes/` (apply in numeric order with `patch -p1`
in the xnu tree; each compile-checked with `tools/xnu-cc.py` on a scratch copy, and the sequence
was re-applied to pristine copies of the files and compared with the compiled tree).

| patch | what | default |
|---|---|---|
| 01-fb-wait-flip-latch | wait for the MDP flush latch before drawing into the next back buffer; power-off copy out of fLock | on |
| 02-dma-real-cache-maintenance | real `dc civac` by VA for the SMMU L1 table and USB DMA; UFS opt-in | SMMU/USB on, UFS `ufsdmasync=1` |
| 03-usb-sweetusbfix-experiment | USB: QUSB2 power-up + Linux core reset + HS-only quirks | OFF, `sweetusbfix=1` |
| 04-amfi-priv-log-race | OOB write in the Sandbox priv-denial log table | on |
| 05-battery-msoc-rounding | FG msoc -> percent uses DIV_ROUND_CLOSEST like Linux | on |

## Ranked findings

### 1. [HIGH, hypothesis for the blocker] USB: the QUSB2 HS PHY is powered down when we start (sweet_usb.c:855-1007, 135-136)
- Every boot log ends the start sequence with `QUSB2 ... PWR_CTRL1 0x23232323` (logs/boot-0097f, 0100x). QUSB2 v2 PWR_CTRL1 (0x210) bit0 is POWER_DOWN
  (Linux phy-qcom-qusb2.c `PWR_CTRL1_POWR_DOWN`); the register is 8 bits replicated over the word, so 0x23 =
  POWER_DOWN | CLAMP_N_EN | VREF_SUPPLY_TRIM: **powered down**. ABL powers the HS PHY down when it hands over. No attempt (0084-0098) ever
  clears it; the sweet-derived code assumes "PHY set up as ABL left it", true on sweet but not here.
- Matches the symptom exactly: `DEPSTARTCFG` (pure register command, bus clock) completes, the next command `SETEPCONFIG` (writes the endpoint's
  context RAM, in the PHY/UTMI clock domain on this core) stays `DEPCMD 0x401` forever; independent of GCTL/RAMCLKSEL, soft reset or not,
  UTMI-as-PIPE clock, GUCTL1, SMMU (all tried). The PHY's 60 MHz UTMI clock feeds the controller; powered down => no clock => command never retires.
  (`PLL_STATUS 0x64` has bit5/PLL_LOCKED set in the dump, so the PLL may still run; the power-down bit gates the analog/UTMI side. Not proven.)
- Fix (patch 03, `sweetusbfix=1`, mask bit 1): clear POWER_DOWN (keep CLAMP_N_EN), wait 250 us, wait for PLL_LOCKED, print before/after.
  mask bit 2: the Linux `dwc3_core_soft_reset` sequence (GCTL.CORESOFTRESET, both PHYSOFTRST, 100 ms, release) before DCTL.CSFTRST, forcing the reset path
  (DEVSPD=HS applies only at a core reset; the no-reset variants kept DEVSPD=4 = SuperSpeed max with no SS PHY). mask bit 4: the mainline sdm845 USB2-only DT
  quirks (`snps,parkmode-disable-ss-quirk` GUCTL1[17], `dis-u1/u2-entry` DCTL INITU1/2ENA=0, `dis_u2_susphy`/`dis_enblslpm` GUSB2PHYCFG[6]/[8]=0).
  Boot with `sweetusb=2 sweetusbfix=1`; the log lines `SWEET USB FIX:` show PWR_CTRL1 before/after. If PWR_CTRL1 is already 0x22/0x20 before the fix the theory is wrong;
  then try `sweetusbfix=2` / `4` alone and look at the remaining candidates below.
- Other candidates, in order, if the PHY is not it (compared with Linux core.c/gadget.c/ep0.c/dwc3-qcom.c as far as I know them; the sources are not in the tree, only dwc3-qcom.c):
  (a) GCC_USB30_PRIM_BCR / QUSB2 PHY BCR reset toggles (xnu never asserts the block resets; Linux does through the reset controller in probe);
  (b) GUSB3PIPECTL.DISRXDETINP3/PHYSOFTRST ordering without a QMP PHY; (c) DCTL.RUN_STOP must stay 0 until after the ep0 commands (it does, line 1003) and ABL's old
  event buffer at GEVNTADR 0x999d6000 is replaced before use (it is, 957-961); (d) GSBUSCFG0/1 (AXI burst) are not touched, correct for the first command;
  (e) DEPSTARTCFG/SETEPCONFIG parameter order matches Linux (ep0 OUT startcfg with XferRscIdx 0; ep n>1 with param 2<<16, lines 405-412, 980-984; action INIT=0/MODIFY=2 at line 721; FIFO number = ep>>1 for IN).
- Side note: the 0089/0098 comments say "DSTS speed 4 is the configured max of a USB3-capable core, not SuperSpeed". In DSTS, CONNECTSPD 4 is *high speed* (SS = 0); DCFG.DEVSPD 4 is
  SuperSpeed. Both statements the notes make are right in effect (link HS, DCFG max SS), only the DSTS wording is off.

### 2. [HIGH, latent] Cache maintenance for device DMA is a no-op in this build (sweet_smmu.c:121, sweet_usb.c:257-260, sweet_ufs.c:133-143)
- `__ARM_COHERENT_IO__` (pexpert/arm64/apple_arm64_common.h:36) makes `flush_dcache64`/`clean_dcache64` a bare `dsb sy` (osfmk/arm/caches.c:383-410, caches_asm.s:442-455); `FlushPoC_DcacheRegion` is empty on `APPLE_ARM64_ARCH_FAMILY`.
  The Qualcomm DMA masters here are not Apple's coherent fabric (the dwc3 stream, the SMMU table walker; sweet's DT: `qcom,gsi-disable-io-coherency`).
- Affected buffers: the SMMU L1 page table (written cacheable, walked with TCR IRGN/ORGN=0 non-cacheable walks => walker can read stale zeros => an
  unidentified/translation fault on the first USB DMA, which on this hypervisor resets the SoC); USB event buffer (device writes, CPU polls cacheable copy: events may never become visible),
  TRBs/setup/data (device may read stale zeros); UFS UTRD/UCD/bounce buffer (works today, so UFS evidently snoops; left opt-in).
- Fix (patch 02): `sweet_dma_sync_va()` in sweet_board.h = `dc civac` over the VA range + dsb. Used for the L1 table, `ud_sync`; UFS under `ufsdmasync=1`. Safe on coherent masters.

### 3. [MEDIUM] Page flip can tear / draw into the buffer still on the panel (SweetFramebuffer.cpp:618-629, 702-807)
- `scanTo()` queues SRC0_ADDR + CTL0 flush (0x20001 for VIG0); the MDP latches it at the next panel vsync (60 Hz => up to 16.7 ms) and then clears the flush bits (the boot probe shows `flush 0x00000000` idle).
  `present()` then picks `back = fFront==1 ? 2 : 1` without checking that the previous flush has latched. With three buffers (0 boot, 1, 2) present #3 draws into the buffer that was the front
  before present #2's `scanTo`, which is still scanned out if present #3 starts < one panel frame (+copy time) after #2: `sweetfb_hz>=~40` or `sweetfb_vsync=1`, as 0100 runs at 30 Hz with a 33 ms
  period it is safe today, but the margin is only the copy time. Fix (patch 01): `waitLatch()` polls the flush bits (<= 25 ms) before drawing.
- Same patch: the power-off path (`vsyncFired`, line 355) copied 10 MB *from the write-combined (uncached) back buffer* while holding `fLock` (100 ms+ with the WC read), blocking `swap()`/`addClient()`; the copy now runs after unlocking
  (only the timer thread touches those buffers).
- Checked OK: SRC0_ADDR is a 32-bit write of a PA < 4 GiB (checked for bufs 1/2 at line 587, not for buf 0: fPhys is 0x9d400000 here), stride `(fBootStride & 0xffff0000) | fRowBytes` correct (stride 0x10e0 in the probe),
  CTL0 flush offset 0x18 and bit 17 per Linux dpu_hw_ctl (CTL_FLUSH_MASK_CTL), `dsb sy` before the address write orders the WC frame stores. Panic hook (serial_console.c:288-291 -> sweet_fb_restore_boot_scanout, line 516) writes
  the same two registers + flush; it can race a concurrent `scanTo` on another CPU that completes afterwards (text invisible), low probability.

### 4. [MEDIUM] Out-of-bounds write in the Sandbox privilege-denial log (sweet_amfi.c:319-346)
- `priv_check_cred` -> `sweet_sandbox_priv_grant` runs concurrently on all CPUs. The slot index re-reads `sweet_priv_logged_count` after the `< SWEET_PRIV_LOG_MAX` test and `++`s non-atomically: two threads at count 63 can both pass
  the test, the second then indexes slot 64 (24 bytes past the array into the next kernel globals) -- needs the exact race at the 64th distinct (priv, process) denial, so rare but real, and lost increments cause duplicate log lines.
- Fix (patch 04): atomic slot reservation (`os_atomic_inc_orig`) and clamped scan.

### 5. [MEDIUM-LOW] AMFI-named policy op 0x60 copyout (sweet_amfi.c:383-397)
- `copyout(&state, arg, 8)` writes 8 bytes to whatever lsd passed. If userland's variable is 4 bytes, 4 bytes of the caller's stack are clobbered (user memory only; no kernel risk). `arg` is not validated (NULL -> EFAULT, fine). The ABI of op 0x60
  is not known from a header; verify against lsd's call site (size of the out variable) before changing. Not patched.

### 6. [LOW] Remaining observations (no patch)
- **SweetSurface.cpp:330** `p->bytesPerRow * sweet_div_up(...)` plane size default is 32-bit and can overflow for hostile plane info, understating `end`/`allocSize`; the lock result then tells the process a plane larger than its mapping. User-side fault only: the
  kernel's own reads (`presentScaled`/`present`) check `offset + (sy+h-1)*bytesPerRow + (sx+w)*4` against `memory->getLength()` (SweetFramebuffer.cpp:660-662, 789-793) and the clip math cannot overflow (sx/dx are clamped to >=0 and the
  sums are <= display/surface size).
- **SweetFramebuffer.cpp:577-614** `flipSetup()` leaks `fBufMap[1]` when buffer 2 fails; harmless one-shot.
- **SweetHID.cpp:190-206** `handleClose` leaves a stale client (raw pointer, unretained) in the array if the replacement `OSArray` allocation fails => UAF on the next dispatch. OOM only.
- **SweetBattery.cpp:238** rounding was "round up" instead of Linux's DIV_ROUND_CLOSEST: +1 % bias (patch 05). `InstantAmperage` (line 126) stores a negative current as UInt32; CF reads it as a large positive. Conversions (voltage raw*122070/1e6 mV, current s16*488281/1e6 mA with sign flip, SOC (msoc-1)*98/253+1) otherwise match qpnp-fg-gen3.c.
- **sweet_spmi.c** whitelist is correct (SID 2 PIDs 0x10/0x13/0x40/0x41 on beryllium); command encoding (EXT_READL = opcode 1 << 27, addr << 4), status bit0/0x0e and RDATA at +0x18 match pmic-arb v5; all array and MMIO offsets are inside the mapped windows
  (core 0x2000, cfg 0x1000, obs 0x10000 for 512 APIDs). Keys and battery use different APIDs, so sharing the observer is safe.
- **sweet_cpufreq.c** LUT parse matches qcom-cpufreq-hw v1 (src!=0: 19.2 MHz * L, src==0: 300 MHz), bounded to 40 rows inside the 0x1400 mapping; picks the highest, relies on firmware for voltage/thermal.
- **sweet_touch.c** bit-bang: open-drain emulation is right (latch cleared before output enable; release = OE off with external pull-up); start/stop/repeated-start/ACK timing and SCL stretching wait are sound at ~100 kHz. No bus recovery (9 clocks) if a slave holds SDA low after an aborted
  transfer. TLMM edge latch (INTR_CFG +8 RAW_STATUS_EN | dual edge, INTR_STATUS +0xc cleared by writing 0) is read-then-clear before the I2C read, so an edge during the read is kept; a pulse's second edge can cause one extra, harmless read (touch_report only emits changes).
  NVT record parsing matches novatek-nvt-ts.c (slot = b0>>3, type b0&7, x = b1<<4|b3>>4, y = b2<<4|b3&15, 0xff = unused); arrays are bounded by `nvt_max <= 10`.
- **sweet_ufs.c** UPIU/PRDT layout, doorbell/UTRLCLR handling and range checks on writes are correct; PRDT chunks <= 256 KiB, bounce 1 MiB fits the 4 PRDT entries. After a timeout the device could still DMA into the reused slot/bounce buffer.
- **sweet_early.c / arm_init.c** bounds are checked in `sweet_early_set_video` (block 0x9c000000+32 MiB); the status bars (stage<=20, 48 px) stay inside 1080 px.
- **USB data path** (ud_rx_done/ud_if_output): lengths are validated before the mbuf copy and the 512-multiple pad byte fits; TRB layout (bpl, bph, size, ctrl; HWO/LST/ISP_IMI/IOC; TRBCTL values) matches Linux. EP commands from the net thread and the event thread touch different DEPCMD registers.

### 7. Scaling / touch inverse map: consistent (SweetFramebuffer.cpp:243-276, 636-699 vs SweetHID.cpp:461-500, 528-539)
- fit (scale 1): scale = panel/logical on the tighter axis, pads = (panel - logical*num/den)/2 with the same truncation in both files; framebuffer maps panel px -> logical `floor((px-pad)*den/num)` (clamped), HID uses the identical formula, so a tap lands on the logical pixel that panel pixel shows (modulo sub-pixel: HID returns the
  left edge of that logical pixel, <= 1 logical px bias). Taps in the bars clamp to the nearest edge. Stretch (scale 2) uses independent axes identically. Crop (scale 0) uses `(logical - panel)/2` in both. Only difference: AppleCLCD falls back to scale 0 if `fXMap` allocation fails, HID does not (OOM only).
