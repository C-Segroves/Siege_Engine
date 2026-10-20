# Extraction map: Varuna's Fall (design)

A remake-original extraction map (DMZ-style) built from the player's own Tribes 2 assets: interiors, shapes, terrain
textures, skies. Layout, story and spawn data are our own work; no game data is copied into the repo.

## Story

Forty years after the Cybrid wars, the colony ark *Varuna* broke up on re-entry over an unnamed frontier world,
scattering its cargo — reactor cores, archive drives, weapon caches and the frozen remains of its crew — across a
basin the size of a small country. No one owns the world. Everyone wants what fell on it.

- **Blood Eagle** hold the **northern mountains**. They claimed the ark's prow, which buried itself in a high valley,
  and dug a fortress around it. Disciplined, heavily armed, they shoot anyone who climbs their passes.
- **Diamond Sword** hold the **central plains**. They turned the ark's flat debris field into an airfield and
  salvage yard, and run patrols in grav cycles and transports. Fast, mobile, mercenary.
- **Starwolf** hold the **southern lakes and coast**. They built pontoon docks and stilt towers over the flooded
  impact crater and control the only clean water. Raiders, ambushers, quick to trade and quicker to betray.
- **Children of the Phoenix** hold the **eastern ruins** where the ark's chapel section came down. They believe
  the *Varuna* was sent, and guard its relics with fanatics and fortified shrines.
- **The Bioderm horde** has no base. It boils out of caves in the western mountains at night and raids whoever is
  weakest, so every faction has to keep watch on its back.

Players are freelancers dropped in by transport to take what they can carry, finish contracts against the factions,
and get out alive. The factions fight each other as much as they fight you (the extraction "story" relations preset:
Blood Eagle vs Diamond Sword, Starwolf vs Phoenix, everyone vs the horde; Diamond Sword and Starwolf an uneasy truce).

## Size and regions

- **Size:** about 6 x 6 km, larger than any Tribes 2 map (Tribes 2 maps top out around 2 km of play area).
- **North (mountains):** high ridges and passes, a buried prow valley. Tribes 2 snow/rock textures.
- **Centre (plains):** wide flat debris field, long sight lines, little cover except wreckage. Desert/lush textures.
- **South (water):** lakes, a flooded crater, a river to the sea, shallow fords. Water planes (MapWater).
- **East (ruins):** broken uplands and the chapel crash site.
- **West (caves):** steep broken mountains with cave-mouth spawns for the horde.

## Faction sites (1–4 each, small to large)

| Faction | Large | Medium | Small |
|---|---|---|---|
| Blood Eagle | Prow Fortress (main base, generators, inventory, turrets, vehicle pad, outposts on two passes) | Pass Station North | Watchtower on the eastern ridge |
| Diamond Sword | Airfield (vehicle pads, hangars, sensors, AA turrets) | Salvage Yard | Two plains watchtowers |
| Starwolf | Crater Docks (stilt towers, pontoons, inventory) | Ford Camp | River watchtower |
| Children of the Phoenix | Chapel Fortress (shrine, generators, turrets) | Relic Shrine | Pilgrim tower |
| Bioderm horde | — | Cave Warren (west) | Two cave mouths |

Each faction flag (for "steal the flag" raid tasks) sits in its large base. Extraction points (at least four,
labelled EXFIL A–D) sit in neutral ground, each at least 600 m from any faction flag and 300 m from any faction
site, spread so every region has one within reach.

## Spawning (DMZ-style)

- Every site has 2–4 spawn areas around it (not inside walls, not in sight of the nearest exfil).
- A per-site **population monitor** keeps a target headcount by site size (small 2–4, medium 4–8, large 8–16,
  vehicles at large sites only) and a **reinforcement timer** (e.g. 60–120 s, faster under attack, slower at
  night for factions, faster at night for the horde).
- Patrols travel between a faction's sites along roads/passes; the horde raids the weakest nearby site.
- Flag theft triggers the existing flag-response squad.
- All numbers live in data (map JSON / extraction_rules.json), not code.
