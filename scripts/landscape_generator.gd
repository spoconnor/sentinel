extends Node3D

enum ObjType { ROBOT, SENTRY, TREE, BOULDER, MEANIE, SENTINEL, PEDESTAL }
const GROUP_BUILD_PLACEABLE := "build_placeable"
const GROUP_TRANSFER_ROBOT := "transfer_robot"

@export var seed_bcd: int = 0x0003
@export var use_generated_bcd: bool = true
@export var landscape_bcd: int = 0x0003
@export var tile_size: float = 1.6
@export var height_scale: float = 0.8

var _ull: int = 0
var _terrain_offset := Vector3.ZERO
var _sentinel_script := load("res://scripts/sentinel.gd")
const ROBOT_MODEL_PATH := "res://models/robot.glb"
const TREE_MODEL_PATH := "res://models/tree.glb"
const BOULDER_MODEL_PATH := "res://models/boulder.glb"
const PEDESTAL_MODEL_PATH := "res://models/pedestal.glb"
const SENTRY_MODEL_PATH := "res://models/sentry.glb"
const SENTINEL_MODEL_PATH := "res://models/sentinel.glb"

func _ready() -> void:
	_generate_level_objects()

func regenerate_level(new_level: int) -> void:
	landscape_bcd = new_level & 0xFFFF
	_generate_level_objects()

func _generate_level_objects() -> void:
	var bcd := landscape_bcd
	if use_generated_bcd:
		bcd = _generate_landscape_bcd_from_sentcode(seed_bcd)
	landscape_bcd = bcd

	var maparr := _generate_landscape(bcd)
	_build_mesh(maparr)

	var sentry_data := _place_sentries(bcd, maparr)
	var objects: Array = sentry_data["objects"]
	var max_height: int = sentry_data["max_height"]

	var player_data := _place_player(bcd, max_height, objects, maparr)
	objects = player_data["objects"]
	max_height = player_data["max_height"]

	var tree_data := _place_trees(max_height, objects, maparr)
	objects = tree_data["objects"]

	call_deferred("_spawn_generated_objects", objects)
	print("Generated landscape_bcd=0x%04X, objects=%d" % [bcd, objects.size()])

func _spawn_generated_objects(objects: Array) -> void:
	_cache_sentinel_start_square(objects)
	_spawn_objects(objects)
	_apply_player_spawn(objects)

func _cache_sentinel_start_square(objects: Array) -> void:
	var build_root := _ensure_build_root()
	for o in objects:
		if int(o.get("type", -1)) != ObjType.SENTINEL:
			continue
		build_root.set_meta("sentinel_start_square_x", int(o.get("x", 0)))
		build_root.set_meta("sentinel_start_square_z", int(o.get("z", 0)))
		return

func _seed(land_bcd: int) -> void:
	_ull = (1 << 16) | (land_bcd & 0xFFFF)

func _rng() -> int:
	for _i in range(8):
		_ull <<= 1
		_ull |= ((_ull >> 20) ^ (_ull >> 33)) & 1
	return (_ull >> 32) & 0xFF

func _rng_bcd_digits() -> int:
	var x := _rng()
	var a := (x >> 4) & 0xF
	if a > 9:
		a -= 6
	var b := x & 0xF
	if b > 9:
		b -= 6
	return (a << 4) | b

func _generate_landscape_bcd_from_sentcode(base_bcd: int) -> int:
	_seed(base_bcd)
	var hi := _rng_bcd_digits()
	var lo := _rng_bcd_digits()
	return ((hi << 8) | lo) & 0xFFFF

func _rng_00_16() -> int:
	var r := _rng()
	return (r & 7) + ((r >> 3) & 0xF)

func _generate_landscape(land_bcd: int) -> Array:
	_seed(land_bcd)
	for _i in range(0x51):
		_rng()

	var hscale := 0x18
	if land_bcd != 0:
		hscale = _rng_00_16() + 0x0E

	var maparr: Array = []
	for z in range(0x20):
		var row: Array = []
		for x in range(0x20):
			row.append(_rng())
		row.reverse()
		maparr.append(row)
	maparr.reverse()

	for _p in range(2):
		maparr = _smooth_map(maparr, true)
		maparr = _smooth_map(maparr, false)

	for z in range(0x20):
		for x in range(0x20):
			maparr[z][x] = _scale_and_offset(maparr[z][x], hscale)

	for _p in range(2):
		maparr = _despike_map(maparr, true)
		maparr = _despike_map(maparr, false)

	maparr = _add_tile_shapes(maparr)
	maparr = _swap_nibbles(maparr)
	return maparr

func _wrapped_slice(maparr: Array, entries: int, by_z: bool, idx: int) -> Array:
	var out: Array = []
	if by_z:
		for x in range(entries):
			out.append(maparr[idx][x & 0x1F])
	else:
		for z in range(entries):
			out.append(maparr[z & 0x1F][idx])
	return out

func _smooth_slice(arr: Array) -> Array:
	var group_size := arr.size() - 0x1F
	var out: Array = []
	for x in range(arr.size() - group_size + 1):
		var s := 0
		for i in range(group_size):
			s += arr[x + i]
		out.append(s / group_size)
	return out

func _smooth_map(maparr: Array, by_z: bool) -> Array:
	var out: Array = []
	if by_z:
		for z in range(0x20):
			out.append(_smooth_slice(_wrapped_slice(maparr, 0x23, true, z)))
	else:
		for z in range(0x20):
			out.append([])
		for x in range(0x20):
			var col := _smooth_slice(_wrapped_slice(maparr, 0x23, false, x))
			for z in range(0x20):
				out[z].append(col[z])
	return out

func _despike_midval(a0: int, a1: int, a2: int) -> int:
	if a1 == a2:
		return a1
	elif a1 > a2:
		if a1 <= a0:
			return a1
		elif a0 < a2:
			return a2
		else:
			return a0
	elif a1 >= a0:
		return a1
	elif a2 < a0:
		return a2
	else:
		return a0

func _despike_slice(arr: Array) -> Array:
	var copy := arr.duplicate()
	for x in range(0x1F, -1, -1):
		copy[x + 1] = _despike_midval(copy[x], copy[x + 1], copy[x + 2])
	var out: Array = []
	for i in range(0x20):
		out.append(copy[i])
	return out

func _despike_map(maparr: Array, by_z: bool) -> Array:
	var out: Array = []
	if by_z:
		for z in range(0x20):
			out.append(_despike_slice(_wrapped_slice(maparr, 0x22, true, z)))
	else:
		for z in range(0x20):
			out.append([])
		for x in range(0x20):
			var col := _despike_slice(_wrapped_slice(maparr, 0x22, false, x))
			for z in range(0x20):
				out[z].append(col[z])
	return out

func _scale_and_offset(v: int, scale_value: int) -> int:
	var mag := v - 0x80
	mag = (mag * scale_value) / 256
	mag = maxi(mag + 6, 0)
	mag = mini(mag + 1, 11)
	return mag

func _tile_shape(fl: int, bl: int, br: int, fr: int) -> int:
	if fl == fr:
		if fl == bl:
			if fl == br:
				return 0
			elif fl < br:
				return 0xA
			else:
				return 0x3
		elif br == bl:
			if br < fr:
				return 0x1
			else:
				return 0x9
		elif br == fr:
			if br < bl:
				return 0x6
			else:
				return 0xF
		else:
			return 0xC
	elif fl == bl:
		if br == fr:
			if br < bl:
				return 0x5
			else:
				return 0xD
		elif br == bl:
			if br < fr:
				return 0xE
			else:
				return 0x7
		else:
			return 0x4
	elif br == fr:
		if br == bl:
			if br < fl:
				return 0xB
			else:
				return 0x2
		else:
			return 0x4
	return 0xC

func _add_tile_shapes(maparr: Array) -> Array:
	var out := maparr.duplicate(true)
	for z in range(0x1E, -1, -1):
		for x in range(0x1E, -1, -1):
			var fl: int = int(maparr[z][x]) & 0xF
			var bl: int = int(maparr[z + 1][x]) & 0xF
			var br: int = int(maparr[z + 1][x + 1]) & 0xF
			var fr: int = int(maparr[z][x + 1]) & 0xF
			var shape := _tile_shape(fl, bl, br, fr)
			out[z][x] = (shape << 4) | (maparr[z][x] & 0xF)
	return out

func _swap_nibbles(maparr: Array) -> Array:
	var out: Array = []
	for z in range(0x20):
		var row: Array = []
		for x in range(0x20):
			var v: int = maparr[z][x]
			row.append(((v & 0xF) << 4) | (v >> 4))
		out.append(row)
	return out

func _build_mesh(maparr: Array) -> void:
	if has_node("Terrain"):
		get_node("Terrain").queue_free()
	if has_node("TerrainBody"):
		get_node("TerrainBody").queue_free()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var flat_colour_a := Color(0.18, 0.78, 0.22)
	var flat_colour_b := Color(0.12, 0.56, 0.56)
	var slope_colour_a := Color(0.26, 0.26, 0.3)
	var slope_colour_b := Color(0.36, 0.36, 0.4)

	for z in range(0x1F):
		for x in range(0x1F):
			var h00 := float((maparr[z][x] >> 4)) * height_scale
			var h10 := float((maparr[z][x + 1] >> 4)) * height_scale
			var h01 := float((maparr[z + 1][x] >> 4)) * height_scale
			var h11 := float((maparr[z + 1][x + 1] >> 4)) * height_scale
			var tile_shape_val := int(maparr[z][x] & 0xF)

			var checker_idx := (x + z) & 1
			var c: Color = flat_colour_a if checker_idx == 0 else flat_colour_b
			if tile_shape_val != 0:
				c = slope_colour_a if checker_idx == 0 else slope_colour_b

			var p00 := Vector3(x * tile_size, h00, z * tile_size)
			var p10 := Vector3((x + 1) * tile_size, h10, z * tile_size)
			var p01 := Vector3(x * tile_size, h01, (z + 1) * tile_size)
			var p11 := Vector3((x + 1) * tile_size, h11, (z + 1) * tile_size)

			st.set_color(c)
			st.add_vertex(p00)
			st.set_color(c)
			st.add_vertex(p11)
			st.set_color(c)
			st.add_vertex(p01)

			st.set_color(c)
			st.add_vertex(p00)
			st.set_color(c)
			st.add_vertex(p10)
			st.set_color(c)
			st.add_vertex(p11)

	st.generate_normals()
	var mesh := st.commit()

	var terrain := MeshInstance3D.new()
	terrain.name = "Terrain"
	terrain.mesh = mesh
	_terrain_offset = Vector3(-16.0 * tile_size, 0.0, -16.0 * tile_size)
	terrain.position = _terrain_offset
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	terrain.material_override = mat
	add_child(terrain)

	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.position = terrain.position
	var collision_shape_node := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	concave.set_faces(mesh.get_faces())
	collision_shape_node.shape = concave
	body.add_child(collision_shape_node)
	add_child(body)

func _height_at(x: int, z: int, maparr: Array) -> int:
	return int(maparr[z][x]) >> 4

func _is_flat(x: int, z: int, maparr: Array) -> bool:
	return (int(maparr[z][x]) & 0xF) == 0

func _objects_at(x: int, z: int, objects: Array) -> bool:
	for o in objects:
		if int(o["x"]) == x and int(o["z"]) == z:
			return true
	return false

func _highest_positions(maparr: Array) -> Array:
	var grid_max: Array = []
	for i in range(0x40):
		var gridx := (i & 7) << 2
		var gridz := (i & 0x38) >> 1
		var max_height := 0
		var max_x := -1
		var max_z := -1
		for j in range(0x10):
			var x := gridx + (j & 3)
			var z := gridz + (j >> 2)
			if x == 0x1F or z == 0x1F:
				continue
			var h := _height_at(x, z, maparr)
			if _is_flat(x, z, maparr) and h >= max_height:
				max_height = h
				max_x = x
				max_z = z
		grid_max.append([max_height, max_x, max_z])
	return grid_max

func _leading_zeros_7bit(v: int) -> int:
	for i in range(6, -1, -1):
		if ((v >> i) & 1) == 1:
			return 6 - i
	return 7

func _calc_num_sentries(landscape_bcd_value: int) -> int:
	if landscape_bcd_value == 0x0000:
		return 1

	var base_sentries := ((landscape_bcd_value & 0xF000) >> 12) + 2
	var num_sentries := 0
	while true:
		var r := _rng()
		var adjust := _leading_zeros_7bit(r & 0x7F)
		if (r & 0x80) != 0:
			adjust = ~adjust
		num_sentries = base_sentries + adjust
		if num_sentries >= 0 and num_sentries <= 7:
			break

	var max_sentries := (landscape_bcd_value & 0x00F0) >> 4
	if landscape_bcd_value >= 0x0100 or max_sentries > 7:
		max_sentries = 7
	return 1 + mini(num_sentries, max_sentries)

func _object_at(type_id: int, x: int, y: int, z: int) -> Dictionary:
	return {
		"type": type_id,
		"x": x,
		"y": y,
		"z": z,
		"rot": ((_rng() & 0xF8) + 0x60) & 0xFF,
		"step": 0,
		"timer": 0,
	}

func _random_coord() -> int:
	while true:
		var r := _rng() & 0x1F
		if r < 0x1F:
			return r
	return 0

func _object_random(type_id: int, max_height: int, objects: Array, maparr: Array) -> Dictionary:
	var current_max := max_height
	while true:
		for _attempt in range(0xFF):
			var x := _random_coord()
			var z := _random_coord()
			var y := _height_at(x, z, maparr)
			if _is_flat(x, z, maparr) and not _objects_at(x, z, objects) and y < current_max:
				return _object_at(type_id, x, y, z)
		current_max += 1
		if current_max >= 0xC:
			return {}
	return {}

func _place_sentries(landscape_bcd_value: int, maparr: Array) -> Dictionary:
	var objects: Array = []
	var highest := _highest_positions(maparr)
	var max_height := 0
	for h in highest:
		max_height = maxi(max_height, int(h[0]))

	var num_sentries := _calc_num_sentries(landscape_bcd_value)
	for _i in range(num_sentries):
		while true:
			var height_indices: Array = []
			for idx in range(highest.size()):
				if int(highest[idx][0]) == max_height:
					height_indices.append(idx)
			if height_indices.size() > 0:
				height_indices.reverse()
				var idx_mask := 0xFF >> _leading_zeros_7bit(height_indices.size() - 1)
				var idx_choice := 0
				while true:
					idx_choice = _rng() & idx_mask
					if idx_choice < height_indices.size():
						break
				var idx_grid: int = int(height_indices[idx_choice])
				var y := int(highest[idx_grid][0])
				var x := int(highest[idx_grid][1])
				var z := int(highest[idx_grid][2])

				for offset in [-9, -8, -7, -1, 0, 1, 7, 8, 9]:
					var idx_clear: int = idx_grid + int(offset)
					if idx_clear >= 0 and idx_clear < highest.size():
						highest[idx_clear][0] = 0

				if objects.is_empty():
					var pedestal := _object_at(ObjType.PEDESTAL, x, y, z)
					pedestal["rot"] = 0
					objects.append(pedestal)
					objects.append(_object_at(ObjType.SENTINEL, x, y + 1, z))
				else:
					objects.append(_object_at(ObjType.SENTRY, x, y, z))

				var r := _rng()
				objects[-1]["step"] = -20 if (r & 1) != 0 else 20
				objects[-1]["timer"] = ((r >> 1) & 0x1F) | 5
				break

			max_height -= 1
			if max_height <= 0:
				return {"objects": objects, "max_height": max_height}

	return {"objects": objects, "max_height": max_height}

func _place_player(landscape_bcd_value: int, max_height: int, objects: Array, maparr: Array) -> Dictionary:
	var player: Dictionary
	if landscape_bcd_value == 0x0000:
		var x := 0x08
		var z := 0x11
		player = _object_at(ObjType.ROBOT, x, _height_at(x, z, maparr), z)
	else:
		var max_player_height := mini(max_height, 6)
		player = _object_random(ObjType.ROBOT, max_player_height, objects, maparr)
	objects.append(player)
	return {"objects": objects, "max_height": max_height}

func _place_trees(max_height: int, objects: Array, maparr: Array) -> Dictionary:
	var num_sents := 0
	for o in objects:
		var t := int(o["type"])
		if t == ObjType.SENTINEL or t == ObjType.SENTRY:
			num_sents += 1

	var r := _rng()
	var max_trees := 48 - (3 * num_sents)
	var num_trees := (r & 7) + ((r >> 3) & 0xF) + 10
	num_trees = mini(num_trees, max_trees)

	for _i in range(num_trees):
		var tree := _object_random(ObjType.TREE, max_height, objects, maparr)
		if not tree.is_empty():
			objects.append(tree)
	return {"objects": objects, "max_height": max_height}

func _object_world_position(o: Dictionary) -> Vector3:
	var center_x := (float(o["x"]) + 0.5) * tile_size
	var center_z := (float(o["z"]) + 0.5) * tile_size
	return Vector3(center_x, float(o["y"]) * height_scale, center_z) + _terrain_offset

func _spawn_objects(objects: Array) -> void:
	if has_node("PlacedObjects"):
		get_node("PlacedObjects").queue_free()
	var root := Node3D.new()
	root.name = "PlacedObjects"
	add_child(root)

	var build_root := _ensure_build_root()
	for child in build_root.get_children():
		build_root.remove_child(child)
		child.queue_free()

	for o in objects:
		var type_id := int(o["type"])
		var n := _create_object_node(type_id, o)
		n.position = _object_world_position(o)
		n.rotation_degrees.y = float(int(o["rot"])) * 360.0 / 256.0

		if type_id == ObjType.TREE:
			_attach_model_contents(n, TREE_MODEL_PATH)
			build_root.add_child(n)
			continue

		if type_id == ObjType.SENTINEL or type_id == ObjType.SENTRY:
			_spawn_watcher(n, type_id == ObjType.SENTINEL, o)
			build_root.add_child(n)
			continue

		var mesh_inst := MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.roughness = 0.8
		mesh_inst.material_override = mat

		if type_id == ObjType.ROBOT:
			_attach_model_contents(n, ROBOT_MODEL_PATH)
			mesh_inst.queue_free()
			build_root.add_child(n)
			continue
		elif type_id == ObjType.SENTINEL:
			var sentinel_mesh := SphereMesh.new()
			sentinel_mesh.radius = 0.6
			mesh_inst.mesh = sentinel_mesh
			mesh_inst.position.y = 0.8
			mat.albedo_color = Color(1.0, 0.35, 0.2)
		elif type_id == ObjType.PEDESTAL:
			_attach_model_contents(n, PEDESTAL_MODEL_PATH)
			mesh_inst.queue_free()
			root.add_child(n)
			continue
		else:
			var sentry_mesh := CylinderMesh.new()
			sentry_mesh.top_radius = 0.35
			sentry_mesh.bottom_radius = 0.45
			sentry_mesh.height = 1.2
			mesh_inst.mesh = sentry_mesh
			mesh_inst.position.y = 0.6
			mat.albedo_color = Color(0.95, 0.75, 0.2)

		n.add_child(mesh_inst)
		if type_id == ObjType.PEDESTAL:
			root.add_child(n)
		else:
			build_root.add_child(n)

func _ensure_build_root() -> Node3D:
	var scene_root := get_parent() as Node3D
	if scene_root == null:
		return self
	var existing := scene_root.get_node_or_null("BuildObjects") as Node3D
	if existing != null:
		return existing
	var created := Node3D.new()
	created.name = "BuildObjects"
	scene_root.add_child(created)
	return created

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

func _create_object_node(type_id: int, data: Dictionary) -> Node3D:
	var is_build_object := type_id == ObjType.ROBOT or type_id == ObjType.TREE or type_id == ObjType.SENTRY or type_id == ObjType.SENTINEL or type_id == ObjType.PEDESTAL
	var node: Node3D = StaticBody3D.new() if is_build_object else Node3D.new()
	if not is_build_object:
		return node

	node.set_meta("grid_x", int(data["x"]))
	node.set_meta("grid_z", int(data["z"]))
	if type_id != ObjType.PEDESTAL:
		node.add_to_group(GROUP_BUILD_PLACEABLE)
		node.set_meta("stack_level", 0)
		node.set_meta("support_boulder_id", -1)

	match type_id:
		ObjType.ROBOT:
			node.add_to_group(GROUP_TRANSFER_ROBOT)
			node.set_meta("object_kind", "robot")
			var col := CollisionShape3D.new()
			var shape := CapsuleShape3D.new()
			shape.radius = 0.32
			shape.height = 1.0
			col.shape = shape
			col.position.y = 0.85
			node.add_child(col)
		ObjType.TREE:
			node.set_meta("object_kind", "tree")
			var col := CollisionShape3D.new()
			var shape := CapsuleShape3D.new()
			shape.radius = 0.38
			shape.height = 2.7
			col.shape = shape
			col.position.y = 1.55
			node.add_child(col)
		ObjType.SENTINEL:
			node.set_meta("object_kind", "sentinel")
			var col := CollisionShape3D.new()
			var shape := CylinderShape3D.new()
			shape.radius = 0.78
			shape.height = 3.1
			col.shape = shape
			col.position.y = 1.55
			node.add_child(col)
		ObjType.SENTRY:
			node.set_meta("object_kind", "sentry")
			var col := CollisionShape3D.new()
			var shape := CylinderShape3D.new()
			shape.radius = 0.52
			shape.height = 2.35
			col.shape = shape
			col.position.y = 1.18
			node.add_child(col)
		ObjType.PEDESTAL:
			node.set_meta("object_kind", "pedestal")
			var col := CollisionShape3D.new()
			var shape := ConvexPolygonShape3D.new()
			var points := PackedVector3Array()
			var r := 0.78
			var h0 := 0.0
			var h1 := 0.8
			for i in range(6):
				var a := TAU * float(i) / 6.0
				points.append(Vector3(cos(a) * r, h0, sin(a) * r))
				points.append(Vector3(cos(a) * r, h1, sin(a) * r))
			shape.points = points
			col.shape = shape
			node.add_child(col)

	return node

func _spawn_watcher(root: Node3D, is_sentinel: bool, data: Dictionary) -> void:
	root.set_script(_sentinel_script)
	root.set("player_path", NodePath("../../Player"))
	root.set("watcher_kind", "sentinel" if is_sentinel else "sentry")
	var step_degrees := float(int(data.get("step", 20)))
	var timer_seconds := float(int(data.get("timer", 20)))
	root.set("step", step_degrees)
	root.set("timer", maxf(0.1, timer_seconds))
	root.set("rotation_speed", 0.0)
	root.set_process(true)
	root.set("scan_range", 32.0 if is_sentinel else 26.0)

	_attach_model_contents(root, SENTINEL_MODEL_PATH if is_sentinel else SENTRY_MODEL_PATH)

func _apply_player_spawn(objects: Array) -> void:
	var player_obj: Dictionary = {}
	for o in objects:
		if int(o["type"]) == ObjType.ROBOT:
			player_obj = o
			break
	if player_obj.is_empty():
		return

	var player := get_node_or_null("../Player") as CharacterBody3D
	if player == null:
		return
	player.global_position = to_global(_object_world_position(player_obj) + Vector3(0, 1.6, 0))
	player.rotation_degrees.y = float(int(player_obj["rot"])) * 360.0 / 256.0
