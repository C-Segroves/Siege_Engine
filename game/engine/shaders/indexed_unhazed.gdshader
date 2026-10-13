// Palette-indexed texture with the 3Space lighting (indexed_body.gdshaderinc) and no distance haze: Earthsiege 1
// textured polys are not ramp-indexed, so the per-object haze windows never reach them (DBSIM 0x5410c,
// docs/formats/world.md section 4 "Textures get no distance haze").
shader_type spatial;
render_mode unshaded, fog_disabled;

#include "res://engine/shaders/indexed_body.gdshaderinc"
