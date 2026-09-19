shader_type spatial;
render_mode cull_disabled;

// Heights arrive in metres on the same grid as the bake, so the plane is left at
// world size and only Y is displaced. Normals come from a central difference of
// the same texture: cheaper and sharper than any normal map we could bake.

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D color_tex : source_color, filter_linear, repeat_disable;
uniform float texel = 0.00048828125;
uniform float world_m = 32768.0;

varying vec2 map_uv;

float height_at(vec2 uv) {
	return textureLod(height_tex, uv, 0.0).r;
}

void vertex() {
	map_uv = UV;
	VERTEX.y = height_at(UV);

	float step_m = texel * world_m;
	float hx = height_at(UV + vec2(texel, 0.0)) - height_at(UV - vec2(texel, 0.0));
	float hz = height_at(UV + vec2(0.0, texel)) - height_at(UV - vec2(0.0, texel));
	NORMAL = normalize(vec3(-hx, 2.0 * step_m, -hz));
}

void fragment() {
	ALBEDO = texture(color_tex, map_uv).rgb;
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
}
