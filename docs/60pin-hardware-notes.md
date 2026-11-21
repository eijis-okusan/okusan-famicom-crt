# HVC-001 60ピン物理斜め差し 仕様書

[English](60pin-hardware-notes.en.md) | **日本語 (Japanese)**

[Okusan Famicom CRT](../README.ja.md) におけるファミコン（HVC-001）60ピン・カードエッジコネクタの物理形状、3軸剛体力学、接触電気特性、実機 CPU / PPU / 音声バス連動、およびライブ接点解析 HUD の技術仕様です。

---

## 1. HVC-001 実寸物理パラメータ（`okusan_cart.h`）

定義元：[`third_party/fceumm/src/okusan_cart.h`](../third_party/fceumm/src/okusan_cart.h#L14-L28)

| 定数名 | 実測値 | 意味 |
| --- | --- | --- |
| `OKUSAN_CART_PIN_COUNT` | `60` | 全接点数（表・手前 Front 1–30、裏・奥 Back 31–60） |
| `OKUSAN_PIN_PITCH_UM` | `2540 µm` (`2.54 mm`) | ピン間隔（0.1 inch 規格） |
| `OKUSAN_CARD_HALF_UM` | `39000 µm` | カセット基板エッジ半幅（全幅 `78.00 mm`） |
| `OKUSAN_CARD_THICK_UM` | `1600 µm` (`1.60 mm`) | FR4 基板厚 |
| `OKUSAN_PAD_WIDTH_UM` | `1550 µm` (`1.55 mm`) | 金メッキ端子パッド幅（櫛歯隔壁・空間ギャップ `0.99 mm`） |
| `OKUSAN_PAD_BOT_UM` .. `TOP` | `1000..7500 µm` | 面取り下端オフセット `1.00 mm`〜上端 `7.50 mm`（有効長 `6.50 mm`） |
| `OKUSAN_WIPER_WIDTH_UM` | `1100 µm` (`1.10 mm`) | 青コネクタポケット内のリン青銅バネ接点幅 |
| `OKUSAN_WIPER_BOT_UM` .. `TOP` | `2500..4200 µm` | 本体バネ接点クラウン帯域 `2.50..4.20 mm`（最大面積 `1.70 × 1.10 = 1.87 mm²`） |
| `OKUSAN_SOCKET_DEPTH_UM` | `10000 µm` (`10.00 mm`) | 青プラスチックソケット深さ |
| `OKUSAN_SLOT_PLAY_UM` | `±350 µm` (`±0.35 mm`) | 左右ガイド横遊びクリアランス |
| `OKUSAN_BRIDGE_THRESHOLD_UM` | `1215 µm` (`1.215 mm`) | 隣接銅パッドが金属短絡を起こす最小横ズレ量 |

> **隣接端子ショート（`SHORT`）の物理検証**  
> 傾き角による幾何横ズレと横遊びの合計最大値は **`604 µm`（約 `0.60 mm`）** であり、青ソケット内の櫛歯プラスチック隔壁および銅間短絡閾値 **`1215 µm`** を超えないため、**正常なコネクタでの純粋な斜め差しによる隣ピン金属短絡は発生しません**。隣接干渉（`XTALK`）は、浮いて High-Z 化した信号ピンへの静電容量結合／リークとして発生します。

---

## 2. 3軸自由度（3-DOF）と接点面積モデル（`ppu.c`）

### 2.1 入力パラメータと操作キー
- **`tilt` (`-32 .. +32`)** — `<` / `>`：左右傾け。負で左端（PRG/CPU 側）浮き、正で右端（PPU/CHR 側）浮き。
- **`lift` (`0 .. +16`)** — `Shift + <` / `Shift + >`：垂直引き抜き量（`1 step = 330 µm`、最大 `5.28 mm`）。
- **`pitch` (`-8 .. +8`)** — `[` / `]`：前後揺らし。負で手前側浮き、正で手前へ倒れて奥側（赤スライダー側）が浮く。
- **差し直し (`0, 0, 0`)** — `/`（`?`）で即座に全 60 ピンを完全挿入状態へ復帰。

### 2.2 各ピンの幾何位置・接触面積算出
1. **長手方向位置 `x_um`**：`((pos * 2) - 29) * 1270 µm`（`pos = 0..29`）。
2. **剛体エッジ浮き `rise_um`**（[`okusan_cart_edge_rise_um`](../third_party/fceumm/src/ppu.c#L344)、[`okusan_cart_pin_rise_um`](../third_party/fceumm/src/ppu.c#L355)）：
   $$\text{rise}_{\text{edge}}(x) = 330 \cdot \text{lift} + \frac{|\text{tilt}| \cdot 185 \cdot \text{dist}(x)}{2 \cdot 39000}$$
   $$\text{rise}_{\text{pin}} = \max\!\left(0,\ \text{rise}_{\text{edge}}(x) + \begin{cases} -45 \cdot \text{pitch} & (\text{Front } 1..30) \\ +45 \cdot \text{pitch} & (\text{Back } 31..60) \end{cases}\right)$$
3. **垂直重なり `ov_v`**（各ピン固有のバネ公差・酸化膜ばらつき `wear_um ∈ [-200, +180] µm` 加算後）：
   $$[\text{pad\_bot}, \text{pad\_top}] = [1000 + \text{rise}_{\text{pin}} + \text{wear},\ 7500 + \text{rise}_{\text{pin}} + \text{wear}] \cap [2500, 4200]$$
4. **横ズレ重なり幅 `lat_ov_w`**（[`okusan_cart_lat_shift_um`](../third_party/fceumm/src/ppu.c#L367)）：
   $$\text{lat\_shift} = \frac{|\text{tilt}| \cdot 185 \cdot \max(800, 3350 - \text{lift}\cdot 165)}{2 \cdot 39000} + \frac{|\text{tilt}| \cdot 350}{32}$$
   $$\text{lat\_ov\_w} = \text{clamp}\!\left(1325 - \text{lat\_shift},\ 0,\ 1100\right)\ \text{µm}$$
   横ズレが `225 µm` までは幅 `100%`（`1100 µm`）、`tilt=32` 時は約 `60.5%` まで減少します。
5. **前後揺らし法線バネ予圧 `preload_um`**：
   $$\text{preload} = 450 + \begin{cases} +68 \cdot \text{pitch} & (\text{Front } 1..30) \\ -68 \cdot \text{pitch} & (\text{Back } 31..60) \end{cases}$$
   `pitch = +7` 以上で裏面 `Back 31..60` のバネ予圧が `0` 以下となり、**表全ピン緑・裏全30ピン OPEN** を再現します。
6. **実効重なり長 `overlap_um`（最大 `1700 µm` 換算）**：
   $$\text{overlap} = \frac{\text{ov\_v} \cdot \text{lat\_ov\_w}}{1100} \cdot \frac{\text{clamp}(\text{preload}, 0, 450)}{450}$$
   実効接触面積は $\text{overlap} \times 1.10 / 1000\ [\text{mm}^2]$（最大 `1.87 mm²`）となります。

---

## 3. 接触 4 状態・電気特性・電源ブラウンアウト

### 3.1 接点状態分類と安定性（60 Hz 点滅抑制）
境界微揺らぎ `okusan_frame_drift` は `okusan_frame_tick >> 7`（**約 2.1 秒周期**）でのみ変化するため、斜め差し中の画面が 60 Hz で不自然に縦流れ・明滅せず、実機同様に**一定箇所が安定して化け、ごく稀にだけ状態が遷移**します。

| 状態コード | `overlap_um` 条件 | 接触抵抗 `R_c` | 電気的挙動 |
| --- | --- | --- | --- |
| `0: OK (SEATED)` | `>= 960 µm`（`920..959` に薄い遷移帯） | `0.2 Ω` | 正常導通（低Vcc・片側GNDバウンス時のみ極稀にエッジ遅れ） |
| `1: WEAK` | `420..959 µm`（`380..419` に遷移帯） | `0.2..4.2 Ω` | **非対称 RC スルーレート遅延**：`0→1` プルアップ側が面積連動で遅延、`1→0` 強プルダウンは通しやすく、端のビット化け・縦筋を発生 |
| `2: MARGINAL` | `70..419 µm`（`40..69` に遷移帯） | `8.0..48.0 Ω` | 面取り先端の酸化膜点接触：隣接クロストークまたは前値保持しつつ約 2.1 秒周期で極稀にオープン欠落 |
| `3: OPEN` | `< 70 µm` | `10 kΩ`（開放） | High-Z 開放：同面隣接駆動ピンがあれば容量結合（`XTALK`）、無ければフローティング／2C02・6502 オープンバス値 |

### 3.2 電源レール（オームの法則・ブラウンアウト）
- **電源ピン**：`PIN_GND1` (Pin 1) // `PIN_GND2` (Pin 16) の並列合成抵抗 $R_g$、および `PIN_VCC_R` (Pin 30) // `PIN_VCC_L` (Pin 31) の並列合成抵抗 $R_v$。
- **降下電圧と遮断**：負荷電流約 `110 mA` として $V_{cc} = \max(0,\ 5000 - 110 \cdot (R_g + R_v)\ [\text{mV}])$。
  - **`Vcc < 3.40 V`（`3400 mV` 未満）**：カセット内部の ROM/Mapper が動作不能（**通電断**）とみなし、PPU/CPU はオープンバス化、テレビ表示は強制的に**無信号モノクロ RF 砂嵐**へ切り替わります。
  - **`3.40 V <= Vcc < 4.35 V`**：マスク ROM アクセスタイム遅延帯（高速信号遷移のエラー率上昇）。
  - **片側 GND 断のグラウンドバウンス**：`GND1`（PRG 側）だけ高抵抗化/開放した場合は CPU バスの、`GND2`（PPU 側）だけ開放した場合は PPU バスのノイズマージンが低下します。

### 3.3 隣接容量・リーククロストーク（`XTALK`）
信号クラス（`PCLS_SIG`）のピンが `SEATED` 以外（`WEAK`/`MARGINAL`/`OPEN`）のとき、同一面（Front 同士または Back 同士）で左右隣接ピンが **`OPEN` かつ `GND` 以外** であれば、`OKUSAN_PIN_FLAG_XTALK_L` (`0x10`) / `OKUSAN_PIN_FLAG_XTALK_R` (`0x20`) が立ち、シアン枠線と接続バーが HUD に表示されます。

---

## 4. 全 60 ピン配列・回路連動仕様（`ppu.c` / `x6502.c` / `pputile.h`）

### 4.1 バス別実機挙動
- **CPU バス (`$4020-$FFFF`, `x6502.c`)**
  - [`okusan_cpu_read_cart`](../third_party/fceumm/src/x6502.c#L87)・[`WrMemNorm`](../third_party/fceumm/src/x6502.c#L109)・[`X6502_DMW`](../third_party/fceumm/src/x6502.c#L148) により、`A0..A14`（Pin 2–13, 33–35）・`D0..D7`（Pin 36–43）・`R/W`（Pin 14）・`M2`（Pin 32）を通過（MMC5 `$5xxx`・WRAM `$6000-$7FFF`・PRG/Mapper `$8000-$FFFF` を網羅）。
  - `$8000` 以上は `/ROMSEL`（Pin 44）断で ROM 非選択となり、CPU データバス容量のオープンバス（`X.DB`）を返して不正オペコード（KIL 等）で実 6502 が停止（`X.jammed`）。リセット (`R`)＋差し直し (`/`) で復帰します。
- **外部 `/IRQ`（Pin 15）**
  - [`okusan_map_irq`](../third_party/fceumm/src/ppu.c#L719) により、本体 2A03 内部の NMI/Reset/APU 割り込みを残したまま外部カートリッジ IRQ（`FCEU_IQEXT | FCEU_IQEXT2`）のみを遮断・トレース。
- **PPU パターン・ネームテーブル・`$2007`**
  - **CHR 読出**：`PPU A0..A13`・`PPU D0..D7`・`PPU /RD`（Pin 17）を通過。`/RD` 断・`PPU A13`（Pin 56）断・通電断時は 2C02 実機 `AD0..AD7` 多重化オープンバス値 **`vadr & 0xFF`**（アドレス数値がそのまま縞模様化する実機特有現象）を返します。
  - **ネームテーブル／属性読出（[`okusan_read_nt_byte`](../third_party/fceumm/src/ppu.c#L779)）**：`CIRAM A10`（Pin 18）でミラーリングを制御し、`CIRAM /CE`（Pin 48）または `PPU /A13`（Pin 49）断時は本体内 2KB VRAM が非選択になるため、タイル ID・属性テーブル双方へオープンバス **`off & 0xFF`** を返します。
  - **`$2007` CHR-RAM / CIRAM 書込（[`B2007`](../third_party/fceumm/src/ppu.c#L1140)）**：`PPU /WR`（Pin 47）と `PPU A13` / `CIRAM /CE` / `PPU /A13` で書込可否を独立判定します。
  - **差し直し（`?` / `/` キー）時の本体 2KB CIRAM（`NTARAM`）残留誤ラッチ（[`okusan_reseat_cart_contact`](../third_party/fceumm/src/ppu.c#L901)）**：`<` / `>` / `[` / `]` 等で斜め位置を変えている間は `NTARAM` を汚さず、**電源 ON（`Vcc >= 3.40 V`）かつ実表示中に `CIRAM` 直接線または 4 本以上の `PPU`/電源ピンが壊れている状態から `?`（`/`）で一気に正常復帰した瞬間だけ**、バス由来パターンの誤書込を `NTARAM` のタイルID／属性へ 1 ショット焼き付けます。これにより「`?` で戻してもその画面の壊れた背景はそのまま残り、スクロール・画面遷移・リセット（`R`）で直る」挙動になります。
- **カセット音声（Pin 45 `SND IN` / Pin 46 `SND OUT`）**
  - 接触度に応じて `okusan_cached_audio_q`（`0..256`）へ変換し、[`MacAudioEngine.mm`](../src/audio/MacAudioEngine.mm) の通過ゲインに反映します。

### 4.2 60 ピン全表（Front 1–30 / Back 31–60）

<details>
<summary>表・手前 Front (Pin 1–30) ＆ 裏・奥 Back (Pin 31–60) 一覧を展開</summary>

| Pin | 面 | 信号名 | `wear_um` | 主な役割・断線/不良時の実機症状 |
| ---: | :---: | :--- | ---: | :--- |
| 1 | Front | `GND` | `-120` | 左端基準電位 (PRG側)。断で電源負荷増＋CPU側グラウンドバウンス |
| 2–13 | Front | `CPU A11..A0` | `-180..+160` | PRG/SRAM/Mapper アドレス。化けると別コード読込・バンクリダイレクト・暴走 |
| 14 | Front | `CPU R/W` | `-60` | 読出(H)/書込(L)切替。断でプルアップされ Mapper/WRAM 書込不能 |
| 15 | Front | `/IRQ` | `+120` | 外部割込 (Mapper→6502)。断で MMC3 等のスキャンライン IRQ 停止 |
| 16 | Front | `GND` | `-80` | 中央基準電位 (PPU側)。断で電源負荷増＋PPU側グラウンドバウンス |
| 17 | Front | `PPU /RD` | `+50` | CHR 読出ストローブ。断で CHR 出力不能→2C02 オープンバス (`vadr & 0xFF`) 縞 |
| 18 | Front | `CIRAM A10` | `-160` | ミラーリング制御。断で単一画面固定化／`PPU A6` 干渉で画面端折り返し化け |
| 19–25 | Front | `PPU A6..A0` | `-190..+150` | タイルID下位 (`A4..A6`)・プレーン (`A3`)・Y行 (`A0..A2`) 崩れ・文字化け |
| 26–29 | Front | `PPU D0..D3` | `-140..+170` | タイル画素右半分ドット欠け・色抜け・縦線ノイズ |
| 30 | Front | `+5V` | `-30` | 右端 VCC 電源。左側 `+5V` と合わせて断で `<3.40V` 通電断砂嵐 |
| 31 | Back | `+5V` | `+90` | 左端 VCC 電源（対称レール） |
| 32 | Back | `M2` | `-130` | 1.79 MHz CPU クロック。断で Mapper/WRAM 書込・同期動作停止 |
| 33–35 | Back | `CPU A12..A14` | `-70..+140` | 上位 ROM アドレス。化けるとバンク全体や命令領域が別箇所へ飛ぶ |
| 36–43 | Back | `CPU D7..D0` | `-170..+180` | CPU 命令/データバス。化けると即座に不正命令で 6502 停止 |
| 44 | Back | `/ROMSEL` | `-140` | `$8000-$FFFF` 選択信号。断で ROM 応答せず 6502 がオープンバス読込→停止 |
| 45–46 | Back | `SND IN/OUT` | `+60 / -100` | カセット拡張音声ループ。接触低下で音量減衰 (`okusan_cached_audio_q`) |
| 47 | Back | `PPU /WR` | `+80` | CHR-RAM / VRAM `$2007` 書込ストローブ。断で書込欠損 |
| 48 | Back | `CIRAM /CE` | `-150` | 本体 2KB VRAM 有効化。断でネームテーブル＋属性がオープンバス (`off & 0xFF`) |
| 49 | Back | `PPU /A13` | `+130` | `$0000-$1FFF` 反転信号。`CIRAM /CE` 断と同等の背景オープンバス化 |
| 50–56 | Back | `PPU A7..A13` | `-190..+150` | タイル上位/BG・SPR バンク (`A12`)/CHR /CS (`A13`)。`A13` 断で全面オープンバス |
| 57–60 | Back | `PPU D7..D4` | `-200..+120` | タイル画素左半分ドット欠け・縦線（`Pin 60 PD4` は最右端 `wear=-200 µm`） |

</details>

---

## 5. 右端 60ピン接点 HUD（`CartConnectorHud.mm`）

実装元：[`src/hud/CartConnectorHud.hpp`](../src/hud/CartConnectorHud.hpp) / [`src/hud/CartConnectorHud.mm`](../src/hud/CartConnectorHud.mm)

- **描画解像度・表示制御**：内部ビットマップ `1280×740`（論理座標 `640×370` を 2× HiDPI 描画）。斜め操作から 1.35 秒間表示し、`\` キーまたはパネルクリックで常時固定表示 (`[LOCK:\]`)。
- **上部ステータス**：3軸姿勢 `T:+20 U:+0 P:+0`、異常バッジ（`[通電断:砂嵐]` / `[CPU停止]`）、左右端浮き量 `[L:+0.00mm R:+3.70mm]`。
- **1:1 mm コネクタ断面図**：`10 mm` 青ソケット・櫛歯隔壁・`2.50..4.20 mm` バネ接点・`78 mm` カセット基板・金パッドと重なり部のライブ視覚化、および平均面積（`%`/`mm²`）・最大隙間・横ズレ・`Vcc`・前後姿勢・`弱/怪/断/隣` ピン数サマリ。
- **60ピンマトリクス ＆ ライブ信号解析ボックス**：
  - 各ピン矩形内の白縦バーが **ライブ High 率（`highDutyPct %`）**、シアン枠と横線が **隣接 XTALK 経路** を表示。
  - 任意のピンをクリックすると下段インスペクタへ固定され、**ピン役割・状態・面積・浮き/隙間・High率・遷移速度 (`MHz高速遷移` / `低速切替` / `固定電位`)・誤読率・直近バス値 `$orig -> 実効 $eff`** をリアルタイム表示します。
