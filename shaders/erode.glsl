#[compute]
#version 450

// Particle hydraulic erosion. One thread per droplet: it runs downhill picking up
// sediment on steep ground and dropping it where the slope eases, which is what
// turns fbm lumps into valleys with fans at their mouths.
// ponytail: droplets race on shared cells; atomics keep the field consistent, and
// the ordering that is lost does not matter at this scale.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Field {
	int data[];
} field;

layout(push_constant, std430) uniform Params {
	vec2 res;
	float scale;
	float seed;
	float sea_level;
	float droplets;
	float lifetime;
	float inertia;
	float erode_rate;
	float deposit_rate;
	float evaporation;
	float gravity;
	float capacity_factor;
	float min_slope;
	vec2 harbor;
	float basin_radius;
} p;

/// Integer hash. A sin-based hash on consecutive droplet ids lands the starts on
/// a lattice, and the tracks then cut dead-straight axis-aligned grooves.
uint wang(uint s) {
	s = (s ^ 61u) ^ (s >> 16);
	s *= 9u;
	s ^= s >> 4;
	s *= 0x27d4eb2du;
	s ^= s >> 15;
	return s;
}

float rnd(uint s) {
	return float(wang(s ^ uint(p.seed) * 2654435761u)) / 4294967296.0;
}

int index_of(ivec2 c) {
	return c.y * int(p.res.x) + c.x;
}

float height_at(ivec2 c) {
	return float(field.data[index_of(c)]) / p.scale;
}

void add_height(ivec2 c, float amount) {
	if (c.x < 0 || c.y < 0 || c.x >= int(p.res.x) || c.y >= int(p.res.y)) {
		return;
	}
	atomicAdd(field.data[index_of(c)], int(amount * p.scale));
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	if (gid >= uint(p.droplets)) {
		return;
	}

	// Adjacent droplet ids must not produce correlated starts, or the launch
	// points line up and the tracks come out as evenly spaced parallel grooves.
	float fx = rnd(gid * 0x9E3779B9u);
	float fy = rnd(gid * 0x85EBCA6Bu + 0x7FEB352Du);
	vec2 pos = vec2(2.0) + vec2(fx, fy) * (p.res - vec2(4.0));

	vec2 dir = vec2(0.0);
	float speed = 1.0;
	float water = 1.0;
	float sediment = 0.0;

	for (int step = 0; step < int(p.lifetime); step++) {
		ivec2 cell = ivec2(pos);
		vec2 f = pos - vec2(cell);

		float h00 = height_at(cell);
		float h10 = height_at(cell + ivec2(1, 0));
		float h01 = height_at(cell + ivec2(0, 1));
		float h11 = height_at(cell + ivec2(1, 1));

		// Droplets stop at the shoreline; the sea floor is not theirs to sculpt.
		if (h00 <= p.sea_level) {
			break;
		}

		float h = mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
		vec2 grad = vec2(
			mix(h10 - h00, h11 - h01, f.y),
			mix(h01 - h00, h11 - h10, f.x));

		// Flat ground ends the droplet. Normalising dir preserves its heading
		// exactly when the gradient vanishes, so a droplet that wanders onto a
		// plain would otherwise fly dead straight forever, ploughing a groove.
		if (dot(grad, grad) < 1e-6) {
			add_height(cell, sediment);
			break;
		}

		dir = normalize(dir * p.inertia - grad * (1.0 - p.inertia));

		vec2 npos = pos + dir;
		if (npos.x < 1.0 || npos.y < 1.0
				|| npos.x >= p.res.x - 2.0 || npos.y >= p.res.y - 2.0) {
			break;
		}

		ivec2 ncell = ivec2(npos);
		vec2 nf = npos - vec2(ncell);
		float nh = mix(
			mix(height_at(ncell), height_at(ncell + ivec2(1, 0)), nf.x),
			mix(height_at(ncell + ivec2(0, 1)), height_at(ncell + ivec2(1, 1)), nf.x),
			nf.y);

		// Leave the capital basin alone: it was flattened on purpose, and droplets
		// would either gully it or silt it up.
		float basin_damp = smoothstep(p.basin_radius * 0.6, p.basin_radius * 1.4,
			distance(pos / p.res, p.harbor));

		float dh = nh - h;
		float capacity = max(-dh, p.min_slope) * speed * water * p.capacity_factor;

		if (sediment > capacity || dh > 0.0) {
			// Uphill means the droplet stalled: drop enough to fill the dip, no more.
			float amount = ((dh > 0.0) ? min(dh, sediment) : (sediment - capacity) * p.deposit_rate)
				* basin_damp;
			sediment -= amount;
			add_height(cell, amount * (1.0 - f.x) * (1.0 - f.y));
			add_height(cell + ivec2(1, 0), amount * f.x * (1.0 - f.y));
			add_height(cell + ivec2(0, 1), amount * (1.0 - f.x) * f.y);
			add_height(cell + ivec2(1, 1), amount * f.x * f.y);
		} else {
			// Never cut deeper than the step itself, or the droplet digs a pit.
			float amount = min((capacity - sediment) * p.erode_rate, -dh) * basin_damp;
			sediment += amount;
			// Spread the cut over a 3x3 brush so channels have banks, not walls.
			for (int y = -1; y <= 1; y++) {
				for (int x = -1; x <= 1; x++) {
					float w = (x == 0 && y == 0) ? 0.4 : ((x == 0 || y == 0) ? 0.1 : 0.05);
					add_height(cell + ivec2(x, y), -amount * w);
				}
			}
		}

		speed = sqrt(max(speed * speed + (-dh) * p.gravity, 0.0));
		water *= 1.0 - p.evaporation;
		pos = npos;
	}
}
