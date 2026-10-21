# The Cybrid siege (Varuna's Fall easter egg)

A hidden event of the extraction map Varuna's Fall (`docs/design/extraction_map_varuna.md`), asked for by the user:
a chain of events that brings a relentless siege of Cybrids against everyone and forces the players out of the map or
kills them. All text, layout and numbers are our own work (no game dialogue, no copied art).

Code: `game/engine/extraction/siege/` (class names `CybridSiege`, `Siege*`, `CybridRules`, `CybridLook`). Numbers:
`extraction_rules.json` key `cybrid_siege` (timings, waves, safe area, exfil closing, texts) and the map's own
`cybrid_siege` key in `maps/varuna.json` (the relay sites, the fragment lines and where they lie). Tests:
`tests/cybrid_siege_check` (one process) and `tests/cybrid_siege_lan` (host and client).

## Story and trigger chain (hidden)

Three buried **ark beacon relays** lie at the Prow Fortress, the Chapel Fortress and the Crater Docks (each at one of
its site's spawn areas). Waking all three, in the right order, within `chain_window_s` (10 minutes) of the first, calls
the Cybrids.

- The order is rolled for every raid (`SiegeChain.make_shuffled`). Nothing shows it.
- **Radio fragments** tell it: three kinds of loot ("Radio fragment (first / second / third)"), two copies each lying in
  wreck recorders at wreck sites (`fragments.spots`), and static that speaks the same lines once to a player walking into an
  echo place (`fragments.echoes`, an `AreaTrigger` each). The fragment of rank *k* tells the line of the relay that is *k-th*
  in this raid's order; two fragments therefore give the whole order. A fragment found is kept on the objectives panel.
- Near a relay the interact key offers *"listen to the ground"* (14 m: a hum) and then *"dig out the buried plate"* (3.5 m).
  The host tells each player only his own band, so the relay positions never reach the clients.
- A relay out of order resets the chain, as does the window running out. Both are quiet: only the one who dug hears
  *"The plate clicks and goes cold."*

## Warning, truce, siege

1. **Broadcast** to all players (three lines, a `MissionAnnouncer` in FIFO order) and a 90 s countdown
   (`MissionTimers`; reminders at 60, 30, 10 s). The HUD shows the countdown (`SiegeHud`).
2. **Truce**: `SiegeRelations.apply_truce` makes the human factions allied to each other and neutral to the players, while
   the Bioderm horde and the Cybrids stay hostile to everyone (`TeamRelations`). The state goes to every peer.
3. **Waves** (`WaveDirector` / `SpawnWave`, trigger `siege_start`): wave *n* arrives at `first_s` then at gaps shrinking from
   40 s to 14 s, at a gate on the map's edge away from the last gate. Composition grows with *n* (infantry from wave 1,
   Hercs from 2, flyers from 5; counts capped; `max_units` live Cybrids at most).
   - **Infantry**: no game has Cybrid soldiers, so they are the Tribes soldier bodies (light / medium / heavy by position)
     with the **Cybrid look**: `engine/shaders/cybrid_metal.gdshader` (dark brushed metal, pulsing red panel seams, red rim,
     made entirely in the shader) over every mesh plus a glowing red visor on the eye node (`CybridLook`). Applied on every
     peer by team (`CybridSiege.apply_looks`), also to units a client rebuilds from a far-bot proxy.
   - **Hercs**: Cybrid Hercs of Earthsiege 1 and 2 and Starsiege (lighter ones first, all from wave 6). Where no such
     pack is installed, Hercs of any installed game (heavy / medium) stand in and wear the same look. **Flyers**: armed Cybrid
     flyers where a pack has one.
   - They hunt everyone: sites first, then players on foot (`SiegeCommander`), and fight whoever they meet.
   - **Bot cap**: units are spawned at the MATCH priority of `BotBudget` (above the garrisons' NEAR / DISTANT shares); when
     the cap still refuses, `SiteSpawner.apply_retire_farthest` removes the garrison soldiers farthest from every player. The
     garrisons refill slower during the siege and patrols and raids stop.
   - Every unit is pinned awake (meta `keep_awake`) so the bot LOD director lets it march from the edge; far ones are drawn
     as proxies and show on the radar like all bots.

## Forcing everyone out

- **Exfils close one by one** (`SiegeTimeline`): the zone farthest from the last exfil first, from `first_close_s` every
  `interval_s`. A transport on its way leaves, a landed one lifts off with whoever boarded, a call ends
  (`ExtractionTransports.apply_close`). Exfil calls get twice as fast while the siege runs. The **last exfil** (the map names
  it; EXFIL B) stays open until `last_close_s`, announced when the one before it closes.
- **Shrinking safe area** (`SiegeZone`): a circle from 4400 m down to 100 m over 21 minutes, each circle inside the one before,
  ending on the last exfil. Its wall is drawn for everyone (`SiegeZoneFx`, `siege_wall.gdshader`). Outside it every
  non-Cybrid unit takes damage that grows each second (`SiegeEnforcer`), and the shared `LeftAreaRule` (a `FailRule`) rules
  it lost after `lethal_grace_s`: it is destroyed.
- **Final stand**: at `final.after_s` a `MissionEnder` verdict carries out "nothing survives" after its grace: every unit but
  the Cybrids is destroyed. The raid then ends the usual way.
- **Extracting during the siege** pays `bonus.flat` + `bonus.fraction` of the haul's value on top. Every extraction, siege
  or not, is counted in `BattleStats.note_extraction` (the credits award and the goal board read it).

## Network

Host-authoritative. `SiegeHost` (host only) runs everything; `CybridSiege` (a child of the `ExtractionDirector` on every
peer) carries it: the broadcast and the truce (reliable, to all), the siege state four times a second (unreliable: phase,
countdown, wave, Cybrid count, the circle, the next closing), a player's relay band, his lines and fragments (reliable, to
him), and his dig request (to the host). Closed exfils travel in the existing exfil states.

## Shared blocks used

`AreaTrigger` (relay reach / sense, echoes), `MissionTimers` (chain window, countdown, closings, final time), `WaveDirector` /
`SpawnWave` (waves), `FailRule` (`LeftAreaRule`, the safe area), `MissionAnnouncer` (the broadcast), `MissionEnder` (the
final stand), `MissionClock`, `MissionWorld`, `MissionSink`.
