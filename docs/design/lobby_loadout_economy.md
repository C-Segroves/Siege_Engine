# One lobby, one loadout screen, one economy (design)

Status: design, nothing built. Written 2026-10-19 for parallel implementation agents. Code paths are relative to
`game/`. Standards: `docs/CODING_STANDARDS.md` (Clean Code; `make_` returns a value, `apply_` mutates, `is_` asks,
`build_` creates nodes, `load_` reads files; section 2 input = named actions only; section 3 UI = one theme, shared
widgets, mouse + keyboard + gamepad on every screen, primary action bottom-right, `menu_back` leaves).
Related: `docs/MENU_MAP.md`, `docs/design/extraction.md`, `docs/design/extraction_map_varuna.md`.
No game data in the repo: every item, price base, shape and skin comes from the installed packs at run time; the repo
holds code and the remake's own design numbers (JSON).

## 0. Decisions the user confirmed (requirements, not questions)

1. One standard lobby for campaign, co-op campaign, every multiplayer mode and extraction, host and players (section 5).
2. One standard loadout screen "Operator Setup" (section 6).
3. Non-hosts see Game Options read-only; ready state on every card with a disallowed-items warning before ready-up;
   own squad as cards, everyone else as a compact list (up to 64); a chat strip; a gamepad equivalent for everything
   (right click = remove = pad X); credits always visible; slot-fit / weight and "not allowed in this mode" indicators;
   the 3 character slots as tabs across the top of the loadout screen.
4. Economy: start with the basic Tribes 1 armours and skins; all else bought with credits earned in any MP mode
   (extraction included); 3 character slots replace `LoadoutPresets`; first purchase is expensive; skins, vehicles
   and character models are lost on death and re-bought for 100 cr, **in extraction only** (nothing owned is ever lost
   elsewhere).
5. Extraction call-ins paid with raid points (section 9).

Terminology: **credits (cr)** = the persistent wallet. **Raid points (RP)** = the per-raid call-in currency; never
persisted, never credits. **Unlock** = a permanent right to use something (armour, body, skin, vehicle, weapon,
ammo type, gear, pack). **Stock** = extraction's physical items (stash/kit, `ExtractionInventory`), unchanged.

## 1. Conflicts resolved in this design (and the choices made)

| # | Conflict | Choice (all numbers are data) |
|---|---|---|
| C1 | Extraction today sells medium/heavy armour (1800/3600), loses it on death, and `start_money` is 3000; the new rule says the basic Tribes 1 armours are free. | The three Tribes 1 armours are free everywhere (extraction too). Paid armours (Tribes 2 etc.) are unlocks; in extraction the worn paid armour is *at risk* (section 4). Old `armor/` stash items migrate to unlocks. `ExtractionRules.start_money` is replaced by `economy_rules.start_credits`. |
| C2 | Extraction vehicle call-in tokens (`callin/<vehicle>`, 2500..14000 cr) vs. "the player's saved vehicle is delivered with raid points". | Tokens are removed. The vehicle becomes a **vehicle unlock** (price = the old call-in base price x multiplier); the raid delivers the slot's preferred vehicle for RP. Stash `callin/` stacks migrate to vehicle unlocks. |
| C3 | Extraction weapons/ammo/gear are physical, lost with the kit; elsewhere the weapon list must persist. | Two ownership layers. Outside extraction weapons/ammo/gear/packs are **unlocks** (buy once, use every match, nothing consumed). In extraction the same screen edits the **kit** from stock (`ExtractionProfile`, unchanged rules: capacity, insured slot, stash). Model, skin, armour and vehicle are always unlocks, in both layers. |
| C4 | "Initial purchase is more costly" is ambiguous. | Unlock price = base price x `unlock_multiplier[kind]` (weapons x2, ...). Re-buying a lost extraction item costs a flat 100 cr. Stock refills in extraction stay at the old shop price. |
| C5 | Loss on death needs a defined scope. | At raid start the active slot's non-free model, skin, armour become *at risk*; the vehicle becomes at risk when it is first **called in** (a vehicle never delivered never left the hangar). Dying moves at-risk, un-insured unlocks to `lost`. Extracting clears the risk. The insured slot may hold one such unlock (section 4). |
| C6 | Starting a fresh account with no weapon or vehicle would be unplayable. | Free: the armour's `default_loadout` weapons and their ammo, the Tribes 1 blaster (`free_weapons`), the default skin/body of each free armour, and one starter vehicle per installed pack (its lowest-rated pilotable vehicle). Data: `free_unlocks`. |
| C7 | Credits are "earned in multiplayer games". | Solo campaign and skirmish vs bots earn nothing (`earn.modes.solo` all 0); co-op campaign, co-op vs Cybrids, every versus mode and extraction earn. Campaign has its own tons/salvage economy and does not use the store. |
| C8 | Profiles live on each player's machine today (trusted). A dedicated server cannot verify ownership. | Same trust model as the extraction kit. Authority is behind one interface (`ProfileAuthority`) so a server-side store can replace `LocalProfileAuthority` later (open question O1). The host always re-validates **allowed** items per mode, never ownership. |
| C9 | The lobby needs "Adjust Teams" but `TeamList` exists as a column board. | `TeamList` is reused unchanged inside an "Adjust teams" dialog opened from Game Options (host). Players still pick their own team on their card. |
| C10 | Raid tasks (`RaidTaskBoard`, max 2) vs "pick up to 3". | Raid tasks become the individual goals of extraction; `tasks.max_picked` becomes 3 (shared `goals.max_individual` = 3). |

## 2. Data models

New folder `engine/economy/` (chunk 1). All persistent classes extend `RefCounted`, have `to_dict()` /
`apply_dict(d)` (JSON numbers come back as floats: cast ints on load, as `ExtractionProfile.apply_dict` does) and
`static load_for(pilot_name)` / `save()` through `SaveGames.read_profile / write_profile`
(`user://saves/profiles/operator_<slug>.json`; profiles stay per player name, `SaveGames.make_slug`).
`PlayerProfile` (settings.json: name, infantry pack, UI choices) stays for the name only.

### 2.1 Ids

`UnlockId` (static helpers; same `kind/ref` shape as `ExtractionItems`, refs are pack-qualified `pack:ID`):

```
armor/tribes:MEDIUM            body/tribes2:bioderm_medium        skin/<body shape id>#<skin id>
vehicle/es1:RAPTOR             herc_skin/<vehicle shape id>#<skin id>
weapon/tribes:DISC             herc_weapon/es1:LASER              ammo/tribes:DISC
gear/tribes:GRENADE            pack/tribes:ENERGYPACK
```
`UnlockId.KINDS`, `make(kind, ref)`, `kind_of(id)`, `ref_of(id)`, `pack_of(id)` ("" never; the pack prefix of the ref).
A stash item `weapon/x` and an unlock `weapon/x` share a string but live in different containers.

### 2.2 `CharacterSlot` (replaces `LoadoutPresets`)

```
class_name CharacterSlot            # engine/economy/character_slot.gd
var index := 0
var label := ""                      # "Slot 1" default, player-editable (MAX_LABEL 24)
var pack := ""                       # infantry game this slot was built for
var armor := ""                      # "tribes:MEDIUM"
var body := ""                       # "" = the armour's default body
var skin := ""
var vehicle := ""                    # preferred vehicle, "" = none
var herc_skin := ""
var infantry := {"weapons": [], "ammo": {}, "gear": {}, "pack": ""}   # ids are bare refs (tribes:DISC)
var herc_loadout: Array = []         # weapon ids in hardpoint order ("" = empty)
static func make_default(i: int) -> CharacterSlot            # free armour, free skin, starter vehicle
func make_roster_fields(ctx: LoadoutContext) -> Dictionary   # legacy roster keys + "slot" snapshot (4.1)
func make_roster_snapshot() -> Dictionary                    # compact form, section 7.1
func make_blocks(ctx: LoadoutContext) -> Array               # [{id, text}] what ctx forbids / what is not owned
func make_resolved(ctx: LoadoutContext, owned: Unlocks) -> Dictionary   # {slot: CharacterSlot, dropped: [text]}
func is_complete() -> bool
func to_dict() -> Dictionary
func apply_dict(d: Dictionary) -> void
```
`make_resolved` never mutates the saved slot: it returns the build the match will use, with disallowed or
unowned parts replaced by the free default and a human line per change (the text of the ready-up warning).

### 2.3 `Unlocks`

```
class_name Unlocks                   # engine/economy/unlocks.gd
var owned := {}                      # id -> true   (never deleted: a missing pack only hides)
var lost := {}                       # id -> true   (extraction deaths; re-buy 100 cr)
func is_free(id: String) -> bool                 # EconomyRules.free_unlocks (+ starter vehicles, armour defaults)
func is_owned(id: String) -> bool                # free or (owned and not lost)
func is_lost(id: String) -> bool
func is_visible(id: String) -> bool              # the id's pack is installed (Assets.has_pack)
func make_owned(kind: String) -> Array           # visible owned ids of a kind
func make_hidden_count() -> int                  # owned ids of packs not installed (footnote only)
func apply_add(id: String) -> void
func apply_lose(id: String) -> void              # owned -> lost
func apply_recover(id: String) -> void           # lost -> owned
```

### 2.4 `OperatorProfile` (the save file)

```
class_name OperatorProfile           # engine/economy/operator_profile.gd
const VERSION := 1
const SLOT_COUNT := 3                # EconomyRules.slot_count()
var pilot := ""
var credits := 0
var unlocks := Unlocks.new()
var slots: Array = []                # 3 CharacterSlot
var active_slot := 0
var at_risk: Array = []              # unlock ids committed to the running raid
var stats := {"matches": 0, "earned": 0, "spent": 0, "unlocks_lost": 0, "bought_back": 0}
var migrated: Array = []             # "loadout_presets", "player_settings", "extraction_v2"
static func load_for(pilot_name: String) -> OperatorProfile    # new profile when none: apply_new
func save() -> bool
func apply_new(pilot_name: String) -> void
func make_active_slot() -> CharacterSlot
func apply_select_slot(i: int) -> void
func apply_award(award: Dictionary) -> void       # credits += award.total, stats; award from CreditsLedger
func is_affordable(price: int) -> bool
func apply_spend(price: int) -> bool              # false (no change) when short
func apply_commit_risk(ids: Array) -> void        # raid start / vehicle called in
func apply_raid_survived() -> void                # at_risk cleared
func apply_raid_lost(insured: Array) -> Array     # at_risk minus insured -> lost; returns the lost ids
```
JSON:
```json
{"version": 1, "pilot": "IRONSIDE", "credits": 1240, "active_slot": 0,
 "unlocks": ["armor/tribes2:MEDIUM", "weapon/tribes:DISC", "ammo/tribes:DISC", "vehicle/es1:BULLDOG"],
 "lost": ["skin/tribes2:male_medium#red"], "at_risk": [],
 "slots": [{"index": 0, "label": "Slot 1", "pack": "tribes", "armor": "tribes:MEDIUM", "body": "", "skin": "",
            "vehicle": "es1:RAPTOR", "herc_skin": "",
            "infantry": {"weapons": ["tribes:DISC", "tribes:CHAINGUN"], "ammo": {"tribes:DISC": 15}, "gear": {"tribes:GRENADE": 5}, "pack": ""},
            "herc_loadout": ["es1:LASER", "es1:AUTOCANNON"]}, {...}, {...}],
 "stats": {"matches": 12, "earned": 6100, "spent": 4860, "unlocks_lost": 1, "bought_back": 1},
 "migrated": ["loadout_presets", "player_settings", "extraction_v2"]}
```
Migration (`OperatorProfile.apply_migrations`, once, recorded in `migrated`): old `LoadoutPresets` files fill slots
1..3 (first herc preset -> vehicle + loadout, first infantry preset -> armour/body/skin; extra presets stay on disk,
untouched); `PlayerProfile` armour/body/skin/herc skins -> slot 1 when no preset; `ExtractionProfile` v2 money ->
credits, `armor/x` stash stacks -> `armor/x` unlocks, `callin/v` stash stacks -> `vehicle/v` unlocks (then removed from
the stash). Everything migrated is *kept as owned* even if its price would now be higher.

### 2.5 `EconomyRules` and `economy_rules.json`

`EconomyRules` (`engine/economy/economy_rules.gd`, same shape as `ExtractionRules`: `data()`, `reload()`, typed
getters) loads `engine/economy/economy_rules.json` (design numbers, tunable, remake values):

```json
{"version": 1, "currency": "cr", "slot_count": 3, "start_credits": 1000,
 "rebuy_price": 100, "rebuy_kinds": ["armor", "body", "skin", "vehicle", "herc_skin"],
 "unlock_multiplier": {"weapon": 2.0, "herc_weapon": 2.0, "ammo": 1.0, "gear": 2.0, "pack": 2.0,
                       "armor": 2.0, "vehicle": 1.5, "body": 1.0, "skin": 1.0, "herc_skin": 1.0},
 "flat_base_price": {"skin": 250, "herc_skin": 250, "body": 900},
 "price_source": "ExtractionItems.make_price (ratings from CombatRating / Packs.combat_rating) for weapon, ammo, gear, pack, armor, vehicle",
 "free_unlocks": {"armor": ["tribes:LIGHT", "tribes:MEDIUM", "tribes:HEAVY"], "default_skin_and_body": true,
                  "default_loadout_weapons": true, "weapons": ["tribes:BLASTER"], "starter_vehicle_per_pack": true},
 "goals": {"max_individual": 3, "max_team": 3, "board_size": 6},
 "earn": {
   "min_match_s": 60, "left_early_factor": 0.5, "bot_kill_factor": 0.5,
   "modes": {
     "solo":            {"per_minute": 0, "per_kill": 0, "per_vehicle_kill": 0, "per_assist": 0, "per_objective": 0, "win_bonus": 0, "loss_bonus": 0, "cap": 0},
     "vs.deathmatch":   {"per_minute": 4, "per_kill": 20, "per_vehicle_kill": 40, "per_assist": 8, "per_objective": 0,  "win_bonus": 150, "loss_bonus": 40, "cap": 1500},
     "vs.team_deathmatch": {"per_minute": 4, "per_kill": 16, "per_vehicle_kill": 40, "per_assist": 8, "per_objective": 0, "win_bonus": 200, "loss_bonus": 60, "cap": 1500},
     "vs.ctf":          {"per_minute": 5, "per_kill": 12, "per_vehicle_kill": 40, "per_assist": 8, "per_objective": 120, "win_bonus": 250, "loss_bonus": 80, "cap": 2000},
     "vs":              {"per_minute": 4, "per_kill": 15, "per_vehicle_kill": 40, "per_assist": 8, "per_objective": 80, "win_bonus": 200, "loss_bonus": 60, "cap": 1500},
     "coop":            {"per_minute": 5, "per_kill": 18, "per_vehicle_kill": 45, "per_assist": 8, "per_objective": 100, "win_bonus": 300, "loss_bonus": 60, "cap": 2000},
     "campaign.coop":   {"per_minute": 5, "per_kill": 15, "per_vehicle_kill": 40, "per_assist": 8, "per_objective": 150, "win_bonus": 400, "loss_bonus": 80, "cap": 2500},
     "extraction":      {"per_minute": 0, "per_kill": 0,  "per_vehicle_kill": 0,  "per_assist": 0, "per_objective": 0,   "win_bonus": 0,   "loss_bonus": 0,  "on_extract": 150, "cap": 0}
   }},
 "tooltips": {"not_allowed": "Not allowed in this mode: %s", "lost": "Lost in a raid - buy back for %d cr"}}
```
Lookup key `EconomyRules.make_mode_key(settings)`: `"<mode>.<game_mode>"` -> `"<mode>"` -> `"vs"`; campaign: `"campaign.coop"`
(solo campaign = `"solo"`). A missing key never errors: it falls back and `push_warning`s once. Extraction's money is
**not** a rate: what the raid carries out (loot value, money, task rewards) is paid on extraction as today and goes
straight into `credits`; `on_extract` is a flat bonus. Cap 0 = no cap. Bot kills pay `bot_kill_factor`.

### 2.6 Store, validation, ledger, goals (all pure, `make_` queries)

```
class_name StoreCatalog              # engine/economy/store_catalog.gd
static func make_categories(ctx: LoadoutContext) -> Array      # [{id, label}] weapons, ammo, gear, packs, armour, models, skins, vehicles
static func make_entries(filter: Dictionary, ctx: LoadoutContext, profile: OperatorProfile) -> Array
   # filter {category, pack, text, owned_only, fits_slot (row key), allowed_only, sort}
   # entry {id, kind, name, pack, state: "free"|"owned"|"lost"|"for_sale"|"not_allowed",
   #        price, reason, detail, tooltip_lines: [String], kg, slots, shape_id, skin_ids}
static func make_price(id: String, state: String) -> int      # lost -> rebuy_price; for_sale -> unlock price
class_name StoreService
static func apply_buy(profile: OperatorProfile, id: String) -> Dictionary     # {ok, text}
static func apply_rebuy(profile: OperatorProfile, id: String) -> Dictionary   # extraction rebuy of a lost unlock
class_name LoadoutContext            # engine/economy/loadout_context.gd
var mode_key := ""; var family := ""; var pack := ""         # match infantry game
var source := "owned"                # "owned" (MP) | "garage" (campaign) | "stash" (extraction) | "bot" (ownership ignored)
var availability := {}               # CampaignAvailability context
var store_enabled := true            # false in campaign
var loss_on_death := false           # true only in extraction
static func make_for(settings: Dictionary, role := "player") -> LoadoutContext
func make_block_reason(id: String) -> String                 # "" = allowed here
class_name LoadoutLayout             # engine/economy/loadout_layout.gd
static func make_rows(side: String, slot: CharacterSlot, ctx: LoadoutContext) -> Array   # side "infantry"|"vehicle"
   # row {key, kind: "armour"|"weapon"|"ammo"|"gear"|"pack"|"hardpoint"|"skin", label, accepts: mask or kind,
   #      current: id, ammo: int, ammo_max: int, locked: bool}
static func make_fit(side: String, slot: CharacterSlot) -> Dictionary   # {slots, slots_max, kg, kg_max, ok}
static func apply_set(slot: CharacterSlot, row_key: String, id: String) -> bool   # false when it does not fit
static func apply_clear(slot: CharacterSlot, row_key: String) -> void
class_name CreditsLedger             # engine/economy/credits_ledger.gd
static func make_award(mode_key: String, stats: Dictionary, goals_done: Array, left_early: bool) -> Dictionary
   # {total, lines: [{text, amount}]}  stats = {seconds, kills, bot_kills, vehicle_kills, assists, objectives, won, extracted_value}
class_name GoalBoard                 # engine/economy/goal_board.gd
static func make_board(mode_key: String, seed_value: int) -> Array          # [{id, scope: "individual"|"team", kind, text, count, reward}]
static func make_progress(goal: Dictionary, stats: Dictionary) -> int
static func make_team_goals(picks_by_peer: Dictionary) -> Array             # the squad's nominations merged (section 5.4)
class_name ProfileAuthority          # engine/economy/profile_authority.gd, LocalProfileAuthority is the only impl now
func make_profile(peer: int) -> OperatorProfile ; func apply_award(peer: int, award: Dictionary) -> void
```
Armour slot fit uses the armour record (`max_weapons`, `weapons`, `ammo`, `default_loadout`) and extraction's
`capacity` (slots/kg) in the stock layer; vehicle rows use `WeaponFit.hardpoint_masks`, `WeaponFit.fits_bay`,
`PackVehicleLoader.has_fixed_loadout` (fixed-loadout vehicles show read-only rows).

## 3. Data flow and ownership of truth

```
OperatorProfile (disk, per name) --active slot--> CharacterSlot --LoadoutContext--> resolved build
   resolved build --Net.set_my_infos--> roster entry (key "slot" + legacy keys) --host RosterValidator--> battle config
battle result --CreditsLedger (host)--> EconomyNet RPC to the owner --OperatorProfile.apply_award + save
```
The battle reads the same roster keys as today (`vehicle`, `loadout`, `infantry_armor`, `infantry_body`,
`infantry_skin`, `herc_skin`, extraction `kit`), written by `CharacterSlot.make_roster_fields`, so battle code is
untouched.

## 4. Extraction reconciled

### 4.1 What is at risk, what is kept

| thing | free item | paid unlock |
|---|---|---|
| model (armour class + body), skin | never at risk | at risk from raid start if worn by the slot; moves to `lost` on death |
| preferred vehicle | never at risk | at risk once **called in** (host tells the owner: `apply_commit_risk([vehicle id])`); lost on death |
| weapons, ammo, gear, pack | kit stock, as today (lost with the kit, insured slot applies) | n/a: raids use stock, not unlocks |
| credits, other unlocks | never at risk | never at risk |

Flow: lobby -> `ExtractionProfile.apply_commit_kit()` (existing) **and** `OperatorProfile.apply_commit_risk(worn paid
unlock ids)`, saved immediately (leaving mid-raid = death: the risk stays in `at_risk` and is resolved as lost at the
next load, as the kit is lost today). Extraction result -> `apply_raid_survived()`. Death result ->
`apply_raid_lost(insured_unlock_ids)` returns the lost ids; KIA banner and results list them with "Buy back 100 cr".
A lost unlock stays visible in the store (`state: "lost"`); slots that referenced it fall back to the free default in
`make_resolved` (the saved slot still names it so a buy-back restores the look).

**Insured slot** (existing rule, extended): the one insured slot may also hold one at-risk unlock id (`insured =
["skin/...", 1]`; `ExtractionProfile.apply_insure` accepts `UnlockId` kinds armor/body/skin/vehicle). Dropping it
from the worn slot = not insured, as for kit items. `make_insured_split` keeps its meaning; the host forwards insured
unlock ids to the owner with the death result.

### 4.2 Changes to existing extraction code (owned by chunk 1 unless noted)

- `ExtractionProfile` -> VERSION 3: drops `money` (wallet = `OperatorProfile.credits`); `apply_extracted(stacks, money)`
  keeps the signature but the money goes to the wallet through `OperatorProfile.apply_award`. `armor/` stash handling
  (`make_wearable_armors`, `apply_kit_armor`) reads `Unlocks` instead of the stash; the kit's `kit_armor` is the active
  slot's armour. `_apply_migration_v2()` does the conversions in 2.4.
- `ExtractionItems`: kinds `armor` and `callin` removed from `KINDS`; `ExtractionShop.BUY_CATEGORIES` loses them.
  Prices still come from `ExtractionItems.make_price` (the economy reuses them as bases).
- `extraction_rules.json` keys `start_money`, `item_kinds.callin`, `item_kinds.armor.price_by_size` are deleted (ExtractionItems, ExtractionProfile read the economy_rules values)
  (code stops reading them); the file itself is edited only by chunk 4 (adds `raid_points`, `callins`) and chunk 5
  (deletes the dead keys).
- Task board: `RaidTaskBoard` unchanged; shown as individual goals; `tasks.max_picked` -> 3 (chunk 4 edits the JSON).

## 5. The standard lobby screen

One screen id `lobby` (`engine/ui/screens/lobby_screen.gd`, rewritten) for every mode. Solo play uses an **offline
local session** (`Net.host_offline()`, a public wrapper of `_host_local`, roster has peer 1 only): skirmish,
single-player campaign, solo extraction. The lobby code never branches on "online" except to hide the chat strip and
the squad list when the roster has one entry. Composed of widgets in `engine/ui/lobby/` (chunk 3):

| widget | role |
|---|---|
| `GameOptionsPanel` | left top. Host: Game Mode (`CatalogBridge.make_game_modes`), Map Selection (`MapPicker`), Options (limits, bots, AI units, balance, infantry pack, relations preset, password), Adjust Teams (opens a `ConfirmDialog`-style sheet hosting the existing `TeamList`; hidden in campaign and extraction-without-squads). Non-host: the same rows via `OptionRow.make_readonly(label, text)` (a label, not a control). Campaign adds host buttons Save game and Hangar. Extraction adds Faction relations, Squads on/off. |
| `OperatorSetupBlock` | left bottom. Name row (`NameRow`), the active slot's name, credits (`CreditsBadge`), a summary line, the **Operator Setup** button which opens the loadout popup (`OperatorSetup.open`, chunk 2). |
| `TeamCarousel` | centre. `OperatorCard`s in a horizontal carousel (own card in front/centre, squadmates and bot slots beside it). |
| `SquadList` | centre-bottom, compact rows for everybody not in your squad (virtualised `Tree`, grouped by team). |
| `LobbyChatStrip` | below the centre. |
| `TaskListPane` | right. Chooses Option A (goals) or Option B (campaign briefing) by `BriefingSource.make_kind(settings)`. |
| `ReadyBar` | footer primary + the warning flow. |

### 5.1 Desktop wireframe (content >= 1100 px; title bar and footer are `ScreenFrame`'s)

```
+------------------------------------------------------------------------------------------------------+
| LOBBY   Capture the Flag - Raindance - 2 teams                          CR 1,240      7 / 24 pilots    |
+----------------------------+---------------------------------------------+---------------------------+
| GAME OPTIONS (host only)   |  TEAM CAROUSEL                              | TASK LIST                 |
|  Game Mode  [ CTF       v] |                                             |  YOUR GOALS (pick 3)      |
|  Map        [ Raindance v] |   +-------+   +===========+   +-------+     |  [x] Capture 2 flags  120 |
|  Options    [ Edit...    ] |   | Bot 1 |   | IRONSIDE  |   | Kira  |     |  [x] 10 kills          80 |
|  Teams      [ Adjust...  ] |   |  [ ]  |   | infantry  |   | ready |     |  [ ] Defend 3 min      60 |
|  (campaign: Save / Hangar) |   |       |   | [3D card] |   |   [v] |     |  [ ] Destroy generator 90 |
|                            |   +-------+   | vehicle   |   +-------+     |  TEAMMATES' GOALS (pick 3)|
|  read-only for players     |    < prev     | [3D card] |     next >      |  [x] Hold the flag 2 min  |
|                            |               |  READY [v]|                 |  [ ] Win without losing   |
+----------------------------+               +===========+                 |  [ ] No vehicle losses    |
| OPERATOR SETUP             |   Squad: Red   (3/4)   * dots = pages       |                           |
|  Name [IRONSIDE        ]   +---------------------------------------------+  squad picks: 5 votes     |
|  Slot 1 "Vanguard"         |  OTHERS (compact)            filter [      ] |                           |
|  Medium / Raptor / 2 wpn   |   Team Blue                                 |                           |
|  CR 1,240                  |   v  Kira       Scout    ready   32 ms       |                           |
|  [ OPERATOR SETUP...     ] |   x  Dune       Heavy    --      41 ms       |                           |
|                            |  (64 players: scroll, 28 px rows)           |                           |
+----------------------------+---------------------------------------------+---------------------------+
| chat: [Kira] gg ready?                                   [ type here (Enter) ]                       |
+------------------------------------------------------------------------------------------------------+
| status: Waiting for Dune to be ready.                     [ Leave ]                  [ START MATCH ] |
+------------------------------------------------------------------------------------------------------+
```
Campaign (Option B) replaces the right pane:
```
| TASK LIST / MISSION BRIEFING             |
|  +------------------------------------+  |
|  | general / leader video   [> skip]  |  |   only when CampaignPresentation.make_movies() has clips
|  +------------------------------------+  |
|  | mission map (top-down)             |  |   only when Session.briefing_map() returns a texture
|  +------------------------------------+  |
|  Campaign 2 - mission 3                  |
|  <briefing text, scrollable>             |
|  Objectives: - ...                       |
```

### 5.2 Narrow wireframe (content < 900 px: phone, web, small window; width constant `Siege/narrow_width`)

```
+--------------------------------------+
| LOBBY  CTF - Raindance    CR 1,240   |
| [ Options ] [ Squad ] [ Tasks ] [Chat]|   tab bar (pad LB / RB), one pane at a time
+--------------------------------------+
|  SQUAD (own squad cards, swipe/left-right)
|  +--------------------------------+  |
|  | IRONSIDE       infantry card   |  |
|  | Medium - Disc, Chaingun        |  |
|  | vehicle card: Raptor           |  |
|  | READY [v]                      |  |
|  +--------------------------------+  |
|  < Bot 1 | IRONSIDE | Kira >          |
|  [ OPERATOR SETUP... ]               |
|  Others (7)  v   (collapsed list)    |
+--------------------------------------+
| [ Leave ]                  [ READY ] |
+--------------------------------------+
```
Options tab = Game Options (read-only for non-hosts); Tasks tab = Option A or B; Chat tab = strip expanded. The
Operator Setup button sits on the Squad tab.

### 5.3 Ready, warnings, large lobbies

- Each `OperatorCard` shows: pilot name, team colour bar, infantry card (armour thumbnail, main weapons), vehicle
  card (thumbnail, name), ready tick, ping. Host card is always ready (as `LobbyText` today).
- **Disallowed-items warning before ready-up:** Ready/Start runs `CharacterSlot.make_blocks(ctx)`. A non-empty list opens
  a modal ("These parts are not allowed here and will be left off: ...") with `Ready anyway` (the match uses
  `make_resolved`) and `Open Operator Setup`. Replaces `LoadoutPresets.ask_dropped`. The warning also lists unowned
  parts (possible after a pack change). When the host changes mode/map, `MatchFlow.apply_revalidate_ready()` clears
  `ready` for pilots whose block list changed.
- The host validates every roster entry again at start (`RosterValidator.apply`, chunk 1): strips disallowed parts,
  logs `NetLog "loadout_stripped"`, never blocks the start.
- Many players: the pilot's **own squad** = same team (or the extraction squad; free-for-all = just you) as cards in the
  carousel; everyone else in `SquadList`, a `Tree` with 28 px rows (name, class icon, ready dot, ping), grouped by
  team, filter box, keyboard type-ahead. No per-player widgets are created for rows off-screen.
- Roster sync cost: `Net._push_roster` rebroadcasts the whole roster per change (O(n^2) at 64). Chunk 1 adds
  `Net.set_my_infos(dict)` (one RPC, one push) and coalesces pushes to one per 0.2 s while in the lobby. The `slot`
  snapshot is about 250 bytes.

### 5.4 Task List (Option A)

Two lists, up to 3 picks each (`goals.max_individual`, `goals.max_team`):
- **Individual missions/goals:** `GoalBoard.make_board(mode_key, seed)` (extraction: the existing `RaidTaskBoard`
  tasks). Picks are stored in the roster (`goals`: ids), rewards paid to the picker (credits, via the ledger; extraction
  tasks pay on extraction, as today).
- **Teammates' missions/goals:** goals the player nominates for the squad. The squad's nominations are merged by
  `GoalBoard.make_team_goals` (the 3 with the most votes, ties by id); all squad members see them, completing one pays
  every member. Free-for-all modes have no team list (pane section hidden).
- v1 evaluates goals from the end-of-match stats (`kills`, `vehicle_kills`, `objectives`, `survived`, `flag_captures`)
  except extraction tasks, which are live (`RaidTasks`). The board is generated by the host (seed in `Net.settings`)
  so everyone sees the same list; a host-only "Reroll" button.

### 5.5 Gamepad / keyboard equivalents

Zones in the lobby: Game Options, Operator Setup block, Carousel, Others list, Task List, Chat, Footer. `ui_*` moves
inside a zone; `menu_zone_next/prev` jumps zones; `menu_tab_prev/next` flips the carousel card or the narrow tabs;
`menu_primary` presses the footer primary (Ready/Start). Chat opens with `chat_all` (lobby context). New actions in
section 7 of this table below.

### 5.6 Menu map changes

`Host` screen disappears: "Host LAN game" creates the lobby with default settings at once and the host edits them in
Game Options. "Arena / versus", "Skirmish", "New campaign", "Continue campaign", "Co-op missions", "Extraction raid"
all open `lobby` with `{kind: ...}` (section 10). Back = `Leave` (ends the session, returns to the page that opened it).

## 6. The standard loadout screen: Operator Setup

`OperatorSetup` (chunk 2, `engine/ui/operator/operator_setup.gd`) is a full-screen modal sheet (`ModalPanel`) over the
lobby, opened by `OperatorSetup.open(parent: Control, ctx: LoadoutContext, slot_index: int) -> OperatorSetup` with
signal `closed(changed: bool)`. Edits go to the `OperatorProfile` and are saved on every change; closing re-announces
the slot (lobby does it on `closed`). `menu_back` closes. The same screen is used in every mode; `LoadoutContext`
decides what the left list and the store show:

| `ctx.source` | mode | left list | store |
|---|---|---|---|
| `owned` | versus, co-op, extraction-less MP | slots filled from owned unlocks | unlock store (credits) |
| `garage` | campaign, co-op campaign | the campaign garage's Hercs, stock counts (`CampaignAvailability`) | hidden (`store_enabled=false`); a "Hangar" button for fabricate/repair |
| `stash` | extraction | kit from stash (`ExtractionProfile`), a third tab STASH, insured slot row | stock shop (existing prices) + unlock store for model/skin/vehicle |
| `bot` | host editing a bot card | any allowed item | hidden |

### 6.1 Desktop wireframe

```
+-- OPERATOR SETUP -------------------------------------------------------------------------------------+
| [ Slot 1 Vanguard* ] [ Slot 2 Scout ] [ Slot 3 (new) ]                              CR 1,240   [Close] |
+--------------------------+------------------------------------+--------------------------------------+
| LOADOUT        [Inf|Veh] | ARMOUR                             | STORE                                |
| Armour: Medium  (fixed)  |  +------------------------------+  | [Weapons][Ammo][Gear][Packs][Skins]..|
| Fit: 2/3 weapons  41/50kg|  |   3D: medium armour          |  | Pack [All v]  Search [      ]        |
|--------------------------|  |   (orbit: drag / right stick)|  | [ ] Owned  [ ] Fits slot  [x] Allowed|
| WEAPONS                  |  +------------------------------+  |------------------------------------- |
|  1. Spinfusor    [T1]    |  LAST: Chaingun [T1]               |  Plasma Gun      [T2]     owned      |
|     ammo 15/15  [-][+]   |  dmg 18  rof 10/s  range 140 m     |  Mortar         [T1]  3,000 cr  BUY  |
|  2. Chaingun     [T1]    |  3.1 kg - 1 slot - allowed         |  Laser Rifle    [T1]  NOT ALLOWED    |
|     ammo 100/100         |                                    |    (light armour only)               |
|  3. (empty)  pick from   |                                    |  Grenade        [T1]  free           |
|     the store            |  [ INFANTRY ]   [ VEHICLE ]        |  ...                                 |
| GEAR                     |   centre bottom: switch side       |  +-- tooltip (on hover / focus) ----+   |
|  Grenades 5/5   Mine 3/3 |                                    |  | Mortar - Tribes 1 - 8 kg          |  |
|  Repair kit  - (none)    |                                    |  | dmg 130 splash 8 m  rof 0.4/s    |  |
| PACK  Energy pack        |                                    |  | Price 3,000 cr (first purchase)   |  |
| (right click / pad X =   |                                    |  | Not allowed: medium armour only   |  |
|  remove)                 |                                    |  +-----------------------------------+  |
|                          |                                    |--------------------------------------|
|                          |                                    | LOOK                                 |
|                          |                                    | Model [Light][Medium*][Heavy][Bioderm]|
|                          |                                    | Skin  [def][red][camo][lock 250]     |
|                          |                                    | Vehicle [Raptor v] skin [def v]      |
+--------------------------+------------------------------------+--------------------------------------+
| status: Mortar needs medium or heavy armour.                    [ Back ]                  [ DONE ]  |
+---------------------------------------------------------------------------------------------------- +
```
- **Left (scrollable):** header with the side switch and a fit bar (slots used / max, kg used / max, red when over);
  then every row `LoadoutLayout.make_rows` returns for that armour or vehicle: armour (fixed), each weapon slot
  followed by its ammo row, grenades/mines/repair kit rows, pack, and for the vehicle each hardpoint with its mask
  ("medium mount"), its weapon and ammo, fixed-loadout vehicles read-only. Empty rows say "(empty - pick from the
  store)". Selecting a row filters the store with `fits_slot`. **Remove: right click / `menu_secondary` (pad X)** on
  a row; `menu_secondary` on an empty row does nothing. Rows carry badges: `NOT ALLOWED` (red, with the reason),
  `AT RISK` (extraction, section 4), `LOST - 100 cr` for a lost unlock.
- **Centre top:** the infantry armour in the existing `HangarView` (3D, orbit/zoom actions) when the side is infantry
  (the vehicle when the side is vehicle), and below it a card for the **last weapon added or hovered** (name, game,
  stats from `CombatRating`, weight, slot cost, allowed / not allowed). Hover or focus updates it.
- **Centre bottom:** two large buttons INFANTRY / VEHICLE (the side switch; `menu_switch_kind`).
- **Right top:** the store. Filters: category tabs (weapons, ammo, gear, packs, armour, models, skins, vehicles ...),
  game (pack) dropdown, text search, toggles Owned / Fits slot / Allowed in this mode, sort (name, price, rating).
  Entry states: `free`, `owned` (click equips), `for_sale` (click opens "Buy for N cr?" then equips), `lost` ("Buy back
  100 cr", extraction only), `not_allowed` (greyed, reason). `ItemTooltip` shows on hover (mouse) or focus (after 0.4 s;
  `menu_info` pins it for gamepad). Packs of games that are not installed are not listed (section 8).
- **Right bottom:** Look: Model (armour class + body, e.g. Tribes 2 Bioderm), Skin (`CatalogBridge.make_skins`), Vehicle
  picker (vehicles you own; `source=garage`: the campaign garage), Herc skin. Locked entries show the price; bought
  with credits earned in games.
- **Top tabs:** the 3 character slots (`OperatorProfile.slots`), each a full config. `menu_tab_prev/next` (pad LB/RB)
  switches slots; a new slot starts as the free default; slot label editable (`menu_secondary` on the tab renames).
  Switching the active slot re-announces to the lobby on close.
- **Credits** always at the top right (`CreditsBadge`, also on the lobby and results screens).
- **Fit/weight indicators:** the left header bar and every store entry's "slots/kg" with a red "does not fit" when the
  current armour cannot take it (`LoadoutLayout.apply_set` false -> status line says why).

Extraction extras: the side switch has a third tab STASH (move kit <-> stash, existing `ExtractionProfile` calls); a row
"Insured slot" (pick one kit stack or one worn paid unlock); a banner "Model, skin and a called-in vehicle are lost if
you die (re-buy 100 cr)"; the store has an extra category "Supplies" (the old shop: ammo loads, gear, weapons as
stock). Raid tasks are not here (they are in the lobby Task List).

### 6.2 Narrow wireframe

```
+--------------------------------------+
| [Slot 1*][Slot 2][Slot 3]   CR 1,240 |   scroll horizontally if needed
| [ Loadout ] [ Store ] [ Look ]       |   tabs (pad LB/RB when focus is on the tab bar)
+--------------------------------------+
| ARMOUR  3D (collapsible, 140 px)     |
| last: Chaingun - 3.1 kg - allowed    |
| [ INFANTRY ] [ VEHICLE ]             |
|--------------------------------------|
| Fit 2/3  41/50 kg                    |
| 1. Spinfusor  ammo 15/15       [ x ] |   x = remove button (no right click on touch)
| 2. Chaingun   ammo 100/100     [ x ] |
| 3. (empty)  -> Store                 |
| ...                                  |
+--------------------------------------+
| [ Back ]                    [ DONE ] |
+--------------------------------------+
```

### 6.3 Gamepad map (Operator Setup)

d-pad / left stick move; A (`ui_accept`) equip / buy; B (`menu_back`) close; **X (`menu_secondary`) remove**; Y (`menu_info`)
pin tooltip; LB/RB (`menu_tab_prev/next`) slot tabs (and store categories when the store has focus); LT/RT
(`menu_zone_prev/next`) jump List / Store / Look; View/Back (`menu_switch_kind`) infantry / vehicle; right stick orbits
the preview; Start (`menu_primary`) = Done.

## 7. Network, roster and the dedicated server

### 7.1 Roster

`Net.ROSTER_KEYS` gains `"slot"`, `"goals"`, `"team_goals"`, `"wingmen"` (chunk 1). `slot` is the compact snapshot of the
resolved build, written by `CharacterSlot.make_roster_snapshot()`:
```json
{"i": 0, "a": "tribes:MEDIUM", "b": "", "s": "", "v": "es1:RAPTOR", "hs": "",
 "w": ["tribes:DISC", "tribes:CHAINGUN"], "am": {"tribes:DISC": 15}, "g": {"tribes:GRENADE": 5}, "p": "",
 "hl": ["es1:LASER", "es1:AUTOCANNON"]}
```
Legacy keys (`vehicle`, `loadout`, `infantry_*`, `herc_skin`, `kit`) are still set from the same data so nothing
downstream changes. `Net.set_my_infos(dict)` sets several keys in one RPC. Host-chosen bot loadouts are in
`Net.settings.bot_loadouts` (`"bot:0"` -> snapshot). Campaign wingmen: `Net.settings.wingmen` = list of
`WingmanSpec` `{index, kind: "infantry"|"vehicle", a, b, s, v, hl, w, skill}`.

### 7.2 Credits

The host computes the award at match end from `MatchResults` stats (kills, vehicle kills, assists, objectives, win,
goals) with `CreditsLedger.make_award` and sends `EconomyNet._award(award)` (reliable, `rpc_id` to the owner). The
owner applies it to his profile, saves, and the results screen shows the lines ("Kills 12 x 16 = 192 ..."). A pilot
who leaves early gets `left_early_factor` of what he had earned (computed at `peer_left`, sent if still connected;
otherwise lost). Extraction: the existing result message (`_raid_result`) carries the money; credits are added there.
Dedicated servers: same flow, the server is the host; it never stores profiles.

### 7.3 Flows per mode (host / client / dedicated)

| mode | entry | lobby pane | Operator Setup source | start | after the match |
|---|---|---|---|---|---|
| single-player campaign | New/Continue campaign -> offline lobby `{kind: campaign}` | Option B; host buttons Save, Hangar; carousel = wingmen | garage | Start mission (replaces Launch) | Debrief -> lobby (next mission) |
| co-op campaign, host | Host -> lobby `{campaign}`; host's campaign offer published (`MatchFlow.publish_campaign_offer`) | Option B | garage (own Herc from the host's garage copy for clients: `source=garage` fed by the offer) | Start mission when all ready | Results -> debrief -> lobby |
| co-op campaign, client | Join -> lobby | Option B read-only options | garage from the offer | Ready | same |
| co-op vs Cybrids | host/join | Option A (team goals) | owned | Start match | Results -> lobby; credits `coop` |
| versus (any game mode), host | "Arena / versus" or Host LAN -> lobby `{vs}` | Option A | owned | Start match (all ready, teams set) | Results -> lobby |
| versus, client | Join | Option A, options read-only | owned | Ready | same |
| skirmish | Skirmish -> offline lobby `{vs, bots}` | Option A hidden (no goals), carousel = bots | owned | Start | back to lobby; credits `solo` = 0 |
| extraction, solo | Extraction -> offline lobby `{extraction}` | Option A: raid tasks + team goals hidden | stash | Start raid | stash/KIA via Results; lobby |
| extraction, LAN host/client | host/join | Option A (tasks), squads optional | stash | Start raid | same |
| dedicated server (any mode) | server config creates settings; clients Join | options read-only for everyone; server auto-starts (`_tick_lobby`) and auto-assigns teams | as per mode | timer or all ready | server loops lobby -> match -> results |

## 8. Missing packs and per-name profiles

- Unlock ids carry their pack. Entries whose pack is not installed (`Assets.has_pack`) are **hidden** from the store,
  the Look pickers, the slot preview and the ledger totals, but stay in `OperatorProfile.unlocks` untouched; they come
  back when the pack is installed. Operator Setup footnote: "N unlocks need games that are not installed".
- A slot that names a hidden or lost part is resolved to the free default for that run only; the saved slot is not
  edited (`make_resolved`), so installing the pack restores the build.
- Credits are global to the profile; mode rules decide what may be used (`LoadoutContext`), not where it was bought.
- Profile file per player name as today; changing the name in `NameRow` loads that name's `OperatorProfile`.

## 9. Extraction call-ins (raid points)

New folder `engine/extraction/callin/` (chunk 4). The existing flying transports (`ExtractionTransports`,
`TransportFlight`; AI-only, untouchable (`protection`), ignored by the AI via meta `dormant`) and Tribes deployables
(`TribesDeployables`, `TribesBase.add_deployed`, `TribesStations`) are reused. All numbers in
`extraction_rules.json` (`raid_points`, `callins`), no game data.

### 9.1 Raid points

`RaidPoints` (host node, child of `ExtractionDirector`): per-peer balance, sent to the owner only (`rpc_id`), shown by
`ExtractionHud` ("RP 340"). Not persistent; unspent RP at extraction convert at `raid_points.unspent_to_credits`
(0.25), lost on death (`lose_on_death`). Earned by host-observed events:

```json
"raid_points": {"kill_infantry": 20, "kill_vehicle": 60, "kill_player": 80, "assist": 8, "task_divisor": 10,
  "objective_generator": 150, "objective_flag": 200, "revive": 40, "difficulty_scaled": true,
  "max_balance": 1500, "lose_on_death": true, "unspent_to_credits": 0.25}
```
Kills scale by the victim faction's `tasks.difficulty` (cybrid 1.6, bioderm 1.3, human 1.0); a task pays its reward /
`task_divisor` RP when done (the existing `RaidTasks.on_unit_destroyed` and task completion call `RaidPoints.apply_add`).

### 9.2 Call-in catalogue (costs RP, cooldown per player, caps per raid)

| id | what | cost | cooldown | cap | notes |
|---|---|---|---|---|---|
| `vehicle_delivery` | the active slot's preferred vehicle is flown in and set down at the player's spot | by class: light 400, medium 700, heavy 1100, flyer 900 | 300 s | 2 | owned vehicle required, not lost; first use puts it at risk (section 4) |
| `armor_drop` | orbital pod with a temporary armour (light/medium/heavy of the match's infantry game) | 150 / 300 / 500 | 180 s | 3 | pod crate; `interact` swaps into the armour for `temp_armor_s` (300 s) keeping the kit; reverts on expiry; never enters bags |
| `ammo_drop` | orbital pod: refills ammo of all carried weapons to the armour maximum | 120 | 90 s | 6 | 3 uses per pod |
| `repair_station` | temporary repair station | 250 | 240 s | 2 | heals vehicles, armour and health in 6 m for `ttl_s` 120 |
| `inventory_station` | temporary inventory station (opens `StationShopPanel`; refill rules as raid stations) | 350 | 300 s | 1 | `ttl_s` 150; same raid rule: no free gear |
| `radar_sweep` | shows hostile units within 300 m on the caller's radar | 150 | 120 s | 4 | 20 s, loud (alerts, 9.5) |
| `bombing_run` | a bomber (Tribes 2 Thundersword, else the best installed bomber / flyer, else the plain flyer) flies in along the designated line and drops a stick of bombs | 450 | 240 s | 2 | `CallinRequest` with a point and a direction; catalog bombs (shared projectile system, caller credited); allies near the line get "danger close" `warn_lead_s` before the first release; the bomber is untouchable, shows on radar |
| `attack_craft` | an AI gunship (Tribes 2 Shrike, else the strongest armed flyer) flies to the point and strafes hostiles within `engage_radius_m` for `loiter_s` | 500 | 300 s | 2 | a real vehicle: hostile AI targets it, it can be shot down (it crashes); leaves when its time or its rounds are gone; its kills credit the caller |

`callin_rules` JSON per entry: `{cost, cooldown_s, max_per_raid, ttl_s, shapes: [...], lz: {...}}`. `shapes` are
candidate shape ids tried in order and the first imported is used (as caches do); the implementer verifies them with
`tests/catalog_dump.gd` against the installed packs (e.g. the Tribes 2 inventory station shape and the existing
cargo-box shapes for pods). Global: `shared_cooldown_s` 20, `max_active_orders` 2 per player, `order_timeout_s` 90
(then refund 100% RP).

### 9.3 Requesting (client -> host)

Every call-in is a **`CallinRequest`** value (`callin_request.gd`): `kind`, `variant` (armour size), caller `peer`, `point`,
`direction` (flat; zero = the way the caller faces), `source` (`"laser"` | `"map"`). There are two ways to make one, both
through the same host validation; a runner (`CallinDirector.register_runner(kind, start, refuse)`) is handed a validated
request and never picks its own point.

**Targeting Laser (`CallinDesignator`).** `callin_menu` (section 11) opens `CallinMenu` and raises the Tribes 2 Targeting
Laser with it (`CallinLaser`: the beam bitmap and colour of the installed Tribes 2 laser rifle, `generic_switch` and
`targetinglaser_paint` sounds when extracted; a plain red beam and the default pack's lock cues otherwise). Picking a row
closes the menu and the player aims; the laser paints where he looks with the verdict live on the spot: a green dot and
footprint ring, or red with the reason in words (out of range, under cover / inside a building, too steep, something in the
way, a unit there, enemy ground, outside the area, no line of sight to the approach, another call-in already there, or any
refusal below). **Fire** designates a green spot; a kind that flies a line (`designation.direction`, the bombing run) takes a
second fire for the direction (a click within 4 m of the first leaves it to the caller's facing). `menu_back`, the alt-fire
(`jet` / `fire_group_2`) or `callin_menu` cancels. The weapon in hand does not fire while the laser is up. Teammates see the
dot (`CallinLaserSync`: painter -> host unreliable at 10 Hz, host -> raid players of his side, name tag, 1.5 s timeout).

**Command map.** In a raid the side list of the command map has the call-ins (`CommandMapCallins`): pick one, click the
point (and the direction for directional kinds); the cursor spot is judged live (green/red ring, the reason in the status
line). Right click, `menu_back` or picking the same row again cancels. Source `"map"` has no laser reach limit.

Both send `_request_callin(kind, variant, point, direction, source)` (reliable, any_peer -> host). The host's
`CallinChecks.make_plan(request)` returns `{ok, pos, reason}`: the facts (not in the raid, downed, RP short, cooldown, cap,
too many active orders, vehicle not owned/lost/not installed: `CallinRefusals`), then the designated point
(`CallinPlacement`, below), then the kind's own `refuse` hook. The client runs the same function on the same data for the
live colour. What a kind needs is `callins.kinds.<kind>.designation {ground, sky, approach, direction}` over defaults
(pods: ground + sky; vehicle delivery: + approach; radar sweep: neither), and `callins.designation {range_m 220,
approach_check_m 120}`. Scripts (`request(kind, variant)`, e2e) ask for "near my feet" (`make_feet_request`).

### 9.4 Landing-zone validation (`CallinPlacement` over `CallinSafety`, style of `ExitSafety`)

The designated point is judged exactly (no ring search; the order lands on the floor point under it):
1. reach: the laser paints no farther than `designation.range_m` (220 m) from the eye; on foot only (map: no limit);
2. area: inside `BattleBounds`;
3. open sky: a ray straight up for `sky_clear_m` (80) hits nothing (no roof, bridge, interior) -> "Under cover";
4. footprint: clear disc (vehicle: hull radius + 8; pod: 3), slope <= 25 deg, not liquid (`MapWater`), not on a
   vehicle/soldier, not in a hostile site's `enemy_base_radius_m`, not on another open call-in;
5. approach (vehicle by transport): from above the zone toward the approach point for `approach_check_m` no geometry or
   terrain stands in the way.
The LZ is re-validated 3 s before delivery; it may shift up to `lz_shift_m` (15), else the order is cancelled with a
full RP refund and a message.

### 9.5 Sequences (host drives; `CallinOrder` state machine)

States: `REQUESTED -> MARKED -> INBOUND -> DELIVERING -> ACTIVE -> EXPIRING -> DONE` (any state -> `CANCELLED`).

**Vehicle delivery**
1. `MARKED`: a coloured flare/smoke marker is placed at the LZ (a procedural light + smoke `Effects` fx; visible to
   all within 300 m, to the caller's squad at any range), and an ETA starts. ETA = (flight from `approach_m` out to the
   LZ at the transport's cruise speed) + `prep_s` (8), clamped to [20, 60] s; the HUD shows "VEHICLE INBOUND 0:37".
2. `INBOUND`: `ExtractionTransports.spawn_transport(vid, lz)` with the transport chosen by the cargo
   (`ExtractionTransports.pick_delivery_transport_id`; rules `transport.delivery`): Hercs, Cybrids and heavy vehicles a Starsiege
   dropship (by faction, then side: `cy_drop` for Cybrids), Tribes vehicles and raiders the Havoc / APCs, the other class when a
   pack is missing, from the pool `callins.vehicle_delivery.transport_ids` (empty: a pod); the dropships play Seq01_FLY in
   flight and Seq02_LAND by height (`DropshipAnimation`), AI-piloted
   (`TransportFlight`), `dormant`, untouchable, flies the shared FlightModel to the LZ at cruise height.
3. `DELIVERING`: `TransportFlight` gains a phase `HOVER_DROP`: descend to `hover_height_m` (6) over the LZ, hold, release
   (the vehicle was spawned `parked`, kinematic, slung below the transport via meta `carried_by`, on a sling as long as the vehicle is tall (`CallinVehicleRun.make_sling_m`: its height + 1.5 m under the transport's lowest point, at least `sling_m` (8); a Herc hangs clear of a dropship hull) and released `hover_height_m` above the ground; on
   release it becomes a normal physics body and settles), then `DEPART` to `leave_m` and removal (existing).
4. `ACTIVE`: the vehicle is empty, parked, team = caller's team, `owner_claim_s` (30) boarding priority for the caller
   (after that the usual Tribes touch rule: anyone may take it). `apply_commit_risk([vehicle id])` is sent to the
   owner. Despawn: destroyed (normal wreck salvage), or `abandon_s` (300) with no occupant and no friendly within 150 m
   (then it is recalled: removed, no loss).
5. No transport installed -> falls back to a **drop pod** delivery (9.5 below) for the vehicle, with a longer
   `fall_s`, so the call-in still works on every pack set.

**Orbital drops (armour, ammo, stations)**
1. `MARKED`: flare at the LZ; 6 s countdown (`marker_s`) shown to the caller's squad; red ring on the ground.
2. `INBOUND`: no transport. A pod falls from `drop_height_m` (400) at `fall_speed_mps` (90, about 4.5 s): a visual
   streak plus a siren/whoosh cue for everyone within 400 m. Clients animate from `(t0, lz, fall_s)` in game time (the frames'
   delta, not the wall clock; visual only). The pod falls nose first and swings upright onto its tail in the last
   `flip_height_m` (40) metres (`CallinPodPose`); each shape's nose axis is data (`pod.nose_axes`).
3. `DELIVERING` (impact): host applies `impact_damage` (400) in `impact_radius_m` (3.5) to anything inside (the caller
   too: the ring warns); a crater decal; impact event sent reliably to all.
4. `ACTIVE`: armour/ammo become a `CallinCrate` (a `LootContainer` variant shown with the cargo-box shape; `interact`
   uses it; replicates through the existing container messages). Stations are spawned via `TribesBase.add_deployed`
   (host decides, every peer builds) with the caller's team, `ttl_s`, reduced hit points.
5. `EXPIRING`: last 8 s the object blinks; `DONE`: removed; crater decal fades after 120 s.

### 9.6 Network (host authoritative)

- Request and refusal text: reliable RPC caller <-> host. Balances, cooldown timers: to the owner only.
- Order state: `_callin_state(order)` to the caller and squad (full), to peers within 400 m of the LZ (marker only,
  no owner); sent on every state change and ETA at 2 Hz.
- Transports, vehicles, stations are normal Battle entities (`send_spawn`, snapshots) and deployables (existing sync);
  the pod's fall is time-based and deterministic from the order. The raid has no late join (`Net._register` refuses in
  game), so there is no state replay.
- Owner-side persistence (vehicle at risk) is sent by `rpc_id` and saved by the owner immediately.
- Dedicated server: identical; the server is the host and is the only simulator.

### 9.7 How enemies and AI react

- Every call-in emits a noise event: marker, transport and pod impact have `alert_radius_m` (flare 120, transport 250,
  impact 180, radar_sweep 200). Within it, AI of factions hostile to the caller's team (`TeamRelations.is_hostile`)
  that are awake get an `investigate` order to the LZ (`InfantryBot` `guard_point` squads leave only to fight, so
  guards only turn and face it unless a target appears); `BotSleep.wake_area` wakes sleeping units there.
- Transports stay untouchable and `dormant`; players can attack the delivered vehicle, the pod crate and stations
  (they have hit points; destroying a station/crate is allowed, the owner is not refunded).
- Other players see the flare and hear the cue: a call-in is a tradeoff between supplies and being found.

## 10. Migration of existing screens

| existing | action |
|---|---|
| `ui/screens/lobby_screen.gd`, `lobby_text.gd` | rewritten (the standard lobby); `lobby_settings.gd` kept, extended with the goals/wingmen keys |
| `ui/screens/host_screen.gd` | deleted (Game Options inside the lobby; "Host" menu entries open the lobby) |
| `ui/screens/armory_screen.gd` | deleted (skirmish = offline lobby) |
| `ui/screens/briefing_screen.gd` | deleted (campaign = lobby, Option B). `Save game`, `Hangar`, briefing movies/talks move into the lobby |
| `ui/screens/extraction_screen.gd`, `extraction_screen_text.gd` | deleted / reduced to text helpers used by Operator Setup (stash tab, insured row) |
| `loadout_presets.gd`, `ui/loadout_preset_bar.gd` | replaced by `CharacterSlot`; deleted after migration code reads the old files (reader stays inside `OperatorProfile`) |
| `ui/pilot_picker.gd`, `ui/herc_selector.gd`, `ui/loadout_editor.gd`, `ui/vehicle_picker.gd` | replaced by Operator Setup; deleted when no user remains (`hangar_screen`, `crew_panel`, `hangar_bay`, `weapon_fit` mention them: chunk 5 greps and keeps what Hangar still needs) |
| `ui/garage_picker.gd` | replaced for selection by the `garage` source; stays only if `hangar_screen` needs it |
| `ui/team_list.gd`, `ui/team_assignment.gd` | kept; `TeamList` shown in the Adjust Teams sheet |
| `ui/name_row.gd`, `ui/catalog_bridge.gd`, `ui/objectives_panel.gd` | kept (the panel is the in-battle HUD; the lobby's Task List is a new widget) |
| `ui/screens/new_campaign_screen.gd`, `debrief_screen.gd`, `killed_screen.gd`, `saga_choice_screen.gd` | route to `lobby` instead of `briefing` |
| `launcher_menu.gd`, `library_home.gd`, `launcher.gd` | menu entries re-pointed; `docs/MENU_MAP.md` updated |
| `hangar_screen.gd`, `training_screen.gd`, `options_screen.gd` | kept (Options' pilot section reads/writes the active slot via `OperatorProfile`) |
| `PlayerProfile` | name/infantry pack only; armour/body/skin/herc skin accessors become thin readers of the active slot (removed in chunk 5 when unused) |

`docs/CODING_STANDARDS.md` section 2 gets the new actions, section 3 the new shared widgets (chunk 1B).

## 11. New input actions and theme

Added to the table in `docs/CODING_STANDARDS.md` first, then `SiegeInput`, then `binding_contexts.gd` (context
`menus`; `callin_menu` in `infantry`):

| action | keyboard / mouse | gamepad | meaning |
|---|---|---|---|
| `menu_secondary` | mouse right | X | remove / alternate action on the focused item (rename a tab) |
| `menu_info` | F1 | Y | pin / unpin the detail tooltip of the focused item |
| `menu_tab_prev` / `menu_tab_next` | Ctrl+PgUp / Ctrl+PgDn | LB / RB | slot tabs, pane tabs, carousel cards, store categories |
| `menu_zone_prev` / `menu_zone_next` | Shift+Tab / Tab (Godot focus) | LT / RT | jump between screen zones |
| `menu_switch_kind` | V | View/Back | infantry <-> vehicle |
| `menu_primary` | Ctrl+Enter | Start | press the footer primary action |
| `callin_menu` | L | LB+RB chord | extraction raid: open the call-in menu (`CallinMenu`) |

Theme variations (names in `siege_theme.gd`, no per-screen overrides): `CreditsLabel`, `CardPanel`, `CardPanelSelected`,
`BadgeNotAllowed`, `BadgeAtRisk`, `BadgeLost`, `TabButton`, `ReadyDot`, `Tooltip`. Constant `Siege/narrow_width` = 900.
Shared widgets (all in `engine/ui/`): `CreditsBadge`, `ItemTooltip`, `OperatorCard`, `ModalSheet` (full-screen modal
used by Operator Setup and the dialogs), `OptionRow.make_readonly`.

## 12. Build plan

Parallelism: **1 and 1B first, together** (disjoint files). Then **2, 3, 4 in parallel** (each depends only on the
API of chunk 1 in section 2; chunk 3 and 4 also use the actions/widgets of 1B). **5 last.** Each chunk lists the files
it exclusively owns; nothing else may be edited by it (shared edits are routed through the owner). Do not touch
`bot_sleep.gd`, `server_config.gd` or infantry motion files (another agent works there). Every chunk: `compile_all`
clean, `--import` after adding a `class_name`, tests silent (`--audio-driver Dummy`), and the existing checks listed
stay green.

### Chunk 1 - profile + economy data layer (no UI)
Owns: `engine/economy/*` (all of section 2: `unlock_id.gd`, `unlocks.gd`, `character_slot.gd`, `operator_profile.gd`,
`economy_rules.gd`, `economy_rules.json`, `store_catalog.gd`, `store_service.gd`, `loadout_context.gd`,
`loadout_layout.gd`, `loadout_validator.gd`, `roster_validator.gd`, `credits_ledger.gd`, `goal_board.gd`,
`profile_authority.gd`, `economy_net.gd`); `engine/extraction/extraction_profile.gd`, `extraction_items.gd`,
`extraction_shop.gd` (section 4.2); `engine/net.gd` (additive: `ROSTER_KEYS`, `set_my_infos`, coalesced push,
`host_offline`); `engine/ui/player_profile.gd` (thin readers); `engine/loadout_presets.gd` (only to expose the file
reader for migration). Tests: `tests/economy_data_check.gd/.tscn` (new): rules load; price table; free set; buy/rebuy;
credits math; ledger per mode and caps; slot resolve with a missing pack; migration from fixture files; extraction
risk/lost/insured cycle; hidden-not-lost; roster snapshot round trip; `RosterValidator` strips. Keep green:
`extraction_check`, `compile_all`. API = section 2 (summary in the report).

### Chunk 1B - input actions, theme, shared UI kit
Owns: `engine/input/siege_input.gd`, `binding_contexts.gd`, `engine/ui/siege_theme.gd`, `siege_theme.tres`,
`engine/ui/credits_badge.gd`, `item_tooltip.gd`, `modal_sheet.gd`, `option_row.gd` (`make_readonly`),
`docs/CODING_STANDARDS.md` (sections 2 and 3), `tests/input_check.gd` additions. Tests: new actions bound with defaults
and no duplicate binding inside a context; theme variations exist; `ModalSheet` closes on `menu_back`.

### Chunk 2 - Operator Setup (loadout screen)  [parallel with 3, 4]
Owns: `engine/ui/operator/*` (`operator_setup.gd`, `loadout_list.gd`, `store_panel.gd`, `look_panel.gd`,
`armour_preview.gd`, `slot_tabs.gd`, `stash_tab.gd`). Uses chunk 1 API only (`LoadoutLayout`, `StoreCatalog`,
`StoreService`, `OperatorProfile`, `LoadoutContext`); entry point `OperatorSetup.open(parent, ctx, slot_index)`.
Tests: `tests/operator_setup_check.gd`: build per source, remove via `menu_secondary`, buy/equip/not-allowed states,
fit warnings, narrow layout (`--shots` writes `renders/operator_*.png`), focus chain reaches every control,
gamepad-only path (synthetic actions) buys and equips an item; extend `ui_nav_check` entry for the popup (read-only
edit of that test is done in chunk 5).

### Chunk 3 - standard lobby  [parallel with 2, 4]
Owns: `engine/ui/lobby/*` (the widgets of section 5), `engine/ui/screens/lobby_screen.gd`, `lobby_text.gd`,
`lobby_settings.gd`, `match_flow.gd`, `engine/ui/screens/results_screen.gd` and `engine/ui/match_results.gd` (credits
lines, award wiring), `tests/e2e_driver.gd` flows `lobby_host` / `lobby_join`. Until chunk 2 lands the
Operator Setup button calls `OperatorSetup.open` if the class exists, else shows a stub dialog (guarded by
`ClassDB`/script existence). Includes `BriefingSource`, `WingmanSlots` adapter (reads `Session`/garage/crew for the
campaign carousel; mission-fixed wingmen are shown locked), campaign pane (movies via `CampaignPresentation`, mission
map via `Session.briefing_map()` returning a texture or null, built from `CommandMapBackground`), goal picking,
the ready warning flow, `MatchFlow.apply_revalidate_ready`. Tests: `tests/lobby_check.gd`: every mode builds with host
and client roles, read-only options for clients, carousel + compact list with 64 fake roster entries (frame cost and
node count bounded), warning dialog on a disallowed item, ready toggle revalidation, narrow tabs, goal limits;
LAN e2e `lobby_host`/`lobby_join` (two processes: client sees host options, readies, match starts). Keep green:
`ui_nav_check` is updated in chunk 5.

### Chunk 4 - extraction call-ins  [parallel with 2, 3]
Owns: `engine/extraction/callin/*` (`raid_points.gd`, `callin_director.gd`, `callin_order.gd`, `callin_safety.gd`,
`callin_menu.gd`, `callin_crate.gd`, `temp_station.gd`, `callin_rules.gd`), `engine/extraction/extraction_rules.json`
(adds `raid_points`, `callins`, tasks max 3), `extraction_director.gd` (hooks: raid-point events, request RPCs,
commit-risk/lost-result calls into the chunk 1 API, remove the old `callin` item use), `transport_flight.gd`
(`HOVER_DROP`), `extraction_transports.gd`, `extraction_hud.gd` (RP and ETA lines), `inventory_panel.gd` (drops the
vehicle token Use button), `raid_tasks.gd` (RP events). Tests: `tests/callin_check.gd`: RP earning per source; each
refusal reason (roofed, cooldown, RP, cap, not owned); delivery sequence timings with fast timers; LZ shift/cancel +
refund; pod impact damage and crate; station ttl; owner risk commit; fallback pod without a transport pack; AI
investigate on alert; extend `extraction_check` for the removed callin items; LAN e2e `extraction_host` with a
client calling a pod (`--extraction-fast`).

### Chunk 5 - cleanup and removal  [after 2, 3, 4]
Owns: deletions and re-pointing in section 10 (`host_screen.gd`, `armory_screen.gd`, `briefing_screen.gd`,
`extraction_screen*.gd`, `loadout_preset_bar.gd`, `pilot_picker.gd`, `herc_selector.gd`, `loadout_editor.gd`,
`vehicle_picker.gd`, `garage_picker.gd` if unused, `loadout_presets.gd` public API), `launcher.gd`,
`launcher_menu.gd`, `library_home.gd`, `new_campaign_screen.gd`, `debrief_screen.gd`, `killed_screen.gd`,
`saga_choice_screen.gd`, dead keys of `extraction_rules.json`, `docs/MENU_MAP.md`, `docs/design/extraction.md`
(sections 4-6, 8-10 updated), `tests/ui_nav_check.gd`, `tests/availability_check.gd`, `tests/campaign_save_check.gd`,
`tests/hangar_check.gd` (re-pointed). Gate: a grep for each deleted class name finds no user; the full headless suite
(`compile_all`, `hangar_check`, `garage_check`, `saga_check`, `extraction_check`, `ui_nav_check`, new checks) passes;
the three screenshots flows (desktop, narrow) render.

## 13. Open questions (answers change numbers or small rules, not the structure)

**User answers (2026-10-19), which override the assumptions below:**
- **O2:** every weapon and ammo is free outside extraction. Credits buy armours, skins, models and vehicles. Extraction keeps its physical kit, which is lost on death.
- **O5:** only Light armour is free in extraction. Medium and Heavy are bought, lost on death, and bought back for 100 cr. All three are free in every other mode.
- **O6:** no team-goal voting and no leader pick. Each player picks their own goals (up to 3). The "Teammates' goals" panel shows the teammates' picks read-only, and the lobby chat is how the squad coordinates.
- **O8:** raid points have a maximum and carry over to the next raid. They disappear when the player dies (the operator is lost and a new one must be picked). They do not convert to credits.


- O1 Dedicated servers cannot verify ownership or credits (profiles are client-held). Accept for now (as the
  extraction kit), or add server-side profile storage later behind `ProfileAuthority`?
- O2 Weapons/ammo outside extraction are permanent unlocks (my reading of "buy with credits"). Alternative: ammo as a
  consumable per match. Which?
- O3 One free starter vehicle per installed game (C6). Is that the intended minimum, or only Tribes/Earthsiege?
- O4 Vehicle risk is triggered when it is called in (C5). Or should the preferred vehicle be at risk from raid start?
- O5 All three Tribes 1 armours free in extraction too (C1), which makes heavy armour free there. Restrict extraction to
  light armour free?
- O6 Teammates' goals are nominations merged by votes (5.4); acceptable, or should the squad leader pick them?
- O7 Call-in menu pad binding is the LB+RB chord (every single pad button is taken on foot). Prefer another?
- O8 Unspent raid points pay 0.25 cr each on extraction; set 0 to forbid it?
- O9 Campaign wingman editing depends on what campaign data allows per game (ES1 crew, ES2/Starsiege lance);
  chunk 3 must report which games give free wingman loadout choice versus fixed.
