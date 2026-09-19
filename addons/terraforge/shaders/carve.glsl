#[compute]
#version 450

// Upsamples the low-resolution water masks back to full resolution and carves
// the river channels into the terrain, so the exported heightmap has valleys
// rather than painted-on blue lines.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly  image2D in_relief;
layout(r32f, set = 0, binding = 1) uniform restrict readonly  image2D in_river_small;
layout(r32f, set = 0, binding = 2) uniform restrict readonly  image2D in_lake_small;
layout(r32f, set = 0, binding = 3) uniform restrict writeonly image2D out_river;
layout(r32f, set = 0, binding = 4) uniform restrict writeonly image2D out_lake;
layout(r32f, set = 0, binding = 5) uniform restrict writeonly image2D out_carved;
layout(r32f, set = 0, binding = 6) uniform restrict readonly  image2D in_lake_mask;

layout(push_constant, std430) uniform Params {
	vec2 res;
	vec2 small_res;
	float sea_level;
	float carve_depth;
} p;

// Images cannot be passed as function parameters here, so this is a macro.
#define BILINEAR(img, uv, out_val) { \
	vec2 sp = (uv) * p.small_res - 0.5; \
	ivec2 i = ivec2(floor(sp)); \
	vec2 f = fract(sp); \
	ivec2 lo = ivec2(0); \
	ivec2 hi = ivec2(p.small_res) - 1; \
	float a = imageLoad(img, clamp(i + ivec2(0, 0), lo, hi)).r; \
	float b = imageLoad(img, clamp(i + ivec2(1, 0), lo, hi)).r; \
	float c = imageLoad(img, clamp(i + ivec2(0, 1), lo, hi)).r; \
	float d = imageLoad(img, clamp(i + ivec2(1, 1), lo, hi)).r; \
	out_val = mix(mix(a, b, f.x), mix(c, d, f.x), f.y); \
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	float h = imageLoad(in_relief, id).r;
	vec2 uv = (vec2(id) + 0.5) / p.res;

	float river = 0.0;
	BILINEAR(in_river_small, uv, river)

	// Lake shores: upsample the water surface level and the coverage mask, then
	// test it against the full-res height. Interpolating the coarse depth mask
	// instead would snap every shore to the low-res grid and read as staircases.
	float level_sum = 0.0;
	float mask = 0.0;
	BILINEAR(in_lake_small, uv, level_sum)
	BILINEAR(in_lake_mask, uv, mask)
	float level = level_sum / max(mask, 1e-4);
	float lake = (mask > 0.02) ? max(level - h, 0.0) : 0.0;
	if (h <= p.sea_level) {
		river = 0.0;
		lake = 0.0;
	}

	// A lake bed is already a hollow, so only free-flowing channels get cut.
	float carved = h - river * p.carve_depth * step(lake, 0.001);
	// Never cut a land cell below the waterline: that turns a river mouth into a
	// fake sea inlet and eats the coastline the regions were built on.
	if (h > p.sea_level) {
		carved = max(carved, p.sea_level + 0.5);
	}

	imageStore(out_river, id, vec4(river, 0.0, 0.0, 1.0));
	imageStore(out_lake, id, vec4(lake, 0.0, 0.0, 1.0));
	imageStore(out_carved, id, vec4(carved, 0.0, 0.0, 1.0));
}
