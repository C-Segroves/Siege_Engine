# Campaign availability: Hercs, tanks and weapons by timeline, unlocks and salvage

User request (2026-10-09): keep tanks available; limit weapons to what the timeline allows plus
what has been salvaged; some Hercs only unlock after certain missions; Hercs and tanks from other
games are available if they come from earlier in the timeline, or if they are roughly equivalent
to what the current campaign has unlocked; mount other games' weapons properly scaled, matching
the hardpoint size.

## 1. Timeline (in-universe years; pack -> era)

| era | pack | year | notes |
|---|---|---|---|
| 1 | es1 | 2471 | Metaltech: Earthsiege |
| 2 | bd | ~2480 | Battledrome. Arena sport in the Earthsiege universe; placed between ES1 and ES2 (assumption: its manual gives no exact year) |
| 3 | es2 | ~2495 | Earthsiege 2, the end of the first Cybrid war |
| 4 | starsiege | 2829 | Starsiege, Harabec's empire and the return of Prometheus |
| 5 | tribes, tribes2 | 3940+ | Tribes. Infantry and vehicles only; never offered as Hercs |

Stored per pack as `pack.json` `"era"` and `"year"`. A pack without these sorts last.

## 2. What the player may field in a campaign

The campaign's **native** content is the content of the pack whose campaign is running.

- **Native Hercs and tanks:** only those unlocked so far. The unlock sources are:
  - ES1: the career start (`CAR_INIT.DAT`) plus the original unlocks/rewards, if decodable;
    otherwise by campaign progress.
  - ES2: tech-unlock vars 60–63 (Raptor II, Ogre, Maverick, Razor; see `es2_campaign_flow.md`)
    plus the starting `HERCS.DAT`.
  - Starsiege: the planet inventories (`scripts/*inventory*`), changed by the mission scripts.
- **Native weapons:** the unlocked set, from these sources:
  - ES1: the armory start stock (`C_ARMORY.DAT`).
  - ES2: weapon-unlock vars 50–59 and script-awarded vars 21–42.
  - Starsiege: the inventories.

  Salvage then adds to this set (§3).
- **Foreign Hercs/tanks** (another pack's, herc category, tanks included) are offered when either
  rule holds:
  1. **Earlier era:** foreign era < native era. These are older designs, always available.
  2. **Equivalent:** the foreign vehicle's combat rating is ≤ the best rating among native vehicles
     unlocked so far, with the same tank/Herc kind compared together. The rating is
     `Packs.combat_rating(v)`, the normalized armour + shields + weapon slots + speed already
     used for balance.

  The Build screen shows why an entry is offered ("older design", "equivalent to Gorgon").
- **Foreign weapons:** the same two rules, comparing against the native weapons unlocked so far of
  the same family/role (beam, cannon, missile, special) by `Packs.weapon_rating(w)`.
  Herc-category weapons only.
- **Only armed vehicles are player-selectable** (user, 2026-10-09). A vehicle needs a weapon
  hardpoint or a fixed weapon (`PackVehicleLoader.is_armed`). Transports, cargo drones and unarmed
  scouts or bombers stay AI-only; levels may use them as objectives later.
- **Tribes vehicles** (category `vehicle`, tribes_vehicles.md): the armed ones (Tribes Scout, Shrike,
  Thundersword, Beowulf) are fielded like Hercs (`CampaignAvailability.FIELDED_CATEGORIES`). Era 5
  means a campaign offers them only by the "equivalent" rule; arena / versus offer them always. Their
  weapons are fixed (`"fixed_loadout": true`): never armed, unarmed, offered or salvaged.
- **Arena / skirmish / versus / co-op skirmish:** no limits (everything enabled in the library).
- **Cybrid weapons by mode** (user, 2026-10-09):
  - **Campaign and co-op:** Cybrid weapons only on Cybrids, as in the originals.
  - **Arena, versus and skirmish:** Cybrid weapons go on any Herc or tank, limited only by
    hardpoint size. This is the `cybrid_weapons_on_hercs` rule; the match mode sets it.
- **Saga:** the native pack is the stage's pack. Hercs and salvage carry over between stages
  (ES1 → ES2 → Starsiege); carried-over items count as earlier-era.

## 3. Salvage ("acquired by scrap")

- **Recovering weapons:** each enemy destroyed in a won mission has a chance to yield its intact
  weapons, if they weren't destroyed as damage components. They go into the career armory as
  counted stock.
  - ES2 rule (`results.dat`): the sim reports weapons recovered, and the shell adds them.
  - ES1/Starsiege: use the same rule until their originals are decoded.
- **Using stock:** arming a hardpoint uses one unit of stock; unarming returns it. Weapons
  unlocked by timeline or tech are unlimited; salvaged foreign weapons are counted.
- **Salvage tonnage:** a pool in kg (shown / 1000 as tons) in Earthsiege and Earthsiege 2; it pays
  for building Hercs, fabricating weapons (ES2) and repairs, and grows with each mission's salvage.
  Prices come from the original tables; vehicles and weapons missing from them are priced by combat
  rating inside the table's range. Starsiege has no pool (inventories). Section 7.

## 4. Mounting other games' weapons

- **Hardpoint sizes:** every hardpoint has a size class S/M/L (from the herc's GL/mount masks).
  Every weapon gets a size class from its own game's data. ES1/ES2 masks; Starsiege
  mountpoint size; Battledrome pod size.
- **Fit rule:** a weapon fits when its size ≤ the hardpoint size (the Packs mask rules, extended
  across packs by size class).
- **Model:** the weapon model is the weapon's own game's shape, scaled to metres
  (`Packs.shape_scale`), then fitted to the hardpoint's reference box: the size of that game's
  native weapon model for the hardpoint's size class. Scale is uniform; the model is aligned with
  the mount node's orientation and its back sits against the hardpoint.
- **Missing model:** a weapon with no model borrows the model of the most similar installed weapon
  (archetype decision tree, `weapon_mounts.md` section 7), else the host's native pod of the same
  family and size, so a mounted weapon is never invisible.

### 4.1 Implementation (WeaponFit, WeaponPodFit, HercModel)

**Size ladder.** All four Herc games state sizes as hardpoint masks on one ladder, so a size class
is the mask's rung: **S = 7, M = 15, L = 31, X = 63** (X is Starsiege only); **I** = Starsiege
turret-only / internal weapons (exporter `NO_FIT_MASK` 127), never offered on a hardpoint.
`engine/weapon_fit.gd` (`WeaponFit`) owns the ladder; the loaders store the classes in the catalog:
weapon `"size"` (`PackWeaponLoader`) and hardpoint `guns[i].size` (`PackVehicleLoader` via
`WeaponFit.apply_hardpoint_sizes`). Herc family only: infantry/vehicle weapons get no size and
never mix with Herc hardpoints.

| game | hardpoint size source | weapon size source |
|---|---|---|
| ES1 | `GL/<UNIT>.GL` byte 25 mask 31/15/7 (gameplay.md section 3) | the GL mask each weapon needs (`PackWeaponLoader.ES1_SIZE`: ATC20/LAS100 S; ATC35/LAS200/ELF/GREN M; ATC50/LAS300/PBEAM/EMP L; MLRS racks and ECM S; Cybrid weapons L) |
| ES2 | `GL` byte 25 mask, same layout (es2.md section 5) | `weapons_engine.json` `hardpoint_mask`: smallest GL mask the weapon occupies in the shell default loadouts `SHELL0/GAM/INI_*.DAT`, else by analogy (es2.md section 9) |
| Battledrome | Herc record mounts `+0x68` bay type: LIGHT/MEDIUM/HEAVY BAY 7/15/31, MINE/MSL LNCHR 7 (bd_weapons.md section 6) | SIM.EXE weapon record bay list (`native.record.bays`): the smallest bay it is allowed in; launchers S |
| Starsiege | `newHardPoint` size letter S/M/L/X (`datHerc_*.cs`, starsiege.md section 3) | `newWeapon` size letter (`datWeapon.cs`); turret-only and internal weapons I |

**Fit rule.** `WeaponFit.fits(weapon, vehicle, i, rules := {})`: same weapon family, Cybrid-only
weapons only where `WeaponFit.allows_cybrid_weapons(vehicle, rules)` (always on Cybrids; on Hercs
and tanks only with `rules.cybrid_weapons_on_hercs`, section 2), and
`rank(weapon size) <= rank(hardpoint size)`. `Packs.weapons_for_mask(mask, include_cybrid, category,
rules)` uses the same concept: `include_cybrid` or the rule lets Cybrid-only weapons through. On the ladder this is exactly the old
`hardpoint mask >= weapon mask` test, so every game's own combinations are unchanged
(`tests/weapon_fit_check` compares the old and new offered lists on all 406 hardpoints: identical).
`Packs.fits` / `Packs.weapons_for_mask` delegate to `WeaponFit.fits_mask`. Not enforced (neither
before nor now): Battledrome's per-weapon bay lists (mines only in the mine launcher, missiles only
in missile launchers).

**Models** (`games/es1/herc_model.gd` `HercModel.mount_plan`, used by battles and `HangarBay`):

| case | what is shown |
|---|---|
| ES1/ES2 internal mount (GL mount group > 3) | nothing (as in the originals) |
| Battledrome weapon on a Battledrome bay pod | the pod baked into the Herc shape |
| Battledrome weapon on a Battledrome mine / missile launcher | nothing (BD draws none) |
| the host game's own weapon with a model | its own pod at its original placement (ES1/ES2 `MECHWPNS` shape of the mount group; Starsiege `model.mount_shapes` at the hardpoint) |
| another game's weapon with a model | that model (metric scale `Packs.shape_scale`), fitted to the host's pod at that hardpoint (a Battledrome bay's baked pod is hidden) |
| a weapon without a model (Battledrome pods, ES2 MINE/LAEW, Starsiege EHUL) | its look-alike from the installed packs (`WeaponLookalike` decision tree, `weapon_mounts.md` section 7), else the host game's own pod of the same family and size class (its representative weapon), else a procedural stand-in pod fitted to the reference box |

**Placement and reference pod** (exact rules and evidence: `weapon_mounts.md`). Every gun has one
hardpoint frame (`WeaponMount.build_frames`): ES1/ES2 the node of the GL mount part at the GL offset,
Battledrome the bay's muzzle point, Starsiege the hardpoint offset on head0. Native pods sit where
the original puts them (ES pod push-out by mount group, Starsiege roll by side, BD baked pods).
A foreign weapon is fitted to the host's own pod at that hardpoint (`WeaponPodFit.frame_reference`):
Battledrome bays the baked pod's box (the baked pod is hidden), Earthsiege the host's representative
pod of the size class and family (median length, Cybrid-only left out) in the hardpoint's mount-group
variant and push-out, Starsiege its pod rolled by side; a game without a pod of that size borrows the
other games' median box (else fixed ES1-like lengths S 3.5, M 4.7, L 6.2, X 7.8 m), hung off the
hardpoint. The size class used is the weapon's own, capped at the hardpoint's.

**Scaling rule.** Uniform scale = reference length / model length (longest axis of the detail-0
geometry, node default transforms applied). The pod's back face goes on the reference's back face,
its face toward the Herc on the reference's inner face (outward = ES mount group / Starsiege side),
centred on the remaining axis. Battledrome launchers (nothing drawn in BD) only give the muzzle
point: there the pod's front goes on it.

**Mount bases.** Starsiege weapon shapes name their per-LOD root pieces `baseA 32`, `baseB16` …:
mostly a flat 1–2 polygon strut, dropped on another game's Herc (`WeaponPodFit.foreign_pod_shape`);
on wg_las / wg_hlas it is the gun body (10 polygons) and stays. Foreign indexed pods always draw with
their own pack's palette (`ShapeInstance`
replaces another pack's palette with the pod pack's default; the Starsiege world-palette remap
applies only when a Starsiege map has set it).

## 5. Implementation: decoded vs approximated (availability, unlocks, salvage)

Code: `engine/campaign_availability.gd` (`CampaignAvailability`, the context and the §2/§3 rules),
`engine/combat_rating.gd` (`CombatRating`; `Packs.combat_rating / weapon_rating / weapon_family /
era / year`), `games/es1/mission/es1_tech.gd`, `games/es1/mission/es2_tech.gd`,
`games/starsiege/ss_inventory.gd`, `engine/garage/garage.gd` (section 6),
`games/es1/battle/battle_salvage.gd`. Each campaign provider has a `garage`,
`availability_context()` and `apply_salvage(ids)`; `Session.availability_context()` adds the
saga carry-over. Tests: `game/tests/availability_check.tscn`, `game/tests/garage_check.tscn`.

**Ratings.** Percentile rank of each stat among the *same game's* entries of the same kind/family
(0 weakest .. 1 strongest), weighted: vehicles armour 0.35 (sum of damage-component hit points;
left out when a game has none, e.g. Battledrome), hardpoints 0.35, shields 0.15, top speed 0.15;
weapons damage per second 0.75, range 0.25. Per-game ranks because the raw scales differ by an
order of magnitude (ES1 LAS100 4478 vs ES2 LAS100 280 dmg/s). "Equivalent" = rating ≤ the best
unlocked native item of the same kind/family + 0.02; the reason names the weakest native item at
least that strong. Tanks compare with the campaign's tanks, or with its Hercs when it has none
(so tanks stay available in Earthsiege and ES2, more of them as stronger Hercs unlock). Weapon
families: beam (beam, emp, plasma), cannon (cannon, grenade), missile (missile, artillery), special
(ecm, mine, other).

**Earthsiege — decoded (H).** `BST\TECH_0.DAT` (career; `TECH_SNG.DAT` single missions), loaded by
GO.EXE 0x158ff: `u16 n`, n × `{s16 kind (0 Herc type, 1 weapon), s16 index, s16 early, s16 late}`;
tech object ctor 0x1ee3 (8 Herc + 17 weapon entries `{early, late, u8 released}`). Release test
0x1f78(missions flown = career record +0xa): released once missions ≥ late, or ≥ early while the
standing test 0x36837 is good; -1 = never; a release raises `TechReleaseAlert`. Career values
(example: Tomahawk early 8 / late 9; the starting Hercs and weapons are 0, some weapons never).
Exported to `shell/hangar.json` `career_tech`,
`single_tech`, `tech_weapons` (`tools/export_shell.py --hangar`). Starting garage: `CAR_INIT.DAT`
Hercs and the `C_ARMORY.DAT` stock (`Es1Tech.make_start_garage`).
*Approximated:* "good standing" = the last mission was won (0x36837 is a rank-table lookup whose
inputs were not traced). Released weapons are unlimited; the C_ARMORY counts only matter for
weapons not yet released.

**Earthsiege 2 — decoded.** `tech_unlock_rules` (var → item, required value): Herc vars 60..63
(e.g. 60 Raptor II = 2; Razor needs only 1, as the campaign's objectives raise its var only once, M),
weapon vars 50..59 (e.g. 50 LAS400 = 1); vars reset after the check. `script_awards` vars 21..42 (mission scripts
set them to 1 when a Cybrid carrying that weapon dies: unit op 13 → var = 1) add var[k] units.
`start_hangar` from `SHELL0/GAM/HERCS.DAT`: `s16 n`, n × `{slot, herc type, condition %, ?, k,
k × {GL slot, weapon (exe table 0x498eb0), %, missile type}}` → four Outlaws (slot 4: Razor type
with condition 0 and no weapons = placeholder, not offered). All in `missions/campaign.json`
(`tools/mission_es2.py`). *Approximated:* award vars are cleared after being counted (the original shell never clears them, which would pay
a kill again after every later mission); the battle salvage list (§3) is added as well.
Start offer (decoded, section 7): what the shell offers from the start is HERC_INF.DAT's / WEAPONS.DAT's `available`
flags (Outlaw, Tomahawk, Samson, Colossus, Apocalypse; the first war's weapons plus FLYMSL, ELF II,
EMP II, PBW II, plasma), and the armory starts with WEAPONS.DAT's 39-item inventory. Without
`economy.json` (older imports) the start offer falls back to HERCS.DAT's types and the first war's
weapons (`Es2Tech.BASE_WEAPONS`).

**Starsiege — decoded.** Planet inventories from `scripts/hu_planet_init.cs` / `cy_planet_init.cs`
(`campaigns/<variant>.json` `inventory_init`) and the Inventory* calls the mission scripts make
(`updatePlanetInventory`, recorded by `StarsiegeMissionRuntime`): per planet and stash (-1)
vehicle and weapon counts, -1 = infinite; ids via `gameplay/ids.json`. Offered = the current
mission's planet + the stash; infinite weapons unlimited, counted ones as stock. The human
campaign starts with only the stash Emancipator; HA0/HA1 add the Emancipator and Avenger on Mars.
Components and pilots are not modelled. Salvage goes to the stash (`vehicle::salvage`).

**Salvage (§3).** `BattleSalvage`: every enemy Herc destroyed in a mission yields the weapons whose
`WEAPON <GL slot + 1>` damage component still has hit points (ES2 DBSIM 0x426ac8 "below 50 %
damage"; weapon components have 1 hp). Starsiege mountpoints have no weapon components, so all its
weapons count as intact. Added only when the mission is won (`Session.finish_mission`,
`MissionLaunch.on_battle_finished` for the ES1 shell career) into the campaign's garage armory.
The "chance" in §3 is not applied (every intact weapon is recovered). Arming takes a counted unit
from the armory, unarming / scrapping puts it back (section 6), in every campaign.

**Fixed loadouts** (Tribes vehicles): `PackVehicleLoader.has_fixed_loadout`. `WeaponFit.fits` offers
nothing for their mounts, `Garage` keeps the standard armament (no arming, no stock), `LoadoutEditor`
shows it read-only, `BattleSalvage` skips them, `Herc.equip` always fits the standard loadout.

**Economy and crew:** sections 7 and 8.

## 6. The garage: one persistent hangar for every campaign

User request (2026-10-09): one hangar, the app's 3D one, for every campaign, with a persistent
garage, identical in every game (same layout, controls, flow and labels); only the data seeds and
the availability rules differ per game.

**Model** (`engine/garage/garage.gd`, `Garage`): `vehicles` = owned Hercs `{uid, vehicle, name,
loadout, pilot_id, condition, build_left}` (at most 16, the original hangar size), `selected` = the
Herc taken into the next mission, `stock` = the armory's counted weapons `{base weapon id: units}`,
`salvage_kg` = the pool, `crew` = the pilot roster, `squad` / `squad_auto` = the chosen wingmen,
`last_report` = the last mission's outcome. Build (only what the campaign offers and the pool pays;
armed with the type's standard weapons as far as the armory allows for free), scrap (never the last
Herc; its counted weapons go back, its parts' worth to the pool), arm / unarm per hardpoint (`WeaponFit`
fit + availability; a counted weapon uses a unit, unarming returns it; unlimited weapons never touch
the stock unless the game fabricates them, section 7), repair, rename, `to_dict` / `from_dict` /
`from_saved`. Every rule takes the campaign's availability context, whose `salvage_stock` is the
armory the garage draws from and whose `economy` (`GarageEconomy`) prices everything.

**Who owns it:** each campaign provider has a `garage`, saved with the campaign:

| provider | seed | armory (`ctx.salvage_stock`) |
|---|---|---|
| Earthsiege (`Campaign`; the shell career keeps it in `career.campaign_state`) | `CAR_INIT.DAT` Hercs + `C_ARMORY.DAT` stock (`Es1Tech.make_start_garage`) | the garage's stock (+ salvage) |
| Earthsiege 2 (`CampaignES2`) | `HERCS.DAT`: four armed Outlaws, `WEAPONS.DAT`'s start inventory (`Es2Tech.make_start_garage`) | the garage's stock (+ script awards, salvage) |
| Starsiege (`SSCampaign`) | one Herc per stash vehicle, standard loadouts (`SSInventory.make_start_garage`) | the planet + stash inventory's counted weapons minus those mounted on the garage's Hercs |

Saves from before the garage get the seed plus their old stock (`armory`, `unlocks.stock`); a shell
career saved with the shell's own hangar (`career.hangar`) moves it into its campaign's garage
(`MissionLaunch.ensure_campaign_state`).

**Saga:** when a stage is won, its Herc types and weapons stay in `carried` (earlier-era designs)
and its garage goes into `carried.garage`; the next stage's garage absorbs it when that stage starts
(after the Starsiege side choice), so owned Hercs and the armory travel ES1 → ES2 → Starsiege.

**UI** (the same for every campaign):
- `engine/ui/screens/hangar_screen.gd` (`HangarScreen`): ScreenFrame + 3D hangar; the salvage pool,
  then two tabs. **Hercs:** owned Hercs (select; condition %, "in the factory"), name, condition with
  Repair / Repair all and their cost, a `LoadoutEditor` per hardpoint showing the units left and the
  fabrication price, Scrap (confirmed, with its value), Build (`VehiclePicker` with the reason each
  type is offered, previewed in the bay; price and build time; disabled when the pool can't pay), the
  armory stock. **Crew** (`engine/ui/crew_panel.gd`, `CrewPanel`): a pilot picker and a Wingman box
  per Herc, the roster (skill, missions, kills, seat), losses, the last mission's report. The bay
  shows the selected Herc's damaged parts (`HercCondition.apply_to_model`).
- `engine/ui/garage_picker.gd` (`GaragePicker`): "Your Herc" on the briefing and the co-op campaign
  host's lobby: the garage's Hercs plus the Herc a mission issues (Earthsiege 2, Starsiege; chosen
  first), and a button that opens the Hangar screen.
- The original Earthsiege shell: the service bay hub shows the selected Herc in 3D; ARMING, REPAIR
  and BUILD open the same Hangar screen over the shell, CREW (1610) opens it on the Crew tab
  (`HangarRouter`, `ShellHangar`). The shell's own arming / build / repair / crew screens and the
  original 2D hangar art are no longer used.
- Skirmish, versus and arena keep the unrestricted `HercSelector`.

## 7. Economy: salvage, prices, repairs, damage between missions

User request (2026-10-10): the missing campaign economy, the same in every game; per-game data and
rules only. Code: `engine/garage/garage_economy.gd` (`GarageEconomy`: prices and formulas),
`engine/garage/herc_condition.gd` (`HercCondition`), `engine/garage/garage_report.gd`
(`GarageReport`: a mission result applied to the garage), `games/es1/battle/battle_salvage.gd`
(the result's `salvage_kg` and `squad`). Data: `<pack>/gameplay/economy.json`
(`tools/export_economy.py`, an importer step of es1 and es2). Test: `game/tests/economy_check.tscn`;
flows: `game/tests/economy_flow.tscn` (`--flow=es2_economy`, `--flow=es1_crew`).

| | Earthsiege (GO.EXE) | Earthsiege 2 (VSHELL.EXE) | Starsiege |
|---|---|---|---|
| pool at start | 60000 kg (0x163ec) | 100000 + rand(11) x 1000 kg (0x40e2ed) | none |
| Herc price (tons) | table 0x808b8, one s16 per Herc type (e.g. Roadrunner 50) | `HERC_INF.DAT` +8 (x1000, 0x411019; e.g. Outlaw 60) | free (inventory) |
| build time (missions) | table 0x808d8, one per Herc type (1..3) | `HERC_INF.DAT` +0xc (0x411086 counts down): 1..3 | at once |
| weapon fabrication | none (released weapons are unlimited) | `WEAPONS.DAT` price x1000 (0x411d57): ATC20 5 t .. pods 50 t | inventory |
| repair costs | `CFG/DAMAGE.DAT` (0x387ac) | `SHELL0/GAM/DAMAGE.DAT` (0x413628) | no damage kept |

**Repair formula** (both games, the same `DAMAGE.DAT` layout: factor 800, 6 armour weights, 9 (+ pilot)
system weights, weapon factor 1000, per-weapon costs): part cost = fixmul(factor, fixmul(weight,
price kg)), fixmul(a, b) = a * b >> 10; the 13 armour components form 6 parts (VSHELL 0x46f8a4:
{0,1} cockpit, {2,4} / {3,5} arms, {6} crotch, {7,9,11} / {8,10,12} legs; a part's condition is their
average); weapon cost = fixmul(weapon factor, weapon cost). Repairing a part from c % to t % costs
(t - c) x cost / 100 (0x41392a). The shell repairs to the levels 100 / 90 / 80 / 60 / 30 % (0x46fd78),
the best one the pool affords (0x411328); Repair (selected Herc) and Repair all do the same.
*Approximations:* the remake simulates no systems, so a system's condition is the mean armour
condition; a remake weapon component has one hit point, so a destroyed weapon is repaired from 0 %
(the original skips weapons at 0 %). Vehicles and weapons missing from a game's tables (another
game's, Cybrids) are priced by combat rating inside the table's price range.

**Damage between missions** (VSHELL 0x40eae7; results.dat per squad Herc: 13 + 10 + 10 condition
percents): every garage Herc that flew (the player's when he takes a garage Herc, the wingmen) keeps
the per-component condition it came back with (`HercCondition`: one fraction per DMG component) and
starts the next battle in it (`BattleSpawner` applies it); the hangar bay and the battle model show
the damaged look of components below 50 %. A Herc destroyed or at <= 29 % is written off (0x410c7c):
its parts' worth (0x413b50: parts at their condition, weapons below 80 %) joins the pool, weapons at
>= 80 % go to the armory; the garage always keeps its last Herc. Starsiege keeps no damage.

**Salvage income** (results.dat, DBSIM): every destroyed enemy is worth its unit type's value word
(DAT 0x52, `threat_value`: Mongoose 600 .. Hyperion / Pitbull 2000, Hercs 1024) x its remaining
health, halved without its cockpit (0x418e60); the sum x 2500 / 1024 (0x4241d0): a few hundred kg a
kill. Earthsiege 2 adds mission var 20 x 25000 kg (the scripts raise var 20 when structures and
groups die). The shell adds it whatever the outcome (0x40eb75). The results screen lists it
("Salvage: 6 t") before the recovered weapons. *Approximations:* the health function 0x41537c is the
hit-point weighted integrity; Earthsiege uses the Earthsiege 2 rule (its sim's salvage is not decoded).

**Weapon fabrication** (Earthsiege 2): a weapon the campaign offers without limit (unlocked) is
fabricated for its price when it is armed and the armory holds no unit of it; taken off, it joins the
armory as an owned unit. Counted weapons (salvage, awards) never cost salvage. *Not modelled:* the
shell's automatic fabrication (option 0x4824e5: keep two of each, or a queue of five) and automatic
repair after a mission (option 0x4824e4); the player repairs and fabricates in the Hangar screen.

**Build:** the pool pays the price at once; the Herc stays in the factory for its build time
(`build_left`, shown in the lists, not selectable for a mission meanwhile). The Build button is
disabled when the pool can't pay. Scrapping pays the parts' worth.

**Saga:** a finished stage's pool joins the next stage's (with its garage and crew).

## 8. Crew and wingmen

Code: `engine/crew/crew.gd` (`Crew`: the roster), `engine/crew/squad_roster.gd` (`SquadRoster`:
seats and wingmen), `engine/ui/crew_panel.gd`; battles: `games/es1/mission/es1_squad_spawner.gd`
(Earthsiege), `MissionRuntimeES2._make_wingman` (Earthsiege 2).

- **Roster:** twelve pilots, each with a chain of replacement names: Earthsiege `CAR/NAMES.DAT`
  (DUGGAN, DUGGAN 1, DUGGAN 2 ...), Earthsiege 2 `SIMVOL0/STR/PILOTS.STR` (DUGGAN, BRUTUS, BUTCHER;
  RIGGS, BRECKER, BOWMAN ...). Record `{id, slot, name, skill, missions, kills}`; the fallen are kept.
- **Seats:** a pilot flies one garage Herc (`pilot_id`); the selected Herc is the player's own. New
  campaigns, merged saga garages and replacements fill the empty seats in roster order.
- **Wingmen:** Earthsiege 2 missions fix the count (MSN group 0's Hercs besides the player,
  `MissionRuntimeES2.wingman_slots`); Earthsiege takes up to three (the HDD's three wingman windows;
  VSHELL squad.h asserts index < 3); Starsiege missions bring their own squadmates (0). The first
  eligible Hercs (built, with a living pilot, not the player's) fly until the player ticks his own
  choice in the Crew tab. Battle config `squad`: `[{vehicle, loadout, name, skill, garage}]`; the
  wingmen start in the player squad's slots with the Herc's loadout and condition and follow the
  player (ES2: they replace MSN group 0's members; slots beyond the squad keep the MSN's own Hercs).
- **After the mission:** each wingman's damage comes back like the player's; a wingman whose Herc was
  destroyed is killed (the remake has no pilot system), counted as a loss (ES2: mission var 9 +=
  losses) and replaced by the next name of his slot. Pilots gain experience.
- *Approximation:* skill (the AI pilot's skill) starts at 0.55 for the original crew, 0.45 for
  replacements, +0.02 a mission and +0.01 a kill, up to 0.9 (the originals' pilot rating is not decoded).
- *Not modelled:* co-op campaign squads (human wingmen only); an aborted mission records no damage.

## 9. Campaign saves: one store for every campaign and front end

User request (2026-10-10): autosave after every finished mission, named saves and loads, a New campaign
flow with a pilot name and the campaign to fly, and a killed pilot replays the mission from the last save
like the originals.

**Store** (`engine/save_games.gd`, `SaveGames`): `user://saves/<id>.json`, shared by the app's launcher
and the original Earthsiege shell. A save is `{meta, pilot, playtime, coop, saga | pack + campaign}`
(+ `shell`: the shell's career record, + `launch`: a restore point's Herc). `meta` = name, kind, pilot,
campaign key (`saga`, `es1`, `es2`, `starsiege_human`, `starsiege_cybrid`), title, mission, games needed,
date, playtime, finished, victory - what the lists show without loading the campaign. Every save carries
the provider, the garage (Hercs, armory, salvage pool), the crew, the economy state and the saga state.

| kind | id | written |
|---|---|---|
| autosave | `auto_<campaign>_<pilot>` | at the start, after every finished mission (win or loss, recorded when the debriefing opens), every hangar change, the saga's side choice, "Save and quit" |
| restore point ("before mission") | `restore_<campaign>_<pilot>` | when a mission is launched (briefing Launch; the shell's career launch) |
| named | `save_<name>` | the Save / Load screen (briefing, saga side choice) or the shell's CAREER BACKUPS SAVE |

Original evidence: Earthsiege 2 autosaves slot 10 whenever the shell hands off to the sim and its "You
were killed. Replay?" / "war lost, replay?" prompts reload it (es2_campaign_flow.md); Earthsiege kept
career backups (MENU1220 CAREER BACKUPS: SAVE / RESTORE, MENU1240 warns that a backup already exists,
MENU1250 tells a killed pilot to restore a backup to go on with the career, MENU1260 CAREER OVER asks
for a restore to replay it); Starsiege replays a failed mission.
Nobody saved mid-mission: the in-battle menu has no save.

**Failed or aborted missions** (playtest E2; an abort counts as a failure everywhere): Earthsiege moves on to the
slot's failure variant (GO.EXE 0x159e9: failed = debriefing code > threshold[type], so e.g. a rescue won with heavy
damage takes the failure branch; 0x141d0 advances); a lost career (next-campaign table "game over") ends on the
end page with *Replay mission* (restore point; the shell's MENU1260 "restore a backup"). Earthsiege 2 moves on after
an ordinary failure; failing a must-win mission loses the war and the end page offers *Replay mission* (VSHELL reloads
slot 10). Starsiege flies a failed mission again: the debriefing offers *Replay mission* from the restore point
(`replays_failed_missions()` of the provider; `tests/campaign_failure_check`).

**App** (`engine/ui/screens/`): the launcher menu and the library offer *Continue campaign* (the newest save
that can go on), *New campaign* (`new_campaign_screen.gd`: pilot name + the saga or one game's campaign,
each with a description, games not installed shown disabled; restarting a pilot's unfinished campaign asks
first) and *Load game* (`saves_screen.gd`: every save, newest first, with name, kind, campaign, mission,
date and playtime; Delete asks first; in save mode a name field, overwriting asks first). Finished
campaigns and saves needing a game that is not installed are listed but cannot be loaded or continued
(`Session.load_save` refuses them too).

**Pilot killed** (`Battle` reports `pilot_killed` when the player's Herc is destroyed; single player only):
the mission is not recorded (`Session.must_replay`); the launcher opens `killed_screen.gd` (each game's
prompt; Earthsiege plays its death song): *Replay mission* reloads the restore point and relaunches the
mission in the same Herc, *Quit to main menu* leaves the campaign at its last save. Campaign won / lost
endings are unchanged.

**Earthsiege shell:** a career is its pilot's Earthsiege autosave (`ShellCareers`; the app's Earthsiege
campaigns appear as careers and vice versa; `user://es1_careers.json` of earlier versions is moved into the
store once and renamed `.moved.json`). Registration (MENU1210) and DELETE (now confirmed with MENU1270) work
on the store; CAREER BACKUPS (`ShellBackups`) lists the Earthsiege named saves and restore points of both
front ends, SAVE writes a backup named after the pilot (MENU1240 before overwriting), RESTORE makes the
selected save the career. A killed pilot: death song + ENDFA, the career goes back to its restore point and
MENU1250 shows over the main menu with the remake's REPLAY next to DONE; a finished career's PROCEED shows
MENU1260.
