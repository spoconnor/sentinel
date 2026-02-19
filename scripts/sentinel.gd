extends Node3D

@export var player_path: NodePath
@export var rotation_speed: float = 0.0
@export var step: float = 20.0
@export var timer: float = 2.0
@export var scan_range: float = 28.0
@export var cone_dot_threshold: float = 0.86
@export var detection_hold_time: float = 1.2
@export var watcher_kind: String = "sentry"

@onready var head_pivot: Node3D = $HeadPivot
@onready var eye_light: SpotLight3D = $HeadPivot/EyeLight

var _player: Node3D
var _player_head: Node3D
var _locked_time: float = 0.0
var _turn_elapsed: float = 0.0
var _action_elapsed: float = 0.0
var _debug_vision_mesh: MeshInstance3D

func _ready() -> void:
	_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		var root := get_tree().current_scene
		if root != null:
			_player = root.get_node_or_null("Player") as Node3D
	if _player != null:
		_player_head = _player.get_node_or_null("CameraPivot/Camera3D") as Node3D
	_create_debug_vision_mesh()

func _process(delta: float) -> void:
	if _player == null or head_pivot == null:
		return

	var head_pos := head_pivot.global_position
	var forward := -head_pivot.global_transform.basis.z.normalized()
	var sees_body := _can_see_point(_player.global_position, head_pos, forward, [_player, self])
	var sees_head := false
	if _player_head != null:
		sees_head = _can_see_point(_player_head.global_position, head_pos, forward, [_player, self])
	var sees_player := sees_body or sees_head

	var sees_square := false
	if sees_player:
		var square_pos := _player.global_position - Vector3(0, 1.65, 0)
		sees_square = _can_see_point(square_pos, head_pos, forward, [_player, self])

	if not sees_player:
		if timer > 0.0:
			_turn_elapsed += delta
			while _turn_elapsed >= timer:
				rotate_y(deg_to_rad(step))
				_turn_elapsed -= timer
		elif rotation_speed != 0.0:
			rotate_y(rotation_speed * delta)

	if sees_player:
		_locked_time += delta
	else:
		_locked_time = max(0.0, _locked_time - delta)

	_update_light()
	_update_debug_vision_visibility()
	_report_contact(sees_player, sees_square)
	_try_action(delta, forward, head_pos, sees_player, sees_square)

func _can_see_point(point: Vector3, head_pos: Vector3, forward: Vector3, exclude_nodes: Array) -> bool:
	var to_point := point - head_pos
	var distance := to_point.length()
	if distance > scan_range or distance <= 0.001:
		return false
	var dir := to_point / distance
	if forward.dot(dir) <= cone_dot_threshold:
		return false
	return _has_line_of_sight(head_pos, point, exclude_nodes)

func _has_line_of_sight(from: Vector3, to: Vector3, exclude_nodes: Array) -> bool:
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	p.exclude = []
	for n in exclude_nodes:
		if n is Node3D:
			p.exclude.append((n as Node3D).get_rid())
	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	return hit.is_empty()

func _report_contact(sees_player: bool, sees_square: bool) -> void:
	if _player != null and _player.has_method("watcher_update_contact"):
		_player.call("watcher_update_contact", get_instance_id(), sees_player, sees_square, watcher_kind)

func _try_action(delta: float, forward: Vector3, head_pos: Vector3, sees_player: bool, sees_square: bool) -> void:
	if _player == null or not _player.has_method("watcher_attempt_action"):
		return

	_action_elapsed += delta
	var interval := 1.2
	if watcher_kind == "meanie":
		interval = maxf(0.35, (timer if timer > 0.0 else 1.0) * 0.5)
	else:
		interval = maxf(0.75, timer if timer > 0.0 else 1.5)

	if _action_elapsed < interval:
		return
	_action_elapsed = 0.0

	_player.call(
		"watcher_attempt_action",
		self,
		forward,
		head_pos,
		scan_range,
		cone_dot_threshold,
		watcher_kind,
		sees_player,
		sees_square
	)

func _create_debug_vision_mesh() -> void:
	if head_pivot == null or _debug_vision_mesh != null:
		return
	var half_angle := acos(clamp(cone_dot_threshold, -1.0, 1.0))
	var cone_radius := tan(half_angle) * scan_range
	cone_radius = maxf(cone_radius, 0.2)

	_debug_vision_mesh = MeshInstance3D.new()
	_debug_vision_mesh.name = "DebugVisionCone"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.02
	cone.bottom_radius = cone_radius
	cone.height = scan_range
	_debug_vision_mesh.mesh = cone
	_debug_vision_mesh.position = Vector3(0, 0, -scan_range * 0.5)
	_debug_vision_mesh.rotation_degrees = Vector3(90, 0, 0)

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.35, 0.2, 0.16) if watcher_kind == "sentinel" else (Color(1.0, 0.82, 0.2, 0.14) if watcher_kind == "sentry" else Color(1.0, 0.35, 0.75, 0.14))
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	_debug_vision_mesh.material_override = mat
	_debug_vision_mesh.visible = false
	head_pivot.add_child(_debug_vision_mesh)

func _update_debug_vision_visibility() -> void:
	if _debug_vision_mesh == null:
		return
	var visible_state := false
	if _player != null and _player.has_method("is_debug_mode_enabled"):
		visible_state = bool(_player.call("is_debug_mode_enabled"))
	_debug_vision_mesh.visible = visible_state

func _update_light() -> void:
	if eye_light == null:
		return

	if watcher_kind == "meanie":
		eye_light.light_color = Color(1.0, 0.25, 0.7)
		eye_light.light_energy = 3.8
		return

	if _locked_time >= detection_hold_time:
		eye_light.light_color = Color(1.0, 0.22, 0.16)
		eye_light.light_energy = 5.5
	elif _locked_time > 0.05:
		eye_light.light_color = Color(1.0, 0.72, 0.2)
		eye_light.light_energy = 4.0
	else:
		eye_light.light_color = Color(0.4, 1.0, 0.85)
		eye_light.light_energy = 2.7
