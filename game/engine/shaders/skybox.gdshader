// Six-face skybox from a map's sky images (cubemap).
shader_type sky;

uniform samplerCube sky_cube : source_color, filter_linear;

void sky() {
	COLOR = texture(sky_cube, EYEDIR).rgb;
}
