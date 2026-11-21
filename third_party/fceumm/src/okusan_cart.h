#ifndef OKUSAN_CART_H
#define OKUSAN_CART_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
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

/* Physical 3-DOF 60-pin Famicom cartridge contact simulator shared by CPU, PPU, and Audio.
 * pins 0..29  = Front Pins 1..30  (GND, CPU A11..A0, R/W, /IRQ, GND, PPU /RD, CIRAM A10, PPU A6..A0, PPU D0..D3, +5V)
 * pins 30..59 = Back  Pins 31..60 (+5V, M2, CPU A12..A14, CPU D7..D0, /ROMSEL, SND IN/OUT, PPU /WR, CIRAM /CE, PPU /A13, PPU A7..A13, PPU D7..D4)
 * tilt:  -32 (left/PRG lifted) .. 0 (seated) .. +32 (right/PPU lifted)
 * lift:    0 (seated) .. +16 (uniform vertical pull-up)
 * pitch:  -8 (front face lifted) .. 0 (flat) .. +8 (back/red-slider face lifted)
 */
void okusan_set_cart_contact(int tilt, int lift);
void okusan_set_cart_contact3(int tilt, int lift, int pitch);
void okusan_set_pin_fault_masks(uint64_t weak_mask, uint64_t open_mask);
void okusan_reseat_cart_contact(void);
int  okusan_cart_is_active(void);
int  okusan_cart_is_powered(void);
int  okusan_cart_vcc_mv(void);
int  okusan_cart_edge_rise_um(int tilt, int lift, int x_um);
int  okusan_cart_lat_shift_um(int tilt, int lift);
void okusan_get_pin_telemetry60(int *out_tilt, int *out_lift, int *out_pitch,
                                OkusanPinTelemetry60 *out_tel, int max_pins);
int  okusan_get_audio_contact_q(void); /* 0..256 cart audio pass-through (Pins 45/46) */

/* CPU 6502 cart bus hooks ($6000-$FFFF read/write) + live bus telemetry called from x6502.c */
void     okusan_trace_cpu_bus(uint32_t orig_a, uint32_t eff_a, uint8_t orig_d, uint8_t eff_d, int is_write);
uint32_t okusan_prg_map_addr(uint32_t addr, int *romsel_open);
uint8_t  okusan_prg_map_data(uint8_t val, uint8_t open_bus);
int      okusan_cpu_map_write(uint32_t addr, uint8_t val, uint32_t *out_addr, uint8_t *out_val);
int      okusan_map_irq(int irq_low);
int      okusan_get_cpu_jammed(void);
uint16_t okusan_get_cpu_pc(void);

#ifdef __cplusplus
}
#endif

#endif /* OKUSAN_CART_H */
