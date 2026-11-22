# HVC-001 60-Pin Cartridge Contact Model Specification

**English** | [日本語 (Japanese)](60pin-hardware-notes.md)

Technical notes on the physical dimensions, 3-DOF rigid-body mechanics, contact electrical behavior, CPU/PPU/audio bus hooks, and live connector HUD implemented in [Okusan Famicom CRT](../README.md).

---

## 1. HVC-001 Physical Connector Dimensions (`okusan_cart.h`)

Defined in [`third_party/fceumm/src/okusan_cart.h`](../third_party/fceumm/src/okusan_cart.h#L21-L34):

| Constant | Value | Meaning |
| --- | --- | --- |
| `OKUSAN_CART_PIN_COUNT` | `60` | Total edge pins (Front 1–30, Back 31–60) |
| `OKUSAN_PIN_PITCH_UM` | `2540 µm` (`2.54 mm`) | Standard 0.1-inch pin pitch |
| `OKUSAN_CARD_HALF_UM` | `39000 µm` | Cartridge PCB edge half-width (`78.00 mm` total width) |
| `OKUSAN_CARD_THICK_UM` | `1600 µm` (`1.60 mm`) | FR4 PCB thickness |
| `OKUSAN_PAD_WIDTH_UM` | `1550 µm` (`1.55 mm`) | Gold finger width (`0.99 mm` insulating comb gap) |
| `OKUSAN_PAD_BOT_UM` .. `TOP` | `1000..7500 µm` | Chamfered pad offset (`6.50 mm` active pad height) |
| `OKUSAN_WIPER_WIDTH_UM` | `1100 µm` (`1.10 mm`) | Phosphor-bronze spring wiper width inside the blue slot |
| `OKUSAN_WIPER_BOT_UM` .. `TOP` | `2500..4200 µm` | Console spring contact crown (`1.70 × 1.10 = 1.87 mm²` max area) |
| `OKUSAN_SOCKET_DEPTH_UM` | `10000 µm` (`10.00 mm`) | Blue plastic socket depth |
| `OKUSAN_SLOT_PLAY_UM` | `±350 µm` (`±0.35 mm`) | Side-guide lateral clearance |
| `OKUSAN_BRIDGE_THRESHOLD_UM` | `1215 µm` (`1.215 mm`) | Minimum lateral shear required for direct copper-to-copper short |

> **Why adjacent pins do not copper-short on pure tilt**  
> Combined geometric tilt shear and slot clearance peaks at **`604 µm` (~`0.60 mm`)**, well below the blue comb barrier / copper short threshold (`1215 µm`). Instead, neighboring-pin interference (`XTALK`) arises electrically via capacitive coupling / leakage onto floating High-Z lines.

---

## 2. 3-DOF Pose & Contact Area Model (`okusan_cart.c`)

### 2.1 Pose Degrees of Freedom
- **`tilt` (`-32 .. +32`)** — `<` / `>`: Lateral rock. Negative lifts the left (PRG/CPU) edge; positive lifts the right (PPU/CHR) edge.
- **`lift` (`0 .. +16`)** — `Shift + <` / `Shift + >`: Uniform vertical pull-up (`330 µm` per step, up to `5.28 mm`).
- **`pitch` (`-8 .. +8`)** — `[` / `]`: Front-to-back rock inside the socket, shifting spring normal preload between Front (1–30) and Back (31–60) faces.
- **Reseat (`0, 0, 0`)** — `/` (`?`): Snaps the cartridge back to fully seated and clears any explicit per-pin fault masks.
- **Randomized Fault Cold Boot & Power OFF (`@`)** — Acts as Power OFF when ON; when OFF, uses [`okusan_set_pin_fault_masks`](../third_party/fceumm/src/okusan_cart.c#L347-L351) plus optional 3-DOF pose skew to randomize faulted pin positions and counts across all 60 pins (`0..59`) *before* power-on (profile-free; US ANSI & Japanese JIS key layouts supported).

### 2.2 Per-Pin Overlap Calculation
1. **Longitudinal coordinate `x_um`** ([`pin_longitudinal_x_um`](../third_party/fceumm/src/okusan_cart.c#L65-L68)): `((pos * 2) - 29) * 1270 µm` (`pos = 0..29`).
2. **Rigid-body vertical rise `rise_um`** ([`okusan_cart_edge_rise_um`](../third_party/fceumm/src/okusan_cart.c#L301-L311), [`pin_rise_3dof_um`](../third_party/fceumm/src/okusan_cart.c#L70-L79)):
   $$\text{rise}_{\text{edge}}(x) = 330 \cdot \text{lift} + \frac{|\text{tilt}| \cdot 185 \cdot \text{dist}(x)}{2 \cdot 39000}$$
   $$\text{rise}_{\text{pin}} = \max\!\left(0,\ \text{rise}_{\text{edge}}(x) + \begin{cases} -45 \cdot \text{pitch} & (\text{Front } 1..30) \\ +45 \cdot \text{pitch} & (\text{Back } 31..60) \end{cases}\right)$$
3. **Vertical overlap `ov_v`** (after per-pin manufacturing wear/tolerance `okusan_pins60_spec[i].wear_um ∈ [-200, +180] µm`):
   $$[\text{pad\_bot}, \text{pad\_top}] = [1000 + \text{rise}_{\text{pin}} + \text{wear},\ 7500 + \text{rise}_{\text{pin}} + \text{wear}] \cap [2500, 4200]$$
4. **Lateral overlap width `lat_ov_w`** ([`okusan_cart_lat_shift_um`](../third_party/fceumm/src/okusan_cart.c#L314-L324)):
   $$\text{lat\_shift} = \frac{|\text{tilt}| \cdot 185 \cdot \max(800, 3350 - \text{lift}\cdot 165)}{2 \cdot 39000} + \frac{|\text{tilt}| \cdot 350}{32}$$
   $$\text{lat\_ov\_w} = \text{clamp}\!\left(1325 - \text{lat\_shift},\ 0,\ 1100\right)\ \text{µm}$$
5. **Front/back spring preload `preload_um`**:
   $$\text{preload} = 450 + \begin{cases} +68 \cdot \text{pitch} & (\text{Front } 1..30) \\ -68 \cdot \text{pitch} & (\text{Back } 31..60) \end{cases}$$
   At `pitch >= +7`, all Back pins (31–60) lose spring normal force while Front pins (1–30) remain seated.
6. **Effective overlap length `overlap_um` (`0..1700 µm`)**:
   $$\text{overlap} = \frac{\text{ov\_v} \cdot \text{lat\_ov\_w}}{1100} \cdot \frac{\text{clamp}(\text{preload}, 0, 450)}{450}$$
   Effective contact area is $\text{overlap} \times 1.10 / 1000\ [\text{mm}^2]$ (`1.87 mm²` max).

---

## 3. Contact States, Power Brownout & Crosstalk

### 3.1 Four Electrical States
Boundary micro-drift ([`okusan_frame_drift`](../third_party/fceumm/src/okusan_cart.h#L112-L116)) updates only at `okusan_cart_rt.frame_tick >> 7` (~2.1 s period) so corrupted screens remain stable just like real hardware instead of flickering artificially at 60 Hz.

| State | `overlap_um` Range | Contact `R_c` | Electrical Behavior |
| --- | --- | --- | --- |
| `0: Seated` | `>= 960 µm` | `0.2 Ω` | Solid contact (rare edge slip only under low Vcc or single-GND bounce) |
| `1: Weak` | `420..959 µm` | `0.2..4.2 Ω` | Asymmetric RC pull-up slew delay (`0→1` drags behind `1→0` pull-down) |
| `2: Marginal` | `70..419 µm` | `8.0..48.0 Ω` | Oxide point contact: holds/crosstalks neighbors with slow intermittent opens |
| `3: Open` | `< 70 µm` | `10 kΩ` (open) | High-Z floating: couples to active adjacent same-face lines (`XTALK`) or returns open-bus |

### 3.2 Ohm's-Law Power Rail & Brownout
- Parallel resistances $R_g = R(\text{GND1}) \parallel R(\text{GND2})$ and $R_v = R(\text{+5V R}) \parallel R(\text{+5V L})$ under ~110 mA cartridge draw yield $V_{cc} = \max(0,\ 5000 - 110(R_g + R_v))\ [\text{mV}]$.
- **`Vcc < 3.40 V` (`3400 mV`)**: Cartridge power collapses; CPU/PPU buses read open-bus and an RF television outputs **unmodulated snow static**.
- **`3.40 V <= Vcc < 4.35 V`**: Mask-ROM brownout access-delay zone.
- **Asymmetric GND bounce**: Lifting only `GND1` (PRG side) or `GND2` (PPU side) raises noise primarily on that half of the connector.

### 3.3 Same-Face Capacitive Crosstalk (`XTALK`)
When any signal pin (`OKUSAN_PCLS_SIG`) is not `Seated`, if its left or right neighbor on the same PCB face is neither `Open` nor `GND`, `OKUSAN_PIN_FLAG_XTALK_L` (`0x10`) / `OKUSAN_PIN_FLAG_XTALK_R` (`0x20`) is flagged, coupling that neighbor's logic level and rendering cyan links on the HUD.

---

## 4. CPU, PPU & Audio Bus Integration (`okusan_cart.c` / `ppu.c` / `x6502.c` / `pputile.h`)

- **CPU Bus (`$4020-$FFFF`, `x6502.c` + `okusan_cart.c`)**: [`okusan_cpu_read_cart`](../third_party/fceumm/src/x6502.c#L87-L103), [`WrMemNorm`](../third_party/fceumm/src/x6502.c#L109-L123), and [`X6502_DMW`](../third_party/fceumm/src/x6502.c#L148-L158) route `CPU A0..A14`, `D0..D7`, `R/W`, `M2`, and `/ROMSEL` (`$8000+`). Floating `/ROMSEL` feeds `X.DB` open-bus until 6502 hits an illegal opcode (`X.jammed`); recover via Reseat (`/`) + Reset (`R`).
- **Per-Pin Explicit Fault Masks (`okusan_set_pin_fault_masks`)**: Pins in `open_mask` drop to `0 µm / OPEN` and pins in `weak_mask` clamp to `700 + wear_um` (`440..940 µm / WEAK`), enabling dirty-pin faults independently or combined with 3-DOF tilt/lift/pitch. Sparse transition chatter on light/medium CPU `WEAK` contacts (~1 in 2048 edges) yields realistic mid-boot glitches/crashes after the reset vector.
- **External `/IRQ` (Pin 15)**: [`okusan_map_irq`](../third_party/fceumm/src/okusan_cart.c#L542) gates external mapper IRQs (`FCEU_IQEXT | FCEU_IQEXT2`) independently of console-internal Reset / NMI / APU interrupts.
- **PPU Pattern, Nametable & `$2007`**:
  - `CHR` reads model 2C02 multiplexed open-bus `vadr & 0xFF` when `PPU /RD` or `PPU A13` opens, while [`okusan_map_ppu_data_bus`](../third_party/fceumm/src/ppu.c#L268) pulls open individual `PPU D0..D7` pins to steady `1` (CMOS/NMOS pull-up) to produce authentic **8px-periodic vertical jailbars**.
  - `CIRAM` reads ([`okusan_read_nt_byte`](../third_party/fceumm/src/ppu.c#L203)) return open-bus `off & 0xFF` for both tile IDs and attributes if `CIRAM /CE` or `PPU /A13` fails (including `WEAK`/`MARGINAL`), and honor `CIRAM A10` mirroring faults.
  - `$2007` writes ([`B2007`](../third_party/fceumm/src/ppu.c#L543)) check `PPU /WR`, `CIRAM /CE`, `PPU /A13`, and `PPU A13` independently.
  - **Persistent CIRAM latch on `?` reseat ([`okusan_reseat_cart_contact`](../third_party/fceumm/src/okusan_cart.c#L354-L378) → [`okusan_ppu_on_reseat_latch`](../third_party/fceumm/src/ppu.c#L321))**: Normal angle adjustments leave internal 2 KB `NTARAM` clean, whereas snapping back with `/` (`?`) from a powered faulted pose stamps a one-shot spurious write into `NTARAM` so corrupted background tiles stay visible on screen until overwritten by scrolling, screen transitions, or Reset (`R`).
- **Cartridge Audio Loop (Pins 45/46 `SND IN/OUT`)**: Modulates [`MacAudioEngine.mm`](../src/audio/MacAudioEngine.mm) pass-through gain ([`okusan_get_audio_contact_q`](../third_party/fceumm/src/okusan_cart.c#L414)).

---

## 5. Interactive 60-Pin Connector HUD (`CartConnectorHud.mm`)

Implemented in [`src/hud/CartConnectorHud.hpp`](../src/hud/CartConnectorHud.hpp) and [`src/hud/CartConnectorHud.mm`](../src/hud/CartConnectorHud.mm).

- Renders at `1280×740` (2× HiDPI `640×370` logical canvas), auto-fading after 1.35 s or pinned continuously with `\` or clicking the HUD.
- Shows live `1:1 mm` PCB insertion cutaway, average contact area (`%` and `mm²`), max gap, lateral shift, `Vcc`, pitch attitude, and `[W/M/O/X]` counts.
- Clicking any pin tile in the `Front 1–30` / `Back 31–60` matrix locks the bottom inspector to that pin's role, overlap area, lift/gap, live HIGH duty bar, transition activity, fault rate, and latest `$orig -> $eff` bus word.
