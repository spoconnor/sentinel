extends CharacterBody3D
signal game_won(ending_energy: int)

@export var mouse_sensitivity: float = 0.0025
@export var gravity: float = 12.0
@export var interact_distance: float = 200.0
@export var place_normal_dot_min: float = 0.98

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D

const GROUP_BUILD_PLACEABLE := "build_placeable"
const GROUP_BUILD_BOULDER := "build_boulder"
const GROUP_TRANSFER_ROBOT := "transfer_robot"

const ENERGY_TREE := 1
const ENERGY_BOULDER := 2
const ENERGY_ROBOT := 3
const ENERGY_SENTRY := 4
const ENERGY_SENTINEL := 4
const ENERGY_MEANIE := 1

const WATCH_LOCK_SECONDS := 5.0
const WATCH_DRAIN_INTERVAL := 5.0
const WATCH_ABSORB_INTERVAL := 5.0
const WATCH_CONTACT_STALE_SECONDS := 0.7
const GRID_SIZE := 31

@export var starting_energy: int = 50

var _pitch: float = 0.0
var _crosshair_layer: CanvasLayer
var _energy_layer: CanvasLayer
var _energy_label: Label
var _warning_label: Label
var _debug_label: Label
var _energy: int = 0
var _debug_mode: bool = false
var _sentinel_isolate_mode: bool = false
var _sentinel_hidden_visuals: Array = []
var _build_root: Node3D
var _active_robot: StaticBody3D
var _hidden_robot_parent: Node
var _hidden_robot_index: int = -1
var _hidden_robot_transform: Transform3D
var _lost: bool = false
var _won: bool = false
var _round_active: bool = true
var _sentinel_start_square: Vector2i = Vector2i.ZERO
var _sentinel_start_square_valid: bool = false

var _watcher_contacts: Dictionary = {}
var _watcher_debug_targets: Dictionary = {}
var _watcher_absorb_ready_at: Dictionary = {}
var _watch_seen_timer: float = 0.0
var _watch_drain_timer: float = 0.0
var _meanie_cooldowns: Dictionary = {}
var _watcher_script := load("res://scripts/sentinel.gd")
const ROBOT_MODEL_PATH := "res://models/robot.glb"
const TREE_MODEL_PATH := "res://models/tree.glb"
const BOULDER_MODEL_PATH := "res://models/boulder.glb"
const MEANIE_MODEL_PATH := "res://models/meanie.glb"

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_energy = max(0, starting_energy)
	call_deferred("_ensure_build_root")
	call_deferred("_create_crosshair")
	call_deferred("_create_energy_ui")
	call_deferred("_ensure_start_robot_host")
	call_deferred("_cache_sentinel_start_square")

func _process(delta: float) -> void:
	if not _round_active:
		return
	if not _sentinel_start_square_valid:
		_cache_sentinel_start_square()
	_update_watcher_pressure(delta)

func _unhandled_input(event: InputEvent) -> void:
	if not _round_active:
		return
	if _lost or _won:
		return
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clamp(_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		camera_pivot.rotation.x = _pitch

	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_D:
		_set_debug_mode(not _debug_mode)
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		_toggle_sentinel_isolate_mode()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_T:
				_try_place_tree()
			KEY_B:
				_try_place_boulder()
			KEY_R:
				_try_place_robot()
			KEY_Q:
				_try_transfer_to_robot()
			KEY_A:
				_try_remove_object()
			KEY_H:
				_try_hyperspace()

func _physics_process(delta: float) -> void:
	if not _round_active:
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif velocity.y < 0.0:
		velocity.y = 0.0

	velocity.x = 0.0
	velocity.z = 0.0
	move_and_slide()
	_update_robot_overlap_collisions()

func _ensure_build_root() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	var existing := root.get_node_or_null("BuildObjects") as Node3D
	if existing != null:
		_build_root = existing
		return
	_build_root = Node3D.new()
	_build_root.name = "BuildObjects"
	root.add_child(_build_root)

func _create_crosshair() -> void:
	var root := get_tree().current_scene
	if root == null:
		return

	_crosshair_layer = CanvasLayer.new()
	_crosshair_layer.name = "Crosshair"
	_crosshair_layer.layer = 10
	_crosshair_layer.visible = true
	root.call_deferred("add_child", _crosshair_layer)

	var ui := Control.new()
	ui.name = "CrosshairUI"
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair_layer.add_child(ui)

	var h := ColorRect.new()
	h.color = Color(1.0, 1.0, 1.0, 0.95)
	h.size = Vector2(18.0, 2.0)
	h.position = Vector2(-9.0, -1.0)
	h.set_anchors_preset(Control.PRESET_CENTER)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(h)

	var v := ColorRect.new()
	v.color = Color(1.0, 1.0, 1.0, 0.95)
	v.size = Vector2(2.0, 18.0)
	v.position = Vector2(-1.0, -9.0)
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(v)

func _create_energy_ui() -> void:
	var root := get_tree().current_scene
	if root == null:
		return

	_energy_layer = CanvasLayer.new()
	_energy_layer.name = "EnergyHUD"
	_energy_layer.layer = 11
	root.call_deferred("add_child", _energy_layer)

	var hud := Control.new()
	hud.name = "EnergyUI"
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_energy_layer.add_child(hud)

	_energy_label = Label.new()
	_energy_label.name = "EnergyLabel"
	_energy_label.text = ""
	_energy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_energy_label.add_theme_font_size_override("font_size", 22)
	_energy_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_energy_label.position = Vector2(0, 8)
	_energy_label.size = Vector2(0, 32)
	_energy_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_energy_label)

	_warning_label = Label.new()
	_warning_label.name = "WarningLabel"
	_warning_label.text = ""
	_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warning_label.add_theme_font_size_override("font_size", 18)
	_warning_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_warning_label.position = Vector2(0, 38)
	_warning_label.size = Vector2(0, 30)
	_warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_warning_label)

	_debug_label = Label.new()
	_debug_label.name = "DebugLabel"
	_debug_label.text = ""
	_debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_debug_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_debug_label.add_theme_font_size_override("font_size", 14)
	_debug_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_debug_label.position = Vector2(0, 68)
	_debug_label.size = Vector2(0, 150)
	_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(_debug_label)

	_update_energy_ui()
	_update_warning_ui(false, false)
	_update_debug_ui()

func _update_energy_ui() -> void:
	if _energy_label == null:
		return
	_energy_label.text = "Energy: %d" % _energy

func _update_warning_ui(sees_player: bool, sees_square: bool) -> void:
	if _warning_label == null:
		return
	if _won:
		_warning_label.text = "YOU WIN"
		_warning_label.modulate = Color(0.4, 1.0, 0.45)
		return
	if _lost:
		_warning_label.text = "GAME OVER"
		_warning_label.modulate = Color(1.0, 0.2, 0.2)
		return
	if not sees_player:
		_warning_label.text = ""
		return

	if sees_square:
		var fill := int(clamp((_watch_seen_timer / WATCH_LOCK_SECONDS) * 10.0, 0.0, 10.0))
		var bar := ""
		for i in range(10):
			bar += "#" if i < fill else "."
		_warning_label.text = "ALERT [%s]" % bar
		_warning_label.modulate = Color(1.0, 0.85, 0.25)
	else:
		_warning_label.text = "ALERT [..::..::..]"
		_warning_label.modulate = Color(1.0, 0.7, 0.25)

func _set_debug_mode(enabled: bool) -> void:
	_debug_mode = enabled
	_update_debug_ui()

func is_debug_mode_enabled() -> bool:
	return _debug_mode

func _update_debug_ui() -> void:
	if _debug_label == null:
		return
	if not _debug_mode:
		_debug_label.text = ""
		return

	var lines: Array[String] = []
	lines.append("DEBUG MODE: ON")
	lines.append("SENTINEL ISOLATE: %s" % ("ON" if _sentinel_isolate_mode else "OFF"))
	for watcher_id in _watcher_contacts.keys():
		var entry: Dictionary = _watcher_contacts[watcher_id]
		var kind := String(entry.get("kind", "watcher"))
		var sees_player := bool(entry.get("sees_player", false))
		var sees_square := bool(entry.get("sees_square", false))
		var target_kind := String(_watcher_debug_targets.get(watcher_id, "none"))
		var los_debug := String(entry.get("los", ""))
		lines.append("%s#%s P:%s S:%s T:%s %s" % [kind, str(watcher_id), "Y" if sees_player else "N", "Y" if sees_square else "N", target_kind, los_debug])

	if lines.size() == 1:
		lines.append("No watcher contact")
	_debug_label.text = "\n".join(lines)

func _toggle_sentinel_isolate_mode() -> void:
	_sentinel_isolate_mode = not _sentinel_isolate_mode
	if _sentinel_isolate_mode:
		_enable_sentinel_isolate_mode()
	else:
		_disable_sentinel_isolate_mode()
	_update_debug_ui()

func _enable_sentinel_isolate_mode() -> void:
	_sentinel_hidden_visuals.clear()
	var root := get_tree().current_scene
	if root == null:
		_sentinel_isolate_mode = false
		return
	var sentinels := _collect_sentinel_nodes(root)
	if sentinels.is_empty():
		_sentinel_isolate_mode = false
		return
	_hide_non_sentinel_visuals(root, sentinels)

func _disable_sentinel_isolate_mode() -> void:
	for entry in _sentinel_hidden_visuals:
		var visual := entry.get("node") as VisualInstance3D
		if visual == null or not is_instance_valid(visual):
			continue
		visual.visible = bool(entry.get("visible", true))
	_sentinel_hidden_visuals.clear()

func _collect_sentinel_nodes(node: Node) -> Array[Node3D]:
	var sentinels: Array[Node3D] = []
	_collect_sentinel_nodes_recursive(node, sentinels)
	return sentinels

func _collect_sentinel_nodes_recursive(node: Node, sentinels: Array[Node3D]) -> void:
	var node3d := node as Node3D
	if node3d != null and String(node3d.get_meta("object_kind", "")) == "sentinel":
		sentinels.append(node3d)
	for child in node.get_children():
		_collect_sentinel_nodes_recursive(child, sentinels)

func _hide_non_sentinel_visuals(node: Node, sentinels: Array[Node3D]) -> void:
	var visual := node as VisualInstance3D
	if visual != null and visual != camera and not _is_part_of_any_sentinel(visual, sentinels):
		_sentinel_hidden_visuals.append({"node": visual, "visible": visual.visible})
		visual.visible = false
	for child in node.get_children():
		_hide_non_sentinel_visuals(child, sentinels)

func _is_part_of_any_sentinel(node: Node, sentinels: Array[Node3D]) -> bool:
	var current := node
	while current != null:
		for sentinel in sentinels:
			if current == sentinel:
				return true
		current = current.get_parent()
	return false

func _energy_cost_for_kind(kind: String) -> int:
	match kind:
		"tree":
			return ENERGY_TREE
		"boulder":
			return ENERGY_BOULDER
		"robot":
			return ENERGY_ROBOT
		"sentry":
			return ENERGY_SENTRY
		"sentinel":
			return ENERGY_SENTINEL
		"meanie":
			return ENERGY_MEANIE
	return 0

func _energy_cost_for_node(node: Node3D) -> int:
	if node == null:
		return 0
	var kind := String(node.get_meta("object_kind", ""))
	return _energy_cost_for_kind(kind)

func _try_spend_energy(amount: int) -> bool:
	if amount <= 0:
		return true
	if _energy - amount < 0:
		return false
	_energy -= amount
	_update_energy_ui()
	return true

func _gain_energy(amount: int) -> void:
	if amount <= 0:
		return
	_energy += amount
	_update_energy_ui()

func _set_lost() -> void:
	if _lost or _won:
		return
	_lost = true
	_update_warning_ui(false, false)

func _set_won() -> void:
	if _won or _lost:
		return
	_won = true
	_update_warning_ui(false, false)
	game_won.emit(_energy)

func set_round_active(active: bool) -> void:
	_round_active = active
	if not active:
		velocity = Vector3.ZERO

func begin_round() -> void:
	_lost = false
	_won = false
	_round_active = true
	_energy = max(0, starting_energy)
	_update_energy_ui()
	_update_warning_ui(false, false)
	_watcher_contacts.clear()
	_watcher_debug_targets.clear()
	_watcher_absorb_ready_at.clear()
	_watch_seen_timer = 0.0
	_watch_drain_timer = 0.0
	_meanie_cooldowns.clear()
	_sentinel_start_square_valid = false
	_sentinel_start_square = Vector2i.ZERO
	_restore_robot_from_transfer(_active_robot)
	_active_robot = null
	_hidden_robot_parent = null
	_hidden_robot_index = -1
	_hidden_robot_transform = Transform3D.IDENTITY
	call_deferred("_ensure_start_robot_host")
	call_deferred("_cache_sentinel_start_square")

func get_energy_value() -> int:
	return _energy

func _get_crosshair_hit() -> Dictionary:
	if camera == null:
		return {}
	var from := camera.global_position
	var to := from + (-camera.global_transform.basis.z * interact_distance)
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.exclude = [self]
	p.collide_with_areas = false
	p.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_ray(p)

func _is_horizontal_surface(hit: Dictionary) -> bool:
	if hit.is_empty():
		return false
	var n: Vector3 = hit.get("normal", Vector3.ZERO)
	return n.dot(Vector3.UP) >= place_normal_dot_min

func _get_tile_size() -> float:
	var landscape := get_node_or_null("../Landscape")
	if landscape != null and landscape.has_method("get"):
		var v: Variant = landscape.get("tile_size")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return float(v)
	return 1.6

func _get_terrain_origin() -> Vector3:
	var terrain := get_node_or_null("../Landscape/Terrain") as Node3D
	if terrain != null:
		return terrain.global_position
	return Vector3.ZERO

func _world_to_square(pos: Vector3) -> Vector2i:
	var tile := _get_tile_size()
	var origin := _get_terrain_origin()
	var gx := int(floor((pos.x - origin.x) / tile))
	var gz := int(floor((pos.z - origin.z) / tile))
	return Vector2i(gx, gz)

func _player_base_position() -> Vector3:
	return global_position - Vector3(0, 1.65, 0)

func _player_occupied_square() -> Vector2i:
	if _active_robot != null and is_instance_valid(_active_robot):
		if _active_robot.has_meta("grid_x") and _active_robot.has_meta("grid_z"):
			return Vector2i(int(_active_robot.get_meta("grid_x", 0)), int(_active_robot.get_meta("grid_z", 0)))
		return _world_to_square(_active_robot_proxy_position())
	return _world_to_square(_player_base_position())

func _node_square(node: Node3D) -> Vector2i:
	if node != null and node.has_meta("grid_x") and node.has_meta("grid_z"):
		return Vector2i(int(node.get_meta("grid_x", 0)), int(node.get_meta("grid_z", 0)))
	if node == null:
		return Vector2i(0, 0)
	return _world_to_square(node.global_position)

func _set_robot_collision_enabled(robot: StaticBody3D, enabled: bool) -> void:
	if robot.get_meta("collision_disabled", false):
		enabled = false
	for child in robot.get_children():
		var col := child as CollisionShape3D
		if col != null:
			col.disabled = not enabled

func _update_robot_overlap_collisions() -> void:
	if _build_root == null:
		return
	var player_square := _world_to_square(_player_base_position())
	for child in _build_root.get_children():
		var robot := child as StaticBody3D
		if robot == null or not robot.is_in_group(GROUP_TRANSFER_ROBOT):
			continue
		var robot_square := _world_to_square(robot.global_position)
		var same_square := robot_square == player_square
		_set_robot_collision_enabled(robot, not same_square)

func _square_center_world(square: Vector2i, y: float) -> Vector3:
	var tile := _get_tile_size()
	var origin := _get_terrain_origin()
	return Vector3(origin.x + (float(square.x) + 0.5) * tile, y, origin.z + (float(square.y) + 0.5) * tile)

func _find_boulder_root(node: Node) -> StaticBody3D:
	var current := node
	while current != null:
		if current is StaticBody3D and current.is_in_group(GROUP_BUILD_BOULDER):
			return current as StaticBody3D
		current = current.get_parent()
	return null

func _find_pedestal_root(node: Node) -> StaticBody3D:
	var current := node
	while current != null:
		if current is StaticBody3D and String((current as Node3D).get_meta("object_kind", "")) == "pedestal":
			return current as StaticBody3D
		current = current.get_parent()
	return null

func _find_placeable_root(node: Node) -> StaticBody3D:
	var current := node
	while current != null:
		if current is StaticBody3D and current.is_in_group(GROUP_BUILD_PLACEABLE):
			return current as StaticBody3D
		current = current.get_parent()
	return null

func _is_pedestal_top_hit(pedestal: Node3D, hit: Dictionary) -> bool:
	if pedestal == null or hit.is_empty():
		return false
	var hit_pos := hit.get("position", Vector3.ZERO) as Vector3
	# Pedestal top is around local y=0.8; accept only hits near that top cap.
	return (hit_pos.y - pedestal.global_position.y) >= 0.68

func _can_see_pedestal_top_for_square(square: Vector2i) -> bool:
	if camera == null:
		return false
	var target := _square_center_world(square, _square_ground_y(square) + 0.8)
	var p := PhysicsRayQueryParameters3D.create(camera.global_position, target)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	p.exclude = [self]
	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	if hit.is_empty():
		return false
	var collider := hit.get("collider") as Node
	if collider == null:
		return false
	var pedestal := _find_pedestal_root(collider)
	if pedestal != null and _node_square(pedestal) == square:
		return true
	var placeable := _find_placeable_root(collider)
	if placeable != null and String(placeable.get_meta("object_kind", "")) == "sentinel" and _node_square(placeable) == square:
		return true
	return false

func _get_base_object_at(square: Vector2i) -> Node3D:
	if _build_root == null:
		return null
	var fallback: Node3D
	var fallback_level := 999
	for c in _build_root.get_children():
		var n := c as Node3D
		if n == null or not n.is_in_group(GROUP_BUILD_PLACEABLE):
			continue
		var gx := int(n.get_meta("grid_x", 999999))
		var gz := int(n.get_meta("grid_z", 999999))
		if gx != square.x or gz != square.y:
			continue
		var level := int(n.get_meta("stack_level", 0))
		if level == 0:
			return n
		if level < fallback_level:
			fallback_level = level
			fallback = n
	if fallback != null:
		return fallback

	# Fallback for objects whose grid metadata is stale: infer occupancy by world-space square center.
	var tile := _get_tile_size()
	var center := _square_center_world(square, 0.0)
	var prox_best: Node3D
	var prox_level := 999
	var prox_dist := INF
	for c in _build_root.get_children():
		var n := c as Node3D
		if n == null or not n.is_in_group(GROUP_BUILD_PLACEABLE):
			continue
		var level := int(n.get_meta("stack_level", 0))
		var d := Vector2(n.global_position.x - center.x, n.global_position.z - center.z).length()
		if d > tile * 0.45:
			continue
		if level < prox_level or (level == prox_level and d < prox_dist):
			prox_level = level
			prox_dist = d
			prox_best = n
	return prox_best

func _get_stacked_on_boulder(boulder: Node3D) -> Node3D:
	if _build_root == null or boulder == null:
		return null
	var support_id := int(boulder.get_instance_id())
	for c in _build_root.get_children():
		var n := c as Node3D
		if n == null or not n.is_in_group(GROUP_BUILD_PLACEABLE):
			continue
		if int(n.get_meta("stack_level", 0)) != 1:
			continue
		if int(n.get_meta("support_boulder_id", -1)) == support_id:
			return n
	return null

func _get_top_object_at_square(square: Vector2i) -> Node3D:
	var base := _get_base_object_at(square)
	if base == null:
		return _get_highest_object_at_square(square)
	if String(base.get_meta("object_kind", "")) != "boulder":
		return base

	var current := base
	while current != null:
		var stacked := _get_stacked_on_boulder(current)
		if stacked == null:
			return current
		current = stacked
		if String(current.get_meta("object_kind", "")) != "boulder":
			return current
	return base

func _get_highest_object_at_square(square: Vector2i) -> Node3D:
	if _build_root == null:
		return null
	var best: Node3D
	var best_level := -999
	for c in _build_root.get_children():
		var n := c as Node3D
		if n == null or not n.is_in_group(GROUP_BUILD_PLACEABLE):
			continue
		var gx := int(n.get_meta("grid_x", 999999))
		var gz := int(n.get_meta("grid_z", 999999))
		if gx != square.x or gz != square.y:
			continue
		var level := int(n.get_meta("stack_level", 0))
		if level > best_level:
			best_level = level
			best = n
	return best

func _get_top_boulder_at_square(square: Vector2i) -> Node3D:
	var base := _get_base_object_at(square)
	if base == null or String(base.get_meta("object_kind", "")) != "boulder":
		return null

	var current := base
	while current != null:
		var stacked := _get_stacked_on_boulder(current)
		if stacked == null:
			return current
		if String(stacked.get_meta("object_kind", "")) != "boulder":
			return current
		current = stacked
	return base

func _get_robot_at_square(square: Vector2i) -> StaticBody3D:
	if _build_root == null:
		return null
	for c in _build_root.get_children():
		var robot := c as StaticBody3D
		if robot == null or not robot.is_in_group(GROUP_TRANSFER_ROBOT):
			continue
		if int(robot.get_meta("grid_x", 999999)) == square.x and int(robot.get_meta("grid_z", 999999)) == square.y:
			return robot
	return null

func _cache_sentinel_start_square() -> void:
	if _sentinel_start_square_valid or _build_root == null:
		return

	if _build_root.has_meta("sentinel_start_square_x") and _build_root.has_meta("sentinel_start_square_z"):
		_sentinel_start_square = Vector2i(int(_build_root.get_meta("sentinel_start_square_x", 0)), int(_build_root.get_meta("sentinel_start_square_z", 0)))
		_sentinel_start_square_valid = true
		return

	for c in _build_root.get_children():
		var n := c as Node3D
		if n == null:
			continue
		if String(n.get_meta("object_kind", "")) != "sentinel":
			continue
		if not n.has_meta("grid_x") or not n.has_meta("grid_z"):
			continue
		_sentinel_start_square = Vector2i(int(n.get_meta("grid_x", 0)), int(n.get_meta("grid_z", 0)))
		_sentinel_start_square_valid = true
		return

func _is_sentinel_square(square: Vector2i) -> bool:
	if not _sentinel_start_square_valid:
		_cache_sentinel_start_square()
	if not _sentinel_start_square_valid:
		return false
	return square == _sentinel_start_square

func _tag_build_object(node: Node3D, kind: String, square: Vector2i, level: int, support_boulder: Node3D) -> void:
	node.add_to_group(GROUP_BUILD_PLACEABLE)
	node.set_meta("object_kind", kind)
	node.set_meta("grid_x", square.x)
	node.set_meta("grid_z", square.y)
	node.set_meta("stack_level", level)
	node.set_meta("support_boulder_id", -1 if support_boulder == null else int(support_boulder.get_instance_id()))

func _attach_model_contents(parent: Node3D, model_path: String) -> void:
	if parent == null or model_path == "":
		return
	var packed := ResourceLoader.load(model_path) as PackedScene
	if packed == null:
		return
	var inst := packed.instantiate() as Node3D
	if inst == null:
		return
	parent.add_child(inst)
	for child in inst.get_children():
		inst.remove_child(child)
		if child is Node:
			(child as Node).owner = null
		parent.add_child(child)
	inst.queue_free()

func _create_tree_node(pos: Vector3, square: Vector2i, level: int, support: Node3D) -> StaticBody3D:
	var tree := StaticBody3D.new()
	_tag_build_object(tree, "tree", square, level, support)
	tree.position = pos

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.38
	shape.height = 2.7
	col.shape = shape
	col.position.y = 1.55
	col.disabled = true
	tree.add_child(col)

	_attach_model_contents(tree, TREE_MODEL_PATH)

	return tree

func _create_boulder_node(pos: Vector3, square: Vector2i, level: int, support: Node3D) -> StaticBody3D:
	var boulder := StaticBody3D.new()
	boulder.add_to_group(GROUP_BUILD_BOULDER)
	_tag_build_object(boulder, "boulder", square, level, support)
	boulder.position = pos

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.02, 1.0, 1.02)
	shape.shape = box
	boulder.add_child(shape)

	_attach_model_contents(boulder, BOULDER_MODEL_PATH)

	return boulder

func _create_robot_node(pos: Vector3, yaw: float, square: Vector2i, level: int, support: Node3D) -> StaticBody3D:
	var robot := StaticBody3D.new()
	robot.add_to_group(GROUP_TRANSFER_ROBOT)
	_tag_build_object(robot, "robot", square, level, support)
	robot.set_meta("collision_disabled", true)
	robot.position = pos
	robot.rotation.y = yaw

	var body_col := CollisionShape3D.new()
	var body_shape := CapsuleShape3D.new()
	body_shape.radius = 0.32
	body_shape.height = 1.0
	body_col.shape = body_shape
	body_col.position.y = 0.85
	body_col.disabled = true
	robot.add_child(body_col)

	_attach_model_contents(robot, ROBOT_MODEL_PATH)

	return robot

func _ensure_start_robot_host() -> void:
	if _build_root == null:
		_ensure_build_root()
		call_deferred("_ensure_start_robot_host")
		return

	# Wait until generated objects exist before creating fallback robot host.
	if _build_root.get_child_count() == 0:
		call_deferred("_ensure_start_robot_host")
		return

	if _active_robot != null and is_instance_valid(_active_robot):
		return

	var base_pos := _player_base_position()
	var square := _world_to_square(base_pos)
	var existing := _get_base_object_at(square)
	if existing != null and existing is StaticBody3D and existing.is_in_group(GROUP_TRANSFER_ROBOT):
		_active_robot = existing as StaticBody3D
		_hide_robot_for_transfer(_active_robot)
		return
	if existing != null:
		return

	var center := _square_center_world(square, base_pos.y)
	var robot := _create_robot_node(center, rotation.y, square, 0, null)
	_build_root.add_child(robot)
	_active_robot = robot
	_hide_robot_for_transfer(_active_robot)

func _get_place_target(hit: Dictionary) -> Dictionary:
	if hit.is_empty():
		return {}

	var collider := hit.get("collider") as Node
	var boulder := _find_boulder_root(collider)
	if boulder != null:
		var b_square := _world_to_square(boulder.global_position)
		var top_boulder := _get_top_boulder_at_square(b_square)
		if top_boulder == null:
			return {}
		return {
			"square": b_square,
			"pos": top_boulder.global_position + Vector3(0, 0.5, 0),
			"level": 1,
			"support": top_boulder,
		}

	var pedestal := _find_pedestal_root(collider)
	if pedestal != null and _is_pedestal_top_hit(pedestal, hit):
		var p_square := _node_square(pedestal)
		return {
			"square": p_square,
			"pos": pedestal.global_position + Vector3(0, 0.8, 0),
			"level": 0,
			"support": null,
		}

	if not _is_horizontal_surface(hit):
		return {}

	var square := _world_to_square(hit["position"])
	var top_boulder_on_square := _get_top_boulder_at_square(square)
	if top_boulder_on_square != null:
		return {
			"square": square,
			"pos": top_boulder_on_square.global_position + Vector3(0, 0.5, 0),
			"level": 1,
			"support": top_boulder_on_square,
		}

	var pos := _square_center_world(square, (hit["position"] as Vector3).y)
	return {
		"square": square,
		"pos": pos,
		"level": 0,
		"support": null,
	}

func _can_place(target: Dictionary) -> bool:
	if target.is_empty():
		return false
	var square: Vector2i = target["square"]
	if square == _player_occupied_square():
		return false
	var level := int(target["level"])
	var support := target["support"] as Node3D
	var base := _get_base_object_at(square)

	if level == 0:
		return base == null

	if support == null or not support.is_in_group(GROUP_BUILD_BOULDER):
		return false
	return _get_stacked_on_boulder(support) == null

func _try_place_tree() -> void:
	if _build_root == null:
		_ensure_build_root()
	var hit := _get_crosshair_hit()
	var target := _get_place_target(hit)
	if not _can_place(target):
		return
	if not _try_spend_energy(ENERGY_TREE):
		return

	var tree := _create_tree_node(target["pos"], target["square"], int(target["level"]), target["support"])
	_build_root.add_child(tree)

func _try_place_boulder() -> void:
	if _build_root == null:
		_ensure_build_root()
	var hit := _get_crosshair_hit()
	var target := _get_place_target(hit)
	if not _can_place(target):
		return
	if not _try_spend_energy(ENERGY_BOULDER):
		return

	var pos := (target["pos"] as Vector3) + Vector3(0, 0.5, 0)
	var boulder := _create_boulder_node(pos, target["square"], int(target["level"]), target["support"])
	_build_root.add_child(boulder)

func _try_place_robot() -> void:
	if _build_root == null:
		_ensure_build_root()
	var hit := _get_crosshair_hit()
	var target := _get_place_target(hit)
	if not _can_place(target):
		return
	if not _try_spend_energy(ENERGY_ROBOT):
		return

	var robot := _create_robot_node(target["pos"], rotation.y, target["square"], int(target["level"]), target["support"])
	_build_root.add_child(robot)

func _try_remove_object() -> void:
	var hit := _get_crosshair_hit()
	if hit.is_empty():
		return

	var collider := hit.get("collider") as Node
	if collider == null:
		return

	var target_square := Vector2i(999999, 999999)
	var focused_placeable := _find_placeable_root(collider)
	var focused_kind := ""
	if focused_placeable != null:
		focused_kind = String(focused_placeable.get_meta("object_kind", ""))
	var blocked_direct_kind := focused_kind == "tree" or focused_kind == "robot" or focused_kind == "meanie"
	# Primary path: targeting terrain/ground resolves to that square, even on slopes.
	if _is_removal_square_surface(collider):
		target_square = _world_to_square(hit["position"])

	# Secondary path: horizontal top-surface targeting.
	if target_square.x == 999999 and _is_horizontal_surface(hit):
		if blocked_direct_kind and focused_placeable != null:
			# Treat this as targeting the square the object stands on.
			target_square = _node_square(focused_placeable)
		else:
			target_square = _world_to_square(hit["position"])

	if target_square.x == 999999:
		var boulder := _find_boulder_root(collider)
		if boulder != null:
			target_square = _node_square(boulder)
		else:
			var pedestal := _find_pedestal_root(collider)
			if pedestal != null and _is_pedestal_top_hit(pedestal, hit):
				target_square = _node_square(pedestal)
			else:
				var placeable := _find_placeable_root(collider)
				if placeable != null:
					var kind := String(placeable.get_meta("object_kind", ""))
					var placeable_square := _node_square(placeable)
					if kind == "sentinel":
						if _can_see_pedestal_top_for_square(placeable_square):
							target_square = placeable_square
					elif kind == "boulder":
						target_square = placeable_square

	if target_square.x == 999999:
		return
	if target_square == _player_occupied_square():
		return

	var hit_position := hit.get("position", Vector3.ZERO) as Vector3
	var top := _get_top_object_at_square(target_square)
	var tile := _get_tile_size()
	if top == null:
		var best_dist := INF
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dz == 0:
					continue
				var neighbor := Vector2i(target_square.x + dx, target_square.y + dz)
				var candidate := _get_top_object_at_square(neighbor)
				if candidate == null:
					continue
				var d := Vector2(hit_position.x - candidate.global_position.x, hit_position.z - candidate.global_position.z).length()
				if d <= tile * 0.75 and d < best_dist:
					best_dist = d
					top = candidate
	if top == null and _build_root != null:
		var world_best_dist := INF
		for c in _build_root.get_children():
			var candidate := c as Node3D
			if candidate == null or not candidate.is_in_group(GROUP_BUILD_PLACEABLE):
				continue
			var d := Vector2(hit_position.x - candidate.global_position.x, hit_position.z - candidate.global_position.z).length()
			if d <= tile * 0.55 and d < world_best_dist:
				world_best_dist = d
				top = candidate
	if top == null:
		return
	if _active_robot != null and top == _active_robot:
		return

	_gain_energy(_energy_cost_for_node(top))
	top.queue_free()

func _is_removal_square_surface(collider: Node) -> bool:
	if collider == null:
		return false
	var terrain_body := get_node_or_null("../Landscape/TerrainBody")
	if terrain_body != null and collider == terrain_body:
		return true
	var ground_body := get_node_or_null("../GroundBody")
	if ground_body != null and collider == ground_body:
		return true
	return false

func _try_transfer_to_robot() -> void:
	var hit := _get_crosshair_hit()
	if hit.is_empty():
		return
	var collider := hit.get("collider") as Node
	if collider == null:
		return

	var target_robot := _find_robot_root(collider)
	if target_robot == null:
		var target_square := Vector2i(999999, 999999)
		var boulder := _find_boulder_root(collider)
		if boulder != null:
			target_square = _node_square(boulder)
		else:
			var pedestal := _find_pedestal_root(collider)
			if pedestal != null and _is_pedestal_top_hit(pedestal, hit):
				target_square = _node_square(pedestal)
			elif _is_horizontal_surface(hit):
				target_square = _world_to_square(hit["position"])

		if target_square.x != 999999:
			target_robot = _get_robot_at_square(target_square)

	if target_robot == null:
		return
	_perform_transfer_to_robot(target_robot)

func _try_hyperspace() -> void:
	if _build_root == null:
		_ensure_build_root()
	var current_square := _player_occupied_square()
	if _is_sentinel_square(current_square):
		_set_won()
		return
	if _energy < ENERGY_ROBOT:
		return

	var max_y := _square_ground_y(current_square)
	for _i in range(256):
		var square := Vector2i(randi_range(0, GRID_SIZE - 1), randi_range(0, GRID_SIZE - 1))
		if square == current_square:
			continue
		if _get_base_object_at(square) != null:
			continue

		var hit := _square_ground_hit(square)
		if hit.is_empty():
			continue
		var normal := hit.get("normal", Vector3.UP) as Vector3
		if normal.dot(Vector3.UP) < place_normal_dot_min:
			continue
		var y := float((hit["position"] as Vector3).y)
		if y > max_y + 0.001:
			continue

		if not _try_spend_energy(ENERGY_ROBOT):
			return
		var pos := _square_center_world(square, y)
		var robot := _create_robot_node(pos, rotation.y, square, 0, null)
		_build_root.add_child(robot)
		_perform_transfer_to_robot(robot)
		return

func _perform_transfer_to_robot(target_robot: StaticBody3D) -> void:
	if target_robot == null or not is_instance_valid(target_robot):
		return
	if _active_robot != null and target_robot == _active_robot:
		return

	_restore_robot_from_transfer(_active_robot)
	var from_pos := global_position
	global_position = target_robot.global_position + Vector3(0, 1.65, 0)
	_active_robot = target_robot
	_hide_robot_for_transfer(_active_robot)

	var to_from := from_pos - global_position
	to_from.y = 0.0
	if to_from.length_squared() > 0.0001:
		look_at(global_position + to_from.normalized(), Vector3.UP)
		_pitch = 0.0
		camera_pivot.rotation.x = _pitch

func _hide_robot_for_transfer(robot: StaticBody3D) -> void:
	if robot == null or not is_instance_valid(robot):
		return
	if not robot.is_inside_tree():
		return

	_hidden_robot_parent = robot.get_parent()
	_hidden_robot_index = robot.get_index()
	_hidden_robot_transform = robot.global_transform
	_hidden_robot_parent.remove_child(robot)

func _restore_robot_from_transfer(robot: StaticBody3D) -> void:
	if robot == null or not is_instance_valid(robot):
		return
	if robot.is_inside_tree():
		return

	var parent := _hidden_robot_parent
	if parent == null or not is_instance_valid(parent):
		parent = _build_root
	if parent == null:
		return

	parent.add_child(robot)
	var max_index := parent.get_child_count() - 1
	if _hidden_robot_index >= 0 and _hidden_robot_index <= max_index:
		parent.move_child(robot, _hidden_robot_index)
	robot.global_transform = _hidden_robot_transform

func _find_robot_root(node: Node) -> StaticBody3D:
	var current := node
	while current != null:
		if current is StaticBody3D and current.is_in_group(GROUP_TRANSFER_ROBOT):
			return current as StaticBody3D
		current = current.get_parent()
	return null

func _active_robot_proxy_position() -> Vector3:
	if _active_robot == null or not is_instance_valid(_active_robot):
		return _player_base_position()
	if _active_robot.is_inside_tree():
		return _active_robot.global_position
	return _hidden_robot_transform.origin

func _active_robot_support_boulder() -> Node3D:
	if _active_robot == null or not is_instance_valid(_active_robot):
		return null
	var support_id := int(_active_robot.get_meta("support_boulder_id", -1))
	return _find_node_by_instance_id(support_id)

func _watcher_ground_point_for_square(square: Vector2i) -> Vector3:
	var y := _square_ground_y(square)
	return _square_center_world(square, y)

func watcher_update_contact(watcher_id: int, sees_player: bool, sees_square: bool, watcher_kind: String = "watcher", los_debug: String = "") -> void:
	var now := Time.get_ticks_msec() * 0.001
	_watcher_contacts[watcher_id] = {
		"time": now,
		"sees_player": sees_player,
		"sees_square": sees_square,
		"kind": watcher_kind,
		"los": los_debug,
	}
	_update_debug_ui()

func watcher_attempt_action(
	watcher: Node3D,
	forward: Vector3,
	head_pos: Vector3,
	scan_range: float,
	cone_threshold: float,
	watcher_kind: String,
	sees_player: bool,
	sees_square: bool
) -> void:
	if _lost or _build_root == null or watcher == null:
		return

	var watcher_id := watcher.get_instance_id()
	var now := Time.get_ticks_msec() * 0.001
	_watcher_debug_targets[watcher_id] = "none"

	if watcher_kind != "meanie" and sees_player and not sees_square:
		_watcher_debug_targets[watcher_id] = "meanie-seek"
		_try_spawn_meanie_near_player(watcher, forward, head_pos, scan_range, cone_threshold)
		_update_debug_ui()
		return

	var target := _find_absorb_target(watcher, forward, head_pos, scan_range, cone_threshold)
	if target != null:
		var has_cooldown := _watcher_absorb_ready_at.has(watcher_id)
		var ready_at := float(_watcher_absorb_ready_at.get(watcher_id, 0.0))
		if not has_cooldown:
			_watcher_absorb_ready_at[watcher_id] = now + WATCH_ABSORB_INTERVAL
			_watcher_debug_targets[watcher_id] = "cooldown"
			_update_debug_ui()
			return
		if now < ready_at:
			_watcher_debug_targets[watcher_id] = "cooldown"
			_update_debug_ui()
			return
		_watcher_debug_targets[watcher_id] = String(target.get_meta("object_kind", "target"))
		_degrade_object_one_energy(target)
		_spawn_random_tree()
		_watcher_absorb_ready_at[watcher_id] = now + WATCH_ABSORB_INTERVAL
		_update_debug_ui()
		return

	_update_debug_ui()

func watcher_can_absorb(watcher: Node3D, forward: Vector3, head_pos: Vector3, scan_range: float, cone_threshold: float) -> bool:
	if _lost or _build_root == null or watcher == null:
		return false
	return _find_absorb_target(watcher, forward, head_pos, scan_range, cone_threshold) != null

func watcher_can_see_player_proxy(watcher: Node3D, head_pos: Vector3, forward: Vector3, scan_range: float, cone_threshold: float) -> bool:
	if watcher == null:
		return false
	if _active_robot == null or not is_instance_valid(_active_robot):
		return false

	var robot_pos := _active_robot_proxy_position()
	var target_pos := robot_pos + Vector3(0, 0.85, 0)
	return _watcher_can_see_unobstructed_point(head_pos, forward, target_pos, scan_range, cone_threshold, watcher)
func watcher_can_see_player_proxy_ground(watcher: Node3D, head_pos: Vector3, forward: Vector3, scan_range: float, cone_threshold: float) -> bool:
	if watcher == null:
		return false
	if _active_robot == null or not is_instance_valid(_active_robot):
		return false

	var support := _active_robot_support_boulder()
	if support != null and is_instance_valid(support):
		return _watcher_can_see_target_point(head_pos, forward, _watcher_target_aim_point(support), scan_range, cone_threshold, watcher, support)

	var square := _world_to_square(_active_robot_proxy_position())
	var ground_point := _watcher_ground_point_for_square(square)
	return _watcher_can_see_ground_point(head_pos, forward, ground_point, scan_range, cone_threshold, watcher)

func watcher_is_absorb_cooling(watcher: Node3D) -> bool:
	if watcher == null:
		return false
	var watcher_id := watcher.get_instance_id()
	var now := Time.get_ticks_msec() * 0.001
	return now < float(_watcher_absorb_ready_at.get(watcher_id, 0.0))

func _find_absorb_target(watcher: Node3D, forward: Vector3, head_pos: Vector3, scan_range: float, cone_threshold: float) -> Node3D:
	var best: Node3D
	var best_dist := INF
	for child in _build_root.get_children():
		var obj := child as Node3D
		if obj == null or obj == watcher:
			continue
		if int(obj.get_meta("stack_level", 0)) != 0:
			continue

		var kind0 := String(obj.get_meta("object_kind", ""))
		if kind0 != "robot" and kind0 != "boulder":
			continue

		var candidate := obj
		var boulder_chain: Array[Node3D] = []
		if kind0 == "boulder":
			boulder_chain.append(obj)
			while true:
				var stacked := _get_stacked_on_boulder(candidate)
				if stacked == null:
					break
				candidate = stacked
				var stacked_kind := String(candidate.get_meta("object_kind", ""))
				if stacked_kind == "boulder":
					boulder_chain.append(candidate)

		var candidate_square := _node_square(candidate)
		if candidate_square == _player_occupied_square():
			continue

		var kind := String(candidate.get_meta("object_kind", ""))
		var level := int(candidate.get_meta("stack_level", 0))
		var stacked_tree_absorbable := kind == "tree" and level == 1

		if kind != "robot" and kind != "boulder" and not stacked_tree_absorbable:
			continue
		if kind == "robot" and _active_robot != null and candidate == _active_robot:
			continue

		var energy := _energy_cost_for_node(candidate)
		if not stacked_tree_absorbable and energy <= 1:
			continue

		var support_id := int(candidate.get_meta("support_boulder_id", -1))
		var support := _find_node_by_instance_id(support_id) if level == 1 else null
		var has_visibility := false
		var target_pos := candidate.global_position

		if level == 1 and support != null:
			if kind == "boulder" or kind == "tree":
				var can_see_candidate := _watcher_can_see_target_point(head_pos, forward, _watcher_target_aim_point(candidate), scan_range, cone_threshold, watcher, candidate)
				var can_see_support := _watcher_can_see_target_point(head_pos, forward, _watcher_target_aim_point(support), scan_range, cone_threshold, watcher, support)
				has_visibility = can_see_candidate or can_see_support
				target_pos = _watcher_target_aim_point(support) if can_see_support and not can_see_candidate else _watcher_target_aim_point(candidate)
			else:
				target_pos = _watcher_target_aim_point(support)
				has_visibility = _watcher_can_see_target_point(head_pos, forward, target_pos, scan_range, cone_threshold, watcher, support)
		elif level == 0 and _get_stacked_on_boulder(candidate) == null:
			# Ground-level robot/boulder with no object on top is a valid absorb target.
			target_pos = _watcher_target_aim_point(candidate)
			has_visibility = _watcher_can_see_target_point(head_pos, forward, target_pos, scan_range, cone_threshold, watcher, candidate)
		else:
			target_pos = _watcher_target_aim_point(candidate)
			has_visibility = _watcher_can_see_target_point(head_pos, forward, target_pos, scan_range, cone_threshold, watcher, candidate)

		var distance := target_pos.distance_to(head_pos)
		if not has_visibility:
			continue

		if distance < best_dist:
			best_dist = distance
			best = candidate
	return best

func _watcher_target_aim_point(target: Node3D) -> Vector3:
	if target == null:
		return Vector3.ZERO
	var kind := String(target.get_meta("object_kind", ""))
	if kind == "tree":
		return target.global_position + Vector3(0, 0.95, 0)
	if kind == "robot":
		return target.global_position + Vector3(0, 0.85, 0)
	return target.global_position

func _watcher_ground_aim_point(target: Node3D) -> Vector3:
	if target == null:
		return Vector3.ZERO
	var square := Vector2i(int(target.get_meta("grid_x", 0)), int(target.get_meta("grid_z", 0)))
	var y := _square_ground_y(square)
	return _square_center_world(square, y)

func _is_within_horizontal_view(origin: Vector3, forward: Vector3, point: Vector3, max_distance: float, horizontal_dot_threshold: float) -> bool:
	var to_point := point - origin
	var flat_to := Vector3(to_point.x, 0.0, to_point.z)
	var flat_distance := flat_to.length()
	if flat_distance > max_distance or flat_distance <= 0.001:
		return false

	var flat_forward := Vector3(forward.x, 0.0, forward.z)
	var flat_forward_len := flat_forward.length()
	if flat_forward_len <= 0.001:
		return false

	var forward_dir := flat_forward / flat_forward_len
	var target_dir := flat_to / flat_distance
	return forward_dir.dot(target_dir) > horizontal_dot_threshold

func _watcher_can_see_target_point(head_pos: Vector3, forward: Vector3, point: Vector3, scan_range: float, cone_threshold: float, watcher: Node3D, target: Node3D) -> bool:
	if not _is_within_horizontal_view(head_pos, forward, point, scan_range, cone_threshold):
		return false
	return _has_world_line_of_sight(head_pos, point, watcher, target)

func _watcher_can_see_ground_point(head_pos: Vector3, forward: Vector3, point: Vector3, scan_range: float, cone_threshold: float, watcher: Node3D) -> bool:
	if not _is_within_horizontal_view(head_pos, forward, point, scan_range, cone_threshold):
		return false
	var p := PhysicsRayQueryParameters3D.create(head_pos, point)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	p.exclude = []
	if watcher is CollisionObject3D:
		p.exclude.append((watcher as CollisionObject3D).get_rid())
	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	if hit.is_empty():
		return false
	var collider := hit.get("collider") as Node
	return _is_removal_square_surface(collider)

func _watcher_can_see_unobstructed_point(head_pos: Vector3, forward: Vector3, point: Vector3, scan_range: float, cone_threshold: float, watcher: Node3D) -> bool:
	if not _is_within_horizontal_view(head_pos, forward, point, scan_range, cone_threshold):
		return false
	var p := PhysicsRayQueryParameters3D.create(head_pos, point)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	p.exclude = []
	if watcher is CollisionObject3D:
		p.exclude.append((watcher as CollisionObject3D).get_rid())
	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	return hit.is_empty()
func _has_world_line_of_sight(from: Vector3, to: Vector3, watcher: Node3D, target: Node3D) -> bool:
	var ray_start := from
	var ray_dir := (to - from).normalized()
	var exclude_rids: Array = []
	if watcher is CollisionObject3D:
		exclude_rids.append((watcher as CollisionObject3D).get_rid())

	for _attempt in range(2):
		var p := PhysicsRayQueryParameters3D.create(ray_start, to)
		p.collide_with_areas = false
		p.collide_with_bodies = true
		p.exclude = exclude_rids
		var hit := get_world_3d().direct_space_state.intersect_ray(p)
		if hit.is_empty():
			return target == null
		var collider := hit.get("collider") as Node
		if collider == null:
			return false

		# Ignore watcher self-hit once, then test the next surface.
		if watcher != null and (collider == watcher or watcher.is_ancestor_of(collider)):
			if collider.has_method("get_rid"):
				exclude_rids.append(collider.call("get_rid"))
			ray_start = (hit.get("position", ray_start) as Vector3) + ray_dir * 0.05
			continue

		if target == null:
			return false
		return target.is_ancestor_of(collider) or collider == target

	return false

func _degrade_object_one_energy(node: Node3D) -> void:
	if node == null or _build_root == null:
		return

	var kind := String(node.get_meta("object_kind", ""))
	var square := Vector2i(int(node.get_meta("grid_x", 0)), int(node.get_meta("grid_z", 0)))
	var level := int(node.get_meta("stack_level", 0))
	var support := _find_node_by_instance_id(int(node.get_meta("support_boulder_id", -1)))
	var placement := _normalize_degrade_placement(square, level, support)
	level = placement["level"]
	support = placement["support"]

	if kind == "tree" and level == 1:
		node.queue_free()
		return

	if kind == "robot":
		var boulder := _create_boulder_node(node.position + Vector3(0, 0.5, 0), square, level, support)
		boulder.rotation = node.rotation
		_build_root.add_child(boulder)
		node.queue_free()
		return

	if kind == "boulder":
		var tree := _create_tree_node(node.position - Vector3(0, 0.5, 0), square, level, support)
		tree.rotation = node.rotation
		_build_root.add_child(tree)
		node.queue_free()
		return

func _normalize_degrade_placement(_square: Vector2i, level: int, support: Node3D) -> Dictionary:
	if level == 1 and support != null and support.is_in_group(GROUP_BUILD_BOULDER):
		return {"level": 1, "support": support}
	return {"level": 0, "support": null}

func _find_node_by_instance_id(id: int) -> Node3D:
	if id < 0 or _build_root == null:
		return null
	for child in _build_root.get_children():
		if child is Node3D and int((child as Node3D).get_instance_id()) == id:
			return child as Node3D
	return null

func _square_ground_y(square: Vector2i) -> float:
	var center := _square_center_world(square, 0.0)
	var from := Vector3(center.x, 128.0, center.z)
	var to := Vector3(center.x, -64.0, center.z)
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	if hit.is_empty():
		return center.y
	return float((hit["position"] as Vector3).y)

func _square_ground_hit(square: Vector2i) -> Dictionary:
	var center := _square_center_world(square, 0.0)
	var from := Vector3(center.x, 128.0, center.z)
	var to := Vector3(center.x, -64.0, center.z)
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	return get_world_3d().direct_space_state.intersect_ray(p)

func _spawn_random_tree() -> bool:
	if _build_root == null:
		return false
	for _i in range(256):
		var square := Vector2i(randi_range(0, GRID_SIZE - 1), randi_range(0, GRID_SIZE - 1))
		if _get_base_object_at(square) != null:
			continue
		var hit := _square_ground_hit(square)
		if hit.is_empty():
			continue
		var normal := hit.get("normal", Vector3.UP) as Vector3
		if normal.dot(Vector3.UP) < place_normal_dot_min:
			continue
		var y := float((hit["position"] as Vector3).y)
		var pos := _square_center_world(square, y)
		var tree := _create_tree_node(pos, square, 0, null)
		_build_root.add_child(tree)
		return true
	return false

func _try_spawn_meanie_near_player(watcher: Node3D, forward: Vector3, head_pos: Vector3, scan_range: float, cone_threshold: float) -> void:
	var watcher_id := watcher.get_instance_id()
	var now := Time.get_ticks_msec() * 0.001
	var ready_at := float(_meanie_cooldowns.get(watcher_id, 0.0))
	if now < ready_at:
		return

	var player_pos := _player_base_position()
	var nearest_tree: Node3D
	var best_dist := INF
	for child in _build_root.get_children():
		var obj := child as Node3D
		if obj == null:
			continue
		var kind := String(obj.get_meta("object_kind", ""))
		if kind != "tree":
			continue
		var square_pos := _watcher_ground_aim_point(obj)
		if not _watcher_can_see_ground_point(head_pos, forward, square_pos, scan_range, cone_threshold, watcher):
			continue
		var d := obj.global_position.distance_to(player_pos)
		if d < best_dist and d <= 12.0:
			best_dist = d
			nearest_tree = obj

	if nearest_tree == null:
		_meanie_cooldowns[watcher_id] = now + 2.0
		return

	_convert_tree_to_meanie(nearest_tree)
	_meanie_cooldowns[watcher_id] = now + 5.0

func _convert_tree_to_meanie(tree: Node3D) -> void:
	if tree == null:
		return
	for child in tree.get_children():
		child.queue_free()

	tree.set_meta("object_kind", "meanie")
	tree.set_script(_watcher_script)
	tree.set("player_path", NodePath("../../Player"))
	tree.set("watcher_kind", "meanie")
	tree.set("step", 20.0)
	tree.set("timer", 1.0)
	tree.set("rotation_speed", 0.0)
	tree.set("scan_range", 24.0)
	tree.set("cone_dot_threshold", 0.84)

	_attach_model_contents(tree, MEANIE_MODEL_PATH)

func _update_watcher_pressure(delta: float) -> void:
	if _won:
		_update_warning_ui(false, false)
		return
	var now := Time.get_ticks_msec() * 0.001
	for k in _watcher_contacts.keys():
		var e: Dictionary = _watcher_contacts[k]
		if now - float(e.get("time", 0.0)) > WATCH_CONTACT_STALE_SECONDS:
			_watcher_contacts.erase(k)
			_watcher_debug_targets.erase(k)
			_watcher_absorb_ready_at.erase(k)

	var sees_player := false
	var sees_square := false
	for e in _watcher_contacts.values():
		if bool(e.get("sees_player", false)):
			sees_player = true
		if bool(e.get("sees_square", false)):
			sees_square = true

	if sees_player and sees_square:
		_watch_seen_timer += delta
		if _watch_seen_timer >= WATCH_LOCK_SECONDS:
			_watch_drain_timer += delta
			while _watch_drain_timer >= WATCH_DRAIN_INTERVAL and not _lost:
				if _energy >= 0:
					_energy -= 1
					_update_energy_ui()
					_spawn_random_tree()
					if _energy <= -1:
						_set_lost()
				_watch_drain_timer -= WATCH_DRAIN_INTERVAL
	else:
		_watch_seen_timer = 0.0
		_watch_drain_timer = 0.0

	_update_warning_ui(sees_player, sees_square)
	_update_debug_ui()
