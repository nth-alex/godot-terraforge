#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict writeonly image2D out_height;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float seed;
	float sea_level;
	float height_scale;
	float coast_warp;
	float falloff_pow;
	float continent_scale;
	float land_bias;
	float terrain_scale;
	float terrain_detail;
} p;

float hash(vec2 v) {
	return fract(sin(dot(v, vec2(127.1, 311.7)) + p.seed) * 43758.5453123);
}

float vnoise(vec2 v) {
	vec2 i = floor(v);
	vec2 f = fract(v);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 v, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	for (int i = 0; i < octaves; i++) {
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

	// Two warp octaves: the coarse one bends the whole landmass into bays and
	// headlands, the fine one frays the shoreline so it is not a smooth curve.
	vec2 w1 = vec2(
		fbm(uv * 3.0 + vec2(11.3, 4.7), 4),
		fbm(uv * 3.0 + vec2(27.1, 19.4), 4)
	) - 0.5;
	vec2 w2 = vec2(
		fbm(uv * 9.0 + vec2(5.2, 31.8), 3),
		fbm(uv * 9.0 + vec2(41.6, 7.9), 3)
	) - 0.5;
	vec2 quv = uv + w1 * p.coast_warp + w2 * p.coast_warp * 0.35;

	float d = clamp(length(quv - vec2(0.5)) * 2.0, 0.0, 1.0);
	// Hard rim keeps open ocean at the texture border, so the continent never
	// gets clipped by the edge and the harbour search cannot pick a cut edge.
	float rim = smoothstep(0.80, 1.0, d) * 2.0;

	float n = fbm(quv * p.continent_scale, 6);
	float shape = n * 1.2 - pow(d, p.falloff_pow) - rim - p.land_bias;

	// shape > 0 is land above sea level, shape < 0 is sea floor below it.
	float h = (shape > 0.0)
		? p.sea_level + shape * (p.height_scale - p.sea_level)
		: p.sea_level * (1.0 + max(shape, -1.0));

	// Rolling interior detail. Without it the regions read as flat plates and the
	// border ridges look like embossed seams rather than mountain ranges.
	if (shape > 0.0) {
		float inland = clamp(shape * 4.0, 0.0, 1.0);
		h += (fbm(quv * p.terrain_scale, 5) - 0.5) * p.terrain_detail * inland;
	}

	imageStore(out_height, id, vec4(h, 0.0, 0.0, 1.0));
}
