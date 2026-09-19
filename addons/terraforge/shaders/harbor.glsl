#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly image2D in_height;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D out_score;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float sea_level;
	float radius;
	float min_water_frac;
} p;

bool is_land(ivec2 c) {
	ivec2 q = clamp(c, ivec2(0), ivec2(p.res) - 1);
	return imageLoad(in_height, q).r > p.sea_level;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	if (!is_land(id)) {
		imageStore(out_score, id, vec4(0.0));
		return;
	}

	// Coastal test: land touching water within a couple of cells.
	bool coastal = false;
	for (int y = -2; y <= 2 && !coastal; y++) {
		for (int x = -2; x <= 2; x++) {
			if (!is_land(id + ivec2(x, y))) {
				coastal = true;
				break;
			}
		}
	}
	if (!coastal) {
		imageStore(out_score, id, vec4(0.0));
		return;
	}

	// Shelter = how much land surrounds this coastal cell. A bay scores high,
	// a cape scores low, because a cape is mostly ringed by water.
	int r = int(p.radius);
	float land = 0.0;
	float total = 0.0;
	for (int y = -r; y <= r; y++) {
		for (int x = -r; x <= r; x++) {
			if (x * x + y * y > r * r) {
				continue;
			}
			total += 1.0;
			if (is_land(id + ivec2(x, y))) {
				land += 1.0;
			}
		}
	}
	float land_frac = land / max(total, 1.0);
	float water_frac = 1.0 - land_frac;

	// Reject puddles: a harbor needs open water nearby, not just a wet dent.
	float score = (water_frac >= p.min_water_frac) ? land_frac : 0.0;
	imageStore(out_score, id, vec4(score, 0.0, 0.0, 1.0));
}
