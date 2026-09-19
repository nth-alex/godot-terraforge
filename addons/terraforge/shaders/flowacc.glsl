#[compute]
#version 450

// One flow-accumulation step. Each cell gathers the accumulation of neighbours
// that drain into it, so after N steps water has travelled N cells downstream.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly  image2D in_filled;
layout(r32f, set = 0, binding = 1) uniform restrict readonly  image2D in_prev;
layout(r32f, set = 0, binding = 2) uniform restrict writeonly image2D out_next;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float sea_level;
	float init;
} p;

/// Steepest-descent neighbour offset on the filled surface, (0,0) if this cell
/// is a sink. Slope is per unit distance so diagonals are not over-favoured.
ivec2 downstream(ivec2 c, ivec2 res) {
	float here = imageLoad(in_filled, c).r;
	float best = 0.0;
	ivec2 dir = ivec2(0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			if (x == 0 && y == 0) {
				continue;
			}
			ivec2 q = c + ivec2(x, y);
			if (q.x < 0 || q.y < 0 || q.x >= res.x || q.y >= res.y) {
				continue;
			}
			float drop = (here - imageLoad(in_filled, q).r) / length(vec2(x, y));
			if (drop > best) {
				best = drop;
				dir = ivec2(x, y);
			}
		}
	}
	return dir;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 res = ivec2(p.res);
	if (id.x >= res.x || id.y >= res.y) {
		return;
	}

	float h = imageLoad(in_filled, id).r;
	if (h <= p.sea_level) {
		imageStore(out_next, id, vec4(0.0, 0.0, 0.0, 1.0));
		return;
	}
	if (p.init > 0.5) {
		// Every land cell contributes its own rainfall.
		imageStore(out_next, id, vec4(1.0, 0.0, 0.0, 1.0));
		return;
	}

	float sum = 1.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			if (x == 0 && y == 0) {
				continue;
			}
			ivec2 q = id + ivec2(x, y);
			if (q.x < 0 || q.y < 0 || q.x >= res.x || q.y >= res.y) {
				continue;
			}
			if (q + downstream(q, res) == id) {
				sum += imageLoad(in_prev, q).r;
			}
		}
	}

	imageStore(out_next, id, vec4(sum, 0.0, 0.0, 1.0));
}
