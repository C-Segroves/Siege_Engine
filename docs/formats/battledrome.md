# Metaltech: Battledrome (Dynamix / Sierra, 1995) — formats and content

Tools: `tools/bd_unchunk.py` (install archive → `bd/installed/`), `tools/export_bd.py`
(→ `gamedata/bd/`, same layout/schema as `tools/export_es1.py` → `gamedata/es1/`).
Game version strings: SIM.EXE "Release 1.3.2 Nov 18 1994 11:05:23", SHELL.EXE same date 13:07.

## 1. Disc layout

Only `INSTALL/ENGLISH/` belongs to Battledrome. `AOD/`, `SIM/`, `ESDEMO/`, `INN/`, `SOUND/`, `SCRNS/`,
`DS/` are demos/ads for other Sierra games. **`INTRO/INTRO.DFL` + `INTRO.RAW` is the *Aces of the Deep*
intro** (U-boat, destroyer, "Aces of the Deep" logo; 320x160, 1166 frames, standard Dynamix DFL — decodes with
`tools/video.py` except that frame 399 ends with a skip past the buffer end, which `dta_lz` reports as
an overrun; wrapping the call with a padded buffer fixes it). Battledrome's own animations are
`DATA/DYNAMIX.DDA` and `DATA/LASER.DDA` (see §6).

`INSTALL.SCR` copies `RESOURCE.000` + `UNCHUNK.EXE` to the target dir and runs
`unchunk RESOURCE.000 .`; exit codes 1..6 = read error / write error / out of memory (needs 550 KB) /
bad resource file / cannot open source / cannot open target.

## 2. RESOURCE.000 / UNCHUNK.EXE

UNCHUNK.EXE is a Borland C++ (1991) 16-bit program packed with LZEXE 0.91 ("LZ91" at 0x1C).
After unpacking (standard LZ91 bit-stream: 16-bit LSB-first flag words, refilled immediately when
exhausted) the main loop is at image 0x2D6B and the chunk library at segment 0x31E.

Container — a flat sequence of chunks, no directory:

```
char tag[4]      "OPN:" = start a new file ("wb"), "CNT:" = continue previous file ("a+b")
u32  size        payload bytes
payload:
  u8   method    0 stored, 1/2 other codecs (unused), 3 = LZHUF
  u32  unpacked size
  compressed data
unpacked stream: NUL-terminated relative path (e.g. "DTS\THOR.DCS"; dirs created by
                 splitting on '\'), followed by the file bytes.
```

Method table at DS:0x16A (14-byte entries: buffer size, read/write work-memory size, near fn ptrs
read=+6, write=+8, init=+10/+12). Method 3's decoder (seg 0x31E:0x160C → image 0x47EC) is
**Okumura/Yoshizaki LZHUF (1988)**: LZSS with N=4096 ring (initialised to spaces up to N−F),
F=60, THRESHOLD=2; adaptive Huffman tree over 314 symbols (256 literals + 58 lengths, T=627,
reconstruct at freq[R]=0x8000); match position = 6 high bits via the static d_code/d_len tables
(at DS:0x249/0x349, identical to LZHUF.C) + low bits read MSB-first; bit stream MSB-first.
`length = sym − 253`, `src = (r − pos − 1) & 4095`.

RESOURCE.000: 237 chunks, all `OPN:` + method 3; 2,540,712 → 8,301,864 bytes. Python decode ≈14 s.

## 3. Installed file catalogue (`bd/installed/`, 237 files)

| where | contents |
|---|---|
| root | `BD.EXE` (launcher, swaps SHELL/SIM), `SHELL.EXE` (menus, ladder, negotiation, hangar), `SIM.EXE` (3D combat), `SOUNDSET.EXE`/`SOUNDPLY.EXE`/`GRAVBD.EXE`/`LOADPATS.EXE` (HMI sound setup), `PATCHES.INI`, `SOUNDSET.INI`, `BD.ADV` (Thrustmaster WCS II map), `STORAGE.DAT` (shell↔sim hand-off, cf. ES1 script.dat) |
| `DTS/` | sim shapes: 10 Herc `.DCS`, obstacles `OBS{0,1,2}{A,B,C,D}.DCS` (+ leftover source `OBS0B.DCD`), `TURRET.DCS`/`TURHLK.DCS` (blaster turret / wreck), `PAD.DTS` (start pad), `REFEREE.DTS`, `CAM.DTS` (camera probe), projectiles (`BULLET`, `BLASTER`, `CANON`, `MISSILE`, `MINE`, `BLAMMO`), effects (`EXPLD1/2`, `SHIELD1`, `SHLDHIT2`, `RDLASER`, `LSRHIT`, `BLASTHIT`, `SHROOM`, `PLASMBAL` — each a DTS + same-named DBA), debris (`DEBRIS1A-D`, `NORMAL1-4`, `PART1-4`), textures `LIGHT/MEDIUM/HEAVY.DBA` (56 each), `OBS.DBA` (32), palettes `NRMPAL/GAMPAL/BRTPAL/DEATHPAL/TEXTURES/ERRPAL.DPL`, arenas `ARENA1-5.DOA`, `HUD.DAT`, `MSGTEXT.BIN`, `WINNER.DBA`, `ERRSCRN.DBA`, `SIMTEST.CRS` |
| `DATA/` | shell: ~60 window bitmaps `W*.DBA`, `PALETTE.DPL`, fonts `ACTIVE/DISPLAY.DFN`, cursors `.CRS`, low-poly hangar Hercs `S<HERC>.DCS` + `S_LIGHT/S_MEDIUM/S_HEAVY.DBA` (48 each), `WATEXT.BIN` (UI strings), `DYNAMIX.DDA`, `LASER.DDA`, `WCHAT.BMP` (Dynamix chunked BMP:/INF:), ladder/net state `NETDATA.DAT`/`NETBAK.DAT`/`LOGGEDIN.DAT`/`PLDATA.DAT`/`OPPONENT.DAT`/`SETUP.DAT` |
| `SOUND/` | 31 `.RAW` + 6 `.SFX` (both headerless unsigned 8-bit mono PCM, as ES1 .RAW), 17 `.HMP` music (HMI; `tools/audio.py hmp_to_mid` works unchanged), HMI drivers `.386`, `DRUM/MELODIC.BNK`, `.DIG` |

No VOLN archives exist — Battledrome loads loose files by path (`dts\thor.dcs`).

Sounds: `AREAN*.RAW` = arena announcer and referee voice, `SHER*.RAW` = **the Herc's own warning voice** (cockpit
messages such as SHIELDS LOW; not the referee), `ENDRND1` end of round, weapon/impact/footfall effects; when each
plays: section 8 "Voices". Music (rendered and selected as decoded in audio_video.md §3) sets selectable in Preferences: ROCK 'N ROLL
(`ROCK1-3`), TECHNO (`TECHNO1-3`), SOUNDTRACK (`SNDTRAK1-3`), VARIETY (all nine, the default), NONE; shell `TITLE`, `S1-3`
(identical). `TECHNO4`, `SHELL2`, `BATTLE`, `FOOTFALL` are not referenced by the executables.

## 4. Executables

All three EXEs use the same FlashTek X-32VM loader as Earthsiege. **SIM.EXE: VA = file offset −
0x69CD** (found by matching `code\*.cpp` assert strings to `push imm32`; ES1 DBSIM is −0x48FD).
`tools/exe.py` works if `IMAGES['SIM'] = ('bd/installed/SIM.EXE', 0x69cd)` is added at runtime.
Key functions: `ArenaData::loadFile` 0x2AC74, `ArenaData::loadShapes` 0x2B093,
`ArenaData::createObj` 0x2B280, `ArenaPalette::loadFile` 0x2C18C.

## 5. Shapes and textures — differences from Earthsiege

* `.DTS` files: same 3Space v2 objects as ES1 (`shape`/`an_shape`, part lists, BSP parts, groups,
  polys, `an_anim_list`). `tools/dts.py` parses every BD DTS with zero unconsumed bytes.
* **New `.DCS` "DCShape" container** (class 0x2BC):
  ```
  (0x1F8,0x2BC) size
    (0x1F5,0x2BC) collision table:
       u8 nDetail, u8 nTubes,
       nDetail x {s16 a, s16 b, u8 tubeCount, u16 firstTube, u8 c}   a/b/c tentative
       nTubes  x {i32 x1,y1,z1, x2,y2,z2, radius}   capsules in shape units
       nDetail x u8 enabled                          (parses exactly for all 34 DCS files)
    [pad to even] one 3Space shape object ((8,0x14) shape or (3,0x1E) an_shape) — dts.py unchanged
    trailer: i32 sphereCenter[3], i32 sphereRadius, i32 (5000), then u32 counts/tables:
       compiled logical-part / cell-anim / mat-anim data (Hercs start with 22 logical parts:
       TORSO, TURRET, LEFT/RIGHT LEG, POD 1-4, MINE POD, MISSILE P1/P2, ENGINE, SHIELD,
       POWER PLANT, PROBE LINK, COMPUTER ... — not fully decoded)
  ```
  `DTS/OBS0B.DCD` is the leftover text source of one DCS ("Part ID 0 Offset (0,0,0)",
  "Detail Part 0 ID 0 On", six "Tube r (p0) (p1)" lines, empty CellAnim/MatAnim).
* **LODs**: ES1 Hercs are several top-level shapes (LOD0 = most detailed). BD Hercs are one
  `an_shape` whose root is a `detail_part` with 6 `bsp_part` children stored **low → high detail**
  (thresholds 7,12,18,25,50,255). `export_bd.py` splits them and reverses to the ES1 order;
  `export_es1.flatten_lod` would otherwise pick the lowest LOD.
* Size: BD Hercs are ~2× ES1 scale (radius ≈ 3000–3500 vs ES1 Raptor 1742; Thor ≈ 4500 tall).
* Cell-anim parts: states 0/1/2 = intact / damaged / destroyed stub (as ES1). The pod cells (anim
  slots 0–3 = POD 1–4) have **13 states = pod animation, not weapon type**: 0 idle, 1–4 firing frames,
  +6 damaged, 12 destroyed (SIM 0x7904; `bd_weapons.md` §6). Pods are baked into the Herc shape.
* Animation: 7 sequences per Herc (tick values 1200, 3, 2000, 6000, 4000, 700, 800), 13 nodes with
  relations like ES1 (node 0 ground tracker, 1 hips, 4/11/12 torso chain).
* Texture sets: Hercs `LIGHT/MEDIUM/HEAVY.DBA` (indices 0–55; 48–55 = pod/weapon panels), obstacles,
  turret and pad `OBS.DBA`. Shell `S*.DCS` use `S_*.DBA` (48 entries, some 8×1 placeholders) but
  SPHANTOM/SSLAYER/STHOR/SVNDICTR reference indices 48–55 (weapon panels missing from S_ sets —
  use the sim set for those). DBA/DBM/DPL formats are identical to ES1 (`tools/gfx.py` unchanged).
* Palettes: sim uses `NRMPAL` (normal), `GAMPAL` (F8 gamma toggle), `DEATHPAL` (death fade),
  `TEXTURES.DPL` (texture shade lists). DPL shade-list trailer = ES1 world-palette layout
  (`world.read_dpl_full` works). `SIMTEST.DPL` (type 2) has a different trailer; the DOA palette field
  (`simtest.dpl`) is read but ignored. Shell uses `DATA/PALETTE.DPL`.

## 6. Arenas (`DTS/ARENAn.DOA`)

```
u32 nShapes, u32 nObjects, i32 8200 (ceiling height?), i32 radius, char palette[20]
nShapes x char name[13]
nObjects x 38 bytes: u32 type (0 obstacle, 1 blaster turret, 2 start pad), u32 shape,
   i32 x,y,z, u16 rx,ry,rz (65536=360°), u32 junk, u32 side (0/1), u32 level
```
Loader rules (SIM 0x2AC74): obstacles are created if `level <= obstacle setting` (NONE..MANY =
0..3), turrets if `level <= blaster-turret setting` (turret shapes TURRET/TURHLK, `side` = owner),
start pads are collected per side and one is chosen. Obstacles at z=8200 with rx=0x8000
hang upside-down from the ceiling. Names `obs?X.dcs` are re-lettered `dts\obs%d%s` with a random
style 0–2 per match (OBS0*/OBS1*/OBS2* = same geometry/collision, different texture mapping).

| file | size option | radius | objects (pads/obst/turrets) |
|---|---|---|---|
| ARENA1.DOA | MINI | 65 000 | 23 (8 / 11 / 4) |
| ARENA2.DOA | SMALL | 80 000 | 25 (8 / 11 / 6) |
| ARENA3.DOA | MED | 100 000 | 29 (8 / 15 / 6) |
| ARENA4.DOA | LARGE | 150 000 | 26 (2 / 18 / 6) |
| ARENA5.DOA | HUGE | 200 000 | 39 (8 / 25 / 6) |

(start pads are 4 per side, except LARGE with 1 per side.)

All use shapes obs0a/b/c/d.dcs + pad.dts. There is no arena shell geometry, sky bitmap or ground
texture: the floor / ceiling / boundary are drawn procedurally (colours not yet located).
Lighting option BRIGHT/DIM/DARK ("LOW VISIBILITY" in README) is a light-intensity setting.

## 7. Hercs (SIM.EXE table, 0x364-byte records at file 0x899C9 + 0x364·k)

| # | name | shape | texture | price | tier | fwd speed? | mass? |
|---|---|---|---|---|---|---|---|
| 0 | Stryder | STRYDER.DCS / SSTRYDER | LIGHT | 50 000 | 0 | 17000 | 1000 |
| 9 | Hammer | THOR.DCS | HEAVY | 350 000 | 4 | 6000 | 3500 |

(Example rows; 10 Hercs in all. The importer writes the full table to `gameplay/hercs.json`, `tools/export_bd.py`.)

Record: 63 stat words, shape/shell-shape/texture paths, component list, name[12], price, tier.
Fields marked `?` in `gameplay/hercs.json` are pattern guesses. Five weapon mounts per Herc
(bay types LIGHT/MEDIUM/HEAVY BAY, MINE LNCHR, MSL LNCHR).

Weapons (0x7C-byte records at SIM 0x80BE4, raw dump `gameplay/weapons.json`): LASER 1–7, BLASTER 1–4,
PLASMA 1–3, CANON 1–5 (autocannon), mine launchers GATOR, BLOODHND, PITBULL (class 5) and missile launchers
MOSQUITO, HORNET, CHARLIE, EAGLE (class 4), two ammo variants each. Components: shields SG I–VI, reactors
1.2–5.2 TW, ARMOR1–12, engines 250 DL … 3000 XE; each with per-Herc compatibility flags and price.
**Fully decoded in `docs/formats/bd_weapons.md`** (`tools/export_bd_weapons.py` → `gameplay/weapons_engine.json`,
`gameplay/loadouts.json`, `audio/sfx/`). The Herc record's mount table is at +0x68: 7 × {bay, pod cell slot,
muzzle x,y,z} (the `mounts?` guess in hercs.json is misaligned).

## 8. Match rules / multiplayer (README, WATEXT.BIN, MSGTEXT.BIN, SHELL strings)

* Two players only: modem (2400–14400 baud, COM1–4), null-modem DIRECT, or IPX LAN; or single
  player vs. AI pilots on a **ladder** (tiers CADET, GLADIATOR, CENTURION, WARRIOR, WARLORD; ~60 named
  AI opponents in SHELL.EXE). INSTANT ACTION = random Herc quick match. Sim runs in lock-step at the
  slower machine's frame rate; replay/record via event streams.
* Challenge → **negotiation** screen: VICTORY TERMS = PRACTICE (no wager/points/damage kept;
  replaced SURRENDER), MECH 25% DMG, 50%, 75%, CRIPPLED, DESTROYED; arena SIZE MINI…HUGE; LIGHTING
  BRIGHT/DIM/DARK; OBSTACLES and BLASTER TURRETS NONE/FEW/SEVERAL/MANY; allowed weapon classes
  LASERS/AUTOCANNON/BLASTERS/PLASMA/MISSLES/MINES/SHIELDS; each side places a **bet** (purse =
  both bets, "MODIFIED PURSE" after penalties/bonuses). SUBMIT/WITHDRAW/ACCEPT/REJECT.
* A **referee** drone (REFEREE.DTS) polices the fight: "BREAK IT UP", "STEP BACK", teleports
  opponents; penalties ILLEGAL WEAPONS (banned class), STANDING TOO CLOSE, SHOOTING AT REFEREE,
  OUT OF BOUNDS, SHOOTING YOUR OWN TURRET; bonuses ENEMY / NEUTRAL TURRET SHOT. Turrets belong to a
  side (DOA `side`).
* Damage persists between matches: Hercs must be repaired/reloaded in the hangar (REPAIR, SELL,
  BUY, per-component prices), up to 4 camera probes (PRB100–400) can be carried.
* Results: win/loss updates wealth, ladder rank and tier ("YOU MOVED UP!").

### Voices (SIM.EXE; decoder `tools/bd_voices.py` -> `cockpit/voices.json`) [C]
One sim time unit = 4 ms (units.md section 4).
* **Sound table `0x78998`**: 43 x {u32 kind, char *path}; kind 1 effect (ids 0-14, 42 COLLIDE), 0 music (15-23),
  2 voice (24-41). The player `0x2828c` drops a voice while Preferences VOICES (SoundManager +0x10a) is off.
* **End of round** (referee state machine `0x13b74`, jump table `0x767ec`, rescheduled `now + [+0x101]`): when the
  victory terms are met (`0x13fa8`) state 1 runs at once: `0x13c85` ENDRND1 (id 24) and both Hercs frozen (+0x40,
  +0x166); after 0x200 units (2.048 s) `0x13cfd` AREAN01 (25); after 0x200 `0x13d6d` AREAN11 (26) when the winner
  is `[0x954ac]`, else AREAN12 (27); after 0x300 (3.072 s) `0x13dde` ends the sim. `[0x954ac]` is always the
  machine's own Herc (`0x2508`: the second machine of a link swaps the start pads, not the pointers), so AREAN11
  is "you won" on the winner's screen and AREAN12 the loser's. Nothing is said at the start of a round or on a kill.
* **Cockpit messages** (MessageManager::set `0x149b0`, table `0x76830`: 32 x {u32 MSGTEXT line, s32 sound, u8 queued,
  u8 urgent, s32 repeat, s32 last}): a message repeats only `repeat` units after it was last shown (768 = 3.07 s
  for INTERNAL DAMAGE, 2560 = 10.24 s for the rest, 1 for the referee lines); within 0x200 units of the previous
  message a non-urgent one is queued (flag 1; ring of 30 at `0x96f10`, drained by `0x14978` once 0x200 units have
  passed) or dropped; otherwise the text is shown and the voice plays, ducking every other sound to half volume
  (`0x2821c`). SHIELDS LOW and SHIELDS DEPLETED share one repeat timer (`0x14ab8` / `0x14ac4`).
  Voices: SHER05 INTERNAL DAMAGE (armour gone, internal value +0x16c changed: `0x7c92`), SHER04 SHIELDS DEPLETED,
  SHER03 SHIELDS LOW, SHER06 SHIELD GENERATOR / SHER07 MAIN or TURRET ENGINE / SHER08 TARGETTING COMPUTER destroyed
  (logical-part table `0x74eb8`, `0xaf88`), SHER09 STRUCTURAL FAILURE IMMINENT, SHER12 PROBE DESTROYED (`0x4901`),
  SHER10 every weapon destroyed (weapon class -> message 12-17, `0xb04c`); referee (urgent): AREAN13A BREAK IT UP,
  AREAN10 WATCH IT!, AREAN07 FINE ASSESSED, AREAN14 STEP BACK, AREAN4A every PENALTY (27-31; referee code
  `0x12c09`..`0x1452c`). AREAN17A is not referenced. There is no crowd sound in the sim.
* **Shield warning** (`0x8057`, every shield update of a Herc with a HUD while the referee state is 0): level =
  shield * 256 / SG points (`0x808c`, truncated); 1..25 -> SHIELDS DEPLETED, 26..63 -> SHIELDS LOW; 0 (empty or no
  generator) says nothing.
* Shell: `BATDROME.SFX` (SHELL.EXE table `0x7ccb0` slot 8) plays once during the DYNAMIX / LASER .DDA intro
  (`0x37d74`).

Remake: `ArenaAnnouncer` (the end-of-round voices on every peer for its own pilot when a match in a Battledrome arena
ends), `BdCockpitMessages` (shield warnings with the original's repeat / spacing / queue for the local pilot's
Battledrome Herc), `Sfx.play_voice` (a message voice ducks every other sound -- the Sfx "Ducked" bus, music
included -- by 6 dB while it plays), Options > Audio "Battledrome voices" (`AudioSettings.voices_on`, default on as
Preferences VOICES; off keeps the message texts); checked by `game/tests/bd_voices_check.tscn`. Not modelled: the
other cockpit messages (the remake's Battledrome Hercs carry one hull, no logical parts), the referee drone and its
penalties, and BATDROME.SFX (the remake has no Battledrome shell intro: the DDA animation format is not decoded,
section 10).

## 9. Tool compatibility summary

| ES1 tool | BD |
|---|---|
| `vol.py` | not needed (no VOL files) |
| `dts.py` / `dts_mesh.py` | unchanged for DTS and for the shape inside DCS (strip the 0x1F8/0x1F5 wrapper first) |
| `gfx.py` | unchanged (DBA, DBM, DPL, CRS) |
| `world.read_dpl_full` | unchanged for all DPLs except SIMTEST |
| `export_es1.shape_to_json` | unchanged, after LOD split (detail_part low→high) |
| `audio.py` | HMP→MIDI unchanged; RAW/SFX = 8-bit PCM |
| `video.py` | DFL works (AoD intro); DDA not supported |
| `exe.py` | needs base 0x69CD for SIM.EXE |

## 10. Unresolved

* DCS collision record fields a/b/c. The trailer's logical-part table (node + offset; hardpoint i = part 11+i)
  is decoded in `bd_weapons.md` §6; the other trailer arrays (cell / mat anim) are parsed but not interpreted.
* Arena floor/ceiling/boundary rendering colours and the meaning of the DOA 8200 field.
* Exact Herc/weapon/component stat field semantics (`?` fields); HUD.DAT layout.
* DDA animation format (`DYNAMIX.DDA`, `LASER.DDA`, header class 0x0C) and `WCHAT.BMP`.
* Sample rate of BD RAW/SFX assumed 11025 Hz like ES1 (not verified in code).
