#[compute]
#version 450

// Fixed-point field back to a float image.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict writeonly image2D out_height;
layout(set = 0, binding = 1, std430) restrict readonly buffer Field {
	int data[];
} field;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float scale;
} p;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}
	float h = float(field.data[id.y * int(p.res.x) + id.x]) / p.scale;
	imageStore(out_height, id, vec4(h, 0.0, 0.0, 1.0));
}
