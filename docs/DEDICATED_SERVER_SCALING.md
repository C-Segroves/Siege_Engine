# Dedicated server scaling: 64 humans + 200 bots

Status: design (2026-10-18). Chunks H (server profile) and K (ENet default, 64 players; K2 WebRTC deferred by the user on 2026-10-18: browsers stay on WebSocket; it needs the webrtc-native GDExtension download) are implemented; see SERVER_DEPLOY.md section 1. Paths are relative to `game/` unless stated.
Goal: a headless dedicated server (`docs/SERVER_DEPLOY.md`, `server/dedicated_server.gd`) that holds 64 humans and
200 bots on Varuna's Fall inside a fixed tick budget, without changing how LAN co-op (host-authoritative, ENet,
`Net.MAX_PLAYERS` 24) plays, and without changing each game's feel.

## Contents
1. [Where we are (measured)](#1-where-we-are-measured)
2. [Principle 1: network](#2-principle-1-network)
3. [Principle 2: interest, delta, rates](#3-principle-2-interest-management-delta-compression-update-rates)
4. [Principle 3: bots](#4-principle-3-bots)
5. [Principle 4: headless server, data layout](#5-principle-4-headless-server-and-data-layout)
6. [Per-game feel](#6-per-game-netcode-feel)
7. [Plan: independent chunks](#7-plan-ordered-independent-chunks)
8. [Target metric and benchmark](#8-target-metric-and-benchmark)
9. [Conflicts with parallel work](#9-conflicts-with-parallel-work)

## 1. Where we are (measured)

One cheap measurement, `tests/varuna_perf.tscn` run `--headless --audio-driver Dummy` (Godot 4.6.3, Windows, this
PC, 56 soldiers all in `far_lod`, 1 human-less solo raid, 30 active physics bodies):

| Sample | frame | process | physics |
|---|---|---|---|
| baseline | 218 ms | 23 ms | 44 ms |
| far bots idle | 212 ms | 22 ms | 43 ms |
| soldiers' `_physics_process` off | 158 ms | 21 ms | 35 ms |

Reading: even with no renderer, 56 soldiers cost about 60 ms of frame time that the soldiers' own physics step
accounts for (the run shows the frame well over `process + physics`, so the sim is running several catch-up
physics ticks per frame; the 60 Hz tick is NOT being held). The "physics" monitor includes the `Herc`
`move_and_slide()` and the `InfantryBot` think/aim/ray work. Numbers are noisy (one run, windows, nav bake going on
in parallel; the nav bake spams `navmesh_edge_merge_errors` warnings) so treat them as an order of magnitude:
**roughly 1 ms per awake soldier per frame**, which puts 264 entities at several hundred ms per tick. The
design below has to remove about 20x.

Bandwidth estimate for today's snapshot (computed, not measured): `Herc.snapshot()` is 14 Variants plus damage
bytes plus soldier extra plus steering stick, about 150 bytes per vehicle after Variant encoding. Broadcast of all
264 entities at 20 Hz to every client is about 0.8 MB/s per client, 50 MB/s (400 Mbit/s) out of the server for 64
clients. Impossible; this is why interest management and bit-packing are the first network chunks.

## 2. Principle 1: network

### 2.1 UDP for gameplay
* Current: `Net.host()` (`engine/net.gd:92-122`) creates `ENetMultiplayerPeer` (UDP) or `WebSocketMultiplayerPeer`
  (TCP); one transport per process (`engine/net.gd:21-24`, `docs/SERVER_DEPLOY.md` section 1). Gameplay RPCs are
  `unreliable_ordered` (`games/es1/battle/battle_net_sync.gd:90,122`) which on WebSocket silently become reliable
  TCP, so head-of-line blocking on a lossy link. The default dedicated transport is `ws` (browser reach).
  `Net.MAX_PLAYERS := 24` (`engine/net.gd:19`) caps ENet at 23 clients (`engine/net.gd:105`).
* Gap: (a) cap of 24; (b) browsers are on TCP; (c) a process can serve only one transport, so a browser player and a
  desktop player cannot share a match.
* Design: 
  1. Desktop clients use ENet (UDP) on dedicated servers too; `ws` stays only as the browser/compat path. Make
     `ServerConfig` default to `enet` when the operator does not serve the web build; add `max_players` to
     `ServerConfig` and make `Net.max_players` a variable (default 24 for LAN, server value for dedicated);
     ENet channels: ch0 reliable (roster, spawn, fx-reliable), ch1 unreliable_ordered (snapshots),
     ch2 unreliable input (RPC `transfer_channel` arguments).
  2. Browsers: `WebRTCMultiplayerPeer` (UDP-like unreliable data channels, via DTLS/SCTP) with the dedicated
     server as one mesh peer per browser. Godot's WebRTC needs the `webrtc-native` GDExtension on native
     (the server) and signalling: reuse the existing HTTP endpoint (`engine/match_list_server.gd`) for a
     `POST /signal` offer/answer exchange; no new service. This is the one high-risk item (native extension per
     platform: Linux amd64/arm64 for the Docker image). Keep WebSocket as the fallback and put the browser on a
     lower `max_players` and 10 Hz profile until WebRTC is proven.
  3. Mixed transport in one match: not supported by Godot's single peer. Option: the server is ENet for desktop,
     and a second process or a thin UDP/WebSocket relay bridges browsers. Defer; start with "one transport per
     server" as today and document the pick.
* Keep: LAN host still uses ENet exactly as now; nothing about the LAN lobby, discovery (`engine/net.gd:205-249`)
  or roster changes.

### 2.2 Client-side prediction with server reconciliation
* Current: none. The client sends its Herc controls every physics tick (`battle_net_sync.gd:34`, `make_controls`
  `71-81`) and every Herc on the client except its own is a puppet via `Herc.is_puppet`/`_puppet_update`
  (`games/es1/herc.gd:762-772`) that lerps between the last two snapshots (`games/es1/herc_snapshots.gd:172-191`).
  The local pilot is NOT a puppet in the sense that it runs the full local sim (`is_local_player()` guards in
  `herc.gd:739`) but there is no input sequence number, no stored input history, no authoritative state to
  compare to, and the client's own body is never corrected from the server's state: today the host effectively
  trusts the client's local result only where `_apply_controls` reflects intent; the host moves its own copy from
  those controls. In practice a pilot sees his own local copy at 0 latency and the host copy may drift.
* Gap: input sequence + ack, a deterministic-enough shared movement step, and a reconciliation rule.
* Design (per game feel, section 6):
  * Add `engine/net/input_frame.gd` (`class_name InputFrame`): `{seq:int, tick:int, throttle, turn, torso, pitch,
    triggers, jet, jump, weapon_slot, ...}` = exactly today's `make_controls` dictionary packed into a
    `PackedByteArray` (about 12 bytes) with a sequence number, sent as the last N (3) unacked frames per packet
    (redundancy beats resend on UDP).
  * Server (`BattleNetSync._client_input`, `battle_net_sync.gd:90-100`): queue frames per peer in a ring, consume
    exactly one per server tick (dropping or repeating the last one on a gap, bounded), stamp the snapshot with
    `last_processed_seq` per client.
  * Client: `engine/net/prediction.gd` (`class_name Prediction`) keeps `seq -> (input, resulting pose)` for the
    local soldier/Herc; on a snapshot it compares the server pose for `last_processed_seq` against the stored one;
    if the error is under an epsilon it keeps predicting, under a threshold (about 1.5 m) it blends the error out
    over about 100 ms (visual smoothing, physics body keeps the predicted state), otherwise it snaps and replays
    the unacked inputs through the SAME movement code (`Infantry._drive`, `InfantryMotion`, `Herc` drive).
  * Scope: prediction only for the locally owned soldier (Tribes feel: ski, jet, jump; `infantry.gd:337-368`,
    `engine/infantry/infantry_motion.gd`) and, with a lower priority, the locally piloted Herc. Flyers
    (`Flyer`) and occupied turrets keep server authority with a short input delay. Local fire is predicted for
    effects only (muzzle flash, tracer); damage stays server-side.
  * Requirement: the movement step must be a pure function of (state, input, dt) with a fixed dt. `_drive(delta)`
    already takes delta and `far_lod` already calls it with a summed delta (`infantry.gd:327-337`), so the
    seam exists; what remains is removing wall-clock reads (`Time.get_ticks_msec` in `far_lod`/`META_LOD_HOLD`
    and `disabled_until`, `infantry.gd:340`) from the movement path.

### 2.3 Lag compensation
* Current: none. Beams ray-cast against current physics at the moment the server processes the trigger
  (`engine/weapons/weapon_shot.gd:21`, `engine/weapons/weapon.gd:188`); projectiles are server-spawned and
  announced (`weapon_shot.gd` `launch_projectile`, `projectile.gd:99`).
* Gap: with 100 ms ping a hitscan shot at a moving target misses by 100 ms of the target's movement (about 6 m at
  Tribes ski speed).
* Design: `engine/net/hit_history.gd` (`class_name HitHistory`): a ring buffer of the last 1 s of (tick, position,
  yaw, bounding capsule/box) per entity, written once per server tick in the entity table (section 5.2). On a
  hitscan shot from a human (not bot, bots shoot "now"), the server computes `rewind_tick = server_tick -
  client_interp_ticks - rtt/2` clamped to 250 ms, temporarily places the candidate bodies' collision shapes at
  their historic transforms (PhysicsServer3D `body_set_state` on the nearest K candidates found by the interest
  grid, or an analytic ray-vs-capsule test on the history, which needs no physics changes), tests, then restores.
  Analytic ray-vs-history-capsule is the recommended path: no physics state churn, deterministic, cheap. Wire it
  in at one place: `WeaponShot.fire_beam` gets an optional `shot.rewind_tick`. Projectiles are slow enough in
  Tribes (spinfusor discs) that they stay server-time; only hitscan (lasers, Laser Rifle, chaingun) rewinds.
  Cap rewind so a high-ping player cannot kill someone behind a corner ("favour the shooter" but max 250 ms).

### 2.4 Fixed server tick independent of FPS
* Current: `project.godot` has no `physics_ticks_per_second` override (Godot default 60); snapshots are accumulated
  by wall delta in `_physics_process` (`battle_net_sync.gd:37-41`), `Net` discovery uses `_process`
  (`engine/net.gd:222`), bots count down in `_physics_process` (`infantry_bot.gd:116-123`). The dedicated server
  has no frame limiter. Headless measurement above shows catch-up ticks under load.
* Gap: no explicit server tick number, no cap on catch-up (`Engine.max_physics_steps_per_frame` default 8 causes
  the spiral of death), snapshot cadence floats with the frame.
* Design: `engine/net/server_clock.gd` (`class_name ServerClock`, child "ServerClock" of the Battle): owns
  `tick:int`, `TICK_HZ := 30` for the dedicated server (physics stays 60 on LAN clients; server physics tick set
  to 30 or 60 by `ServerConfig.tick_hz` through `Engine.physics_ticks_per_second` at `dedicated_server.start`),
  `Engine.max_physics_steps_per_frame = 2`, and `Engine.max_fps = tick_hz` on the headless server so it
  sleeps instead of spinning. Everything networked uses `tick` (snapshot tick, input seq mapping, hit history),
  never `Time.get_ticks_msec()` (replace the `now` in `_send_snapshot_when_due`, `battle_net_sync.gd:42`).
  LAN host keeps 60 Hz physics and 20 Hz snapshots to stay unchanged.

## 3. Principle 2: interest management, delta compression, update rates

### 3.1 Interest management (grid + line of sight + radar)
* Current: none for the network; `_send_snapshot_when_due` loops all `battle.vehicles` and ships them to all
  peers via one broadcast RPC (`battle_net_sync.gd:43-51`). Pieces that exist and are reusable:
  `RadarContacts.is_on_scope(viewer, unit)` (`engine/radar_contacts.gd:266-276`) which already encodes "what this
  player's radar shows" (sensor link, Tribes sensor net via `TribesBase.is_on_radar`, `SensorTowers` reach,
  mission-hidden meta); `LineOfSight.is_clear` (`engine/line_of_sight.gd:15-20`) a physics ray;
  `BotSleep._find_human_nodes/_nearest_flat` (`engine/bot_sleep.gd:95-144`) the nearest-human-distance
  computation; `SiteSpawner._apply_soldier_lod` (`engine/extraction/site_spawner.gd:236-248`) a 150 m radius LOD.
  Fog end is the practical sight range (`BotSleep.make_sight_range`, `bot_sleep.gd:39-46`).
* Gap: no spatial index, so every query is O(humans x entities) with Node property reads; no per-client
  visibility set; entity create/destroy is a reliable broadcast (`battle.gd:200-215`, `_spawn.rpc`,
  `_remove_vehicle.rpc`), not interest-scoped, so a client instantiates all 264 nodes.
* Design: `engine/net/interest_grid.gd` (`class_name InterestGrid`): uniform 2D grid on the map's ground plane,
  cell 128 m (matches nav `TILE_SIZE := 96`, same order), cell -> `PackedInt32Array` of entity indices, rebuilt
  in one pass per server tick from the entity table (O(N), no nodes touched). Per client, `visible_set(client)` =
  union of:
  1. entities in cells within the client's view radius (min(fog end, `view_m`, per-class: soldiers 300 m, Hercs 800
     m, turrets/structures 1200 m), staggered: recompute each client every 4th tick (client-staggered, 15 Hz
     visibility is plenty);
  2. entities `RadarContacts.is_on_scope` says the client's viewer sees (radar counts as visible, as
     required); evaluated only for the candidates the radar range grid cells cover, cached per client for 0.5 s,
     and sent on the LOW rate tier (section 3.3) because radar blips need position only;
  3. always: the client's own team (Tribes: sensor net / com link already makes allies known), flags, objectives,
     and entities the client targets (`target` field in controls, `battle_net_sync.gd:73`);
  4. line of sight: only used to PRUNE the near tier in dense interiors, not to add; a LOS ray per pair is too
     expensive (64 x 200 = 12800 rays per refresh). Use it as a tie-break: an entity inside the near radius but
     occluded by terrain for >2 s (3 rays from the client eye, cached) drops to the mid rate tier, it does
     NOT disappear (anti-wallhack is out of scope; it is a bandwidth knob, flagged `interest.los_demote`).
  Enter/leave events: when an entity enters a client's set the server sends a full "spawn state" (reliable
  channel), when it leaves a "forget" (reliable), so clients free the puppet node. Replaces the broadcast
  `_spawn`/`_remove_vehicle` RPCs for dedicated mode.
* Keep for LAN: `InterestGrid.enabled = false` (everyone sees everything), which is today's behaviour with 24
  players and about 30 entities.

### 3.2 Delta compression and bit packing against the last acked snapshot
* Current: full-state `Array` of Variants per entity (`Herc.snapshot`, `herc.gd:731-734`, plus damage block and
  extras) in one `unreliable_ordered` RPC at fixed 20 Hz (`battle_net_sync.gd:9,51`); damage is hand-delta'd with
  resend windows (`make_damage_update`, `battle_net_sync.gd:56-65`) because the channel is unreliable; no acks.
* Gap: about 150 B/entity, no quantisation, no baseline, no per-client state.
* Design: `engine/net/snapshot_codec.gd` (`class_name SnapshotCodec`) + `engine/net/client_baseline.gd`:
  * Server keeps a ring of the last 32 snapshots of the entity table (packed arrays, section 5.2). A client acks
    the newest snapshot tick it applied (piggybacked on its input packet: 2 bytes). The server encodes each client's
    packet as a delta against that acked tick; if the ack is older than 32 ticks it sends a full snapshot.
  * Quantisation (bit budget per entity, approx.): id 10 bits (index in the client's visible list, not the net id),
    position 3 x 16 bits relative to the map origin at 5 cm resolution over 3276 m (Varuna's Fall is about 6 km;
    use cell-relative: 12 bits within-cell x 2 + height 12 bits plus cell id 10 bits as full state only),
    yaw/torso/pitch 3 x 9 bits, flags 4 bits (alive, firing, jetting, stowed), shields/integrity 3 x 6 bits, only
    when changed (1 change-mask bit per field group). Unchanged entity = 1 bit; moving soldier delta about 5-9
    bytes. Damage block and kit state keep their existing resend rules but ride the delta (they become
    "changed since acked" instead of timers: `_damage` dictionary in `battle_net_sync.gd:19` goes away for dedicated).
  * Implementation uses `PackedByteArray.encode_u16/encode_u32` and a small `BitWriter` (30 lines); no per-field
    Variants. Encode cost target: under 20 us per entity.
  * Budget: 64 clients x 40 visible entities x 6 B x 20 Hz = 0.3 MB/s total out, versus 50 MB/s today.
  * Wire: one RPC `_snapshot_packed(tick, PackedByteArray)` per client (`rpc_id(peer, ...)`), not a Variant array.

### 3.3 Lower update rates for far entities + client interpolation
* Current: one fixed rate (`SNAPSHOT_HZ := 20.0`, `battle_net_sync.gd:9`); puppets interpolate between the last
  two snapshots only (`herc_snapshots.gd:172-191`): no render delay, so a late packet freezes and then jumps.
  `Infantry.far_lod` already steps far soldiers every 4th physics tick (`infantry.gd:316-337`), meaning far
  soldiers move in 4-tick jumps that the 20 Hz snapshot hides.
* Gap: no rate tiers; no snapshot buffer / render delay; no extrapolation.
* Design: three tiers per (client, entity), decided in `InterestGrid`: NEAR (under 100 m or targeted or the
  client's own vehicle's weapons): every snapshot, 30 Hz; MID (100-400 m, or radar-only Herc): every 3rd, 10 Hz;
  FAR (radar blips, structures' state): every 12th, 2.5 Hz position only. Client side `HercSnapshots` grows
  from a 2-entry pair to a 3-6 entry ring with `render_delay = 2 x snapshot interval` (100 ms at 20 Hz) and
  tier-aware `dt` (it already takes `dt` per `push`); extrapolate at most 250 ms along the last velocity, then
  hold. Server-side per-tier rotation is `(tick + entity_index) % period == 0` so load spreads evenly.

## 4. Principle 3: bots

### 4.1 AI decision tick at 5-10 Hz, movement interpolated between
* Current: `InfantryBot` thinks every `THINK_SECONDS := 0.4` (2.5 Hz, `engine/infantry/infantry_bot.gd:28,119-123`)
  but `_aim_and_fire()` and `_move(delta)` run EVERY physics tick (`infantry_bot.gd:127-129`), including a
  `move_and_slide` per soldier (`infantry.gd:368,447`). `AIPilot` thinks on a variable period
  (`games/es1/ai_pilot.gd:93-98`, `_make_think_period` at 272). Bots are full `CharacterBody3D` nodes.
* Gap: the expensive parts (aim ray work, move_and_slide, animation `_animate`) are per tick; decision is cheap
  and already low-rate. Target is the reverse: cheap per-tick, decisions at 5-10 Hz.
* Design: split the bot into DECIDE (rate `think_hz`, 5 near, 2.5 far, 10 for bots within 30 m of a human) and
  ACT. ACT for NEAR bots stays a real `_drive` so combat feel is intact; for MID/FAR bots ACT is a kinematic
  integration of the last `wish` and heading along the current path point (no `move_and_slide`) with one
  down-ray every N ticks to stick to terrain (heightmap lookup instead of ray: `MapTerrain` height sample, see
  section 5). Existing hook: the `_lod_t`/stride mechanism (`infantry.gd:319-337`) is the template: generalise
  `far_lod: bool` into `ai_lod: int` (0 near, 1 mid, 2 far, 3 asleep) set by one `BotLodDirector`.

### 4.2 LOD AI
* Current: `far_lod` (boolean, 150 m, `site_spawner.gd:236-248`, rule `lod_radius_m`) steps movement every 4th
  tick and skips animation; it only covers extraction soldiers (`director.faction_teams`), not vs/co-op AI or Hercs
  (`AIPilot`). `BotSleep` (`engine/bot_sleep.gd`) fully sleeps units beyond sight range of all humans and keeps
  radar-visible units awake (`bot_sleep.gd:87-92,127-136`), but is DISABLED (`extraction_rules.json:149-150
  "enabled": false`) and is O(humans x vehicles) with `get_children()` scans for the brain every 0.5 s
  (`bot_sleep.gd:118-124`). It also only runs on the host and sleeps by node `set_physics_process(false)`: sleeping
  bodies stay in the scene (cheap but not free: 200 nodes with collision shapes still sit in the broadphase).
* Gap: no medium tier; BotSleep off and with a measured-unknown reason (verify: the radar-contact rule keeps most
  units awake on non-Tribes maps because `RadarContacts.is_on_scope` is true for "every unit" inside radar range,
  `radar_contacts.gd:266-276`, so on Varuna a 1200 m default radar range wakes everything near any human, and with
  64 humans spread over the map almost nothing sleeps. That has to be measured with the benchmark, section 8).
* Design: tiers by distance to the nearest human (grid lookup, not a scan):
  * NEAR (under 150 m, or in a human's scope cone, or hurt): full: 5-10 Hz decide, per-tick `_drive`, animation
    off on the headless server (nothing to see).
  * MEDIUM (150-500 m): decide at 2.5 Hz, simplified nav (follow the cached path points, no obstacle probing, no
    `is_building_ahead` rays, see `infantry_bot_route.gd:38-57`), kinematic ACT at 15 Hz with terrain-height
    sampling; no `move_and_slide`; shoots only at targets within the sight cone, resolved with the damage model
    "dice" (an abstract fight: a near-miss sound is not needed on the server) rather than rays when no human is
    within 300 m of the target.
  * FAR (500 m+ and not a mission objective): either linear move along the path (`entity.pos += dir * speed *
    dt`, 2 Hz) or hibernate. Hibernate = BotSleep today; reworked to not use Nodes at all (section 5): the
    entity row stays in the table, its CharacterBody is removed from the physics space (`PhysicsServer3D
    body_set_space(rid, RID())`) and re-added on wake, with position taken from the row. That makes sleeping bots
    cost nothing in the broadphase either.
  * Radar rule fix: the "stays awake while on a human's radar" rule must be tier-demoting, not waking: a radar blip
    only needs a position that moves plausibly; FAR linear move satisfies it. So `BotSleep` keeps its guard
    list (objective, leader, engaged order, `keep_awake`, dormant) but replaces `RadarContacts.is_on_scope -> awake`
    with `is_on_scope -> at most MEDIUM`.
  * Keep from the originals: the Tribes bots' behaviour (path markers) is untouched; the tier changes only the cost
    of acting it out.

### 4.3 Async / threaded pathfinding
* Current: `BattleNavigation` bakes nav tiles asynchronously (`bake_navigation_mesh(..., true)` style; header
  `battle_navigation.gd:11-14`, `_pending`, `SYNC_FRAMES` at 53) but `make_path` is a synchronous
  `NavigationServer3D.map_get_path` on the main thread (`battle_navigation.gd:67-74`) called from each bot's
  route code when the goal moved or every few seconds (`infantry_bot_route.gd:10-16,83-90`). With 200 bots
  re-asking this is main-thread spikes.
* Gap: no path request queue, no budget, no async query. Godot 4.6 exposes `NavigationServer3D.query_path(
  NavigationPathQueryParameters3D, NavigationPathQueryResult3D, callback)` which runs on the navigation
  server's thread when `navigation/3d/use_async_iterations` is on (project setting, default on in 4.4+; verify
  for 4.6.3 in the benchmark) and calls the callback on the main thread.
* Design: `BattleNavigation.request_path(bot_id, from, to, profile)` (new, next to `make_path`) enqueues; a
  dispatcher issues at most `paths_per_tick` (4-8) `query_path` calls per server tick, prioritising NEAR bots;
  the callback stores `PackedVector3Array` in a `bot_id -> path` PackedArray row. `InfantryBotRoute`
  gains `request()` + `poll()` and keeps the current straight-line fallback while no path has arrived (that
  fallback already exists, "returns [] ... moves as it did without navigation", `battle_navigation.gd:62-65`, so
  behaviour degrades to today's). Path sharing: bots with the same objective and a start in the same 32 m cell
  reuse one path (formation followers already follow a leader, `bot_sleep.gd:65-69`).
  Test with the existing `tests/bot_path_check`.

## 5. Principle 4: headless server and data layout

### 5.1 Strip graphics, audio, animation, heavy assets
* Current: the server runs the full client scene `res://games/es1/battle.tscn`
  (`server/dedicated_server.gd:10,88`) with `--headless --audio-driver Dummy`. Headless already avoids GPU work
  (`DisplayServer.get_name() == "headless"` is checked in places such as
  `engine/command_map/command_map_background.gd:32`) but the server still builds meshes and materials
  (`engine/shape_instance.gd`, `engine/map_builder.gd`, terrain chunk meshes: the profile above lists 36 terrain
  chunk MeshInstance3Ds), runs `_animate` per soldier (`infantry.gd:354`) and `herc_animator`, loads
  textures/palettes (`engine/palette.gd`) and creates FX (`engine/fx/*`, `battle_fx`, `FxParticles` CPU particles
  run headless per the file header).
* Gap: no `Server` build profile; no flag that tells the builders "collision only".
* Design:
  1. `engine/server_profile.gd` (`class_name ServerProfile`, static `is_server()` = `Net.dedicated or
     DisplayServer.get_name() == "headless"`) read at the five choke points: map/terrain builder (build collision
     only: `HeightMapShape3D` for terrain, box/capsule shapes for structures from the same dimensions the visual
     uses; skip `MeshInstance3D`, materials, textures), `ShapeInstance` (collision-only path using the shape's
     bounding box/cylinder), `Herc._animate`/`InfantryAnimation` (skip; the server needs the hitbox, not the
     pose: use one capsule per soldier, 2.3 m x 0.6 m radius per `BattleNavigation.SOLDIER`, and the existing
     cell/hit-zone model for Hercs only where damage zones need it), FX (`WeaponShot._announce` should only
     serialize the event for clients, not build local FX), sounds (already Dummy).
  2. Explicit hit-zone note: Herc damage uses per-cell state (`shape.get_cell_state`, `herc_snapshots.gd:213-243`);
     the server must keep the cell data (it is authoritative), but it can drop meshes and keep the cell volumes
     as boxes.
  3. Export for the server: a Linux "dedicated server" export preset with the Godot feature tag `dedicated_server`
     (Godot 4.x strips textures/audio/meshes from the export when exporting for the dedicated server target:
     "Export Mode: Export as dedicated server" strips resource types by their import settings). Combined with
     the code path above this removes most of the load time and RAM, but maps loaded from the operator's own
     packs at runtime (`Assets`, `Packs`) still need the explicit collision-only builder.
  4. Memory/RAM target: under 2 GB for 264 entities on Varuna (measure with `Performance.MEMORY_STATIC`).

### 5.2 Data-oriented storage for mass entities
* Current: each entity is a `Herc`/`Infantry` Node (`CharacterBody3D`) in `battle.vehicles: Dictionary net_id ->
  Herc` (`battle.gd:~40`), all state in GDScript properties; every pass (snapshot, BotSleep, radar, LOD, interest)
  walks the dictionary and reads properties through the script interpreter.
* Gap: Godot has no ECS. The realistic equivalent is a server-side SoA entity table in packed arrays, with the
  Node left as an "interface" only for entities that need rich logic (humans, near bots), plus `PhysicsServer3D`
  bodies directly for far/medium bots, and RenderingServer/MultiMesh only on clients (the server has no
  renderer).
* Design:
  * `engine/net/entity_table.gd` (`class_name EntityTable`): parallel packed arrays indexed by a dense `row`
    (net_id -> row via `Dictionary` or `PackedInt32Array` since net ids are small ints): `pos_x/pos_y/pos_z
    (PackedFloat32Array)`, `yaw/torso/pitch (PackedFloat32Array)`, `vel`, `flags (PackedInt32Array)` (alive,
    firing, jetting, stowed, human, ai_tier 2 bits), `team (PackedByteArray)`, `health bytes` etc.,
    `last_changed_tick (PackedInt32Array)`, `tier`. One `sync_from_nodes()` per tick copies the ~100 Nodes that are
    active; the table is the single source for `InterestGrid`, `SnapshotCodec`, `HitHistory`, `BotLodDirector`,
    the benchmark, and metrics. Writing is O(N) packed-array stores (about 2 ms for 264 in GDScript, to be
    measured).
  * Bots at MEDIUM/FAR tier are row-only: movement is `pos += dir*speed*dt` into the table; the Node is
    "demoted" (physics off, removed from the space, kept in `battle.vehicles` for counts/objectives exactly as
    `BotSleep` does now: `bot_sleep.gd:5-8`) and "promoted" back when the tier changes. Promotion reads
    position from the table, hence no teleport glitch.
  * Direct physics: a promoted/near bot keeps its `CharacterBody3D`; for bots that only need to be a hit target
    while MEDIUM, create ONE `PhysicsServer3D` static/kinematic body with a capsule per bot (`body_create`,
    `body_add_shape`, `body_set_mode(KINEMATIC)`, `body_set_state(TRANSFORM)` from the table at the tier rate),
    no Node, no script. That is the realistic "direct bodies" tool and costs far less than a script CharacterBody.
  * Clients (not the server): far bots render as instances in a `MultiMeshInstance3D` or
    `RenderingServer.instance_create` (billboards or a low-poly soldier) updated from the packed snapshot array,
    and only promoted to the full animated `Infantry` Node inside ~120 m. This is the client counterpart of
    server-side tiers and removes the `_spawn` of 264 full nodes per client.
  * Rule: do NOT convert the human soldier/Herc to the table; they stay Nodes (rich logic: kit, weapons,
    HUD). Convert only the passive state that the network, the grid and the LOD need.

## 6. Per-game netcode feel

The engine is game-agnostic (`engine/`, memory rule); tuning lives in a `net_profile` per game pack
(`games/<id>/net_profile.json`, read by `ServerClock`/`SnapshotCodec`/`Prediction`):

| Game | Movement authority | Prediction | Hitscan | Projectiles | Tick/snapshot |
|---|---|---|---|---|---|
| Tribes 1/2/V (infantry, ski, jet) | client-predicted, server-reconciled (originals did the same) | full, reconcile 1.5 m, blend 100 ms | rewind (Laser Rifle, chaingun) | server time, client shows predicted trail | 32 ms tick (T1/T2 used 32 ms), snapshot 30 Hz near |
| Earthsiege 1, Starsiege Herc (heavy, slow) | server authoritative with prediction of the pilot's own Herc (slow, forgiving) | yes, loose threshold 3 m | rewind (lasers) | server time | 30 Hz tick, 15 Hz near |
| Flyers (`Flyer`) | server authoritative | none (input delay only) | rewind | server time | 20 Hz |
| Extraction (Varuna, `extraction`) | like Tribes for the soldier | full | rewind vs players, "now" vs bots | server time | as Tribes |
| LAN co-op (host + up to 23) | unchanged: host sim, current RPCs | off by default (flag `prediction.enabled=false` keeps today's path) | rewind off | unchanged | 60 Hz physics / 20 Hz snapshots |

Original feel: Tribes 1/2 clients predict movement and the server corrects, with a fixed 32 ms tick; that is the
tick/snapshot row above. Earthsiege/Starsiege were lockstep-ish LAN designs; the remake already deviates
(host-authoritative), so the "slow Herc" row keeps the heavy, deliberate feel by keeping reconciliation loose and
the sim at 30 Hz.

## 7. Plan: ordered, independent chunks

Order is the recommended landing order; "deps" says what a chunk really needs. Chunks with no deps can run in
parallel branches/agents. Every test runs `--headless --audio-driver Dummy` with a `*_check.tscn` convention
like `tests/bot_path_check`.

| # | Chunk | Files (new unless noted) | Tests | Deps |
|---|---|---|---|---|
| A | (done 2026-10-18, section 8.1) Metrics + load benchmark (build FIRST; proves everything else) | `tests/server_load_bench.gd/.tscn`, `engine/net/server_metrics.gd` (per-system us timers, tick histogram, bytes/s) | the benchmark itself, prints `BENCH ...` | none |
| B | (done 2026-10-18, section 8.1) ServerClock + fixed tick + frame cap | `engine/net/server_clock.gd`; edit `server/dedicated_server.gd`, `server/server_config.gd` (`tick_hz`, `max_players`), `battle_net_sync.gd:37-50` uses the tick | `tests/server_clock_check` (tick count stable under a forced 100 ms stall: catch-up capped) | none |
| C | EntityTable (SoA) + sync_from_nodes | `engine/net/entity_table.gd` | `tests/entity_table_check` (round trip with 300 fake rows, perf < 2 ms) | none |
| D | InterestGrid + tiers (+ radar/LOS rules) | `engine/net/interest_grid.gd`; reads `radar_contacts.gd`, `line_of_sight.gd` (no edits) | `tests/interest_grid_check` (cells, radar-visible entity included, far entity at FAR tier, LOS demote) | C |
| E | (done 2026-10-18, section 8.2) SnapshotCodec + client baseline/acks + packed RPC | `engine/net/snapshot_codec.gd`, `bit_writer.gd`, `client_baseline.gd`; edit `battle_net_sync.gd` (send/recv path behind `Net.dedicated`), `herc_snapshots.gd` (ring buffer, render delay) | `tests/snapshot_codec_check` (encode/decode, loss simulation drops 30% of packets, delta vs full, byte budget asserts) | C; D optional (works with "everyone visible") |
| F | Bot LOD director (tiers) + BotSleep rework | `engine/bot_lod.gd`; edit `engine/bot_sleep.gd`, `engine/infantry/infantry.gd` (`far_lod` -> `ai_lod`), `engine/infantry/infantry_bot.gd` (decide/act split), `engine/extraction/site_spawner.gd:236-256`, `extraction_rules.json:148-150` | extend `tests/bot_path_check`; new `tests/bot_lod_check` (tier switches by distance, objective/leader pinned awake, wake on damage, radar demotes not wakes) | C helps, not required |
| G | Async path queue | edit `engine/navigation/battle_navigation.gd`, `engine/infantry/infantry_bot_route.gd` | `tests/bot_path_check` + `tests/nav_async_check` (200 requests, main-thread time per tick bounded, fallback straight line) | none |
| H | Server profile (collision-only world, no animation/FX/meshes) + export preset | `engine/server_profile.gd`; edits at `map_builder.gd`, `shape_instance.gd`, `herc_animator.gd`, `infantry_animation.gd`, `fx/*`, `export_presets.cfg` | `tests/server_profile_check` (collision parity: same ray hits with and without meshes on Varuna), startup time + RAM in bench | none (touches many files, so run before many agents edit the same ones) |
| I | (done 2026-10-18, section 8.3) Input frames, prediction, reconciliation | `engine/net/input_frame.gd`, `engine/net/prediction.gd`; edit `battle_net_sync.gd:34,90-120`, `engine/infantry/infantry.gd` (movement purity), `engine/infantry/infantry_motion.gd` | `tests/prediction_check` (inject 120 ms lag + 5% loss: error stays under 0.3 m, snap rate under 1 per 10 s, replay equals server) | B; E recommended |
| J | (done 2026-10-18, section 8.3) HitHistory + lag compensation | `engine/net/hit_history.gd`; edit `engine/weapons/weapon_shot.gd`, `weapon.gd` (`rewind_tick`) | `tests/lag_comp_check` (target moving 8 m/s, 100 ms rtt shot hits in the past position, rewind clamp at 250 ms) | B, C |
| K | Transport: ENet dedicated default, `max_players`, WebRTC browser path | edit `engine/net.gd:19-24,92-122`, `server/server_config.gd`, `engine/match_list_server.gd` (`/signal`), `deploy/*`, docs/SERVER_DEPLOY.md | `tests/net_slow_load_check` (exists) + `tests/net_transport_check` (64 loopback ENet clients connect, roster/refusal paths) | none; WebRTC half is a separate risky sub-chunk K2 |
| L | (done 2026-10-18, section 8.4) Client far-bot rendering (MultiMesh/RenderingServer) + client spawn by interest | edit `games/es1/battle.gd` (`_spawn`, `_remove_vehicle`), new `engine/render/far_bots.gd` | visual: render a screenshot at 200 bots; `tests/far_bots_check` (counts, promote/demote) | D, E |
| M | (done 2026-10-18, section 8.4; one table, `engine/net/net_profiles.json`) Per-game `net_profile.json` + tuning pass | `games/<id>/net_profile.json`, loader | `tests/net_profile_check` | after E, I, J |

Parallelism:
* Wave 1 (all independent, can run concurrently): A, B, C, G, H, K (K without WebRTC).
* Wave 2 (after C lands; B for I/J): D, E, F can run concurrently with each other (they only share C's table).
  J and I need B and C; I also prefers E's acks.
* Wave 3: L (needs D+E), K2 (WebRTC), M.
* File-collision notes inside the plan: E, I and J all edit `battle_net_sync.gd` (E: send/recv, I: input path, J none);
  H touches many shared builder files and should merge first; F and G both touch bot files
  (`infantry_bot_route.gd` is G; `infantry_bot.gd`, `infantry.gd` is F): different regions, low conflict.

## 8. Target metric and benchmark

Targets (dedicated server, headless, Varuna's Fall, Linux x86-64 or the 4-core Oracle Ampere A1 in
SERVER_DEPLOY section 7):

| Metric | Target at 64 humans + 200 bots |
|---|---|
| Server tick | 30 Hz (33.3 ms budget); p50 under 12 ms, p99 under 25 ms, zero ticks over 33 ms in a 10-minute run |
| Catch-up physics steps per frame | max 1-2 (`max_physics_steps_per_frame`), logged |
| Bandwidth out | under 60 KB/s per client average, under 4 MB/s total |
| Bandwidth in | under 4 KB/s per client |
| RAM | under 2 GB |
| Pathfinding | main-thread path cost under 1 ms per tick, 4-8 queries dispatched per tick |
| Bot decision cost | under 0.05 ms per NEAR bot, under 0.01 ms per MEDIUM/FAR bot |

(The "12 ms p50" gives a 3x margin for cloud CPU variance. The current state is measured at about several hundred
ms per frame for far fewer entities, so these are about a 20x improvement; chunks F+H+C account for most of it.)

Benchmark `tests/server_load_bench.tscn`:
* Starts a real `Battle` for Varuna (`VarunaMap.MAP_ID`, as `tests/varuna_perf.gd:46-52` does) with
  `Net.host(...)` on loopback, ENet.
* Spawns 200 bots through `SiteSpawner` / `InfantryBots` with the production rules, and 64 synthetic humans:
  headless "client" Nodes in the same process that open real ENet peers (`ENetMultiplayerPeer.create_client`) to
  the server on loopback, and send scripted `InputFrame`s (random walk toward objectives, shoot at the nearest
  visible entity at 1 Hz, jitter 20-80 ms and 3% loss simulated by a drop filter in the client's send path).
  Process split: server and clients in separate Godot processes (clients in 1 process of 64 peers) so the
  server's tick time is not polluted by client work; use `--headless --audio-driver Dummy` for both.
* Measures per tick (via `ServerMetrics` timers around the Battle's systems: physics, bot decide, bot act, nav,
  codec/encode, interest, send) and prints `BENCH tick_ms p50= p95= p99= max= | bots_near= mid= far= asleep= |
  out_kBps_per_client= | rss_mb= | catchup_steps_max= |`. Exit code non-zero if p99 > the target or catch-up > 2.
* Staged: 8 humans + 24 bots, 24 + 80, 64 + 200, so a regression points at the scale it breaks.
* Also runs with `interest=off, tiers=off` once to show the before number for the record.
* Baseline to record first (chunk A): today's server with the same load (expected to fail by a wide margin).

### 8.1 Chunk A and B as built (2026-10-18)

* `engine/net/server_clock.gd` (`ServerClock`, child "ServerClock" of `BattleNetSync`): `tick` counts at `tick_hz`
  of simulated time, fed by the physics step; `max_catchup_steps` (2) caps the ticks run per advance and counts
  the dropped ones. A pilot-hosted (LAN) battle ticks at 60 Hz, one tick per physics step, with snapshots every
  3rd tick (20 Hz) exactly as before; a dedicated server ticks at `tick_hz` (30, `server.json` key) and
  `ServerClock.configure_dedicated` sets the engine's physics rate, `max_physics_steps_per_frame` and
  `max_fps` (2 x tick_hz, so the headless process sleeps). Snapshots go out on `tick % interval == 0` and are
  stamped with simulated milliseconds derived from the tick number (`_snapshot(sim_ms, states)`, same signature
  as before); `Time.get_ticks_msec()` is gone from the send path. At 30 Hz the 20 Hz snapshot rate becomes every
  2nd tick (15 Hz). Test: `tests/server_clock_check`.
* `engine/net/server_metrics.gd` (`ServerMetrics`, child of the Battle): per-tick milliseconds of work
  (p50/p95/p99/max; frames are timed head to tail, a stalled frame's time is split over its catch-up ticks),
  ticks over budget, max catch-up steps per frame, ENet bytes sent/received per client per second,
  entity counts (entities, humans, bots, far_lod, asleep) and `Performance.MEMORY_STATIC`. The dedicated server
  prints it as a `SERVER STATS ...` line every `stats_seconds` (60, 0 = off).
* `tests/server_load_bench.tscn`: each stage runs in a fresh child Godot process. The server hosts a real
  `Battle` over loopback ENet (`Net.host`, `Net.start_game`); the synthetic humans are raw ENet connections
  (`tests/server_bench_clients.gd`, serviced by a worker thread) registered in the roster, whose soldiers are
  driven on the server side (`tests/server_bench_pilots.gd`); bots are topped up with `InfantryBots.spawn_bot`
  on top of whatever the raid populates itself (extraction sites add their garrisons, so `bots` can exceed the
  stage's number). Map: Varuna's Fall when the Tribes 2 pack is installed (an extraction raid), else a fallback
  versus match on the first installed world (`--map=fallback` forces it). Options: `--stages=s8,s24,s64`,
  `--baseline` (report the misses, exit 0), `--seconds=`, `--warmup=`, `--tick-hz=`, `--map=`. Without
  `--baseline` it exits 1 when a stage misses a section 8 target (p50, p99, catch-up steps, kB/s in/out per
  client, MB, ticks over budget, humans connected, bots spawned, clients dropped) and 2 when a stage does not
  run to the end. Limits: the clients run in the server's process (their cost is small but not zero), carry no
  scene (so no client-side cost) and send no input packets (the inbound figure is ENet's own traffic).

Baseline, today's server (2026-10-18, Windows PC with other agents' Godot jobs running, so noisy; headless,
loopback ENet, 30 Hz tick and physics, 20 s measured after 8 s warm-up and 4 s settle,
`godot ... res://tests/server_load_bench.tscn -- --baseline`). All three stages miss every target:

| Stage (map) | humans | bots | ticks/s | tick p50 / p95 / p99 / max (ms) | ticks over 33 ms | catch-up max | out kB/s per client | static MB |
|---|---|---|---|---|---|---|---|---|
| s8 (Varuna) | 8 | 58 (24 asked + garrisons) | 23.7 | 28.9 / 184 / 207 / 222 | 147 of 473 | 2 | 247 | 1197 |
| s24 (Varuna) | 24 | 80 | 8.7 | 60.5 / 418 / 474 / 474 | 182 of 182 | 2 | 140 | 1269 |
| s64 (Varuna) | 64 | 200 | 2.0 | 190.6 / 2251 / 2487 / 2487 | 46 of 46 | 2 | 24 (only 46 snapshots) | 1379 |
| s8 (fallback, Desert) | 8 | 24 | 30.0 | 21.8 / 31 / 38 / 48 | 13 of 450 | 1 | 133 | 469 |
| s24 (fallback, Desert) | 24 | 80 | 7.5 | 126 / 149 / 202 / 202 | 112 of 112 | 2 | 113 | 506 |

Findings: the 64 + 200 stage runs at about 2 ticks per second (190 ms per tick at best, 2.5 s stalls), as
expected. Snapshots are one broadcast Variant array, about 20 kB at 66 entities, above the 1392 byte MTU
(Godot warns "Sending 19960 bytes unreliably"); at 30 Hz-class rates that is 250 kB/s per client already at
8 humans. Building Varuna blocks the server's main loop for about 27 s (`MB`/`TT` timing lines), longer than the
15 s minimum of `Net.PEER_TIMEOUT_MIN_MS`, so real clients already connected when a raid starts would be dropped;
the bench clients use longer timeouts to survive it (chunk H shortens the load).
Fixed (2026-10-18): the load code now calls `LoadKeepAlive.pump()` (`engine/net/load_keepalive.gd`) between its steps (map
build, shape placement, the raid set-up one physics frame after `_ready`, bot spawns), which services the ENet peer every
100 ms without dispatching game packets. The raid's first-frame set-up (about 12 s of the 27) is inside the window.
`tests/net_load_keepalive_check` (host + client both load Varuna with 4 s peer timeouts; `--control` shows it fails
without the pump). The server's multiplayer layer
accepts a burst of ENet connections over several polls, so a test must wait for `multiplayer.get_peers()`.

### 8.2 Chunk E as built (2026-10-18)

* `engine/net/snapshot_codec.gd` (`SnapshotCodec`): a unit's state is cut into 8 groups (pose, status, resources, triggers,
  damage block, soldier extra, kit, missile stick), each a fixed byte layout: position in cm relative to a 128 m cell
  (cell i16 x 2 only when it changed, height 5 cm steps), yaw / torso / pitch 16 bit, speed i16, alive as a flag bit,
  health a byte, shields / capacitor as halves. A record is `id u16, mask u16, group bytes`; a moving soldier is 15 B.
  `make_packets` splits a client's records so every packet is at most 1280 B (MTU 1392 minus the RPC wrapper) with a
  9 B header `tick u32, tick rate u8, part, parts, forget count, record count`; `decode_packet` returns field patches.
* `engine/net/client_baseline.gd` (`ClientBaseline`): per client, the groups it acknowledged (`confirmed`), the entities
  it may show (`known`), and the packet ticks still waiting for an ack. Every packet is a delta against `confirmed`
  (an unchanged group costs nothing), never chained, so a lost packet only repeats groups. No ack for 32 snapshots:
  the baseline is dropped and the client gets full state again, still at its tier rates. Same-cell poses omit the
  cell only when no packet with another cell is in flight.
* `engine/net/interest_probes.gd` (`InterestProbes`): the grid's `radar_probe` (`RadarContacts.is_on_scope`, cached
  0.5 s) and `occlusion_probe` (`not LineOfSight.is_clear` from the eye, cached 2 s), both in simulated time with a
  per-entity jitter. `games/es1/battle/battle_snapshot_stream.gd` (server) builds, per snapshot: rebuild the grid,
  evaluate each client every 4th snapshot (staggered; every snapshot with the grid disabled), encode each needed
  entity once, then per client `should_send` (tier intervals counted in snapshots: NEAR 15 Hz, MID 5 Hz, FAR 3 Hz at
  30 Hz tick / 15 Hz snapshots) and the changed groups allowed by the tier (FAR: pose + status only, MID: no
  resources / kit / stick). Entities that left a client's set are listed as forgotten until acknowledged.
  `battle_snapshot_receiver.gd` (client) merges the patches into each unit's last state and calls
  `Herc.apply_snapshot` with `dt` = time since that unit's own last update, so far entities interpolate over their long
  interval exactly as near ones; forgotten units are hidden (the node stays: client-side despawn is chunk L); a tick
  is acked once all its parts arrived and every record could be applied (the client sends `_client_ack(ticks)`,
  unreliable, each ack twice).
* Wiring (`battle_net_sync.gd`): the packed path is on for `Net.dedicated` with the interest grid enabled; a LAN
  host keeps the Variant snapshots unless `BattleNetSync.packed_in_lan` (grid off) / `interest_in_lan` (grid on) are
  set, which the tests do. Both RPCs exist on every client, so mixed versions of the sender are fine. Packets use the
  existing unreliable_ordered channel; enter / leave ride in the packets (forget list, first full record) instead
  of a separate reliable message.
* Tests: `tests/snapshot_codec_check` (round trip, delta, MTU, 30% packet and ack loss converges, stale fallback),
  `tests/snapshot_net_check` (two processes over ENet, `-- --interest` for the grid on). `tests/server_bench_pilots.gd`
  makes the synthetic humans' acks (after 100 ms, none lost), because the bench clients are raw ENet connections that
  cannot speak RPC; without acks the server sends tier-rate full state (the fallback).

Out kB/s per client, `server_load_bench --baseline`, 20 s measured, same PC and conditions as section 8.1 (the s64
after-figure covers only 28 ticks because that stage still runs at about 1.4 ticks/s, which bots, pathfinding and map
cost, not the network):

| Stage | before (Variant broadcast) | after (packed, interest) | target |
|---|---|---|---|
| s8 Varuna (8h + 58b) | 247.1 | 12.3 | 60 |
| s24 Varuna (24h + 80b) | 184.5 | 7.4 | 60 |
| s64 Varuna (64h + 200b) | 24 (46 snapshots, not steady) | 4.1 | 60 |
| s8 fallback (8h + 24b) | 133.0 | 5.6 | 60 |
| s24 fallback (24h + 80b) | 132.7 | 5.9 | 60 |

Tick times in these runs are not chunk E's (p50 17-123 ms, dominated by physics and bots), and the bench's inbound figure
stays ENet's own traffic.

### 8.3 Chunks I and J as built (2026-10-18)

* Input frames (`engine/net/input_frame.gd`): the `make_controls` dictionary plus a sequence number in 22 bytes (analogs and
  aim as i16, triggers, target, jet / jump / slot, missile stick); a packet is `body u16, echo tick u32, count, frames` and
  carries the newest 3 unacked frames (`REDUNDANCY`). `engine/net/input_queue.gd` (server): drops duplicates, slots late
  older frames in order, caps the backlog (4), refills to 2 frames after a gap (jitter buffer), repeats the last frame for 6
  ticks on a gap and then lets go of the movement. `ServerPilotLink` (per pilot, set as `Herc.pilot_link`): the body steps
  exactly one queued frame per physics step and keeps `PilotState` (position, velocity, yaw, speed, capacitor, floor) with the
  sequence of that frame; `BattlePilotSync` echoes it (`_pilot_state`, 47 B, only for a new sequence number).
* Handshake (`BattleNetSync`): the server offers (`_prediction_offer`, body id and tick rate, every second) to a pilot with a
  Herc or soldier of his own and keeps the plain `_client_input` path until frames arrive; a client that takes the offer
  sends `_client_input_frames` instead and the server ignores plain controls for a body fed by frames. A link quiet for 500 ms
  is dropped (the client died, boarded a vehicle, or the body changed) and the plain path takes over. Flyers, riders, turret
  seats and bots keep the plain path. LAN hosts are unchanged unless `BattleNetSync.prediction_in_lan` /
  `lag_comp_in_lan` are set (the tests do).
* Prediction (`engine/net/prediction.gd`, `Herc.pilot_link`): the local body (puppet for damage, weapons and snapshots) runs
  `Herc.step_movement` / `Infantry.step_movement` (the same `_drive` as the server) from the pilot's quantized controls, one
  input frame per server tick (`physics_hz / tick_hz` steps per frame: 2 against a 30 Hz server). On an echo it compares the
  server's state with what it predicted for that sequence number: under 5 cm nothing, below 1.5 m (soldier) / 3 m (Herc) it
  rewinds, replays the unacked frames and blends the difference out over 100 ms, otherwise it snaps to the replayed state. The
  snapshot path no longer overwrites the predicted body's speed and capacitor. The server's clock is untouched: a dedicated
  server at 30 Hz integrates one step of 1/30 s where the client replays two of 1/60 s, which shows as sub-metre blends.
* HitHistory (`engine/net/hit_history.gd`): ring of the last second of hit capsules, copied from the EntityTable once per
  tick (`hit_radius` / `hit_height` columns, `make_hit_capsule()` on Herc and Infantry); `find_hit` is an analytic ray against
  the capsules of the two ticks around the view time, interpolated. `LagCompensation` (`engine/net/lag_compensation.gd`):
  `rewind = rtt + interpolation delay` (one snapshot interval, 66 ms at 15 Hz) capped at 250 ms; `cast_ray` skips the
  physics bodies of units, so walls and structures stay where they are, then tests the history up to the first wall.
  `WeaponShot.fire_beam` uses it for the beams of human pilots (`shot.rewind`, from `BattleNetSync.make_rewind`; bots and the
  server's own pilot shoot "now"); an unguided straight projectile of 250 m/s or more (`Projectile.rewind`) is rewound too,
  stepping its view time forward with its flight time. Slower shots (discs, shells, missiles) stay in server time. The round
  trip is measured through the pilot states (`PeerLatency`, any transport), else ENet's own figure.
* Tests: `tests/prediction_check` (real Infantry and Herc movement on both sides, 120 ms round trip, 5% loss, jitter: no snap,
  largest one-step correction under 0.3 m, ends together; a push is blended; a teleport snaps once; a 70% loss burst
  converges; wire formats), `tests/lag_comp_check` (a target at 8 m/s hit at the client's view time with 150 ms of latency,
  missed against the world now; 600 ms is clamped to 250 ms; walls block; the one-second window; round-trip measurement).
  Regression: `game_modes_lan`, `snapshot_net_check` (+ `--interest`), `net_slow_load_check`, `net_transport_check`, the
  dedicated WebSocket e2e (`server_ws_check` + `lan_join --transport=ws --dedicated`, prediction active at 30 Hz against 60 Hz
  physics, no snap) and the LAN co-op e2e (`lan_host` / `lan_join --mode=coop`) all pass.

### 8.4 Chunks L and M as built (2026-10-18)

* Client despawn / spawn (L): the snapshot record has a ninth group, `GROUP_TIER` (u8, per client, sent when it changes and
  acknowledged like any group), so the client knows a unit is at the FAR tier. `BattleFarUnits` (client only, `Battle.far_units`)
  keeps the spawn spec of every bot (AI Hercs and soldier bots; humans, the local player and his target are never touched).
  `BattleSnapshotReceiver`: a bot announced FAR loses its node (`park`: out of `battle.vehicles` and the EntityTable,
  `queue_free`) and is drawn as a proxy; a forgotten bot loses its node and has no proxy; a record that is not FAR builds the node again from
  the kept spec (`Battle.build_unit`, the body of `_spawn`) at the place the proxy stood, with the last damage block re-applied (the
  server will not resend a group the client acknowledged). A dead bot stays a hidden proxy. Other forgotten units stay hidden as before.
  Known gap: the cockpit/HUD radar and command map read the scene nodes, so a parked bot is not on a client's radar until it
  comes within MID range (the interest rules still send FAR radar contacts; drawing them needs the three radar displays to read
  `FarBots` too).
* Far drawing: `engine/render/far_bots.gd` (`FarBots`): one MultiMesh per body kind (soldier capsule, vehicle box), all instances written
  per frame into one buffer (colour per team: allies green, others red), poses interpolated from the previous to the newest pose over
  the time that separated them (far tier: about 3 Hz), dead proxies scaled to zero. No node per bot, no physics, no animation.
* Tests: `tests/far_bots_check` (interpolation, slot reuse on promotion, 200 proxies in the buffers), `tests/far_bots_net_check`
  (two processes with the interest grid on: a bot held 600 m away is a proxy without a node, comes back as a node at 40 m, and at 1500 m
  has neither).
* Net profiles (M): `engine/net/net_profile.gd` (`NetProfile`) reads `engine/net/net_profiles.json`: a `default` entry and one per
  game pack id (`CommandProviders.make_game_pack`: es1, es2, bd, starsiege, tribes, tribes2, tribes_aa, tribes_v), each naming only what it
  changes, `inherits` to start from another. Keys: `tick_hz`, `snapshot_hz`, `tier_intervals`, `interest`
  (near / mid / soldier / vehicle metres), `prediction` (enabled, blend_s, epsilon_m, snap_infantry_m, snap_herc_m), `lag_comp` (enabled,
  max_rewind_ms, beams, projectile_min_mps, include / exclude weapon ids), `evidence`. Unknown keys and out-of-range values are reported
  and ignored. Defaults equal the former constants (30 Hz tick, 15 Hz snapshots, 1/3/5 tier intervals, 100/400 m, 1.5 m / 3 m snap, 100 ms
  blend, 250 ms rewind, beams plus projectiles of 250 m/s or more); Tribes ticks and snapshots at 32 Hz (Torque's 32 ms tick; 31.25 Hz
  rounded), Earthsiege / Starsiege keep 30 Hz / 15 Hz with a 120 ms blend (no original prediction: the loose reconcile keeps the heavy feel).
  tribes_v is an alias entry of tribes (its pack directory was not touched).
* Wiring: `BattleNetSync.profile` feeds the dedicated tick (`ServerClock.make_for_session(profile.tick_hz)` when `tick_hz` is 0 in
  `server.json`, the new default; a number pins every game), the snapshot interval (a LAN host keeps 20 Hz), the interest grid
  (`apply_to_grid`), the rewind cap and weapon policy (`LagCompensation.make_beam_rewind_for` / `is_compensated`; the `rewind` description
  carries the profile as `policy`), and on the client the prediction thresholds (`apply_to_prediction`); `prediction.enabled = false` stops
  the server offering prediction. Test: `tests/net_profile_check`.
* Live-fire (`tests/lag_comp_live_fire`): host and client over ENet, the dedicated pieces on (`packed_in_lan`, `prediction_in_lan`,
  `lag_comp_in_lan`), the client with 100 ms of simulated latency each way (`BattleNetSync.simulated_one_way_ms`, a `DelayLine` on what the
  client sends and receives) aims a Raptor laser at a unit running 16 m/s across its front and holds the trigger. Rewound (`make_rewind`):
  10 to 11 of 26 shots hit (the others are at the turning points, where the aim is off); the same shots with the profile's lag
  compensation off: 1 of 25 (at a turning point). The aim error against the unit's position now is 4.5 to 5 degrees (5 m at 70 m)
  against 1.7 degrees (the unit's centre at a fixed height) for the position the client saw.

### 8.5 Server tick profile and fixes (2026-10-19)

How it was measured: `tests/server_load_bench.tscn` now sets `ServerProfile.set_collision_only(true)` first, as `DedicatedServer.start` does (it
did not, so the bench was timing a full-world server: 1315 MB and about 5400 nodes instead of 646 MB and 4460). `-- --stage=s8 --probe`
adds `tests/server_tick_probe.gd`, run after the warm-up: no flag = a node census and an ablation (each script's nodes switched off in
turn), `--markers` = self time of every scripted node's `_physics_process` / `_process` by script (marker nodes inserted in tree
order; the worst single tick per script is printed too), `--stream` = the phases of one packed snapshot, `--ticked` = time of
`BattleNetSync._on_tick`, `--radar` = microseconds per call of the radar helpers, `--spikes` = frames above 70 ms. The marker
sums add a little overhead per scripted node; use them for ranking.

Top costs found (Varuna s8 unless noted), in order of payoff:

| # | Cost | Where | Fix |
|---|---|---|---|
| 1 | Radar scope of every bot against every human: `SensorTowers.is_revealed_by` walked all com towers (about 110 us per call, twice per `RadarContacts.is_on_scope`, 64 humans x 150 far bots) | `BotSleep.apply_tick` took 120-160 ms once per 0.5 s (the p99 spikes) and the interest probes asked the same thing per client | `SensorTowers.begin_cache` / `end_cache`: one scope per director step / interest refresh reads the towers once and remembers (side, unit) answers (2 us per call; a call outside a scope is live and unchanged, only cheaper: distance first). `BotSleep` steps a quarter of the units every quarter period on a server (`SERVER_SLICES`; same cadence per unit, no 150 ms stall), asks one viewer per (side, radar mode) where a Tribes sensor net decides, and skips viewers beyond their range with no tower reach |
| 2 | Tribes turrets (34): the rig posed the turret meshes every tick (nobody sees them) and every target search scanned all units with script predicates; all turrets thought on the same tick | `tribes_turret.gd` 8-11 ms per tick | no `TribesTurretRig` on a collision-only server; `TurretTargeting.find_nearest` filters by native distance first and tests arc / line of sight (a physics ray) nearest first until one passes; first search staggered over 8 slots on a server |
| 3 | Snapshot stream at the Tribes profile's 32 Hz (every tick): per client the interest evaluation (radar probe over all entities: cache lookups with a clock call and an allocation each), per-entity `should_send` / `tier_of` calls, per-client RPC | `server_clock.gd` (the `ticked` signal) 9-65 ms per tick, the largest block at 24+ clients | radar probe in one batch call per client with int-coded cache answers, shared across the clients of a side where a sensor net decides (Tribes), and the client's radar picture kept for half the cache life; `InterestGrid._add_nearby` inlined; `_make_records` walks the tier map once; interest evaluation cadence scaled to the snapshot rate (about 4 a second as designed, was 8 at 30 Hz); sleeping bots reuse their last encoding; the clients' packets are built on `WorkerThreadPool` from 6 clients up (about 1.9x on 16 cores: GDScript allocation contends) and sent from the main thread |
| 4 | Soldier / Herc target search by every bot (`InfantryBot._find_target`, `AIPilot._find_target`): all vehicles, script predicates first | 3-6 ms per tick at 80 awake bots | native distance test first |
| 5 | `BattleBounds` world-floor test per unit per tick (terrain sample + all building boxes) | 2 ms | a server checks each unit every 4th tick with the time covered |
| 6 | `OccupancyDirector._board_by_touch`: every on-foot soldier x every vehicle, full boarding check | 2.5-43 ms (64 humans + 200 bots) | list the touchable vehicles once per tick, 60 m prefilter |
| 7 | Client-only work on the server: effect sprites, beams, projectile looks (`FxPlayer`, `Projectile`), HUD / nameplates / chat panel / extraction + revive HUD / command-map input (`ServerProfile.apply_client_only` sets `PROCESS_MODE_DISABLED`; they still accept calls) | 1-8 ms per frame at s64 | skipped on a collision-only server. Cameras, audio players and the objectives panel (which also sends the host's lines) stay: they cost nothing per tick |

Measured, `server_load_bench --baseline`, 20 s measured, quiet PC (no other Godot job), headless, 30 Hz. Before = commit b6c2b87 with only
the bench change above (15 Hz snapshots; the Tribes 32 Hz profile did not exist yet); after = the working tree of 2026-10-19, which snapshots
every tick on Varuna (twice the snapshot work of the before runs):

| Stage | before p50 / p99 (ms) | after p50 / p99 (ms) | ticks/s after | target p50 / p99 |
|---|---|---|---|---|
| s8 Varuna (8h + 56b) | 22.4 / 142.5 | 6.9 / 11.2 | 30.0 | 12 / 25 met |
| s24 Varuna (24h + 75b) | 55.7 / 259.8 | 21.2 / 32.7 | 29.9 | 12 / 25 not met |
| s64 Varuna (64h + 200b) | 264 / 1586 | 104.5 / 168.7 | 9.5 | 12 / 25 not met |
| s8 fallback (8h + 24b) | 11.4 / 19.1 | 6.5 / 10.2 | 30.0 | met |
| s24 fallback (24h + 80b) | 40.0 / 48.4 | 27.0 / 37.5 | 30.0 | not met |
| s64 fallback (64h + 200b) | 143.6 / 180.0 | 82.8 / 133.0 | 11.6 | not met |

What is left at s64 (Varuna, ms per tick, marker sums): the snapshot pipeline about 55-60 (interest refresh about 12, encoding the
awake units 7, the clients' packets 25 on threads and 47 on one, `record_sent` 4, the RPCs 1.5), infantry bodies 10, `BotSleep` 8,
turrets 5, projectiles 5, weapons 4. A client receives about 33 records per snapshot (of 77 visible), so 64 clients x 33 x 32 Hz is 67k
records a second at about 7 us (threads) to 17 us (one core) each in GDScript: that is the wall. The cheaper ways on, in order: (1) share
one record between clients whose acknowledged baseline is the same (needs a baseline signature in `ClientBaseline`), (2) lower the NEAR /
MID tier rates or the interest radii for 64-player servers in `net_profiles.json` (a profile choice: 32 Hz to every near unit is the
original Tribes feel), (3) a governor that serves a client every 2nd tick when the tick overruns, (4) the encoder as a GDExtension. The
bench's own `server_bench_pilots` (4 ms at s64) is part of the measured tick. A segfault at exit of `--probe --markers` is the probe's
(markers are left in the tree now).

Tests run after the changes: `compile_all` (725 scripts, 0 failed), `interest_grid_check`, `snapshot_codec_check`, `snapshot_net_check`
(+ `--interest`), `server_profile_check`, `bot_lod_check`, `command_map_check`, `aa_turret_check`, `tribes_base_check`,
`tribes_vehicle_check`, `vehicle_riders_check`, `bot_path_check`, `weapon_fx_check`, `far_bots_net_check`, `net_profile_check`,
`net_transport_check`, `standardization_check`, `aa_bounds_check` pass. `death_fx_check` fails on the tribes_aa / tribes_v packs (no death
steps in their data, not this change); `bounds_maps_check` did not finish in 280 s (not compared).

#### 8.5.1 Shared records, governor, tier rates (2026-10-19, second round)

Done, in the order of payoff:

1. **One record per (entity, acknowledged state, tier), shared by every client** (`BattleSnapshotStream`, `ClientBaseline`). Every group of
   an encoded unit gets a version number that only moves when its bytes change. A client's baseline keeps the version of each group it
   acknowledged and a signature of them (a sum of version x group weight, updated at the acknowledgement, so clients with the same
   acknowledged state, however they got there, have the same signature). The delta record for "what differs from signature s at tier t" is
   built the first time a client asks and reused by the next (`SharedRecord`: bytes with and without the pose cell; the cell shortcut runs
   on int cell codes). Per client per snapshot that leaves a tier-map walk with a dictionary hit per entity; the packets are still built per
   client (on the worker threads from 6 clients). 83-87% of the records are reused on Varuna (41-65% on the fallback map, where 200 awake
   bots move every tick). `ClientBaseline`'s byte API (`make_changed_groups`, `record_sent`) stays for the codec check.
   Tier intervals and interest evaluations now count each client's own servings (`ClientBaseline.serves`).
2. **Overrun governor** (`engine/net/snapshot_governor.gd`, on in `BattleNetSync` when `Net.dedicated`, needs 8+ clients, reads
   `ServerMetrics.recent_tick_ms`): above 85% of the tick budget it climbs one level per 6 snapshots: 1 FAR interval x2, 2 FAR x3, 3 clients
   served every 2nd snapshot (round-robin), 4 every 3rd. Back down one level after a hold-down (96 snapshots, doubling when the load comes
   straight back) under 60%. A skipped snapshot loses nothing (packets are deltas against what the client acknowledged, each unit's update
   carries the time it covers, so the client interpolates over the gap); interest evaluations scale with the servings.
3. **Tier rates** (`net_profiles.json`): Tribes MID / FAR from every 3rd / 5th snapshot to every 4th / 8th (32 Hz near, 8 Hz mid, 4 Hz far;
   was 10.7 / 6.4 Hz), about a sixth fewer records at s64; interest radii kept (100 / 400 m, 300 m soldiers, 800 m vehicles: the fight stays
   per-tick). The ES / Starsiege profiles stay (15 Hz snapshots, 5 / 3 Hz mid / far is already low).
4. **Interest probes**: the radar answer lives 1 s (was 0.5), a client's radar picture is reused 0.5 s, and a sensor-net team shares one
   picture; the refreshes of one client's answers are spread over half the cache life (they all fell within 97 ms: a burst of 264
   evaluations or ray casts per client each second).

Bench additions: `server_load_bench` prints `stream cost ms/snapshot` (p50 / p99 / max and the mean of encode / interest / build /
deliver) and the sharing rate and governor state; `ServerMetrics` exists from the warm-up on (the governor reads it); `server_tick_probe
--stream` times the new phases. New check: `tests/snapshot_share_check` (signatures, cell codes, governor levels).

Measured, `server_load_bench --baseline`, 20 s, headless, 30 Hz tick. The PC was NOT quiet: 2 to 4 other Godot test processes (other
agents' checks) and about 10% CPU were running throughout, so read the figures to a few ms. Before = the "after" column of section 8.5 above
(Varuna) and the first run of this session (fallback is not in the earlier table at s64).

| Stage | before p50 / p99 (ms) | after p50 / p99 (ms) | stream ms per snapshot p50 / p99 | governor at end | target |
|---|---|---|---|---|---|
| s8 Varuna | 6.9 / 11.2 | 6.9 / 11.3 | 2.1 / 3.6 | 0 | met |
| s24 Varuna | 21.2 / 32.7 | 18.9 / 32.7 | 6.2 / 15.8 | 0 | not met |
| s64 Varuna | 104.5 / 168.7 (9.5 ticks/s) | 69.9 / 113.2 (13.6 ticks/s) | 15.3 / 67 | 4 | not met |
| s8 fallback | 6.5 / 10.2 | 6.6 / 10.1 | | 0 | met |
| s24 fallback | 27.0 / 37.5 | 21.4 / 43.5 | | 2 | not met |
| s64 fallback | 82.8 / 133.0 | 62.5 / 112.6 (15.1 ticks/s); out 85.6 kB/s per client (target 60) | | 4 | not met |

Why the target is still missed: the snapshot stream is no longer the wall. At s24 it costs 6 ms of 19 (encode 1.7, interest 2.0, build
2.6, deliver 0.6); at s64 with the governor at its top level (21 of 64 clients served per snapshot) 15 ms of 70 (encode 6.5, interest 11.8
averaged over the snapshots, build 6.1). The other 13 ms (s24) and 55 ms (s64) are the simulation: `--markers` at s64 gives infantry
bodies 11, `BotSleep` 8, projectiles 6, turrets 6, infantry weapons 4, occupancy 3, the bench's own pilots 3, bounds 2, plus the physics
step and navigation. To get p50 under 12 ms at s24 the simulation alone would have to fall from 13 to under 8 ms with the stream at its
current 6 ms; at s64 it is not reachable in one process in GDScript with 200 awake bots whatever the stream costs. What would move it,
in order: (1) bot LOD for the sim itself (fewer awake bots per server: the `asleep` count is already 134 of 200 and the other 66 are the
cost); (2) native (GDExtension) evaluation of the radar / nearby sets, the largest stream phase at s64 (about 12 ms): the radar answer is
generic GDScript per entity, so it needs the sensor rules ported, not just a loop; (3) the infantry body step as a batch (11 ms).
**GDExtension encoder: not warranted now.** Encoding plus record building is about 12 ms at s64 and 4 ms at s24 after the sharing; a native
encoder would save perhaps two thirds of that, which does not change the verdict at either size. Worth building only after the simulation
costs above are down, and then together with the interest evaluation (one native "snapshot builder" over the EntityTable). Splitting a
64-player match over two processes (sim and snapshot sender) is the other structural option and costs more than either.

Tests run after the changes: `compile_all` (729 scripts, 0 failed), `snapshot_codec_check`, `snapshot_share_check`, `snapshot_net_check`
(plain and `--interest`), `interest_grid_check`, `net_profile_check`, `prediction_check`, `lag_comp_check`, `lag_comp_live_fire`,
`far_bots_net_check`, `game_modes_lan` (host and client, plain and `--interest`) and `net_transport_check` pass.

#### 8.5.2 Simulation cost round (2026-10-19, third round)

Each cost was timed in place (a temporary microsecond accumulator per section, removed again), not guessed from the marker sums. Findings
and changes, all outcome-neutral (same tiers, same shots, same targets; only the cost moves):

| Cost (s64 Varuna, ms per tick, marker sums) | before | after | what it was / change |
|---|---|---|---|
| `BotSleep` | 8.4 | 1.7 | the radar test for units beyond sight (about 290 us per unit): with 64 viewers on 64 different sides (the bench is a free-for-all) every unit asked `SensorTowers.is_revealed_by` once per viewer. Now: the towers reaching a unit are found once per unit per director step (`SensorTowers.make_reaching_towers`, `is_reached_by_any`), a unit beyond every viewer's radar range and every tower's reach is answered at once from the distance already computed, and otherwise only the viewers in range plus the viewers allied to a reaching tower are asked (`_make_tower_allies`, per step). A sensor net asks one viewer per (side, radar mode) |
| turrets | 5.3 | 3.3 | `_send_aim`: every turret think (5 a second) sent an aim RPC to all 64 clients, 570 us a call, 1.1 s of the 18 s run; an idle turret now repeats it every 10th think only (`AIM_REPEAT_THINKS`; a lost packet is healed within 2 s; a turret with a target still sends every think). Output per client at s24 fell from 24.5 to 14.3 kB/s. What is left is the shots (`_play_fire.rpc`, about 1.4 ms a shot at 64 clients) and the searches (110 us each) |
| projectiles | 6.7 | 4.0 | a plain (not rewound) step reuses one `PhysicsRayQueryParameters3D` (no allocation per tick, no typed array copy), no exclude array after the muzzle clearance, and a collision-only server skips `look_at` (nobody sees a shot fly). Impacts (355 us each: damage, splash) and spawns are unchanged; pooling was not done (a spawn is not the cost) |
| occupancy (`_board_by_touch`) | 3.2 | 3.1 (no gain measured) | the touchable list is built by a loop with the type test first instead of a lambda `filter` over 264 units |
| interest (`_add_always_relevant`) | | | visits only the client's own unit, target and team rows (`_team_rows` of the grid, built in `rebuild`), in the same ascending row order, so the tier map's key order is unchanged; the full loop remains when the table changed after the rebuild |
| infantry | 13 to 15 | same | NOT reducible without changing outcomes: 85% of it is `move_and_slide` (about 220 us a call on Varuna: terrain trimesh / heightmap chunks and building colliders under the capsule, against 14 us on a plain heightmap in a scratch scene; a 0.5 m floor snap is not the cost: snap 0 gave the same time). Only 6% of the calls are by a soldier standing still, so "move only when moving" would save little and would change `velocity` / floor state seen by the snapshots. Done: `apply_fall_damage` returns before reading the slide collisions when the speed cannot exceed `fall_min_speed` (the impact along a normal is never more than the speed), and `_apply_held_fall` tests the floor before `get_real_velocity` |
| infantry weapons | 3.3 | same | idle weapons could sleep (`set_physics_process(false)` until the trigger is set), but a weapon woken inside the frame by a brain that runs earlier in tree order would first run next frame: one tick later than today. Left alone |

Measured, `server_load_bench --baseline`, 20 s, headless, 30 Hz, PC not quiet (the user's editor and one more Godot process stayed open;
nothing else running), so read to about 2 ms. Before = the first runs of this round on the same tree (the "after" column of 8.5.1 was
taken on a different load):

| Stage | before p50 / p99 (ms) | after p50 / p99 (ms) | ticks/s after | target |
|---|---|---|---|---|
| s24 Varuna (24h + 75b) | 20.7 / 31.6 | 18.2 / 30.4 | 30.0 | 12 / 25 not met |
| s64 Varuna (64h + 200b) | 81.1 / 138.1 (12.2 ticks/s) | 62.9 / 111.9 (14.8 ticks/s) | 14.8 | 12 / 25 not met |

What stands in the way now: s24 is infantry (about 5 ms of `move_and_slide` for 24 humans and the awake bots) plus the stream (6.5 ms) plus
the physics step (about 4 ms); s64 adds 64 humans' `move_and_slide` (about 14 ms) to that. To get under 12 ms the next real levers are
(1) cheaper soldier collision (a simpler capsule-vs-world test for NEAR bots, or Jolt: both change outcomes, so they are a gameplay decision),
(2) the stream at its current 6.5 ms (s24) / 16 ms (s64), (3) fewer awake bots. The interest candidate lists by grid cell for a range-limited
radar were not built: the Varuna bench is never range-limited (pulse sensors reach everywhere), and the fallback map is small.

Tests run after the changes: `compile_all` (731 scripts, 0 failed), `bot_lod_check`, `infantry_check`, `infantry2_check`, `extraction_check`,
`varuna_check`, `scope_check`, `tribes_base_check`, `game_modes_check`, `snapshot_codec_check`, `snapshot_share_check`, `snapshot_net_check`
(plain and `--interest`), `interest_grid_check`, `prediction_check`, `lag_comp_check`, `far_bots_check`, `far_bots_net_check` and all 7
`trace_*_check` goldens (not re-recorded) pass.

#### 8.5.3 Cheap body step for far soldiers, per-server bot cap (2026-10-19, fourth round)

**Cheap body step** (`engine/infantry/infantry_cheap_step.gd`, used by `Infantry._drive`). An AI soldier with `far_lod` set (the BotSleep MID
tier and beyond; humans and NEAR bots never) no longer calls `move_and_slide`. The velocity is integrated and the body is placed by rays
that pass through unit bodies: one down ray at the new spot finds the floor (terrain, building floors and roofs alike; a grounded soldier
follows it up and down a step's worth), one waist-high ray toward the new spot stops him at a wall (he slides along it once, else stands),
an airborne soldier (jump, jet, a step off an edge) falls under the same gravity and lands when his feet reach the floor, taking the
armour's fall damage along the ray's normal (`InfantryMotion.apply_impact_damage`, shared with `apply_fall_damage`). `Infantry.cheap_floor`
carries the floor state (`is_on_floor_now()` replaces `is_on_floor()` in the soldier and in the bot's jet jump, since the real body's flag is
stale while it is not stepped). On promotion the first full tick calls `apply_floor_snap()`, so nothing teleports or jitters; tests: the
NEAR-vs-MID distance (55.0 vs 54.3 m in 5 s, 10% rule) and a promotion with no jump in `bot_lod_check`, and new
`tests/infantry_cheap_step_check` (ground following, wall stop, jump and landing, 60 m fall damage, promotion). Cost: about 29 us per
`_drive` in that check (3 rays at most), against about 220 us per `move_and_slide` on Varuna (8.5.2). Not simulated for MID bots: pushing
against other bodies, the held-fall rescue (needs slide collisions) and footstep floor type (the server poses nobody).
`--no-cheap-step` on `server_load_bench` switches it off (the "before" below).

**Result: no measurable gain in the bench**, and the reason is where the bots are, not the step. A MID soldier already stepped every 4th tick
(`LOD_FAR_STRIDE`), and on Varuna 120 to 130 of the 200 bots are ASLEEP, so only a handful of awake bots are MID; the 64 humans and the NEAR bots keep `move_and_slide`. `--probe --markers` at s24 on the fallback map (41 to 48 MID bots) gives
`infantry.gd` 2.06 ms before and 2.19 ms after (noise). The step is correct and cheap, and it pays when many bots stand MID (a big
open map with a wide sight range, or a server whose humans are spread out), but the s24 / s64 numbers are decided by the humans' own bodies,
the stream and the physics step. The machine: the user's editor and a stale test process of another agent were open but idle, other agents ran
short Godot jobs during the first minutes (the runs below were back to back, alternating before and after), so read to about 3 ms; s64 also
swings with the governor level (4 in every run).

Measured, `server_load_bench --baseline --stages=s24,s64`, 20 s, 30 Hz, headless:

| Stage | before p50 / p99 (ms) | after p50 / p99 (ms) | far_lod bots (asleep) before / after | target |
|---|---|---|---|---|
| s24 Varuna | 19.8 / 32.3 | 19.8 / 32.4 | 67 (65) / 65 (64) | 12 / 25 not met |
| s64 Varuna | 61.6 / 110.9 (15.0 ticks/s) | 69.4 / 99.7 (14.3 ticks/s) | 144 (130) / 130 (120) | 12 / 25 not met |
| s24 fallback | 25.5 / 50.0 | 24.3 / 50.9 | 48 (0) / 41 (0) | not met |
| s64 fallback | 68.1 / 134.7 (13.2 ticks/s) | 83.5 / 145.5 (11.3 ticks/s) | 11 (0) / 13 (0) | not met |

(`far_lod` counts every bot at MID or beyond, ASLEEP ones included, so on Varuna only 1 to 10 awake bots are MID. The s64 differences are the
run-to-run spread of a governed, overrunning server (stream cost per snapshot 15.7 vs 16.6 ms on Varuna), not the step.)

**Per-server bot cap** (`engine/bot_budget.gd`). Setting `max_bots` (0 = no cap) in `server.json` / `--max-bots=N` (`ServerConfig`,
`deploy/server.json.example`, `docs/SERVER_DEPLOY.md`) reaches the battle through `LobbySettings`/`Net.settings` (`BotBudget.CONFIG_KEY`;
a battle config key of the same name wins). It caps live AI soldiers plus AI vehicles (dead ones do not count). Every spawner asks
`BotBudget.admits(battle, priority)`; the priorities leave room for what matters: CRITICAL (mission units) is never refused but counts as live;
MATCH (the match's `infantry_bots`, config `ai` units, game-mode defenders) up to the cap; NEAR (extraction garrison, squad or response soldier
or vehicle within 250 m of a human) up to 90% of it; DISTANT up to 70%. Wired into `InfantryBots.spawn_all` / `spawn_bot` (so SiteSpawner,
extraction squads and the response squads, whose specs carry a faction, are classed by distance), `ExtractionSquads._spawn_vehicle`,
`GameModeDefenders.spawn_all` and `BattleSpawner.spawn_roster`. A refused `spawn_bot` returns null (all callers already handled it); the
site spawner tries again on its next reinforcement timer. Mission waves (`spawn_ai`, `spawn_bot` with a mission) are CRITICAL and not gated
because their callers do not handle a null unit; they count against the cap, so garrisons give way. Not done: despawning a distant garrison
to make room for a critical spawn, and the lobby's bot slider (Game Options, `engine/ui/lobby/game_options_panel.gd`, left to the UI work: write
`BotBudget.CONFIG_KEY` into the settings dictionary `LobbySettings.make` returns, and into `MatchFlow`'s config). Test: `tests/bot_budget_check`.

Tests run: `compile_all` (759 scripts, 0 failed), `bot_lod_check` (with the new MID section), `bot_budget_check`, `infantry_cheap_step_check`,
`infantry_check`, `infantry2_check`, `extraction_check`, `varuna_check`, `game_modes_check`, `far_bots_check`, `scope_check` and the 7 `trace_*_check`
goldens (not re-recorded) pass.

#### 8.5.4 Jolt for the server, interest cell index (2026-10-21, fifth round)

**(a) Jolt Physics: kept, as a server-only setting.** Godot reads `physics/3d/physics_engine` once at start-up (no script can switch it, there is
no `--physics-engine` flag in 4.6, and no `headless` feature tag), so the server profile is a file: `deploy/server_override.cfg`
(`3d/physics_engine="Jolt Physics"`) is copied to the gitignored `game/override.cfg` by `deploy/install.sh`, the Dockerfile
(`Dockerfile.dockerignore` lets it through) and, for a bare run, by hand (`docs/SERVER_DEPLOY.md` section 3). Dev, client and test runs keep
GodotPhysics, so the trace goldens are untouched. The bench cannot switch engines either: the "after" runs below are a scratch copy of `game/`
with the same two lines in its `project.godot`. `--probe --markers` at s24 (24 humans, 80 bots): `infantry.gd` 6.5 ms per tick -> 2.15 ms
(`move_and_slide` on Varuna roughly 3x cheaper). `infantry_check`, `infantry2_check`, `bot_lod_check`, `flight_check`, `held_weapon_check`
(1948 checks) all pass under Jolt. Caveat: a client predicts its soldier on GodotPhysics and the server moves it on Jolt, so slide / step
details at walls and edges differ slightly; reconciliation absorbs it, but a client moving on Jolt too would remove the difference (not done:
changes every client and the goldens).

**(b) Cheaper static collision: not built.** Varuna's terrain already is a `HeightMapShape3D` (`MapTerrain._add_heightmap_collision`; trimesh chunks
only for terrains with holes) and there are only 36 plain `StaticBody3D` plus 37 base objects and 34 turrets, so there are few bodies to merge.
Under Jolt the soldiers' whole script cost is 2 ms, so a heightfield / merge rework of the world would chase well under 1 ms.

**(c) Interest pass: one part done.** Timed per part (`server_tick_probe --stream`, s64, 64 clients, with the sensor-tower cache scope that
`_refresh_interest` opens): evaluating all clients once 46 ms, of which the nearby-cell scan 24 ms, always-relevant 0.5 ms, radar contacts 0.8 ms
(the radar picture is cached; its misses are paid inside the refresh scope and are 2 to 3 ms per client per second in the bench's
64-side free-for-all, a team-shared picture where a sensor net decides). `InterestGrid` now keeps a `CellIndex` per class (soldiers, other
units) of the populated cells and a client visits only the populated cells inside its own view box for each class (soldiers 300 m, vehicles
800 m): the scan went 24 -> 17 ms per all-client evaluation (about -1.5 ms per tick at s64, under 0.5 ms at s24; the bench's
`interest` phase did not move beyond noise). The order of the tier map's keys changed (soldiers before other units; was cell order); the
interest, codec, share, net (plain and `--interest`) and far-bots net checks pass. Per-cell cached radar coverage was NOT built: the cache
already holds the answer per client and entity, the answer depends on the viewer's range, mode and the unit's cloak, and an exact per-cell
version would change what a client is told about; the remaining radar cost is the cache misses, which a shared team picture removes where
the game has a sensor net.

Measured, `server_load_bench --stage`, 15 s, 30 Hz, headless, two alternating runs each, PC otherwise idle at the start of the runs (no other
Godot process) but other agents ran Godot checks during them, so read to about 3 ms. Before = GodotPhysics + the previous interest grid
(the same tree otherwise); after = Jolt + the cell index:

| Stage | before p50 / p99 (ms) | after p50 / p99 (ms) | ticks/s after | target |
|---|---|---|---|---|
| s24 Varuna | 22.3 / 34.5 and 20.7 / 34.4 | 18.0 / 30.0 and 19.0 / 50.0 | 29.9 and 29.2 | 12 / 25 not met |
| s64 Varuna | 77.4 / 151.8 and 78.3 / 122.0 (12.1 to 12.3 ticks/s) | 68.7 / 176.8 and 66.2 / 131.3 (13.9 to 14.2 ticks/s) | 14 | 12 / 25 not met |

So Jolt takes about 3 ms off s24 and 10 ms off s64 at p50; the p99 swings with the other agents' load (one outlier each way). The target is
still not met: at s24 the stream (about 7 ms: encode 2, interest 2.5, build 2.7, deliver 0.7) plus roughly 8 ms of many small scripted
nodes (turrets 1.0, net sync 0.8, bounds 0.8, flyers 0.7, weapons 0.7, occupancy 0.7, bot sleep 0.7, projectiles 0.6, pilots 0.6) leave
about 18 ms; at s64 the stream under the governor and 200 bots are the wall as before. Next levers unchanged: fewer awake bots (`max_bots`),
a native snapshot builder, or a second process for the sender.

Tests run: `compile_all` is the integration agent's batch; the files here are `interest_grid`, `snapshot_codec`, `snapshot_share`, `net_profile`,
`snapshot_net` (plain and `--interest`) and `far_bots_net` checks (pass), plus the five Jolt checks above (pass, Jolt scratch copy).

## 9. Conflicts with parallel work

* Do not touch: `engine/mission/*`, `tests/mission_*_check`, `tests/trace_*_check`, `games/tribes_v/*`.
* This document touches none of them. The plan avoids them: the bot/LOD chunk (F) edits
  `engine/extraction/site_spawner.gd`, which is extraction, not mission; `TribesBase.is_on_radar` in
  `games/tribes/tribes_base_object.gd` is read by the interest rules but not edited; the Tribes V pack only needs
  its `net_profile.json` in chunk M, which waits until the tribes_v edits settle. If mission scripts spawn AI
  units through `engine/mission/*`, they must register in `EntityTable` through the same `net_id`/`battle.vehicles`
  path so chunk C/F need no change there; verify when those land.
* Merge-order risk: chunk H (server profile) edits shared builders; land it early or coordinate with whoever is
  editing `map_builder.gd`/`shape_instance.gd`.
