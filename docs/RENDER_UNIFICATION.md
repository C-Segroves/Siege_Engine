# Render unification: one imported format, one material, one scene setup

Goal (USER_TODO.md, Engineering): importers differ per game, but once imported everything renders through the same
code and looks as the original intended. Colour differences between games are fixed at import, not at draw time.

## 1. Audit: today's render paths

| Area | Code | Look |
|---|---|---|
| 3Space textured poly (es1, es2, bd) | `Palette.material` -> `indexed.gdshader` (ES2, hazed) / `indexed_unhazed.gdshader` (ES1), `indexed_body.gdshaderinc` | unshaded; index texture + `texlight` remap (8 rows ES1, 32 rows ES2) + palette lookup, I = (1 - n.L)/2 from global `sun_dir`, palette point lights |
| 3Space shaded poly | `shaded.gdshader` | unshaded; 32-step shade list per material through the palette |
| 3Space solid poly | `Palette.material` -> unshaded StandardMaterial3D, palette colour | flat |
| Darkstar/Torque shapes (starsiege, tribes, tribes2) | `ShapeInstance._rgba_material` / `_override_material` (skins) -> PBR StandardMaterial3D (roughness 0.9, flags: additive, translucent = alpha scissor, self-illuminating = unshaded, `damage` = hidden decal) | lit by Godot lights; Darkstar indexed skins (`kind tex`) still go through palette shaders with the world palette (`ShapeInstance.world_palettes`) |
| Terrain | `ground.gdshader` (ES1), `es2_terrain.gdshader` (ES2), `MapTerrain._material` (Darkstar/engine maps, PBR) | |
| Sky | `SceneLighting.build_palette_environment` (ES band panorama), `darkstar_sky.gd`+shader, `skybox.gdshader`, solid colour | |
| Environment / tone map | ES1/ES2 worlds + BD arena: LINEAR, flat ambient, depth fog in haze colour (`SceneLighting`, `arena_builder.gd:69`); Darkstar/engine maps: FILMIC (`map_environment.gd:43`), `DirectionalLight3D` with shadows + `sun_dir`; hangar: FILMIC 1.05 (`hangar_bay.gd:645`); test scenes: studio env (default tone map) | **two tone maps in the game** |
| Fog / haze | ES: Godot depth fog, textures un-fogged for ES1 (`fog_disabled`); Darkstar: Godot depth fog | |
| Special | cockpit art (320x200 indexed 2D, `tools/cockpit*.py`, cockpit scenes); HUD target pictures (`engine/target_view/*`: flat, ramp `target_ramp.gdshader`, lit paints, on a 2D damage diagram); damage looks (cells swapped per state, Darkstar `damage` decal materials); FX (`engine/fx/fx_materials.gd`, sprites/beams/rings/particles, unshaded additive); `DynamicLights` + `PaletteLights` | |

Known mixed-scene faults: ES Hercs washed out on Darkstar maps (FILMIC applied on top of palette colours, which were
authored for LINEAR); Tribes vehicles dark on ES worlds (no directional light, flat ambient only).

## 2. Canonical imported format

Per shape: `shape.json` (geometry, nodes, sequences, LODs, cells; unchanged) plus a **material table** where every
polygon refers to a material id, and every material is the same record regardless of source game:

```
material: {
  albedo:   "tex/<name>.png"          true-colour sRGB PNG (RGBA when alpha is needed), or albedo_color [r,g,b]
  ramp:     8 | 32 | 0                number of baked light levels (0 = not 3Space-lit, use lambert)
  ramp_png: "tex/<name>_ramp.png"      only when ramp > 0 (see below)
  emission: optional PNG, roughness: optional (unused by the shared shader today)
  flags:    unshaded | alpha_test | alpha_blend | additive | two_sided | decal_hidden
}
```

Palette baking at import (the importers already know palette + remap tables):

- **Textured 3Space poly**: bake the lit texture stack `albedo[level] = palette[texlight[level][index]]`, level 0..R-1
  (R = 8 for ES1, 32 for ES2/BD). Stored as a vertical strip PNG (width x height*R). Runtime loads it as a
  `Texture2DArray`. This reproduces the indexed lighting exactly, because the original selects the level per polygon
  from I and then looks the texel up; no per-pixel palette work is left at runtime. Index 0 transparency becomes alpha.
- **Shaded 3Space poly**: 1 x R strip, `palette[shade_list[level]]`. **Solid**: 1x1, R = 1.
- **Darkstar/Torque**: albedo PNG as-is (already true colour, or palette-resolved at import for PiDX skins using the
  pack's world palette), R = 0 (lambert mode), flags from the Torque flags.
- Colour space: all stored in sRGB; the palette's own gamma (VGA 6-bit DAC values) is expanded to 8-bit at import.

Haze: stored per world/map as standard fog parameters in the map JSON (`fog_color`, begin/end; ES2 RMP haze rows map to
fog colour + range, ES1 `no_haze_textures: true`); no shader-side palette haze tables.

Not imported as materials (stay special): the 320x200 cockpit art and HUD target diagrams (pixel-exact 2D, drawn by the
2D UI), terrain ground LUT (distance-banded 16-entry tables; migrates in a later phase to a baked mip chain or keeps
`ground.gdshader`), sky shaders (they output final colours, scene-agnostic), FX sprites (already true colour unshaded).

## 3. Canonical runtime: one shader, one scene setup

`engine/shaders/unified.gdshader` (spatial, `unshaded`, reads only **global** uniforms so a model needs no scene knowledge):

- inputs: `albedo_array` (Texture2DArray, layers = R or 1), `ramp_levels`, flags as uniforms/defines (alpha_test,
  additive, two_sided via render modes in variants).
- lighting (`lit_mode`): **ramp** (R > 0): level = int(I*(R-1)), I = (1 - n.L)/2 + palette point lights (global
  `sun_dir`, `palette_lights`), exactly the old behaviour; **lambert** (R == 0): `albedo * (ambient + sun_color * max(-n.L, 0))`
  from new globals `scene_ambient`, `scene_sun_color`; **unshaded**: albedo.
- tone-map neutrality: global `scene_tonemap` (0 linear, 1 filmic). When filmic the shader writes the exact inverse
  of Godot's filmic curve so the displayed colour equals the authored colour. This is a bridge: once all scenes are
  LINEAR the branch is dead and removed.
- all scene builders call one `SceneLighting.publish(spec)` that sets `sun_dir`, `scene_sun_color`, `scene_ambient`,
  `scene_tonemap`. ES/BD/Darkstar/hangar/test scenes then differ only in values, not in code.

Scene setup target: one `SceneLighting.build_environment(spec)`; tone map LINEAR everywhere (Darkstar maps' filmic
look re-created by baking terrain/interior albedo and picking sun/ambient values at import), Godot fog from per-pack
params, `DirectionalLight3D` kept only for terrain/PBR leftovers and shadow casting.

## 4. Special cases that stay special and why

- Cockpit art and target diagrams: authored 2D at 320x200 with palette cycling and per-level colour ramps; scaling
  them through 3D shading would break pixel fidelity. They only share the palette-to-sRGB import step.
- Terrain ES1/ES2: per-pixel distance-banded LUT; keep shaders, but they publish through the same globals.
- Sky: output final authored colours; unaffected by tone mapping via `sky` handling.
- Damage looks / cells: geometry swaps, unchanged; decal materials become a flag (`decal_hidden`) plus per-instance alpha.
- FX: additive/unshaded sprites already uniform; migrate to flags later.

## 5. Phased migration

1. (this task) Prototype `unified.gdshader` + runtime bake of ES1 Herc and T2 vehicle materials, behind `render_unified`.
2. Move the bake into importers (`tools/*.py`): write `*_ramp.png` strips and the material table to scratch packs; the
   runtime bake becomes a loader.
3. All Hercs/vehicles/buildings of all 3Space + Darkstar packs on the unified material; delete `_rgba_material` PBR.
4. Terrain + interiors; unify Environment (LINEAR everywhere), remove the filmic bridge.
5. New packs (Aerial Assault, Vengeance) emit the canonical table from their importers; FX flags.
6. Default `render_unified` on, delete old shaders/paths.

## 6. Risks

- Lambert + ambient is a different look from the PBR the Darkstar maps shipped with; may need per-pack tuning of
  `scene_sun_color` / ambient to match.
- Unified Darkstar models stop receiving real Godot shadows (and map point lights); loss of shadow contact on ground.
- Texture2DArray strips for ES2 (32 levels) multiply texture memory by 32 for each texture; mitigate by baking only
  used levels or by sampling the index + 1D LUT when memory matters (Web export limit).
- Inverse filmic is exact only for unshaded colours before fog; fog is applied before tone map, so fogged pixels shift
  slightly (acceptable, and gone once everything is LINEAR).
- Per-polygon level selection in the 3Space originals is per polygon, ours per fragment from the interpolated normal;
  flat polygons here, so identical, but smooth-normal Darkstar meshes should stay lambert.
- Web/GLES3 compatibility renderer: Texture2DArray and global uniforms need verification.
- Skin texture overrides (`SkinCatalog`) and world-palette swaps for Darkstar indexed skins must be re-baked per world.

## 7. Prototype results (phase 2)

Flag `render_unified` (settings.json key, or env SIEGE_RENDER_UNIFIED=1; `RenderUnified.force` for tests), default off.
Code: `engine/render/render_unified.gd`, `engine/render/unified_material.gd` (runtime bake, stands in for the importer),
`engine/shaders/unified_{nearest,linear}.gdshader` + `unified_body.gdshaderinc`, globals `scene_sun_color`,
`scene_ambient`, `scene_tonemap` (project.godot), published by `SceneLighting.apply_scene_light` from
`build_palette_environment` and `MapEnvironment._add_sun`; hook in `ShapeInstance._material_for`.
Renders: `tests/render_unified_shots.tscn` (windowed; env RU_SHOT_DIR, RU_SAME_SUN=1 to hold the sun direction constant).

- ES1 Herc on ES1 world: old and unified pixel-identical (leg sample 75.8/88.3/72.6 both).
- ES1 Herc on T2 map, same sun direction: old 96/112/92 (washed out by filmic), unified 75.8/88.5/72.6 = the ES1-world colour.
- T2 vehicle on T2 map: close to the old look but about 15% brighter (lambert vs PBR, no map shadow on the model).
- T2 vehicle on ES1 world: old and unified similar; the unified look is now the same model colour in both worlds
  apart from the scene's own ambient/sun values (the old path was dark without a directional light).
- Left on the old path for now: additive and damage-decal materials, skin overrides, terrain, FX.

## 8. Migration progress (phases 1-7 of the approved plan)

Status: every pack's shapes (3Space es1/es2/bd, Darkstar/Torque starsiege/tribes/tribes2, Aerial Assault `tribes_aa`,
Vengeance `tribes_v`) draw through the unified material, and `render_unified` is now **ON by default**. Switch back with
settings.json `"render_unified": false` or env `SIEGE_RENDER_UNIFIED=0` (`=1` forces on). Renders: `tests/render_unified_shots.tscn`
(env RU_SHOT_DIR, RU_ONLY=substring, RU_DIST=camera distance factor, RU_SAME_SUN=1), 12+ combos over all packs; results in
`renders/ru2` (all packs), `ru3*` (hazed distances), `ru4` (skins, additive, decals), `ru5` (AA / Vengeance), `ru6` (final, flag default).

1. **Lighting.** The prototype's global lambert was replaced by `unified_lit*.gdshader`: the Torque/Darkstar look is now
   the same PBR (roughness 0.9) lit by the scene's own lights, so map shadows fall on unified models again and the
   ~15% brightness excess is gone (lit models are within 0-8% of the old look, visually equal). Only ramp (3Space) mode keeps the
   palette math plus the inverse-filmic bridge. Palette worlds (ES1/ES2/BD) add one `DirectionalLight3D` whose cull mask is the
   unified-lit render layer (bit 20, set on every ShapeInstance mesh), so Torque models standing in them are lit by the
   world sun and nothing else changes (`SceneLighting.add_palette_world_sun`). The hangar and studio environments now publish their
   tone map too. Shape instances in ramp mode do not receive shadows (they never did in the originals).
2. **ES2 / BD.** 32-level ramps render pixel-identical to the old shaders, near and at hazed distances (haze is Godot fog;
   ES1 textures keep `fog_disabled` through `unified_nearest_unhazed`). Texture memory with every shape of a pack loaded at once:
   es1 11 MB, es2 94 MB, bd 16 MB (`tests/render_unified_memory_check.tscn`, budgets 64/256/128 MB). A mission loads a fraction of
   that, so no compact layout was needed. If the web build needs it: dedupe identical levels or fall back to index + 1D LUT.
3. **Skins, decals, additive.** `UnifiedMaterial.from_texture` (SkinCatalog overrides, honouring the base material's flags),
   `unified_lit_add` (additive), `unified_lit_blend` (damage decals hidden by `alpha_mul` 0), alpha test via `alpha_cut`.
   Palette swaps: the world palette id is part of the cache key, so per-world re-bakes are automatic.
4. **New packs.** Aerial Assault and Vengeance shapes/interiors are canonical rgba shapes and already go through
   `from_rgba`; rendered in `ru5`.
5. **Importer-side bake.** `tools/unified_bake.py <pack ...> [--palettes ..] [--out scratch]` writes
   `<pack>/unified/<palette>__<texset>__<index>.png` (vertical RGBA strip, R levels). `UnifiedMaterial` loads a strip when present and
   its size fits, else bakes at load time. Verified byte-for-byte on scratch bakes of es1, es2 and bd
   (`tests/render_unified_bake_check.tscn`, env RU_BAKE_DIR). Gamedata was NOT touched. **Re-import step for the user (optional,
   speeds loading):** `python tools/unified_bake.py es1 es2 bd` (writes into gamedata/<pack>/unified, ~9 MB per world palette
   for es2, so bake only the palettes you use with `--palettes`), then run the bake check against the same folder via `--out`
   first if in doubt. Hooking it into the export_*.py importers is the remaining mechanical step.
6. **Terrain and FX.** Per section 4 these stay: ES1/ES2 terrain shaders (they already publish through the same globals),
   Darkstar `MapTerrain` (lit PBR, now consistent with the lit unified models), sky shaders, FX sprites (already unshaded true colour),
   320x200 cockpit art and HUD target diagrams. Nothing further joins the unified path.
7. **Default switch.** Pure-scene renders: ES1/ES2/BD pixel-identical, Torque/Darkstar within a few percent; mixed scenes:
   ES Hercs on Darkstar maps match their ES-world colour (the old filmic wash-out is gone, which is the intended change: about 20%
   darker than before there), Torque models in ES worlds are sun-lit. All gate tests pass with the flag on.
   Web/GLES3 (Compatibility): not smoke-tested (a web export needs the full pack set). Texture2DArray, global uniforms (including the
   `palette_lights` sampler read with texelFetch), `fog_disabled` and light cull masks are all supported by the Compatibility
   renderer in 4.6, so only a runtime check on a real browser remains; if it fails, set `render_unified` false for the web preset.
