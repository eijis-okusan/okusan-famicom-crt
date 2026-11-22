/* FCE Ultra - NES/Famicom Emulator
 *
 * Copyright notice for this file:
 *  Copyright (C) 2002 Xodnizel
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

/* dec-12-19                                    */
/* 4024(w), 4025(w), 4031(r) by dink(fbneo)     */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fceu-types.h"
#include "x6502.h"
#include "fceu.h"
#include "fds.h"
#include "fds_apu.h"
#include "sound.h"
#include "general.h"
#include "state.h"
#include "file.h"
#include "fceu-memory.h"
#include "cart.h"
#include "okusan_cart.h"
#include "md5.h"

/*	TODO:  Add code to put a delay in between the time a disk is inserted
 *	and the when it can be successfully read/written to.  This should
 *	prevent writes to wrong places OR add code to prevent disk ejects
 *	when the virtual motor is on(mmm...virtual motor).
 */

static DECLFR(FDSRead4030);
static DECLFR(FDSRead4031);
static DECLFR(FDSRead4032);
static DECLFR(FDSRead4033);

static DECLFW(FDSWrite);

static void FDSInit(void);
static void FDSClose(void);

static void FP_FASTAPASS(1) FDSFix(int a);

static uint8_t FDSRegs[6];
static int32_t IRQLatch, IRQCount;
static uint8_t IRQa;

static uint8_t *FDSROM = NULL;
static uint32_t FDSROMSize = 0;
static uint8_t *FDSRAM = NULL;
static uint32_t FDSRAMSize;
static uint8_t *FDSBIOS = NULL;
static uint32_t FDSBIOSsize;
static uint8_t *CHRRAM = NULL;
static uint32_t CHRRAMSize;

/* Original disk data backup, to help in creating save states. */
static uint8_t *diskdatao_buf = NULL;
static uint8_t *diskdatao[OKUSAN_FDS_MAX_SIDES] = { 0, 0, 0, 0, 0, 0, 0, 0 };
static uint8_t *diskdata[OKUSAN_FDS_MAX_SIDES] = { 0, 0, 0, 0, 0, 0, 0, 0 };

static uint32_t TotalSides;
static uint8_t DiskWritten = 0;	/* Set to 1 if disk was written to. */
static uint8_t writeskip;
static int32_t DiskPtr;
static int32_t DiskSeekIRQ;
static uint8_t SelectDisk, InDisk;

/* Okusan CRT FDS live status, delayed swap, mechanical synth telemetry, and fault injector */
static int      okusan_fds_active = 0;
static int      okusan_fds_pending_side = -1;
static int      okusan_fds_delayed_insert_frames = 0;
static int      okusan_fds_rw_decay = 0;
static uint32_t okusan_fds_seek_seq = 0;
static uint32_t okusan_fds_latch_seq = 0;
static int      okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
static int      okusan_fds_fault_motor_frames = 0;
static int      okusan_fds_err01_tripped = 0;
static uint32_t okusan_fds_fault_rng_ctr = 0x9E3779B9u;

enum FDS_DiskBlockIDs {
	DSK_INIT = 0,
	DSK_VOLUME,
	DSK_FILECNT,
	DSK_FILEHDR,
	DSK_FILEDATA
};

static uint8_t  mapperFDS_control;    /* 4025(w) control register */
static uint16_t mapperFDS_filesize;   /* size of file being read/written */
static uint8_t  mapperFDS_block;      /* block-id of current block */
static uint16_t mapperFDS_blockstart; /* start-address of current block */
static uint16_t mapperFDS_blocklen;   /* length of current block */
static uint16_t mapperFDS_diskaddr;   /* current address relative to blockstart */
static uint8_t  mapperFDS_diskaccess; /* disk needs to be accessed at least once before writing */

#define GET_FDS_DISK() (diskdata[InDisk][mapperFDS_blockstart + mapperFDS_diskaddr])
#define FDS_DISK_INSERTED (InDisk != 255)

#define DC_INC    1
#define BYTES_PER_SIDE 65500

uint8_t *FDSROM_ptr(void) {
	return (FDSROM);
}

uint32_t FDSROM_size(void) {
	return (FDSROMSize);
}

static void FDSGI(int h) {
	switch (h) {
	case GI_CLOSE: FDSClose(); break;
	case GI_POWER: FDSInit(); break;
	}
}

static void FDSStateRestore(int version) {
	uint32_t x;

	/* Sanity-check disk indices and block parameters. A malicious
	 * savestate could otherwise:
	 *  - set InDisk to a value 0..254 (255 means ejected) that's >=
	 *    TotalSides, causing the read path to index past the
	 *    8-element diskdata[] array and dereference an arbitrary
	 *    pointer-shaped 8 bytes (heap-read primitive);
	 *  - set mapperFDS_block to an out-of-enum value (no current
	 *    case crashes but better to clamp);
	 *  - set mapperFDS_blockstart + mapperFDS_diskaddr beyond 65500
	 *    (BYTES_PER_SIDE), causing GET_FDS_DISK() to OOB-read up
	 *    to 65 KB past the disk buffer. */
	if (TotalSides > OKUSAN_FDS_MAX_SIDES)
		TotalSides = OKUSAN_FDS_MAX_SIDES;
	if (InDisk != 255 && InDisk >= TotalSides)
		InDisk = 255;	/* eject */
	if (TotalSides == 0 || SelectDisk >= TotalSides)
		SelectDisk = 0;
	if (mapperFDS_block > DSK_FILEDATA)	/* enum values 0..4 are valid */
		mapperFDS_block = DSK_INIT;
	/* BYTES_PER_SIDE is 65500. The read/write sites compute
	 * (blockstart + diskaddr) as the offset into a 65500-byte buffer
	 * after gating on diskaddr < blocklen. Clamp each component such
	 * that any allowed (blockstart + diskaddr) stays within the buffer:
	 *  - blockstart < BYTES_PER_SIDE  (so the base is in-range)
	 *  - diskaddr fits in the remaining space, capped by blocklen anyway
	 *  - blocklen capped to BYTES_PER_SIDE - blockstart so the gating
	 *    check 'diskaddr < blocklen' is sufficient. */
	if (mapperFDS_blockstart >= BYTES_PER_SIDE)
		mapperFDS_blockstart = 0;
	if (mapperFDS_blocklen > BYTES_PER_SIDE - mapperFDS_blockstart)
		mapperFDS_blocklen = BYTES_PER_SIDE - mapperFDS_blockstart;
	if (mapperFDS_diskaddr > mapperFDS_blocklen)
		mapperFDS_diskaddr = mapperFDS_blocklen;

	setmirror(((FDSRegs[5] & 8) >> 3) ^ 1);

	if (version >= 9810)
		for (x = 0; x < TotalSides; x++) {
			int b;
			for (b = 0; b < 65500; b++)
				diskdata[x][b] ^= diskdatao[x][b];
		}
}

static void FDSInit(void) {
	memset(FDSRegs, 0, sizeof(FDSRegs));
	writeskip = DiskPtr = DiskSeekIRQ = 0;

	setmirror(1);
	setprg8(0xE000, 0);			/* BIOS */
	setprg32r(1, 0x6000, 0);	/* 32KB RAM */
	setchr8(0);					/* 8KB CHR RAM */

	MapIRQHook = FDSFix;
	GameStateRestore = FDSStateRestore;

	SetReadHandler(0x4030, 0x4030, FDSRead4030);
	SetReadHandler(0x4031, 0x4031, FDSRead4031);
	SetReadHandler(0x4032, 0x4032, FDSRead4032);
	SetReadHandler(0x4033, 0x4033, FDSRead4033);

	SetWriteHandler(0x4020, 0x4025, FDSWrite);

	SetWriteHandler(0x6000, 0xDFFF, CartBW);
	SetReadHandler(0x6000, 0xFFFF, CartBR);

	IRQCount = IRQLatch = IRQa = 0;

	FDSSoundReset();
	InDisk = (TotalSides > 0) ? 0 : 255;
	SelectDisk = 0;
	okusan_fds_active = 1;
	okusan_fds_pending_side = -1;
	okusan_fds_delayed_insert_frames = 0;
	okusan_fds_rw_decay = 0;
	okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;

	mapperFDS_control = 0;
	mapperFDS_filesize = 0;
	mapperFDS_block = 0;
	mapperFDS_blockstart = 0;
	mapperFDS_blocklen = 0;
	mapperFDS_diskaddr = 0;
	mapperFDS_diskaccess = 0;
}

void FCEU_FDSInsert(int oride) {
	if (InDisk == 255) {
		FCEU_DispMessage(RETRO_LOG_INFO, 2000, "Disk %d of %d Side %s Inserted",
				1 + (SelectDisk >> 1), (TotalSides + 1) >> 1, (SelectDisk & 1) ? "B" : "A");
		InDisk = SelectDisk;
	} else {
		FCEU_DispMessage(RETRO_LOG_INFO, 2000, "Disk %d of %d Side %s Ejected",
				1 + (SelectDisk >> 1), (TotalSides + 1) >> 1, (SelectDisk & 1) ? "B" : "A");
		InDisk = 255;
	}
}

void FCEU_FDSEject(void) {
	InDisk = 255;
}

void FCEU_FDSSelect(void) {
	if (InDisk != 255) {
		FCEUD_DispMessage(RETRO_LOG_WARN, 2000, "Eject disk before selecting");
		return;
	}
	SelectDisk = ((SelectDisk + 1) % TotalSides) & 3;
	FCEU_DispMessage(RETRO_LOG_INFO, 2000, "Disk %d of %d Side %s Selected",
			1 + (SelectDisk >> 1), (TotalSides + 1) >> 1, (SelectDisk & 1) ? "B" : "A");
}

/* 2018/12/15 - update irq timings */
static void FP_FASTAPASS(1) FDSFix(int a) {
	if ((IRQa & 2) && (FDSRegs[3] & 0x1)) {
		if (IRQCount <= 0) {
			if (!(IRQa & 1))
				IRQa &= ~2; /* does not clear latch, fix Druid */
			IRQCount = IRQLatch;
			X6502_IRQBegin(FCEU_IQEXT);
		} else {
			IRQCount -= a;
		}
	}

	if (DiskSeekIRQ > 0) {
		DiskSeekIRQ -= a;
		if (DiskSeekIRQ <= 0) {
			if (FDSRegs[5] & 0x80) {
				X6502_IRQBegin(FCEU_IQEXT2);
			}
		}
	}
}

static DECLFR(FDSRead4030) {
	uint8_t ret = 0;

	/* Cheap hack. */
	if (X.IRQlow & FCEU_IQEXT) ret |= 1;
	if (X.IRQlow & FCEU_IQEXT2) ret |= 2;

	if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR27_CRC_ERROR) {
		if (mapperFDS_diskaccess &&
		    ((mapperFDS_block >= DSK_FILECNT && (mapperFDS_control & 0x10)) ||
		     (mapperFDS_block >= DSK_FILEHDR && mapperFDS_diskaddr >= 2))) {
			ret |= 0x10;
		}
	} else if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR28_PREMATURE_END) {
		if (mapperFDS_block == DSK_FILEDATA && mapperFDS_diskaddr >= 2) {
			ret |= 0x40;
		}
	}

	{
		X6502_IRQEnd(FCEU_IQEXT);
		X6502_IRQEnd(FCEU_IQEXT2);
	}
	return ret;
}

static DECLFR(FDSRead4031) {
	uint8_t ret = 0xff;

	if (FDS_DISK_INSERTED && mapperFDS_control & 0x04) {
		mapperFDS_diskaccess = 1;
		okusan_fds_rw_decay = 4;
		ret = 0;

		if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR01_HALF_INSERTED &&
		    okusan_fds_err01_tripped) {
			DiskSeekIRQ = 150;
			X6502_IRQEnd(FCEU_IQEXT2);
			return 0xff;
		}

		switch (mapperFDS_block) {
		case DSK_FILEHDR:
			if (mapperFDS_diskaddr < mapperFDS_blocklen) {
				ret = GET_FDS_DISK();
				if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR24_BLOCK3_ID &&
				    mapperFDS_diskaddr == 0) {
					ret = 0x00;
				}
				switch (mapperFDS_diskaddr) {
				case 13:
					mapperFDS_filesize = ret;
					break;
				case 14:
					mapperFDS_filesize |= ret << 8;
					break;
				}
				mapperFDS_diskaddr++;
			}
			break;
		default:
			if (mapperFDS_diskaddr < mapperFDS_blocklen) {
				uint16_t rel_addr = mapperFDS_diskaddr;
				ret = GET_FDS_DISK();
				if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR21_BAD_VOL_HDR &&
				    mapperFDS_block == DSK_VOLUME && rel_addr >= 1 && rel_addr <= 14) {
					ret ^= 0x55;
				} else if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR22_BLOCK1_ID &&
				           mapperFDS_block == DSK_VOLUME && rel_addr == 0) {
					ret = 0x00;
				} else if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR23_BLOCK2_ID &&
				           mapperFDS_block == DSK_FILECNT && rel_addr == 0) {
					ret = 0x00;
				} else if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR25_BLOCK4_ID &&
				           mapperFDS_block == DSK_FILEDATA && rel_addr == 0) {
					ret = 0x00;
				}
				mapperFDS_diskaddr++;
			}
			break;
		}

		DiskSeekIRQ = 150;
		X6502_IRQEnd(FCEU_IQEXT2);
	}

	return ret;
}

static DECLFR(FDSRead4032) {
	uint8_t ret;

	ret = X.DB & ~7;
	if (InDisk == 255)
		ret |= 5;

	if (InDisk == 255 || !(FDSRegs[5] & 1) || (FDSRegs[5] & 2))
		ret |= 2;

	if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR01_HALF_INSERTED &&
	    (okusan_fds_err01_tripped || okusan_fds_fault_motor_frames >= 8)) {
		okusan_fds_err01_tripped = 1;
		ret |= 0x05;
	} else if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR28_PREMATURE_END &&
	           mapperFDS_block == DSK_FILEDATA && mapperFDS_diskaddr >= 2) {
		ret |= 0x02;
	}

	return ret;
}

static DECLFR(FDSRead4033) {
	if (okusan_fds_fault_mode == OKUSAN_FDS_FAULT_ERR02_LOW_BATTERY) {
		return 0x00;
	}
	return 0x80;		/* battery */
}

static DECLFW(FDSWrite) {
	switch (A) {
	case 0x4020:
		IRQLatch &= 0xFF00;
		IRQLatch |= V;
		break;
	case 0x4021:
		IRQLatch &= 0xFF;
		IRQLatch |= V << 8;
		break;
	case 0x4022:
		if (FDSRegs[3] & 0x1) {
			IRQa = (V & 0x3);
			if (IRQa & 2) {
				IRQCount = IRQLatch;
			} else {
				X6502_IRQEnd(FCEU_IQEXT);
				X6502_IRQEnd(FCEU_IQEXT2);
			}
		}
		break;
	case 0x4023:
		if (!(V & 1)) {
			X6502_IRQEnd(FCEU_IQEXT);
			X6502_IRQEnd(FCEU_IQEXT2);
		}
		break;
	case 0x4024:
		if (FDS_DISK_INSERTED && ~mapperFDS_control & 0x04) {
			okusan_fds_rw_decay = 4;

			if (mapperFDS_diskaccess == 0) {
				mapperFDS_diskaccess = 1;
				break;
			}

			switch (mapperFDS_block) {
				case DSK_FILEHDR:
					if (mapperFDS_diskaddr < mapperFDS_blocklen) {
						GET_FDS_DISK() = V;
						switch (mapperFDS_diskaddr) {
							case 13: mapperFDS_filesize = V; break;
							case 14:
								mapperFDS_filesize |= V << 8;
								break;
						}
						mapperFDS_diskaddr++;
					}
					break;
				default:
					if (mapperFDS_diskaddr < mapperFDS_blocklen) {
						GET_FDS_DISK() = V;
						mapperFDS_diskaddr++;
					}
					break;
			}

		}
		break;
	case 0x4025:
		X6502_IRQEnd(FCEU_IQEXT2);
		if (FDS_DISK_INSERTED) {
			if (V & 0x40 && ~mapperFDS_control & 0x40) {
				mapperFDS_diskaccess = 0;

				DiskSeekIRQ = 150;
				okusan_fds_seek_seq++;

				/* blockstart  - address of block on disk
				 * diskaddr    - address relative to blockstart
				 * _block -> _blockID ?
				 */
				mapperFDS_blockstart += mapperFDS_diskaddr;
				mapperFDS_diskaddr = 0;

				mapperFDS_block++;
				if (mapperFDS_block > DSK_FILEDATA)
					mapperFDS_block = DSK_FILEHDR;

				switch (mapperFDS_block) {
					case DSK_VOLUME:
						mapperFDS_blocklen = 0x38;
						break;
					case DSK_FILECNT:
						mapperFDS_blocklen = 0x02;
						break;
					case DSK_FILEHDR:
						mapperFDS_blocklen = 0x10;
						break;
					case DSK_FILEDATA:		 /* <blockid><filedata> */
						mapperFDS_blocklen = 0x01 + mapperFDS_filesize;
						break;
				}
			}

			if (V & 0x02) { /* transfer reset */
				mapperFDS_block = DSK_INIT;
				mapperFDS_blockstart = 0;
				mapperFDS_blocklen = 0;
				mapperFDS_diskaddr = 0;
				mapperFDS_diskaccess = 0;
				DiskSeekIRQ = 150;
				okusan_fds_seek_seq++;
			}
			if (V & 0x40) { /* turn on motor */
				DiskSeekIRQ = 150;
			}
		}
		mapperFDS_control = V;
		setmirror(((V >> 3) & 1) ^ 1);
		break;
	}
	FDSRegs[A & 7] = V;
}

struct codes_t {
	uint8_t code;
	char *name;
};

static const struct codes_t list[] = {
	{ 0x01, "Nintendo" },
	{ 0x02, "Rocket Games" },
	{ 0x08, "Capcom" },
	{ 0x09, "Hot B Co." },
	{ 0x0A, "Jaleco" },
	{ 0x0B, "Coconuts Japan" },
	{ 0x0C, "Coconuts Japan/G.X.Media" },
	{ 0x13, "Electronic Arts Japan" },
	{ 0x18, "Hudson Soft Japan" },
	{ 0x19, "S.C.P." },
	{ 0x1A, "Yonoman" },
	{ 0x20, "Destination Software" },
	{ 0x22, "VR 1 Japan" },
	{ 0x25, "San-X" },
	{ 0x28, "Kemco Japan" },
	{ 0x29, "Seta" },
	{ 0x36, "Codemasters" },
	{ 0x37, "GAGA Communications" },
	{ 0x38, "Laguna" },
	{ 0x39, "Telstar Fun and Games" },
	{ 0x41, "Ubi Soft Entertainment" },
	{ 0x42, "Sunsoft" },
	{ 0x47, "Spectrum Holobyte" },
	{ 0x49, "Irem" },
	{ 0x4A, "Gakken" },
	{ 0x4D, "Malibu Games" },
	{ 0x4F, "Eidos/U.S. Gold" },
	{ 0x50, "Absolute Entertainment" },
	{ 0x51, "Acclaim" },
	{ 0x52, "Activision" },
	{ 0x53, "American Sammy Corp." },
	{ 0x54, "Take 2 Interactive" },
	{ 0x55, "Hi Tech" },
	{ 0x56, "LJN LTD." },
	{ 0x58, "Mattel" },
	{ 0x5A, "Mindscape/Red Orb Ent." },
	{ 0x5C, "Taxan" },
	{ 0x5D, "Midway" },
	{ 0x5F, "American Softworks" },
	{ 0x60, "Titus Interactive Studios" },
	{ 0x61, "Virgin Interactive" },
	{ 0x62, "Maxis" },
	{ 0x64, "LucasArts Entertainment" },
	{ 0x67, "Ocean" },
	{ 0x69, "Electronic Arts" },
	{ 0x6E, "Elite Systems Ltd." },
	{ 0x6F, "Electro Brain" },
	{ 0x70, "Infogrames" },
	{ 0x71, "Interplay" },
	{ 0x72, "JVC Musical Industries Inc" },
	{ 0x73, "Parker Brothers" },
	{ 0x75, "SCI" },
	{ 0x78, "THQ" },
	{ 0x79, "Accolade" },
	{ 0x7A, "Triffix Ent. Inc." },
	{ 0x7C, "Microprose Software" },
	{ 0x7D, "Universal Interactive Studios" },
	{ 0x7F, "Kemco" },
	{ 0x80, "Misawa" },
	{ 0x83, "LOZC" },
	{ 0x8B, "Bulletproof Software" },
	{ 0x8C, "Vic Tokai Inc." },
	{ 0x91, "Chun Soft" },
	{ 0x92, "Video System" },
	{ 0x93, "BEC" },
	{ 0x96, "Yonezawa/S'pal" },
	{ 0x97, "Kaneko" },
	{ 0x99, "Victor Interactive Software" },
	{ 0x9A, "Nichibutsu/Nihon Bussan" },
	{ 0x9B, "Tecmo" },
	{ 0x9C, "Imagineer" },
	{ 0x9F, "Nova" },
	{ 0xA0, "Telenet" },
	{ 0xA1, "Hori" },
	{ 0xA2, "Scorpion Soft " },
	{ 0xA4, "Konami" },
	{ 0xA6, "Kawada" },
	{ 0xA7, "Takara" },
	{ 0xA8, "Royal Industries" },
	{ 0xA9, "Technos Japan Corp." },
	{ 0xAA, "JVC" },
	{ 0xAC, "Toei Animation" },
	{ 0xAD, "Toho" },
	{ 0xAF, "Namco" },
	{ 0xB0, "Acclaim Japan" },
	{ 0xB1, "ASCII" },
	{ 0xB2, "Bandai" },
	{ 0xB3, "Soft Pro Inc." },
	{ 0xB4, "Enix" },
	{ 0xB6, "HAL Laboratory" },
	{ 0xB7, "SNK" },
	{ 0xB9, "Pony Canyon Hanbai" },
	{ 0xBA, "Culture Brain" },
	{ 0xBB, "Sunsoft" },
	{ 0xBC, "Toshiba EMI" },
	{ 0xBD, "Sony Imagesoft" },
	{ 0xBF, "Sammy" },
	{ 0xC0, "Taito" },
	{ 0xC1, "Sunsoft / Ask Co., Ltd." },
	{ 0xC2, "Kemco" },
	{ 0xC3, "Square Soft" },
	{ 0xC4, "Tokuma Shoten " },
	{ 0xC5, "Data East" },
	{ 0xC6, "Tonkin House" },
	{ 0xC7, "East Cube" },
	{ 0xC8, "Koei" },
	{ 0xCA, "Konami/Palcom/Ultra" },
	{ 0xCB, "Vapinc/NTVIC" },
	{ 0xCC, "Use Co.,Ltd." },
	{ 0xCD, "Meldac" },
	{ 0xCE, "FCI/Pony Canyon" },
	{ 0xCF, "Angel" },
	{ 0xD1, "Sofel" },
	/*{ 0xD2, "Quest" },*/
	{ 0xD2, "Bothtec, Inc." },
	{ 0xD3, "Sigma Enterprises" },
	{ 0xD4, "Ask Kodansa" },
	{ 0xD6, "Naxat" },
	{ 0xD7, "Copya System" },
	{ 0xD9, "Banpresto" },
	{ 0xDA, "TOMY" },
	/*{ 0xDB, "LJN Japan" },*/
	{ 0xDB, "Hiro Co., Ltd." },
	{ 0xDD, "NCS" },
	{ 0xDF, "Altron Corporation" },
	{ 0xE2, "Yutaka" },
	{ 0xE3, "Varie" },
	{ 0xE5, "Epoch" },
	{ 0xE7, "Athena" },
	{ 0xE8, "Asmik Ace Entertainment Inc." },
	{ 0xE9, "Natsume" },
	{ 0xEA, "King Records" },
	{ 0xEB, "Atlus" },
	{ 0xEC, "Epic/Sony Records" },
	{ 0xEE, "IGS" },
	{ 0xF0, "A Wave" },
	{ 0 }
 };

static const char *getManufacturer(uint8_t code)
{
	int x = 0;
	char *ret = "unlicensed";

	while (list[x].code != 0) {
		if (list[x].code == code) {
			ret = list[x].name;
			break;
		}
		x++;
	} 

	return ret;
}

static void FreeFDSMemory(void) {
	uint32_t x;
	if (FDSROM)
		free(FDSROM);
	FDSROM = NULL;
	FDSROMSize = 0;
	if (diskdatao_buf)
		free(diskdatao_buf);
	diskdatao_buf = NULL;
	for (x = 0; x < OKUSAN_FDS_MAX_SIDES; x++) {
		diskdata[x] = NULL;
		diskdatao[x] = NULL;
	}
	if (FDSBIOS)
		free(FDSBIOS);
	FDSBIOS = NULL;
	if (FDSRAM)
		free(FDSRAM);
	FDSRAM = NULL;
	if (CHRRAM)
		free(CHRRAM);
	CHRRAM = NULL;
}

static int SubLoad(FCEUFILE *fp) {
	struct md5_context md5;
	/* Zero-initialise so that if FCEU_fread returns short for any reason
	 * (truncated stream mid-read, IO error etc.) the downstream memcmps and
	 * header[4] read see deterministic 0s rather than stack garbage. */
	uint8_t header[16] = {0};
	uint32_t x;
	uint64_t fsize = FCEU_fgetsize(fp);

	/* Reject files too short to contain a 16-byte header. Otherwise the
	 * subsequent FCEU_fread leaves header[] partially uninitialised, and
	 * the magic-string memcmps and side-count read at header[4] could
	 * spuriously succeed on stack garbage. */
	if (fsize < 16)
		return(0);

	if (FCEU_fread(header, 1, 16, fp) != 16)
		return(0);

	if (memcmp(header, "FDS\x1a", 4)) {
		if (!(memcmp(header + 1, "*NINTENDO-HVC*", 14))) {
			long t;
			t = FCEU_fgetsize(fp);
			if (t < 65500)
				t = 65500;
			TotalSides = t / 65500;
			FCEU_fseek(fp, 0, SEEK_SET);
		} else
			return(0);
	} else
		TotalSides = header[4];

	if (TotalSides > OKUSAN_FDS_MAX_SIDES) TotalSides = OKUSAN_FDS_MAX_SIDES;
	if (TotalSides < 1) TotalSides = 1;

	/* Pre-allocate all 8 side slots so later hot-swapping never invalidates ExState pointers. */
	FDSROMSize = OKUSAN_FDS_MAX_SIDES * BYTES_PER_SIDE;
	FDSROM = (uint8_t*)FCEU_malloc(FDSROMSize);
	if (!FDSROM)
		return (0);
	memset(FDSROM, 0, FDSROMSize);

	for (x = 0; x < OKUSAN_FDS_MAX_SIDES; x++)
		diskdata[x] = &FDSROM[x * BYTES_PER_SIDE];

	md5_starts(&md5);

	for (x = 0; x < TotalSides; x++) {
		/* Zero from FCEU_malloc covers any short read here; flag it so
		 * the user knows a side is incomplete. */
		if (FCEU_fread(diskdata[x], 1, 65500, fp) != 65500)
			FCEU_PrintError(" FDS side %u truncated.\n", (unsigned)x);
		md5_update(&md5, diskdata[x], 65500);
	}
	md5_finish(&md5, GameInfo->MD5);
	return(1);
}

static void PreSave(void) {
	uint32_t x;
	for (x = 0; x < TotalSides; x++) {
		int b;
		for (b = 0; b < 65500; b++)
			diskdata[x][b] ^= diskdatao[x][b];
	}
}

static void PostSave(void) {
	uint32_t x;
	for (x = 0; x < TotalSides; x++) {
		int b;
		for (b = 0; b < 65500; b++)
			diskdata[x][b] ^= diskdatao[x][b];
	}
}

static int find_bytes_in_slice(const uint8_t *haystack, size_t hay_len,
                               const uint8_t *needle, size_t needle_len) {
	size_t i;
	if (!haystack || !needle || needle_len == 0 || hay_len < needle_len) return 0;
	for (i = 0; i <= hay_len - needle_len; i++) {
		if (haystack[i] == needle[0] && memcmp(haystack + i, needle, needle_len) == 0) {
			return 1;
		}
	}
	return 0;
}

/* Extracts an 8 KB FDS BIOS image from either raw 8 KB dumps, mirrored 16 KB dumps,
 * or iNES-wrapped (.nes, CHR == 0) BIOS files into `out_bios`. Returns 1 on match. */
static int extract_fds_bios_from_fp(FCEUFILE *fp, uint8_t *out_bios) {
	static const uint8_t kFdsHvcSig[14] = {
		'*','N','I','N','T','E','N','D','O','-','H','V','C','*'
	};
	uint64_t fsize;
	uint8_t *buf;
	size_t read_len;
	size_t prg_start = 0;
	size_t num_chunks;
	int is_ines = 0;
	int found = 0;
	long long k;

	if (!fp || !out_bios) return 0;
	fsize = FCEU_fgetsize(fp);
	if (fsize < 8192 || fsize > 65552) return 0;

	buf = (uint8_t *)malloc((size_t)fsize);
	if (!buf) return 0;

	FCEU_fseek(fp, 0, SEEK_SET);
	read_len = FCEU_fread(buf, 1, (size_t)fsize, fp);
	FCEU_fseek(fp, 0, SEEK_SET);

	if (read_len != (size_t)fsize) {
		free(buf);
		return 0;
	}

	if (fsize == 8192 && memcmp(buf, "NES\x1a", 4) != 0) {
		if (buf[0x1FFD] >= 0xE0) {
			memcpy(out_bios, buf, 8192);
			found = 1;
		}
		free(buf);
		return found;
	}

	if (fsize >= 16 && memcmp(buf, "NES\x1a", 4) == 0) {
		is_ines = 1;
		if (buf[5] != 0) { /* FDS BIOS never uses CHR-ROM banks */
			free(buf);
			return 0;
		}
		prg_start = 16u + ((buf[6] & 4u) ? 512u : 0u);
	}

	if (fsize <= prg_start || (fsize - prg_start) < 8192) {
		free(buf);
		return 0;
	}

	num_chunks = (size_t)((fsize - prg_start) / 8192u);
	/* Prefer the highest 8 KB bank first (NROM-128 maps $E000-$FFFF to the last 8 KB). */
	for (k = (long long)num_chunks - 1; k >= 0; k--) {
		const uint8_t *chunk = buf + prg_start + (size_t)k * 8192u;
		if (chunk[0x1FFD] >= 0xE0 &&
		    find_bytes_in_slice(chunk, 8192u, kFdsHvcSig, sizeof(kFdsHvcSig))) {
			memcpy(out_bios, chunk, 8192u);
			found = 1;
			break;
		}
	}
	(void)is_ines;
	free(buf);
	return found;
}

int FDSIsBiosStream(FCEUFILE *fp) {
	uint8_t tmp[8192];
	return extract_fds_bios_from_fp(fp, tmp);
}

int FDSLoad(const char *name, FCEUFILE *fp) {
	uint32_t x;
	int bios_standby = 0;

	FreeFDSMemory();
	ResetCartMapping();

	FDSBIOSsize = 8192;
	FDSBIOS = (uint8_t*)FCEU_gmalloc(FDSBIOSsize);
	if (!FDSBIOS)
		return 0;

	if (extract_fds_bios_from_fp(fp, FDSBIOS)) {
		/* Direct 8 KB / wrapped FDS BIOS load -> boot FDS BIOS standby with empty drive */
		struct md5_context bios_md5;
		SetupCartPRGMapping(0, FDSBIOS, FDSBIOSsize, 0);
		md5_starts(&bios_md5);
		md5_update(&bios_md5, FDSBIOS, FDSBIOSsize);
		md5_finish(&bios_md5, GameInfo->MD5);

		TotalSides = 0;
		FDSROMSize = OKUSAN_FDS_MAX_SIDES * BYTES_PER_SIDE;
		FDSROM = (uint8_t*)FCEU_malloc(FDSROMSize);
		if (!FDSROM) {
			FreeFDSMemory();
			return 0;
		}
		memset(FDSROM, 0, FDSROMSize);
		for (x = 0; x < OKUSAN_FDS_MAX_SIDES; x++)
			diskdata[x] = &FDSROM[x * BYTES_PER_SIDE];
		bios_standby = 1;
	} else {
		FCEUFILE *zp;
		char *fn = FCEU_MakeFName(FCEUMKF_FDSROM, 0, 0);

		if (!(zp = FCEU_fopen(fn, NULL, 0))) {
			FCEU_PrintError("FDS BIOS ROM image missing!\n");
			FCEUD_DispMessage(RETRO_LOG_ERROR, 3000, "FDS BIOS image (disksys.rom) missing");
			free(fn);
			FreeFDSMemory();
			return 0;
		}
		free(fn);

		if (FCEU_fread(FDSBIOS, 1, FDSBIOSsize, zp) != FDSBIOSsize) {
			FCEU_fclose(zp);
			FreeFDSMemory();
			FCEU_PrintError("Error reading FDS BIOS ROM image.\n");
			FCEUD_DispMessage(RETRO_LOG_ERROR, 3000, "Error reading FDS BIOS image (disksys.rom)");
			return 0;
		}
		FCEU_fclose(zp);

		SetupCartPRGMapping(0, FDSBIOS, FDSBIOSsize, 0);
		FCEU_fseek(fp, 0, SEEK_SET);
		if (!SubLoad(fp)) {
			FreeFDSMemory();
			return(0);
		}
	}

	diskdatao_buf = (uint8_t*)FCEU_malloc(OKUSAN_FDS_MAX_SIDES * BYTES_PER_SIDE);
	if (!diskdatao_buf) {
		FreeFDSMemory();
		return(0);
	}
	memset(diskdatao_buf, 0, OKUSAN_FDS_MAX_SIDES * BYTES_PER_SIDE);
	for (x = 0; x < OKUSAN_FDS_MAX_SIDES; x++) {
		diskdatao[x] = &diskdatao_buf[x * BYTES_PER_SIDE];
		if (x < TotalSides)
			memcpy(diskdatao[x], diskdata[x], BYTES_PER_SIDE);
	}

	DiskWritten = 1;

	GameInfo->type = GIT_FDS;
	GameInterface = FDSGI;

	SelectDisk = 0;
	InDisk = 255;
	okusan_fds_active = 1;
	okusan_fds_pending_side = -1;
	okusan_fds_delayed_insert_frames = 0;
	okusan_fds_rw_decay = 0;
	okusan_fds_seek_seq = 0;
	okusan_fds_latch_seq = 0;
	okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;

	ResetExState(PreSave, PostSave);
	FDSSoundStateAdd();

	AddExState(&TotalSides, 4, 1, "TSID");
	for (x = 0; x < OKUSAN_FDS_MAX_SIDES; x++) {
		char temp[5];
		sprintf(temp, "DDT%d", x);
		AddExState(diskdata[x], 65500, 0, temp);
	}

	AddExState(&FDSRegs[0], 1, 0, "REG1");
	AddExState(&FDSRegs[1], 1, 0, "REG2");
	AddExState(&FDSRegs[2], 1, 0, "REG3");
	AddExState(&FDSRegs[3], 1, 0, "REG4");
	AddExState(&FDSRegs[4], 1, 0, "REG5");
	AddExState(&FDSRegs[5], 1, 0, "REG6");
	AddExState(&IRQCount, 4, 1, "IRQC");
	AddExState(&IRQLatch, 4, 1, "IQL1");
	AddExState(&IRQa, 1, 0, "IRQA");
	AddExState(&writeskip, 1, 0, "WSKI");
	AddExState(&DiskPtr, 4, 1, "DPTR");
	AddExState(&DiskSeekIRQ, 4, 1, "DSIR");
	AddExState(&SelectDisk, 1, 0, "SELD");
	AddExState(&InDisk, 1, 0, "INDI");
	AddExState(&DiskWritten, 1, 0, "DSKW");

	AddExState(&mapperFDS_control, 1, 0, "CTRG");
	AddExState(&mapperFDS_filesize, 2, 1, "FLSZ");
	AddExState(&mapperFDS_block, 1, 0, "BLCK");
	AddExState(&mapperFDS_blockstart, 2, 1, "BLKS");
	AddExState(&mapperFDS_blocklen, 2, 1, "BLKL");
	AddExState(&mapperFDS_diskaddr, 2, 1, "DADR");
	AddExState(&mapperFDS_diskaccess, 1, 0, "DACC");

	CHRRAMSize = 8192;
	CHRRAM = (uint8_t*)FCEU_gmalloc(CHRRAMSize);
	if (!CHRRAM)
		return 0;
	SetupCartCHRMapping(0, CHRRAM, CHRRAMSize, 1);
	AddExState(CHRRAM, CHRRAMSize, 0, "CHRR");

	FDSRAMSize = 32768;
	FDSRAM = (uint8_t*)FCEU_gmalloc(FDSRAMSize);
	if (!FDSRAM)
		return 0;
	SetupCartPRGMapping(1, FDSRAM, FDSRAMSize, 1);
	AddExState(FDSRAM, FDSRAMSize, 0, "FDSR");

	SetupCartMirroring(0, 0, 0);

	if (bios_standby) {
		FCEU_printf(" FDS BIOS     : standby (no disk inserted)\n");
	} else {
		FCEU_printf(" Code         : %02x\n", diskdata[0][0xf]);
		FCEU_printf(" Manufacturer : %s\n", getManufacturer(diskdata[0][0xf]));
		FCEU_printf(" # of Sides   : %d\n", TotalSides);
		FCEU_printf(" ROM MD5      : 0x%s\n", md5_asciistr(GameInfo->MD5));
	}

	FCEUI_SetVidSystem(0);

	return 1;
}

void FDSClose(void) {
	okusan_fds_active = 0;
	okusan_fds_pending_side = -1;
	okusan_fds_delayed_insert_frames = 0;
	okusan_fds_rw_decay = 0;
	okusan_fds_seek_seq = 0;
	okusan_fds_latch_seq = 0;
	okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;
	TotalSides = 0;
	InDisk = 255;
	SelectDisk = 0;

	FreeFDSMemory();
}

__attribute__((visibility("default")))
void okusan_fds_tick_frame(void) {
	if (!okusan_fds_active) {
		okusan_fds_rw_decay = 0;
		return;
	}

	if (okusan_fds_delayed_insert_frames > 0) {
		okusan_fds_delayed_insert_frames--;
		if (okusan_fds_delayed_insert_frames == 0 && okusan_fds_pending_side >= 0) {
			if ((uint32_t)okusan_fds_pending_side < TotalSides) {
				InDisk = (uint8_t)okusan_fds_pending_side;
				SelectDisk = InDisk;
				mapperFDS_block = DSK_INIT;
				mapperFDS_blockstart = 0;
				mapperFDS_blocklen = 0;
				mapperFDS_diskaddr = 0;
				okusan_fds_latch_seq++;
			}
			okusan_fds_pending_side = -1;
		}
	}

	if (okusan_fds_fault_mode != OKUSAN_FDS_FAULT_NONE) {
		int motor_on = (InDisk != 255) && ((mapperFDS_control & 0x01) != 0);
		if (motor_on && okusan_fds_fault_motor_frames < 1000) {
			okusan_fds_fault_motor_frames++;
		}
	}

	if (okusan_fds_rw_decay > 0) {
		okusan_fds_rw_decay--;
	}
}

__attribute__((visibility("default")))
int okusan_fds_is_active(void) {
	return okusan_fds_active;
}

__attribute__((visibility("default")))
void okusan_fds_get_status(int *out_inserted_side, int *out_total_sides,
                           int *out_motor_on, int *out_rw_activity,
                           uint32_t *out_seek_seq, uint32_t *out_latch_seq,
                           int *out_fault_mode) {
	int inserted = (okusan_fds_active && InDisk != 255 && InDisk < TotalSides) ? (int)InDisk : -1;
	int motor = (okusan_fds_active && inserted >= 0 && (mapperFDS_control & 0x01) != 0) ? 1 : 0;
	if (out_inserted_side) *out_inserted_side = inserted;
	if (out_total_sides)   *out_total_sides   = okusan_fds_active ? (int)TotalSides : 0;
	if (out_motor_on)      *out_motor_on      = motor;
	if (out_rw_activity)   *out_rw_activity   = (okusan_fds_active && okusan_fds_rw_decay > 0) ? 1 : 0;
	if (out_seek_seq)      *out_seek_seq      = okusan_fds_seek_seq;
	if (out_latch_seq)     *out_latch_seq     = okusan_fds_latch_seq;
	if (out_fault_mode)    *out_fault_mode    = okusan_fds_fault_mode;
}

__attribute__((visibility("default")))
int okusan_fds_hot_swap_disk(const uint8_t *data, uint32_t size) {
	uint32_t sides = 0;
	uint32_t offset = 0;
	uint32_t x;
	int was_inserted;

	if (!okusan_fds_active || !data || size < 16 || !FDSROM || !diskdatao_buf)
		return 0;

	if (memcmp(data, "FDS\x1a", 4) == 0) {
		sides = data[4];
		offset = 16;
	} else if (memcmp(data + 1, "*NINTENDO-HVC*", 14) == 0) {
		sides = (size < BYTES_PER_SIDE) ? 1 : (size / BYTES_PER_SIDE);
		offset = 0;
	} else {
		return 0;
	}

	if (sides < 1) sides = 1;
	if (sides > OKUSAN_FDS_MAX_SIDES) sides = OKUSAN_FDS_MAX_SIDES;

	memset(FDSROM, 0, OKUSAN_FDS_MAX_SIDES * BYTES_PER_SIDE);
	memset(diskdatao_buf, 0, OKUSAN_FDS_MAX_SIDES * BYTES_PER_SIDE);

	for (x = 0; x < sides; x++) {
		uint32_t src_off = offset + x * BYTES_PER_SIDE;
		if (src_off < size) {
			uint32_t avail = size - src_off;
			if (avail > BYTES_PER_SIDE) avail = BYTES_PER_SIDE;
			memcpy(diskdata[x], data + src_off, avail);
			memcpy(diskdatao[x], diskdata[x], BYTES_PER_SIDE);
		}
	}

	okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;
	okusan_fds_pending_side = -1;
	okusan_fds_delayed_insert_frames = 0;

	was_inserted = (InDisk != 255);
	TotalSides = sides;
	SelectDisk = 0;
	mapperFDS_block = DSK_INIT;
	mapperFDS_blockstart = 0;
	mapperFDS_blocklen = 0;
	mapperFDS_diskaddr = 0;

	if (was_inserted) {
		/* Brief physical swap gap so BIOS/game sees card removal before new card arrives */
		InDisk = 255;
		okusan_fds_pending_side = 0;
		okusan_fds_delayed_insert_frames = 34;
	} else {
		InDisk = 0;
	}
	okusan_fds_latch_seq++;
	return (int)TotalSides;
}

__attribute__((visibility("default")))
void okusan_fds_eject_disk(void) {
	if (!okusan_fds_active) return;
	okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;
	okusan_fds_pending_side = -1;
	okusan_fds_delayed_insert_frames = 0;
	if (InDisk != 255) {
		InDisk = 255;
		okusan_fds_latch_seq++;
	}
}

__attribute__((visibility("default")))
void okusan_fds_set_side(int side) {
	if (!okusan_fds_active || TotalSides == 0) return;
	if (side < 0) side = 0;
	if ((uint32_t)side >= TotalSides) side = (int)TotalSides - 1;

	okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;
	SelectDisk = (uint8_t)side;

	if (InDisk != 255) {
		InDisk = 255;
		okusan_fds_pending_side = side;
		okusan_fds_delayed_insert_frames = 34;
		okusan_fds_latch_seq++;
	} else {
		okusan_fds_pending_side = -1;
		okusan_fds_delayed_insert_frames = 0;
		InDisk = (uint8_t)side;
		mapperFDS_block = DSK_INIT;
		mapperFDS_blockstart = 0;
		mapperFDS_blocklen = 0;
		mapperFDS_diskaddr = 0;
		okusan_fds_latch_seq++;
	}
}

__attribute__((visibility("default")))
void okusan_fds_clear_fault(void) {
	okusan_fds_fault_mode = OKUSAN_FDS_FAULT_NONE;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;
}

__attribute__((visibility("default")))
int okusan_fds_trigger_random_fault(uint32_t rng_seed) {
	int target_side;
	uint32_t mixed;
	int mode;

	if (!okusan_fds_active || TotalSides == 0)
		return 0;

	target_side = (InDisk != 255 && InDisk < TotalSides)
	              ? (int)InDisk
	              : (SelectDisk < TotalSides ? (int)SelectDisk : 0);

	okusan_fds_fault_rng_ctr += 0x9E3779B9u;
	mixed = rng_seed ^ okusan_fds_fault_rng_ctr;
	mixed ^= mixed >> 16;
	mixed *= 0x7FEB352Du;
	mixed ^= mixed >> 15;
	mixed *= 0x846CA68Bu;
	mixed ^= mixed >> 16;

	/* Cycle across all 9 real read-time FDS hardware/BIOS faults (ERR. 01..28) */
	mode = 1 + (int)(mixed % 9u);

	okusan_fds_fault_mode = mode;
	okusan_fds_fault_motor_frames = 0;
	okusan_fds_err01_tripped = 0;
	InDisk = 255;
	okusan_fds_pending_side = target_side;
	okusan_fds_delayed_insert_frames = 20;
	okusan_fds_latch_seq++;
	return mode;
}

__attribute__((visibility("default")))
uint8_t *okusan_fds_get_side_ptr(int side, const uint8_t **out_orig_ptr) {
	if (!okusan_fds_active || side < 0 || (uint32_t)side >= TotalSides)
		return NULL;
	if (out_orig_ptr) *out_orig_ptr = diskdatao[side];
	return diskdata[side];
}
