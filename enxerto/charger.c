/*
 * Early fast charging, see charger.h. Port of xnu/patches-11215/0201 (bsd/dev/sweet_charger.c, sweetcharger=2)
 * to Enxerto's polled SPMI (pmic.c). Register map (PMI8998 SID 2, SMB2 block on the 0x1000 base):
 *   CHGR  0x1006 STATUS_1 [2:0] state   0x1007 STATUS_2 hot/cold/soft/OV/safety bits   0x100d STATUS_7 ADC temp
 *         0x1042 CHARGING_ENABLE_CMD    0x1061 FAST_CHARGE_CURRENT_CFG (25 mA/LSB)
 *         0x1070 FLOAT_VOLTAGE_CFG (3487.5 mV + 7.5 mV/LSB)    0x1090 JEITA_EN_CFG (read only)
 *   USBIN 0x130b TYPE_C_STATUS_1 [7] UFP Rp default (USB 500/900) [6] Rp 1.5 A [5] Rp 3.0 A [4:0] FMB/open (smb-reg.h)
 *         0x130e TYPE_C_STATUS_4 [7] DFP mode [6] VBUS [5] VBUS error [4] debounce done [3] audio adapter [0] CC attached
 *         0x1307 APSD_STATUS [0] done   0x1308 APSD_RESULT [0] SDP [1] OCP [2] CDP [3] DCP [4] float [5] QC2 [6] QC3
 *         0x1310 INT_RT_STS [4] plugged  0x1340 USBIN_CMD_IL [0] suspend  0x1365 USBIN_LOAD_CFG [4] ICL override after APSD
 *         0x1366 USBIN_ICL_OPTIONS [0] use USBIN_CURRENT_LIMIT_CFG  0x1370 USBIN_CURRENT_LIMIT_CFG (25 mA/LSB)
 *         0x1380 AICL options [2] AICL_EN (read only)
 *   MISC  0x1607 ICL_STATUS (limit in force)  0x160b POWER_PATH_STATUS
 * ICL sequence = downstream smblib_set_icl_current(): current, USBIN_MODE_CHG, ICL_OVERRIDE_AFTER_APSD, un-suspend.
 *
 * Kernel hand-off assumption (checked against 0201): sc_control() never assumes power-on defaults when it
 * programs (it reads, then writes whatever differs), but it snapshots ICL cfg / ICL options / load cfg / FCC
 * the first time it writes and gives THOSE back on unplug, a new APSD result or a temperature fault. If Enxerto
 * left its own ICL override in place that snapshot would be Enxerto's, and the kernel's "restore" would then
 * park e.g. a 2000 mA override on a later SDP port. So by default charger_handoff() puts the registers back
 * to what Enxerto found before the jump (the kernel then sees the ABL state it has always seen and ramps up
 * itself ~20 s after it starts); "bergamota.charger=keep" skips that.
 *
 * No static pointer tables (build.sh rejects ABS64 relocations); MMU off or on, only pmic.c's Device MMIO.
 */
#include "charger.h"
#include "fdt.h"
#include "pmic.h"

#ifndef ENXERTO_CHARGER
#define ENXERTO_CHARGER	1
#endif

#if ENXERTO_CHARGER

#define CHG_ICL_DCP_MA		2000u
#define CHG_ICL_CDP_MA		1500u
#define CHG_ICL_HVDCP_MA	1500u
#define CHG_ICL_OCP_MA		1800u	/* OCP (= DCP downstream), Rp not 3.0 A */
#define CHG_ICL_FLOAT_MA	1000u
#define CHG_ICL_RP30_MA		2000u	/* Type-C Rp 3.0 A, our DCP cap (AICL stays on and backs off a weak source) */
#define CHG_ICL_NO_AICL_MA	1500u	/* AICL off: no automatic back-off from a weak adapter */
#ifndef CHARGER_FCC_MA
#define CHG_FCC_MA		2000u	/* the kernel's default: 0.5 C of 4000 mAh, DTS has no constant-charge-current-max */
#else
#define CHG_FCC_MA		(CHARGER_FCC_MA)
#endif
#define CHG_FV_RAW_MAX		121u	/* 3487.5 mV + 121 * 7.5 mV = 4395 mV <= voltage-max-design 4.4 V */
#define CHG_STEP_MA		25u
#define CHG_TICK_MS		5000u
#define CHG_DEBOUNCE_US		20000u
#define CHG_BAD_MAX		5u
#define CHG_FAIL_MAX		6u

#define R_STATUS1	0x1006u
#define R_STATUS2	0x1007u
#define R_STATUS7	0x100du
#define R_CHG_EN	0x1042u
#define R_FCC		0x1061u
#define R_FV		0x1070u
#define R_JEITA_EN	0x1090u
#define R_APSD_STATUS	0x1307u
#define R_APSD_RESULT	0x1308u
#define R_TYPEC1	0x130bu
#define R_TYPEC4	0x130eu
#define R_RT_STS	0x1310u
#define R_CMD_IL	0x1340u
#define R_LOAD_CFG	0x1365u
#define R_ICL_OPTIONS	0x1366u
#define R_ICL_CFG	0x1370u
#define R_AICL_OPTIONS	0x1380u
#define R_ICL_STATUS	0x1607u

#define APSD_QC3	0x40u
#define APSD_QC2	0x20u
#define APSD_FLOAT	0x10u
#define APSD_DCP	0x08u
#define APSD_CDP	0x04u
#define APSD_OCP	0x02u
#define APSD_SDP	0x01u

enum { MODE_OFF, MODE_ON, MODE_KEEP };
enum { CTL_OFF, CTL_RO, CTL_IDLE, CTL_WAIT, CTL_HOLD, CTL_APPLIED, CTL_FAILED, CTL_SPMI };

struct snap {
	int core_ok;
	uint8_t typec1, typec4;
	uint8_t st1, st2, st7, chg_en, fcc, fv, jeita, apsd_st, apsd_res, rt, cmd_il, load, icl_opt, icl_cfg, aicl_opt, icl_stat;
	int have_icl_stat, have_jeita;
};

static struct {
	int mode, ready, ctl;
	int failed;
	int saved;
	uint8_t o_icl, o_opt, o_load, o_fcc;	/* registers before our first write */
	int applied;
	uint16_t applied_key;
	uint8_t applied_icl_raw, applied_fcc_raw;
	unsigned bad, writes, write_fails, applies, restores;
	uint64_t last_ms;
	int ticked;
	struct snap s;
	struct pmic_batt b;
} cs;

static uint64_t ms_now(void)
{
	uint64_t t, f;

	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t) : : "memory");
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	return t / (f / 1000);
}

static void udelay(unsigned us)
{
	uint64_t f, t;

	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	uint64_t end = t + f / 1000000 * us;
	do
		__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(t));
	while (t < end);
}

/* ---- read side ---- */

static void sample(struct snap *s)
{
	uint8_t d;

	*s = (struct snap){ 0 };
	s->core_ok = 1;
#define RD(reg, field) do { if (pmic_chg_read(reg, &d)) s->core_ok = 0; else s->field = d; } while (0)
	RD(R_STATUS1, st1);
	RD(R_STATUS2, st2);
	RD(R_STATUS7, st7);
	RD(R_CHG_EN, chg_en);
	RD(R_FCC, fcc);
	RD(R_FV, fv);
	RD(R_APSD_STATUS, apsd_st);
	RD(R_APSD_RESULT, apsd_res);
	RD(R_RT_STS, rt);
	RD(R_CMD_IL, cmd_il);
	RD(R_LOAD_CFG, load);
	RD(R_ICL_OPTIONS, icl_opt);
	RD(R_ICL_CFG, icl_cfg);
	RD(R_AICL_OPTIONS, aicl_opt);
#undef RD
	if (!pmic_chg_read(R_TYPEC1, &d))
		s->typec1 = d;
	if (!pmic_chg_read(R_TYPEC4, &d))
		s->typec4 = d;
	if (!pmic_chg_read(R_ICL_STATUS, &d)) {
		s->icl_stat = d;
		s->have_icl_stat = 1;
	}
	if (!pmic_chg_read(R_JEITA_EN, &d)) {
		s->jeita = d;
		s->have_jeita = 1;
	}
}

/*
 * Too hot / too cold: no raising, give back what we changed. The JEITA soft limits (warm, cool)
 * are not a reason to hold: the charger's own JEITA compensation already lowers FCC/FV there (as Linux smb2 lets it), and
 * this phone's thermistor sits in the warm zone while charging, which kept every charge at 500 mA. Battery OV (STATUS_2
 * bit 5) is not one either: in the warm zone the compensated FV is below the battery, the charger flags OV and stops
 * charging by itself, and holding the input at 500 mA only drained the battery under load (kernel 0225 likewise).
 * An expired safety timer (bit 6) neither: the charger stops by itself, the input only feeds the system (kernel 0226).
 */
static int unsafe(const struct snap *s)
{
	return (s->st2 & 0x03u) != 0 || (s->st7 & 0x0cu) != 0;
}

/*
 * Type-C Rp the source advertises (TYPE_C_STATUS_1 [7:5]): 0 = none/invalid, 1 = default USB, 2 = 1.5 A, 3 = 3.0 A.
 * Valid only for an attached UFP with VBUS, debounce done, no VBUS error and no audio adapter, and exactly one Rp bit.
 * No PD stack here: the source stays at 5 V, Rp is only the current it promises at 5 V.
 */
static unsigned typec_rp(const struct snap *s)
{
	uint8_t t4 = s->typec4, t1 = s->typec1 & 0xe0u;

	if (!(t4 & 0x01u) || (t4 & 0x80u) || !(t4 & 0x40u) || !(t4 & 0x10u) || (t4 & 0x28u))
		return 0;
	if (t1 == 0x80u)
		return 1;
	if (t1 == 0x40u)
		return 2;
	if (t1 == 0x20u)
		return 3;
	return 0;
}

/*
 * Input current limit (mA) for the source; 0 = leave the hardware alone (SDP stays 500/900 mA, unknown too).
 * Policy after downstream smb-lib.c / mainline qcom_smbx.c: OCP is treated as DCP (a USB-C charger often
 * classifies as OCP): Rp 3.0 A -> our cap, else 1800 mA (downstream DCP_CURRENT_UA; 1500 mA when AICL is off,
 * see the cap in control()); FLOAT 1000 mA (downstream FLOAT_CHARGER_UA); DCP 2000, CDP 1500, QC2/QC3 1500.
 */
static unsigned icl_for(const struct snap *s)
{
	uint8_t res = s->apsd_res & 0x7fu;

	if (res & (APSD_QC3 | APSD_QC2))
		return CHG_ICL_HVDCP_MA;
	if (res & APSD_DCP)
		return CHG_ICL_DCP_MA;
	if (res & APSD_CDP)
		return CHG_ICL_CDP_MA;
	if (res & APSD_OCP)
		return typec_rp(s) == 3 ? CHG_ICL_RP30_MA : CHG_ICL_OCP_MA;
	if (res & APSD_FLOAT)
		return CHG_ICL_FLOAT_MA;
	return 0;
}

/* ---- write side: every write read back; the cache copy only moves on success ---- */

static int set(unsigned addr, uint8_t *cache, uint8_t want)
{
	if (*cache == want)
		return 0;
	cs.writes++;
	if (pmic_chg_write(addr, want)) {
		cs.write_fails++;
		return -1;
	}
	*cache = want;
	return 1;
}

/* Put back what we changed: never above the original, never above what we set (lower the current first). */
static void restore(struct snap *s)
{
	if (!cs.applied || !cs.saved) {
		cs.applied = 0;
		return;
	}
	uint8_t icl = cs.o_icl < cs.applied_icl_raw ? cs.o_icl : cs.applied_icl_raw;
	uint8_t fcc = cs.o_fcc < cs.applied_fcc_raw ? cs.o_fcc : cs.applied_fcc_raw;

	(void)set(R_ICL_CFG, &s->icl_cfg, icl);
	(void)set(R_FCC, &s->fcc, fcc);
	(void)set(R_ICL_OPTIONS, &s->icl_opt, (uint8_t)((s->icl_opt & ~1u) | (cs.o_opt & 1u)));
	(void)set(R_LOAD_CFG, &s->load, (uint8_t)((s->load & ~0x10u) | (cs.o_load & 0x10u)));
	cs.applied = 0;
	cs.restores++;
}

/* One control pass over a settled snapshot. Returns registers written, -1 on a failed write. */
static int control(struct snap *s)
{
	int plug = (s->rt & 0x10u) != 0;
	uint8_t res = s->apsd_res & 0x7fu;

	if (!plug) {
		restore(s);
		cs.ctl = CTL_IDLE;
		cs.bad = 0;
		return 0;
	}
	if (unsafe(s)) {
		restore(s);
		cs.ctl = CTL_HOLD;
		return 0;
	}
	if (!(s->apsd_st & 1u)) {
		cs.ctl = CTL_WAIT;
		return 0;
	}
	uint16_t key = (uint16_t)(res | typec_rp(s) << 8);

	if (cs.applied && cs.applied_key != key)
		restore(s);

	unsigned icl = icl_for(s);
	if (icl && !(s->aicl_opt & 4u) && icl > CHG_ICL_NO_AICL_MA)
		icl = CHG_ICL_NO_AICL_MA;
	unsigned fcc = CHG_FCC_MA;
	int wrote = 0, r, fail = 0;
	uint8_t o_icl = s->icl_cfg, o_opt = s->icl_opt, o_load = s->load, o_fcc = s->fcc;

#define STEP(x) do { r = (x); if (r < 0) fail = 1; else wrote += r; } while (0)
	if (!cs.saved) {
		cs.o_icl = o_icl;
		cs.o_opt = o_opt;
		cs.o_load = o_load;
		cs.o_fcc = o_fcc;
		cs.saved = 1;
	}
	if (icl) {
		uint8_t raw = (uint8_t)(icl / CHG_STEP_MA);
		STEP(set(R_ICL_CFG, &s->icl_cfg, raw));
		STEP(set(R_ICL_OPTIONS, &s->icl_opt, (uint8_t)(s->icl_opt | 1u)));
		STEP(set(R_LOAD_CFG, &s->load, (uint8_t)(s->load | 0x10u)));
		cs.applied_icl_raw = raw;
	} else {
		restore(s);	/* SDP / float / OCP / none: the hardware limit stays; give back anything left */
	}
	if (!fail) {
		uint8_t raw = (uint8_t)(fcc / CHG_STEP_MA);
		STEP(set(R_FCC, &s->fcc, raw));
		cs.applied_fcc_raw = raw;
	}
	if (!fail && (s->fv == 0 || s->fv > CHG_FV_RAW_MAX))
		STEP(set(R_FV, &s->fv, (uint8_t)CHG_FV_RAW_MAX));
	if (!fail && !(s->chg_en & 1u))
		STEP(set(R_CHG_EN, &s->chg_en, (uint8_t)(s->chg_en | 1u)));
	if (!fail && (s->cmd_il & 1u))
		STEP(set(R_CMD_IL, &s->cmd_il, (uint8_t)(s->cmd_il & ~1u)));
#undef STEP
	if (fail)
		return -1;
	if (wrote && icl && !cs.applied)
		cs.applies++;
	if (icl) {
		cs.applied = 1;
		cs.applied_key = key;
	}
	cs.ctl = CTL_APPLIED;
	return wrote;
}

/* Two equal snapshots (plug, APSD result and done flag, nothing unsafe), 20 ms apart, then act on the second. */
static void step(void)
{
	static struct snap a;	/* first sample; the second one lands in cs.s (no struct copies: no libc memcpy) */
	struct snap *b = &cs.s;

	sample(&a);
	if (!a.core_ok) {
		sample(b);
		cs.ctl = CTL_SPMI;
		return;
	}
	udelay(CHG_DEBOUNCE_US);
	sample(b);
	if (!b->core_ok) {
		cs.ctl = CTL_SPMI;
		return;
	}
	int plug = (b->rt & 0x10u) != 0;

	if (((a.rt ^ b->rt) & 0x10u) || ((a.apsd_res ^ b->apsd_res) & 0x7fu) || ((a.apsd_st ^ b->apsd_st) & 1u) || typec_rp(&a) != typec_rp(b) ||
	    (unsafe(&a) != unsafe(b))) {
		cs.ctl = plug ? CTL_WAIT : CTL_IDLE;
		return;
	}
	if (cs.failed) {
		cs.ctl = CTL_FAILED;
		return;
	}
	int wrote = control(b);

	/* writes needed on 5 passes in a row: the hardware does not keep them */
	cs.bad = wrote != 0 ? cs.bad + 1 : 0;
	if (cs.bad >= CHG_BAD_MAX || cs.write_fails >= CHG_FAIL_MAX) {
		cs.failed = 1;
		restore(b);
		cs.ctl = CTL_FAILED;
	}
	if (wrote > 0)
		sample(b);	/* what the registers say now */
}

static void refresh(void)
{
	step();
	pmic_read_batt(&cs.b);
	cs.last_ms = ms_now();
	cs.ticked = 1;
}

/* ---- public ---- */

static int starts_word(const char *v, const char *w)
{
	while (*w && *v == *w)
		v++, w++;
	return !*w && (*v == 0 || *v == ' ');
}

int enxerto_charger_init(uintptr_t dtb)
{
	const char *v = dtb ? fdt_cmdline_opt(dtb, "bergamota.charger=") : 0;

	cs.mode = MODE_ON;
	if (v && starts_word(v, "0"))
		cs.mode = MODE_OFF;
	else if (v && starts_word(v, "keep"))
		cs.mode = MODE_KEEP;
	cs.ctl = CTL_OFF;
	if (cs.mode == MODE_OFF)
		return -1;
	if (pmic_init() < 0)
		return -1;
	cs.ready = 1;
	refresh();
	return 0;
}

void enxerto_charger_tick(int force)
{
	if (!cs.ready)
		return;
	if (!force && cs.ticked && ms_now() - cs.last_ms < CHG_TICK_MS)
		return;
	refresh();
}

void enxerto_charger_handoff(void)
{
	if (!cs.ready || cs.mode == MODE_KEEP)
		return;
	sample(&cs.s);
	if (cs.s.core_ok)
		restore(&cs.s);
	cs.ready = 0;	/* never write again after the hand-off */
	cs.ctl = CTL_OFF;
}

/* ---- text ---- */

struct sb {
	char *d;
	unsigned n, max;
};

static void sb_str(struct sb *b, const char *s)
{
	while (*s && b->n + 1 < b->max)
		b->d[b->n++] = *s++;
	b->d[b->n] = 0;
}

static void sb_u(struct sb *b, unsigned v)
{
	char t[12];
	int n = 0;

	do
		t[n++] = (char)('0' + v % 10);
	while ((v /= 10) && n < 12);
	while (n && b->n + 1 < b->max)
		b->d[b->n++] = t[--n];
	b->d[b->n] = 0;
}

static void sb_hex2(struct sb *b, unsigned v)
{
	static const char h[] = "0123456789abcdef";
	char t[3] = { h[(v >> 4) & 15], h[v & 15], 0 };

	sb_str(b, t);
}

static const char *type_name(const struct snap *s)
{
	uint8_t r = s->apsd_res & 0x7fu;

	if (!(s->rt & 0x10u))
		return "none";
	return (r & APSD_QC3) ? "QC3" : (r & APSD_QC2) ? "QC2" : (r & APSD_DCP) ? "DCP" : (r & APSD_CDP) ? "CDP" :
	       (r & APSD_FLOAT) ? "FLOAT" : (r & APSD_OCP) ? "OCP" : (r & APSD_SDP) ? "SDP" : "?";
}

/* switch -> no jump table / lookup table of pointers (ABS64 relocations) */
__attribute__((optimize("no-jump-tables", "no-tree-switch-conversion")))
static const char *ctl_name(void)
{
	switch (cs.ctl) {
	case CTL_RO: return "ro";
	case CTL_IDLE: return "idle";
	case CTL_WAIT: return "wait";
	case CTL_HOLD: return "hold";
	case CTL_APPLIED: return "applied";
	case CTL_FAILED: return "failed";
	case CTL_SPMI: return "spmi";
	}
	return "off";
}

/* switch -> no jump table / lookup table of pointers (ABS64 relocations) */
__attribute__((optimize("no-jump-tables", "no-tree-switch-conversion")))
static const char *state_name(uint8_t st1)
{
	switch (st1 & 7u) {
	case 0: return "TRKL";
	case 1: return "PRE";
	case 2: return "FAST";
	case 3: return "FULLON";
	case 4: return "TAPER";
	case 5: return "FULL";
	case 6: return "INHIB";
	}
	return "DIS";
}

void enxerto_charger_status(char *buf, unsigned n)
{
	struct sb b = { buf, 0, n };

	buf[0] = 0;
	if (!cs.ticked && !cs.ready) {
		sb_str(&b, cs.mode == MODE_OFF ? "off" : "unavailable");
		return;
	}
	const struct snap *s = &cs.s;

	sb_str(&b, ctl_name());
	if (!s->core_ok)
		return;
	sb_str(&b, " ");
	sb_str(&b, type_name(s));
	sb_str(&b, " ");
	if (s->have_icl_stat)
		sb_u(&b, s->icl_stat * CHG_STEP_MA);
	else
		sb_str(&b, "?");
	sb_str(&b, "/");
	sb_u(&b, s->fcc * CHG_STEP_MA);
	sb_str(&b, "mA ");
	sb_u(&b, (6975u + 15u * s->fv) / 2u);	/* 3487.5 mV + 7.5 mV * raw */
	sb_str(&b, "mV ");
	sb_str(&b, state_name(s->st1));
	if (cs.b.valid) {
		sb_str(&b, " ");
		sb_u(&b, cs.b.soc);
		sb_str(&b, "%");
	}
}

void enxerto_charger_raw(char *buf, unsigned n)
{
	struct sb b = { buf, 0, n };
	const struct snap *s = &cs.s;

	buf[0] = 0;
	if (!cs.ticked) {
		sb_str(&b, "unavailable");
		return;
	}
	sb_str(&b, "st=");
	sb_hex2(&b, s->st1);
	sb_str(&b, "/");
	sb_hex2(&b, s->st2);
	sb_str(&b, " apsd=");
	sb_hex2(&b, s->apsd_res);
	sb_str(&b, " je=");
	if (s->have_jeita)
		sb_hex2(&b, s->jeita);
	else
		sb_str(&b, "??");
	sb_str(&b, " rp=");
	sb_u(&b, typec_rp(s));
	sb_str(&b, " aicl=");
	sb_u(&b, (s->aicl_opt >> 2) & 1u);
	sb_str(&b, " w=");
	sb_u(&b, cs.writes);
	sb_str(&b, "/");
	sb_u(&b, cs.write_fails);
}

void enxerto_charger_line(char *buf, unsigned n)
{
	struct sb b = { buf, 0, n };
	const struct snap *s = &cs.s;

	buf[0] = 0;
	if (!cs.ticked || !s->core_ok)
		return;
	if (!(s->rt & 0x10u)) {
		sb_str(&b, "on battery");
		if (cs.b.valid) {
			sb_str(&b, " ");
			sb_u(&b, cs.b.soc);
			sb_str(&b, "%");
		}
		return;
	}
	uint8_t st = s->st1 & 7u;
	sb_str(&b, st == 5 ? "charged" : (st <= 4) ? "charging" : "not charging");
	if (s->have_icl_stat) {
		sb_str(&b, " ");
		sb_u(&b, s->icl_stat * CHG_STEP_MA);
		sb_str(&b, " mA");
	}
	sb_str(&b, " ");
	sb_str(&b, type_name(s));
	if (cs.b.valid) {
		sb_str(&b, " ");
		sb_u(&b, cs.b.soc);
		sb_str(&b, "%");
	}
}

#else /* !ENXERTO_CHARGER */

int enxerto_charger_init(uintptr_t dtb) { (void)dtb; return -1; }
void enxerto_charger_tick(int force) { (void)force; }
void enxerto_charger_handoff(void) { }
void enxerto_charger_status(char *buf, unsigned n) { (void)n; buf[0] = 'o'; buf[1] = 'f'; buf[2] = 'f'; buf[3] = 0; }
void enxerto_charger_raw(char *buf, unsigned n) { (void)n; buf[0] = 0; }
void enxerto_charger_line(char *buf, unsigned n) { (void)n; buf[0] = 0; }

#endif
