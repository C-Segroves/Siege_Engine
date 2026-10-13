# Engine weapon schema (all packs)

Every game's weapons are converted into `gamedata/<pack>/gameplay/weapons_engine.json` with this
schema, in **real-world units in the shared metric world** (metres, seconds, m/s — use the pack's
world scale from `game/engine/packs.gd` WORLD_SCALE: es1/es2 1/256 m per unit, bd 0.00215, tribes 1.0,
and time bases from `gamedata/<pack>/units.json` / `docs/formats/units.md`). Damage stays in the
Earthsiege damage scale (shield points / armour points, ES1 Herc shields 3500 per pair of banks,
components 300–2000 hp); convert other games' damage into that scale and note the factor.

```json
{
  "pack": "bd",
  "damage_scale_note": "how damage was converted",
  "weapons": [
    {
      "name": "BLASTER",              // unique within the pack (id becomes "<pack>:<name>")
      "display_name": "Blaster",
      "category": "herc",             // REQUIRED: "herc" | "infantry" | "vehicle" - families never mix
                                      //   (Herc weapons only on Hercs/Cybrids; Tribes infantry weapons only
                                      //    on armors; Tribes vehicle weapons only on Tribes vehicles)
      "source": "SIM.EXE 0x....",     // evidence
      "size_class": "light|medium|heavy|missile|special",   // what hardpoints accept it
      "hardpoint_mask": 15,            // ES1-style mask if known (7 small/missile, 15 medium, 31 large)
      "kind": "beam|cannon|missile|grenade|mine|bomb|plasma|flame|emp|ecm|artillery|other",
                                      //   bomb: dropped straight down (Tribes 2 Thundersword)
      "fire_group": 1,                // optional trigger: 1 primary, 2 secondary (default: by kind)
      "range": 200.0,                  // m
      "refire": 0.5,                   // s between shots (or bursts)
      "burst": 1,                      // shots per trigger pull / salvo
      "burst_interval": 0.0,           // s between shots in a burst
      "spread_deg": 0.0,               // random cone
      "ammo": -1,                      // -1 unlimited/energy, else rounds (salvos for missile racks)
      "energy": {"min_charge": 0, "per_shot": 0},   // capacitor model (ES1: cap 960, +200/s)
      "heat": null,                    // if the game models heat: per shot / dissipation
      "damage": {"shield": 600, "armor": 900, "splash": 0.0, "splash_radius": 0.0},
      "effects": {"emp_shield_drain": 0, "elf_leech": 0, "disable_seconds": 0},
      "projectile": {                  // null for instant beams
        "speed": 300.0,                // m/s
        "gravity": 0.0,                // m/s^2 (lobbed grenades/artillery)
        "lifetime": 2.0,               // s
        "guidance": "none|sarh|arh|arm|eo|heat|wire",
        "turn_rate_deg": 0.0,          // homing
        "arm_delay": 0.0,              // mines/missiles
        "proximity": 0.0,              // m (mines/flak)
        "shape": "bd:BLASTER",         // projectile model (pack-qualified shape id) or null
        "trail": "none|smoke|glow",
        "inherit_velocity": 0.0,       // optional: share of the shooter's velocity added (Tribes velInheritFactor)
        "color": [1.0, 0.9, 0.4]       // optional: projectile colour when there is no model
      },
      "beam": {"color": [1.0, 0.3, 0.2], "width": 0.2, "duration": 0.12, "count": 1},   // beams only
      "model": {"mount_shapes": ["es1:MECHWPNS_22", "..."],   // weapon pod model(s) per mount group (BD pods are baked into the Herc)
                "pod_extent": [50, 0, 50],         // optional, 3Space: pod half extent, pushed out per GL mount group
                "muzzle_units": [0, 630, 0],        // optional: muzzle in the pod's own frame (shape units)
                "fire_offsets": [[0, 2.3, 0.73]]},  // optional, Starsiege: every weaponShot offset (docs/formats/weapon_mounts.md)
      "sounds": {"fire": "<pack sound stem>", "hit": "<stem>"},   // a stem may be qualified: "tribes2:shrike_blaster"
      "fx": {"projectile": {...}, "beam": {...}, "trail": {...}, "muzzle": "<effect>",
             "impact": {"miss": ["<effect>"], "shield": [...], "armor": [...]}},   // the game's own look:
                                      //   docs/formats/weapon_fx.md (effects in gamedata/<pack>/fx/effects.json)
      "notes": "anything uncertain"
    }
  ]
}
```

Weapon families are kept strictly separate (user requirement): the armory/loadouts only offer
weapons whose `category` matches the platform (`herc`, `infantry`, `vehicle`). Missing = `herc`.
Infantry-family weapons (Tribes armours' hand weapons) live in `gameplay/weapons_infantry.json` of the same
schema (tools/export_tribes_infantry.py, docs/formats/tribes_infantry.md); only soldiers carry them.
Vehicle-family weapons (Tribes) are the fixed armament of their vehicles (`"fixed_loadout": true`) and
are never offered anywhere: see tribes_vehicles.md.

Rules: keep values the original code uses; mark guesses in `notes`. Sounds must exist as WAV under
`gamedata/<pack>/audio/sfx/...` (convert them; 8-bit PCM 11025 Hz for 1994–95 Dynamix games).
Projectile/effect shapes must be exported to `gamedata/<pack>/shapes/` in the ES1 shape JSON schema.
Every weapon carries an `fx` block written by the pack's fx exporter (`tools/fx_<pack>.py`, importer step
`weapon_fx`): how its shot, beam, trail, muzzle flash and impacts (miss / shield / armour) look in its own game,
referencing the pack effect library `gamedata/<pack>/fx/effects.json` (sprites extracted from the disc into
`gamedata/<pack>/fx/sprites/`). The 3Space v1 table packs (ES1) carry it per weapon in `gameplay/weapons.json`.
A weapon without one is drawn with a generic look and fails `tests/weapon_fx_check`. Contract and per-game
decoding: `docs/formats/weapon_fx.md`.
