/* FCE Ultra - NES/Famicom Emulator
 *
 * Copyright notice for this file:
 *  Copyright (C) 1998 BERO
 *  Copyright (C) 2003 Xodnizel
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include        <string.h>
#include        <stdlib.h>

#include        "fceu-types.h"
#include        "x6502.h"
#include        "fceu.h"
#include        "ppu.h"
#include        "nsf.h"
#include        "sound.h"
#include        "general.h"
#include        "fceu-endian.h"
#include        "fceu-memory.h"

#include        "cart.h"
#include        "okusan_cart.h"
#include        "palette.h"
#include        "state.h"
#include        "video.h"
#include        "input.h"

#ifdef HAVE_HDPACK
#include        "hdpack/hdpack.h"
#endif

#define VBlankON        (PPU[0] & 0x80)		/* Generate VBlank NMI */
#define Sprite16        (PPU[0] & 0x20)		/* Sprites 8x16/8x8 */
#define BGAdrHI         (PPU[0] & 0x10)		/* BG pattern adr $0000/$1000 */
#define SpAdrHI         (PPU[0] & 0x08)		/* Sprite pattern adr $0000/$1000 */
#define INC32           (PPU[0] & 0x04)		/* auto increment 1/32 */

#define SpriteON        (PPU[1] & 0x10)		/* Show Sprite */
#define ScreenON        (PPU[1] & 0x08)		/* Show screen */
#define GRAYSCALE       (PPU[1] & 0x01)		/* Grayscale (AND palette entries with 0x30) */

#define PPU_status      (PPU[2])

#define Pal             (PALRAM)

static void FetchSpriteData(void);
static void FASTAPASS(1) RefreshLine(int lastpixel);
static void RefreshSprites(void);
static void CopySprites(uint8_t *target);

static void Fixit1(void);
static uint32_t ppulut1[256];
static uint32_t ppulut2[256];
static uint32_t ppulut3[128];

static void makeppulut(void) {
	int x;
	int y;
	int cc, xo, pixel;


	for (x = 0; x < 256; x++) {
		ppulut1[x] = 0;
		for (y = 0; y < 8; y++)
			ppulut1[x] |= ((x >> (7 - y)) & 1) << (y * 4);
		ppulut2[x] = ppulut1[x] << 1;
	}

	for (cc = 0; cc < 16; cc++) {
		for (xo = 0; xo < 8; xo++) {
			ppulut3[xo | (cc << 3)] = 0;
			for (pixel = 0; pixel < 8; pixel++) {
				int shiftr;
				shiftr = (pixel + xo) / 8;
				shiftr *= 2;
				ppulut3[xo | (cc << 3)] |= (uint32_t)((cc >> shiftr) & 3) << (2 + pixel * 4);
			}
		}
	}
}

static uint8_t ppudead = 1;
static uint8_t kook = 0;

int MMC5Hack = 0, PEC586Hack = 0;
uint32_t MMC5HackVROMMask = 0;
uint8_t *MMC5HackExNTARAMPtr = 0;
uint8_t *MMC5HackVROMPTR = 0;
uint8_t MMC5HackCHRMode = 0;
uint8_t MMC5HackSPMode = 0;
uint8_t MMC50x5130 = 0;
uint8_t MMC5HackSPScroll = 0;
uint8_t MMC5HackSPPage = 0;

uint8_t VRAMBuffer = 0, PPUGenLatch = 0;
uint8_t *vnapage[4];
uint8_t PPUNTARAM = 0;
uint8_t PPUCHRRAM = 0;

/* Color deemphasis emulation.  Joy... */
static uint8_t deemp = 0;
static int deempcnt[8];

void (*GameHBIRQHook)(void), (*GameHBIRQHook2)(void);
void FP_FASTAPASS(1) (*PPU_hook)(uint32_t A);

uint8_t vtoggle = 0;
uint8_t XOffset = 0;

uint32_t TempAddr = 0, RefreshAddr = 0;

static int maxsprites = 8;

/* scanline is equal to the current visible scanline we're on. */
int scanline;
static uint32_t scanlines_per_frame;

uint8_t PPU[4];
uint8_t PPUSPL;
uint8_t NTARAM[0x800], PALRAM[0x20], SPRAM[0x100], SPRBUF[0x100];
uint8_t UPALRAM[0x03];/* for 0x4/0x8/0xC addresses in palette, the ones in
					 * 0x20 are 0 to not break fceu rendering.
					 */

#define MMC5SPRVRAMADR(V)   &MMC5SPRVPage[(V) >> 10][(V)]
#define VRAMADR(V)          &VPage[(V) >> 10][(V)]

static uint8_t * MMC5BGVRAMADR(uint32_t V) {
	if (!Sprite16) {
		extern uint8_t mmc5ABMode;				/* A=0, B=1 */
		if (mmc5ABMode == 0)
			return MMC5SPRVRAMADR(V);
		else
			return &MMC5BGVPage[(V) >> 10][(V)];
	} else return &MMC5BGVPage[(V) >> 10][(V)];
}

/* Okusan CRT: Rigorous 60-Pin Physical Famicom Cartridge Edge-Connector Emulation
 *
 * Models all 60 physical contacts (Front 1..30, Back 31..60) at exact 2.54 mm pitch,
 * 78.00 mm PCB width, 1.55 mm gold fingers (0.99 mm gap), and 2.80..4.50 mm console
 * phosphor-bronze spring wiper crown inside a 10.00 mm deep slot with +/-0.35 mm side play.
 *
 * Mechanical verification:
 *   Max tilt+play lateral shift (~0.66 mm) < copper-short threshold (1.215 mm).
 *   Therefore pure tilting CANNOT physically short adjacent pads on a normal connector;
 *   neighbor interference occurs physically via capacitive/creepage crosstalk onto High-Z
 *   (OPEN / MARGINAL / WEAK) pins from actively driven same-face neighbors.
 */
static int okusan_tilt = 0;       /* -32 .. +32 (left/PRG lift .. 0 .. right/PPU lift) */
static int okusan_lift = 0;       /*   0 .. +16 (uniform vertical pull-up) */
static int okusan_pitch = 0;      /*  -8 .. +8  (front-back card rock in blue socket) */
static uint64_t okusan_pin_weak_mask = 0ULL; /* Per-pin explicit WEAK fault mask (bit i = Pin i) */
static uint64_t okusan_pin_open_mask = 0ULL; /* Per-pin explicit OPEN fault mask (bit i = Pin i) */
static uint32_t okusan_frame_tick = 0;

/* Pin index layout: 0..29 = Front Pins 1..30, 30..59 = Back Pins 31..60 */
enum {
	/* Front 1..30 (pos 0..29) */
	PIN_GND1 = 0,     PIN_CPU_A11 = 1,  PIN_CPU_A10 = 2,  PIN_CPU_A9 = 3,   PIN_CPU_A8 = 4,
	PIN_CPU_A7 = 5,   PIN_CPU_A6 = 6,   PIN_CPU_A5 = 7,   PIN_CPU_A4 = 8,   PIN_CPU_A3 = 9,
	PIN_CPU_A2 = 10,  PIN_CPU_A1 = 11,  PIN_CPU_A0 = 12,  PIN_CPU_RW = 13,  PIN_IRQ = 14,
	PIN_GND2 = 15,    PIN_PPU_RD = 16,  PIN_CIRAM_A10 = 17, PIN_PPU_A6 = 18, PIN_PPU_A5 = 19,
	PIN_PPU_A4 = 20,  PIN_PPU_A3 = 21,  PIN_PPU_A2 = 22,  PIN_PPU_A1 = 23,  PIN_PPU_A0 = 24,
	PIN_PPU_D0 = 25,  PIN_PPU_D1 = 26,  PIN_PPU_D2 = 27,  PIN_PPU_D3 = 28,  PIN_VCC_R = 29,
	/* Back 31..60 (pos 0..29) */
	PIN_VCC_L = 30,   PIN_M2 = 31,      PIN_CPU_A12 = 32, PIN_CPU_A13 = 33, PIN_CPU_A14 = 34,
	PIN_CPU_D7 = 35,  PIN_CPU_D6 = 36,  PIN_CPU_D5 = 37,  PIN_CPU_D4 = 38,  PIN_CPU_D3 = 39,
	PIN_CPU_D2 = 40,  PIN_CPU_D1 = 41,  PIN_CPU_D0 = 42,  PIN_ROMSEL = 43,  PIN_SND_IN = 44,
	PIN_SND_OUT = 45, PIN_PPU_WR = 46,  PIN_CIRAM_CE = 47, PIN_PPU_NA13 = 48, PIN_PPU_A7 = 49,
	PIN_PPU_A8 = 50,  PIN_PPU_A9 = 51,  PIN_PPU_A10 = 52, PIN_PPU_A11 = 53, PIN_PPU_A12 = 54,
	PIN_PPU_A13 = 55, PIN_PPU_D7 = 56,  PIN_PPU_D6 = 57,  PIN_PPU_D5 = 58,  PIN_PPU_D4 = 59
};

enum {
	PCLS_GND = 0,
	PCLS_VCC = 1,
	PCLS_SIG = 2
};

typedef struct {
	int16_t  wear_um; /* Per-pin spring/chamfer/oxide tolerance (-200 .. +180 um) */
	uint8_t  pclass;  /* PCLS_GND / PCLS_VCC / PCLS_SIG */
	uint8_t  salt;
} OkusanPin60;

static const OkusanPin60 okusan_pins60_spec[OKUSAN_CART_PIN_COUNT] = {
	/* Front 1..30 */
	{ -120, PCLS_GND, 11 }, { -180, PCLS_SIG, 13 }, {  +60, PCLS_SIG, 17 }, {  -40, PCLS_SIG, 19 }, { +110, PCLS_SIG, 23 },
	{ -150, PCLS_SIG, 29 }, {  +30, PCLS_SIG, 31 }, {  -90, PCLS_SIG, 37 }, { +140, PCLS_SIG, 41 }, {  -20, PCLS_SIG, 43 },
	{ +160, PCLS_SIG, 47 }, { -110, PCLS_SIG, 53 }, {  +80, PCLS_SIG, 59 }, {  -60, PCLS_SIG, 61 }, { +120, PCLS_SIG, 67 },
	{  -80, PCLS_GND, 71 }, {  +50, PCLS_SIG, 73 }, { -160, PCLS_SIG, 79 }, { +130, PCLS_SIG, 83 }, { -100, PCLS_SIG, 89 },
	{  +70, PCLS_SIG, 97 }, { -190, PCLS_SIG, 101}, { +150, PCLS_SIG, 103}, {  -50, PCLS_SIG, 107}, {  +90, PCLS_SIG, 109},
	{ -140, PCLS_SIG, 113}, { +110, PCLS_SIG, 127}, {  -70, PCLS_SIG, 131}, { +170, PCLS_SIG, 137}, {  -30, PCLS_VCC, 139},
	/* Back 31..60 */
	{  +90, PCLS_VCC, 149}, { -130, PCLS_SIG, 151}, { +140, PCLS_SIG, 157}, {  -70, PCLS_SIG, 163}, { +100, PCLS_SIG, 167},
	{ -170, PCLS_SIG, 173}, {  +40, PCLS_SIG, 179}, { -110, PCLS_SIG, 181}, { +160, PCLS_SIG, 191}, {  -30, PCLS_SIG, 193},
	{ +120, PCLS_SIG, 197}, {  -90, PCLS_SIG, 199}, { +180, PCLS_SIG, 211}, { -140, PCLS_SIG, 223}, {  +60, PCLS_SIG, 227},
	{ -100, PCLS_SIG, 229}, {  +80, PCLS_SIG, 233}, { -150, PCLS_SIG, 239}, { +130, PCLS_SIG, 241}, {  -60, PCLS_SIG, 251},
	{ +150, PCLS_SIG,  12}, { -120, PCLS_SIG,  24}, {  +40, PCLS_SIG,  36}, { -160, PCLS_SIG,  48}, { +110, PCLS_SIG,  60},
	{ -190, PCLS_SIG,  72}, { +120, PCLS_SIG,  84}, { -130, PCLS_SIG,  96}, {  +70, PCLS_SIG, 108}, { -200, PCLS_SIG, 120}
};

static uint8_t  okusan_cached_pins[OKUSAN_CART_PIN_COUNT];
static int16_t  okusan_cached_rise_um[OKUSAN_CART_PIN_COUNT];
static int16_t  okusan_cached_overlap_um[OKUSAN_CART_PIN_COUNT];
static int      okusan_cached_pwr_dead = 0;
static int      okusan_cached_vcc_mv   = 4978;
static int      okusan_cached_audio_q  = 256;
static int      okusan_gnd_bounce_cpu_q = 0;
static int      okusan_gnd_bounce_ppu_q = 0;
static int      okusan_vcc_slow_q       = 0;

static uint32_t okusan_last_cpu_addr = 0x8000u;
static uint8_t  okusan_last_cpu_data = 0xEAu;
static uint32_t okusan_last_ppu_addr = 0x0000u;
static uint8_t  okusan_last_ppu_data = 0x00u;
static uint32_t okusan_ppu_trace_div = 0;
static uint32_t okusan_nt_trace_div  = 0;

/* Live per-pin signal/data accumulators -> snapshotted each frame into okusan_frame_tel */
static uint32_t okusan_acc_cnt[OKUSAN_CART_PIN_COUNT];
static uint32_t okusan_acc_hi[OKUSAN_CART_PIN_COUNT];
static uint32_t okusan_acc_tog[OKUSAN_CART_PIN_COUNT];
static uint32_t okusan_acc_fault[OKUSAN_CART_PIN_COUNT];
static uint8_t  okusan_acc_prev_b[OKUSAN_CART_PIN_COUNT];
static uint16_t okusan_acc_orig_w[OKUSAN_CART_PIN_COUNT];
static uint16_t okusan_acc_eff_w[OKUSAN_CART_PIN_COUNT];
static OkusanPinTelemetry60 okusan_frame_tel[OKUSAN_CART_PIN_COUNT];

static INLINE void okusan_trace_pin_bit(int pin, uint32_t orig_b, uint32_t eff_b, uint16_t orig_w, uint16_t eff_w) {
	uint8_t eb = (uint8_t)(eff_b ? 1u : 0u);
	uint8_t ob = (uint8_t)(orig_b ? 1u : 0u);
	okusan_acc_cnt[pin]++;
	okusan_acc_hi[pin] += eb;
	if (eb != okusan_acc_prev_b[pin]) okusan_acc_tog[pin]++;
	if (eb != ob) okusan_acc_fault[pin]++;
	okusan_acc_prev_b[pin] = eb;
	okusan_acc_orig_w[pin] = orig_w;
	okusan_acc_eff_w[pin]  = eff_w;
}

static void okusan_finalize_frame_telemetry(void) {
	for (int i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
		OkusanPinTelemetry60 *t = &okusan_frame_tel[i];
		t->state      = okusan_cached_pins[i];
		t->rise_um    = okusan_cached_rise_um[i];
		t->overlap_um = okusan_cached_overlap_um[i];
		uint32_t c = okusan_acc_cnt[i];
		if (c > 0) {
			t->duty_pct  = (uint8_t)((okusan_acc_hi[i] * 100u + c / 2u) / c);
			t->fault_pct = (uint8_t)((okusan_acc_fault[i] * 100u + c / 2u) / c);
			uint32_t tr  = (okusan_acc_tog[i] * 100u) / c;
			t->toggling  = (uint8_t)(tr >= 12u ? 2u : (okusan_acc_tog[i] > 0u ? 1u : 0u));
			t->bus_orig  = okusan_acc_orig_w[i];
			t->bus_eff   = okusan_acc_eff_w[i];
		} else {
			/* Static / non-sampled rails: GND, +5V, M2 clock, /IRQ, Audio */
			if (i == PIN_GND1 || i == PIN_GND2) {
				t->duty_pct = 0; t->toggling = 0;
				t->fault_pct = ((okusan_cached_pins[i] & 0x0F) == OKUSAN_PIN_OPEN) ? 100 : 0;
				t->bus_orig = 0x0000u; t->bus_eff = t->fault_pct ? 0xFFFFu : 0x0000u;
			} else if (i == PIN_VCC_L || i == PIN_VCC_R) {
				uint8_t st = okusan_cached_pins[i] & 0x0F;
				t->duty_pct = (st == OKUSAN_PIN_OPEN) ? 0 : (uint8_t)((okusan_cached_vcc_mv * 100) / 5000);
				t->toggling = 0;
				t->fault_pct = (okusan_cached_pwr_dead || st == OKUSAN_PIN_OPEN) ? 100 : (st != OKUSAN_PIN_SEATED ? 25 : 0);
				t->bus_orig = 5000u;
				t->bus_eff  = (st == OKUSAN_PIN_OPEN) ? 0u : (uint16_t)okusan_cached_vcc_mv;
			} else if (i == PIN_M2) {
				uint8_t st = okusan_cached_pins[i] & 0x0F;
				t->duty_pct = (st == OKUSAN_PIN_OPEN) ? 100 : 62; t->toggling = (st == OKUSAN_PIN_OPEN) ? 0 : 2;
				t->fault_pct = (st == OKUSAN_PIN_OPEN) ? 100 : (st == OKUSAN_PIN_MARGINAL ? 45 : 0);
				t->bus_orig = 1789u; t->bus_eff = (st == OKUSAN_PIN_OPEN) ? 0u : 1789u;
			} else if (i == PIN_SND_IN || i == PIN_SND_OUT) {
				t->duty_pct = (uint8_t)((okusan_cached_audio_q * 100) / 256);
				t->toggling = (okusan_cached_audio_q > 0) ? 2 : 0;
				t->fault_pct = (uint8_t)(100 - t->duty_pct);
				t->bus_orig = 256u; t->bus_eff = (uint16_t)okusan_cached_audio_q;
			} else {
				uint8_t st = okusan_cached_pins[i] & 0x0F;
				t->duty_pct = 100; t->toggling = 0;
				t->fault_pct = (st == OKUSAN_PIN_OPEN) ? 100 : 0;
				t->bus_orig = 1u; t->bus_eff = (st == OKUSAN_PIN_OPEN) ? 0u : 1u;
			}
		}
		okusan_acc_cnt[i] = 0;
		okusan_acc_hi[i]  = 0;
		okusan_acc_tog[i] = 0;
		okusan_acc_fault[i] = 0;
	}
}

__attribute__((visibility("default")))
void okusan_trace_cpu_bus(uint32_t orig_a, uint32_t eff_a, uint8_t orig_d, uint8_t eff_d, int is_write) {
	static const int cpu_addr_pin[15] = {
		PIN_CPU_A0,  PIN_CPU_A1,  PIN_CPU_A2,  PIN_CPU_A3,  PIN_CPU_A4,
		PIN_CPU_A5,  PIN_CPU_A6,  PIN_CPU_A7,  PIN_CPU_A8,  PIN_CPU_A9,
		PIN_CPU_A10, PIN_CPU_A11, PIN_CPU_A12, PIN_CPU_A13, PIN_CPU_A14
	};
	static const int cpu_data_pin[8] = {
		PIN_CPU_D0, PIN_CPU_D1, PIN_CPU_D2, PIN_CPU_D3,
		PIN_CPU_D4, PIN_CPU_D5, PIN_CPU_D6, PIN_CPU_D7
	};
	uint16_t oa16 = (uint16_t)(orig_a & 0xFFFFu);
	uint16_t ea16 = (uint16_t)(eff_a & 0xFFFFu);
	for (int b = 0; b < 15; ++b) {
		okusan_trace_pin_bit(cpu_addr_pin[b], (oa16 >> b) & 1u, (ea16 >> b) & 1u, oa16, ea16);
	}
	uint32_t rw_o = is_write ? 0u : 1u;
	uint32_t rw_e = ((okusan_cached_pins[PIN_CPU_RW] & 0x0Fu) == OKUSAN_PIN_OPEN) ? 1u : rw_o;
	okusan_trace_pin_bit(PIN_CPU_RW, rw_o, rw_e, (uint16_t)rw_o, (uint16_t)rw_e);

	uint32_t rom_o = (orig_a >= 0x8000u) ? 0u : 1u;
	uint32_t rom_e = ((okusan_cached_pins[PIN_ROMSEL] & 0x0Fu) == OKUSAN_PIN_OPEN) ? 1u : rom_o;
	okusan_trace_pin_bit(PIN_ROMSEL, rom_o, rom_e, oa16, (uint16_t)(rom_e ? 0xFFFFu : ea16));

	if (orig_a >= 0x8000u || is_write) {
		for (int b = 0; b < 8; ++b) {
			okusan_trace_pin_bit(cpu_data_pin[b], (orig_d >> b) & 1u, (eff_d >> b) & 1u, orig_d, eff_d);
		}
	}
}

static INLINE int okusan_pin_x_um(int idx) {
	int pos = (idx < 30) ? idx : (idx - 30);
	return (pos * 2 - 29) * (OKUSAN_PIN_PITCH_UM / 2);
}

/* Rigid-body straight PCB edge rise in micrometers: zero floor clipping (~4.3 deg chute limit) */
__attribute__((visibility("default")))
int okusan_cart_edge_rise_um(int tilt, int lift, int x_um) {
	int lift_um = lift * 330;
	if (tilt == 0) return lift_um;
	int at = tilt < 0 ? -tilt : tilt;
	int dist_um = (tilt > 0) ? (x_um + OKUSAN_CARD_HALF_UM) : (OKUSAN_CARD_HALF_UM - x_um);
	if (dist_um < 0) dist_um = 0;
	int tilt_um = (at * 185 * dist_um) / (2 * OKUSAN_CARD_HALF_UM);
	return lift_um + tilt_um;
}

/* Per-pin 3-DOF rigid rise (tilt + lift + front-back rock lever across 1.6mm PCB) */
static INLINE int okusan_cart_pin_rise_um(int tilt, int lift, int pitch, int pin_idx) {
	int r = okusan_cart_edge_rise_um(tilt, lift, okusan_pin_x_um(pin_idx));
	if (pitch != 0) {
		/* pitch > 0: rocked forward -> minor vertical lever across 1.6mm PCB (dominant effect is normal preload) */
		int face_lift = (pin_idx < 30) ? (-pitch * 45) : (+pitch * 45);
		r += face_lift;
		if (r < 0) r = 0;
	}
	return r;
}

__attribute__((visibility("default")))
int okusan_cart_lat_shift_um(int tilt, int lift) {
	int at = tilt < 0 ? -tilt : tilt;
	if (at == 0) return 0;
	int eff_h = 3350 - (lift * 330) / 2;
	if (eff_h < 800) eff_h = 800;
	int geom = (at * 185 * eff_h) / (2 * OKUSAN_CARD_HALF_UM);
	int play = (at * OKUSAN_SLOT_PLAY_UM) / 32;
	return geom + play;
}

/* Very slow, rare contact micro-drift (~2.1 sec step at 60 Hz) so faults stay rock-steady */
static INLINE uint32_t okusan_frame_drift(uint32_t salt) {
	uint32_t step = (okusan_frame_tick >> 7) + salt * 41u;
	uint32_t h = (step ^ (step >> 3)) * 2246822519u;
	return (h >> 24) & 255u;
}

static INLINE uint32_t okusan_pin_chatter(uint32_t salt) {
	return okusan_frame_drift(salt + 17u);
}

/* Contact resistance in 0.1-ohm units (dOhm) for power-rail Ohm's law brownout model */
static INLINE int okusan_pin_res_dohm(uint8_t st, int ov_um) {
	uint8_t base = st & 0x0Fu;
	if (base == OKUSAN_PIN_SEATED) return 2; /* 0.2 ohm */
	if (base == OKUSAN_PIN_WEAK) {
		int d = 960 - ov_um;
		if (d < 0) d = 0;
		return 2 + (d * 40) / 540; /* 0.2 .. 4.2 ohm */
	}
	if (base == OKUSAN_PIN_MARGINAL) {
		int d = 420 - ov_um;
		if (d < 0) d = 0;
		return 80 + (d * 400) / 380; /* 8.0 .. 48.0 ohm oxidized tip point contact */
	}
	return 100000; /* 10 kOhm open */
}

static void okusan_refresh_frame_cache(void) {
	int i;
	const int any_geom = (okusan_tilt != 0 || okusan_lift != 0 || okusan_pitch != 0);
	const int any_mask = (okusan_pin_weak_mask != 0ULL || okusan_pin_open_mask != 0ULL);
	if (!any_geom) {
		for (i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
			okusan_cached_pins[i]       = OKUSAN_PIN_SEATED;
			okusan_cached_rise_um[i]    = 0;
			okusan_cached_overlap_um[i] = OKUSAN_WIPER_TOP_UM - OKUSAN_WIPER_BOT_UM;
		}
		if (!any_mask) {
			okusan_cached_vcc_mv    = 4978;
			okusan_cached_pwr_dead  = 0;
			okusan_cached_audio_q   = 256;
			okusan_gnd_bounce_cpu_q = 0;
			okusan_gnd_bounce_ppu_q = 0;
			okusan_vcc_slow_q       = 0;
			return;
		}
	} else {
		/* Lateral pad-to-wiper width reduction from tilt+play shear (without adjacent copper bridging) */
		int lat_um = okusan_cart_lat_shift_um(okusan_tilt, okusan_lift);
		int lat_ov_w = (OKUSAN_PAD_WIDTH_UM + OKUSAN_WIPER_WIDTH_UM) / 2 - lat_um;
		if (lat_ov_w > OKUSAN_WIPER_WIDTH_UM) lat_ov_w = OKUSAN_WIPER_WIDTH_UM;
		if (lat_ov_w < 0) lat_ov_w = 0;

		for (i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
			int rise = okusan_cart_pin_rise_um(okusan_tilt, okusan_lift, okusan_pitch, i);
			int eff_bot = OKUSAN_PAD_BOT_UM + rise + okusan_pins60_spec[i].wear_um;
			int eff_top = OKUSAN_PAD_TOP_UM + rise + okusan_pins60_spec[i].wear_um;
			int ov_lo = eff_bot > OKUSAN_WIPER_BOT_UM ? eff_bot : OKUSAN_WIPER_BOT_UM;
			int ov_hi = eff_top < OKUSAN_WIPER_TOP_UM ? eff_top : OKUSAN_WIPER_TOP_UM;
			int ov_v = ov_hi - ov_lo;
			if (ov_v < 0) ov_v = 0;
			if (ov_v > (OKUSAN_WIPER_TOP_UM - OKUSAN_WIPER_BOT_UM)) {
				ov_v = OKUSAN_WIPER_TOP_UM - OKUSAN_WIPER_BOT_UM;
			}

			/* Spring wiper normal preload (450um nominal): pitch > 0 loads Front, unloads Back */
			int preload_um = 450 + ((i < 30) ? (+okusan_pitch * 68) : (-okusan_pitch * 68));
			int eff_preload = preload_um > 450 ? 450 : (preload_um < 0 ? 0 : preload_um);
			int ov = (ov_v * lat_ov_w) / OKUSAN_WIPER_WIDTH_UM;
			ov = (ov * eff_preload) / 450;

			uint32_t d = okusan_frame_drift(okusan_pins60_spec[i].salt);
			uint8_t st;
			if (ov >= 960) {
				st = OKUSAN_PIN_SEATED;
			} else if (ov >= 920) {
				st = (d < 24u) ? OKUSAN_PIN_WEAK : OKUSAN_PIN_SEATED;
			} else if (ov >= 420) {
				st = OKUSAN_PIN_WEAK;
			} else if (ov >= 380) {
				st = (d < 24u) ? OKUSAN_PIN_MARGINAL : OKUSAN_PIN_WEAK;
			} else if (ov >= 70) {
				st = OKUSAN_PIN_MARGINAL;
			} else if (ov >= 40) {
				st = (d < 24u) ? OKUSAN_PIN_OPEN : OKUSAN_PIN_MARGINAL;
			} else {
				st = OKUSAN_PIN_OPEN;
			}

			okusan_cached_pins[i]       = st;
			okusan_cached_rise_um[i]    = (int16_t)rise;
			okusan_cached_overlap_um[i] = (int16_t)ov;
		}
	}

	if (any_mask) {
		for (i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
			uint64_t bit = 1ULL << i;
			if (okusan_pin_open_mask & bit) {
				okusan_cached_pins[i]       = OKUSAN_PIN_OPEN;
				okusan_cached_overlap_um[i] = 0;
				if (okusan_cached_rise_um[i] < 2400) okusan_cached_rise_um[i] = 2400;
			} else if ((okusan_pin_weak_mask & bit) && (okusan_cached_pins[i] & 0x0Fu) < OKUSAN_PIN_WEAK) {
				int weak_ov = 700 + okusan_pins60_spec[i].wear_um;
				if (weak_ov < 440) weak_ov = 440;
				if (weak_ov > 940) weak_ov = 940;
				okusan_cached_pins[i]       = OKUSAN_PIN_WEAK;
				okusan_cached_overlap_um[i] = (int16_t)weak_ov;
				if (okusan_cached_rise_um[i] < 900) okusan_cached_rise_um[i] = 900;
			}
		}
	}

	/* Strict Ohm's-law power rail calculation across Pin 1/16 (GND) & Pin 30/31 (+5V) at ~110mA load */
	int r_gnd1 = okusan_pin_res_dohm(okusan_cached_pins[PIN_GND1],  okusan_cached_overlap_um[PIN_GND1]);
	int r_gnd2 = okusan_pin_res_dohm(okusan_cached_pins[PIN_GND2],  okusan_cached_overlap_um[PIN_GND2]);
	int r_vccL = okusan_pin_res_dohm(okusan_cached_pins[PIN_VCC_L], okusan_cached_overlap_um[PIN_VCC_L]);
	int r_vccR = okusan_pin_res_dohm(okusan_cached_pins[PIN_VCC_R], okusan_cached_overlap_um[PIN_VCC_R]);
	long long rg = ((long long)r_gnd1 * r_gnd2) / (r_gnd1 + r_gnd2);
	long long rv = ((long long)r_vccL * r_vccR) / (r_vccL + r_vccR);
	long long drop_mv = (rg + rv) * 11LL; /* 1 dOhm (0.1 ohm) * 110 mA = 11 mV */
	int vcc_mv = (drop_mv >= 5000LL) ? 0 : (int)(5000LL - drop_mv);
	okusan_cached_vcc_mv    = vcc_mv;
	okusan_cached_pwr_dead  = (vcc_mv < 3400) ? 1 : 0; /* < 3.40V brownout cutoff -> unpowered */
	okusan_vcc_slow_q       = (vcc_mv >= 3400 && vcc_mv < 4350) ? (((4350 - vcc_mv) * 140) / 950) : 0;
	okusan_gnd_bounce_cpu_q = (r_gnd1 > r_gnd2 + 10) ? (r_gnd1 > 100 ? 72 : (r_gnd1 * 72) / 100) : 0;
	okusan_gnd_bounce_ppu_q = (r_gnd2 > r_gnd1 + 10) ? (r_gnd2 > 100 ? 72 : (r_gnd2 * 72) / 100) : 0;

	int s_in  = okusan_cached_pins[PIN_SND_IN]  & 0x0F;
	int s_out = okusan_cached_pins[PIN_SND_OUT] & 0x0F;
	int s_worst = s_in > s_out ? s_in : s_out;
	if (s_worst == OKUSAN_PIN_SEATED)        okusan_cached_audio_q = 256;
	else if (s_worst == OKUSAN_PIN_WEAK)     okusan_cached_audio_q = 192;
	else if (s_worst == OKUSAN_PIN_MARGINAL) okusan_cached_audio_q = (int)(72u + (okusan_frame_drift(227u) >> 1));
	else                                     okusan_cached_audio_q = 0;

	for (i = 0; i < OKUSAN_CART_PIN_COUNT; ++i) {
		uint8_t st = okusan_cached_pins[i] & 0x0F;
		if (st == OKUSAN_PIN_SEATED || okusan_pins60_spec[i].pclass != PCLS_SIG) continue;
		int pos = (i < 30) ? i : (i - 30);
		if (pos > 0) {
			uint8_t nst = okusan_cached_pins[i - 1] & 0x0F;
			if (okusan_pins60_spec[i - 1].pclass != PCLS_GND && nst != OKUSAN_PIN_OPEN) {
				okusan_cached_pins[i] |= OKUSAN_PIN_FLAG_XTALK_L;
			}
		}
		if (pos < 29) {
			uint8_t nst = okusan_cached_pins[i + 1] & 0x0F;
			if (okusan_pins60_spec[i + 1].pclass != PCLS_GND && nst != OKUSAN_PIN_OPEN) {
				okusan_cached_pins[i] |= OKUSAN_PIN_FLAG_XTALK_R;
			}
		}
	}
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
	okusan_refresh_frame_cache();
}

__attribute__((visibility("default")))
void okusan_set_cart_contact(int tilt, int lift) {
	okusan_set_cart_contact3(tilt, lift, 0);
}

__attribute__((visibility("default")))
void okusan_set_pin_fault_masks(uint64_t weak_mask, uint64_t open_mask) {
	okusan_pin_weak_mask = weak_mask;
	okusan_pin_open_mask = open_mask;
	okusan_refresh_frame_cache();
}

__attribute__((visibility("default")))
int okusan_cart_is_active(void) {
	return (okusan_tilt != 0 || okusan_lift != 0 || okusan_pitch != 0 ||
	        okusan_pin_weak_mask != 0ULL || okusan_pin_open_mask != 0ULL);
}

__attribute__((visibility("default")))
int okusan_cart_is_powered(void) {
	return okusan_cached_pwr_dead ? 0 : 1;
}

__attribute__((visibility("default")))
int okusan_cart_vcc_mv(void) {
	return okusan_cached_vcc_mv;
}

__attribute__((visibility("default")))
void okusan_get_pin_telemetry60(int *out_tilt, int *out_lift, int *out_pitch,
                                OkusanPinTelemetry60 *out_tel, int max_pins) {
	if (out_tilt)  *out_tilt  = okusan_tilt;
	if (out_lift)  *out_lift  = okusan_lift;
	if (out_pitch) *out_pitch = okusan_pitch;
	if (!out_tel || max_pins <= 0) return;
	int n = max_pins < OKUSAN_CART_PIN_COUNT ? max_pins : OKUSAN_CART_PIN_COUNT;
	for (int i = 0; i < n; ++i) {
		out_tel[i] = okusan_frame_tel[i];
		out_tel[i].state      = okusan_cached_pins[i];
		out_tel[i].rise_um    = okusan_cached_rise_um[i];
		out_tel[i].overlap_um = okusan_cached_overlap_um[i];
	}
}

__attribute__((visibility("default")))
int okusan_get_audio_contact_q(void) {
	return okusan_cached_audio_q;
}

static INLINE uint32_t okusan_pin_xfer_bit(
	int pin_idx, uint32_t val_bit, uint32_t prev_bit,
	uint32_t xtalk_l_bit, uint32_t xtalk_r_bit, uint32_t float_bit,
	uint32_t bus_hash, int is_ppu) {
	uint8_t raw = okusan_cached_pins[pin_idx];
	uint8_t st  = raw & 0x0Fu;
	uint32_t vb = val_bit ? 1u : 0u;
	uint32_t pb = prev_bit ? 1u : 0u;
	int stress_q = (is_ppu ? okusan_gnd_bounce_ppu_q : okusan_gnd_bounce_cpu_q) + okusan_vcc_slow_q;

	if (st == OKUSAN_PIN_SEATED) {
		if (stress_q > 0 && vb != pb) {
			uint32_t h = (bus_hash ^ okusan_pins60_spec[pin_idx].salt ^ (okusan_frame_tick >> 7)) & 255u;
			if (h < (uint32_t)(stress_q / 3)) return pb;
		}
		return vb;
	}

	uint32_t fb = float_bit ? 1u : 0u;
	int has_xl = (raw & OKUSAN_PIN_FLAG_XTALK_L) != 0;
	int has_xr = (raw & OKUSAN_PIN_FLAG_XTALK_R) != 0;
	uint32_t xb = has_xl ? (xtalk_l_bit ? 1u : 0u) : (has_xr ? (xtalk_r_bit ? 1u : 0u) : fb);
	uint32_t drift = okusan_pin_chatter(okusan_pins60_spec[pin_idx].salt);

	if (st == OKUSAN_PIN_WEAK) {
		/* Asymmetric RC slew lag: 0->1 pull-up rises slower than 1->0 NMOS sink, scaled continuously by area */
		int ov = okusan_cached_overlap_um[pin_idx];
		int weak_q = ((960 - ov) * 205) / 540 + stress_q;
		if (weak_q < 0) weak_q = 0;
		if (weak_q > 255) weak_q = 255;
		uint32_t phase = (bus_hash + okusan_pins60_spec[pin_idx].salt * 19u + (drift >> 3)) & 255u;
		if (!is_ppu && ov >= 620) {
			/* On light/medium oxidized CPU pins, slew glitch occurs only on rare edge transitions
			 * (~1 in 2048 transitions) so the game boots past the reset vector and glitches/crashes organically. */
			if (((bus_hash ^ okusan_frame_tick) & 15u) != 0u) return vb;
			phase = ((bus_hash * 29u) + (drift >> 1)) & 1023u;
			weak_q = (weak_q >> 5) + 1;
		}
		if (vb && !pb) {
			if (phase < (uint32_t)weak_q) return 0u;
		} else if (!vb && pb) {
			int fall_q = (weak_q > 130) ? ((weak_q - 130) * 2) : 0;
			if (phase < (uint32_t)fall_q) return 1u;
		} else if (weak_q >= 235 && phase < 24u) {
			return pb ^ 1u;
		}
		return vb;
	}

	if (st == OKUSAN_PIN_MARGINAL) {
		/* Grazing chamfer contact: holds neighbor/prev steadily, with only very rare glitches */
		if (drift < 12u) return fb;
		if (has_xl || has_xr) return xb;
		return (vb != pb) ? pb : vb;
	}

	/* OKUSAN_PIN_OPEN: High-Z capacitive coupling tracks driven neighbor stably, else floats */
	if ((has_xl || has_xr) && xb != fb) return xb;
	return fb;
}

static INLINE uint32_t okusan_map_cpu_addr_bits(uint32_t addr) {
	static const int cpu_addr_pin[15] = {
		PIN_CPU_A0,  PIN_CPU_A1,  PIN_CPU_A2,  PIN_CPU_A3,  PIN_CPU_A4,
		PIN_CPU_A5,  PIN_CPU_A6,  PIN_CPU_A7,  PIN_CPU_A8,  PIN_CPU_A9,
		PIN_CPU_A10, PIN_CPU_A11, PIN_CPU_A12, PIN_CPU_A13, PIN_CPU_A14
	};
	static const int xtalk_l_bit[15] = {
		 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, -1, -1, 12, 13
	};
	static const int xtalk_r_bit[15] = {
		-1,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 13, 14, -1
	};

	uint32_t prev = okusan_last_cpu_addr;
	uint32_t bh = (addr ^ (addr >> 7)) & 255u;
	uint32_t out = 0u;
	for (int b = 0; b < 15; ++b) {
		uint32_t vb = (addr >> b) & 1u;
		uint32_t pb = (prev >> b) & 1u;
		uint32_t xl = (xtalk_l_bit[b] >= 0) ? ((addr >> xtalk_l_bit[b]) & 1u) : 0u;
		uint32_t xr = (xtalk_r_bit[b] >= 0) ? ((addr >> xtalk_r_bit[b]) & 1u) : 1u;
		uint32_t rb = okusan_pin_xfer_bit(cpu_addr_pin[b], vb, pb, xl, xr, 1u, bh + (uint32_t)b * 7u, 0);
		out |= (rb << b);
	}
	okusan_last_cpu_addr = addr;
	return out;
}

static INLINE uint8_t okusan_map_cpu_data_bits(uint8_t val, uint8_t open_bus) {
	static const int cpu_data_pin[8] = {
		PIN_CPU_D0, PIN_CPU_D1, PIN_CPU_D2, PIN_CPU_D3,
		PIN_CPU_D4, PIN_CPU_D5, PIN_CPU_D6, PIN_CPU_D7
	};
	uint32_t prev = okusan_last_cpu_data;
	uint32_t bh = (okusan_last_cpu_addr ^ ((uint32_t)val << 3)) & 255u;
	uint32_t out = 0u;
	for (int b = 0; b < 8; ++b) {
		uint32_t vb = ((uint32_t)val >> b) & 1u;
		uint32_t pb = (prev >> b) & 1u;
		uint32_t xl = (b < 7) ? (((uint32_t)val >> (b + 1)) & 1u) : ((okusan_last_cpu_addr >> 14) & 1u);
		uint32_t xr = (b > 0) ? (((uint32_t)val >> (b - 1)) & 1u) : 0u;
		uint32_t fb = ((uint32_t)open_bus >> b) & 1u;
		if ((okusan_cached_pins[cpu_data_pin[b]] & 0x0Fu) == OKUSAN_PIN_OPEN &&
		    okusan_pin_chatter(211u + (uint32_t)b) < 72u) {
			fb = 1u;
		}
		uint32_t rb = okusan_pin_xfer_bit(cpu_data_pin[b], vb, pb, xl, xr, fb, bh + (uint32_t)b * 13u, 0);
		out |= (rb << b);
	}
	okusan_last_cpu_data = val;
	return (uint8_t)out;
}

static INLINE int okusan_ctrl_pin_dropped(int pin_idx, uint32_t salt, uint32_t thresh) {
	uint8_t st = okusan_cached_pins[pin_idx] & 0x0Fu;
	return (st == OKUSAN_PIN_OPEN ||
	        (st == OKUSAN_PIN_MARGINAL && okusan_pin_chatter(salt) < thresh));
}

/* Real 6502 cartridge bus hooks ($4020-$FFFF) called from x6502.c */
uint32_t okusan_prg_map_addr(uint32_t addr, int *romsel_open) {
	if (romsel_open) *romsel_open = 0;
	if (!okusan_cart_is_active() || addr < 0x4020u) return addr;
	if (okusan_cached_pwr_dead) {
		if (romsel_open) *romsel_open = 1;
		return addr;
	}

	if (addr >= 0x8000u && okusan_ctrl_pin_dropped(PIN_ROMSEL, 101u, 95u)) {
		if (romsel_open) *romsel_open = 1;
		return addr;
	}

	uint32_t a15_hi = addr & ~0x7FFFu;
	return a15_hi | okusan_map_cpu_addr_bits(addr);
}

uint8_t okusan_prg_map_data(uint8_t val, uint8_t open_bus) {
	if (!okusan_cart_is_active()) return val;
	if (okusan_cached_pwr_dead) return open_bus;
	return okusan_map_cpu_data_bits(val, open_bus);
}

int okusan_cpu_map_write(uint32_t addr, uint8_t val, uint32_t *out_addr, uint8_t *out_val) {
	*out_addr = addr;
	*out_val  = val;
	if (!okusan_cart_is_active() || addr < 0x4020u) return 1;
	if (okusan_cached_pwr_dead) return 0;

	if (okusan_ctrl_pin_dropped(PIN_CPU_RW, 149u, 110u)) return 0;
	if (okusan_ctrl_pin_dropped(PIN_M2,     151u, 100u)) return 0;
	if (addr >= 0x8000u && okusan_ctrl_pin_dropped(PIN_ROMSEL, 157u, 95u)) return 0;

	*out_addr = (addr & ~0x7FFFu) | okusan_map_cpu_addr_bits(addr);
	*out_val  = okusan_map_cpu_data_bits(val, okusan_last_cpu_data);
	return 1;
}

__attribute__((visibility("default")))
int okusan_map_irq(int irq_low) {
	int ext = irq_low & (FCEU_IQEXT | FCEU_IQEXT2);
	if (!ext) return irq_low;
	if (!okusan_cart_is_active()) {
		okusan_trace_pin_bit(PIN_IRQ, 0u, 0u, (uint16_t)irq_low, (uint16_t)irq_low);
		return irq_low;
	}
	if (okusan_cached_pwr_dead || okusan_ctrl_pin_dropped(PIN_IRQ, 67u, 110u)) {
		okusan_trace_pin_bit(PIN_IRQ, 0u, 1u, 0u, 1u);
		return irq_low & ~(FCEU_IQEXT | FCEU_IQEXT2);
	}
	okusan_trace_pin_bit(PIN_IRQ, 0u, 0u, 0u, 0u);
	return irq_low;
}

static INLINE void okusan_trace_ppu_addr_pins(uint32_t orig_a, uint32_t eff_a) {
	static const int ppu_addr_pin[14] = {
		PIN_PPU_A0, PIN_PPU_A1, PIN_PPU_A2,  PIN_PPU_A3,  PIN_PPU_A4,  PIN_PPU_A5,  PIN_PPU_A6,
		PIN_PPU_A7, PIN_PPU_A8, PIN_PPU_A9,  PIN_PPU_A10, PIN_PPU_A11, PIN_PPU_A12, PIN_PPU_A13
	};
	uint16_t oa = (uint16_t)(orig_a & 0x3FFFu);
	uint16_t ea = (uint16_t)(eff_a  & 0x3FFFu);
	for (int b = 0; b < 14; ++b) {
		okusan_trace_pin_bit(ppu_addr_pin[b], (oa >> b) & 1u, (ea >> b) & 1u, oa, ea);
	}
	uint32_t na13_o = ((oa >> 13) & 1u) ^ 1u;
	uint32_t na13_e = ((okusan_cached_pins[PIN_PPU_NA13] & 0x0Fu) == OKUSAN_PIN_OPEN) ? 1u : na13_o;
	okusan_trace_pin_bit(PIN_PPU_NA13, na13_o, na13_e, (uint16_t)na13_o, (uint16_t)na13_e);
	uint32_t rd_o = 0u; /* PPU /RD is LOW during pattern/NT read fetches */
	uint32_t rd_e = ((okusan_cached_pins[PIN_PPU_RD] & 0x0Fu) == OKUSAN_PIN_OPEN) ? 1u : 0u;
	okusan_trace_pin_bit(PIN_PPU_RD, rd_o, rd_e, oa, ea);
}

static INLINE void okusan_trace_ppu_data_pins(uint8_t orig_d, uint8_t eff_d) {
	static const int ppu_data_pin[8] = {
		PIN_PPU_D0, PIN_PPU_D1, PIN_PPU_D2, PIN_PPU_D3,
		PIN_PPU_D4, PIN_PPU_D5, PIN_PPU_D6, PIN_PPU_D7
	};
	for (int b = 0; b < 8; ++b) {
		okusan_trace_pin_bit(ppu_data_pin[b], (orig_d >> b) & 1u, (eff_d >> b) & 1u, orig_d, eff_d);
	}
}

static INLINE int okusan_map_nt(int ntIdx) {
	uint32_t bit = (uint32_t)(ntIdx & 1);
	if (!okusan_cart_is_active()) {
		if ((okusan_nt_trace_div & 63u) == 0u) {
			okusan_trace_pin_bit(PIN_CIRAM_A10, bit, bit, (uint16_t)ntIdx, (uint16_t)ntIdx);
		}
		return ntIdx;
	}
	uint32_t a6  = (okusan_last_ppu_addr >> 6) & 1u;
	uint32_t mapped = okusan_pin_xfer_bit(PIN_CIRAM_A10, bit, bit, 0u, a6, 1u, okusan_last_ppu_addr & 255u, 1);
	int res = (ntIdx & ~1) | (int)mapped;
	if ((okusan_nt_trace_div & 63u) == 0u) {
		okusan_trace_pin_bit(PIN_CIRAM_A10, bit, mapped, (uint16_t)ntIdx, (uint16_t)res);
	}
	return res;
}

static INLINE uint8_t okusan_read_nt_byte(const uint8_t *nt_page, uint32_t off) {
	uint32_t do_tr = ((++okusan_nt_trace_div & 63u) == 0u);
	if (!okusan_cart_is_active()) {
		if (do_tr) {
			okusan_trace_pin_bit(PIN_CIRAM_CE, 0u, 0u, (uint16_t)(0x2000u | off), (uint16_t)(0x2000u | off));
			okusan_trace_ppu_addr_pins(0x2000u | off, 0x2000u | off);
		}
		return nt_page[off];
	}
	uint8_t ce_st  = okusan_cached_pins[PIN_CIRAM_CE] & 0x0Fu;
	uint8_t na13   = okusan_cached_pins[PIN_PPU_NA13] & 0x0Fu;
	int open_bus_nt = (okusan_cached_pwr_dead || ce_st == OKUSAN_PIN_OPEN || na13 == OKUSAN_PIN_OPEN ||
	                   ((ce_st == OKUSAN_PIN_MARGINAL || ce_st == OKUSAN_PIN_WEAK ||
	                     na13 == OKUSAN_PIN_MARGINAL || na13 == OKUSAN_PIN_WEAK) &&
	                    ((off + okusan_pin_chatter(239u)) & 255u) < 42u));
	if (do_tr) {
		okusan_trace_pin_bit(PIN_CIRAM_CE, 0u, open_bus_nt ? 1u : 0u,
		                     (uint16_t)(0x2000u | off),
		                     open_bus_nt ? (uint16_t)(off & 0xFFu) : (uint16_t)(0x2000u | off));
		okusan_trace_ppu_addr_pins(0x2000u | off, 0x2000u | off);
	}
	return open_bus_nt ? (uint8_t)(off & 0xFFu) : nt_page[off];
}

static INLINE uint32_t okusan_map_chr_addr(uint32_t vadr, int plane) {
	(void)plane;
	uint32_t a = vadr & 0x1FFFu;
	uint32_t do_tr = ((++okusan_ppu_trace_div & 31u) == 0u);
	if (!okusan_cart_is_active()) {
		if (do_tr) okusan_trace_ppu_addr_pins(a, a);
		return a;
	}
	if (okusan_cached_pwr_dead) {
		if (do_tr) okusan_trace_ppu_addr_pins(a, 0x3FFFu);
		return 0x1FFFu;
	}

	static const int ppu_addr_pin[14] = {
		PIN_PPU_A0, PIN_PPU_A1, PIN_PPU_A2,  PIN_PPU_A3,  PIN_PPU_A4,  PIN_PPU_A5,  PIN_PPU_A6,
		PIN_PPU_A7, PIN_PPU_A8, PIN_PPU_A9,  PIN_PPU_A10, PIN_PPU_A11, PIN_PPU_A12, PIN_PPU_A13
	};
	static const int xtalk_l_bit[14] = {
		 1,  2,  3,  4,  5,  6, -1,
		-1,  7,  8,  9, 10, 11, 12
	};
	static const int xtalk_r_bit[14] = {
		-1,  0,  1,  2,  3,  4,  5,
		 8,  9, 10, 11, 12, 13, -1
	};

	uint32_t prev = okusan_last_ppu_addr;
	uint32_t full = vadr & 0x3FFFu;
	uint32_t bh = (full ^ (full >> 6)) & 255u;
	uint32_t out  = 0u;
	for (int b = 0; b < 13; ++b) {
		uint32_t vb = (full >> b) & 1u;
		uint32_t pb = (prev >> b) & 1u;
		uint32_t xl = (xtalk_l_bit[b] >= 0) ? ((full >> xtalk_l_bit[b]) & 1u) : ((okusan_last_ppu_data >> 7) & 1u);
		uint32_t xr = (xtalk_r_bit[b] >= 0) ? ((full >> xtalk_r_bit[b]) & 1u) : (okusan_last_ppu_data & 1u);
		uint32_t rb = okusan_pin_xfer_bit(ppu_addr_pin[b], vb, pb, xl, xr, 1u, bh + (uint32_t)b * 11u, 1);
		out |= (rb << b);
	}
	okusan_last_ppu_addr = full;
	if (do_tr) {
		uint32_t a13_e = ((okusan_cached_pins[PIN_PPU_A13] & 0x0Fu) == OKUSAN_PIN_OPEN) ? 1u : 0u;
		okusan_trace_ppu_addr_pins(full, (out & 0x1FFFu) | (a13_e << 13));
	}
	return out & 0x1FFFu;
}

static INLINE uint8_t okusan_map_ppu_data_bus(uint8_t val, uint8_t open_bus, uint32_t vadr) {
	(void)open_bus;
	static const int ppu_data_pin[8] = {
		PIN_PPU_D0, PIN_PPU_D1, PIN_PPU_D2, PIN_PPU_D3,
		PIN_PPU_D4, PIN_PPU_D5, PIN_PPU_D6, PIN_PPU_D7
	};
	uint32_t prev = okusan_last_ppu_data;
	uint32_t bh = (vadr ^ ((uint32_t)val << 2)) & 255u;
	uint32_t out = 0u;
	for (int b = 0; b < 8; ++b) {
		uint32_t vb = ((uint32_t)val >> b) & 1u;
		uint32_t pb = (prev >> b) & 1u;
		uint32_t xl, xr;
		if (b < 4) {
			/* Pin layout Front 25..30: PA0, PD0, PD1, PD2, PD3, +5V -> PD0's left neighbor PA0 toggles with Y; hold steady pull-up bit cleanly */
			xl = (b > 0) ? (((uint32_t)val >> (b - 1)) & 1u) : vb;
			xr = (b < 3) ? (((uint32_t)val >> (b + 1)) & 1u) : 1u;
		} else {
			/* Pin layout Back 56..60: PA13, PD7, PD6, PD5, PD4 */
			xl = (b < 7) ? (((uint32_t)val >> (b + 1)) & 1u) : vb;
			xr = (b > 4) ? (((uint32_t)val >> (b - 1)) & 1u) : 1u;
		}
		/* An open individual PPU data pin floats to CMOS/NMOS pull-up (1) rather than lower scanline address Y,
		 * producing authentic crisp 8px-periodic vertical stripes/jailbars when a data line drops. */
		uint32_t rb = okusan_pin_xfer_bit(ppu_data_pin[b], vb, pb, xl, xr, 1u, bh + (uint32_t)b * 17u, 1);
		out |= (rb << b);
	}
	okusan_last_ppu_data = val;
	return (uint8_t)out;
}

static INLINE uint8_t okusan_map_chr_data(uint8_t val, int plane, uint32_t vadr) {
	(void)plane;
	uint32_t do_tr = ((okusan_ppu_trace_div & 31u) == 0u);
	if (!okusan_cart_is_active()) {
		if (do_tr) okusan_trace_ppu_data_pins(val, val);
		return val;
	}

	/* True 2C02 multiplexed AD0..AD7 bus: lower address byte remains on bus capacitance if CHR ignores OE */
	uint8_t open_bus = (uint8_t)(vadr & 0xFFu);
	if (okusan_cached_pwr_dead ||
	    okusan_ctrl_pin_dropped(PIN_PPU_RD, 73u, 110u) ||
	    okusan_ctrl_pin_dropped(PIN_PPU_A13, 79u, 90u)) {
		if (do_tr) okusan_trace_ppu_data_pins(val, open_bus);
		return open_bus;
	}

	uint8_t eff = okusan_map_ppu_data_bus(val, open_bus, vadr);
	if (do_tr) okusan_trace_ppu_data_pins(val, eff);
	return eff;
}

/* Real HVC-001 transient CIRAM (/WE, /CE, A10, AD0..AD7) write-latching when snapping back to seated via '?' ('/').
 * While adjusting angles (< > [ ]), CIRAM is untouched; only snapping from a faulted powered state via '?'
 * latches bus-derived corruption into internal 2KB CIRAM (vnapage) so that screen stays broken until overwritten. */
__attribute__((visibility("default")))
void okusan_reseat_cart_contact(void) {
	int was_faulted = okusan_cart_is_active();
	if (was_faulted && !okusan_cached_pwr_dead && !ppudead && (ScreenON || SpriteON)) {
		int ciram_sev = (int)(okusan_cached_pins[PIN_PPU_WR]    & 0x0Fu)
		              + (int)(okusan_cached_pins[PIN_CIRAM_CE]  & 0x0Fu)
		              + (int)(okusan_cached_pins[PIN_PPU_NA13]  & 0x0Fu)
		              + (int)(okusan_cached_pins[PIN_CIRAM_A10] & 0x0Fu);
		int ppu_faults = 0;
		for (int p = PIN_PPU_RD; p <= PIN_VCC_R; ++p) {
			if ((okusan_cached_pins[p] & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_faults++;
		}
		for (int p = PIN_PPU_WR; p <= PIN_PPU_D4; ++p) {
			if ((okusan_cached_pins[p] & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_faults++;
		}
		if ((okusan_cached_pins[PIN_GND1]  & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_faults++;
		if ((okusan_cached_pins[PIN_GND2]  & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_faults++;
		if ((okusan_cached_pins[PIN_VCC_L] & 0x0Fu) != OKUSAN_PIN_SEATED) ppu_faults++;

		if (ciram_sev > 0 || ppu_faults >= 4) {
			int burst = 8 + ciram_sev * 2 + (ppu_faults / 2);
			if (burst > 28) burst = 28;
			uint32_t rng = (okusan_frame_tick * 747796405u)
			             ^ ((uint32_t)(okusan_tilt + 64) * 2891336453u)
			             ^ ((uint32_t)(okusan_lift + 16) * 277803737u)
			             ^ ((uint32_t)(okusan_pitch + 16) * 1597334677u);
			for (int b = 0; b < burst; ++b) {
				rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
				int nt = (int)(rng & 3u);
				if (!(PPUNTARAM & (1 << nt)) || !vnapage[nt]) continue;
				uint32_t base_off = (rng >> 8) & 0x3FFu;
				uint32_t mode = (rng >> 20) & 3u;
				uint32_t run = (base_off < 0x3C0u) ? (1u + ((rng >> 24) & 3u)) : 1u;
				for (uint32_t k = 0; k < run; ++k) {
					uint32_t off = (base_off + k) & 0x3FFu;
					uint8_t cur = vnapage[nt][off];
					uint8_t val = cur;
					if (mode < 2u) {
						val = okusan_map_ppu_data_bus(cur, (uint8_t)(off & 0xFFu), 0x2000u | off);
						if (val == cur) val = (uint8_t)(cur ^ ((rng >> 16) & 0xFFu));
					} else if (mode == 2u) {
						uint32_t alias = 0x20u << ((rng >> 22) & 2u);
						val = vnapage[nt][off ^ alias];
					} else {
						val = (uint8_t)((off & 0xFFu) ^ (okusan_last_ppu_data & 0x0Fu));
					}
					vnapage[nt][off] = val;
				}
			}
		}
	}
	okusan_pin_weak_mask = 0ULL;
	okusan_pin_open_mask = 0ULL;
	okusan_set_cart_contact3(0, 0, 0);
}

/* Sprite 0 on the current line, until its hit is found (0x100: none). */
static int32_t sphitx;
static uint8_t sphitdata;

/* A status or open-bus read changes nothing rendering depends on, so the
 * line is brought up to date only when the read can see the sprite-0 hit
 * land, or when a mapper or input hook watches the rendering as it goes.
 * Otherwise the next register access or the end of the line renders it. */
#define PPU_READ_NEEDS_LINE \
	(sphitx != 0x100 || PPU_hook || MMC5Hack || InputScanlineHook)

static DECLFR(A2002) {
	uint8_t ret;

	if (PPU_READ_NEEDS_LINE)
		FCEUPPU_LineUpdate();
	ret = PPU_status;
	ret |= PPUGenLatch & 0x1F;

	{
		vtoggle = 0;
		PPU_status &= 0x7F;
		PPUGenLatch = ret;
	}

	return ret;
}

static DECLFR(A200x) {	/* Not correct for $2004 reads. */
	if (PPU_READ_NEEDS_LINE)
		FCEUPPU_LineUpdate();
	return PPUGenLatch;
}

static INLINE uint8_t okusan_read_ppu_cpu_bus(uint32_t addr) {
	if (addr < 0x2000u) {
		if (!okusan_cart_is_active()) return VPage[addr >> 10][addr];
		int plane = (addr >> 3) & 1;
		uint32_t ma = okusan_map_chr_addr(addr, plane);
		uint32_t mapped = (addr & ~0x1FFFu) | (ma & 0x1FFFu);
		return okusan_map_chr_data(VPage[mapped >> 10][mapped], plane, mapped);
	}
	int ntIdx = okusan_map_nt((addr >> 10) & 0x3);
	return okusan_read_nt_byte(vnapage[ntIdx], addr & 0x3FFu);
}

static DECLFR(A2007) {
	uint8_t ret;
	uint32_t tmp = RefreshAddr & 0x3FFF;

	FCEUPPU_LineUpdate();

	if (tmp >= 0x3F00) {	/* Palette RAM tied directly to the output data, without VRAM buffer */
		if (!(tmp & 3)) {
			if (!(tmp & 0xC))
				ret = PALRAM[0x00];
			else
				ret = UPALRAM[((tmp & 0xC) >> 2) - 1];
		} else
			ret = PALRAM[tmp & 0x1F];
		if (GRAYSCALE)
			ret &= 0x30;
		{
			VRAMBuffer = okusan_read_ppu_cpu_bus((tmp - 0x1000u) & 0x3FFFu);
			if (PPU_hook) PPU_hook(tmp);
		}
	} else {
		ret = VRAMBuffer;
		{
			if (PPU_hook) PPU_hook(tmp);
			PPUGenLatch = VRAMBuffer;
			VRAMBuffer = okusan_read_ppu_cpu_bus(tmp);
		}
	}

	{
		if ((ScreenON || SpriteON) && (scanline < 240)) {
			uint32_t rad = RefreshAddr;
			if ((rad & 0x7000) == 0x7000) {
				rad ^= 0x7000;
				if ((rad & 0x3E0) == 0x3A0)
					rad ^= 0xBA0;
				else if ((rad & 0x3E0) == 0x3e0)
					rad ^= 0x3e0;
				else
					rad += 0x20;
			} else
				rad += 0x1000;
			RefreshAddr = rad;
		} else {
			if (INC32)
				RefreshAddr += 32;
			else
				RefreshAddr++;
		}
		if (PPU_hook) PPU_hook(RefreshAddr & 0x3fff);
	}
	return ret;
}

static DECLFW(B2000) {
	FCEUPPU_LineUpdate();
	PPUGenLatch = V;

	if (!(PPU[0] & 0x80) && (V & 0x80) && (PPU_status & 0x80))
		TriggerNMI2();

	PPU[0] = V;
	TempAddr &= 0xF3FF;
	TempAddr |= (V & 3) << 10;
}

static DECLFW(B2001) {
	FCEUPPU_LineUpdate();
	PPUGenLatch = V;
	PPU[1] = V;
	if (V & 0xE0)
		deemp = V >> 5;
}

static DECLFW(B2002) {
	PPUGenLatch = V;
}

static DECLFW(B2003) {
	PPUGenLatch = V;
	PPU[3] = V;
	PPUSPL = V & 0x7;
}

/* For scanlines 0-255, the sprites whose rows cover each line, as bits
 * by OAM index (lo: 0-31, hi: 32-63), rebuilt when OAM or the sprite
 * height has changed since. */
static uint32_t spr_line_lo[256], spr_line_hi[256];
static uint8_t spr_lines_h;
static uint8_t spr_lines_dirty = 1;

static DECLFW(B2004) {
	PPUGenLatch = V;
	spr_lines_dirty = 1;
	if (PPUSPL >= 8) {
		if (PPU[3] >= 8)
			SPRAM[PPU[3]] = V;
	} else {
		SPRAM[PPUSPL] = V;
	}
	PPU[3]++;
	PPUSPL++;
}

static DECLFW(B2005) {
	uint32_t tmp = TempAddr;
	FCEUPPU_LineUpdate();
	PPUGenLatch = V;
	if (!vtoggle) {
		tmp &= 0xFFE0;
		tmp |= V >> 3;
		XOffset = V & 7;
	} else {
		tmp &= 0x8C1F;
		tmp |= ((V & ~0x7) << 2);
		tmp |= (V & 7) << 12;
	}
	TempAddr = tmp;
	vtoggle ^= 1;
}


static DECLFW(B2006) {
	FCEUPPU_LineUpdate();

	PPUGenLatch = V;
	if (!vtoggle) {
		TempAddr &= 0x00FF;
		TempAddr |= (V & 0x3f) << 8;
	} else {
		TempAddr &= 0xFF00;
		TempAddr |= V;

		RefreshAddr = TempAddr;
		if (PPU_hook)
			PPU_hook(RefreshAddr);
	}
	vtoggle ^= 1;
}

static DECLFW(B2007) {
	uint32_t tmp = RefreshAddr & 0x3FFF;
	PPUGenLatch = V;
	if (tmp < 0x2000) {
		if (PPUCHRRAM & (1 << (tmp >> 10))) {
			uint8_t wr_ok = 1;
			uint8_t wr_val = V;
			uint32_t wr_addr = tmp;
			if (okusan_cart_is_active()) {
				if (okusan_cached_pwr_dead ||
				    okusan_ctrl_pin_dropped(PIN_PPU_WR,  163u, 110u) ||
				    okusan_ctrl_pin_dropped(PIN_PPU_A13, 167u, 90u)) {
					wr_ok = 0;
				} else {
					wr_addr = okusan_map_chr_addr(tmp, (tmp >> 3) & 1);
					wr_val  = okusan_map_ppu_data_bus(V, V, wr_addr);
				}
				okusan_trace_pin_bit(PIN_PPU_WR, 0u, wr_ok ? 0u : 1u, (uint16_t)tmp, (uint16_t)wr_addr);
				okusan_trace_ppu_data_pins(V, wr_ok ? wr_val : (uint8_t)(tmp & 0xFFu));
			} else {
				okusan_trace_pin_bit(PIN_PPU_WR, 0u, 0u, (uint16_t)tmp, (uint16_t)tmp);
			}
			if (wr_ok && (PPUCHRRAM & (1 << (wr_addr >> 10))))
				VPage[wr_addr >> 10][wr_addr] = wr_val;
		}
	} else if (tmp < 0x3F00) {
		int ntIdx = (tmp & 0xF00) >> 10;
		uint32_t off = tmp & 0x3FF;
		uint8_t wr_ok = 1;
		if (okusan_cart_is_active()) {
			uint8_t wr_st   = okusan_cached_pins[PIN_PPU_WR]   & 0x0Fu;
			uint8_t ce_st   = okusan_cached_pins[PIN_CIRAM_CE] & 0x0Fu;
			uint8_t na13_st = okusan_cached_pins[PIN_PPU_NA13] & 0x0Fu;
			if (okusan_cached_pwr_dead || wr_st == OKUSAN_PIN_OPEN ||
			    ce_st == OKUSAN_PIN_OPEN || na13_st == OKUSAN_PIN_OPEN) {
				wr_ok = 0;
			} else {
				ntIdx = okusan_map_nt(ntIdx);
			}
			okusan_trace_pin_bit(PIN_PPU_WR, 0u, wr_ok ? 0u : 1u, (uint16_t)tmp, (uint16_t)((ntIdx << 10) | off));
			okusan_trace_pin_bit(PIN_CIRAM_CE, 0u, (ce_st == OKUSAN_PIN_OPEN || na13_st == OKUSAN_PIN_OPEN) ? 1u : 0u,
			                     (uint16_t)tmp, (uint16_t)off);
		} else {
			okusan_trace_pin_bit(PIN_PPU_WR, 0u, 0u, (uint16_t)tmp, (uint16_t)tmp);
		}
		if (wr_ok && (PPUNTARAM & (1 << ntIdx)))
			vnapage[ntIdx][off] = V;
	} else {
		if (!(tmp & 3)) {
			if (!(tmp & 0xC))
				PALRAM[0x00] = PALRAM[0x04] = PALRAM[0x08] = PALRAM[0x0C] = V & 0x3F;
			else
				UPALRAM[((tmp & 0xC) >> 2) - 1] = V & 0x3F;
		} else
			PALRAM[tmp & 0x1F] = V & 0x3F;
	}
	if (INC32)
		RefreshAddr += 32;
	else
		RefreshAddr++;
	if (PPU_hook)
		PPU_hook(RefreshAddr & 0x3fff);
}

static DECLFW(B4014) {
	uint32_t t = V << 8;
	int x;

	for (x = 0; x < 256; x++)
		X6502_DMW(0x2004, X6502_DMR(t + x));
}

#define PAL(c)  ((c) + cc)

#define GETLASTPIXEL    (PAL ? ((timestamp * 48 - linestartts) / 15) : ((timestamp * 48 - linestartts) >> 4))

static uint8_t *Pline, *Plinef;
static int firsttile;
static int linestartts;
static int tofix = 0;

static void ResetRL(uint8_t *target) {
	memset(target, 0xFF, 256);
	if (InputScanlineHook)
		InputScanlineHook(0, 0, 0, 0);
	Plinef = target;
	Pline = target;
	firsttile = 0;
	linestartts = x6502_count_base;
	tofix = 0;
	FCEUPPU_LineUpdate();
	tofix = 1;
}

static uint8_t sprlinebuf[256 + 8];
/* Columns [spr_xmin, spr_xmax) of sprlinebuf that sprites drew into. */
static int spr_xmin, spr_xmax;

void FCEUPPU_LineUpdate(void) {
	if (Pline) {
		int l = GETLASTPIXEL;
		RefreshLine(l);
	}
}

static int rendis = 0;

void FCEUI_SetRenderDisable(int sprites, int bg) {
	if (sprites >= 0) {
		if (sprites == 2) rendis ^= 1;
		else rendis = (rendis & ~1) | sprites ? 1 : 0;
	}
	if (bg >= 0) {
		if (bg == 2) rendis ^= 2;
		else rendis = (rendis & ~2) | bg ? 2 : 0;
	}
}

static void CheckSpriteHit(int p);

static void EndRL(void) {
	RefreshLine(272);
	if (tofix)
		Fixit1();
	CheckSpriteHit(272);
	Pline = 0;
}

static void CheckSpriteHit(int p) {
	int l = p - 16;
	int x;

	if (sphitx == 0x100) return;

	for (x = sphitx; x < (sphitx + 8) && x < l; x++) {
		if ((sphitdata & (0x80 >> (x - sphitx))) && !(Plinef[x] & 64) && x < 255) {
			PPU_status |= 0x40;
			sphitx = 0x100;
			break;
		}
	}
}

/* spork the world.  Any sprites on this line? Then this will be set to 1.
 * Needed for zapper emulation and *gasp* sprite emulation.
 */
static int spork = 0;

/* lasttile is really "second to last tile." */
static void FASTAPASS(1) RefreshLine(int lastpixel) {
	static uint32_t pshift[2];
	static uint32_t atlatch;
	uint32_t smorkus = RefreshAddr;

	#define RefreshAddr smorkus
	uint32_t vofs;
	int X1;

	register uint8_t *P = Pline;
	int lasttile = lastpixel >> 3;
	int numtiles;
	static int norecurse = 0;	/* Yeah, recursion would be bad.
								 * PPU_hook() functions can call
								 * mirroring/chr bank switching functions,
								 * which call FCEUPPU_LineUpdate, which call this
								 * function.
								 */
	if (norecurse) return;

	if (sphitx != 0x100 && !(PPU_status & 0x40)) {
		if ((sphitx < (lastpixel - 16)) && !(sphitx < ((lasttile - 2) * 8)))
			lasttile++;
	}

	if (lasttile > 34) lasttile = 34;
	numtiles = lasttile - firsttile;

	if (numtiles <= 0) return;

	P = Pline;

	vofs = 0;

	if(PEC586Hack)
		vofs = ((RefreshAddr & 0x200) << 3) | ((RefreshAddr >> 12) & 7);
	else
		vofs = ((PPU[0] & 0x10) << 8) | ((RefreshAddr >> 12) & 7);

	if (!ScreenON && !SpriteON) {
		uint32_t tem;
		tem = Pal[0] | (Pal[0] << 8) | (Pal[0] << 16) | (Pal[0] << 24);
		tem |= 0x40404040;
		FCEU_dwmemset(Pline, tem, numtiles * 8);
		P += numtiles * 8;
		Pline = P;

		firsttile = lasttile;

		#define TOFIXNUM (272 - 0x4)
		if (lastpixel >= TOFIXNUM && tofix) {
			Fixit1();
			tofix = 0;
		}

		if (InputScanlineHook && (lastpixel - 16) >= 0) {
			InputScanlineHook(Plinef, spork ? sprlinebuf : 0, linestartts, lasttile * 8 - 16);
		}
		return;
	}

	/* Priority bits, needed for sprite emulation. */
	Pal[0] |= 64;
	Pal[4] |= 64;
	Pal[8] |= 64;
	Pal[0xC] |= 64;

	/* This high-level graphics MMC5 emulation code was written for MMC5 carts in "CL" mode.
	 * It's probably not totally correct for carts in "SL" mode.
	 */

#define PPUT_MMC5
	if (MMC5Hack && geniestage != 1) {
		if (MMC5HackCHRMode == 0 && (MMC5HackSPMode & 0x80)) {
			int tochange = MMC5HackSPMode & 0x1F;
			tochange -= firsttile;
			for (X1 = firsttile; X1 < lasttile; X1++) {
				if ((tochange <= 0 && MMC5HackSPMode & 0x40) || (tochange > 0 && !(MMC5HackSPMode & 0x40))) {
					#define PPUT_MMC5SP
					#include "pputile.h"
					#undef PPUT_MMC5SP
				} else {
					#include "pputile.h"
				}
				tochange--;
			}
		} else if (MMC5HackCHRMode == 1 && (MMC5HackSPMode & 0x80)) {
			int tochange = MMC5HackSPMode & 0x1F;
			tochange -= firsttile;

			#define PPUT_MMC5SP
			#define PPUT_MMC5CHR1
			for (X1 = firsttile; X1 < lasttile; X1++) {
				#include "pputile.h"
			}
			#undef PPUT_MMC5CHR1
			#undef PPUT_MMC5SP
		} else if (MMC5HackCHRMode == 1) {
			#define PPUT_MMC5CHR1
			for (X1 = firsttile; X1 < lasttile; X1++) {
				#include "pputile.h"
			}
			#undef PPUT_MMC5CHR1
		} else {
			for (X1 = firsttile; X1 < lasttile; X1++) {
				#include "pputile.h"
			}
		}
	}
	#undef PPUT_MMC5
	else if (PPU_hook) {
		norecurse = 1;
		#define PPUT_HOOK
		if (PEC586Hack) {
			#define PPU_BGFETCH
			for (X1 = firsttile; X1 < lasttile; X1++) {
				#include "pputile.h"
			}
			#undef PPU_BGFETCH
		} else {
			for (X1 = firsttile; X1 < lasttile; X1++) {
				#include "pputile.h"
			}
		}
		#undef PPUT_HOOK
		norecurse = 0;
	} else {
		if (PEC586Hack) {
			#define PPU_BGFETCH
			for (X1 = firsttile; X1 < lasttile; X1++) {
				#include "pputile.h"
			}
			#undef PPU_BGFETCH
		} else {
			for (X1 = firsttile; X1 < lasttile; X1++) {
				#include "pputile.h"
			}
		}
	}

#undef vofs
#undef RefreshAddr

	/* Reverse changes made before. */
	Pal[0] &= 63;
	Pal[4] &= 63;
	Pal[8] &= 63;
	Pal[0xC] &= 63;

	RefreshAddr = smorkus;
	if (firsttile <= 2 && 2 < lasttile && !(PPU[1] & 2)) {
		uint32_t tem;
		tem = Pal[0] | (Pal[0] << 8) | (Pal[0] << 16) | (Pal[0] << 24);
		tem |= 0x40404040;
		*(uint32_t*)Plinef = *(uint32_t*)(Plinef + 4) = tem;
	}

	if (!ScreenON) {
		uint32_t tem;
		int tstart, tcount;
		tem = Pal[0] | (Pal[0] << 8) | (Pal[0] << 16) | (Pal[0] << 24);
		tem |= 0x40404040;

		tcount = lasttile - firsttile;
		tstart = firsttile - 2;
		if (tstart < 0) {
			tcount += tstart;
			tstart = 0;
		}
		if (tcount > 0)
			FCEU_dwmemset(Plinef + tstart * 8, tem, tcount * 8);
	}

	if (lastpixel >= TOFIXNUM && tofix) {
		Fixit1();
		tofix = 0;
	}

	/* This only works right because of a hack earlier in this function. */
	CheckSpriteHit(lastpixel);

	if (InputScanlineHook && (lastpixel - 16) >= 0) {
		InputScanlineHook(Plinef, spork ? sprlinebuf : 0, linestartts, lasttile * 8 - 16);
	}
	Pline = P;
	firsttile = lasttile;
}

static INLINE void Fixit2(void) {
	if (ScreenON || SpriteON) {
		uint32_t rad = RefreshAddr;
		rad &= 0xFBE0;
		rad |= TempAddr & 0x041f;
		RefreshAddr = rad;
	}
}

static void Fixit1(void) {
	if (ScreenON || SpriteON) {
		uint32_t rad = RefreshAddr;

		if ((rad & 0x7000) == 0x7000) {
			rad ^= 0x7000;
			if ((rad & 0x3E0) == 0x3A0)
				rad ^= 0xBA0;
			else if ((rad & 0x3E0) == 0x3e0)
				rad ^= 0x3e0;
			else
				rad += 0x20;
		} else
			rad += 0x1000;
		RefreshAddr = rad;
	}
}

void MMC5_hb(int);		/* Ugh ugh ugh. */
static void DoLine(void)
{
	int x;
	uint8_t *target = NULL;
	uint8_t *dtarget = NULL;

	if (scanline >= 240 && (unsigned)scanline != totalscanlines)
	{
		X6502_Run(256 + 69);
		scanline++;
		X6502_Run(16);
		return;
	}

	target = XBuf + ((scanline < 240 ? scanline : 240) << 8);
	dtarget = XDBuf + ((scanline < 240 ? scanline : 240) << 8);

#ifdef HAVE_HDPACK
	/* HD packs: snapshot the loopy-t / fine-x scroll registers at line
	 * start and invalidate the per-line tile fetch slots. */
	if (hdnes_active && scanline < 240)
		HDNes_LineStart(scanline);
#endif

	if (MMC5Hack && (ScreenON || SpriteON)) MMC5_hb(scanline);

	X6502_Run(256);
	EndRL();

	if (rendis & 2) {/* User asked to not display background data. */
		uint32_t tem;
		tem = Pal[0] | (Pal[0] << 8) | (Pal[0] << 16) | (Pal[0] << 24);
		tem |= 0x40404040;
		FCEU_dwmemset(target, tem, 256);
	}

#ifdef HAVE_HDPACK
	/* HD packs: the line's XBuf still holds pure background pixels
	 * here (bit 6 = colour-0 transparency), which is exactly what the
	 * per-pixel HD screen info needs; sprites are merged from the
	 * records made by FetchSpriteData on the previous line. */
	if (hdnes_active && scanline < 240)
		HDNes_RecordLine(scanline, target, rendis);
#endif

	if (SpriteON)
		CopySprites(target);

	/* One pass over the line: greyscale (while rendering), then the
	 * palette bank bits the line's emphasis selects. */
	{
		uint32_t and_mask = 0xFFFFFFFFu;
		uint32_t or_mask;

		if ((ScreenON || SpriteON) && (PPU[1] & 0x01))
			and_mask = 0x30303030u;
		if ((PPU[1] >> 5) == 0x7) {
			and_mask &= 0x3f3f3f3fu;
			or_mask   = 0xc0c0c0c0u;
		} else if (PPU[1] & 0xE0)
			or_mask   = 0x40404040u;
		else {
			and_mask &= 0x3f3f3f3fu;
			or_mask   = 0x80808080u;
		}
		for (x = 0; x < 256; x += 4) {
			uint32_t w;
			memcpy(&w, target + x, 4);
			w = (w & and_mask) | or_mask;
			memcpy(target + x, &w, 4);
		}
	}

	/* The line's colour emphasis, one byte per pixel. */
	memset(dtarget, PPU[1] >> 5, 256);

    sphitx = 0x100;

	if (ScreenON || SpriteON)
		FetchSpriteData();

	if (GameHBIRQHook && (ScreenON || SpriteON) && ((PPU[0] & 0x38) != 0x18)) {
		X6502_Run(6);
		Fixit2();
		X6502_Run(4);
		GameHBIRQHook();
		X6502_Run(85 - 16 - 10);
	} else {
		X6502_Run(6);	/* Tried 65, caused problems with Slalom(maybe others) */
		Fixit2();
		X6502_Run(85 - 6 - 16);

		/* A semi-hack for Star Trek: 25th Anniversary */
		if (GameHBIRQHook && (ScreenON || SpriteON) && ((PPU[0] & 0x38) != 0x18))
			GameHBIRQHook();
	}

	if (SpriteON)
		RefreshSprites();
	if (GameHBIRQHook2 && (ScreenON || SpriteON))
		GameHBIRQHook2();
	scanline++;
	if (scanline < 240) {
		ResetRL(XBuf + (scanline << 8));
	}
	X6502_Run(16);
}

#define V_FLIP  0x80
#define H_FLIP  0x40
#define SP_BACK 0x20

typedef struct {
	uint8_t y, no, atr, x;
} SPR;

typedef struct {
	uint8_t ca[2], atr, x;
} SPRB;

void FCEUI_DisableSpriteLimitation(int a) {
	maxsprites = a ? 64 : 8;
}

static uint8_t numsprites, SpriteBlurp;
static void BuildSpriteLines(uint8_t H) {
	int i, t;

	memset(spr_line_lo, 0, sizeof(spr_line_lo));
	memset(spr_line_hi, 0, sizeof(spr_line_hi));
	for (i = 0; i < 64; i++) {
		int y = SPRAM[i << 2];
		uint32_t bit = (uint32_t)1 << (i & 31);
		uint32_t *line = (i < 32) ? spr_line_lo : spr_line_hi;
		for (t = 0; t < H && y + t < 256; t++)
			line[y + t] |= bit;
	}
	spr_lines_h = H;
	spr_lines_dirty = 0;
}

/* Index of the lowest set bit of a nonzero word. */
static const uint8_t spr_debruijn[32] = {
	0, 1, 28, 2, 29, 14, 24, 3, 30, 22, 20, 15, 25, 17, 4, 8,
	31, 27, 13, 23, 21, 19, 16, 7, 26, 12, 18, 6, 11, 5, 10, 9
};
#define SPR_LOWEST_BIT(m) \
	spr_debruijn[(((m) & (0u - (m))) * 0x077CB531u) >> 27]

/* Next OAM index from the candidate masks, lowest first; -1 when none
 * are left. */
static INLINE int NextSprite(uint32_t *lo, uint32_t *hi) {
	int i;
	if (*lo) {
		i = SPR_LOWEST_BIT(*lo);
		*lo &= *lo - 1;
		return i;
	}
	if (*hi) {
		i = 32 + SPR_LOWEST_BIT(*hi);
		*hi &= *hi - 1;
		return i;
	}
	return -1;
}

static void FetchSpriteData(void) {
	uint8_t ns, sb;
	SPR *spr;
	uint8_t H;
	int n;
	int vofs;
	uint8_t P0 = PPU[0];
	uint32_t cand_lo, cand_hi;
	int i;

	H = 8;

	ns = sb = 0;

	vofs = (uint32_t)(P0 & 0x8 & (((P0 & 0x20) ^ 0x20) >> 2)) << 9;
	H += (P0 & 0x20) >> 2;

	/* Past line 255 (the pre-render line) every sprite is a candidate
	 * and the range test below decides. */
	if ((uint32_t)scanline < 256) {
		if (spr_lines_dirty || spr_lines_h != H)
			BuildSpriteLines(H);
		cand_lo = spr_line_lo[scanline];
		cand_hi = spr_line_hi[scanline];
	} else
		cand_lo = cand_hi = 0xFFFFFFFFu;

#ifdef HAVE_HDPACK
	if (hdnes_active)
		HDNes_SpriteFetchStart();
#endif

	if (!PPU_hook)
		while ((i = NextSprite(&cand_lo, &cand_hi)) >= 0) {
			spr = (SPR*)SPRAM + i;
			n = 63 - i;
			if ((uint32_t)(scanline - spr->y) >= H) continue;
			if (ns < maxsprites) {
				if (n == 63) sb = 1;

				{
					SPRB dst;
					uint8_t *C;
					int t;
					uint32_t vadr;

					t = (int)scanline - (spr->y);

					if (Sprite16)
						vadr = ((spr->no & 1) << 12) + ((spr->no & 0xFE) << 4);
					else
						vadr = (spr->no << 4) + vofs;

					if (spr->atr & V_FLIP) {
						vadr += 7;
						vadr -= t;
						vadr += (P0 & 0x20) >> 1;
						vadr -= t & 8;
					} else {
						vadr += t;
						vadr += t & 8;
					}

					/* Fix this geniestage hack */
					if (MMC5Hack && geniestage != 1) {
						C = MMC5SPRVRAMADR(vadr);
						dst.ca[0] = C[0];
						dst.ca[1] = C[8];
					} else {
						uint32_t sa0 = okusan_map_chr_addr(vadr, 0);
						uint32_t sa1 = okusan_map_chr_addr(vadr | 8u, 1);
						uint8_t *C1 = VRAMADR(sa1);
						C = VRAMADR(sa0);
						dst.ca[0] = okusan_map_chr_data(C[0], 0, sa0);
						dst.ca[1] = okusan_map_chr_data(C1[0], 1, sa1);
					}
					dst.x = spr->x;
					dst.atr = spr->atr;

					/* memcpy avoids the strict-aliasing UB of casting
					 * a uint8_t buffer and a struct SPRB through a
					 * uint32_t* and also dodges the alignment trap on
					 * strict-alignment hosts. The compiler emits the
					 * same single 32-bit move on x86/ARM. */
					memcpy(&SPRBUF[ns << 2], &dst, 4);

#ifdef HAVE_HDPACK
					/* HD packs: record the sprite for next
					 * line's per-pixel assembly.  vadr has
					 * v-flip and the 8x16 half applied, so
					 * (vadr & 7) is the source row and
					 * C - (vadr & 7) the 16-byte tile base. */
					if (hdnes_active)
						HDNes_RecordSprite(ns, spr->x, spr->atr,
							C - (vadr & 7), (uint8_t)(vadr & 7),
							dst.ca[0], dst.ca[1]);
#endif
				}

				ns++;
			} else {
				PPU_status |= 0x20;
				break;
			}
		}
	else
		while ((i = NextSprite(&cand_lo, &cand_hi)) >= 0) {
			spr = (SPR*)SPRAM + i;
			n = 63 - i;
			if ((uint32_t)(scanline - spr->y) >= H) continue;

			if (ns < maxsprites) {
				if (n == 63) sb = 1;

				{
					SPRB dst;
					uint8_t *C;
					int t;
					uint32_t vadr;

					t = (int)scanline - (spr->y);

					if (Sprite16)
						vadr = ((spr->no & 1) << 12) + ((spr->no & 0xFE) << 4);
					else
						vadr = (spr->no << 4) + vofs;

					if (spr->atr & V_FLIP) {
						vadr += 7;
						vadr -= t;
						vadr += (P0 & 0x20) >> 1;
						vadr -= t & 8;
					} else {
						vadr += t;
						vadr += t & 8;
					}

					if (MMC5Hack) {
						C = MMC5SPRVRAMADR(vadr);
						dst.ca[0] = C[0];
						if (ns < 8) {
							PPU_hook(0x2000);
							PPU_hook(vadr);
						}
						dst.ca[1] = C[8];
					} else {
						uint32_t sa0 = okusan_map_chr_addr(vadr, 0);
						uint32_t sa1 = okusan_map_chr_addr(vadr | 8u, 1);
						uint8_t *C1 = VRAMADR(sa1);
						C = VRAMADR(sa0);
						dst.ca[0] = okusan_map_chr_data(C[0], 0, sa0);
						if (ns < 8) {
							PPU_hook(0x2000);
							PPU_hook(vadr);
						}
						dst.ca[1] = okusan_map_chr_data(C1[0], 1, sa1);
					}
					dst.x = spr->x;
					dst.atr = spr->atr;


					memcpy(&SPRBUF[ns << 2], &dst, 4);

#ifdef HAVE_HDPACK
					/* HD packs: record the sprite for next
					 * line's per-pixel assembly.  vadr has
					 * v-flip and the 8x16 half applied, so
					 * (vadr & 7) is the source row and
					 * C - (vadr & 7) the 16-byte tile base. */
					if (hdnes_active)
						HDNes_RecordSprite(ns, spr->x, spr->atr,
							C - (vadr & 7), (uint8_t)(vadr & 7),
							dst.ca[0], dst.ca[1]);
#endif
				}

				ns++;
			} else {
				PPU_status |= 0x20;
				break;
			}
		}

	/* Handle case when >8 sprites per scanline option is enabled. */
	if (ns > 8) PPU_status |= 0x20;
	else if (PPU_hook) {
		for (n = 0; n < (8 - ns); n++) {
			PPU_hook(0x2000);
			PPU_hook(vofs);
		}
	}
	numsprites = ns;
	SpriteBlurp = sb;
}

static void RefreshSprites(void) {
	int n;
	SPRB *spr;

	spork = 0;
	if (!numsprites) return;

	FCEU_dwmemset(sprlinebuf, 0x80808080, 256);
	numsprites--;
	spr = (SPRB*)SPRBUF + numsprites;
	spr_xmin = 256;
	spr_xmax = 0;

	for (n = numsprites; n >= 0; n--, spr--) {
		register uint32_t pixdata;
		register uint8_t J, atr;

		int x = spr->x;
		uint8_t *C;
		uint8_t *VB;

		pixdata = ppulut1[spr->ca[0]] | ppulut2[spr->ca[1]];
		J = spr->ca[0] | spr->ca[1];
		atr = spr->atr;

		if (J) {
			if (x < spr_xmin)
				spr_xmin = x;
			if (x + 8 > spr_xmax)
				spr_xmax = x + 8;
			if (n == 0 && SpriteBlurp && !(PPU_status & 0x40)) {
				sphitx = x;
				sphitdata = J;
				if (atr & H_FLIP)
					sphitdata = ((J << 7) & 0x80) |
								((J << 5) & 0x40) |
								((J << 3) & 0x20) |
								((J << 1) & 0x10) |
								((J >> 1) & 0x08) |
								((J >> 3) & 0x04) |
								((J >> 5) & 0x02) |
								((J >> 7) & 0x01);
			}

			C = sprlinebuf + x;
			VB = (PALRAM + 0x10) + ((atr & 3) << 2);

			if (atr & SP_BACK) {
				if (atr & H_FLIP) {
					if (J & 0x80) C[7] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x40) C[6] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x20) C[5] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x10) C[4] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x08) C[3] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x04) C[2] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x02) C[1] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x01) C[0] = VB[pixdata] | 0x40;
				} else {
					if (J & 0x80) C[0] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x40) C[1] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x20) C[2] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x10) C[3] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x08) C[4] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x04) C[5] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x02) C[6] = VB[pixdata & 3] | 0x40;
					pixdata >>= 4;
					if (J & 0x01) C[7] = VB[pixdata] | 0x40;
				}
			} else {
				if (atr & H_FLIP) {
					if (J & 0x80) C[7] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x40) C[6] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x20) C[5] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x10) C[4] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x08) C[3] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x04) C[2] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x02) C[1] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x01) C[0] = VB[pixdata];
				} else {
					if (J & 0x80) C[0] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x40) C[1] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x20) C[2] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x10) C[3] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x08) C[4] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x04) C[5] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x02) C[6] = VB[pixdata & 3];
					pixdata >>= 4;
					if (J & 0x01) C[7] = VB[pixdata];
				}
			}
		}
	}
	SpriteBlurp = 0;
	spork = 1;
}

static void CopySprites(uint8_t *target) {
	int n = ((PPU[1] & 4) ^ 4) << 1;
	int end;
	uint8_t *P = target;

	if (!spork) return;
	spork = 0;

	if (rendis & 1) return;	/* User asked to not display sprites. */

	/* Only the 4-byte groups sprites drew into. */
	if (n < (spr_xmin & ~3))
		n = spr_xmin & ~3;
	end = (spr_xmax + 3) & ~3;
	if (end > 256)
		end = 256;

	for (; n < end; n += 4)
	{
		uint32_t t;
		memcpy(&t, sprlinebuf + n, 4);

		if (t != 0x80808080) {
			#ifdef MSB_FIRST
			if (!(t & 0x80000000)) {
				if (!(t & 0x40000000) || (P[n] & 64))	/* Normal sprite || behind bg sprite */
					P[n] = sprlinebuf[n];
			}

			if (!(t & 0x800000)) {
				if (!(t & 0x400000) || (P[n + 1] & 64))	/* Normal sprite || behind bg sprite */
					P[n + 1] = (sprlinebuf + 1)[n];
			}

			if (!(t & 0x8000)) {
				if (!(t & 0x4000) || (P[n + 2] & 64))		/* Normal sprite || behind bg sprite */
					P[n + 2] = (sprlinebuf + 2)[n];
			}

			if (!(t & 0x80)) {
				if (!(t & 0x40) || (P[n + 3] & 64))		/* Normal sprite || behind bg sprite */
					P[n + 3] = (sprlinebuf + 3)[n];
			}
			#else

			if (!(t & 0x80)) {
				if (!(t & 0x40) || (P[n] & 0x40))		/* Normal sprite || behind bg sprite */
					P[n] = sprlinebuf[n];
			}

			if (!(t & 0x8000)) {
				if (!(t & 0x4000) || (P[n + 1] & 0x40))		/* Normal sprite || behind bg sprite */
					P[n + 1] = (sprlinebuf + 1)[n];
			}

			if (!(t & 0x800000)) {
				if (!(t & 0x400000) || (P[n + 2] & 0x40))	/* Normal sprite || behind bg sprite */
					P[n + 2] = (sprlinebuf + 2)[n];
			}

			if (!(t & 0x80000000)) {
				if (!(t & 0x40000000) || (P[n + 3] & 0x40))	/* Normal sprite || behind bg sprite */
					P[n + 3] = (sprlinebuf + 3)[n];
			}
			#endif
		}
	}
}

void FCEUPPU_SetVideoSystem(int w) {
	if (w) {
		scanlines_per_frame = dendy ? 262 : 312;
		FSettings.FirstSLine = FSettings.UsrFirstSLine[1];
		FSettings.LastSLine = FSettings.UsrLastSLine[1];
	} else {
		scanlines_per_frame = 262;
		FSettings.FirstSLine = FSettings.UsrFirstSLine[0];
		FSettings.LastSLine = FSettings.UsrLastSLine[0];
	}
}

void FCEUPPU_Init(void) {
	makeppulut();
}

void FCEUPPU_Reset(void) {
	VRAMBuffer = PPU[0] = PPU[1] = PPU_status = PPU[3] = 0;
	PPUSPL = 0;
	PPUGenLatch = 0;
	RefreshAddr = TempAddr = 0;
	vtoggle = 0;
	ppudead = 2;
	kook = 0;
}

void FCEUPPU_Power(void) {
	int x;

	memset(NTARAM, 0x00, 0x800);
	memset(PALRAM, 0x00, 0x20);
	memset(UPALRAM, 0x00, 0x03);
	memset(SPRAM, 0x00, 0x100);
	spr_lines_dirty = 1;
	FCEUPPU_Reset();
	for (x = 0x2000; x < 0x4000; x += 8) {
		ARead[x] = A200x;
		BWrite[x] = B2000;
		ARead[x + 1] = A200x;
		BWrite[x + 1] = B2001;
		ARead[x + 2] = A2002;
		BWrite[x + 2] = B2002;
		ARead[x + 3] = A200x;
		BWrite[x + 3] = B2003;
		ARead[x + 4] = A200x;	/* A2004; */
		BWrite[x + 4] = B2004;
		ARead[x + 5] = A200x;
		BWrite[x + 5] = B2005;
		ARead[x + 6] = A200x;
		BWrite[x + 6] = B2006;
		ARead[x + 7] = A2007;
		BWrite[x + 7] = B2007;
	}

	BWrite[0x4014] = B4014;
}


int FCEUPPU_Loop(int skip) {
	okusan_finalize_frame_telemetry();
	okusan_frame_tick++;
	okusan_refresh_frame_cache();
	/* Needed for Knight Rider, possibly others. */
	if (ppudead) {
		memset(XBuf, 0x80, 256 * 240);
		X6502_Run(scanlines_per_frame * (256 + 85));
		ppudead--;
	} else {
		X6502_Run(256 + 85);
		PPU_status |= 0x80;

		/* Not sure if this is correct.  According to Matt Conte and my own tests, it is.
		 * Timing is probably off, though.
		 * NOTE:  Not having this here breaks a Super Donkey Kong game.
		 */
		PPU[3] = PPUSPL = 0;

		/* I need to figure out the true nature and length of this delay. */
		X6502_Run(12);
		if (GameInfo->type == GIT_NSF)
			DoNSFFrame();
		else {
			if (VBlankON)
				TriggerNMI();
		}
		X6502_Run((scanlines_per_frame - 242) * (256 + 85) - 12);
		if (overclock_enabled && vblankscanlines) {
			if (!DMC_7bit || !skip_7bit_overclocking) {
				overclocked = 1;
				X6502_Run(vblankscanlines * (256 + 85) - 12);
				overclocked = 0;
			}
		}
		PPU_status &= 0x1f;
		X6502_Run(256);

		{
			int x;

			if (ScreenON || SpriteON) {
				if (GameHBIRQHook && ((PPU[0] & 0x38) != 0x18))
					GameHBIRQHook();
				if (PPU_hook)
					for (x = 0; x < 42; x++) {
						PPU_hook(0x2000); PPU_hook(0);
					}
				if (GameHBIRQHook2)
					GameHBIRQHook2();
			}
			X6502_Run(85 - 16);
			if (ScreenON || SpriteON) {
				RefreshAddr = TempAddr;
				if (PPU_hook) PPU_hook(RefreshAddr & 0x3fff);
			}

			/* Clean this stuff up later. */
			spork = numsprites = 0;
			ResetRL(XBuf);

			X6502_Run(16 - kook);
			kook ^= 1;
		}
		if (GameInfo->type == GIT_NSF)
			X6502_Run((256 + 85) * normal_scanlines);
		else {
			int x, max, maxref;

			deemp = PPU[1] >> 5;

         /* manual samples can't play correctly with overclocking */
			if (DMC_7bit && skip_7bit_overclocking)
				totalscanlines = normal_scanlines;
			else
				totalscanlines = normal_scanlines + (overclock_enabled ? extrascanlines : 0);

			for (scanline = 0; (unsigned)scanline < totalscanlines; ) {	/* scanline is incremented in  DoLine.  Evil. :/ */
				deempcnt[deemp]++;
				DoLine();
				if ((unsigned)scanline < normal_scanlines || (unsigned)scanline == totalscanlines)
					overclocked = 0;
				else {
					if (DMC_7bit && skip_7bit_overclocking) /* 7bit sample started after 240th line */
						break;
					overclocked = 1;
				}
			}

			DMC_7bit = 0;
			if (MMC5Hack && (ScreenON || SpriteON)) MMC5_hb(scanline);
			for (x = 1, max = 0, maxref = 0; x < 7; x++) {
				if (deempcnt[x] > max) {
					max = deempcnt[x];
					maxref = x;
				}
				deempcnt[x] = 0;
			}
			SetNESDeemph(maxref, 0);
		}
	}

	{
		FCEU_PutImage();
		return(1);
	}
}

static uint16_t TempAddrT, RefreshAddrT;

void FCEUPPU_LoadState(int version) {
	spr_lines_dirty = 1;
	TempAddr = TempAddrT;
	RefreshAddr = RefreshAddrT;
}

SFORMAT FCEUPPU_STATEINFO[] = {
	{ NTARAM, 0x800, "NTAR" },
	{ PALRAM, 0x20, "PRAM" },
	{ SPRAM, 0x100, "SPRA" },
	{ PPU, 0x4, "PPUR" },
	{ &kook, 1, "KOOK" },
	{ &ppudead, 1, "DEAD" },
	{ &PPUSPL, 1, "PSPL" },
	{ &XOffset, 1, "XOFF" },
	{ &vtoggle, 1, "VTGL" },
	{ &RefreshAddrT, 2 | FCEUSTATE_RLSB, "RADD" },
	{ &TempAddrT, 2 | FCEUSTATE_RLSB, "TADD" },
	{ &VRAMBuffer, 1, "VBUF" },
	{ &PPUGenLatch, 1, "PGEN" },
	{ 0 }
};

void FCEUPPU_SaveState(void) {
	TempAddrT = TempAddr;
	RefreshAddrT = RefreshAddr;
}
