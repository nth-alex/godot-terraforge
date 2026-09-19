#[compute]
#version 450

// Upsamples the road mask computed on the CPU and notches it into the terrain,
// so a road reads as a cut through a ridge rather than a stripe painted over it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly  image2D in_height;
layout(r32f, set = 0, binding = 1) uniform restrict readonly  image2D in_road_small;
layout(r32f, set = 0, binding = 2) uniform restrict writeonly image2D out_road;
layout(r32f, set = 0, binding = 3) uniform restrict writeonly image2D out_graded;

layout(push_constant, std430) uniform Params {
	vec2 res;
	vec2 small_res;
	float sea_level;
	float notch_depth;
} p;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	vec2 uv = (vec2(id) + 0.5) / p.res;
	vec2 sp = uv * p.small_res - 0.5;
	ivec2 i = ivec2(floor(sp));
	vec2 f = fract(sp);
	ivec2 lo = ivec2(0);
	ivec2 hi = ivec2(p.small_res) - 1;
	float a = imageLoad(in_road_small, clamp(i + ivec2(0, 0), lo, hi)).r;
	float b = imageLoad(in_road_small, clamp(i + ivec2(1, 0), lo, hi)).r;
	float c = imageLoad(in_road_small, clamp(i + ivec2(0, 1), lo, hi)).r;
	float d = imageLoad(in_road_small, clamp(i + ivec2(1, 1), lo, hi)).r;
	float road = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);

	float h = imageLoad(in_height, id).r;
	if (h <= p.sea_level) {
		road = 0.0;
	}

	float graded = max(h - road * p.notch_depth, p.sea_level + 0.5);
	imageStore(out_road, id, vec4(road, 0.0, 0.0, 1.0));
	imageStore(out_graded, id, vec4((h <= p.sea_level) ? h : graded, 0.0, 0.0, 1.0));
}
