# fajita (OnePlus 6T / SDM845) touchscreen: Synaptics RMI4 spec for a polled driver

Scope: bring up the S3706B/S3320 RMI4 controller on `i2c@a90000` with **no interrupts**,
feeding `sweet_hid_touch(finger, down, x, y)` with panel-native coordinates (0..1079, 0..2339).
No repo code was changed; this is the research result. Everything marked **(C)** is verified in
source/DT, **(D)** is derived, **(?)** is a guess to be measured on the device.

---

## 1. Which QUPv3 SE is 0xa90000, and the GCC numbers

### Identity

| item | value | source / confidence |
|---|---|---|
| DT node | `i2c@a90000`, `compatible = "qcom,i2c-geni"`, `reg = <0xa90000 0x4000>` | live FDT + `dtb/fajita2.dts:1787` **(C)** |
| vendor alias | `qupv3_se12_i2c = "/soc/i2c@a90000"` | `dtb/fajita2.dts:19626` **(C)** |
| GIC IRQ | `<0 0x165 0>` = SPI 357 | DT **(C)**, unused in v1 |
| wrapper (QUPv3 core 1) | `qcom,qupv3_1_geni_se@ac0000`, `reg=<0xac0000 0x6000>` | DT **(C)** |
| SE index inside wrapper | **4** (`GCC_QUPV3_WRAP1_S4_CLK`) | DT clock list **(C)** |
| global vendor index | SE12 = 8 (core 0) + 4 | alias **(C)** |
| I2C pins | gpio49 (SCL) / gpio50 (SDA), function `qup12` | live FDT pinctrl **(C)** |

`qupv3_0` = 0xac0000's sibling at 0x8c0000 owns 0x880000..0x89c000 (SE0..7);
`qupv3_1` owns 0xa80000..0xa9c000 → 0xa90000 is the **5th SE (index 4)** of core 1, which the
vendor numbering calls `se12`. The wrapper block itself (`0xac0000`) is **not touched** by a
FIFO-mode driver — Linux uses it only for the GPI-DMA path and bus-bandwidth votes.

### GENI SE register block (offsets from 0x0A90000) — from `include/linux/qcom-geni-se.h` (C)

| off | reg | use |
|---|---|---|
| 0x020 | `GENI_FORCE_DEFAULT_REG` | write 1 |
| 0x024 | `GENI_OUTPUT_CTRL` | write 0x7F |
| 0x028 | `GENI_CGC_CTRL` | `|= 0x7F` |
| 0x040 | `SE_GENI_STATUS` | bit0 `M_GENI_CMD_ACTIVE`, bit12 `S_GENI_CMD_ACTIVE` |
| 0x048 | `GENI_SER_M_CLK_CFG` | `(clk_div<<4)|1` |
| 0x068 | `GENI_FW_REVISION_RO` | bits15:8 protocol (must be **3** = I2C) |
| 0x07c | `SE_GENI_CLK_SEL` | DFS index, write 0 |
| 0x254 | `SE_GENI_BYTE_GRAN` | 0 |
| 0x258 | `SE_GENI_DMA_MODE_EN` | 0 (FIFO mode) |
| 0x260/0x264 | TX_PACKING_CFG0/1 | see §4.2 |
| 0x26c | `SE_I2C_TX_TRANS_LEN` | TX length |
| 0x270 | `SE_I2C_RX_TRANS_LEN` | RX length |
| 0x278 | `SE_I2C_SCL_COUNTERS` | `(t_high<<20)|(t_low<<10)|t_cycle` |
| 0x284/0x288 | RX_PACKING_CFG0/1 | same as TX |
| 0x600 | `SE_GENI_M_CMD0` | `(opcode<<27)|(addr<<9)|params` |
| 0x604 | `SE_GENI_M_CMD_CTRL_REG` | bit1 = abort |
| **0x610** | `SE_GENI_M_IRQ_STATUS` | polled |
| **0x614** | `SE_GENI_M_IRQ_EN` | 0 in v1 |
| **0x618** | `SE_GENI_M_IRQ_CLEAR` | write 1s to clear |
| 0x644/0x648 | S_IRQ_EN / S_IRQ_CLEAR | 0 |
| 0x700 | `SE_GENI_TX_FIFOn` | 32-bit writes |
| 0x780 | `SE_GENI_RX_FIFOn` | 32-bit reads |
| 0x800 | `SE_GENI_TX_FIFO_STATUS` | bits23:0 word count |
| 0x804 | `SE_GENI_RX_FIFO_STATUS` | bits24:0 word count |
| 0x80c/0x810/0x814 | TX_WM / RX_WM / RX_RFR_WM | 1 / 0 / rx_depth-1 |
| 0xe18 | `SE_GSI_EVENT_EN` | 0 |
| 0xe1c | `SE_IRQ_EN` | 0 (no external IRQ routing) |
| 0xe24/0xe28 | HW_PARAM_0/1 | FIFO depths (32 words each here) |
| 0xe30 | `SE_DMA_GENERAL_CFG` | `|= 0x0f` |

Note: the task listed "SE_IRQ 0x608/0x60c". The correct header values are **0x610/0x614/0x618**
(and 0x608 is not defined); the existing `sweet_touch.c` already uses 0x610 (patch 0060).

### GCC (base 0x00100000, `reg = <0x100000 0x1f0000>`, `#clock-cells = <1>`) (C)

| item | value |
|---|---|
| branch/vote reg | **0x5200c** |
| bit 20 | `GCC_QUPV3_WRAP_1_M_AHB_CLK` (id 110) |
| bit 21 | `GCC_QUPV3_WRAP_1_S_AHB_CLK` (id 111) |
| bit 22..29 | `GCC_QUPV3_WRAP1_S0..S7_CLK` → **S4 = bit 26** (id 100) |
| CBCR / halt status | **0x184d4**, bit31 `CBCR_CLK_OFF` (0 = running) |
| RCG for S4 | **0x184d8**: +0x0 CMD, +0x4 CFG, +0x8 M, +0xc N, +0x10 D |

RCG programming for 19.2 MHz (XO), as `sweet_touch.c` does and as `gcc-sdm845.c`'s
`F(19200000, P_BI_TCXO, 1, 0, 0)` entry implies:

```
CFG (0x184dc) = (CFG & ~(0x371f | BIT(20))) | 1   // SRC_SEL=0 (bi_tcxo), SRC_DIV=1 (÷1), MODE=0
CMD (0x184d8) = 0x3                                // ROOT_EN | UPDATE; poll bit0 until 0
```

Parent map is `{bi_tcxo:0, gpll0:1, gpll0_out_even:6, test:7}` — XO is mux value 0 **(C)**.
Field layout from `drivers/clk/qcom/clk-rcg2.c`: `SRC_DIV[4:0]`, `SRC_SEL[10:8]`,
`MODE[13:12]`, `HW_CLK_CTRL[20]` **(C)**.

---

## 2. TLMM: exact registers for GPIO 125 / 99 / 88 / 49 / 50

SDM845 TLMM block: `pinctrl@03400000`, `reg = <0x03400000 0xc00000>` **(C, live FDT)**.
`pinctrl-sdm845.c` places pins in quadrants **relative to that base**:

| quadrant | offset | absolute |
|---|---|---|
| NORTH | 0x00500000 | **0x03900000** |
| SOUTH | 0x00900000 | **0x03D00000** |

Per pin, stride **0x1000** (`REG_SIZE`), four registers:

| off | reg | bits |
|---|---|---|
| +0x0 | `GPIO_CFG` (ctl) | [1:0] pull, [3:2] mux, [7:5] intr target, [8:6] drive, [9] OE |
| +0x4 | `GPIO_IO` | [0] in level, [1] out level |
| +0x8 | `GPIO_INTR_CFG` | [0] en, [1] polarity, [3:2] detection, [4] raw-status en, [7:5] target (3 = APSS) |
| +0xc | `GPIO_INTR_STATUS` | [0] status, [4] raw status |

Encodings **(C)**: pull `0=none, 1=pull-down, 2=keeper, 3=pull-up` (`MSM_NO_PULL..MSM_PULL_UP`);
mux `0 = gpio`, `1 = qup12` for gpio49/50 (their funcs array is `{gpio, qup12, …}`);
drive `mA = (raw+1)*2` → raw 0=2 mA, 3=8 mA, 7=16 mA.

### Per-pin values

| pin | role | quadrant | CFG addr | IO addr | CFG value | notes |
|---|---|---|---|---|---|---|
| 125 | ATTN (input, unused as IRQ) | NORTH | **0x0397d000** | 0x0397d004 | **0x1c3** | mux0, pull-up, 16 mA, OE=0 |
| 99 | RESET (output) | NORTH | **0x03963000** | 0x03963004 | **0x2c3** | mux0, pull-up, 8 mA, OE=1; level via IO bit1 |
| 88 | VIO 1.8 V enable (output) | **SOUTH** | **0x03d58000** | 0x03d58004 | **0x2c0** | mux0, no pull, 8 mA, OE=1 |
| 49 | I2C SCL (`qup12`) | NORTH | 0x03931000 | 0x03931004 | 0x004 | mux1, 2 mA, no pull (do not touch if ABL already did) |
| 50 | I2C SDA (`qup12`) | NORTH | 0x03932000 | 0x03932004 | 0x004 | same |

**Trap:** the existing sweet driver maps TLMM at `0x03900000` — that is NORTH only. GPIO 88 is in
SOUTH; poking 0x03958000 instead of 0x03d58000 silently writes a different pin (VIO never comes up).

Order for an output: set `GPIO_IO` bit1 first, then set `GPIO_CFG` with OE=1 (avoids a glitch),
exactly like `touch_gpio()` in patch 0060.

**Pin-number discrepancy, resolved:** the vendor `pmx_ts_int_active` pinctrl group in the live DTB
muxes `gpio122`, while both `synaptics,irq-gpio` and `interrupts` say **125**. Mainline
(`sdm845-oneplus-common.dtsi`, `ts_default_pins`) uses **gpio99 + gpio125**, so 125 is correct and
the vendor pinctrl node is stale (it is shared with enchilada). Pin 122's config is irrelevant
because we drive nothing through the IRQ line in v1.

---

## 3. Power: PM8998 LDO28 + GPIO 88

Verified from the vendor DTS *and* from mainline's fajita DTS:

| rail | node | identifier | value |
|---|---|---|---|
| VDD (touch analog) | `/soc/rpmh-regulator-ldoa28/regulator-l28` | `qcom,resource-name = "ldoa28"`, `regulator-name = "pm8998_l28"`, type `pmic4-ldo` | min 2856000 µV, max **3008000 µV**, init 2856000 µV, `qcom,set = 3`, init-mode 2 (LPM) |
| VIO 1.8 V | `ts_1p8_supply` = `regulator-fixed` on **TLMM gpio88**, `enable-active-high` | — | 1800000 µV |
| I2C pull-up rail | `vcc_i2c_1v8` is commented out in the vendor DT | — | assume always on |

**(C)** `vdd_2v8-supply` in the live FDT resolves to the l28 node, and mainline names it
`vreg_l28a_3p0` with exactly 2856000..3008000 µV and `RPMH_REGULATOR_MODE_HPM`.

RPMh encoding (`drivers/regulator/rpmh-regulator.c`) **(C)**:

| property | value |
|---|---|
| resource offsets | voltage **+0** (unit = **mV**), enable **+4**, mode **+8** |
| PMIC4 LDO raw modes | RET 4, LPM 5, **HPM 7** (PMIC5 LDO HPM is also 7) |
| set/TCS | vote only the ACTIVE set (as `sweet_rpmh.c` already does) |

So: extend `sweet_rpmh_vreg_enable()` to accept `"ldoa28"` with mV in `[2856, 3008]` and vote
**3008 mV, mode 7, enable 1**. `sweet_rpmh.c` already resolves the resource through cmd-db, so no
hardcoded address is needed; the only change is the guard at the top of
`sweet_rpmh_vreg_enable()` (`strcmp(res,"ldoc11")` + 2950..3400 mV) — keep the "one resource per
board" policy, just change it to `ldoa28` / 2856..3008.

**Differences vs sweet:** sweet voted `ldoc11` (PM6150L, PMIC5 LDO, 3200 mV). fajita needs
`ldoa28` (PM8998, PMIC4 LDO, 3008 mV). Raw mode 7 is HPM on both, and the voltage unit is mV on
both, so the payload format is unchanged. The VIO rail is *not* a PMIC regulator on fajita — it is
the GPIO 88 load switch (on sweet it was a PMIC GPIO).

Power-on order (vendor `tpd_hw_pwron()`, mainline `syna,*delay-ms`):

```
vote ldoa28 3008 mV/mode7/en       (wait for TCS completion)
delay ~10 ms
gpio88 = 1                          (VIO on)
delay ~10 ms
gpio99 = 1 ; delay 10 ms ; gpio99 = 0 ; delay 10 ms ; gpio99 = 1   (reset pulse)
delay 100..200 ms                   (mainline: syna,startup-delay-ms = 200,
                                     syna,reset-delay-ms = 200)
first I2C access
```

---

## 4. Synaptics RMI4 over I2C, polled

### 4.1 Transport

* 7-bit address **0x20**.
* Register addressing used by *both* working drivers for this panel (vendor
  `synaptics_driver_s3320.c` and mainline `rmi_i2c.c`): **1-byte register address**,
  `START addr [A] RESTART data… [NAK] STOP`. Page select = write `0x00` to register `0xFF`
  (only page 0 is needed). The 2-byte MSB-first address form also exists in the RMI4 spec but is
  not what these drivers use here — don't complicate GENI with 3-byte writes.
* So every access is ≤2 TX bytes + N RX bytes: one `touch_msg_run()` call with `stretch=1` for the
  address byte, followed by one with opcode 2 for the data. That is exactly the shape
  `sweet_touch.c` already implements (3-byte TX limit, 90-byte RX limit).

### 4.2 GENI FIFO specifics that matter

* **Packing.** Left unconfigured by ABL you get the byte-swapped-register-address bug that cost
  time on sweet. Program, and read back, the known-good constants from patch 0063:
  `0x254 = 0`, `0x260 = 0x0007f8fe`, `0x264 = 0x000ffefe`, `0x284 = 0x0007f8fe`,
  `0x288 = 0x000ffefe`. This means: 4 × 8-bit bytes per 32-bit FIFO word, transmitted
  **LSB byte first**, each byte MSB first. So a word is built as
  `b0 | b1<<8 | b2<<16 | b3<<24` — `b0` is the first byte on the wire. (The sweet bug was building
  it as `b0<<24 | …`, which put the register address out reversed.)
* **Clock.** `SE_GENI_CLK_SEL(0x07c) = 0`; `GENI_SER_M_CLK_CFG(0x048) = (clk_div<<4)|1`;
  `SE_I2C_SCL_COUNTERS(0x278) = (t_high<<20)|(t_low<<10)|t_cycle`.
  Vendor table (`i2c-qcom-geni.c`): 100 kHz = `clk_div 7 / 10 / 11 / 26`; 400 kHz = `2 / 5 / 12 / 24`;
  1 MHz = `1 / 3 / 9 / 18`.
  With a 19.2 MHz SE clock these give ≈105 kHz / 400 kHz / 1.07 MHz if
  `SCL = SEclk / (clk_div * t_cycle)`, or ≈92/266/1066 kHz if the divider is `clk_div+1`.
  Start at **100 kHz** for bring-up, then switch to 400 kHz.
* **Write transfer:** `TX_TRANS_LEN = n`, `M_CMD0 = (1<<27) | (0x20<<9) | (stretch?4:0)`,
  `TX_WM(0x80c) = 1`, poll `M_IRQ_STATUS` bit30 (`M_TX_FIFO_WATERMARK_EN`), write one word to
  `0x700`, clear `TX_WM`.
* **Read transfer:** `RX_TRANS_LEN = n`, `M_CMD0 = (2<<27) | (0x20<<9)`, then drain
  `RX_FIFO_STATUS & 0x1ffffff` words from `0x780` until `DONE`; bytes come out
  `word>>(8*p)` for p=0..3, which matches the LSB-first packing.
* **Status bits to poll** (`M_IRQ_STATUS` 0x610): `bit0 DONE`, `bit1 OVERRUN`, `bit2 ILLEGAL_CMD`,
  `bit3 FAILURE`, `bit10 GP_IRQ_1 = NACK`. Write observed bits back to `0x618`.
* **Idle/abort:** require `SE_GENI_STATUS(0x040) & 1 == 0` before a new command; if stuck,
  `M_CMD_CTRL(0x604) = 2` (abort) and drain FIFOs.
* **Preconditions** (from sweet, proven): `SE_FW(0x068) >>8 == 3`, `GENI_IF_FIFO_DISABLE_RO(0x064)
  bit0 == 0`, TX/RX FIFO depth 32 (`HW_PARAM` bits29:24), `SE_IRQ_EN(0xe1c) = 0`,
  `SE_GENI_M_IRQ_EN(0x614) = 0` (pure polling), `GENI_OUTPUT_CTRL(0x024) = 0x7f`,
  `FORCE_DEFAULT(0x020) = 1`, `CGC_CTRL(0x028) |= 0x7f`, `DMA_GENERAL_CFG(0xe30) |= 0x0f`,
  `DMA_MODE_EN(0x258) = 0`, `GSI_EVENT_EN(0xe18) = 0`.

### 4.3 PDT (function descriptor table)

Entries are **6 bytes**, scanned **downward from 0x00E9** in steps of 6 (`0xE9, 0xE3, 0xDD, 0xD7 …`),
stopping at the entry whose function number is 0 (**C**, `rmi_driver.c` `PDT_START_SCAN_LOCATION
0x00E9`, `PDT_ENTRY_SIZE 6`).

| entry byte | register (for the entry at `A`) | meaning |
|---|---|---|
| 0 | `A+0` | query base |
| 1 | `A+1` | command base |
| 2 | `A+2` | control base |
| 3 | `A+3` | data base |
| 4 | `A+4` | bits[3:0] interrupt-source count, bits[7:5] version |
| 5 | `A+5` | function number |

The "0x00E3/0x00E4" in the task are the *query/command base bytes of the F01 entry* — note F01 is
**not** the topmost entry on this panel. Upstream's quirk table for this exact panel
(`rmi_s3706_fallback_pdt`, OnePlus 6/6T series, merged for 6.19) is
`{0x34,0x41, 0x01,0x01, 0x12,0x01}` = `(fn, byte4)` for 0xE9, 0xE3, 0xDD:

| addr | function | intr sources | version | comment |
|---|---|---|---|---|
| 0xE9 | **0x34** (flash/FW update) | 1 | 2 | IRQ status bit 0 |
| 0xE3 | **0x01** (device control) | 1 | 0 | IRQ bit 1 |
| 0xDD | **0x12** (2D sensor) | 1 | 0 | IRQ bit 2 = **0x04** |
| 0xD7 | 0x00 | — | — | end of table |

Bases (`buf[0..3]`) must still be read from the device — they are IC-specific. Extra
confidence: the OnePlus vendor driver hardcodes exactly `0xDD → F12`, `0xE3 → F01`, `0xE9 → F34`,
so the entry order is confirmed twice over. Because these are cheap "minimal" ICs that only
implement registers the vendor driver reads, keep every access to what is listed below.

### 4.4 F01 (device control / IRQ)

| reg | meaning |
|---|---|
| query + 0x00 | RMI protocol/manufacturer; product ID string = **query+0x10**, 10 bytes ASCII; product info **query+0x1e**, 2 bytes (`rmi_f01.c`) |
| command + 0x00 | write **0x01** = device reset (100 ms) |
| control + 0x00 | bit7 configured, bits[2:0] sleep mode (0 = normal), bit2 NOSLEEP |
| control + 0x01 | interrupt enable mask (write **0x7f**) |
| data + 0x00 | device status: bit7 unconfigured, bit6 bootloader |
| data + 0x01.. | interrupt status, one byte per ≤8 IRQ sources; **read clears** |

Init: write control+0 = **0x84** (configured + nosleep, mode normal) [mainline writes nosleep via
`syna,nosleep-mode`; the vendor only writes 0x80 — either works], then control+1 = 0x7f, then read
data+0…data+1 to clear stale IRQs.

Per-frame poll (2 bytes at data base): `status = b0`, `irq = b1`.
* `irq & 0x04` → read and parse F12 (bit 2, from the PDT order above).
* `status & 0x80` → device re-initialised itself: rewrite control+0 = 0x84 and re-enable.
* `irq & 0x01` (vendor: "spontaneous reset") → release all fingers, re-init if status bit7 set.
* `irq & 0x10` → vendor's virtual keys (F1A, not in the PDT here); ignore in v1.

### 4.5 F12 (2D sensor) report layout

`rmi_f12.c`: `F12_DATA1_BYTES_PER_OBJ = 8`; upstream's hardcoded descriptor for these ICs is
`reg_size = 80`, `num_subpackets = 10`, `data1_offset = 0`, `pkt_size = 88`.

Read **88 bytes** (multiple of 4 — these aftermarket ICs penalise unaligned reads) from the F12
**data base**, then, per finger i (0..9), record at `buf[8*i]`:

| byte | field | notes |
|---|---|---|
| +0 | type/status | 1 finger, 2 stylus, 3 palm; **0 = no object** (upstream uses it directly as `switch`) |
| +1 | X low | |
| +2 | X high nibble | `x = ((b2 & 0x0f) << 8) | b1` (12-bit) |
| +3 | Y low | |
| +4 | Y high nibble | `y = ((b4 & 0x0f) << 8) | b3` |
| +5 | Z (pressure) | 0..255 |
| +6 | Wx | touch major |
| +7 | Wy | touch minor |

Skip the vendor's extra "object attention" read at absolute `0x0C` (their
`F12_2D_DATA15 = 0x0C`); with objects at `data_base+0` a 2-byte read at 0x0C cannot be a presence
bitmap, and the per-object status byte already says who is present. If a first touch session
produces zero objects on every report while `irq & 0x04` keeps firing, log the raw 96 bytes and
re-derive — that is the only piece of the layout I would not bet the port on.

### 4.6 Coordinates → `sweet_hid_touch()`

`SweetHIDTouch` (patch 0061) expects **panel-native** pixels: it adds `fOffX=(1125-1080)/2=22`,
`fOffY=(2436-2340)/2=48` and divides by 1125/2436, i.e. the 1080×2340 panel is centred unscaled in
the 1125×2436 iOS display. So the driver must hand over `0..1079 × 0..2339`.

```
x_panel = clamp(x_raw * 1080 / X_RAW, 0, 1079)
y_panel = clamp(y_raw * 2340 / Y_RAW, 0, 2339)
```

`X_RAW` is almost certainly 1080 (mainline clips x at 1079 and does no scaling). `Y_RAW` is the open
question: the vendor DT says `synaptics,display-coords = <1080 2160>` (which the vendor driver never
uses — it is vestigial), so the sensor may report 0..2159 and need a 2340/2160 = 1.0833 scale.
Make both raw maxima boot-args (`sweetts_xraw`, `sweetts_yraw`, defaults 1080/2340) and log the
observed raw min/max once per second so one swipe to each corner settles it.

No axis inversion for fajita (the vendor applies `1079-x / 1919-y` only for the 15811 panel,
`s3508==0`). Finger identity: index i in the F12 record is stable enough; mirror sweet's
`touch_report(mask,x,y)` helper (call `sweet_hid_touch(i,1,x,y)` on change, `(i,0,x,y)` on release).

---

## 5. Probe sequence (polled, no GIC)

```
 0. map GCC 0x100000 (+0x60000), TLMM NORTH 0x03900000 (+0x5b000), TLMM SOUTH 0x03d00000 (+0x10000),
    SE 0x0a90000 (+0x4000); bail out loudly on any NULL
 1. RPMh: ldoa28 = 3008 mV, mode 7, enable 1        -> log TCS done + resource addr
 2. tlmm_out(88, 1)                                 -> 10 ms
 3. tlmm_out(99, 1); 10 ms; tlmm_out(99, 0); 10 ms; tlmm_out(99, 1)
 4. 100..200 ms
 5. clock vote: 0x5200c |= BIT(20)|BIT(21)|BIT(26); RCG 0x184d8/0x184dc as in §1;
    poll 0x184d4 bit31 == 0 (running). Log vote/CFG/CBCR values.
 6. SE sanity: FW(0x068) proto==3, version; HW_PARAM_0/1 FIFO depths; STATUS not busy;
    drain/clear FIFOs; program packing + timings at 100 kHz; write IRQ_EN=0, M_IRQ_EN=0.
 7. probe: write 0xFF page 0; read 2 bytes at 0x00E9 (F34 entry)
      - if fn == 0 -> aftermarket IC: use fallback pairs {0x34/0x41, 0x01/0x01, 0x12/0x01}
      - else parse the real table; in both cases take bases from buf[0..3]
    Example log: "SWEET TS: pdt 0xE9 fn=0x34 q=.. c=.. ctl=.. d=.. int=1 v=2"
 8. F01 soft reset: write 0x01 to F01 command base; 100 ms
 9. re-scan PDT (bases can move after reset), then:
      product ID = 10 bytes at F01 query+0x10 -> print as ASCII
      F01 control0 = 0x84, control1 = 0x7f, read data0/data1 to clear
10. dump 32 bytes of F12 query and 16 bytes of F12 control once (for the log), then start the loop
11. loop every 4 ms (400 kHz) / 10 ms (100 kHz):
      read 2 bytes at F01 data base
      if status & 0x80 -> re-init (step 9)
      if irq & 0x04   -> read 88 bytes at F12 data base, parse, report, log every 100th report
      if a transfer fails twice in a row -> full re-init, and after 3 failures mark dead
```

Suggested log lines (so the panel/persistent log alone tells the story):

```
SWEET TS: gcc vote=.. rcg=.. cfg=.. cbcr=..            (clock state)
SWEET TS: se fw=0x.. proto=3 status=.. tx=.. rx=..     (SE sanity)
SWEET TS: pdt 0xE9 fn=0x34 ... / 0xE3 fn=0x01 ... / 0xDD fn=0x12 data=0x..  (bases!)
SWEET TS: product id "S3706B..."  f01 q=.. c=.. ctl=.. d=..
SWEET TS: f12 query: .. .. .. (32 bytes)  ctrl: (16 bytes)
SWEET TS: first report irq=0x04 raw[0..7]=.. .. ..      (proves layout)
SWEET TS: finger0 x=123 y=456 z=30 -> 102 355        (raw -> panel)
SWEET TS: raw max x=1079 y=2159 (1 s summary)          (settles X_RAW/Y_RAW)
SWEET TS: nack at reg 0x.. ; re-init  /  SWEET TS: dead after 3 errors
```

Keep the delayed start (`sweettouchdelay`, default 45 s in sweet): if the I2C or MMIO access hangs
the SoC, the log and the GUI are already up.

---

## 6. Confidence ledger

**Certain (source/DT-verified)**

* `i2c@a90000` = QUPv3 core 1 (`0xac0000`), SE index 4, vendor alias `qupv3_se12`, GIC SPI 357.
* GCC vote reg `0x5200c`, bits 20/21/26; CBCR `0x184d4` bit31; RCG `0x184d8` (+0/+4/+8/+0xc/+0x10);
  XO parent = mux 0, config `CFG = …|1`, `CMD = 3`.
* TLMM `0x03400000`, NORTH `+0x500000`, SOUTH `+0x900000`, stride `0x1000`,
  regs `+0/+4/+8/+0xc`, pull/mux/drive/OE encodings, per-pin addresses and CTL values in §2.
* Touch pins: IRQ 125, reset 99, VIO enable 88, I2C 49/50 (function `qup12`).
* VDD = RPMh `ldoa28` (PM8998 LDO28, pmic4-ldo, 2856..3008 mV); VIO = fixed 1.8 V on GPIO 88.
* RPMh resource offsets voltage/enable/mode = +0/+4/+8, voltage unit mV, HPM raw 7 on PMIC4 LDO.
* RMI4: addr 0x20, 1-byte addressing + 0xFF page; PDT at 0xE9 step −6, 6-byte entries, fields as
  tabulated; this panel's entry order F34/F01/F12 at 0xE9/0xE3/0xDD and the fallback byte pairs.
* F12 objects: 8 bytes each at data base + 0, 10 objects, field order status/X/Y/Z/Wx/Wy, 12-bit
  X/Y; F01 control/data semantics; GENI register map, packing constants, SCL tables, IRQ status bits.
* `sweet_hid_touch` wants panel-native 1080×2340.

**Derived (consistent with two independent sources, but not read off a datasheet)**

* `SCL = SEclk / (clk_div * t_cycle)` at 19.2 MHz (the vendor table fits exactly);
  the alternative `clk_div+1` reading is also safe — either way ≤400 kHz.
* RCG `SRC_DIV = 1` means ÷1 for the XO parent (that is what the freq table and sweet's working
  code both do).
* PDT interrupt-bit assignment: F34→bit0, F01→bit1, F12→bit2 (matches the vendor's `0x04` test);
  confirm by logging all status bits.
* Drive strength `mA = (raw+1)*2` (from `msm_regval_to_drive`), pull encodings from
  `MSM_*` defines.

**Unknown / measure on the device**

* Actual F01/F12 base values (printed by step 7/9).
* F12 `Y_RAW` (2160 vs 2340) and whether any offset/axis inversion is needed.
* Whether the vendor's absolute-0x0C "object attention" read is meaningful at all (we bypass it).
* Whether the panel needs F12 control writes (dribble/report-rate); mainline touches them, the
  vendor driver does not — start without, add only if reports are missing.
* The 2-byte MSB-first register address form (untested here; 1-byte works in two drivers).

---

## 7. Delta list vs `bsd/dev/sweet_touch.c` (patch 0060 + 0063)

1. `TOUCH_SE_PA 0x0a84000 → 0x0a90000`.
2. `TOUCH_NORTH_PA 0x03900000` stays for GPIO 99/125; add a **SOUTH** mapping `0x03d00000` for GPIO 88.
3. `TOUCH_GCC_VOTE` mask: `(0x0f << 18) | (1 << 23)` (wrap1 SE0..3 + SE7) →
   `(1 << 20) | (1 << 21) | (1 << 26)` (m-ahb, s-ahb, SE4).
4. `TOUCH_RCG` → `0x184d8` (was SE7's RCG); CFG/CMD writes unchanged in shape.
5. New: `sweet_rpmh_vreg_enable("ldoa28", 3008)`; drop the "L11C must be powered by firmware" note.
6. New: GPIO 88 high (VIO), reset on 99, ATTN on 125 configured as input with pull-up (never used).
7. Replace the Goodix GT9896 protocol block with RMI4: probe (PDT/product id/F01 init) + the
   polled frame loop of §5; keep `touch_msg_run()`, `touch_irq()`, `touch_report()` and the
   packing/timing code as they are.
8. Keep the 88-byte F12 read inside the existing 90-byte RX limit.

---

## 8. Sources

Vendor / LineageOS 22.2 kernel (OnePlus sdm845), branch `lineage-22.2`:
* `drivers/clk/qcom/gcc-sdm845.c` — https://github.com/LineageOS/android_kernel_oneplus_sdm845/blob/lineage-22.2/drivers/clk/qcom/gcc-sdm845.c
  (branch enables 0x5200c bits, RCG 0x184d8, parent map, 19.2 MHz table)
* `include/dt-bindings/clock/qcom,gcc-sdm845.h` — clock IDs 100/101/110/111
* `drivers/i2c/busses/i2c-qcom-geni.c` — clk map, SCL counters, cmd encoding, FIFO/IRQ handling
* `drivers/platform/msm/qcom-geni-se.c` + `include/linux/qcom-geni-se.h` — register map, packing
* `drivers/pinctrl/qcom/pinctrl-sdm845.c` / `pinctrl-msm.c` — TLMM quadrants, per-pin regs, bit fields
* `drivers/regulator/rpmh-regulator.c` — resource offsets, PMIC4 LDO modes, mV unit
* `arch/arm64/boot/dts/qcom/sdm845-qupv3.dtsi` — `qupv3_se12_i2c` clock/reg binding
* `arch/arm64/boot/dts/qcom/fajita.dtsi` — `synaptics-rmi-ts@20` node (gpio 125/99/88, l28, coords)
* `drivers/input/touchscreen/synaptics_driver_s3320.c` — vendor RMI4 sequence (power, reset,
  PDT hardcodes 0xDD/0xE3/0xE9, F01 ctrl/data, 8-byte objects, F12 data base)

Mainline:
* `drivers/input/rmi4/rmi_driver.c`, `rmi_f01.c`, `rmi_f12.c`, `rmi_i2c.c` — PDT scan (0xE9, 6),
  F01 query/product id, 8-byte objects / 88-byte packet, 1-byte I2C addressing + 0xFF page
  (https://codebrowser.dev/linux/linux/drivers/input/rmi4/rmi_f12.c.html)
* `Documentation/devicetree/bindings/input/syna,rmi4.yaml` — `syna,*` properties
  (there is **no** upstream `synaptics-rmi4.rst`; rmi4 has only DT bindings and code comments)
* `arch/arm64/boot/dts/qcom/sdm845-oneplus-common.dtsi` (+ `sdm845-oneplus-fajita.dts`) — the
  authoritative modern fajita touch node: `syna,rmi4-s3706b`, IRQ gpio125 edge-falling,
  `vreg_l28a_3p0` 2856..3008 mV HPM, `ts_1p8_supply` = fixed regulator on gpio88,
  `ts_default_pins` = gpio99+gpio125 gpio/pull-up/16 mA, 400 kHz, `syna,clip-x-high = <1079>`
* postmarketOS RMI4 quirks for OnePlus 6/6T (s3706b fallback PDT + hardcoded F12 descriptor):
  https://lore.kernel.org/all/20260324-synaptics-rmi4-v9-0-2168d2df68f5@ixit.cz/
  branch: https://codeberg.org/sdm845/linux/commits/b4/synaptics-rmi4
  (`rmi_s3706_fallback_pdt[] = {0x34,0x41,0x01,0x01,0x12,0x01}`, `pkt_size = 88`,
  `reg_size = 80`, `num_subpackets = 10`, `data1_offset = 0`)
