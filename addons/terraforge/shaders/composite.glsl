#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f,   set = 0, binding = 0) uniform restrict readonly  image2D  in_height;
layout(r32ui,  set = 0, binding = 1) uniform restrict readonly  uimage2D in_region;
layout(r32f,   set = 0, binding = 2) uniform restrict readonly  image2D  in_border;
layout(rgba8,  set = 0, binding = 3) uniform restrict writeonly image2D  out_color;

layout(r32f,   set = 0, binding = 5) uniform restrict readonly  image2D  in_river;
layout(r32f,   set = 0, binding = 6) uniform restrict readonly  image2D  in_lake;
layout(r32f,   set = 0, binding = 7) uniform restrict readonly  image2D  in_road;

layout(set = 0, binding = 4, std430) restrict readonly buffer Seeds {
	vec4 data[];
} seeds;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float sea_level;
	float height_scale;
	float view_mode;   // 0 height, 1 hillshade, 2 regions, 3 water, 4 roads, 5 composite
	float meters_per_pixel;
	float border_px;
} p;

vec3 hsv2rgb(vec3 c) {
	vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);
	vec3 t = abs(fract(c.xxx + k) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(t - 1.0, 0.0, 1.0), c.y);
}

float height_at(ivec2 c) {
	return imageLoad(in_height, clamp(c, ivec2(0), ivec2(p.res) - 1)).r;
}

float hillshade(ivec2 id) {
	float hl = height_at(id - ivec2(1, 0));
	float hr = height_at(id + ivec2(1, 0));
	float hd = height_at(id - ivec2(0, 1));
	float hu = height_at(id + ivec2(0, 1));
	vec3 n = normalize(vec3(hl - hr, hd - hu, 2.0 * p.meters_per_pixel));
	vec3 sun = normalize(vec3(-0.6, -0.6, 0.55));
	return clamp(dot(n, sun) * 0.5 + 0.55, 0.0, 1.2);
}

vec3 region_color(uint rid) {
	float golden = 0.61803398875;
	float hue = fract(float(rid) * golden + 0.12);
	return hsv2rgb(vec3(hue, 0.42, 0.92));
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	float h = height_at(id);
	bool land = h > p.sea_level;
	uint packed = imageLoad(in_region, id).r;
	uint rid = (packed == 0xFFFFFFFFu) ? 0xFFFFFFFFu : (packed & 0xFFFFu);
	float border = imageLoad(in_border, id).r;
	int mode = int(p.view_mode);

	vec3 col;

	if (mode == 0) {
		float g = clamp(h / max(p.height_scale, 1.0), 0.0, 1.0);
		col = vec3(g);
	} else if (mode == 1) {
		col = vec3(hillshade(id)) * (land ? 1.0 : 0.35);
	} else if (mode == 2) {
		col = land ? region_color(rid) : vec3(0.06, 0.12, 0.24);
	} else if (mode == 3 || mode == 4) {
		col = land ? vec3(0.82, 0.80, 0.74) : vec3(0.06, 0.12, 0.24);
	} else {
		if (!land) {
			// Shelf shading: shallower water reads lighter.
			float depth = clamp((p.sea_level - h) / max(p.sea_level, 1.0), 0.0, 1.0);
			col = mix(vec3(0.20, 0.42, 0.62), vec3(0.03, 0.09, 0.22), depth);
		} else {
			col = region_color(rid) * hillshade(id);
		}
	}

	if (land && (mode == 2 || mode == 3 || mode == 5)) {
		float river = imageLoad(in_river, id).r;
		float lake = imageLoad(in_lake, id).r;
		// Lakes sit on top of rivers: a river running into one should disappear.
		col = mix(col, vec3(0.16, 0.42, 0.68), clamp(river, 0.0, 1.0) * 0.9);
		col = mix(col, vec3(0.13, 0.33, 0.58), step(0.001, lake));
	}

	if (land && (mode == 2 || mode == 4 || mode == 5)) {
		float road = imageLoad(in_road, id).r;
		col = mix(col, vec3(0.42, 0.29, 0.16), smoothstep(0.22, 0.50, road));
	}

	if (land && (mode == 2 || mode == 5)) {
		// Capital gets a gold wash so it is findable at a glance.
		if (rid != 0xFFFFFFFFu && seeds.data[int(rid)].w > 0.5) {
			col = mix(col, vec3(1.0, 0.85, 0.35), 0.28);
		}
		float bw = p.border_px / p.res.x;
		float line = 1.0 - smoothstep(bw * 0.5, bw, border);
		col = mix(col, vec3(0.08, 0.06, 0.05), line * 0.85);
	}

	imageStore(out_color, id, vec4(col, 1.0));
}
