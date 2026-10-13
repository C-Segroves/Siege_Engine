# Audio & video formats

Tools: `tools/audio.py` (PCM→WAV, HMP→MIDI, SNC→JSON, sound/voice tables), `tools/wav_pcm.py` (every sound the
Tribes / Tribes 2 / Starsiege exporters copy is written as PCM: Tribes 2 ships most WAVs as IMA ADPCM, format 0x11,
decoded to 16-bit PCM and trimmed to the `fact` length; any other codec fails the import) and `tools/video.py`
(DFL+RAW→OGV/PNG, ANM→PNG). Both have `all <outdir>` CLIs.

Confidence: **[C]** confirmed from code/disassembly and verified on data, **[H]** high (consistent
across all files), **[M]** medium (plausible inference), **[L]** guess.

---

## 1. Digital audio: `*.SFX`, `*.RAW`

Headerless **unsigned 8-bit mono PCM, 11025 Hz** [C].

- DBSIM: SoundManager driver init struct defaults at VA `0x959ec..0x95a0c`:
  buffer 4096, **rate 0x2b11 = 11025**, MIDI driver `0xa002` (FM) @ port 0x388, digi driver
  `0xe000` (Sound Blaster) @ 0x220 IRQ 7 DMA 1. GO.EXE and PLAYFLIC also contain 11025 and
  PLAYFLIC converts ms→sound bytes with `ms*0x2b11/1000`.
- Extension decides type (`0x4f4e8`): `.hmp` → MIDI object (`0x504da`), `.sfx`/`.raw` → digital
  object (`0x507c7`). `.sfx` and `.raw` are the same format (e.g. `VEHIC1R.SFX` == `VEHIC1R.RAW`).
- Start-sample (`0x509c4`) builds an HMI `_SOS_START_SAMPLE`: volume = vol%·0x7fff·master/10000,
  optional pitch (16.16, clamped ≥0x8000, set by `0x50884` – used for engine pitch), optional loop
  count / loop point / loop length (default whole sample). No per-file loop points exist.

Locations: `SIMSOUND/HMI/*.SFX` (sim effects), `SIMVOICE/SIMVOICE/Pn_mmvvv.SFX` (wingman radio),
`SPEECH/SNC/*.RAW` (shell briefing speech), `SHELL0/RES32/*.SFX|*.RAW` (shell UI sounds:
menu door open/close, hammer/ratchet = mech lab, vehicles), `original/SSET/SOUNDSET.RAW` (sound
test). 378 files → WAV; durations 0.06–8.2 s.

### Sim sound table `SIMVOL0/STR/SOUNDS.STR` [C structure, M field names]
Generic Dynamix STR: `u32 dataSize, u16 count, count × {u16 len, char str[len], u8 n, u8 extra[n]}`.
Loaded by DBSIM `0x4dc70` ("sounds","str"); index = sound ID. For sounds `n=4`:

| byte | meaning (from loader `0x4dcf5`) |
|---|---|
| 0 | loop count → `obj->vtbl+0x28(-1,-1,count)`; 0 = once, 255 = forever, 5 = warning woop ×5 |
| 1 | volume 0–100 → `vtbl+0x2c` |
| 2 | if non-zero: preload/lock sample at load (`0x501ec`) [M] |
| 3 | passed to object create, stored at obj+0x34 (positional/3D flag?) [L] |

IDs 0–9 are music: 0 battle1a, 1 battle2a, 2 battle3a, 3 battle1b, 4 battle2b, 5 battle3b,
6–9 = battle1a (unused aliases). 10–46 are SFX (`tools/audio.py` writes `tables/sim_sounds.json`).

### Battle music selection (DBSIM `0x585dc`) [H, engagement test M]
On mission start a random theme 0..2 is picked (`call 0x63b3c(rng, 3)`) = the **"A" (calm)** variant, at
volume 100. State: `0x96d0c` song id, `0x96d0e` combat flag, `0x96d18` switch pending, `0x96d10` the clock time
before which no scan runs. The scan runs **every frame**, except for **300 clock units after the mission start
and after every switch** (`0x96d10` = now + 0x12c is written only there: `0x5866f`, `0x5883a`, `0x58912`).
* Calm -> combat: an enemy that is targeted/visible (`0x2d624`, `0x2d71c`) or closer than **25000 units**
  (`0x5880b`; distance `0x6325a` = max + weighted rest) switches to the **"B" (combat)** variant (id +3). While in
  combat such an enemy makes the function return at once (`0x5881b`).
* Combat -> calm (`0x5888f`): with no engaged enemy, every live Herc of the unit list `0xaf72c` (both sides, the
  list `0x15b9f` counts per team; dead ones skipped by `+0x9e` / `+0x93`) is measured; one **farther than 18928
  units** (`0x588ef`) keeps the combat theme, otherwise A returns (id -3). In practice the calm theme comes back
  once the enemies are down and the squad is near.
* Clock (`0x981c4`): the 120 Hz timer callback `0x63e3c` (PIT divisor `0x26d3` set at `0x5a9f7`, registered at
  `0x63e90`) counts `0x981c8` every tick and `0x981c4` every second tick, so **300 units = 5 s** [M].

A switch fades the playing song by **-15 volume per frame** (`0x586a0`) and then starts the other variant **from
its beginning at full volume** (`0x58713`, no fade-in). Remake: `games/es1/battle/battle_music.gd`
(`HOLD_SECONDS`, `is_engaged`, `is_all_close`).

### Pilot radio `SIMVOL0/STR/PILOT{1,2,4}.STR` [H]
Same STR layout, `n=7`: `extra = [message, variant, 0, 3, 6, 1, 20]` (last 5 constant, unknown).
Entry text is the subtitle; audio is `SIMVOICE/P{pilot}_{message:02d}{variant:03d}.SFX`
(all 45 entries per pilot resolve; P1 has 5 additional unreferenced files).
`PILOTS.STR` = pilot names. Output: `tables/pilot{n}_voice.json`.

**Remake use: wingman chatter on the radio channel** (`WingmanRadio`, `game/engine/crew/wingman_radio.gd`,
`RadioTable`). The host's mission runtime (`MissionRuntime.start_wingman_radio`, the career squad from
`ES1SquadSpawner`) listens to the wingmen and speaks a random variant of a message through `Battle.radio(wingman
name, text, "es1:sim/p<n>_<mm><vvv>")`: the chat's radio channel shows it when the clip starts (`RadioVoice`).
Wingman k (spawn order) uses table `PILOT{1,2,4}[k mod 3]`. The original trigger code is not traced, so which
event says which message is an approximation [L], chosen by what the lines mean:

| message | when (remake) |
|---|---|
| 1 | a wingman acquires a hostile target after having none (one call per squad every 20 s) |
| 2 | a wingman destroys a hostile unit |
| 3 | a wingman's integrity falls under 35 % (once per mission) |
| 4 or 9 (random) | a wingman is destroyed |
| 5 | the human player destroys a hostile unit (a random living wingman says it) |
| 6 | the mission is won (a random living wingman) |
| 8 | the human player hits a wingman |
| 7, 10-34, 35-42 | unused: retreat, order acknowledgements and radar answers need the wingman order menu the remake lacks |

A wingman stays quiet for 6 s after a line (except his last words), so the radio never floods. Earthsiege has no
other in-mission speaker lines: MSN texts are briefing / debriefing only, and "Nav point reached" and the end
texts stay on the system channel.

## 2. Lip sync: `SHELL0/SNC/*.SNC` [C timing, M tag meaning]

```
u16 nbytes                     // = filesize-2
{ u16 tag; u16 ticks; } [nbytes/4]
```
`ticks` are **1/60 s**: Σticks × 183.75 = RAW sample count for 158/161 files (11025/60 = 183.75).
`tag` 1..24 selects a mouth shape: the companion `<char>_SYNC.TTM` (SHELL0/RES32) is a Dynamix
TTM 4.14 script with one scene per tag, each `DRAW_SPRITE(x,y,frame,slot)` from `<char>_SYNC.DBA`
(C0_SYNC.DBA / D0_SYNC.DBA) at the portrait's mouth position. Speech audio is
`SPEECH/SNC/<same name>.RAW`. `C0_FILES.DAT`… are whitespace-separated preload lists
(TTM, SNC, RAW per character set: C0–C3 commanders, D0–D3, G0, T0/T1; referenced by GO.EXE as
`SNC\C0_FILES.DAT` etc.). Output: `voice/shell_sync/*.json` with start/dur in seconds.
Known data quirks: T1_01003.SNC has no RAW; T1_08001 sync is 2 s longer than its audio.

## 3. Music: `*.HMP` (HMI MIDI "HMIMIDIP", old format) [C]

```
0x00 "HMIMIDIP" + zero pad
0x20 u32 offset of the branch table (= file length - its size; 0 in some Battledrome files)
0x30 u32 nTracks
0x34 u32 division (ticks per quarter note; Earthsiege 120, Battledrome / SOUNDSET 192)
0x38 u32 tempo = ticks per SECOND (Earthsiege 120, Battledrome 60)
0x3c u32 song length in seconds (matches computed length)
0x40 u32 channelPriority[16]
0x80 track/device map (32 × 5 u32; device ids 0xa000/0xa002…)  [M]
0x308 tracks: { u32 trackNo, u32 chunkLen (incl. 12-byte header), u32 midiChannel, data[] }
```
Track data = standard MIDI events with running status, but delta times use HMI's reversed VLQ:
7-bit groups **least significant first**, the **last** byte has bit 7 set (`0x80` = 0).
Meta events `FF tt len …`; track 0 is an empty conductor track. The bytes after the last track are the
branch table (below).

HMI controllers (values may exceed 127): the SOS sequencer (DBSIM `0x7f4b8`, jump table `0xa79a0`) consumes
108-121, everything else reaches the driver [C]:

| cc | meaning |
|---|---|
| 102 | **pitch-bend range in semitones**, handled by the FM driver (`fmmidi.com 0x187e`, default 2). Earthsiege DEATH uses 8; Battledrome ROCK2/3, SNDTRAK1, TITLE use 12. |
| 108 v | branch point marker on every track (no action itself) |
| 109 v | loop setup: copies the following cc110's count into branch point v |
| 110 n | loop start (n = count, 255 = forever) |
| 111 / 112 v | loop end: unless the count runs out, **every track jumps** to its branch point v (the event after its 108/110 marker), its clock restarts there and its saved program + controllers are re-sent; **no note-off is sent** (`0x7f6f2`) |

**Branch table** (header `0x20` = its file offset) [C]: `u8 count[nTracks]`, then per branch point 24 bytes
`{u32 offset (+0xc from the track chunk start = the event after the marker), u8 id, u8 program, u8 0, u8 nCtlBytes,
u32 file offset of (controller, value) pairs, u32 same, 8 x 0}`. Earthsiege songs: one point (id 128) per track at
tick 0/1. Battledrome songs have no branch table (10-21 zero bytes) and no loop controllers.

**Device map** [C]: HMP `0x80` holds 5 device ids per track. SOS (`0x6e874`) tries a track's slots in order against
the loaded drivers (`0xA000` also matches 0xA001/0xA008, `0xA002` also matches 0xA009 = OPL3); first match wins,
an unmatched track is silent. The games load the configured MIDI driver plus **0xA005** (digital MIDI, `0x4f2c4`),
so `0xA005` tracks play DRUM32.DIG samples on the Sound Blaster DSP; with an AdLib (no DSP) they are silent.
`0xA000` = Sound Master II, `0xA003` = callback track (no notes). Events of one timer tick (header `0x38` = ticks
per second: Earthsiege 120, Battledrome 60) are sent in track order, then file order. Channel remapping is off
(`0x7225a(0)`). **cc7 is scaled** by song x master volume (`0x7163f`, both 0x7f).

### The FM driver: `SOS/HMIMDRV.386` -> `fmmidi.com` (0xA002, "HMI MIDI Driver For OPL2") [C]
`HMIMDRV.386`: `u32 count`, then per driver `{u32, u32 0x2c, u32 checksum, name "x.com", ..., +0x2c u32 total,
+0x30 u32 code size, +0x34 u32 device id, +0x3c code}`. Both games' setup offers only **"FM: a002"**
(`STUFF/SOUNDSET.INI`); `fmmidi3.com` (0xA009, OPL3) is never used, so a Sound Blaster 16 ran its OPL3 in OPL2
mode (mono). Addresses are in the Earthsiege build (code at file offset 0x5c); the Battledrome build is identical
apart from the modulator rule below. Emulation: `tools/hmi_fm.py` (tables are read from the user's file).

* **Dispatch** `0x80c`: note on (vel > 0) `0xf4c`; note off / vel 0 `0x143c`; controller `0x174a` (7 volume,
  64 sustain, 102 bend range, 121 reset, 123 all notes off; **cc10 pan, cc1 and cc11 are ignored**); program
  `0x16fd` (stored only); pitch bend `0x18bf` (**MSB only**; the drum channel ignores bends).
* **Voices** `0x1dde`: the lowest free voice (a key-off frees it, even while it releases); else the lowest voice of
  the **lowest-numbered MIDI channel that has never received a pitch bend**; else voice = note (-9 once), out of
  range for notes >= 18 (the emulation drops such notes; Earthsiege DEATH, DESERT and LOSING hit this).
* **Note on**: key off the voice, write release rate 15 to both operators 5 times ("damp"), load the patch
  (`0x1f25`: modulator 20/40/60/80/E0, C0 = packed fb*2|con used **raw**, carrier 20/60/80/E0; the carrier level is
  only shadowed), then the carrier level from velocity: `v = vel * (cc7*128/127) >> 7`, `a = curve[v/2]`
  (64-byte table, 63..0), **TL = 64 - (64 - a)(64 - patchTL)/64** (amplitudes multiply). The modulator gets the
  same treatment when (Earthsiege) the patch's packed C0 byte is 0, computed with the *carrier's* TL, or
  (Battledrome) when the patch is additive, with its own TL (for drums Battledrome tests the melodic patch of
  program[9]). Frequency: `u32 table[note]` (MIDI 12 = C0, block*1024 + fnum); A0, B0 without key, B0 with key;
  then the channel's bend. Drums (channel 9): the DRUM.BNK patch of the note at the pitch in its name entry byte 2.
* **cc7** re-levels the channel's sounding voices with their stored velocity. cc121 resets volume 127, bend centre,
  range 2, sustain off. **cc123 also resets the channel volume to 127.**
* **Sustain**: any non-zero value holds note-offs (up to 32 per channel), released newest first on pedal up.
* **Pitch bend** `0x1981`: `f = table[n]`, step to `table[n +- range]`,
  `f +- step * ((|bend - 64| * 1000) >> 6) / 1000`; a step that leaves the block (> 0x2cf) uses the wrap tables.
* **Banks**: `0x0d21` packs the first `used - 2` (126) records in place; programs index records directly.
  Layout (`SOS/MELODIC.BNK`, `DRUM.BNK`, 5404 B, AdLib BNK) [C]: 28-byte header `{u8 ver[2], "ADLIB-", u16 used,
  u16 count, u32 nameOfs, u32 dataOfs}`, 128 x 12-byte names `{u16 index, u8 flag, char name[9]}`, 128 x 30-byte
  records `{u8 perc, u8 voice, mod[13], car[13], u8 modWave, u8 carWave}` with operator fields ksl, mult, fb, ar,
  sl, eg, dr, rr, tl, am, vib, ksr, con. `mod.con` is the raw C0 connection bit (0 FM, 1 additive); in DRUM.BNK the
  name entry's flag byte is the note the drum sounds at.

MIDI conversion (`tools/audio.py mid`): MIDI format 1, division from the header, tempo `division/tps` s per quarter,
HMI controllers 102-119 removed, loop points as `FF 06 "loopStart"/"loopEnd"` markers.

### The digital drum driver (0xA005, in the SOS library) [C]
`DBSIM 0x81789`: note on -> sample = DRUM32.DIG[note]; volume `(driverVol * vel >> 7) << 8`; 8 voices
(`0x4f254`); at the limit the oldest sample of the same channel stops. Every DRUM32.DIG sample has flags
`0xffff8000` (+0x24): note-offs and re-triggers are ignored, samples always play out. **cc7 sets one volume for
the whole driver**; cc10 one pan. No pitch. DIG file: `HMIDIGIP`, a 0x28-byte header, then per sample a 0x74-byte
SOS start-sample image (+0x08 length, +0x18 note, +0x24 flags) and u8 PCM at 11025 Hz. Emulation: `tools/hmi_digi.py`.

### Rendering (`tools/render_music.py all es1|bd`)
One pyopl (DOSBox OPL) chip per song, shared by all channels. Variants: **sb** (OPL3 in OPL2 mode, 16-bit, plus the
DSP drums mixed at equal full scale) and **adlib** (YM3812 with the YM3014 DAC's 10-bit-mantissa quantisation, FM
tracks only). Mono, 15 Hz DC block, one fixed gain (0.55) for every song so relative loudness is kept.
Output: `gamedata/<pack>/audio/music/<sb|adlib>/<track>.ogg` + `music.json` (loop points, policy, voice statistics,
situations, PCM hashes). A looping song's file is its first pass plus one loop pass (`loop_start`/`loop_end`). The
wrap is sample-exact where the chip state repeats (MENU, ICE, SHELLB, INTRO2, VOLCANO ...) and level-matched (within
2 dB, 10 ms envelopes) where the free-running LFO or starved voices make passes differ. Battledrome songs play
once (arena) or restart (shell S1-S3). `render_music.py check` and `spectrogram` report levels and draw pictures.

Shell music (GO.EXE) [C]. Sound table `0x828c0` ids: 1/2 menu, 3 shella, 4 shellb, 5 shellc, 6 shella, 7 death,
8 win2, 12 intro1, 13 intro2, 15 rubble, 16 ice, 17 desert, 18 volcano, 19 losing.
* Region change `0x395a0`: table `0x817d0` = 1,1,3,4,3,3,1, so **1000/2000 menu, 3000 war room shella, 4000 hangar
  shellb, 5000 debriefing shella, 6000 briefing map shella, 7000 monitor menu**. The song restarts only when it changes.
* General's (G0) transmission `0x37f1e`: id 15 + `0x814d8[campaign]` (0,1,1,2,2,3,3,3) = rubble / ice / desert / volcano.
* Start-up `0x3bdef`: intro1 under DYNAMIX + LEAD_IN, intro2 from IINTRO (+ EARTH_W).
* Return from a career mission (`0x3ba93`, mode 1), instead of the debriefing: the pilot record's status
  (`0x1618d`, crew record +0xf) 0 = **pilot killed** `0x3bc94`: death + `endfa.ttm`; else the campaign status
  (`0x15aa5`) 99 = **won** `0x3bce6`: intro2 + `end_win1..3.ttm` + `intro\earth.ttm`; -1 = **lost** `0x3bd30`:
  losing + `failed.ttm` + `intro\earth.ttm`. Each then returns to the main menu (`0x3b3db`). Remake:
  `ShellMissions.make_career_ending`, `ShellSequences.play_career_ending` (won / lost: the career is marked over
  and let go). The battle reports `pilot_killed` when the player's Herc was destroyed (`Battle.is_player_killed`);
  a killed pilot plays death + ENDFA (`ShellSequences.play_pilot_killed`) but **does not end the career** any
  more: it goes back to its restore point and MENU1250 offers REPLAY (campaign_availability.md §9). The app's
  killed-in-action prompt plays the same death song for Earthsiege (`MenuMusic.play_pilot_killed`), the other
  games their menu music.
* **shellc and win2 are never played** (no code path uses ids 5, 6 or 8).

Battledrome: SIM.EXE table `0x78998`, music ids 15-23; Preferences MUSIC TYPE -> `0x78af4` (first, count): ROCK (15,3),
TECHNO (18,3), SOUNDTRACK (21,3), VARIETY (15,9), and NONE (4: no music, `0x5e5`); `0x28486` plays a random track of the
set, never the previous one, once. **Default VARIETY**: the SoundManager constructor sets 3 (`0x27deb`) and the shipped
STORAGE.DAT holds music type 3 [M]. Remake: Options > Audio "Battledrome arena music" (`MusicLibrary.arena_set`). SHELL.EXE `0x7ccb0`: 0 TITLE, 1-3 S1/S2/S3 (identical files), restarted whenever it is not playing. BATTLE,
FOOTFALL, SHELL2 and TECHNO4 are unreferenced.

### CD-audio and streamed music of the later games
`tools/music_situations.py` reads each game's own scripts into `<pack>/audio/music_situations.json`;
the engine plays them through `engine/cd_music.gd` (CD tracks from the user's rips) [C unless noted]:
* **Starsiege**: missions call `cdAudioCycle(...)` (campaign onMissionStart, multiplayer onMissionLoad,
  training 5, 6). Each track plays once, then the next; the list repeats. Tracks outside 2..13 are dropped
  (CDAudio::cycle `0x55a69c`), so the script's SS1 = 14 is never heard (the soundtrack import's 14->11 alias is a
  repair, not original behaviour). Changes fade the CD out (+0.05 attenuation per 0.1 s, `0x55a930`), no cross-fade.
  Shell: SHELL1.WAV looped (sound.cs). No combat/death/victory music.
* **Tribes**: main menu CD track 2 looped (GUI.CS); missions set `$cdTrack` / `$cdPlayMode` (1 loop, else once;
  TheRedSands uses 8 = once); hard cuts.
* **Tribes 2**: `base/music/<musicTrack>.mp3` from the mission, looped, hard cuts; silent shell and training; credits
  a random one of the five. The five files are album tracks 2-5 and 7 (album 1 and 6 are album-only) [H].
* **Earthsiege 2**: shell HMI\SHELL2.WAV while prefs byte 5 (`0x4824bd`) is 0 (default), else SHELL1.WAV, looped by
  VSHELL (`0x42ed97`). No menu sets that byte: every shell start toggles it and saves the prefs (`0x42ee1b`:
  `0x40d87d(5)`, `0x40d752`), so SHELL2 and SHELL1 **alternate per shell start** (VSHELL runs again after every
  sim). Remake: `CdMusic.play_menu` (a new start = the menu music begins while neither song plays; the choice is
  kept in the settings as `es2_shell_music`). Sim CD track
  (launch counter mod 5) + 2 looped = 2, 3, 4, 5, 6, 2 ... per sim launch (DBSIM `0x461c86`, ES.EXE `-R<n>`); training
  is silent; CD track 7 is never played [H].

### Menu music of the app's own screens (`engine/menu_music.gd`) [remake]
The app's screens play the menu music of the game the player is in: a campaign's briefing / debriefing (and the
hangar between them) and the end screen, the saga's Starsiege choice, a LAN lobby (its map's game; a co-op
campaign: the host's campaign). Earthsiege 2 SHELL2 / SHELL1, Starsiege SHELL1, Tribes CD track 2, Battledrome's
shell song S1; **Tribes 2 is silent** (its LaunchGui never starts music: `MusicPlayer` plays only missions and
credits, server.cs:194 stops it on disconnect). Earthsiege plays its shell's song for the same place (briefing
map 6000 / debriefing 5000: shella; else the main menu's menu) and at a campaign's end intro2 (won) / losing (lost);
the other games had no ending music, so their menu music plays. The **library home and the launcher main menu
belong to no game and are silent** (remake decision). The jukebox is left alone; the original ES1 shell keeps its
own region music. A battle fades the menu music out (1 s) before its own starts.

## 4. Video: `FLIC/*.DFL` + `*.RAW` (PLAYFLIC.EXE)

PLAYFLIC = Jim Kent's READFLIC + Dynamix extensions; X-32VM image, **VA = file offset − 0x47F2**.
Launched by `ESCD.EXE` as `playflic.exe flic\intro3.dfl -S83` / `flic\end.dfl -S83`.

Container = standard **Autodesk FLC** (magic 0xAF12, 128-byte header, frame chunks 0xF1FA) [C]:
INTRO3 1074 frames, END 397 frames, 320×200×8. Header speed (71 ms) is overridden by **-S83**.
Chunk dispatcher `0x31d0` (jump table at 0x15d94, types 4..24):

| type | handler | meaning |
|---|---|---|
| 4 | 0x2d00 | COLOR_256 (8-bit RGB, written >>2 to the DAC) |
| 7/11/12/13/15/16 | std | FLC SS2 / COLOR_64 / LC / BLACK / BRUN / COPY (only 13 used) |
| 18 | – | PSTAMP thumbnail (ignored) |
| **20** | 0x2c1c→0x3e19 | **Dynamix LZ delta** (all image data) |
| **21** | 0x23ec | SOUND: `u32 kind (0 digi .raw, 1 midi), u32 soundId, char name[13]` |
| **22** | 0x286c | PALETTE FADE: `u32 dir, u32 mode, u32 n, u32 rgb444` |
| 23 | 0x2b64 | (unused here) |
| **24** | 0x213c | SYNC: `u32 mode (13 CLOCK, 14 SOUND), u32 enable, u32 soundId, i32 adjustMs` |

**Chunk 20 (DTA_LZ)** [C, verified visually]: `u32 nOps`, then ops; low 3 bits of the first byte =
opcode, operating on the screen buffer in place (dst starts at top-left, pitch 320):
```
0: u16 w        skip w>>3 pixels
1: u16 w        copy w>>3 literal bytes that follow
2: s8 a, u8 n   copy n bytes from dst + (a>>3)
3: u8 a, s8 o   copy a>>3 bytes from dst + o
4: s8 a, u8 n   copy n bytes from dst + (a>>3) - pitch   (row above)
5: s8 a, u8 n   copy n bytes from dst + (a>>3) + pitch   (row below = previous frame)
6: s16 a, u16 n copy n bytes from dst + (a>>3)
7: u16 a, s16 o copy a>>3 bytes from dst + o
```
Copies are `rep movsw` + `movsb` (overlapping back-references replicate like LZ77).
**Chunk 22 fade**: dir 6 = fade in from colour, 7 = fade out to colour; mode 8 = immediate
blocking loop of n palette writes (no waits → effectively instant), mode 9 = spread over the next
n frames (step applied before each frame decode: pal = target + (colour−target)·k/n, k = remaining
(in) or elapsed (out)). INTRO: `6/9 n=32000` holds black, `6/8 300` = fade in, `7/8` = cut to black.
**Sync** [C]: the SOUND sync sets base = audio position + adjustMs·11025/1000; frame k is shown when
the audio byte position reaches base + k·(83·11025/1000 = 915). INTRO adjust 150 ms → 0.15 + 1074·0.083
= 89.29 s vs 89.31 s audio; END adjust 1450 ms → 34.4 s video, 36.3 s audio (tail silence).

**RAW** = 8-bit unsigned mono 11025 Hz [C]. `INTROB3.RAW` 89.3 s, `END.RAW` 36.3 s.

Converter output: `flic/intro3.ogv`, `end.ogv` (Theora 640×400 yuv420p 24 fps CFR + Vorbis,
frame 0 held for adjustMs, last frame held to the audio end; ffmpeg from `pip install imageio-ffmpeg`),
plus `.wav`, `.json` timing, and optional `--png` frame dumps.

## 5. `SHELL0/ANM/*.ANM` and `SHELL0/INTRO/*`

- `ESIEGE2.ANM` (7 frames), `ESIEGE3.ANM` (8 frames): **Electronic Arts Deluxe Paint Animation**
  (`LPF `/`ANIM`, 320×200, 15 fps) [C]. They are the main-menu "blast door" closing/opening
  animation (EARTHSIEGE logo panels; pure green = keyed/transparent area showing the menu
  behind). Played by GO.EXE (`anm\esiege2.anm`, `anm\esiege3.anm`) with `MENUCLS*.RAW` /
  `MENUOPN2.RAW` sounds. ffmpeg decodes them natively; `video.py anm` dumps PNGs.
- `SHELL0/INTRO/*`: the in-shell intro/credits slideshow — Dynamix TTM 4.14 scripts
  (`VER:`/`PAG:`/`TT3:` (RLE-compressed bytecode)/`TTI:`/`TAG:`), full-screen DBM backgrounds
  (`IA..IM.DBM` 320×200 in DBM container, loaded as `*.SCR`), credit-name DBAs
  (PRODUCER/PROGRMM/ARTISTS/…), palettes (`*.DPL`) [H]. TTM opcodes seen: `0x1051` select bmp slot,
  `0xF02F` load bitmap, `0xF01F` load screen, `0xF05F` load palette, `0xF04F` load font,
  `0x0FF0` update/next scene, `0xA504` draw sprite(x,y,frame,slot), `0x1021` delay (ticks),
  `0x4124` fade, `0xA104`/`0x4204` rect ops [M]. The music for it is `INTRO1/INTRO2.HMP` [L].

## Unknowns
- SOUNDS.STR byte 3 and PILOT extra bytes 3–7 semantics.
- Battle music: the meaning of the unit flags `+0x9e` / `+0x93` and of `[obj+0x3f]+0x14 == 1` in the scans (taken
  as "destroyed" / "an enemy Herc"); whether a 60 Hz fallback timer (`0x697ea`) can ever be the clock's source.
- The DSP mixing latency of digital drums (SOS starts samples in its DMA blocks) is not modelled.
- Blocking (mode 8) fades are rendered instantly; on real hardware they took a fraction of a second.
