#[compute]
#version 450

// Box-average the relief down to the water simulation resolution.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly  image2D in_full;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D out_small;

layout(push_constant, std430) uniform Params {
	vec2 small_res;
	float factor;
} p;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.small_res.x) || id.y >= int(p.small_res.y)) {
		return;
	}
	int f = int(p.factor);
	float sum = 0.0;
	for (int y = 0; y < f; y++) {
		for (int x = 0; x < f; x++) {
			sum += imageLoad(in_full, id * f + ivec2(x, y)).r;
		}
	}
	imageStore(out_small, id, vec4(sum / float(f * f), 0.0, 0.0, 1.0));
}
