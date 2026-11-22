/* Okusan Famicom CRT: HVC-001 60-Pin Cartridge Physical & Electrical Contact Model
 *
 * Models all 60 physical card-edge contacts (Front 1..30, Back 31..60) at exact
 * 2.54 mm pitch, 78.00 mm PCB width, 1.55 mm gold fingers (0.99 mm comb barrier),
 * and 2.50..4.20 mm phosphor-bronze spring wiper crown inside a 10.00 mm deep slot
 * with +/-0.35 mm side play.
 *
 * Mechanical property:
 *   Max combined tilt+play lateral shear (~0.604 mm) < copper-short threshold (1.215 mm).
 *   Pure tilting therefore never directly shorts adjacent metal fingers; neighboring-pin
 *   interference occurs electrically via capacitive/leakage crosstalk onto High-Z lines.
 */

#include <string.h>

#include "fceu-types.h"
#include "x6502.h"
#include "okusan_cart.h"

const OkusanPinSpec okusan_pins60_spec[OKUSAN_CART_PIN_COUNT] = {
	/* Front 1..30 */
	{ -120, OKUSAN_PCLS_GND, 11 }, { -180, OKUSAN_PCLS_SIG, 13 }, {  +60, OKUSAN_PCLS_SIG, 17 },
	{  -40, OKUSAN_PCLS_SIG, 19 }, { +110, OKUSAN_PCLS_SIG, 23 }, { -150, OKUSAN_PCLS_SIG, 29 },
	{  +30, OKUSAN_PCLS_SIG, 31 }, {  -90, OKUSAN_PCLS_SIG, 37 }, { +140, OKUSAN_PCLS_SIG, 41 },
	{  -20, OKUSAN_PCLS_SIG, 43 }, { +160, OKUSAN_PCLS_SIG, 47 }, { -110, OKUSAN_PCLS_SIG, 53 },
	{  +80, OKUSAN_PCLS_SIG, 59 }, {  -60, OKUSAN_PCLS_SIG, 61 }, { +120, OKUSAN_PCLS_SIG, 67 },
	{  -80, OKUSAN_PCLS_GND, 71 }, {  +50, OKUSAN_PCLS_SIG, 73 }, { -160, OKUSAN_PCLS_SIG, 79 },
	{ +130, OKUSAN_PCLS_SIG, 83 }, { -100, OKUSAN_PCLS_SIG, 89 }, {  +70, OKUSAN_PCLS_SIG, 97 },
	{ -190, OKUSAN_PCLS_SIG, 101}, { +150, OKUSAN_PCLS_SIG, 103}, {  -50, OKUSAN_PCLS_SIG, 107},
	{  +90, OKUSAN_PCLS_SIG, 109}, { -140, OKUSAN_PCLS_SIG, 113}, { +110, OKUSAN_PCLS_SIG, 127},
	{  -70, OKUSAN_PCLS_SIG, 131}, { +170, OKUSAN_PCLS_SIG, 137}, {  -30, OKUSAN_PCLS_VCC, 139},
	/* Back 31..60 */
	{  +90, OKUSAN_PCLS_VCC, 149}, { -130, OKUSAN_PCLS_SIG, 151}, { +140, OKUSAN_PCLS_SIG, 157},
	{  -70, OKUSAN_PCLS_SIG, 163}, { +100, OKUSAN_PCLS_SIG, 167}, { -170, OKUSAN_PCLS_SIG, 173},
	{  +40, OKUSAN_PCLS_SIG, 179}, { -110, OKUSAN_PCLS_SIG, 181}, { +160, OKUSAN_PCLS_SIG, 191},
	{  -30, OKUSAN_PCLS_SIG, 193}, { +120, OKUSAN_PCLS_SIG, 197}, {  -90, OKUSAN_PCLS_SIG, 199},
	{ +180, OKUSAN_PCLS_SIG, 211}, { -140, OKUSAN_PCLS_SIG, 223}, {  +60, OKUSAN_PCLS_SIG, 227},
	{ -100, OKUSAN_PCLS_SIG, 229}, {  +80, OKUSAN_PCLS_SIG, 233}, { -150, OKUSAN_PCLS_SIG, 239},
	{ +130, OKUSAN_PCLS_SIG, 241}, {  -60, OKUSAN_PCLS_SIG, 251}, { +150, OKUSAN_PCLS_SIG,  12},
	{ -120, OKUSAN_PCLS_SIG,  24}, {  +40, OKUSAN_PCLS_SIG,  36}, { -160, OKUSAN_PCLS_SIG,  48},
	{ +110, OKUSAN_PCLS_SIG,  60}, { -190, OKUSAN_PCLS_SIG,  72}, { +120, OKUSAN_PCLS_SIG,  84},
	{ -130, OKUSAN_PCLS_SIG,  96}, {  +70, OKUSAN_PCLS_SIG, 108}, { -200, OKUSAN_PCLS_SIG, 120}
};

OkusanCartRuntime okusan_cart_rt = {
	0,
	{0}, {0}, {0},
	0, 4978, 256, 0, 0, 0, 0,
	{0}, {0}, {0}, {0}, {0}, {0}, {0}
};

static int      okusan_tilt = 0;              /* -32 .. +32 (left/PRG lift .. 0 .. right/PPU lift) */
static int      okusan_lift = 0;              /*   0 .. +16 (uniform vertical pull-up) */
static int      okusan_pitch = 0;             /*  -8 .. +8  (front-back card rock in blue socket) */
static uint64_t okusan_pin_weak_mask = 0ULL;  /* Per-pin explicit WEAK fault mask (bit i = Pin i) */
static uint64_t okusan_pin_open_mask = 0ULL;  /* Per-pin explicit OPEN fault mask (bit i = Pin i) */

static uint32_t okusan_last_cpu_addr = 0x8000u;
static uint8_t  okusan_last_cpu_data = 0xEAu;
static OkusanPinTelemetry60 okusan_frame_tel[OKUSAN_CART_PIN_COUNT];

/* ------------------------------------------------------------------------- */
/* Geometry & Contact Resistance Helpers                                     */
/* ------------------------------------------------------------------------- */

static INLINE int pin_longitudinal_x_um(int pin_idx) {
	int pos = (pin_idx < 30) ? pin_idx : (pin_idx - 30);
	return (pos * 2 - 29) * (OKUSAN_PIN_PITCH_UM / 2);
}

static INLINE int pin_rise_3dof_um(int tilt, int lift, int pitch, int pin_idx) {
	int rise = okusan_cart_edge_rise_um(tilt, lift, pin_longitudinal_x_um(pin_idx));
	if (pitch != 0) {
		/* Front-to-back rocking applies a minor vertical lever across the 1.6 mm PCB thickness. */
		int face_lift = (pin_idx < 30) ? (-pitch * 45) : (+pitch * 45);
		rise += face_lift;
		if (rise < 0) rise = 0;
	}
	return rise;
}

/* Contact resistance in 0.1-ohm units (dOhm) for the power-rail Ohm's-law brownout model. */
static INLINE int pin_resistance_dohm(uint8_t raw_state, int overlap_um) {
	uint8_t base_state = raw_state & 0x0Fu;
	if (base_state == OKUSAN_PIN_SEATED) return 2; /* 0.2 ohm */
	if (base_state == OKUSAN_PIN_WEAK) {
		int deficit = 960 - overlap_um;
		if (deficit < 0) deficit = 0;
		return 2 + (deficit * 40) / 540; /* 0.2 .. 4.2 ohm */
	}
	if (base_state == OKUSAN_PIN_MARGINAL) {
		int deficit = 420 - overlap_um;
		if (deficit < 0) deficit = 0;
		return 80 + (deficit * 400) / 380; /* 8.0 .. 48.0 ohm oxidized tip contact */
	}
	return 100000; /* 10 kOhm open */
}

static uint8_t classify_overlap_state(int overlap_um, uint32_t drift_sample) {
	if (overlap_um >= 960) return OKUSAN_PIN_SEATED;
	if (overlap_um >= 920) return (drift_sample < 24u) ? OKUSAN_PIN_WEAK : OKUSAN_PIN_SEATED;
	if (overlap_um >= 420) return OKUSAN_PIN_WEAK;
	if (overlap_um >= 380) return (drift_sample < 24u) ? OKUSAN_PIN_MARGINAL : OKUSAN_PIN_WEAK;
	if (overlap_um >= 70)  return OKUSAN_PIN_MARGINAL;
	if (overlap_um >= 40)  return (drift_sample < 24u) ? OKUSAN_PIN_OPEN : OKUSAN_PIN_MARGINAL;
	return OKUSAN_PIN_OPEN;
}

static void update_power_and_audio_rails(void) {
	/* Strict Ohm's-law rail calculation across Pin 1/16 (GND) & Pin 30/31 (+5V) under ~110 mA load. */
	int r_gnd1 = pin_resistance_dohm(okusan_cart_rt.cached_pins[OKUSAN_PIN_GND1],  okusan_cart_rt.cached_overlap_um[OKUSAN_PIN_GND1]);
	int r_gnd2 = pin_resistance_dohm(okusan_cart_rt.cached_pins[OKUSAN_PIN_GND2],  okusan_cart_rt.cached_overlap_um[OKUSAN_PIN_GND2]);
	int r_vccl = pin_resistance_dohm(okusan_cart_rt.cached_pins[OKUSAN_PIN_VCC_L], okusan_cart_rt.cached_overlap_um[OKUSAN_PIN_VCC_L]);
	int r_vccr = pin_resistance_dohm(okusan_cart_rt.cached_pins[OKUSAN_PIN_VCC_R], okusan_cart_rt.cached_overlap_um[OKUSAN_PIN_VCC_R]);

	long long gnd_parallel_dohm = ((long long)r_gnd1 * r_gnd2) / (r_gnd1 + r_gnd2);
	long long vcc_parallel_dohm = ((long long)r_vccl * r_vccr) / (r_vccl + r_vccr);
	long long drop_mv = (gnd_parallel_dohm + vcc_parallel_dohm) * 11LL; /* 1 dOhm (0.1 ohm) * 110 mA = 11 mV */
	int vcc_mv = (drop_mv >= 5000LL) ? 0 : (int)(5000LL - drop_mv);

	okusan_cart_rt.vcc_mv           = vcc_mv;
	okusan_cart_rt.power_dead       = (vcc_mv < 3400) ? 1 : 0; /* < 3.40 V brownout cutoff -> unpowered */
	okusan_cart_rt.vcc_slow_q       = (vcc_mv >= 3400 && vcc_mv < 4350) ? (((4350 - vcc_mv) * 140) / 950) : 0;
	okusan_cart_rt.gnd_bounce_cpu_q = (r_gnd1 > r_gnd2 + 10) ? (r_gnd1 > 100 ? 72 : (r_gnd1 * 72) / 100) : 0;
	okusan_cart_rt.gnd_bounce_ppu_q = (r_gnd2 > r_gnd1 + 10) ? (r_gnd2 > 100 ? 72 : (r_gnd2 * 72) / 100) : 0;

	int snd_in_state  = okusan_cart_rt.cached_pins[OKUSAN_PIN_SND_IN]  & 0x0F;
	int snd_out_state = okusan_cart_rt.cached_pins[OKUSAN_PIN_SND_OUT] & 0x0F;
	int snd_worst     = (snd_in_state > snd_out_state) ? snd_in_state : snd_out_state;

	if (snd_worst == OKUSAN_PIN_SEATED)        okusan_cart_rt.audio_q = 256;
	else if (snd_worst == OKUSAN_PIN_WEAK)     okusan_cart_rt.audio_q = 192;
	else if (snd_worst == OKUSAN_PIN_MARGINAL) okusan_cart_rt.audio_q = (int)(72u + (okusan_frame_drift(227u) >> 1));
	else                                       okusan_cart_rt.audio_q = 0;
}

static void update_crosstalk_flags(void) {
	for (int i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
		uint8_t contact_state = okusan_cart_rt.cached_pins[i] & 0x0F;
		if (contact_state == OKUSAN_PIN_SEATED || okusan_pins60_spec[i].pin_class != OKUSAN_PCLS_SIG) {
			continue;
		}
		int pos = (i < 30) ? i : (i - 30);
		if (pos > 0) {
			uint8_t left_state = okusan_cart_rt.cached_pins[i - 1] & 0x0F;
			if (okusan_pins60_spec[i - 1].pin_class != OKUSAN_PCLS_GND && left_state != OKUSAN_PIN_OPEN) {
				okusan_cart_rt.cached_pins[i] |= OKUSAN_PIN_FLAG_XTALK_L;
			}
		}
		if (pos < 29) {
			uint8_t right_state = okusan_cart_rt.cached_pins[i + 1] & 0x0F;
			if (okusan_pins60_spec[i + 1].pin_class != OKUSAN_PCLS_GND && right_state != OKUSAN_PIN_OPEN) {
				okusan_cart_rt.cached_pins[i] |= OKUSAN_PIN_FLAG_XTALK_R;
			}
		}
	}
}

static void refresh_frame_cache(void) {
	const int has_pose_skew  = (okusan_tilt != 0 || okusan_lift != 0 || okusan_pitch != 0);
	const int has_pin_masks  = (okusan_pin_weak_mask != 0ULL || okusan_pin_open_mask != 0ULL);
	okusan_cart_rt.active    = (has_pose_skew || has_pin_masks) ? 1 : 0;

	if (!has_pose_skew) {
		for (int i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
			okusan_cart_rt.cached_pins[i]       = OKUSAN_PIN_SEATED;
			okusan_cart_rt.cached_rise_um[i]    = 0;
			okusan_cart_rt.cached_overlap_um[i] = OKUSAN_WIPER_TOP_UM - OKUSAN_WIPER_BOT_UM;
		}
		if (!has_pin_masks) {
			okusan_cart_rt.vcc_mv           = 4978;
			okusan_cart_rt.power_dead       = 0;
			okusan_cart_rt.audio_q          = 256;
			okusan_cart_rt.gnd_bounce_cpu_q = 0;
			okusan_cart_rt.gnd_bounce_ppu_q = 0;
			okusan_cart_rt.vcc_slow_q       = 0;
			return;
		}
	} else {
		/* Lateral pad-to-wiper width loss from tilt + slot play (below copper-bridging threshold). */
		int lat_shift_um  = okusan_cart_lat_shift_um(okusan_tilt, okusan_lift);
		int lat_overlap_w = (OKUSAN_PAD_WIDTH_UM + OKUSAN_WIPER_WIDTH_UM) / 2 - lat_shift_um;
		if (lat_overlap_w > OKUSAN_WIPER_WIDTH_UM) lat_overlap_w = OKUSAN_WIPER_WIDTH_UM;
		if (lat_overlap_w < 0) lat_overlap_w = 0;

		for (int i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
			int rise_um = pin_rise_3dof_um(okusan_tilt, okusan_lift, okusan_pitch, i);
			int pad_bot = OKUSAN_PAD_BOT_UM + rise_um + okusan_pins60_spec[i].wear_um;
			int pad_top = OKUSAN_PAD_TOP_UM + rise_um + okusan_pins60_spec[i].wear_um;
			int ov_low  = pad_bot > OKUSAN_WIPER_BOT_UM ? pad_bot : OKUSAN_WIPER_BOT_UM;
			int ov_high = pad_top < OKUSAN_WIPER_TOP_UM ? pad_top : OKUSAN_WIPER_TOP_UM;
			int vertical_overlap = ov_high - ov_low;
			if (vertical_overlap < 0) vertical_overlap = 0;
			if (vertical_overlap > (OKUSAN_WIPER_TOP_UM - OKUSAN_WIPER_BOT_UM)) {
				vertical_overlap = OKUSAN_WIPER_TOP_UM - OKUSAN_WIPER_BOT_UM;
			}

			/* Spring wiper normal preload (450 um nominal): pitch > 0 loads Front, unloads Back. */
			int raw_preload = 450 + ((i < 30) ? (+okusan_pitch * 68) : (-okusan_pitch * 68));
			int eff_preload = raw_preload > 450 ? 450 : (raw_preload < 0 ? 0 : raw_preload);
			int overlap_um  = (vertical_overlap * lat_overlap_w) / OKUSAN_WIPER_WIDTH_UM;
			overlap_um = (overlap_um * eff_preload) / 450;

			uint32_t drift_sample = okusan_frame_drift(okusan_pins60_spec[i].salt);
			okusan_cart_rt.cached_pins[i]       = classify_overlap_state(overlap_um, drift_sample);
			okusan_cart_rt.cached_rise_um[i]    = (int16_t)rise_um;
			okusan_cart_rt.cached_overlap_um[i] = (int16_t)overlap_um;
		}
	}

	if (has_pin_masks) {
		for (int i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
			uint64_t bit = 1ULL << i;
			if (okusan_pin_open_mask & bit) {
				okusan_cart_rt.cached_pins[i]       = OKUSAN_PIN_OPEN;
				okusan_cart_rt.cached_overlap_um[i] = 0;
				if (okusan_cart_rt.cached_rise_um[i] < 2400) okusan_cart_rt.cached_rise_um[i] = 2400;
			} else if ((okusan_pin_weak_mask & bit) &&
			           (okusan_cart_rt.cached_pins[i] & 0x0Fu) < OKUSAN_PIN_WEAK) {
				int weak_overlap = 700 + okusan_pins60_spec[i].wear_um;
				if (weak_overlap < 440) weak_overlap = 440;
				if (weak_overlap > 940) weak_overlap = 940;
				okusan_cart_rt.cached_pins[i]       = OKUSAN_PIN_WEAK;
				okusan_cart_rt.cached_overlap_um[i] = (int16_t)weak_overlap;
				if (okusan_cart_rt.cached_rise_um[i] < 900) okusan_cart_rt.cached_rise_um[i] = 900;
			}
		}
	}

	update_power_and_audio_rails();
	update_crosstalk_flags();
}

static void finalize_frame_telemetry(void) {
	for (int i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
		OkusanPinTelemetry60 *tel = &okusan_frame_tel[i];
		tel->state      = okusan_cart_rt.cached_pins[i];
		tel->rise_um    = okusan_cart_rt.cached_rise_um[i];
		tel->overlap_um = okusan_cart_rt.cached_overlap_um[i];

		uint32_t sample_count = okusan_cart_rt.acc_cnt[i];
		if (sample_count > 0) {
			tel->duty_pct  = (uint8_t)((okusan_cart_rt.acc_hi[i] * 100u + sample_count / 2u) / sample_count);
			tel->fault_pct = (uint8_t)((okusan_cart_rt.acc_fault[i] * 100u + sample_count / 2u) / sample_count);
			uint32_t toggle_pct = (okusan_cart_rt.acc_tog[i] * 100u) / sample_count;
			tel->toggling  = (uint8_t)(toggle_pct >= 12u ? 2u : (okusan_cart_rt.acc_tog[i] > 0u ? 1u : 0u));
			tel->bus_orig  = okusan_cart_rt.acc_orig_word[i];
			tel->bus_eff   = okusan_cart_rt.acc_eff_word[i];
		} else if (i == OKUSAN_PIN_GND1 || i == OKUSAN_PIN_GND2) {
			uint8_t base = okusan_cart_rt.cached_pins[i] & 0x0F;
			tel->duty_pct = 0;
			tel->toggling = 0;
			tel->fault_pct = (base == OKUSAN_PIN_OPEN) ? 100 : 0;
			tel->bus_orig = 0x0000u;
			tel->bus_eff  = tel->fault_pct ? 0xFFFFu : 0x0000u;
		} else if (i == OKUSAN_PIN_VCC_L || i == OKUSAN_PIN_VCC_R) {
			uint8_t base = okusan_cart_rt.cached_pins[i] & 0x0F;
			tel->duty_pct  = (base == OKUSAN_PIN_OPEN) ? 0 : (uint8_t)((okusan_cart_rt.vcc_mv * 100) / 5000);
			tel->toggling  = 0;
			tel->fault_pct = (okusan_cart_rt.power_dead || base == OKUSAN_PIN_OPEN) ? 100 : (base != OKUSAN_PIN_SEATED ? 25 : 0);
			tel->bus_orig  = 5000u;
			tel->bus_eff   = (base == OKUSAN_PIN_OPEN) ? 0u : (uint16_t)okusan_cart_rt.vcc_mv;
		} else if (i == OKUSAN_PIN_M2) {
			uint8_t base = okusan_cart_rt.cached_pins[i] & 0x0F;
			tel->duty_pct  = (base == OKUSAN_PIN_OPEN) ? 100 : 62;
			tel->toggling  = (base == OKUSAN_PIN_OPEN) ? 0 : 2;
			tel->fault_pct = (base == OKUSAN_PIN_OPEN) ? 100 : (base == OKUSAN_PIN_MARGINAL ? 45 : 0);
			tel->bus_orig  = 1789u;
			tel->bus_eff   = (base == OKUSAN_PIN_OPEN) ? 0u : 1789u;
		} else if (i == OKUSAN_PIN_SND_IN || i == OKUSAN_PIN_SND_OUT) {
			tel->duty_pct  = (uint8_t)((okusan_cart_rt.audio_q * 100) / 256);
			tel->toggling  = (okusan_cart_rt.audio_q > 0) ? 2 : 0;
			tel->fault_pct = (uint8_t)(100 - tel->duty_pct);
			tel->bus_orig  = 256u;
			tel->bus_eff   = (uint16_t)okusan_cart_rt.audio_q;
		} else {
			uint8_t base = okusan_cart_rt.cached_pins[i] & 0x0F;
			tel->duty_pct  = 100;
			tel->toggling  = 0;
			tel->fault_pct = (base == OKUSAN_PIN_OPEN) ? 100 : 0;
			tel->bus_orig  = 1u;
			tel->bus_eff   = (base == OKUSAN_PIN_OPEN) ? 0u : 1u;
		}

		okusan_cart_rt.acc_cnt[i]   = 0;
		okusan_cart_rt.acc_hi[i]    = 0;
		okusan_cart_rt.acc_tog[i]   = 0;
		okusan_cart_rt.acc_fault[i] = 0;
	}
}

/* ------------------------------------------------------------------------- */
/* Public Pose, Telemetry & Geometry APIs                                    */
/* ------------------------------------------------------------------------- */

void okusan_begin_ppu_frame(void) {
	finalize_frame_telemetry();
	okusan_cart_rt.frame_tick++;
	refresh_frame_cache();
}

__attribute__((visibility("default")))
int okusan_cart_edge_rise_um(int tilt, int lift, int x_um) {
	int lift_um = lift * 330;
	if (tilt == 0) return lift_um;

	int abs_tilt = (tilt < 0) ? -tilt : tilt;
	int dist_um  = (tilt > 0) ? (x_um + OKUSAN_CARD_HALF_UM) : (OKUSAN_CARD_HALF_UM - x_um);
	if (dist_um < 0) dist_um = 0;

	int tilt_um = (abs_tilt * 185 * dist_um) / (2 * OKUSAN_CARD_HALF_UM);
	return lift_um + tilt_um;
}

__attribute__((visibility("default")))
int okusan_cart_lat_shift_um(int tilt, int lift) {
	int abs_tilt = (tilt < 0) ? -tilt : tilt;
	if (abs_tilt == 0) return 0;

	int eff_height_um = 3350 - (lift * 330) / 2;
	if (eff_height_um < 800) eff_height_um = 800;

	int geom_um = (abs_tilt * 185 * eff_height_um) / (2 * OKUSAN_CARD_HALF_UM);
	int play_um = (abs_tilt * OKUSAN_SLOT_PLAY_UM) / 32;
	return geom_um + play_um;
}

__attribute__((visibility("default")))
void okusan_set_cart_contact3(int tilt, int lift, int pitch) {
	if (tilt < -32) tilt = -32;
	if (tilt > 32)  tilt = 32;
	if (lift < 0)   lift = 0;
	if (lift > 16)  lift = 16;
	if (pitch < -8) pitch = -8;
	if (pitch > 8)  pitch = 8;

	okusan_tilt  = tilt;
	okusan_lift  = lift;
	okusan_pitch = pitch;
	refresh_frame_cache();
}

__attribute__((visibility("default")))
void okusan_set_cart_contact(int tilt, int lift) {
	okusan_set_cart_contact3(tilt, lift, 0);
}

__attribute__((visibility("default")))
void okusan_set_pin_fault_masks(uint64_t weak_mask, uint64_t open_mask) {
	okusan_pin_weak_mask = weak_mask;
	okusan_pin_open_mask = open_mask;
	refresh_frame_cache();
}

__attribute__((visibility("default")))
void okusan_reseat_cart_contact(void) {
	if (okusan_cart_is_active() && !okusan_cart_rt.power_dead) {
		int ciram_severity = (int)(okusan_cart_rt.cached_pins[OKUSAN_PIN_PPU_WR]    & 0x0Fu)
		                   + (int)(okusan_cart_rt.cached_pins[OKUSAN_PIN_CIRAM_CE]  & 0x0Fu)
		                   + (int)(okusan_cart_rt.cached_pins[OKUSAN_PIN_PPU_NA13]  & 0x0Fu)
		                   + (int)(okusan_cart_rt.cached_pins[OKUSAN_PIN_CIRAM_A10] & 0x0Fu);
		int ppu_fault_count = 0;
		for (int p = OKUSAN_PIN_PPU_RD; p <= OKUSAN_PIN_VCC_R; ++p) {
			if ((okusan_cart_rt.cached_pins[p] & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_fault_count++;
		}
		for (int p = OKUSAN_PIN_PPU_WR; p <= OKUSAN_PIN_PPU_D4; ++p) {
			if ((okusan_cart_rt.cached_pins[p] & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_fault_count++;
		}
		if ((okusan_cart_rt.cached_pins[OKUSAN_PIN_GND1]  & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_fault_count++;
		if ((okusan_cart_rt.cached_pins[OKUSAN_PIN_GND2]  & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_fault_count++;
		if ((okusan_cart_rt.cached_pins[OKUSAN_PIN_VCC_L] & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_fault_count++;

		okusan_ppu_on_reseat_latch(ciram_severity, ppu_fault_count,
		                           okusan_tilt, okusan_lift, okusan_pitch,
		                           okusan_cart_rt.frame_tick);
	}
	okusan_pin_weak_mask = 0ULL;
	okusan_pin_open_mask = 0ULL;
	okusan_set_cart_contact3(0, 0, 0);
}

__attribute__((visibility("default")))
int okusan_cart_is_powered(void) {
	return okusan_cart_rt.power_dead ? 0 : 1;
}

__attribute__((visibility("default")))
int okusan_cart_vcc_mv(void) {
	return okusan_cart_rt.vcc_mv;
}

__attribute__((visibility("default")))
void okusan_get_pin_telemetry60(int *out_tilt, int *out_lift, int *out_pitch,
                                OkusanPinTelemetry60 *out_tel, int max_pins) {
	if (out_tilt)  *out_tilt  = okusan_tilt;
	if (out_lift)  *out_lift  = okusan_lift;
	if (out_pitch) *out_pitch = okusan_pitch;
	if (!out_tel || max_pins <= 0) return;

	int count = max_pins < OKUSAN_CART_PIN_COUNT ? max_pins : OKUSAN_CART_PIN_COUNT;
	for (int i = 0; i < count; ++i) {
		out_tel[i]            = okusan_frame_tel[i];
		out_tel[i].state      = okusan_cart_rt.cached_pins[i];
		out_tel[i].rise_um    = okusan_cart_rt.cached_rise_um[i];
		out_tel[i].overlap_um = okusan_cart_rt.cached_overlap_um[i];
	}
}

__attribute__((visibility("default")))
int okusan_get_audio_contact_q(void) {
	return okusan_cart_rt.audio_q;
}

/* ------------------------------------------------------------------------- */
/* 6502 Cartridge Bus Hooks ($4020-$FFFF)                                   */
/* ------------------------------------------------------------------------- */

static INLINE uint32_t map_cpu_addr_bits(uint32_t addr) {
	static const int cpu_addr_pin[15] = {
		OKUSAN_PIN_CPU_A0,  OKUSAN_PIN_CPU_A1,  OKUSAN_PIN_CPU_A2,  OKUSAN_PIN_CPU_A3,  OKUSAN_PIN_CPU_A4,
		OKUSAN_PIN_CPU_A5,  OKUSAN_PIN_CPU_A6,  OKUSAN_PIN_CPU_A7,  OKUSAN_PIN_CPU_A8,  OKUSAN_PIN_CPU_A9,
		OKUSAN_PIN_CPU_A10, OKUSAN_PIN_CPU_A11, OKUSAN_PIN_CPU_A12, OKUSAN_PIN_CPU_A13, OKUSAN_PIN_CPU_A14
	};
	static const int xtalk_left_bit[15]  = {  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, -1, -1, 12, 13 };
	static const int xtalk_right_bit[15] = { -1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 13, 14, -1 };

	uint32_t prev_addr = okusan_last_cpu_addr;
	uint32_t bus_hash  = (addr ^ (addr >> 7)) & 255u;
	uint32_t mapped    = 0u;
	for (int bit = 0; bit < 15; ++bit) {
		uint32_t orig_bit = (addr >> bit) & 1u;
		uint32_t prev_bit = (prev_addr >> bit) & 1u;
		uint32_t xl = (xtalk_left_bit[bit]  >= 0) ? ((addr >> xtalk_left_bit[bit])  & 1u) : 0u;
		uint32_t xr = (xtalk_right_bit[bit] >= 0) ? ((addr >> xtalk_right_bit[bit]) & 1u) : 1u;
		uint32_t eff_bit = okusan_pin_xfer_bit(cpu_addr_pin[bit], orig_bit, prev_bit, xl, xr, 1u,
		                                       bus_hash + (uint32_t)bit * 7u, 0);
		mapped |= (eff_bit << bit);
	}
	okusan_last_cpu_addr = addr;
	return mapped;
}

static INLINE uint8_t map_cpu_data_bits(uint8_t val, uint8_t open_bus) {
	static const int cpu_data_pin[8] = {
		OKUSAN_PIN_CPU_D0, OKUSAN_PIN_CPU_D1, OKUSAN_PIN_CPU_D2, OKUSAN_PIN_CPU_D3,
		OKUSAN_PIN_CPU_D4, OKUSAN_PIN_CPU_D5, OKUSAN_PIN_CPU_D6, OKUSAN_PIN_CPU_D7
	};
	uint32_t prev_data = okusan_last_cpu_data;
	uint32_t bus_hash  = (okusan_last_cpu_addr ^ ((uint32_t)val << 3)) & 255u;
	uint32_t mapped    = 0u;
	for (int bit = 0; bit < 8; ++bit) {
		uint32_t orig_bit  = ((uint32_t)val >> bit) & 1u;
		uint32_t prev_bit  = (prev_data >> bit) & 1u;
		uint32_t xl        = (bit < 7) ? (((uint32_t)val >> (bit + 1)) & 1u) : ((okusan_last_cpu_addr >> 14) & 1u);
		uint32_t xr        = (bit > 0) ? (((uint32_t)val >> (bit - 1)) & 1u) : 0u;
		uint32_t float_bit = ((uint32_t)open_bus >> bit) & 1u;
		if ((okusan_cart_rt.cached_pins[cpu_data_pin[bit]] & 0x0Fu) == OKUSAN_PIN_OPEN &&
		    okusan_pin_chatter(211u + (uint32_t)bit) < 72u) {
			float_bit = 1u;
		}
		uint32_t eff_bit = okusan_pin_xfer_bit(cpu_data_pin[bit], orig_bit, prev_bit, xl, xr, float_bit,
		                                       bus_hash + (uint32_t)bit * 13u, 0);
		mapped |= (eff_bit << bit);
	}
	okusan_last_cpu_data = val;
	return (uint8_t)mapped;
}

__attribute__((visibility("default")))
void okusan_trace_cpu_bus(uint32_t orig_a, uint32_t eff_a, uint8_t orig_d, uint8_t eff_d, int is_write) {
	static const int cpu_addr_pin[15] = {
		OKUSAN_PIN_CPU_A0,  OKUSAN_PIN_CPU_A1,  OKUSAN_PIN_CPU_A2,  OKUSAN_PIN_CPU_A3,  OKUSAN_PIN_CPU_A4,
		OKUSAN_PIN_CPU_A5,  OKUSAN_PIN_CPU_A6,  OKUSAN_PIN_CPU_A7,  OKUSAN_PIN_CPU_A8,  OKUSAN_PIN_CPU_A9,
		OKUSAN_PIN_CPU_A10, OKUSAN_PIN_CPU_A11, OKUSAN_PIN_CPU_A12, OKUSAN_PIN_CPU_A13, OKUSAN_PIN_CPU_A14
	};
	static const int cpu_data_pin[8] = {
		OKUSAN_PIN_CPU_D0, OKUSAN_PIN_CPU_D1, OKUSAN_PIN_CPU_D2, OKUSAN_PIN_CPU_D3,
		OKUSAN_PIN_CPU_D4, OKUSAN_PIN_CPU_D5, OKUSAN_PIN_CPU_D6, OKUSAN_PIN_CPU_D7
	};

	uint16_t oa16 = (uint16_t)(orig_a & 0xFFFFu);
	uint16_t ea16 = (uint16_t)(eff_a & 0xFFFFu);
	for (int bit = 0; bit < 15; ++bit) {
		okusan_trace_pin_bit(cpu_addr_pin[bit], (oa16 >> bit) & 1u, (ea16 >> bit) & 1u, oa16, ea16);
	}

	uint32_t rw_orig = is_write ? 0u : 1u;
	uint32_t rw_eff  = ((okusan_cart_rt.cached_pins[OKUSAN_PIN_CPU_RW] & 0x0Fu) == OKUSAN_PIN_OPEN) ? 1u : rw_orig;
	okusan_trace_pin_bit(OKUSAN_PIN_CPU_RW, rw_orig, rw_eff, (uint16_t)rw_orig, (uint16_t)rw_eff);

	uint32_t romsel_orig = (orig_a >= 0x8000u) ? 0u : 1u;
	uint32_t romsel_eff  = ((okusan_cart_rt.cached_pins[OKUSAN_PIN_ROMSEL] & 0x0Fu) == OKUSAN_PIN_OPEN) ? 1u : romsel_orig;
	okusan_trace_pin_bit(OKUSAN_PIN_ROMSEL, romsel_orig, romsel_eff, oa16, (uint16_t)(romsel_eff ? 0xFFFFu : ea16));

	if (orig_a >= 0x8000u || is_write) {
		for (int bit = 0; bit < 8; ++bit) {
			okusan_trace_pin_bit(cpu_data_pin[bit], (orig_d >> bit) & 1u, (eff_d >> bit) & 1u, orig_d, eff_d);
		}
	}
}

uint32_t okusan_prg_map_addr(uint32_t addr, int *romsel_open) {
	if (romsel_open) *romsel_open = 0;
	if (!okusan_cart_is_active() || addr < 0x4020u) return addr;
	if (okusan_cart_rt.power_dead) {
		if (romsel_open) *romsel_open = 1;
		return addr;
	}
	if (addr >= 0x8000u && okusan_ctrl_pin_dropped(OKUSAN_PIN_ROMSEL, 101u, 95u)) {
		if (romsel_open) *romsel_open = 1;
		return addr;
	}
	return (addr & ~0x7FFFu) | map_cpu_addr_bits(addr);
}

uint8_t okusan_prg_map_data(uint8_t val, uint8_t open_bus) {
	if (!okusan_cart_is_active()) return val;
	if (okusan_cart_rt.power_dead) return open_bus;
	return map_cpu_data_bits(val, open_bus);
}

int okusan_cpu_map_write(uint32_t addr, uint8_t val, uint32_t *out_addr, uint8_t *out_val) {
	*out_addr = addr;
	*out_val  = val;
	if (!okusan_cart_is_active() || addr < 0x4020u) return 1;
	if (okusan_cart_rt.power_dead) return 0;

	if (okusan_ctrl_pin_dropped(OKUSAN_PIN_CPU_RW, 149u, 110u)) return 0;
	if (okusan_ctrl_pin_dropped(OKUSAN_PIN_M2,     151u, 100u)) return 0;
	if (addr >= 0x8000u && okusan_ctrl_pin_dropped(OKUSAN_PIN_ROMSEL, 157u, 95u)) return 0;

	*out_addr = (addr & ~0x7FFFu) | map_cpu_addr_bits(addr);
	*out_val  = map_cpu_data_bits(val, okusan_last_cpu_data);
	return 1;
}

__attribute__((visibility("default")))
int okusan_map_irq(int irq_low) {
	int ext = irq_low & (FCEU_IQEXT | FCEU_IQEXT2);
	if (!ext) return irq_low;
	if (!okusan_cart_is_active()) {
		okusan_trace_pin_bit(OKUSAN_PIN_IRQ, 0u, 0u, (uint16_t)irq_low, (uint16_t)irq_low);
		return irq_low;
	}
	if (okusan_cart_rt.power_dead || okusan_ctrl_pin_dropped(OKUSAN_PIN_IRQ, 67u, 110u)) {
		okusan_trace_pin_bit(OKUSAN_PIN_IRQ, 0u, 1u, 0u, 1u);
		return irq_low & ~(FCEU_IQEXT | FCEU_IQEXT2);
	}
	okusan_trace_pin_bit(OKUSAN_PIN_IRQ, 0u, 0u, 0u, 0u);
	return irq_low;
}
