@tool
extends EditorPlugin
## Docks the generator UI as a main screen tab, beside 2D / 3D / Script.

var _ui: Control


func _enter_tree() -> void:
	_ui = preload("res://addons/terraforge/main.tscn").instantiate()
	_ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	EditorInterface.get_editor_main_screen().add_child(_ui)
	_make_visible(false)


func _exit_tree() -> void:
	if _ui:
		_ui.queue_free()
		_ui = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _ui:
		_ui.visible = visible


func _get_plugin_name() -> String:
	return "TerraForge"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"HeightMapShape3D", &"EditorIcons")
