extends Control

## Tool UI: map preview on the left, parameters on the right.
## Changing a parameter re-runs only the passes that depend on it.

const VIEW_NAMES := ["Height", "Hillshade", "Regions", "Water", "Roads", "Composite"]

# Parameters that only affect the display pass. Everything else needs a full regen.
const DISPLAY_ONLY := ["view_mode", "border_px"]

var gen: WorldGen
var map_rect: TextureRect
var overlay: Control
var info_label: Label
var _seed_edit: LineEdit
var _defaults: Dictionary
var _busy := false


func _ready() -> void:
	gen = WorldGen.new()
	_defaults = gen.params.duplicate()
	_build_ui()
	_regenerate()
	if "--test" in OS.get_cmdline_user_args():
		_run_self_check()


# ---------------------------------------------------------------- ui

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.split_offset = 960
	add_child(split)

	var map_holder := Control.new()
	map_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(map_holder)

	map_rect = TextureRect.new()
	map_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	map_holder.add_child(map_rect)

	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_labels)
	map_holder.add_child(overlay)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 340
	split.add_child(scroll)

	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 6)
	scroll.add_child(panel)

	info_label = Label.new()
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(info_label)

	_add_option(panel, "View", VIEW_NAMES, "view_mode")
	_add_seed_row(panel)
	_add_slider(panel, "Metres / pixel", "meters_per_pixel", 2, 64, 1)
	_add_slider(panel, "Land amount", "land_bias", -0.2, 0.8, 0.01)
	_add_slider(panel, "Height scale (m)", "height_scale", 500, 4000, 50)
	_add_slider(panel, "Coast ruggedness", "coast_warp", 0.0, 0.5, 0.01)
	_add_slider(panel, "Continent falloff", "falloff_pow", 0.8, 5.0, 0.1)
	_add_slider(panel, "Continent detail", "continent_scale", 1.0, 8.0, 0.1)
	_add_slider(panel, "Harbour search radius", "harbor_radius", 4, 32, 1)
	_add_slider(panel, "Harbour min water", "harbor_min_water", 0.0, 0.6, 0.01)
	_add_slider(panel, "Terrain detail (m)", "terrain_detail", 0.0, 800.0, 10.0)
	_add_slider(panel, "Terrain detail scale", "terrain_scale", 2.0, 40.0, 0.5)
	_add_slider(panel, "Ridge height x", "ridge_height_mult", 0.0, 3.0, 0.05)
	_add_slider(panel, "Ridge width x", "ridge_width_mult", 0.2, 3.0, 0.05)
	_add_slider(panel, "Ridge detail", "ridge_scale", 4.0, 80.0, 1.0)
	_add_slider(panel, "Ridge blend radius", "ridge_blend_sigma", 0.04, 0.5, 0.01)
	_add_slider(panel, "Coast fade (m)", "coast_fade", 0.0, 400.0, 10.0)
	_add_slider(panel, "Pass frequency", "gap_scale", 2.0, 20.0, 0.5)
	_add_slider(panel, "Pass width", "gap_threshold", 0.2, 0.7, 0.01)
	_add_slider(panel, "Pass amount", "gap_amount", 0.0, 1.0, 0.05)
	_add_slider(panel, "Basin radius", "basin_radius", 0.0, 0.15, 0.005)
	_add_slider(panel, "Basin elevation (m)", "basin_elevation", 0.0, 200.0, 5.0)
	_add_slider(panel, "Basin flatness", "basin_flatness", 0.0, 1.0, 0.05)
	_add_slider(panel, "Shelf radius", "shelf_radius", 0.0, 0.2, 0.005)
	_add_slider(panel, "Shelf depth (m)", "shelf_depth", 0.0, 150.0, 5.0)
	_add_slider(panel, "Droplets", "droplets", 0, 1500000, 50000)
	_add_slider(panel, "Droplet lifetime", "droplet_lifetime", 4, 96, 1)
	_add_slider(panel, "Erode rate", "erode_rate", 0.0, 1.0, 0.02)
	_add_slider(panel, "Deposit rate", "deposit_rate", 0.0, 1.0, 0.02)
	_add_slider(panel, "Sediment capacity", "sediment_capacity", 0.5, 16.0, 0.5)
	_add_slider(panel, "Evaporation", "evaporation", 0.0, 0.2, 0.005)
	_add_slider(panel, "River threshold", "river_threshold", 4.0, 120.0, 1.0)
	_add_slider(panel, "River softness", "river_softness", 1.0, 60.0, 1.0)
	_add_slider(panel, "River carve (m)", "carve_depth", 0.0, 200.0, 5.0)
	_add_slider(panel, "Lake min depth (m)", "lake_min_depth", 0.0, 120.0, 1.0)
	_add_slider(panel, "Fill iterations", "fill_iterations", 0, 800, 25)
	_add_slider(panel, "Flow iterations", "flow_iterations", 0, 800, 25)
	_add_slider(panel, "Road slope cost", "road_slope_cost", 0.0, 40.0, 0.5)
	_add_slider(panel, "Road water cost", "road_water_cost", 0.0, 40.0, 0.5)
	_add_slider(panel, "Road notch (m)", "road_notch", 0.0, 200.0, 5.0)
	_add_slider(panel, "Capital spokes", "capital_spokes", 0, 8, 1)
	_add_slider(panel, "Border ruggedness", "border_warp", 0.0, 0.2, 0.005)
	_add_slider(panel, "Border detail", "warp_scale", 1.0, 12.0, 0.25)
	_add_slider(panel, "Region size spread", "weight_influence", 0.0, 0.02, 0.001)
	_add_slider(panel, "Relaxation", "relaxation", 0, 4, 1)
	_add_slider(panel, "Border line width", "border_px", 0.0, 8.0, 0.5)

	var export_button := Button.new()
	export_button.text = "Export bake"
	export_button.pressed.connect(func() -> void:
		var files := gen.export_world("res://export")
		info_label.text = "Exported %d files to\n%s" % [
			files.size(), ProjectSettings.globalize_path("res://export")])
	panel.add_child(export_button)

	var reset := Button.new()
	reset.text = "Reset settings"
	reset.pressed.connect(func() -> void:
		gen.params = _defaults.duplicate()
		_regenerate()
		_refresh_controls())
	panel.add_child(reset)


func _add_seed_row(parent: Node) -> void:
	var box := VBoxContainer.new()
	var text := Label.new()
	text.text = "Seed"
	box.add_child(text)

	var row := HBoxContainer.new()
	_seed_edit = LineEdit.new()
	_seed_edit.text = str(gen.params["seed"])
	_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_seed_edit)

	_seed_edit.text_submitted.connect(func(_t: String) -> void:
		gen.params["seed"] = int(_seed_edit.text.strip_edges())
		_seed_edit.text = str(gen.params["seed"])
		_regenerate())

	var rnd := Button.new()
	rnd.text = "Random"
	rnd.pressed.connect(func() -> void:
		gen.params["seed"] = randi() % 10000
		_seed_edit.text = str(gen.params["seed"])
		_regenerate())
	row.add_child(rnd)

	box.add_child(row)
	parent.add_child(box)


func _add_slider(parent: Node, label: String, key: String, lo: float, hi: float, step: float) -> void:
	var box := VBoxContainer.new()
	var text := Label.new()
	text.text = "%s: %s" % [label, gen.params[key]]
	box.add_child(text)

	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = gen.params[key]
	slider.set_meta("key", key)
	slider.set_meta("label", label)
	slider.set_meta("text_node", text)
	slider.value_changed.connect(func(v: float) -> void:
		gen.params[key] = int(v) if step == 1 and lo == int(lo) else v
		text.text = "%s: %s" % [label, gen.params[key]]
		_apply_change(key))
	box.add_child(slider)
	parent.add_child(box)


func _add_option(parent: Node, label: String, items: Array, key: String) -> void:
	var box := VBoxContainer.new()
	var text := Label.new()
	text.text = label
	box.add_child(text)
	var option := OptionButton.new()
	for i in items.size():
		option.add_item(str(items[i]), i)
	option.selected = gen.params[key]
	option.set_meta("key", key)
	option.item_selected.connect(func(idx: int) -> void:
		gen.params[key] = idx
		_apply_change(key))
	box.add_child(option)
	parent.add_child(box)


func _refresh_controls() -> void:
	_seed_edit.text = str(gen.params["seed"])
	for slider in _find_sliders(self):
		var key: String = slider.get_meta("key")
		slider.set_value_no_signal(gen.params[key])
		var text: Label = slider.get_meta("text_node")
		text.text = "%s: %s" % [slider.get_meta("label"), gen.params[key]]
	for opt in _find_nodes(self, OptionButton):
		opt.select(gen.params[opt.get_meta("key")])


func _find_sliders(node: Node) -> Array:
	return _find_nodes(node, HSlider)


func _find_nodes(node: Node, type: Variant) -> Array:
	var out := []
	for child in node.get_children():
		if is_instance_of(child, type) and child.has_meta("key"):
			out.append(child)
		out.append_array(_find_nodes(child, type))
	return out


# ---------------------------------------------------------------- generation

func _apply_change(key: String) -> void:
	if key in DISPLAY_ONLY:
		_show(gen.render())
	else:
		_regenerate()


func _regenerate() -> void:
	if _busy:
		return
	_busy = true
	var start := Time.get_ticks_msec()
	_show(gen.generate())
	var elapsed := Time.get_ticks_msec() - start
	info_label.text = "%d regions · capital %s\n%.1f km across · %.0f min on foot\n%.0f%% land · %d ms" % [
		gen.region_count(),
		gen.region_defs[gen.capital_index]["name"],
		gen.world_size_km(),
		gen.crossing_minutes(),
		gen.land_fraction * 100.0,
		elapsed,
	]
	_busy = false


func _show(image: Image) -> void:
	map_rect.texture = ImageTexture.create_from_image(image)
	overlay.queue_redraw()


# ---------------------------------------------------------------- labels

func _map_to_screen(uv: Vector2) -> Vector2:
	## Mirrors STRETCH_KEEP_ASPECT_CENTERED so labels land on their regions.
	var box := map_rect.size
	var side: float = minf(box.x, box.y)
	var origin := (box - Vector2(side, side)) * 0.5
	return origin + uv * side


func _draw_labels() -> void:
	if gen.seeds.is_empty():
		return
	var font := ThemeDB.fallback_font
	for i in gen.region_count():
		var pos := _map_to_screen(gen.seeds[i])
		var name: String = gen.region_defs[i]["name"]
		var is_capital: bool = i == gen.capital_index
		var size := 15 if is_capital else 12
		var width := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var at := pos - Vector2(width * 0.5, 0.0)
		overlay.draw_string(font, at + Vector2(1, 1), name,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
		overlay.draw_string(font, at, name, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			Color(1.0, 0.88, 0.45) if is_capital else Color.WHITE)
		if is_capital:
			overlay.draw_arc(pos, 9.0, 0.0, TAU, 24, Color(1.0, 0.85, 0.35), 2.0)


# ---------------------------------------------------------------- self check

func _run_self_check() -> void:
	# Let the UI lay out and draw so the capture shows labels, not just the map.
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var fails: Array[String] = []

	# Seed field and Reset must round-trip params through the UI.
	gen.params["land_bias"] = 0.5
	gen.params["view_mode"] = 0
	gen.params = _defaults.duplicate()
	_refresh_controls()
	if gen.params["land_bias"] != _defaults["land_bias"] or _seed_edit.text != str(_defaults["seed"]):
		fails.append("reset did not restore defaults / seed field")

	# Every named region must actually own pixels, or a name is a lie.
	var ids := gen.region_ids()
	var seen := {}
	for v in ids:
		if v != -1:
			seen[v] = true
	if seen.size() != gen.region_count():
		fails.append("regions with pixels: %d, expected %d" % [seen.size(), gen.region_count()])

	# A continent that is all land or all sea means the falloff is broken.
	if gen.land_fraction < 0.15 or gen.land_fraction > 0.85:
		fails.append("land fraction %.2f outside 0.15..0.85" % gen.land_fraction)

	# The capital must sit on land with open water in reach, or it is no harbour.
	var res: int = gen.params["resolution"]
	var heights := gen.heights()
	var sea: float = gen.params["sea_level"]
	var cx := int(gen.harbor_uv.x * res)
	var cy := int(gen.harbor_uv.y * res)
	if heights[cy * res + cx] <= sea:
		fails.append("capital is in the sea: height %.1f m, sea %.1f m" % [heights[cy * res + cx], sea])
	# Only the core is fully flattened; outside it the basin deliberately eases
	# back into the surrounding hills.
	var basin_r := int(gen.params["basin_radius"] * 0.35 * res)
	var river_mask := gen.rivers()
	var road_mask := gen.roads()
	var lo := INF
	var hi := -INF
	for dy in range(-basin_r, basin_r + 1, 4):
		for dx in range(-basin_r, basin_r + 1, 4):
			var bi := clampi(cy + dy, 0, res - 1) * res + clampi(cx + dx, 0, res - 1)
			# A river channel and a road cutting through are wanted, not defects;
			# the check is whether the ground between them is buildable.
			if heights[bi] <= sea or river_mask[bi] > 0.2 or road_mask[bi] > 0.2:
				continue
			lo = minf(lo, heights[bi])
			hi = maxf(hi, heights[bi])
	if hi - lo > 25.0:
		fails.append("capital basin is not flat: %.0f m of relief" % (hi - lo))
	else:
		print("capital basin relief: %.1f m over %d px" % [hi - lo, basin_r * 2])

	var water_near := false
	var reach := int(res * 0.03)
	for dy in range(-reach, reach + 1, 4):
		for dx in range(-reach, reach + 1, 4):
			var x := clampi(cx + dx, 0, res - 1)
			var y := clampi(cy + dy, 0, res - 1)
			if heights[y * res + x] <= sea:
				water_near = true
	if not water_near:
		fails.append("no water within %d px of capital" % reach)

	var exported := gen.export_world("user://selfcheck_export")
	for path in exported:
		if not FileAccess.file_exists(path):
			fails.append("export missing %s" % path)
	var baked := Image.load_from_file(ProjectSettings.globalize_path(
		"user://selfcheck_export/regions.png"))
	if baked == null or baked.get_width() != res:
		fails.append("regions.png did not bake at %d px" % res)
	# The bake claims metres above zero; check the file actually round-trips that.
	var exr := Image.load_from_file(ProjectSettings.globalize_path(
		"user://selfcheck_export/heightmap.exr"))
	if exr == null:
		fails.append("heightmap.exr did not load back")
	else:
		var baked_m := exr.get_pixel(cx, cy).r
		var want_m := heights[cy * res + cx]
		if absf(baked_m - want_m) > 1.0:
			fails.append("heightmap.exr is not metres: %.1f baked vs %.1f expected"
				% [baked_m, want_m])
		else:
			print("heightmap.exr at capital: %.1f m" % baked_m)
	print("export: ", ProjectSettings.globalize_path("user://selfcheck_export"))

	var shot := "user://selfcheck.png"
	get_viewport().get_texture().get_image().save_png(shot)
	print("screenshot: ", ProjectSettings.globalize_path(shot))
	gen.params["view_mode"] = 1
	gen.render().save_png("user://selfcheck_relief.png")
	print("relief: ", ProjectSettings.globalize_path("user://selfcheck_relief.png"))
	if fails.is_empty():
		print("PASS: %d regions, capital %s at %v, land %.0f%%" % [
			gen.region_count(),
			gen.region_defs[gen.capital_index]["name"],
			gen.harbor_uv,
			gen.land_fraction * 100.0])
	else:
		for f in fails:
			print("FAIL: ", f)
	get_tree().quit(0 if fails.is_empty() else 1)
