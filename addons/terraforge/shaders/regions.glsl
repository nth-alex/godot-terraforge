#[compute]
#version 450

#define MAX_SEEDS 64

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f,  set = 0, binding = 0) uniform restrict readonly  image2D  in_height;
layout(r32ui, set = 0, binding = 1) uniform restrict writeonly uimage2D out_region;
layout(r32f,  set = 0, binding = 2) uniform restrict writeonly image2D  out_border;

layout(set = 0, binding = 3, std430) restrict readonly buffer Seeds {
	// xy = position in uv space, z = power-diagram weight, w = capital flag
	vec4 data[];
} seeds;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float seed;
	float sea_level;
	float seed_count;
	float border_warp;
	float warp_scale;
} p;

float hash(vec2 v) {
	return fract(sin(dot(v, vec2(127.1, 311.7)) + p.seed) * 43758.5453123);
}

float vnoise(vec2 v) {
	vec2 i = floor(v);
	vec2 f = fract(v);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x),
		u.y);
}

float fbm(vec2 v) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	for (int i = 0; i < 4; i++) {
		sum += amp * vnoise(v);
		norm += amp;
		v *= 2.03;
		amp *= 0.5;
	}
	return sum / norm;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	vec2 uv = (vec2(id) + 0.5) / p.res;

	// Warped lookup position: keeps borders organic instead of straight-edged.
	vec2 w = vec2(
		fbm(uv * p.warp_scale + vec2(3.7, 8.2)),
		fbm(uv * p.warp_scale + vec2(15.9, 2.4))
	) - 0.5;
	vec2 quv = uv + w * p.border_warp;

	int count = int(p.seed_count);
	float best = 1e20;
	float second = 1e20;
	uint best_id = 0u;
	uint second_id = 0u;

	for (int i = 0; i < count && i < MAX_SEEDS; i++) {
		vec4 s = seeds.data[i];
		vec2 d = quv - s.xy;
		// Power diagram: weight shifts the border without moving the seed.
		float pd = dot(d, d) - s.z;
		if (pd < best) {
			second = best;
			second_id = best_id;
			best = pd;
			best_id = uint(i);
		} else if (pd < second) {
			second = pd;
			second_id = uint(i);
		}
	}

	// Distance to the nearest region border, in uv units.
	float border = (second - best) / max(2.0 * sqrt(max(best, 1e-6)), 1e-4);

	bool land = imageLoad(in_height, id).r > p.sea_level;
	// Nearest region in the low half, second-nearest in the high half: the ridge
	// pass needs both sides of a border to blend their settings.
	// Ocean gets a sentinel id so downstream passes can skip it.
	uint packed = best_id | (second_id << 16);
	imageStore(out_region, id, uvec4(land ? packed : 0xFFFFFFFFu, 0u, 0u, 0u));
	imageStore(out_border, id, vec4(border, 0.0, 0.0, 1.0));
}
