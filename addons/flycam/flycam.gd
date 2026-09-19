class_name FlyCam
extends Camera3D
## A free-flying camera: WASD flies where you look, the mouse turns, Shift is
## faster, Esc releases the mouse. No gravity, no ground, no collision.
##
## Drop the addons/flycam folder into any Godot 4 project and add a FlyCam node —
## class_name registers it in the Create Node dialog, so there is no plugin to
## enable. Everything below is exported, because the right speed depends on the
## scale of the world it is flying over.

## Metres per second.
@export var speed := 14.0
## Multiplier while the sprint key is held.
@export var sprint := 3.0
## Radians of turn per pixel of mouse movement.
@export var sensitivity := 0.0025
## How far up and down the camera can look, in degrees. Short of 90 on purpose:
## at exactly 90 the forward vector is vertical and the heading is ambiguous.
@export_range(1.0, 89.9) var pitch_limit := 82.0
## Capture the mouse on start. Turn off for a project that has its own UI focus
## rules, and call grab_mouse() when the camera should take over.
@export var capture_on_ready := true

## Whether the camera is taking input. grab_mouse()/release_mouse() set it.
## Tracked here rather than read back off Input.mouse_mode, because capture is
## not available on every platform — headless, in particular, where a test
## driving this camera would otherwise never move it.
var active := false

@export_group("Keys")
@export var key_forward := KEY_W
@export var key_back := KEY_S
@export var key_left := KEY_A
@export var key_right := KEY_D
@export var key_sprint := KEY_SHIFT


func _ready() -> void:
	if capture_on_ready:
		grab_mouse()


func grab_mouse() -> void:
	active = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func release_mouse() -> void:
	active = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and active:
		var limit := deg_to_rad(pitch_limit)
		rotation.y -= event.relative.x * sensitivity
		rotation.x = clampf(rotation.x - event.relative.y * sensitivity, -limit, limit)
	elif event.is_action_pressed("ui_cancel"):
		release_mouse()
	elif event is InputEventMouseButton and not active:
		grab_mouse()


func _process(delta: float) -> void:
	if not active:
		return
	# Raw keys, not InputMap actions: a camera that is dropped into a project
	# should not need project settings edited before it works.
	var input := Vector3(
		float(Input.is_key_pressed(key_right)) - float(Input.is_key_pressed(key_left)),
		0.0,
		float(Input.is_key_pressed(key_back)) - float(Input.is_key_pressed(key_forward)))
	if input == Vector3.ZERO:
		return
	var rate := speed * (sprint if Input.is_key_pressed(key_sprint) else 1.0)
	# Own basis, so W follows the aim: look down and W descends. global_position,
	# so it still flies straight when parented under a rotated node.
	global_position += (global_basis * input).normalized() * rate * delta
