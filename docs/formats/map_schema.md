# Engine map schema (arena maps from every game)

Every game's playable maps are converted into `gamedata/<pack>/maps/<map_id>/map.json` plus
assets in that folder. Coordinates are **already in the engine frame**: metres, **y up**,
Godot convention (x right, -z = original north/forward). Convert Z-up originals with
`(x, y, z)_orig * metres_per_unit -> (x, z, -y)`. Rotations as yaw/pitch/roll in degrees in the
engine frame (or a 3x3 basis "basis": [[...],[...],[...]] in engine frame when not pure yaw).

```jsonc
{
  "pack": "tribes", "id": "Raindance", "name": "Raindance",
  "source": "base/missions/Raindance.mis",          // evidence
  "modes": ["ctf", "deathmatch"],                   // engine game-mode ids the map supports (docs/formats/game_modes.md)
  "original_modes": ["CTF"],                        // what the mission itself declares
  "mode_objects": [...], "mode_settings": {...},    // flags, switches, Nexus, goals ...; the mission's limits (game_modes.md §2)
  "world": {"pack": "es1", "index": 0, "zone": 0},  // optional: Earthsiege arena maps, ground built by WorldBuilder
  "bounds": {"min": [x, z], "max": [x, z]},         // playable area (metres, engine x/z)
  "terrain": {                                       // null for indoor/arena maps (Battledrome)
    "heights": "height.r32",          // float32 little-endian, row-major, rows = +z, cols = +x
    "size": [256, 256],               // samples (cols, rows)
    "square": 8.0,                    // metres between samples
    "origin": [x0, z0],               // engine x/z of sample (0,0)
    "height_scale": 1.0,              // heights already in metres if 1.0
    "albedo": "albedo.png",           // baked colour map covering the whole terrain (RGB)
    "albedo_repeat": 1.0,             // 1 = one image across the terrain; else tile count
    "detail": "detail.png",           // optional tiled detail texture
    "holes": "holes.png"              // optional L8 mask, one pixel per square ((cols-1) x (rows-1)),
                                      // 255 = hole (no mesh, no collision; entrances to underground bases);
                                      // or a list of [column, row] hole squares (Tribes 2 emptySquares)
  },
  "world_palette": "Ice_d",            // optional (Darkstar): indexed skins exported as "<X>_<id>" are drawn
                                      // with "<world_palette>_<id>" on this map, as the original did
  "environment": {
    "sky_color": [r, g, b], "horizon_color": [r, g, b], "skybox": ["px.png", ...] /* optional */,
    "fog_color": [r, g, b], "fog_start": 200, "fog_end": 800,
    "sun_dir": [x, y, z], "sun_color": [r, g, b], "ambient": [r, g, b],
    "gravity": 20.0,                  // m/s^2 as the original game had it (null = engine default)
    "darkstar_sky": {                 // optional (Tribes 1 / Starsiege), tools/darkstar_sky.py; drawn by
                                      // engine/darkstar_sky.gd + shaders/darkstar_sky.gdshader
      "panels": "sky_panels.png",     // 16 sky panels side by side (slot k at x = k*w), null = untextured sky
      "first_corner_deg": 67.5,       // angle of ring corner 0 (CCW from east = engine +x, north = engine -z);
      "panel_deg": 22.5,              //   panel k spans corner k -> k+1 at first_corner - k*panel_deg (clockwise)
      "band_bottom": -0.1, "band_top": 0.6,   // panel bottom/top height per ring radius (flat chord panels)
      "top_color": [r, g, b],         // flat cone above the panels (zenith); below: the fog colour
      "bottom_color": [r, g, b],      // original bottom cone colour (informational; the engine hazes to fog)
      "planets": [{"image": "sky_planet_0.png", "dir": [x, y, z], "radius_deg": 2.4}],  // RGBA billboards
      "stars": {"colors": [[r,g,b] x3], "in_front": true} | null   // procedural star field, 3 brightness classes
    },
    "weather": {                      // optional falling snow / rain (Darkstar Snowfall, tools/darkstar_weather.py);
                                      // drawn by engine/map_weather.gd around the current camera
      "kind": "snow",                 // "snow" | "rain"
      "intensity": 1.0,               // 0..1, particle count fraction
      "wind": [x, y, z],              // particle velocity, engine frame, original units (Starsiege snow
                                      //   y -35, rain -85); the renderer scales it to m/s (x0.2)
      "source": "SNOW intensity=1 wind=(0 0 -35) rain=0"
    }
  },
  "point_lights": [                   // optional placed lights (Tribes: Vengeance), engine/map_lights.gd: a pool of
                                      // omni lights follows the ones nearest the camera
    {"pos": [x, y, z], "color": [r, g, b] /* fractions */, "range": 20.0 /* metres */, "type": 1 /* Unreal LightType */}
  ],
  "interiors": [                      // buildings, exported as shapes (ES1 shape JSON schema)
    {"shape": "tribes:int_bbase1", "pos": [x, y, z], "yaw": 0, "pitch": 0, "roll": 0, "scale": 1,
     "collide": true}
  ],
  "statics": [                        // props, rocks, trees, towers (shapes)
    {"shape": "tribes:rock1", "pos": [...], "yaw": 0, "scale": 1, "collide": true}
  ],
  "spawns": [
    // kind: "herc" (Herc start), "infantry" (soldier respawn), "vehicle_pad" (vehicle station /
    // pad — the engine spawns Hercs here on Tribes maps), "flyer"
    {"kind": "herc", "pos": [x, y, z], "yaw": 0, "team": 0}
  ],
  "stations": [                       // gameplay objects with a model
    // kind: "inventory" (armor/weapon station), "ammo", "vehicle" (vehicle station/pad),
    // "repair", "generator", "sensor", "turret", "flag", "objective"
    {"kind": "inventory", "shape": "tribes:invstation", "pos": [...], "yaw": 0, "team": 0}
  ],
  "notes": "anything approximated"
}
```

Also write `gamedata/<pack>/maps/_index.json`: `[{"id", "name", "modes", "terrain": bool,
"spawns": {kind: count}, "size_m": [w, d]}]`.

Rules: keep the original placements; if something can't be decoded (e.g. an interior), list it in
`notes` and leave it out rather than guessing positions. Shapes referenced must exist in
`gamedata/<pack>/shapes/` (palette-index textures or material kind "rgba", see
`docs/formats/tribes2.md` §5 / `game/engine/shape_instance.gd`).
