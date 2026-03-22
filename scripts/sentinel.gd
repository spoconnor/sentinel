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
var _debug_last_body_hit: String = ""
var _debug_last_head_hit: String = ""

func _ready() -> void:
	_refresh_player_refs()
	_create_debug_vision_mesh()

func _process(delta: float) -> void:
	if _player == null:
		_refresh_player_refs()
	if _player == null or head_pivot == null:
		return

	var head_pos := head_pivot.global_position
	var forward := -head_pivot.global_transform.basis.z.normalized()

	var body_point := _player_body_target_point()
	var sees_body := false
	if _is_within_view(head_pos, forward, body_point, scan_range, cone_dot_threshold):
		sees_body = _has_line_of_sight_to_player(head_pos, body_point, "body")
	else:
		_debug_last_body_hit = "out-of-view"

	var sees_head := false
	if _player_head != null and _is_within_view(head_pos, forward, _player_head.global_position, scan_range, cone_dot_threshold):
		sees_head = _has_line_of_sight_to_player(head_pos, _player_head.global_position, "head")
	else:
		_debug_last_head_hit = "out-of-view"

	var sees_direct_player := sees_body or sees_head
	var sees_square := false
	if sees_direct_player and _player != null and _player.has_method("watcher_can_see_player_support"):
		sees_square = bool(_player.call("watcher_can_see_player_support", self, head_pos, forward, scan_range, cone_dot_threshold))
	var sees_player := sees_direct_player and sees_square

	if not sees_player and _player != null and _player.has_method("watcher_can_see_player_proxy"):
		var proxy_player_visible := bool(_player.call("watcher_can_see_player_proxy", self, head_pos, forward, scan_range, cone_dot_threshold))
		if proxy_player_visible:
			sees_player = true
			if _player.has_method("watcher_can_see_player_proxy_ground"):
				sees_square = bool(_player.call("watcher_can_see_player_proxy_ground", self, head_pos, forward, scan_range, cone_dot_threshold))
			else:
				sees_square = true

	var sees_absorbable := false
	var absorb_cooldown := false
	if not sees_player and _player != null:
		if _player.has_method("watcher_can_absorb"):
			sees_absorbable = bool(_player.call("watcher_can_absorb", self, forward, head_pos, scan_range, cone_dot_threshold))
		if _player.has_method("watcher_is_absorb_cooling"):
			absorb_cooldown = bool(_player.call("watcher_is_absorb_cooling", self))

	if not sees_player and not sees_absorbable and not absorb_cooldown:
		if timer > 0.0:
			_turn_elapsed += delta
			while _turn_elapsed >= timer:
				rotate_y(deg_to_rad(step))
				_turn_elapsed -= timer
		elif rotation_speed != 0.0:
			rotate_y(rotation_speed * delta)
	else:
		_turn_elapsed = 0.0

	if sees_player:
		_locked_time += delta
	else:
		_locked_time = max(0.0, _locked_time - delta)

	_update_light()
	_update_debug_vision_visibility()
	var los_debug := "body=%s head=%s" % [_debug_last_body_hit, _debug_last_head_hit]
	_report_contact(sees_player, sees_square, los_debug)
	_try_action(delta, forward, head_pos, sees_player, sees_square)

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

func _is_within_view(origin: Vector3, forward: Vector3, point: Vector3, max_distance: float, horizontal_dot_threshold: float) -> bool:
	return _is_within_horizontal_view(origin, forward, point, max_distance, horizontal_dot_threshold)

func _can_see_point(point: Vector3, head_pos: Vector3, forward: Vector3, exclude_nodes: Array, target: Node3D = null) -> bool:
	if not _is_within_view(head_pos, forward, point, scan_range, cone_dot_threshold):
		return false
	return _has_line_of_sight(head_pos, point, exclude_nodes, target)

func _has_line_of_sight(from: Vector3, to: Vector3, exclude_nodes: Array, target: Node3D = null) -> bool:
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	p.exclude = []
	for n in exclude_nodes:
		if n is Node3D:
			p.exclude.append((n as Node3D).get_rid())
	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	if hit.is_empty():
		return target == null
	if target == null:
		return false
	var collider := hit.get("collider") as Node
	if collider == null:
		return false
	return collider == target or target.is_ancestor_of(collider)

func _has_line_of_sight_to_player(from: Vector3, to: Vector3, debug_slot: String = "") -> bool:
	if _player == null:
		if debug_slot == "body":
			_debug_last_body_hit = "no-player"
		elif debug_slot == "head":
			_debug_last_head_hit = "no-player"
		return false

	var ray_dir := (to - from).normalized()
	var ray_start := from + ray_dir * 0.12
	var exclude_rids: Array = []
	if has_method("get_rid"):
		exclude_rids.append(call("get_rid"))

	for _attempt in range(3):
		var p := PhysicsRayQueryParameters3D.create(ray_start, to)
		p.collide_with_areas = false
		p.collide_with_bodies = true
		p.exclude = exclude_rids
		var hit := get_world_3d().direct_space_state.intersect_ray(p)
		if hit.is_empty():
			if debug_slot == "body":
				_debug_last_body_hit = "empty"
			elif debug_slot == "head":
				_debug_last_head_hit = "empty"
			return true

		var collider := hit.get("collider") as Node
		var collider_name := "null"
		if collider != null:
			collider_name = str(collider.get_path())
		if debug_slot == "body":
			_debug_last_body_hit = collider_name
		elif debug_slot == "head":
			_debug_last_head_hit = collider_name
		if collider == null:
			return false

		# Ignore our own collision and the Sentinel's support pedestal so they don't
		# block line-of-sight checks toward the player.
		if _should_ignore_los_blocker(collider):
			if collider.has_method("get_rid"):
				exclude_rids.append(collider.call("get_rid"))
			ray_start = (hit.get("position", ray_start) as Vector3) + ray_dir * 0.12
			continue

		var current := collider
		while current != null:
			if current == _player:
				return true
			current = current.get_parent()
		return false

	return false

func _should_ignore_los_blocker(collider: Node) -> bool:
	if collider == null:
		return false
	if collider == self or self.is_ancestor_of(collider):
		return true

	var kind := String(collider.get_meta("object_kind", ""))
	if kind != "pedestal":
		return false

	var own_x := int(get_meta("grid_x", -1))
	var own_z := int(get_meta("grid_z", -1))
	return int(collider.get_meta("grid_x", -2)) == own_x and int(collider.get_meta("grid_z", -2)) == own_z
	
func _player_body_target_point() -> Vector3:
	if _player == null:
		return Vector3.ZERO
	var player_col := _player.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if player_col != null:
		return player_col.global_position
	return _player.global_position + Vector3(0, 1.0, 0)

func _refresh_player_refs() -> void:
	_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		var root := get_tree().current_scene
		if root != null:
			_player = root.get_node_or_null("Player") as Node3D
	_player_head = null
	if _player != null:
		_player_head = _player.get_node_or_null("CameraPivot/Camera3D") as Node3D

func _report_contact(sees_player: bool, sees_square: bool, los_debug: String = "") -> void:
	if _player != null and _player.has_method("watcher_update_contact"):
		_player.call("watcher_update_contact", get_instance_id(), sees_player, sees_square, watcher_kind, los_debug)

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

	_debug_vision_mesh = MeshInstance3D.new()
	_debug_vision_mesh.name = "DebugVisionCone"
	_debug_vision_mesh.mesh = _build_debug_sector_mesh(scan_range, half_angle)
	_debug_vision_mesh.position = Vector3(0, 0.05, 0)

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.35, 0.2, 0.16) if watcher_kind == "sentinel" else (Color(1.0, 0.82, 0.2, 0.14) if watcher_kind == "sentry" else Color(1.0, 0.35, 0.75, 0.14))
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	_debug_vision_mesh.material_override = mat
	_debug_vision_mesh.visible = false
	head_pivot.add_child(_debug_vision_mesh)

func _build_debug_sector_mesh(radius: float, half_angle: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	var segments := maxi(12, int(ceil(rad_to_deg(half_angle * 2.0))))

	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3.ZERO
	for i in range(segments):
		var t0 := -half_angle + (float(i) / float(segments)) * (half_angle * 2.0)
		var t1 := -half_angle + (float(i + 1) / float(segments)) * (half_angle * 2.0)
		var p0 := Vector3(sin(t0) * radius, 0.0, -cos(t0) * radius)
		var p1 := Vector3(sin(t1) * radius, 0.0, -cos(t1) * radius)

		st.add_vertex(center)
		st.add_vertex(p1)
		st.add_vertex(p0)

	mesh = st.commit()
	return mesh

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
