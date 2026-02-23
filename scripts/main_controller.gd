extends Node3D

@onready var _player := $Player
@onready var _landscape := $Landscape

var _current_map_level: int = 0
var _intro_layer: CanvasLayer
var _level_label: Label
var _message_label: Label
var _play_button: Button

func _ready() -> void:
	_current_map_level = int(_landscape.get("landscape_bcd"))
	_create_intro_ui()
	if _player != null and _player.has_signal("game_won"):
		_player.connect("game_won", Callable(self, "_on_game_won"))
	_show_intro("")

func _create_intro_ui() -> void:
	_intro_layer = CanvasLayer.new()
	_intro_layer.name = "IntroUI"
	_intro_layer.layer = 30
	add_child(_intro_layer)

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro_layer.add_child(root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.05, 0.82)
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 220)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-210, -110)
	root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "SENTINEL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	vb.add_child(title)

	_level_label = Label.new()
	_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_level_label.add_theme_font_size_override("font_size", 22)
	vb.add_child(_level_label)

	_message_label = Label.new()
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.add_theme_font_size_override("font_size", 16)
	vb.add_child(_message_label)

	_play_button = Button.new()
	_play_button.text = "Play"
	_play_button.custom_minimum_size = Vector2(160, 44)
	_play_button.pressed.connect(_on_play_pressed)
	vb.add_child(_play_button)

func _show_intro(message: String) -> void:
	_update_intro_labels(message)
	_intro_layer.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if _player != null and _player.has_method("set_round_active"):
		_player.call("set_round_active", false)

func _update_intro_labels(message: String) -> void:
	if _level_label != null:
		_level_label.text = "Map Level: %d" % _current_map_level
	if _message_label != null:
		_message_label.text = message

func _on_play_pressed() -> void:
	_intro_layer.visible = false
	if _landscape != null and _landscape.has_method("regenerate_level"):
		_landscape.call("regenerate_level", _current_map_level)
	if _player != null and _player.has_method("begin_round"):
		_player.call("begin_round")
	if _player != null and _player.has_method("set_round_active"):
		_player.call("set_round_active", true)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_game_won(ending_energy: int) -> void:
	var bonus := int(ceil(float(max(0, ending_energy)) / 5.0))
	_current_map_level += bonus
	_show_intro("Victory! Level +%d" % bonus)
