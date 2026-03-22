extends Node3D

enum ObjType { ROBOT, SENTRY, TREE, BOULDER, MEANIE, SENTINEL, PEDESTAL }
const GROUP_BUILD_PLACEABLE := "build_placeable"
const GROUP_TRANSFER_ROBOT := "transfer_robot"

@export var seed_bcd: int = 0x0000
@export var use_generated_bcd: bool = false
@export var use_cpc_code: bool = false
@export var cpc_code: String = ""
@export var landscape_bcd: int = 0x0000
@export var tile_size: float = 1.6
@export var height_scale: float = 2.0

var _ull: int = 0
var _rng_usage: int = 0
var _cpc_code_to_level: Dictionary = {}
var _terrain_offset := Vector3.ZERO
var _sentinel_script := load("res://scripts/sentinel.gd")
var _model_utils := preload("res://scripts/model_utils.gd")
const ROBOT_MODEL_PATH := "res://models/robot.glb"
const TREE_MODEL_PATH := "res://models/tree.glb"
const BOULDER_MODEL_PATH := "res://models/boulder.glb"
const ROBOT_VISUAL_SCALE := 0.75
const PEDESTAL_MODEL_PATH := "res://models/pedestal.glb"
const SENTRY_MODEL_PATH := "res://models/sentry.glb"
const SENTINEL_MODEL_PATH := "res://models/sentinel.glb"
const PEDESTAL_VISUAL_LIFT := 0.42
const PEDESTAL_TOP_HEIGHT := 0.84
const CPC_CODES_PATH := "res://example_code/sentinel_codes.txt"
const WATCHER_TURN_STEP_SCALE := 0.25
const WATCHER_TURN_TIMER_SCALE := 0.25
const WATCHER_VIEW_DOT_THRESHOLD := 0.9986295
const WATCHER_LIGHT_SPOT_ANGLE := 6.5

func _ready() -> void:
	_generate_level_objects()

func level_number_to_bcd(level_number: int) -> int:
	var clamped := clampi(level_number, 0, 9999)
	return (
		((clamped / 1000) % 10) << 12 |
		((clamped / 100) % 10) << 8 |
		((clamped / 10) % 10) << 4 |
		(clamped % 10)
	)

func landscape_bcd_to_level_number(level_bcd: int) -> int:
	return (
		((level_bcd >> 12) & 0xF) * 1000 +
		((level_bcd >> 8) & 0xF) * 100 +
		((level_bcd >> 4) & 0xF) * 10 +
		(level_bcd & 0xF)
	)

func is_valid_bcd_level(level_bcd: int) -> bool:
	if level_bcd < 0 or level_bcd > 0x9999:
		return false
	for shift in [0, 4, 8, 12]:
		if ((level_bcd >> shift) & 0xF) > 9:
			return false
	return true

func regenerate_level(new_level: int) -> void:
	landscape_bcd = level_number_to_bcd(new_level)
	use_cpc_code = false
	_generate_level_objects()

func regenerate_level_from_cpc_code(code: String) -> bool:
	var decoded := cpc_code_to_landscape_bcd(code)
	if decoded < 0:
		return false
	cpc_code = _normalize_cpc_code(code)
	use_cpc_code = true
	landscape_bcd = decoded
	_generate_level_objects()
	return true

func _generate_level_objects() -> void:
	var bcd := landscape_bcd
	if use_generated_bcd:
		if not is_valid_bcd_level(seed_bcd):
			push_error("seed_bcd must be a 4-digit BCD landscape value in the range 0x0000..0x9999")
			return
		bcd = _generate_landscape_bcd_from_sentcode(seed_bcd)
	elif use_cpc_code:
		var decoded := cpc_code_to_landscape_bcd(cpc_code)
		if decoded < 0:
			push_error("Invalid CPC code: %s" % cpc_code)
			return
		bcd = decoded
	elif not is_valid_bcd_level(bcd):
		push_error("landscape_bcd must be a 4-digit BCD landscape value in the range 0x0000..0x9999")
		return
	landscape_bcd = bcd

	var level_data := generate_level_snapshot(bcd)
	var maparr: Array = level_data["map"]
	_build_mesh(maparr)
	var objects: Array = level_data["objects"]

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
	_rng_usage = 0

func _rng() -> int:
	for _i in range(8):
		_ull <<= 1
		_ull |= ((_ull >> 20) ^ (_ull >> 33)) & 1
	_rng_usage += 1
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
	return generate_landscape_pipeline(land_bcd)["swap"]

func generate_landscape_pipeline(land_bcd: int) -> Dictionary:
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
	var stages := {
		"random": _copy_map(maparr),
	}

	var smooth_stage := 0
	for _p in range(2):
		maparr = _smooth_map(maparr, true)
		stages["smooth%d" % smooth_stage] = _copy_map(maparr)
		smooth_stage += 1
		maparr = _smooth_map(maparr, false)
		stages["smooth%d" % smooth_stage] = _copy_map(maparr)
		smooth_stage += 1

	for z in range(0x20):
		for x in range(0x20):
			maparr[z][x] = _scale_and_offset(maparr[z][x], hscale)
	stages["scaled"] = _copy_map(maparr)

	var despike_stage := 0
	for _p in range(2):
		maparr = _despike_map(maparr, true)
		stages["despike%d" % despike_stage] = _copy_map(maparr)
		despike_stage += 1
		maparr = _despike_map(maparr, false)
		stages["despike%d" % despike_stage] = _copy_map(maparr)
		despike_stage += 1

	maparr = _add_tile_shapes(maparr)
	stages["shape"] = _copy_map(maparr)
	maparr = _swap_nibbles(maparr)
	stages["swap"] = _copy_map(maparr)
	return stages

func generate_level_snapshot(land_bcd: int) -> Dictionary:
	var stages := generate_landscape_pipeline(land_bcd)
	var maparr: Array = stages["swap"]

	var sentry_data := _place_sentries(land_bcd, maparr)
	var objects: Array = sentry_data["objects"]
	var max_height: int = sentry_data["max_height"]

	var player_data := _place_player(land_bcd, max_height, objects, maparr)
	objects = player_data["objects"]
	max_height = player_data["max_height"]

	var tree_data := _place_trees(max_height, objects, maparr)
	objects = tree_data["objects"]

	return {
		"stages": stages,
		"map": maparr,
		"objects": objects,
		"max_height": max_height,
		"rng_usage": _rng_usage,
		"rng_state": _ull,
	}

func map_to_memory_bytes(maparr: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(0x400)
	for offset in range(0x400):
		var coord := _get_x_z_from_offset(offset)
		bytes[offset] = int(maparr[coord.y][coord.x]) & 0xFF
	return bytes

func cpc_code_to_landscape_bcd(code: String) -> int:
	_ensure_cpc_code_table_loaded()
	var normalized := _normalize_cpc_code(code)
	if normalized.is_empty():
		return -1
	return int(_cpc_code_to_level.get(normalized, -1))

func _copy_map(maparr: Array) -> Array:
	return maparr.duplicate(true)

func _get_x_z_from_offset(offset: int) -> Vector2i:
	var x := ((offset & 0x300) >> 8) | ((offset & 0xE0) >> 3)
	var z := offset & 0x1F
	return Vector2i(x, z)

func _normalize_cpc_code(code: String) -> String:
	return code.strip_edges()

func _ensure_cpc_code_table_loaded() -> void:
	if not _cpc_code_to_level.is_empty():
		return
	var file := FileAccess.open(CPC_CODES_PATH, FileAccess.READ)
	if file == null:
		push_error("Unable to open CPC code table: %s" % CPC_CODES_PATH)
		return

	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if not line.begins_with("|"):
			continue
		var parts := line.split("|", false)
		if parts.size() < 3:
			continue
		var land := String(parts[0]).strip_edges()
		var cpc := String(parts[2]).strip_edges()
		if land.length() != 4 or cpc.length() != 8:
			continue
		if not _is_decimal_digits(cpc):
			continue
		_cpc_code_to_level[cpc] = land.hex_to_int()

func _is_decimal_digits(text: String) -> bool:
	if text.is_empty():
		return false
	for i in range(text.length()):
		var c := text.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true

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
	mag = floori(float(mag * scale_value) / 256.0)
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

func _mask_for_count(count: int) -> int:
	var mask := 1
	while mask < count:
		mask = (mask << 1) | 1
	return mask

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
				var idx_mask := _mask_for_count(height_indices.size())
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
	# Clean up any previous generated container, including auto-renamed duplicates.
	for child in get_children():
		if child is Node and String((child as Node).name).begins_with("PlacedObjects"):
			remove_child(child)
			child.queue_free()
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
		if type_id == ObjType.SENTINEL:
			n.position.y += PEDESTAL_TOP_HEIGHT - height_scale
		n.rotation_degrees.y = float(int(o["rot"])) * 360.0 / 256.0

		if type_id == ObjType.TREE:
			var tree_visuals := _attach_model_contents(n, TREE_MODEL_PATH)
			_normalize_model_nodes(n, tree_visuals)
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
			var robot_visuals := _attach_model_contents(n, ROBOT_MODEL_PATH)
			_scale_model_nodes(robot_visuals, ROBOT_VISUAL_SCALE)
			_normalize_model_nodes(n, robot_visuals)
			_apply_character_palette(n, "robot")
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
			n.position.y += PEDESTAL_VISUAL_LIFT
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

func _attach_model_contents(parent: Node3D, model_path: String) -> Array:
	return _model_utils.attach_model_contents(parent, model_path)

func _scale_model_nodes(nodes: Array, scale_factor: float) -> void:
	_model_utils.scale_nodes(nodes, scale_factor)

func _normalize_model_nodes(parent: Node3D, nodes: Array) -> void:
	_model_utils.center_and_ground_nodes(parent, nodes)

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
			node.set_meta("collision_disabled", true)
			var col := CollisionShape3D.new()
			var shape := CapsuleShape3D.new()
			shape.radius = 0.32
			shape.height = 1.0
			col.shape = shape
			col.position.y = 0.85
			col.disabled = true
			node.add_child(col)
		ObjType.TREE:
			node.set_meta("object_kind", "tree")
			var col := CollisionShape3D.new()
			var shape := CapsuleShape3D.new()
			shape.radius = 0.38
			shape.height = 2.7
			col.shape = shape
			col.position.y = 1.55
			col.disabled = true
			node.add_child(col)
		ObjType.SENTINEL:
			node.set_meta("object_kind", "sentinel")
			var col := CollisionShape3D.new()
			var shape := CylinderShape3D.new()
			shape.radius = 0.78
			shape.height = 3.1
			col.shape = shape
			col.position.y = 1.55
			col.disabled = true
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
			col.position.y = PEDESTAL_VISUAL_LIFT
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
	var step_degrees := float(int(data.get("step", 20))) * WATCHER_TURN_STEP_SCALE
	var timer_seconds := float(int(data.get("timer", 20))) * WATCHER_TURN_TIMER_SCALE
	root.set("step", step_degrees)
	root.set("timer", maxf(0.1, timer_seconds))
	root.set("rotation_speed", 0.0)
	root.set_process(true)
	root.set("scan_range", 80.0 if is_sentinel else 26.0)
	root.set("cone_dot_threshold", WATCHER_VIEW_DOT_THRESHOLD)

	var visuals := _attach_model_contents(root, SENTINEL_MODEL_PATH if is_sentinel else SENTRY_MODEL_PATH)
	_restore_watcher_tags(root, "sentinel" if is_sentinel else "sentry")
	if is_sentinel:
		_stylize_sentinel(root)
	_normalize_model_nodes(root, visuals)
	_apply_character_palette(root, "sentinel" if is_sentinel else "sentry")

func _restore_watcher_tags(root: Node3D, watcher_kind: String) -> void:
	if root == null:
		return

	var head_pivot := root.get_node_or_null("HeadPivot") as Node3D
	if head_pivot == null:
		var nested_head_pivot := root.find_child("HeadPivot", true, false) as Node3D
		if nested_head_pivot != null:
			var old_parent := nested_head_pivot.get_parent()
			if old_parent != null and old_parent != root:
				old_parent.remove_child(nested_head_pivot)
				nested_head_pivot.owner = null
				root.add_child(nested_head_pivot)
			head_pivot = nested_head_pivot
	if head_pivot == null:
		head_pivot = Node3D.new()
		head_pivot.name = "HeadPivot"
		head_pivot.position.y = 1.4 if watcher_kind == "sentinel" else 1.2
		root.add_child(head_pivot)

	head_pivot.rotation_degrees.x = 0.0

	if root.get_node_or_null("Base") == null:
		var cube_base := root.get_node_or_null("Cube") as Node3D
		if cube_base != null:
			cube_base.name = "Base"

	var eye_light := head_pivot.get_node_or_null("EyeLight") as SpotLight3D
	if eye_light == null:
		eye_light = SpotLight3D.new()
		eye_light.name = "EyeLight"
		eye_light.position = Vector3(0, 0, -0.42) if watcher_kind == "sentinel" else Vector3(0, 0, -0.25)
		eye_light.rotation_degrees.x = -5.0
		eye_light.spot_range = 24.0 if watcher_kind == "sentinel" else 20.0
		eye_light.spot_angle = WATCHER_LIGHT_SPOT_ANGLE
		eye_light.light_energy = 2.7
		head_pivot.add_child(eye_light)

func _stylize_sentinel(root: Node3D) -> void:
	if root == null:
		return

	var base := root.find_child("Base", true, false) as Node3D
	var ankle := root.find_child("Ankle", true, false) as Node3D
	var trunk := root.find_child("Trunk", true, false) as Node3D
	var shoulder := root.find_child("Shoulder", true, false) as Node3D
	var head := root.find_child("Head", true, false) as Node3D
	var face := root.find_child("FaceCone", true, false) as Node3D
	var head_pivot := root.find_child("HeadPivot", true, false) as Node3D

	# Edited sentinel.glb is a minimal two-part model. Keep the head sitting directly on top
	# of the cube body and scale the visuals to about 10% taller than the robot.
	if ankle == null and trunk == null and shoulder == null and face == null:
		var base_mesh := base as MeshInstance3D
		var head_mesh := head as MeshInstance3D
		if base_mesh != null:
			base_mesh.scale *= 0.56
			base_mesh.position *= 0.56
			base_mesh.position.x = 0.0
			base_mesh.position.z = 0.0
		if head_mesh != null:
			head_mesh.scale *= 0.56
			head_mesh.position = Vector3.ZERO
		if head_pivot != null and base_mesh != null and head_mesh != null:
			var cube_top := _mesh_local_top(base_mesh)
			var head_bottom := _mesh_local_bottom(head_mesh)
			head_pivot.position = Vector3(0.0, cube_top - head_bottom + 0.02, 0.0)
			var eye_light := head_pivot.get_node_or_null("EyeLight") as SpotLight3D
			if eye_light != null:
				eye_light.position = Vector3(0.0, 0.0, -0.42)
		return

	# Slim legs, small torso, forward beak to match reference silhouette.
	if base:
		base.scale = Vector3(0.7, 0.6, 0.7)
		base.position.y = 0.15
	if ankle:
		ankle.scale = Vector3(0.55, 1.55, 0.55)
		ankle.position.y = 0.2
	if trunk:
		trunk.scale = Vector3(0.7, 0.6, 0.7)
		trunk.position.y = 1.1
	if shoulder:
		shoulder.scale = Vector3(0.8, 0.55, 0.8)
		shoulder.position.y = 1.35
	if head:
		head.scale = Vector3(0.6, 0.45, 0.6)
		head.position.y = 1.55
	if face:
		face.scale = Vector3(0.55, 1.6, 0.55)
		face.position = Vector3(0.0, 1.55, -0.45)
		face.rotation_degrees.x = -18.0
	if head_pivot:
		head_pivot.position.y = 1.4

func _mesh_local_top(mesh_node: MeshInstance3D) -> float:
	if mesh_node == null or mesh_node.mesh == null:
		return mesh_node.position.y if mesh_node != null else 0.0
	var aabb := mesh_node.mesh.get_aabb()
	return mesh_node.position.y + (aabb.position.y + aabb.size.y) * mesh_node.scale.y

func _mesh_local_bottom(mesh_node: MeshInstance3D) -> float:
	if mesh_node == null or mesh_node.mesh == null:
		return mesh_node.position.y if mesh_node != null else 0.0
	var aabb := mesh_node.mesh.get_aabb()
	return mesh_node.position.y + aabb.position.y * mesh_node.scale.y

func _apply_character_palette(root: Node3D, kind: String) -> void:
	var palette := {}
	if kind == "sentinel":
		palette = {
			"Base": Color(0.82, 0.15, 0.12),
			"Ankle": Color(0.72, 0.12, 0.1),
			"Trunk": Color(0.86, 0.2, 0.16),
			"Shoulder": Color(0.75, 0.14, 0.12),
			"Head": Color(0.08, 0.1, 0.12),
			"Crown0": Color(0.98, 0.9, 0.28),
			"Crown1": Color(0.98, 0.9, 0.28),
			"Crown2": Color(0.98, 0.9, 0.28),
			"Crown3": Color(0.98, 0.9, 0.28),
			"Crown4": Color(0.98, 0.9, 0.28),
			"FaceCone": Color(0.98, 0.9, 0.28),
			"_default": Color(0.18, 0.18, 0.2),
		}
	elif kind == "sentry":
		palette = {
			"Base": Color(0.92, 0.72, 0.2),
			"Shaft": Color(0.86, 0.62, 0.18),
			"Head": Color(0.12, 0.14, 0.18),
			"FaceCone": Color(0.96, 0.86, 0.32),
			"_default": Color(0.2, 0.2, 0.24),
		}
	elif kind == "robot":
		palette = {
			"Stem": Color(0.08, 0.38, 0.48),
			"Body": Color(0.08, 0.3, 0.7),
			"SideL": Color(0.12, 0.5, 0.6),
			"SideR": Color(0.12, 0.5, 0.6),
			"Head": Color(0.98, 0.9, 0.28),
			"_default": Color(0.12, 0.12, 0.14),
		}
	_apply_palette_to_meshes(root, palette)

func _apply_palette_to_meshes(root: Node, palette: Dictionary) -> void:
	if root == null:
		return
	if root is MeshInstance3D:
		var mesh_node := root as MeshInstance3D
		var key := mesh_node.name
		var color: Color = palette.get(key, palette.get("_default", Color(0.8, 0.8, 0.8)))
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.9
		mat.metallic = 0.05
		mesh_node.material_override = mat
	for child in root.get_children():
		if child is Node:
			_apply_palette_to_meshes(child, palette)

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

	var square := Vector2i(int(player_obj.get("x", 0)), int(player_obj.get("z", 0)))
	var ground_y := _square_ground_y(square)
	var spawn_world := _square_center_world(square, ground_y + 1.65)
	player.global_position = to_global(spawn_world)
	player.rotation_degrees.y = float(int(player_obj["rot"])) * 360.0 / 256.0

func _square_center_world(square: Vector2i, y: float) -> Vector3:
	return Vector3((float(square.x) + 0.5) * tile_size, y, (float(square.y) + 0.5) * tile_size) + _terrain_offset

func _square_ground_y(square: Vector2i) -> float:
	var center := _square_center_world(square, 0.0)
	var from := center + Vector3(0, 128.0, 0)
	var to := center + Vector3(0, -64.0, 0)
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	if hit.is_empty():
		return center.y
	return float((hit["position"] as Vector3).y)
