@tool
extends RefCounted

## GPU world generator. Every pass is a compute shader on a local RenderingDevice,
## so a parameter tweak is a re-dispatch, not a rebuild.

const LOW_RES := 256          # resolution used for seed placement + harbor search
const MAX_SEEDS := 64         # must match MAX_SEEDS in regions.glsl
const SEED_STRIDE := 16       # bytes per seed (vec4)

var params := {
	"resolution": 2048,
	"seed": 1337,
	"meters_per_pixel": 16.0,
	"sea_level": 200.0,
	"height_scale": 2000.0,
	"coast_warp": 0.25,
	"falloff_pow": 2.2,
	"continent_scale": 2.5,
	"land_bias": 0.28,
	"terrain_scale": 14.0,
	"terrain_detail": 260.0,
	"harbor_radius": 12.0,
	"harbor_min_water": 0.18,
	"ridge_scale": 26.0,
	"ridge_height_mult": 1.0,
	"ridge_width_mult": 1.0,
	"coast_fade": 80.0,
	"ridge_blend_sigma": 0.16,
	"gap_scale": 7.0,
	"gap_threshold": 0.44,
	"gap_amount": 0.85,
	"border_warp": 0.06,
	"warp_scale": 4.0,
	"weight_influence": 0.004,
	"relaxation": 1,
	"basin_radius": 0.045,
	"basin_elevation": 35.0,
	"basin_flatness": 1.0,
	"shelf_radius": 0.07,
	"shelf_depth": 30.0,
	"droplets": 300000,
	"droplet_lifetime": 34,
	"erosion_inertia": 0.05,
	"erode_rate": 0.3,
	"deposit_rate": 0.3,
	"evaporation": 0.02,
	"erosion_gravity": 10.0,
	"sediment_capacity": 4.0,
	"water_res": 512,
	"fill_iterations": 700,
	"flow_iterations": 700,
	"fill_epsilon": 0.02,
	"river_threshold": 12.0,
	"river_softness": 8.0,
	"carve_depth": 45.0,
	"lake_min_depth": 20.0,
	"road_res": 256,
	"road_slope_cost": 9.0,
	"road_water_cost": 12.0,
	"road_notch": 12.0,
	"capital_spokes": 4,
	"view_mode": 5,
	"border_px": 2.5,
}

var region_defs: Array = []
var capital_index := 0

var seeds: Array[Vector2] = []     # uv positions, index == region index
var harbor_uv := Vector2(0.5, 0.5)
var land_fraction := 0.0

var _rd: RenderingDevice
var _shaders := {}
var _pipelines := {}
var _tex := {}
var _tex_res := 0
var _seed_buffer: RID
var _region_buffer: RID
var _field_buffer: RID
var _field_res := 0


func _init() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("No local RenderingDevice. Compute needs the Forward+ renderer.")
		return
	for name in ["continent", "harbor", "regions", "ridges", "downsample",
			"basin", "erode_init", "erode", "erode_resolve",
			"fill", "flowacc", "water", "carve", "roads", "composite"]:
		var file: RDShaderFile = load("res://addons/terraforge/shaders/%s.glsl" % name)
		var shader := _rd.shader_create_from_spirv(file.get_spirv())
		_shaders[name] = shader
		_pipelines[name] = _rd.compute_pipeline_create(shader)
	_seed_buffer = _rd.storage_buffer_create(MAX_SEEDS * SEED_STRIDE)
	_region_buffer = _rd.storage_buffer_create(MAX_SEEDS * SEED_STRIDE)
	_load_regions()


func _load_regions() -> void:
	var text := FileAccess.get_file_as_string("res://addons/terraforge/regions.json")
	var data: Dictionary = JSON.parse_string(text)
	region_defs = data["regions"]
	capital_index = int(data.get("capital_index", 0))


func region_count() -> int:
	return region_defs.size()


func world_size_km() -> float:
	return params["resolution"] * params["meters_per_pixel"] / 1000.0


## Minutes to cross the continent on foot at WoW-ish run speed (7 m/s).
func crossing_minutes(speed_mps: float = 7.0) -> float:
	return (world_size_km() * 1000.0 / speed_mps) / 60.0


# ---------------------------------------------------------------- textures

func _make_texture(w: int, h: int, format: int) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = w
	fmt.height = h
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.format = format
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	return _rd.texture_create(fmt, RDTextureView.new(), [])


func _ensure_textures() -> void:
	var res: int = params["resolution"]
	if _tex_res == res and not _tex.is_empty():
		return
	for rid in _tex.values():
		_rd.free_rid(rid)
	_tex.clear()
	var F := RenderingDevice.DATA_FORMAT_R32_SFLOAT
	_tex["height"] = _make_texture(res, res, F)
	_tex["border"] = _make_texture(res, res, F)
	_tex["relief"] = _make_texture(res, res, F)
	_tex["shaped"] = _make_texture(res, res, F)
	_tex["eroded"] = _make_texture(res, res, F)
	var wr: int = params["water_res"]
	_tex["relief_small"] = _make_texture(wr, wr, F)
	_tex["fill_a"] = _make_texture(wr, wr, F)
	_tex["fill_b"] = _make_texture(wr, wr, F)
	_tex["acc_a"] = _make_texture(wr, wr, F)
	_tex["acc_b"] = _make_texture(wr, wr, F)
	_tex["river_small"] = _make_texture(wr, wr, F)
	_tex["lake_small"] = _make_texture(wr, wr, F)
	_tex["river"] = _make_texture(res, res, F)
	_tex["lake"] = _make_texture(res, res, F)
	_tex["carved"] = _make_texture(res, res, F)
	_tex["road_small"] = _make_texture(params["road_res"], params["road_res"], F)
	_tex["road"] = _make_texture(res, res, F)
	_tex["graded"] = _make_texture(res, res, F)
	_tex["region"] = _make_texture(res, res, RenderingDevice.DATA_FORMAT_R32_UINT)
	_tex["color"] = _make_texture(res, res, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	_tex["low_height"] = _make_texture(LOW_RES, LOW_RES, F)
	_tex["low_score"] = _make_texture(LOW_RES, LOW_RES, F)
	if _field_res != res:
		if _field_buffer.is_valid():
			_rd.free_rid(_field_buffer)
		_field_buffer = _rd.storage_buffer_create(res * res * 4)
		_field_res = res
	_tex_res = res


# ---------------------------------------------------------------- dispatch

func _image_uniform(binding: int, tex: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(tex)
	return u


func _buffer_uniform(binding: int, buf: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buf)
	return u


func _dispatch(name: String, uniforms: Array, push: PackedFloat32Array, res: int) -> void:
	var bytes := push.to_byte_array()
	assert(bytes.size() % 4 == 0, "push constant must be 4-byte aligned")
	var uset := _rd.uniform_set_create(uniforms, _shaders[name], 0)
	var groups := int(ceil(res / 8.0))
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[name])
	_rd.compute_list_bind_uniform_set(list, uset, 0)
	_rd.compute_list_set_push_constant(list, bytes, bytes.size())
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()


## Runs `iters` ping-pong steps in a single command list. Submitting once instead
## of per step is the difference between a stutter and a slider you can drag.
## Returns the texture holding the result.
func _iterate(name: String, source: RID, a: RID, b: RID, push: PackedFloat32Array,
		init_index: int, iters: int, res: int) -> RID:
	var set_ab := _rd.uniform_set_create([
		_image_uniform(0, source), _image_uniform(1, a), _image_uniform(2, b),
	], _shaders[name], 0)
	var set_ba := _rd.uniform_set_create([
		_image_uniform(0, source), _image_uniform(1, b), _image_uniform(2, a),
	], _shaders[name], 0)

	var groups := int(ceil(res / 8.0))
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[name])

	# Step 0 seeds the buffer, so it runs with the init flag set and reads nothing.
	for step in iters + 1:
		var into_b := step % 2 == 0
		_rd.compute_list_bind_uniform_set(list, set_ab if into_b else set_ba, 0)
		push[init_index] = 1.0 if step == 0 else 0.0
		var bytes := push.to_byte_array()
		_rd.compute_list_set_push_constant(list, bytes, bytes.size())
		_rd.compute_list_dispatch(list, groups, groups, 1)
		_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return b if iters % 2 == 0 else a


const HEIGHT_FIXED_POINT := 256.0  # ~4 mm per integer step, plenty for metres


func _run_basin() -> void:
	var res: int = params["resolution"]
	_dispatch("basin", [
		_image_uniform(0, _tex["relief"]),
		_image_uniform(1, _tex["shaped"]),
	], PackedFloat32Array([
		float(res), float(res),
		harbor_uv.x, harbor_uv.y,
		params["sea_level"],
		params["basin_radius"],
		params["basin_elevation"],
		params["basin_flatness"],
		params["shelf_radius"],
		params["shelf_depth"],
	]), res)


func _run_erosion() -> void:
	var res: int = params["resolution"]
	var resf := float(res)
	var groups := int(ceil(res / 8.0))

	_dispatch("erode_init", [
		_image_uniform(0, _tex["shaped"]),
		_buffer_uniform(1, _field_buffer),
	], PackedFloat32Array([resf, resf, HEIGHT_FIXED_POINT]), res)

	var count := int(params["droplets"])
	if count > 0:
		var push := PackedFloat32Array([
			resf, resf,
			HEIGHT_FIXED_POINT,
			float(params["seed"]),
			params["sea_level"],
			float(count),
			float(params["droplet_lifetime"]),
			params["erosion_inertia"],
			params["erode_rate"],
			params["deposit_rate"],
			params["evaporation"],
			params["erosion_gravity"],
			params["sediment_capacity"],
			0.05,
			harbor_uv.x, harbor_uv.y,
			params["basin_radius"],
		])
		var bytes := push.to_byte_array()
		var uset := _rd.uniform_set_create([_buffer_uniform(0, _field_buffer)],
			_shaders["erode"], 0)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipelines["erode"])
		_rd.compute_list_bind_uniform_set(list, uset, 0)
		_rd.compute_list_set_push_constant(list, bytes, bytes.size())
		_rd.compute_list_dispatch(list, int(ceil(count / 64.0)), 1, 1)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()

	_dispatch("erode_resolve", [
		_image_uniform(0, _tex["eroded"]),
		_buffer_uniform(1, _field_buffer),
	], PackedFloat32Array([resf, resf, HEIGHT_FIXED_POINT]), res)


func _run_water() -> void:
	# The depression fill propagates one cell per iteration, so the iteration count
	# has to exceed the distance from the deepest basin to the sea. At 2048 that is
	# over a thousand steps; running the simulation at 512 makes it both converge
	# and cost a quarter of the dispatches. River masks upsample fine.
	var res: int = params["resolution"]
	var wr: int = params["water_res"]
	var wrf := float(wr)

	_dispatch("downsample", [
		_image_uniform(0, _tex["eroded"]),
		_image_uniform(1, _tex["relief_small"]),
	], PackedFloat32Array([wrf, wrf, float(res / wr)]), wr)

	var filled := _iterate("fill", _tex["relief_small"], _tex["fill_a"], _tex["fill_b"],
		PackedFloat32Array([wrf, wrf, params["sea_level"], params["fill_epsilon"], 0.0]),
		4, int(params["fill_iterations"]), wr)
	var acc := _iterate("flowacc", filled, _tex["acc_a"], _tex["acc_b"],
		PackedFloat32Array([wrf, wrf, params["sea_level"], 0.0]),
		3, int(params["flow_iterations"]), wr)

	_dispatch("water", [
		_image_uniform(0, _tex["relief_small"]),
		_image_uniform(1, filled),
		_image_uniform(2, acc),
		_image_uniform(3, _tex["river_small"]),
		_image_uniform(4, _tex["lake_small"]),
	], PackedFloat32Array([
		wrf, wrf,
		params["sea_level"],
		params["river_threshold"],
		params["river_softness"],
		params["lake_min_depth"],
	]), wr)

	_dispatch("carve", [
		_image_uniform(0, _tex["eroded"]),
		_image_uniform(1, _tex["river_small"]),
		_image_uniform(2, _tex["lake_small"]),
		_image_uniform(3, _tex["river"]),
		_image_uniform(4, _tex["lake"]),
		_image_uniform(5, _tex["carved"]),
	], PackedFloat32Array([
		float(res), float(res), wrf, wrf,
		params["sea_level"],
		params["carve_depth"],
	]), res)


func _run_continent(target: RID, res: int) -> void:
	_dispatch("continent", [_image_uniform(0, target)], PackedFloat32Array([
		float(res), float(res),
		float(params["seed"]),
		params["sea_level"],
		params["height_scale"],
		params["coast_warp"],
		params["falloff_pow"],
		params["continent_scale"],
		params["land_bias"],
		params["terrain_scale"],
		params["terrain_detail"],
	]), res)


func _run_harbor() -> PackedFloat32Array:
	_dispatch("harbor", [
		_image_uniform(0, _tex["low_height"]),
		_image_uniform(1, _tex["low_score"]),
	], PackedFloat32Array([
		float(LOW_RES), float(LOW_RES),
		params["sea_level"],
		params["harbor_radius"],
		params["harbor_min_water"],
	]), LOW_RES)
	return _rd.texture_get_data(_tex["low_score"], 0).to_float32_array()


func _run_regions() -> void:
	_dispatch("regions", [
		_image_uniform(0, _tex["height"]),
		_image_uniform(1, _tex["region"]),
		_image_uniform(2, _tex["border"]),
		_buffer_uniform(3, _seed_buffer),
	], PackedFloat32Array([
		float(params["resolution"]), float(params["resolution"]),
		float(params["seed"]),
		params["sea_level"],
		float(region_count()),
		params["border_warp"],
		params["warp_scale"],
	]), params["resolution"])


func _run_ridges() -> void:
	_dispatch("ridges", [
		_image_uniform(0, _tex["height"]),
		_image_uniform(1, _tex["region"]),
		_image_uniform(2, _tex["border"]),
		_image_uniform(3, _tex["relief"]),
		_buffer_uniform(4, _region_buffer),
		_buffer_uniform(5, _seed_buffer),
	], PackedFloat32Array([
		float(params["resolution"]), float(params["resolution"]),
		float(params["seed"]),
		params["sea_level"],
		params["ridge_scale"],
		params["ridge_height_mult"],
		params["ridge_width_mult"],
		params["coast_fade"],
		float(region_count()),
		params["ridge_blend_sigma"],
		params["gap_scale"],
		params["gap_threshold"],
		params["gap_amount"],
	]), params["resolution"])


func _run_composite() -> void:
	_dispatch("composite", [
		_image_uniform(0, _tex["graded"]),
		_image_uniform(1, _tex["region"]),
		_image_uniform(2, _tex["border"]),
		_image_uniform(3, _tex["color"]),
		_buffer_uniform(4, _seed_buffer),
		_image_uniform(5, _tex["river"]),
		_image_uniform(6, _tex["lake"]),
		_image_uniform(7, _tex["road"]),
	], PackedFloat32Array([
		float(params["resolution"]), float(params["resolution"]),
		params["sea_level"],
		params["height_scale"],
		float(params["view_mode"]),
		params["meters_per_pixel"],
		params["border_px"],
	]), params["resolution"])


# ---------------------------------------------------------------- seeding

func _upload_seeds() -> void:
	var data := PackedFloat32Array()
	data.resize(MAX_SEEDS * 4)
	for i in region_count():
		var w: float = float(region_defs[i].get("weight", 1.0))
		data[i * 4 + 0] = seeds[i].x
		data[i * 4 + 1] = seeds[i].y
		# Power-diagram weight: shifts the border outward without moving the seed.
		data[i * 4 + 2] = (w - 1.0) * params["weight_influence"]
		data[i * 4 + 3] = 1.0 if i == capital_index else 0.0
	_rd.buffer_update(_seed_buffer, 0, data.size() * 4, data.to_byte_array())

	var rp := PackedFloat32Array()
	rp.resize(MAX_SEEDS * 4)
	for i in region_count():
		rp[i * 4 + 0] = float(region_defs[i].get("ridge_height", 600.0))
		rp[i * 4 + 1] = float(region_defs[i].get("ridge_width", 0.03))
	_rd.buffer_update(_region_buffer, 0, rp.size() * 4, rp.to_byte_array())


func _pick_harbor(score: PackedFloat32Array) -> Vector2:
	var best := -1.0
	var best_i := -1
	for i in score.size():
		if score[i] > best:
			best = score[i]
			best_i = i
	if best_i < 0 or best <= 0.0:
		return Vector2(0.5, 0.5)  # no coast found; fall back to centre
	var x := best_i % LOW_RES
	var y := best_i / LOW_RES
	return Vector2((x + 0.5) / LOW_RES, (y + 0.5) / LOW_RES)


func _place_seeds(mask: PackedFloat32Array) -> void:
	var sea: float = params["sea_level"]
	var land_cells: Array[Vector2] = []
	for i in mask.size():
		if mask[i] > sea:
			land_cells.append(Vector2(
				(i % LOW_RES + 0.5) / LOW_RES,
				(i / LOW_RES + 0.5) / LOW_RES))
	land_fraction = float(land_cells.size()) / float(LOW_RES * LOW_RES)

	seeds.clear()
	seeds.resize(region_count())
	seeds[capital_index] = harbor_uv

	if land_cells.is_empty():
		for i in region_count():
			seeds[i] = Vector2(0.5, 0.5)
		return

	# Dart throwing with a shrinking minimum distance. Simple, and with only
	# 15 seeds it converges in a handful of attempts.
	# ponytail: dart throwing, swap for real Poisson-disk if seed count grows a lot.
	var rng := RandomNumberGenerator.new()
	rng.seed = params["seed"]
	var placed: Array[int] = [capital_index]
	var min_dist := sqrt(land_fraction / float(region_count())) * 0.75
	for i in region_count():
		if i == capital_index:
			continue
		var dist := min_dist
		var found := false
		for attempt in 400:
			var candidate: Vector2 = land_cells[rng.randi() % land_cells.size()]
			var ok := true
			for j in placed:
				if seeds[j].distance_to(candidate) < dist:
					ok = false
					break
			if ok:
				seeds[i] = candidate
				found = true
				break
			if attempt % 50 == 49:
				dist *= 0.8
		if not found:
			seeds[i] = land_cells[rng.randi() % land_cells.size()]
		placed.append(i)

	_relax(mask)


func _relax(mask: PackedFloat32Array) -> void:
	## Lloyd relaxation evens out region sizes. The capital stays pinned to its
	## harbour, otherwise it drifts inland and stops being a port.
	var sea: float = params["sea_level"]
	var steps: int = int(params["relaxation"])
	for _step in steps:
		var sum := PackedVector2Array()
		var count := PackedInt32Array()
		sum.resize(region_count())
		count.resize(region_count())
		for i in mask.size():
			if mask[i] <= sea:
				continue
			var uv := Vector2((i % LOW_RES + 0.5) / LOW_RES, (i / LOW_RES + 0.5) / LOW_RES)
			var best := INF
			var best_j := 0
			for j in region_count():
				var w: float = float(region_defs[j].get("weight", 1.0))
				var d: float = uv.distance_squared_to(seeds[j]) - (w - 1.0) * float(params["weight_influence"])
				if d < best:
					best = d
					best_j = j
			sum[best_j] += uv
			count[best_j] += 1
		for j in region_count():
			if j == capital_index or count[j] == 0:
				continue
			seeds[j] = sum[j] / float(count[j])


# ---------------------------------------------------------------- roads

## Region pairs joined by a road, as [from, to] index pairs. Exported with the
## world so the game can answer "which road leads to Ashmoor".
var road_graph: Array = []


## Downsample a square float field by whole-number averaging.
func _shrink(src: PackedFloat32Array, from_res: int, to_res: int) -> PackedFloat32Array:
	var f := from_res / to_res
	var out := PackedFloat32Array()
	out.resize(to_res * to_res)
	for y in to_res:
		for x in to_res:
			var sum := 0.0
			for sy in f:
				for sx in f:
					sum += src[(y * f + sy) * from_res + x * f + sx]
			out[y * to_res + x] = sum / float(f * f)
	return out


## Minimum spanning tree over the region seeds, plus direct spokes from the
## capital. The tree alone would leave the capital at the end of a chain; a
## capital is the hub everything routes back to, so it gets its own edges.
func _road_edges() -> Array:
	var n := region_count()
	var edges: Array = []
	var linked := [capital_index]
	var pending := range(n).filter(func(i: int) -> bool: return i != capital_index)

	while not pending.is_empty():
		var best_d := INF
		var best_a := -1
		var best_b := -1
		for a in linked:
			for b in pending:
				var d: float = seeds[a].distance_to(seeds[b])
				if d < best_d:
					best_d = d
					best_a = a
					best_b = b
		edges.append([best_a, best_b])
		linked.append(best_b)
		pending.erase(best_b)

	var by_distance := pending.duplicate()
	by_distance = range(n).filter(func(i: int) -> bool: return i != capital_index)
	by_distance.sort_custom(func(a: int, b: int) -> bool:
		return seeds[capital_index].distance_to(seeds[a]) < seeds[capital_index].distance_to(seeds[b]))
	for i in mini(int(params["capital_spokes"]), by_distance.size()):
		var pair := [capital_index, by_distance[i]]
		if not edges.any(func(e: Array) -> bool:
				return (e[0] == pair[0] and e[1] == pair[1]) or (e[0] == pair[1] and e[1] == pair[0])):
			edges.append(pair)
	return edges


func _run_roads() -> void:
	var rr: int = params["road_res"]
	var wr: int = params["water_res"]
	var sea: float = params["sea_level"]

	var height := _shrink(_rd.texture_get_data(_tex["relief_small"], 0).to_float32_array(), wr, rr)
	var river := _shrink(_rd.texture_get_data(_tex["river_small"], 0).to_float32_array(), wr, rr)
	var lake := _shrink(_rd.texture_get_data(_tex["lake_small"], 0).to_float32_array(), wr, rr)

	# AStarGrid2D is built in and does exactly this job: weighted grid pathfinding.
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, rr, rr)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.update()

	for y in rr:
		for x in rr:
			var i := y * rr + x
			var cell := Vector2i(x, y)
			if height[i] <= sea or lake[i] > 0.0:
				grid.set_point_solid(cell, true)
				continue
			# Steepest neighbour drop stands in for slope; roads hate climbing.
			var slope := 0.0
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var q: Vector2i = cell + d
				if q.x < 0 or q.y < 0 or q.x >= rr or q.y >= rr:
					continue
				slope = maxf(slope, absf(height[q.y * rr + q.x] - height[i]))
			var w: float = 1.0 + (slope / 50.0) * params["road_slope_cost"] \
				+ river[i] * params["road_water_cost"]
			grid.set_point_weight_scale(cell, clampf(w, 1.0, 64.0))

	var mask := PackedFloat32Array()
	mask.resize(rr * rr)
	road_graph = _road_edges()

	for edge in road_graph:
		var from := Vector2i(clampi(int(seeds[edge[0]].x * rr), 0, rr - 1),
			clampi(int(seeds[edge[0]].y * rr), 0, rr - 1))
		var to := Vector2i(clampi(int(seeds[edge[1]].x * rr), 0, rr - 1),
			clampi(int(seeds[edge[1]].y * rr), 0, rr - 1))
		# A seed can land in a lake or just offshore; nothing routes to a solid cell.
		if grid.is_point_solid(from) or grid.is_point_solid(to):
			continue
		# One cell per step. The bilinear upsample already spreads it to a few
		# pixels at full resolution; a 3x3 brush here came out 400 m wide.
		for point in grid.get_id_path(from, to):
			mask[point.y * rr + point.x] = 1.0

	_rd.texture_update(_tex["road_small"], 0, mask.to_byte_array())

	var res: int = params["resolution"]
	_dispatch("roads", [
		_image_uniform(0, _tex["carved"]),
		_image_uniform(1, _tex["road_small"]),
		_image_uniform(2, _tex["road"]),
		_image_uniform(3, _tex["graded"]),
	], PackedFloat32Array([
		float(res), float(res), float(rr), float(rr),
		sea,
		params["road_notch"],
	]), res)


# ---------------------------------------------------------------- export

## Writes the bake set to `dir`. Returns the list of files written.
func export_world(dir: String) -> PackedStringArray:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var res: int = params["resolution"]
	var written := PackedStringArray()

	# Heightmap in real metres, not normalised 0..1: the conversion constant is
	# the thing every terrain importer gets wrong later.
	var height := heights()
	var height_image := Image.create_from_data(res, res, false, Image.FORMAT_RF,
		height.to_byte_array())
	var exr := dir.path_join("heightmap.exr")
	if height_image.save_exr(exr, true) == OK:
		written.append(exr)
	else:
		# EXR writing is not in every build; 16-bit PNG keeps the bake usable.
		var png := dir.path_join("heightmap.png")
		var norm := Image.create_empty(res, res, false, Image.FORMAT_RH)
		for y in res:
			for x in res:
				var v: float = height[y * res + x] / maxf(params["height_scale"], 1.0)
				norm.set_pixel(x, y, Color(v, v, v))
		norm.save_png(png)
		written.append(png)

	var ids := region_ids()
	var rivers_data := rivers()
	var lakes_data := lakes()
	var roads_data := roads()

	var region_bytes := PackedByteArray()
	var road_bytes := PackedByteArray()
	var water_bytes := PackedByteArray()
	region_bytes.resize(res * res)
	road_bytes.resize(res * res)
	water_bytes.resize(res * res * 3)
	for i in res * res:
		# 255 marks ocean; region ids stay 0..14 so they index regions.json directly.
		region_bytes[i] = 255 if ids[i] < 0 else ids[i]
		road_bytes[i] = int(clampf(roads_data[i], 0.0, 1.0) * 255.0)
		water_bytes[i * 3 + 0] = int(clampf(rivers_data[i], 0.0, 1.0) * 255.0)
		water_bytes[i * 3 + 1] = int(clampf(lakes_data[i], 0.0, 255.0))
		water_bytes[i * 3 + 2] = 0

	for entry in [
		["regions.png", Image.FORMAT_L8, region_bytes],
		["roads.png", Image.FORMAT_L8, road_bytes],
		["water.png", Image.FORMAT_RGB8, water_bytes],
	]:
		var path: String = dir.path_join(entry[0])
		Image.create_from_data(res, res, false, entry[1], entry[2]).save_png(path)
		written.append(path)

	var preview := dir.path_join("preview.png")
	render().save_png(preview)
	written.append(preview)

	var regions_out: Array = []
	for i in region_count():
		var def: Dictionary = region_defs[i].duplicate()
		def["id"] = i
		def["seed_uv"] = [seeds[i].x, seeds[i].y]
		def["seed_px"] = [int(seeds[i].x * res), int(seeds[i].y * res)]
		regions_out.append(def)

	var meta := {
		"resolution": res,
		"meters_per_pixel": params["meters_per_pixel"],
		"world_size_km": world_size_km(),
		"sea_level_m": params["sea_level"],
		"height_scale_m": params["height_scale"],
		"seed": params["seed"],
		"capital_index": capital_index,
		"harbor_uv": [harbor_uv.x, harbor_uv.y],
		"harbor_px": [int(harbor_uv.x * res), int(harbor_uv.y * res)],
		"regions": regions_out,
		"road_graph": road_graph,
		"layers": {
			"heightmap": "metres above zero, sea level at sea_level_m",
			"regions.png": "region id, 255 = ocean",
			"water.png": "R = river strength, G = lake depth in metres clamped to 255",
			"roads.png": "road strength",
		},
	}
	var json_path := dir.path_join("world.json")
	var f := FileAccess.open(json_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, "  "))
	f.close()
	written.append(json_path)

	return written


# ---------------------------------------------------------------- public

## Full regeneration. Returns the preview image.
func generate() -> Image:
	_ensure_textures()
	_run_continent(_tex["height"], params["resolution"])
	_run_continent(_tex["low_height"], LOW_RES)
	harbor_uv = _pick_harbor(_run_harbor())
	_place_seeds(_rd.texture_get_data(_tex["low_height"], 0).to_float32_array())
	_upload_seeds()
	_run_regions()
	_run_ridges()
	_run_basin()
	_run_erosion()
	_run_water()
	_run_roads()
	return render()


## Re-runs only the display pass. Use for view-mode switches.
func render() -> Image:
	_run_composite()
	var res: int = params["resolution"]
	var bytes := _rd.texture_get_data(_tex["color"], 0)
	return Image.create_from_data(res, res, false, Image.FORMAT_RGBA8, bytes)


## Nearest-region id per pixel, with -1 for ocean. The texture also packs the
## second-nearest region in the high 16 bits for the ridge pass; strip it here.
func region_ids() -> PackedInt32Array:
	var raw := _rd.texture_get_data(_tex["region"], 0).to_int32_array()
	var out := PackedInt32Array()
	out.resize(raw.size())
	for i in raw.size():
		out[i] = -1 if raw[i] == -1 else (raw[i] & 0xFFFF)
	return out


## Final height in metres per pixel: ridges raised, river channels carved, road
## notches graded. This is the export bake.
func heights() -> PackedFloat32Array:
	return _rd.texture_get_data(_tex["graded"], 0).to_float32_array()


## Road strength 0..1 per pixel.
func roads() -> PackedFloat32Array:
	return _rd.texture_get_data(_tex["road"], 0).to_float32_array()


## River strength 0..1 per pixel.
func rivers() -> PackedFloat32Array:
	return _rd.texture_get_data(_tex["river"], 0).to_float32_array()


## Lake depth in metres per pixel, 0 where there is no lake.
func lakes() -> PackedFloat32Array:
	return _rd.texture_get_data(_tex["lake"], 0).to_float32_array()
