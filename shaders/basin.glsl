#[compute]
#version 450

// Flattens buildable ground around the harbour and lifts a shallow shelf in front
// of it. A capital needs somewhere to actually put a city, and a harbour needs
// water it could plausibly dock in rather than a cliff into deep sea.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly  image2D in_height;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D out_height;

layout(push_constant, std430) uniform Params {
	vec2 res;
	vec2 harbor;
	float sea_level;
	float basin_radius;
	float basin_elevation;
	float basin_flatness;
	float shelf_radius;
	float shelf_depth;
} p;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	float h = imageLoad(in_height, id).r;
	vec2 uv = (vec2(id) + 0.5) / p.res;
	float d = distance(uv, p.harbor);

	if (h > p.sea_level) {
		// Full flattening at the centre, easing out so the basin meets the hills
		// without a step.
		float t = 1.0 - smoothstep(p.basin_radius * 0.35, p.basin_radius, d);
		h = mix(h, p.sea_level + p.basin_elevation, t * p.basin_flatness);
	} else {
		// Shelf only ever lifts the sea floor; never dig the seabed deeper.
		float t = 1.0 - smoothstep(p.shelf_radius * 0.35, p.shelf_radius, d);
		float shelf = p.sea_level - p.shelf_depth;
		h = max(h, mix(h, shelf, t));
	}

	imageStore(out_height, id, vec4(h, 0.0, 0.0, 1.0));
}
