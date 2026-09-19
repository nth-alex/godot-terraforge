#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f,  set = 0, binding = 0) uniform restrict readonly  image2D  in_height;
layout(r32ui, set = 0, binding = 1) uniform restrict readonly  uimage2D in_region;
layout(r32f,  set = 0, binding = 2) uniform restrict readonly  image2D  in_border;
layout(r32f,  set = 0, binding = 3) uniform restrict writeonly image2D  out_relief;

layout(set = 0, binding = 4, std430) restrict readonly buffer RegionParams {
	// x = ridge height in metres, y = ridge half-width in uv units
	vec4 data[];
} rp;

layout(set = 0, binding = 5, std430) restrict readonly buffer Seeds {
	vec4 data[];
} seeds;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float seed;
	float sea_level;
	float ridge_scale;
	float height_mult;
	float width_mult;
	float coast_fade;
	float seed_count;
	float blend_sigma;
	float gap_scale;
	float gap_threshold;
	float gap_amount;
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

/// Plain fbm, used to punch saddles through the ranges.
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

/// Ridged multifractal: the abs() fold turns noise valleys into sharp crests,
/// and weighting each octave by the last keeps detail on the ridges only.
float ridged(vec2 v) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	float prev = 1.0;
	for (int i = 0; i < 6; i++) {
		float n = 1.0 - abs(2.0 * vnoise(v) - 1.0);
		n *= n;
		sum += n * amp * prev;
		prev = n;
		norm += amp;
		v *= 2.07;
		amp *= 0.5;
	}
	return sum / norm;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	if (id.x >= int(p.res.x) || id.y >= int(p.res.y)) {
		return;
	}

	float h = imageLoad(in_height, id).r;
	uint packed = imageLoad(in_region, id).r;

	// Ocean keeps its sea-floor height untouched.
	if (packed == 0xFFFFFFFFu || h <= p.sea_level) {
		imageStore(out_relief, id, vec4(h, 0.0, 0.0, 1.0));
		return;
	}

	// Blend every region's ridge settings by distance instead of picking the two
	// nearest. Picking snaps when the second-nearest region changes, which draws
	// a visible crack along the second-order Voronoi edges; a smooth weight does
	// not, and a neighbouring range still fades into its neighbour's character.
	vec2 uv0 = (vec2(id) + 0.5) / p.res;
	float sigma2 = max(p.blend_sigma * p.blend_sigma, 1e-6);
	vec2 acc = vec2(0.0);
	float wsum = 0.0;
	for (int i = 0; i < int(p.seed_count); i++) {
		vec2 d = uv0 - seeds.data[i].xy;
		float w = exp(-dot(d, d) / sigma2);
		acc += w * rp.data[i].xy;
		wsum += w;
	}
	acc /= max(wsum, 1e-6);
	float ridge_height = acc.x * p.height_mult;
	float ridge_width = max(acc.y * p.width_mult, 1e-5);

	float border = imageLoad(in_border, id).r;
	float t = border / ridge_width;
	float mask = exp(-t * t);

	// Mountain passes. Without gaps every region is a sealed bowl, the depression
	// fill has nowhere to drain it, and the whole interior floods into one lake.
	float g = fbm(uv0 * p.gap_scale + vec2(51.3, 17.7));
	float gate = smoothstep(p.gap_threshold - 0.08, p.gap_threshold + 0.08, g);
	mask *= mix(1.0, gate, p.gap_amount);

	// Fade the ridge out at the shoreline so mountains do not grow out of surf.
	float coast = smoothstep(p.sea_level, p.sea_level + p.coast_fade, h);

	vec2 uv = (vec2(id) + 0.5) / p.res;
	float r = ridged(uv * p.ridge_scale);

	imageStore(out_relief, id, vec4(h + r * ridge_height * mask * coast, 0.0, 0.0, 1.0));
}
