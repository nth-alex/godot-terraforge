#[compute]
#version 450

// Copies the relief into a fixed-point integer buffer. Droplets need atomic
// read-modify-write on the heightfield, which images cannot do.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly image2D in_height;
layout(set = 0, binding = 1, std430) restrict buffer Field {
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
	field.data[id.y * int(p.res.x) + id.x] = int(imageLoad(in_height, id).r * p.scale);
}
