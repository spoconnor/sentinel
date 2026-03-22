extends RefCounted
class_name ModelUtils

static func attach_model_contents(parent: Node3D, model_path: String) -> Array:
	if parent == null or model_path == "":
		return []

	var packed := ResourceLoader.load(model_path) as PackedScene
	if packed == null:
		return []

	var inst := packed.instantiate() as Node3D
	if inst == null:
		return []

	var added_nodes: Array = []
	parent.add_child(inst)
	for child in inst.get_children():
		inst.remove_child(child)
		if child is Node:
			(child as Node).owner = null
		parent.add_child(child)
		if child is Node3D:
			added_nodes.append(child)
	inst.queue_free()
	return added_nodes

static func scale_nodes(nodes: Array, scale_factor: float) -> void:
	if is_zero_approx(scale_factor):
		return

	for node in nodes:
		var node3d := node as Node3D
		if node3d == null:
			continue
		node3d.scale *= scale_factor
		node3d.position *= scale_factor

static func center_and_ground_nodes(parent: Node3D, nodes: Array) -> void:
	if parent == null:
		return

	var bounds := _compute_mesh_bounds(parent, nodes)
	if bounds.size == Vector3.ZERO:
		return

	var center_x := bounds.position.x + (bounds.size.x * 0.5)
	var center_z := bounds.position.z + (bounds.size.z * 0.5)
	var offset := Vector3(-center_x, -bounds.position.y, -center_z)
	for node in nodes:
		var node3d := node as Node3D
		if node3d == null:
			continue
		node3d.position += offset

static func _compute_mesh_bounds(_parent: Node3D, roots: Array) -> AABB:
	var bounds := AABB()
	var has_bounds := false
	var pending: Array = []
	for root in roots:
		var node3d := root as Node3D
		if node3d == null:
			continue
		pending.append({
			"node": node3d,
			"transform": node3d.transform,
		})

	while not pending.is_empty():
		var current: Dictionary = pending.pop_back()
		var node3d := current.get("node") as Node3D
		var node_transform: Transform3D = current.get("transform", Transform3D.IDENTITY)

		if node3d is MeshInstance3D:
			var mesh_node := node3d as MeshInstance3D
			if mesh_node.mesh != null:
				var mesh_aabb := mesh_node.mesh.get_aabb()
				for corner in _aabb_corners(mesh_aabb):
					var local_corner := Vector3(node_transform * corner)
					if not has_bounds:
						bounds = AABB(local_corner, Vector3.ZERO)
						has_bounds = true
					else:
						bounds = bounds.expand(local_corner)

		for child in node3d.get_children():
			var child3d := child as Node3D
			if child3d == null:
				continue
			pending.append({
				"node": child3d,
				"transform": node_transform * child3d.transform,
			})

	return bounds if has_bounds else AABB()

static func _aabb_corners(aabb: AABB) -> Array:
	var p := aabb.position
	var s := aabb.size
	return [
		p,
		p + Vector3(s.x, 0, 0),
		p + Vector3(0, s.y, 0),
		p + Vector3(0, 0, s.z),
		p + Vector3(s.x, s.y, 0),
		p + Vector3(s.x, 0, s.z),
		p + Vector3(0, s.y, s.z),
		p + s,
	]
