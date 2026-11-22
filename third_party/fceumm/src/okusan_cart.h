#ifndef OKUSAN_CART_H
#define OKUSAN_CART_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__cplusplus) || (defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L) || defined(__GNUC__) || defined(__clang__)
#define OKUSAN_INLINE static inline
#else
#define OKUSAN_INLINE static __inline
#endif

enum {
	OKUSAN_CART_PIN_COUNT = 60
};

/* Real HVC-001 60-pin Famicom card-edge physical dimensions in micrometers (um) */
enum {
	OKUSAN_PIN_PITCH_UM        = 2540,  /* 2.54 mm pitch across 30 positions */
	OKUSAN_CARD_HALF_UM        = 39000, /* 78.00 mm cartridge PCB edge width */
	OKUSAN_CARD_THICK_UM       = 1600,  /* 1.60 mm cartridge FR4 PCB thickness */
	OKUSAN_PAD_WIDTH_UM        = 1550,  /* 1.55 mm gold finger width (0.99 mm comb barrier gap) */
	OKUSAN_PAD_BOT_UM          = 1000,  /* 1.00 mm chamfered bottom offset */
	OKUSAN_PAD_TOP_UM          = 7500,  /* 7.50 mm top of pad (6.50 mm tall pad) */
	OKUSAN_WIPER_WIDTH_UM      = 1100,  /* 1.10 mm console spring leaf width inside blue pocket */
	OKUSAN_WIPER_BOT_UM        = 2500,  /* 2.50 mm spring crown bottom height */
	OKUSAN_WIPER_TOP_UM        = 4200,  /* 4.20 mm spring crown top height (1.70 mm = 1.87 mm^2) */
	OKUSAN_SOCKET_DEPTH_UM     = 10000, /* 10.00 mm console socket slot depth */
	OKUSAN_SLOT_PLAY_UM        = 350,   /* +/-0.35 mm side guide lateral clearance */
	OKUSAN_BRIDGE_THRESHOLD_UM = 1215   /* Min lateral shear for copper short (> max tilt+play) */
};

enum {
	OKUSAN_PIN_SEATED   = 0,
	OKUSAN_PIN_WEAK     = 1,
	OKUSAN_PIN_MARGINAL = 2,
	OKUSAN_PIN_OPEN     = 3,
	OKUSAN_PIN_FLAG_XTALK_L = 0x10,
	OKUSAN_PIN_FLAG_XTALK_R = 0x20
};

/* Physical 0-based pin indices: Front 0..29 = Pins 1..30, Back 30..59 = Pins 31..60 */
enum {
	/* Front face (controller side): Pins 1..30 */
	OKUSAN_PIN_GND1 = 0,     OKUSAN_PIN_CPU_A11 = 1,  OKUSAN_PIN_CPU_A10 = 2,  OKUSAN_PIN_CPU_A9 = 3,   OKUSAN_PIN_CPU_A8 = 4,
	OKUSAN_PIN_CPU_A7 = 5,   OKUSAN_PIN_CPU_A6 = 6,   OKUSAN_PIN_CPU_A5 = 7,   OKUSAN_PIN_CPU_A4 = 8,   OKUSAN_PIN_CPU_A3 = 9,
	OKUSAN_PIN_CPU_A2 = 10,  OKUSAN_PIN_CPU_A1 = 11,  OKUSAN_PIN_CPU_A0 = 12,  OKUSAN_PIN_CPU_RW = 13,  OKUSAN_PIN_IRQ = 14,
	OKUSAN_PIN_GND2 = 15,    OKUSAN_PIN_PPU_RD = 16,  OKUSAN_PIN_CIRAM_A10 = 17, OKUSAN_PIN_PPU_A6 = 18, OKUSAN_PIN_PPU_A5 = 19,
	OKUSAN_PIN_PPU_A4 = 20,  OKUSAN_PIN_PPU_A3 = 21,  OKUSAN_PIN_PPU_A2 = 22,  OKUSAN_PIN_PPU_A1 = 23,  OKUSAN_PIN_PPU_A0 = 24,
	OKUSAN_PIN_PPU_D0 = 25,  OKUSAN_PIN_PPU_D1 = 26,  OKUSAN_PIN_PPU_D2 = 27,  OKUSAN_PIN_PPU_D3 = 28,  OKUSAN_PIN_VCC_R = 29,
	/* Back face (red-slider side): Pins 31..60 */
	OKUSAN_PIN_VCC_L = 30,   OKUSAN_PIN_M2 = 31,      OKUSAN_PIN_CPU_A12 = 32, OKUSAN_PIN_CPU_A13 = 33, OKUSAN_PIN_CPU_A14 = 34,
	OKUSAN_PIN_CPU_D7 = 35,  OKUSAN_PIN_CPU_D6 = 36,  OKUSAN_PIN_CPU_D5 = 37,  OKUSAN_PIN_CPU_D4 = 38,  OKUSAN_PIN_CPU_D3 = 39,
	OKUSAN_PIN_CPU_D2 = 40,  OKUSAN_PIN_CPU_D1 = 41,  OKUSAN_PIN_CPU_D0 = 42,  OKUSAN_PIN_ROMSEL = 43,  OKUSAN_PIN_SND_IN = 44,
	OKUSAN_PIN_SND_OUT = 45, OKUSAN_PIN_PPU_WR = 46,  OKUSAN_PIN_CIRAM_CE = 47, OKUSAN_PIN_PPU_NA13 = 48, OKUSAN_PIN_PPU_A7 = 49,
	OKUSAN_PIN_PPU_A8 = 50,  OKUSAN_PIN_PPU_A9 = 51,  OKUSAN_PIN_PPU_A10 = 52, OKUSAN_PIN_PPU_A11 = 53, OKUSAN_PIN_PPU_A12 = 54,
	OKUSAN_PIN_PPU_A13 = 55, OKUSAN_PIN_PPU_D7 = 56,  OKUSAN_PIN_PPU_D6 = 57,  OKUSAN_PIN_PPU_D5 = 58,  OKUSAN_PIN_PPU_D4 = 59
};

enum {
	OKUSAN_PCLS_GND = 0,
	OKUSAN_PCLS_VCC = 1,
	OKUSAN_PCLS_SIG = 2
};

typedef struct {
	int16_t  wear_um;    /* Per-pin spring/chamfer/oxide tolerance (-200 .. +180 um) */
	uint8_t  pin_class;  /* OKUSAN_PCLS_GND / OKUSAN_PCLS_VCC / OKUSAN_PCLS_SIG */
	uint8_t  salt;       /* Per-pin hash salt for deterministic micro-drift */
} OkusanPinSpec;

typedef struct {
	uint8_t  state;       /* 0=OK, 1=WEAK, 2=MARGINAL, 3=OPEN + XTALK bits (0x10/0x20) */
	uint8_t  duty_pct;    /* 0..100% live HIGH level ratio observed at this pin */
	uint8_t  toggling;    /* 0=static, 1=occasional transitions, 2=active MHz bus traffic */
	uint8_t  fault_pct;   /* 0..100% live bit-corruption/mismatch ratio observed at this pin */
	int16_t  rise_um;     /* Vertical edge lift at this pin (um) */
	int16_t  overlap_um;  /* Contact overlap length (0..1700 um); area = overlap*1.1/1000 mm^2 */
	uint16_t bus_orig;    /* Latest original word (addr/data) driven onto this bus */
	uint16_t bus_eff;     /* Latest effective word after pin contact faults */
} OkusanPinTelemetry60;

/* Shared per-frame runtime state for zero-overhead inline CPU/PPU bus hooks */
typedef struct {
	int      active;
	uint8_t  cached_pins[OKUSAN_CART_PIN_COUNT];
	int16_t  cached_rise_um[OKUSAN_CART_PIN_COUNT];
	int16_t  cached_overlap_um[OKUSAN_CART_PIN_COUNT];
	int      power_dead;
	int      vcc_mv;
	int      audio_q;
	int      gnd_bounce_cpu_q;
	int      gnd_bounce_ppu_q;
	int      vcc_slow_q;
	uint32_t frame_tick;

	uint32_t acc_cnt[OKUSAN_CART_PIN_COUNT];
	uint32_t acc_hi[OKUSAN_CART_PIN_COUNT];
	uint32_t acc_tog[OKUSAN_CART_PIN_COUNT];
	uint32_t acc_fault[OKUSAN_CART_PIN_COUNT];
	uint8_t  acc_prev_bit[OKUSAN_CART_PIN_COUNT];
	uint16_t acc_orig_word[OKUSAN_CART_PIN_COUNT];
	uint16_t acc_eff_word[OKUSAN_CART_PIN_COUNT];
} OkusanCartRuntime;

extern const OkusanPinSpec okusan_pins60_spec[OKUSAN_CART_PIN_COUNT];
extern OkusanCartRuntime   okusan_cart_rt;

/* Slow boundary micro-drift (~2.1 s period at 60 Hz) so screen corruption stays rock-steady */
OKUSAN_INLINE uint32_t okusan_frame_drift(uint32_t salt) {
	uint32_t step = (okusan_cart_rt.frame_tick >> 7) + salt * 41u;
	uint32_t hash = (step ^ (step >> 3)) * 2246822519u;
	return (hash >> 24) & 255u;
}

OKUSAN_INLINE uint32_t okusan_pin_chatter(uint32_t salt) {
	return okusan_frame_drift(salt + 17u);
}

OKUSAN_INLINE void okusan_trace_pin_bit(int pin_idx, uint32_t orig_bit, uint32_t eff_bit,
                                        uint16_t orig_word, uint16_t eff_word) {
	uint8_t eb = (uint8_t)(eff_bit ? 1u : 0u);
	uint8_t ob = (uint8_t)(orig_bit ? 1u : 0u);
	okusan_cart_rt.acc_cnt[pin_idx]++;
	okusan_cart_rt.acc_hi[pin_idx] += eb;
	if (eb != okusan_cart_rt.acc_prev_bit[pin_idx]) okusan_cart_rt.acc_tog[pin_idx]++;
	if (eb != ob) okusan_cart_rt.acc_fault[pin_idx]++;
	okusan_cart_rt.acc_prev_bit[pin_idx]  = eb;
	okusan_cart_rt.acc_orig_word[pin_idx] = orig_word;
	okusan_cart_rt.acc_eff_word[pin_idx]  = eff_word;
}

OKUSAN_INLINE int okusan_ctrl_pin_dropped(int pin_idx, uint32_t salt, uint32_t thresh) {
	uint8_t contact_state = okusan_cart_rt.cached_pins[pin_idx] & 0x0Fu;
	return (contact_state == OKUSAN_PIN_OPEN ||
	        (contact_state == OKUSAN_PIN_MARGINAL && okusan_pin_chatter(salt) < thresh));
}

/* Simulates electrical transfer of one signal bit across a seated, weak (RC-lagged), marginal, or open pin. */
OKUSAN_INLINE uint32_t okusan_pin_xfer_bit(
	int pin_idx, uint32_t val_bit, uint32_t prev_bit_in,
	uint32_t xtalk_left_bit, uint32_t xtalk_right_bit, uint32_t float_bit_in,
	uint32_t bus_hash, int is_ppu) {
	uint8_t raw_state     = okusan_cart_rt.cached_pins[pin_idx];
	uint8_t contact_state = raw_state & 0x0Fu;
	uint32_t driven_bit   = val_bit ? 1u : 0u;
	uint32_t prev_bit     = prev_bit_in ? 1u : 0u;
	int stress_q = (is_ppu ? okusan_cart_rt.gnd_bounce_ppu_q : okusan_cart_rt.gnd_bounce_cpu_q)
	             + okusan_cart_rt.vcc_slow_q;

	if (contact_state == OKUSAN_PIN_SEATED) {
		if (stress_q > 0 && driven_bit != prev_bit) {
			uint32_t h = (bus_hash ^ okusan_pins60_spec[pin_idx].salt ^ (okusan_cart_rt.frame_tick >> 7)) & 255u;
			if (h < (uint32_t)(stress_q / 3)) return prev_bit;
		}
		return driven_bit;
	}

	uint32_t float_bit  = float_bit_in ? 1u : 0u;
	int has_xtalk_l     = (raw_state & OKUSAN_PIN_FLAG_XTALK_L) != 0;
	int has_xtalk_r     = (raw_state & OKUSAN_PIN_FLAG_XTALK_R) != 0;
	uint32_t coupled_bit = has_xtalk_l
	    ? (xtalk_left_bit ? 1u : 0u)
	    : (has_xtalk_r ? (xtalk_right_bit ? 1u : 0u) : float_bit);
	uint32_t drift_sample = okusan_pin_chatter(okusan_pins60_spec[pin_idx].salt);

	if (contact_state == OKUSAN_PIN_WEAK) {
		/* Asymmetric RC slew lag: 0->1 pull-up rises slower than 1->0 NMOS sink, scaled continuously by area */
		int overlap_um = okusan_cart_rt.cached_overlap_um[pin_idx];
		int weak_q = ((960 - overlap_um) * 205) / 540 + stress_q;
		if (weak_q < 0)   weak_q = 0;
		if (weak_q > 255) weak_q = 255;

		uint32_t phase = (bus_hash + okusan_pins60_spec[pin_idx].salt * 19u + (drift_sample >> 3)) & 255u;
		if (!is_ppu && overlap_um >= 620) {
			/* On light/medium oxidized CPU pins, slew glitch occurs only on rare transitions
			 * (~1 in 2048 edges) so games boot past the reset vector and crash naturally mid-boot. */
			if (((bus_hash ^ okusan_cart_rt.frame_tick) & 15u) != 0u) return driven_bit;
			phase  = ((bus_hash * 29u) + (drift_sample >> 1)) & 1023u;
			weak_q = (weak_q >> 5) + 1;
		}
		if (driven_bit && !prev_bit) {
			if (phase < (uint32_t)weak_q) return 0u;
		} else if (!driven_bit && prev_bit) {
			int fall_q = (weak_q > 130) ? ((weak_q - 130) * 2) : 0;
			if (phase < (uint32_t)fall_q) return 1u;
		} else if (weak_q >= 235 && phase < 24u) {
			return prev_bit ^ 1u;
		}
		return driven_bit;
	}

	if (contact_state == OKUSAN_PIN_MARGINAL) {
		/* Grazing chamfer contact: holds neighbor/prev steadily, with rare open dropouts */
		if (drift_sample < 12u) return float_bit;
		if (has_xtalk_l || has_xtalk_r) return coupled_bit;
		return (driven_bit != prev_bit) ? prev_bit : driven_bit;
	}

	/* OKUSAN_PIN_OPEN: High-Z capacitive coupling tracks active neighbor stably, else floats */
	if ((has_xtalk_l || has_xtalk_r) && coupled_bit != float_bit) return coupled_bit;
	return float_bit;
}

/* Fast inline check used in hot 1.79 MHz CPU / 5.37 MHz PPU loops when cartridge is seated flat. */
OKUSAN_INLINE int okusan_cart_is_active(void) {
	return okusan_cart_rt.active;
}

/* Physical 3-DOF 60-pin Famicom cartridge contact simulator shared by CPU, PPU, and Audio. */
void okusan_set_cart_contact(int tilt, int lift);
void okusan_set_cart_contact3(int tilt, int lift, int pitch);
void okusan_set_pin_fault_masks(uint64_t weak_mask, uint64_t open_mask);
void okusan_reseat_cart_contact(void);
void okusan_begin_ppu_frame(void);
int  okusan_cart_is_powered(void);
int  okusan_cart_vcc_mv(void);
int  okusan_cart_edge_rise_um(int tilt, int lift, int x_um);
int  okusan_cart_lat_shift_um(int tilt, int lift);
void okusan_get_pin_telemetry60(int *out_tilt, int *out_lift, int *out_pitch,
                                OkusanPinTelemetry60 *out_tel, int max_pins);
int  okusan_get_audio_contact_q(void); /* 0..256 cart audio pass-through (Pins 45/46) */

/* CPU 6502 cart bus hooks ($4020-$FFFF read/write) + live bus telemetry called from x6502.c */
void     okusan_trace_cpu_bus(uint32_t orig_a, uint32_t eff_a, uint8_t orig_d, uint8_t eff_d, int is_write);
uint32_t okusan_prg_map_addr(uint32_t addr, int *romsel_open);
uint8_t  okusan_prg_map_data(uint8_t val, uint8_t open_bus);
int      okusan_cpu_map_write(uint32_t addr, uint8_t val, uint32_t *out_addr, uint8_t *out_val);
int      okusan_map_irq(int irq_low);
int      okusan_get_cpu_jammed(void);
uint16_t okusan_get_cpu_pc(void);

/* Implemented in ppu.c: applies one-shot bus-derived CIRAM corruption on '?' reseat while PPU is active */
void okusan_ppu_on_reseat_latch(int ciram_severity, int ppu_fault_count,
                                int tilt, int lift, int pitch, uint32_t frame_tick);

/* Famicom 3D System (HVC-031 / HVC-032) shutter telemetry ($4016 bit 1 OUT1) */
void okusan_record_4016_out1(uint8_t out1_bit);
int  okusan_get_3d_system_active(void);
int  okusan_get_3d_current_eye(void);

/* Famicom Disk System (HVC-022) BIOS standby, hot-swap, & fault telemetry */
enum {
	OKUSAN_FDS_MAX_SIDES  = 8,
	OKUSAN_FDS_SIDE_BYTES = 65500
};

enum OkusanFdsFaultMode {
	OKUSAN_FDS_FAULT_NONE = 0,
	OKUSAN_FDS_FAULT_ERR01_HALF_INSERTED = 1,
	OKUSAN_FDS_FAULT_ERR02_LOW_BATTERY   = 2,
	OKUSAN_FDS_FAULT_ERR21_BAD_VOL_HDR   = 3,
	OKUSAN_FDS_FAULT_ERR22_BLOCK1_ID     = 4,
	OKUSAN_FDS_FAULT_ERR23_BLOCK2_ID     = 5,
	OKUSAN_FDS_FAULT_ERR24_BLOCK3_ID     = 6,
	OKUSAN_FDS_FAULT_ERR25_BLOCK4_ID     = 7,
	OKUSAN_FDS_FAULT_ERR27_CRC_ERROR     = 8,
	OKUSAN_FDS_FAULT_ERR28_PREMATURE_END = 9
};

void     okusan_fds_tick_frame(void);
int      okusan_fds_is_active(void);
void     okusan_fds_get_status(int *out_inserted_side, int *out_total_sides,
                               int *out_motor_on, int *out_rw_activity,
                               uint32_t *out_seek_seq, uint32_t *out_latch_seq,
                               int *out_fault_mode);
int      okusan_fds_hot_swap_disk(const uint8_t *data, uint32_t size);
void     okusan_fds_eject_disk(void);
void     okusan_fds_set_side(int side);
void     okusan_fds_clear_fault(void);
int      okusan_fds_trigger_random_fault(uint32_t rng_seed);
uint8_t *okusan_fds_get_side_ptr(int side, const uint8_t **out_orig_ptr);

#ifdef __cplusplus
}
#endif

#endif /* OKUSAN_CART_H */
