# Earthsiege 2 campaign / mission flow (VSHELL.EXE)

Reverse-engineering report (confidence H/M/L). Addresses are VSHELL.EXE VAs.

## Key globals
- `[0x48260c]` mode: 1 campaign, 0 training/instant action.
- `[0x46fb10]`/`[0x46fb14]` CAREER.DAT records (8 bytes: s16 w0, s16 n, char** names); `[0x46fb18]` career index (0 training, 1..5 = C1..C5); `[0x46fb1a]` mission index.
- `[0x46fb34]` MISSIONS.BIN strings; `[0x48260e]` game state (2 in progress, 1 won, 0 war lost, 3 killed).
- `[0x482af4]` s32 salvage pool (kg; shown /1000 as Tons); `[0x482af8]` s16 mission vars[1000] (saved).
- `[0x482aa1]` campaign difficulty; `[0x479bb8]` training index; `[0x4824dd..e6]` training/instant-action options.

## Campaign order (H)
- CAREER.DAT: s16 count=6; per record {s16 w0, s16 n, s16 MISSIONS.BIN ids[n]}. Record 0 (w0=5, n=11): TRAIN1..8, DEMO, DEMO_01, DEMO_02. Records 1..5 (w0=0..4, n=10): C1_01..C5_10.
- w0 = theater: 0 Alpha, 1 Delta, 2 Omicron, 3 Bravo, 4 Luna (ESTEXT 0x77..0x7b; clips alph_th/delt_th/omic_th/brav_th/luna.avi). Copied to script header word0 in campaign mode.
- MISSIONS.BIN: s32 count, s32 datasize, u16 offs[count], NUL strings ("MSN\C1_01.MSN"). Names come from career[c].names[m].
- New game (0x40e2ed): vars zeroed; mode 1 -> career 1 mission 0; salvage = 100000 + rand(11)*1000.
- Autosave slot 10 every time the shell hands off to the sim; relaunch with reason 3/4 loads it and processes results.
- Advance 0x412dc7(success), campaign only:
  ```
  debrief; m++; if m >= career[c].n: m = 0; c++
  if success and c >= 6: VICTORY
  if not success and (m == 0 or c > 4): WAR LOST
  c==1 and m==3 -> player herc slot := 4;  c==1 and m==6 -> remove hangar herc 8 / unassign pilot
  else continue
  ```
  Failing a normal mission does NOT replay it - the campaign moves on. Must-win: each campaign's last mission (Cx_10) and every C5 (Luna) mission. War lost -> a replay-the-mission prompt (reloads slot 10). Victory -> victory.avi, credits.avi. Player killed -> a replay prompt (no advance), all modes.
- Campaign intro: c<N>.avi then theater clip (C5 also dropship.avi); commander text CAMPAIGN.STR entry N-1 (u32 size, s16 count=5, entries {s16 len, text, s8 k, k bytes}).
- Video clip table at 0x470e74 (86 entries): 0-5 pt1-6, 6-10 rc1-5, 11-17 as1-7, 18-21 es1-4, 22-25 rs1-4, 26-30 sc1-5, 31-34 rd1-4, 35 sp1, 36-39 gd1-4, 40-43 ex1-4, 44-47 rf1-4, 48-51 co1-4, 52-55 fl1-4, 56-59 sk1-4, 60-63 sv1-4, 64-67 hc1-4, 68-69 intr_pt1/2, 70-74 c1-c5, 75-79 theater clips, 80 transm3, 81 end1a, 82 death, 83 victory, 84 credits, 85 dropship. MSN 'values' s8 = clip index (briefing getter 0x4135da, debrief 0x4135e1).
- THEATER.DAT / MAP_INFO.DAT / MAP_LOCS.DAT / TRN_HERC.DAT unreferenced (leftovers). HERCS.DAT = starting campaign hangar (s16 count=5 + herc records), mode 1 only.

## After the sim (0x40eae7)
1. mission.var -> vars. results.dat: s16 success -> var0; s32 salvage_kg -> pool (added whatever the outcome, 0x40eb75); s16 n + n*(s16 a, s16 b) weapons recovered (campaign: add item type a to inventory, 0x41229d); then per-herc state (player + squad, 0x411720: 13 armour + 10 system (9 = pilot health) + n weapon condition %).
2. Squad (0x410c7c): a Herc at <= 29 % overall (0x411bd4: sum of the 22 + n percents / (22 + n)) is written off - its value (0x411432 = 0x413b50: parts at their condition + weapons below 80 %) -> pool, losses +1; otherwise its pilot is healed to 100. Pilot health 0 = killed (the player: game state 3, "killed, replay?"); dead pilots counted -> var9 ("Losses") and replaced; pilot record +0x2d/+0x2f/+0x31 mission stats are summed into +0x33/+0x35/+0x37, +0x39 = missions (0x41000e); var7 = squad field (L).
3. Campaign only: costs subtracted - automatic repair (0x40e804, option 0x4824e4: pool / squad size each, to the best affordable level, 0x411328) and weapon fabrication (0x40f324 -> 0x412428 / 0x412341, option 0x4824e5: keep two of every available weapon, or the queue of five at 0x46f8d6); the factory advances the Hercs being built (0x410a2b / 0x411086); tech unlocks:
   - Hercs (0x4118c5): vars 60..63, one per unlockable Herc (e.g. var60 Raptor II); expected value 2 (1 for the last one, M); var reset to 0.
   - Weapons (0x4126be): vars 50..59, one per unlockable weapon, each compared with 1 or 2 (e.g. var50==1 Laser400); var reset either way.
   - Script-awarded weapons (0x412760): vars 21..42, one weapon each, add var[k] copies at 100% (e.g. 21 Radar Jammer, 22 AC50). NOT reset by the shell (scripts must clear them).
   - The importer writes the full var maps to `missions/campaign.json` (`tech_unlock_rules`, `script_awards`; `tools/mission_es2.py`).
   - Report: outcome, salvage tons, weapons recovered, kills/losses (You/Squad); then advance.
   Success is only the sim's flag; the shell never re-evaluates objectives. Training: no advance/debrief/unlocks.
- Debrief selection (0x41ca4e, MSN version 5): conditions (14-byte {id,parent,type,a,b,c,?}; type 0: parent && var[a] OP c with OP = b-0x119 -> == != < <= > >=; 1: rand(a); 2: parent; 3: random cond value in [a,b]); values (8-byte {id,cond,pick,value}, last true wins); debrief records (64 bytes {cond, 30 ENG text ids, value_id}); first kept record used (30 text ids + AVI id). Briefing record 144 bytes {cond, ids[10], ids[30], ids[30], value -> briefing AVI}.

## Mission var setup (0x40e94e) (H)
- Campaign: var1 = career (1..5), var2 = mission (0..9); others persist. Mode 0: all zeroed.
- Both: var3 = `[0x482606]` (L), var4..6 = rand(12). MSN load zeroes vars listed in header words 10..39 (shipped: only var0).
- Script header: w0 theater (campaign) / 1; mode 0 only: w5 ammo (0 limited/1 unlimited), w6 invulnerable, w7 difficulty (campaign: `[0x482aa1]`) ROOKIE..ELITE 0..3, w9 day/night.

## Training / instant action / squad
- Training buttons set training index; new game mode 0 pilot "TRAINEE"; skips briefing UI.
- Instant action: mission = 8 + option -> DEMO / DEMO_01 / DEMO_02.
- Squad from MSN group 0: size = 1 + non -1 entries at group0 +0x38 (also in campaign: the MSN fixes wingman count).
- Player herc (mode 0): TRAIN5-8 and DEMO* load `gam\ini_<type>.dat` (outl, rapt, toma, sams, colo, apoc, ogre, mavr, razr; user's choice); otherwise from MSN group0[0] herc record (type +0x30, weapons +0x32[k], ammo +0x74[k]). Wingmen from group0[k+1]. Campaign: hercs/pilots from the player's own hangar/squad.

## Economy data (H; implemented in campaign_availability.md section 7, tools/export_economy.py)
- `GAM\HERC_INF.DAT` (0x41181c -> 0x483b54): s16 n = 9, n x 16 bytes {type, tons, km/h, hardpoints, price (tons; build cost x1000, 0x411019), ?, build time in missions (0x411086: build progress `herc+0x4a` = (time - left) x 100 / time), available flag (set by the Herc unlocks 0x4118c5; on at the start for Outlaw, Tomahawk, Samson, Colossus, Apocalypse)}. The build screen 0x446cfa prints tons, km/h, hardpoints and the price; 0x446e71 the pool minus the queued weapons, in tons.
- `GAM\WEAPONS.DAT` (0x411fc4 -> 0x483be4, 29-byte records): s16 n = 33, n x {s16 index, s16 len, name, u16 price (tons, x1000 at 0x411d57), u8 available (the weapon unlocks 0x4126be set it), s16 shelf}; then s16 k = 39, k x {s16 weapon, s16 condition %, s16 missile type}: the new campaign's weapon inventory. Record +0x17 is the stock count.
- `GAM\DAMAGE.DAT` (0x413628): s16 factor 800, s16[6] armour part weights, s16[9] system weights, s16 weapon factor 1000, s16 n = 33, s16[n] weapon repair costs. Part costs per Herc type at 0x4840cc (33 words: 6 armour at +0, 9 systems at +0x1a) = fixmul(800, fixmul(weight, price x1000)); weapon costs at 0x48431e = fixmul(1000, cost); fixmul = a * b >> 10 (0x450a84). Armour parts = the DMG armour components {0,1} {2,4} {3,5} {6} {7,9,11} {8,10,12} (0x46f8a4, averaged by 0x411c29). Repair levels 100 / 90 / 80 / 60 / 30 / 1 % (0x46fd78 / 0x46fd84; level lookup 0x41381c); bringing a part from c to t costs (t - c) x cost / 100 (0x41392a); a Herc's cost to a level (0x4139f7) skips weapons at 0 %.
- `SIMVOL0\STR\PILOTS.STR`: 36 names = 12 pilots x (pilot, replacement 1, replacement 2).
- DBSIM salvage (0x418e60, summed by 0x4241d0): per destroyed enemy unit, its type record (+2 = the 216-byte DAT) word DAT 0x52 x remaining health (0x41537c, 0..1024) >> 10, halved when component 0 is destroyed; results salvage = fixmul(2500, sum) + var20 x 25000 kg.
