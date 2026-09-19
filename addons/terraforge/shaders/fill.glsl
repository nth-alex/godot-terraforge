#[compute]
#version 450

// One Planchon-Darboux relaxation step: the filled surface starts at +inf and
// is pulled down until every land cell has a downhill path to the sea. Lakes are
// whatever ends up standing above the original terrain.
// ponytail: O(longest basin) iterations, swap for priority-flood if 2048 gets slow.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly  image2D in_height;
layout(r32f, set = 0, binding = 1) uniform restrict readonly  image2D in_prev;
layout(r32f, set = 0, binding = 2) uniform restrict writeonly image2D out_next;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float sea_level;
	float epsilon;
	float init;
} p;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 res = ivec2(p.res);
	if (id.x >= res.x || id.y >= res.y) {
		return;
	}

	float h = imageLoad(in_height, id).r;
	bool edge = id.x == 0 || id.y == 0 || id.x == res.x - 1 || id.y == res.y - 1;
	bool outlet = edge || h <= p.sea_level;

	// Outlets are fixed at terrain height; they are where water leaves the map.
	if (outlet) {
		imageStore(out_next, id, vec4(h, 0.0, 0.0, 1.0));
		return;
	}
	if (p.init > 0.5) {
		imageStore(out_next, id, vec4(1.0e6, 0.0, 0.0, 1.0));
		return;
	}

	float best = 1.0e9;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			if (x == 0 && y == 0) {
				continue;
			}
			ivec2 q = clamp(id + ivec2(x, y), ivec2(0), res - 1);
			best = min(best, imageLoad(in_prev, q).r);
		}
	}

	imageStore(out_next, id, vec4(max(h, best + p.epsilon), 0.0, 0.0, 1.0));
}
