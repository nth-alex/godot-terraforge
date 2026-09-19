@tool
extends SubViewportContainer

## 3D preview of the bake. The heightmap drives vertex displacement on a flat
## grid, so a regenerate is a texture swap, not a mesh rebuild.

const GRID := 255          # plane subdivisions; 256x256 verts
const SUN_ANGLE := Vector3(-50.0, -35.0, 0.0)
const FOV := 70.0
const FlyCam := preload("res://addons/terraforge/fly_cam.gd")
const FAR := 100000.0      # world-scale terrain; the 4000 default clips it

var cam: Camera3D  # FlyCam; typed loosely because the class is a preload
var _mesh: MeshInstance3D
var _mat: ShaderMaterial


func _init() -> void:
	stretch = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vp := SubViewport.new()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Default false makes the SubViewport defer input to the parent viewport, so
	# _unhandled_input inside it never fires and the camera looks dead.
	vp.handle_input_locally = true
	add_child(vp)

	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://addons/terraforge/shaders/terrain_preview.gdshader")

	_mesh = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.subdivide_width = GRID
	plane.subdivide_depth = GRID
	_mesh.mesh = plane
	_mesh.material_override = _mat
	# The displaced mesh leaves the flat plane's bounds; without this it pops out
	# of view the moment the camera looks along the ground.
	_mesh.extra_cull_margin = 16384.0
	vp.add_child(_mesh)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(SUN_ANGLE.x), deg_to_rad(SUN_ANGLE.y), 0.0)
	sun.light_energy = 1.1
	vp.add_child(sun)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.ambient_light_energy = 0.4
	vp.add_child(env)

	cam = FlyCam.new()
	# The 3D view shares a window with the parameter panel, so the camera must not
	# swallow the mouse on load; click inside the viewport to take control, Esc to
	# hand it back.
	cam.capture_on_ready = false
	cam.fov = FOV
	cam.far = FAR
	vp.add_child(cam)


# The editor consumes input before _unhandled_input reaches a plugin's nodes, so
# the camera is driven from here. Only events the camera actually uses are
# marked handled, and only then, or the parameter panel would stop receiving
# clicks while the 3D view is up.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var mine := false
	if event is InputEventMouseButton and event.pressed:
		mine = cam.active or get_global_rect().has_point(event.global_position)
	elif event is InputEventMouseMotion:
		mine = cam.active
	elif event.is_action_pressed("ui_cancel"):
		mine = cam.active
	if not mine:
		return
	cam.handle_input(event)
	get_viewport().set_input_as_handled()


## Push a fresh bake. heights are metres, color is the composite view.
func refresh(heights: PackedFloat32Array, color: Image, world_m: float) -> void:
	var res := int(sqrt(heights.size()))
	var h_img := Image.create_from_data(res, res, false, Image.FORMAT_RF,
		heights.to_byte_array())
	_mat.set_shader_parameter("height_tex", ImageTexture.create_from_image(h_img))
	_mat.set_shader_parameter("color_tex", ImageTexture.create_from_image(color))
	_mat.set_shader_parameter("texel", 1.0 / float(res))
	_mat.set_shader_parameter("world_m", world_m)

	var plane: PlaneMesh = _mesh.mesh
	plane.size = Vector2(world_m, world_m)
	if not cam.has_meta("framed"):
		cam.set_meta("framed", true)
		# Frame the whole map, and scale speed to it: 14 m/s over a 33 km world
		# feels frozen.
		cam.look_at_from_position(Vector3(0.0, world_m * 0.6, world_m * 0.7),
			Vector3.ZERO, Vector3.UP)
		cam.speed = world_m * 0.05
