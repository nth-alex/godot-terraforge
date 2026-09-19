#[compute]
#version 450

// Turns accumulation into a river mask, reads lakes off the filled surface, and
// carves the channels into the terrain so the exported heightmap has real valleys.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly  image2D in_relief;
layout(r32f, set = 0, binding = 1) uniform restrict readonly  image2D in_filled;
layout(r32f, set = 0, binding = 2) uniform restrict readonly  image2D in_acc;
layout(r32f, set = 0, binding = 3) uniform restrict writeonly image2D out_river;
layout(r32f, set = 0, binding = 4) uniform restrict writeonly image2D out_lake;
layout(r32f, set = 0, binding = 5) uniform restrict writeonly image2D out_lake_mask;
layout(push_constant, std430) uniform Params {
	vec2 res;
	float sea_level;
	float river_threshold;
	float river_softness;
	float lake_min_depth;
} p;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	float h = imageLoad(in_relief, id).r;
	float filled = imageLoad(in_filled, id).r;
	float acc = imageLoad(in_acc, id).r;

	if (h <= p.sea_level) {
		imageStore(out_river, id, vec4(0.0));
		imageStore(out_lake, id, vec4(0.0));
		imageStore(out_lake_mask, id, vec4(0.0));
		return;
	}

	// sqrt keeps the mask readable: drainage area grows far faster than channel width.
	float flow = sqrt(max(acc, 0.0));
	float river = smoothstep(p.river_threshold, p.river_threshold + p.river_softness, flow);

	float lake = max(filled - h, 0.0);
	float is_lake = step(p.lake_min_depth, lake);

	imageStore(out_river, id, vec4(river, 0.0, 0.0, 1.0));
	// Store the water surface level, not the depth: carve.glsl reconstructs the
	// shoreline against the full-res terrain, so a coarse depth would staircase.
	imageStore(out_lake, id, vec4(filled * is_lake, 0.0, 0.0, 1.0));
	imageStore(out_lake_mask, id, vec4(is_lake, 0.0, 0.0, 1.0));
}
