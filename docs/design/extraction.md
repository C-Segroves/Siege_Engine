# Extraction mode (design + MVP status)

User request (USER_TODO.md, "Later: extraction-shooter mode"): extraction-style multiplayer maps with bots; several
human factions, a Bioderm faction and a Cybrid faction; an inventory that picks up loot and money; a shop for
upgrades, weapons and vehicles that can be called in; transports and cargo carriers that drop players into the fight
and fly them out.

This is a **remake mode**: none of the original games had it. Everything it shows comes from the user's imported
packs (shapes, armours, weapons, vehicles, maps); the repo only holds code and the remake's own design values
(`game/engine/extraction/extraction_rules.json`: timers, capacities, price ranges, loot weights, faction rosters,
short faction blurbs written for the remake). No original text is copied.

Status markers: **[MVP]** built and tested, **[later]** designed, not built.

## 1. The loop

1. **Prepare** (the standard lobby, solo from `launcher -> Extraction raid (solo)` or hosted over LAN, and its Operator Setup with the stash tab; docs/design/lobby_loadout_economy.md sections 5 and 6):
   pick an armour (any installed Tribes / Tribes 2 armour), move items from the stash into the raid kit (limited by
   the armour's slots and kilograms), buy and sell. **[MVP]**
2. **Drop in**: the raid starts; the kit leaves the profile (it is now at risk). Players ride an AI transport to the
   insertion point and get out when it lands. **[MVP]**
3. **Loot and fight**: caches around the map's landmarks hold weapons, ammunition, grenades / mines / repair kits,
   backpacks, Herc weapon salvage, trade goods and money; AI faction squads guard them; other players are hostile.
   Killed soldiers drop bags, destroyed vehicles leave salvage. **[MVP]**
4. **Exfil**: call a transport to the nearest extraction zone, survive until it lands, board it. When it lifts off,
   everything carried goes to the stash. **[MVP]**
5. **Die** and everything carried lies in a bag on the ground for whoever gets there first. **[MVP]**

## 2. Maps, drop-in and exfil

- **Maps**: any map of the map picker; the big Tribes, Tribes 2 and Starsiege multiplayer maps are the intended ones
  (default: Tribes 2 Katabatic, then Tribes Raindance). The playable area is the map schema's `bounds`
  (map_schema.md); worlds without bounds use a square of `fallback_half_size_m`. **[MVP]**
- **Loot areas** (`ExtractionMap`): the map's buildings and stations first, picked far apart
  (`area_min_spacing_m`), random ground points when the map has too few. Caches sit on the highest floor at their
  spot (a building's floor or roof, else the terrain), never inside a building. **[MVP]**
- **Extraction zones**: `zones` (3) points on a ring inside the map edge, named A, B, C; HUD markers show them all
  the time. **[MVP]**
- **Transports** (`ExtractionTransports`, `TransportFlight`): the first installed of `transport.ids` - Tribes 2
  Havoc, Tribes HPC, Tribes LPC, Starsiege dropship / Knight's drop ship / cargo ship. They fly the shared
  FlightModel (the Starsiege dropships fly as hover craft, flight_model.md), are AI-piloted (occupancy seat 0 =
  AI), untouchable (spawn protection) and ignored by the AI (meta "dormant"). **[MVP]**
  - **Drop-in**: players start in the passenger seats (OccupancyDirector seat rules: heavy armour only in the seats
    it may take), the transport flies in from `approach_m` out, lands at the insertion point (of a few random points,
    the one farthest from the loot areas), everybody gets out, it leaves and is removed. More players than seats:
    more transports. No transport with passenger seats installed: players start at the map edge. **[MVP]**
  - Riders may jump out early (the jump key leaves a Tribes vehicle in flight; the jetpack breaks the fall) - only
    where it is safe (playtest X7, `ExitSafety` through `OccupancyDirector.exit_guard`): inside the mission area, over a
    floor whose fall his armour survives at his health (the jetpack is not counted on), not over liquid (MapWater), not
    into geometry; else "Wait - not safe to drop: <reason>". Bags and drops land on the first floor below (X1). A
    passenger's chase camera follows the vehicle (X6). **[MVP]**
  - **Exfil**: `exfil_call` -> after `exfil_delay_s` a transport flies to the zone nearest the caller and waits
    `exfil_wait_s` on the ground. Boarding is the Tribes touch rule (any player, any team: you can steal a seat).
    It lifts off `depart_after_board_s` after the first player boards or when the wait ends; players aboard are
    extracted. A transport without passenger seats (Starsiege dropships), or no transport pack at all, **opens the
    zone** instead: standing inside it for `zone_hold_s` extracts. One exfil per zone at a time; everybody sees the
    calls on the HUD (ambushes are part of the game). **[MVP]**
  - [later] Cargo carriers (Starsiege cargo ship, cargo drones) lowering a called-in Herc on a sling; transports that
    can be shot down after a grace period; a raid timer that closes the zones; flares marking a landed exfil.

## 3. Factions

Each loot area gets a faction (the available ones, shuffled, round the areas) and a squad that guards it
(`ExtractionSquads`; soldiers: InfantryBot `guard_point` / `guard_radius`, they leave only to fight; vehicles:
AIPilot GUARD). Totals are capped by the match settings ("Infantry bots" = faction soldiers, "AI units" = faction
vehicles). A faction fields what the packs provide; one without anything installed is skipped. **[MVP]**

| faction | kind | fields | lore (remake blurb) |
|---|---|---|---|
| UEN Remnant | human | Tribes armour soldiers; Earthsiege / Earthsiege 2 / Battledrome Hercs | Earthsiege-era Earth forces |
| Imperial Guard | human | soldiers; Starsiege Imperial (tr_, ha_, pl_) Hercs and tanks | Harabec's Empire |
| Knights and Rebels | human | soldiers; Starsiege Knight / Rebel / Outrider (kn_, rb_, pi_) units | the colonial rising |
| Blood Eagle, Diamond Sword, Starwolf, Children of the Phoenix | human | Tribes / Tribes 2 soldiers | the Tribes tribes |
| Bioderm Horde | bioderm | Tribes 2 armour stats in the Tribes 2 **Bioderm bodies** (`bioderm_light/medium/heavy`, now converted by the Tribes 2 importer step) | engineered warriors |
| Cybrid | cybrid | Cybrid Hercs and tanks of Earthsiege, Earthsiege 2, Starsiege (no infantry) | the machine war |

**Relations** (user decision 2026-10-11: "room for human factions to fight", for story reasons). A data-driven
matrix: rules `relations.presets`, each preset a list of faction pairs with a stance (`allied` / `neutral` /
`hostile`) and a `human_default` for the human pairs it does not list. `always_hostile_kinds` (Bioderms, Cybrids)
fight everyone in every preset; players are hostile to every faction and to each other (lobby "Squads by team" puts
same-team players in one squad, which is what makes them teammates for the revive). `ExtractionFactions.apply_relations
(teams, preset_id)` fills `TeamRelations` (stances per team pair; `is_hostile`, `is_allied`, `make_stance`); the
host sends the table in the raid setup. AI target searches (AIPilot, FlyerAI, InfantryBot) ask
`TeamRelations.is_hostile`; a neutral who is shot at still answers fire (AIPilot). **[MVP]**

Presets (the raid host picks one: config / lobby setting `extraction_relations`, `ExtractionFactions.CONFIG_KEY`;
`make_preset_list()` -> [{id, label}] for the lobby's "Faction relations" row; default `story`):

| preset | human pairs |
|---|---|
| `story` - Story feuds | the pairs below; every other human pair neutral |
| `all_hostile` - Everyone hostile | all hostile |
| `humans_allied` - Humans allied | all allied (one human front against Bioderms and Cybrids; the players stay everybody's prey) |

The story matrix, with the remake's short reasons (our own summaries, no original text):

| pair | stance | why |
|---|---|---|
| Imperial Guard - Knights and Rebels | hostile | the Knights and the colonial rebels rose against the Empire |
| UEN Remnant - Knights and Rebels | hostile | the old Earth corps hunts rebels and the pirates riding with them |
| UEN Remnant - Imperial Guard | neutral | both descend from Earth's forces: an uneasy truce |
| Blood Eagle - Diamond Sword | hostile | the oldest rivalry of the tribal wars |
| every other pair of the four tribes | hostile | rival tribes raiding the same worlds |
| tribes - Earth / Imperial / Knights | neutral | different eras and fronts: they leave each other alone unless shot at |

[later] Faction reputation and contracts (work for a faction: its squads leave you alone, its shop sells its gear);
faction-specific loot tables; Cybrid drones (Starsiege jammer / protector) and flyers patrolling; faction colours on
the HUD; Bioderm animations once the Tribes 2 .dsq sequences are decoded (the male armours share the same limit).

## 4. Items, loot and inventory

`ExtractionItems` builds the catalog at run time from the installed packs (nothing is listed in the repo):

| kind | from | weight / stack | price (credits) |
|---|---|---|---|
| `weapon/<id>` | infantry hand weapons (category "infantry") | 6 kg, 1 per slot | 300..1500 by rating: damage-per-second and range percentiles among its game's hand weapons (CombatRating weights) |
| `ammo/<id>` | weapons some armour carries ammunition for | a full load weighs 1.5 kg; a slot holds the largest armour load | 12 % of the weapon price per load |
| `gear/<id>` | grenades, concussion grenades, mines, repair kits (modelled ones) | 0.5 kg, 5 per slot | 40..120 by kind |
| `pack/<id>` | backpacks the remake models | 8 kg | 500..900 |
| `salvage/<id>` | Herc weapons (category "herc") of every Herc game | 20 kg | 600..4000 by `Packs.weapon_rating`; sell only |
| `valuable/<key>` | rules' trade goods: power cell, navigation computer, sensor array, Cybrid neural core (Cybrid wrecks only) | 1..3 kg | fixed; sell only |
| `callin/<vehicle>` | every pilotable vehicle | 0 kg | 2500..14000 by `Packs.combat_rating` |

- **Caches** (`LootRoller`, rules `caches`): supply cache, weapons locker, salvage crate, each with roll counts,
  money and category weights; strong weapons and salvage are rarer (weight 1.25 - rating); a rolled weapon comes with
  half a load of its ammunition. 2-4 caches per loot area plus `scattered_caches` anywhere. The host rolls them from a
  seed (config `extraction_seed`, else time). Models: the first imported of the kind's `shapes` (Tribes 2 ammo boxes,
  Tribes ammo unit, Starsiege cargo boxes), sized to a 0.9-1.6 m crate; a plain box if none is imported. **[MVP]**
- **Inventory** (`ExtractionInventory`): slots and kilograms by armour size (light 10 / 30 kg, medium 14 / 50,
  heavy 18 / 80); money weighs nothing. **[MVP]**
- **Equipment** (`ExtractionLoadout`): the weapons in hand are the first weapon items the armour may carry; the worn
  pack the first allowed pack item; magazines and the kit's grenades / mines / repair kits are loaded from the
  inventory every `reload_seconds` as they empty. Picking up a weapon equips it when a weapon slot is free. **[MVP]**
- **Pickup**: `interact` (E, pad X; the nearest interact offer, `InfantryInteraction`) takes the money and everything that fits from the nearest container within
  `pickup_reach_m`; what does not fit stays. **[MVP]**
- **Drop**: the inventory panel drops one / all of an item into a bag at your feet. **[MVP]**
- **Armour is an item** (`armor/<armour id>`; user decision "Armor can be dropped"): medium and heavy armours cost
  the economy's `armor_base_by_size` (1800 / 3600) and weigh 15 / 25 kg as loot; the shop sells them, weapons lockers roll them
  (armory weight `armor` 1). Light armours are **standard issue**: price 0, always wearable, never stashed, sold,
  rolled or dropped (`ExtractionItems.is_free_armor`), so a broke pilot can always raid. Wearing a paid armour takes it
  out of the stash (`ExtractionProfile.apply_kit_armor`; only owned ones are offered); the raid spends it with the kit;
  extracting brings it back to the stash and he wears it again. **[MVP]**
- **Insured slot** (user decision "have an insured slot"): the kit has one insured slot holding either one kit stack
  (at most one inventory slot of it, e.g. one weapon or one stack of rounds) or the worn paid armour. It travels in the
  roster kit (`insured: [id, units]`); on death the host splits what he carried (`ExtractionLoadout.make_insured_split`):
  the insured units he still carries go home to his stash, everything else goes in the bag. Dropped or sold during the
  raid = not carried = not kept. Operator Setup's stash tab marks it (Insure / Uninsure per kit row, "Insured slot:" line), the
  inventory panel shows `[INSURED]` on it, the KIA banner names what was kept. **[MVP]**
- **Death**: everything carried (inventory + loaded rounds + kit), the worn paid armour and the money go into a bag
  where the soldier fell, except the insured stack. Bots drop their weapons, rounds, kit and a little money;
  destroyed vehicles leave their Herc weapons as salvage (Cybrids sometimes a neural core). **[MVP]**
- **Downed and revive** (user decision "a revive mechanic for your team to pick you up"; `ExtractionRevive`,
  `DownedState`, `DownedPilot`, `ReviveHud`): a lethal hit on a player's soldier while a teammate (same or allied team,
  in the raid, on his feet) is alive **downs** him instead (Infantry `lethal_hit_guard`, host only): health set to
  `downed_health_fraction`, the body lies prone, he crawls at `crawl_speed_mps`, cannot fire (no last-stand pistol:
  keeps the rule simple and teammates' revives meaningful), jet, jump, loot, use items or call exfil, and the AI ignores
  him (meta `dormant`), though a player can still finish him. A bleed-out timer runs (`bleed_out_s`, 45 s; 12 s fast).
  A teammate **holds `interact`** within `reach_m` (interact offer "hold to revive NAME", progress bar for both):
  `revive_s` (5 s) of holding gets him up with `revived_health_fraction` of his health and his own controls back;
  releasing, moving out of reach, or the reviver going down interrupts it (progress lost). Bleeding out, a hit while
  downed (execution) or the last standing teammate falling kills him: the usual death and bag. With no teammate up a
  lethal hit kills at once (solo raids play as before). Riding a vehicle (crawled aboard the exfil) the bleed-out pauses.
  Falls through the world / stuck in geometry still kill outright. LAN: the host decides; downed changes are reliable
  RPCs, states (time left, reviver, progress) go to every peer 4 x a second. **[MVP]**
  Scope: extraction raids only. Co-op / versus keep Tribes respawns, where a revive would only shorten the respawn.
  Bot revives: [later]. Faction bots die outright, and squad bots that revive players need the InfantryBot task
  system to accept a "go to and hold" task (agent C's area). The rules already allow any allied soldier as reviver.
- [later] Per-item loot window (take single items instead of everything), weapon attachments / Herc upgrade parts,
  keys / locked rooms in bases, rarity colours, loot tables per map and per faction.

## 5. Economy, shop and vehicle call-ins

- **Shop** (`ExtractionShop`, the Operator Setup store): buys weapons, ammunition (by the load), gear, backpacks and call-ins;
  everything sells back for `sell_fraction` (50 %). New profiles start with the economy's `start_credits` and a starter kit
  (the light armour's spawn weapons, two loads, grenades, a repair kit). **[MVP]**
- **Vehicle call-ins**: a bought token is an item; carried into the raid, the inventory panel's **Use** puts that
  vehicle on the ground in front of the soldier, empty and parked; he boards it with the usual rules (hatch for
  Herc-type vehicles in light armour, touch for Tribes vehicles; tribes_vehicles.md section 6). Lost with everything
  else on death. **[MVP]**
- **Standard issue** (playtest X5): the rules' `free_weapons` (the Tribes 1 Blaster) cost nothing and are worth
  nothing; a raider who brings no weapon his armour carries gets one; never rolled as loot nor left in a bag.
  `weapon_overrides` tune hand weapons for raids only (damage / refire scales, price): the Tribes 2 blaster is the
  paid upgrade (x1.2 damage, x0.9 refire, 450 cr).
- **Supply stations** (X2; `ExtractionStation`, `StationShopPanel`): a map inventory station in a raid refills health
  and energy (TribesStations) and opens the supply panel: Reload from the carried ammunition, Buy ammunition loads for
  the weapons in hand, the armour's hand items and weapons at shop prices; carried raid credits pay first, the rest
  comes off the pilot's account (charged on his own machine). Packs carry no rounds of their own: ammunition is always
  an `ammo/` stack; the ammo pack only raises what the weapons hold.
- **Panels**: the inventory and supply panels are modals (layer 85, under the battle menu): a ModalShade dims the
  HUD, the ModalPanel is centred, rows wrap their names in a column clear of the buttons (`InventoryPanel.make_row`).
- **Equip** (X4): the inventory panel's Equip takes a carried weapon in hand / wears a pack (moved to the front of the
  inventory, which the loadout reads in order); rows show `[IN HAND]`, `[READY]`, `[WORN]`, `[INSURED]`.
- **Raid tasks** (X8; rules `tasks`, `RaidTaskBoard`, `RaidTasks`): the lobby's task list offers `board_size` tasks
  (kill N of a faction's soldiers / vehicles, blow up the generator of its base, steal its flag), a pilot takes up to
  `max_picked`; reward = `reward_per` x count x the faction kind's `difficulty`. In the raid the task factions are
  placed first, the host counts the player's kills (on foot or from his vehicle), binds the generator nearest the
  faction's area (TribesBase) and puts the faction flag (a task-only valuable in the mode-object flag's shape) at the
  flag nearest it; carrying the flag out completes that task and hands the flag in (never stashed). Generator and flag
  tasks claim a map base first (`RaidTasks.make_site_claims`: a team's generators and flag in `mode_objects`), and
  the faction's squad guards the loot area nearest it. Done tasks pay on extraction; a task the map cannot hold is
  void. Progress goes to its owner (objective lines, ObjectivesPanel). **[MVP]**
- [later] Rank unlocks (ratings from raids survived), delivery by cargo carrier with a delay and a landing zone,
  armed transports and gunships as call-ins with AI pilots, vehicle insurance, Herc garage between raids reusing
  `Garage` / `LoadoutEditor` (owned Hercs with salvaged weapons fitted), crafting salvage into Herc weapons.

## 6. Persistence

`ExtractionProfile` per pilot name: `user://saves/profiles/extraction_<pilot>.json` written with
`SaveGames.write_profile` (a folder the campaign save lists never read). Format version 2. Fields: money, stash
(paid armours as `armor/` items), kit (armour + items + `insured` [id, units] or []), last kit (Operator Setup's
"Re-equip last raid's kit", with its insured slot), stats (raids, extracted, died, earned). **Migration** from version 1
(armour was free to pick): the armour worn stays worn (owned); the last raid's armour, when another paid one, is put in
the stash; the insured slot starts empty (`ExtractionProfile._apply_migration_v1`). The kit is spent
when the raid starts (each peer saves its own profile); the haul is added when the extraction message arrives.
Leaving mid-raid loses the kit. **[MVP]** Tests keep the player's files (`tests/saved_campaign_guard.gd` now also
backs up the profiles folder).

[later] Owned vehicles (a garage of called-in vehicles that survived), profile import / export for LAN parties,
server-side profiles for a dedicated host (today each player is trusted with his own kit).

## 7. Multiplayer

Host-authoritative like every LAN battle (up to `Net.MAX_PLAYERS` 24 players plus bots):

- the lobby roster carries each player's kit (`Net` roster key `kit`); `MatchFlow.apply_extraction_roster` sets
  every player's armour and team (own team each, or squads by lobby team);
- one reliable raid setup message (`ExtractionDirector._setup_raid`): caches, zones, faction teams, relations;
- container changes and new bags go to every peer; **inventories go to their owner only** (`rpc_id`);
- requests (pickup, drop, use, exfil) are reliable RPCs to the host, which checks reach, status and capacity;
- equipment changes re-equip the soldier on every peer; rounds and kit travel in the soldier snapshots as before;
- exfil states go to everybody four times a second; the extraction / death result goes to the owner, who updates
  and saves his own profile. **[MVP]** (LAN e2e: two processes, both loot, the client extracts.)

## 8. Controls and UI

| action | keys | does |
|---|---|---|
| `interact` | E / pad X | loot the container within reach (the nearest interact offer) |
| `inventory_toggle` | I / pad hold X | inventory panel (Drop, Use; controls held while open) |
| `exfil_call` | O / pad hold right stick click | call the exfil to the nearest zone |

The three are in the `infantry` binding context (CODING_STANDARDS.md section 2). HUD (`ExtractionHud`): money, load,
the exfil calls with time and distance, the pickup hint, markers on nearby caches and bags and on every zone, the
EXTRACTED / KILLED IN ACTION banner. Screens use the shared widgets (`ScreenFrame`, `OptionRow`, `MapPicker`, the
new `ItemRow`); lists are paged so the focus chain stays short for keyboard and gamepad. **[MVP]**

## 9. Code and tests

| code | role |
|---|---|
| `engine/extraction/extraction_rules.json`, `extraction_rules.gd` | design values |
| `extraction_items.gd`, `loot_roller.gd`, `extraction_inventory.gd`, `extraction_loadout.gd` | items, loot, carrying |
| `extraction_factions.gd`, `extraction_squads.gd`, `engine/team_relations.gd` | factions, squads, relations |
| `extraction_map.gd`, `extraction_transports.gd`, `transport_flight.gd` | layout, drop-in, exfil |
| `extraction_director.gd` | the raid (child "Extraction" of the Battle), network messages |
| `loot_container.gd`, `extraction_hud.gd`, `inventory_panel.gd` | world objects, HUD, panel |
| `extraction_revive.gd`, `downed_state.gd`, `downed_pilot.gd`, `revive_hud.gd` | downed, bleed-out, revive |
| `extraction_station.gd`, `station_shop_panel.gd`, `exit_safety.gd`, `raid_task_board.gd`, `raid_tasks.gd` | supply stations, safe drop, raid tasks |
| `extraction_profile.gd`, `extraction_shop.gd`, `extraction_screen_text.gd` (text helpers of Operator Setup), `engine/ui/item_row.gd` | between raids |

Tests: `game/tests/extraction_check.tscn` (catalog, loot per pack set, inventory limits, shop, profile, relation
presets and the bots' targets under each, owned armour / insured slot / v1 migration, a solo raid with drop-in / loot /
panel / exfil / stash, a raid in paid armour ending in death (armour in the bag, insured weapon home), a raid with a
teammate: downed, revived both ways, interrupted, bled out; the solo raid lobby and its stash; `--shots` writes
`renders/extraction_*.png` and `extraction2_*.png`; `-- --only-revive` skips the first two raids); LAN: `tests/e2e_driver.tscn` flows `extraction_host` / `extraction_join` with
`-- --extraction-fast` (short timers, also config `extraction_fast`).

## 10. Open questions for the user

- Gamepad: every pad button is already taken on foot, so the three new actions sit on the back paddles (paddle 1-3).
  Prefer a hold-to-use on an existing button (e.g. hold B = loot, hold Back = inventory)?
- PvP default: every pilot for himself (current, lobby "Team play" off) or co-op squads by default?
