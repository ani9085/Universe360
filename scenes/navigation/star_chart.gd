extends Node3D

const Schema := preload("res://src/contracts/schema.gd")
const OrbitModel := preload("res://src/navigation/orbit_model.gd")
const Navigation := preload("res://src/navigation/navigation.gd")
const COLORS := {
	"sol": Color("#ffab5b"), "sol.mercury": Color("#b6aea7"), "sol.venus": Color("#efc68c"),
	"sol.earth": Color("#71a7fd"), "sol.earth.moon": Color("#c7cddd"), "sol.mars": Color("#d9856c"),
	"sol.jupiter": Color("#e2a382"), "sol.saturn": Color("#ead09d"), "sol.uranus": Color("#91d5d1"),
	"sol.neptune": Color("#7797e8"),
}

var _model: OrbitModel
var _camera := Camera3D.new()
var _markers := {}
var _paths := {}
var _selection := MeshInstance3D.new()
var _ship := Node3D.new()
var _yaw := -0.32
var _pitch := 0.88
var _view_width := 138.0
var _manual_offset := Vector3.ZERO
var _manual_heading := 0.0
var _ship_anchor := Vector3.ZERO
var _guide_heading := 0.0
var _selected_id := ""
var _font := SystemFont.new()


func _ready() -> void:
	_font.font_names = PackedStringArray(["Malgun Gothic", "Noto Sans CJK KR"])
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#0b1220")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#c9d7e7")
	environment.ambient_light_energy = 0.55
	world.environment = environment
	add_child(world)

	var light := DirectionalLight3D.new()
	add_child(light)
	light.rotation_degrees = Vector3(-50, -32, 0)
	light.light_energy = 0.9

	add_child(_camera)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_WIDTH
	_camera.current = true
	_update_camera()

	_selection.mesh = _orbit_ring(1.0)
	_selection.material_override = _material(Color("#84dbe9"), true)
	_selection.visible = false
	add_child(_selection)

	var arrow := CylinderMesh.new()
	arrow.top_radius = 0.0
	arrow.bottom_radius = 0.55
	arrow.height = 1.7
	arrow.radial_segments = 3
	var marker := MeshInstance3D.new()
	marker.mesh = arrow
	marker.material_override = _material(Color("#8ff0d4"), true)
	marker.rotation.x = PI / 2.0
	_ship.add_child(marker)
	add_child(_ship)
	_ship.visible = false
	_add_star_field()


func set_model(model: OrbitModel) -> void:
	_model = model
	for node: Node3D in _markers.values() + _paths.values():
		node.queue_free()
	_markers.clear()
	_paths.clear()
	for body: Dictionary in model.system_bodies():
		var id: String = body["id"]
		var marker := _make_body(body)
		add_child(marker)
		_markers[id] = marker
		if body["parent_id"] != null:
			var path := MeshInstance3D.new()
			path.mesh = _orbit_ring(model.visual_orbit_radius(body))
			path.material_override = _material(Color("#304665"), true)
			add_child(path)
			_paths[id] = path
	_place_bodies(0)


func show_state(state: Dictionary) -> void:
	if _model == null or state.is_empty():
		return
	_place_bodies(state["tick"])
	var ship: Dictionary = state["ship"]
	var marker: Node3D = _markers.get(ship["body_id"])
	_ship.visible = marker != null
	if marker == null:
		return
	_ship_anchor = marker.position + Vector3(0.0, 2.1, 0.0)
	if ship["mode"] == Schema.FLIGHT:
		var destination: Node3D = _markers.get(ship["destination_id"])
		if destination != null:
			var route := Navigation.route(ship["destination_id"])
			var fraction := 1.0 - float(ship["travel_ticks_remaining"]) / float(route.get("ticks", 1))
			var target := destination.position + Vector3(0.0, 2.1, 0.0)
			var heading := target - _ship_anchor
			_guide_heading = atan2(heading.x, heading.z)
			_ship_anchor = _ship_anchor.lerp(target, clampf(fraction, 0.0, 1.0))
	else:
		_guide_heading = 0.0
	_update_ship()


func select_body(id: String) -> void:
	_selected_id = id
	_update_selection()


func pick(point: Vector2) -> String:
	var nearest := ""
	var best := INF
	for id: String in _markers:
		var marker: Node3D = _markers[id]
		if _camera.is_position_behind(marker.position):
			continue
		var distance := point.distance_to(_camera.unproject_position(marker.position))
		var radius := float(marker.get_meta("radius"))
		var pick_size := maxf(14.0, radius * get_viewport().get_visible_rect().size.x / _view_width + 6.0)
		if distance <= pick_size and distance < best:
			nearest = id
			best = distance
	return nearest


func point_for_body(id: String) -> Vector2:
	var marker: Node3D = _markers.get(id)
	return Vector2(-1.0, -1.0) if marker == null else _camera.unproject_position(marker.position)


func rotate_camera(relative: Vector2) -> void:
	_yaw -= relative.x * 0.007
	_pitch = clampf(_pitch + relative.y * 0.007, 0.18, 1.48)
	_update_camera()


func zoom(factor: float) -> void:
	_view_width = clampf(_view_width * factor, 35.0, 200.0)
	_update_camera()


func steer(turn: int, thrust: int, delta: float) -> void:
	_manual_heading = wrapf(_manual_heading + turn * delta * 2.2, -PI, PI)
	var heading := _guide_heading + _manual_heading
	_manual_offset += Vector3(sin(heading), 0.0, cos(heading)) * thrust * delta * 5.0
	_manual_offset = _manual_offset.limit_length(5.0)
	_update_ship()


func stop_steering() -> void:
	_manual_offset = Vector3.ZERO
	_manual_heading = 0.0
	_update_ship()


func _place_bodies(tick: int) -> void:
	for id: String in _markers:
		_markers[id].position = _model.visual_position(id, tick)
		if _paths.has(id):
			var parent: String = _model_body(id)["parent_id"]
			_paths[id].position = _model.visual_position(parent, tick)
	_update_selection()


func _update_selection() -> void:
	var marker: Node3D = _markers.get(_selected_id)
	_selection.visible = marker != null
	if marker != null:
		_selection.position = marker.position + Vector3(0.0, 0.08, 0.0)
		_selection.scale = Vector3.ONE * (float(marker.get_meta("radius")) + 0.76)


func _update_ship() -> void:
	_ship.position = _ship_anchor + _manual_offset
	_ship.rotation.y = _guide_heading + _manual_heading


func _update_camera() -> void:
	_camera.size = _view_width
	var ground := cos(_pitch) * 150.0
	_camera.position = Vector3(sin(_yaw) * ground, sin(_pitch) * 150.0, cos(_yaw) * ground)
	_camera.look_at(Vector3.ZERO)


func _make_body(body: Dictionary) -> Node3D:
	var node := Node3D.new()
	var id: String = body["id"]
	var radius := _model.visual_body_radius(body)
	node.set_meta("radius", radius)
	node.set_meta("body", body)
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere
	mesh.material_override = _material(COLORS.get(id, Color.WHITE), id == "sol")
	node.add_child(mesh)
	if id == "sol.saturn":
		var ring := MeshInstance3D.new()
		ring.mesh = _orbit_ring(radius * 1.62)
		ring.material_override = _material(Color("#b4a178"), true)
		ring.rotation.z = -0.32
		node.add_child(ring)
	var label := Label3D.new()
	label.position = Vector3(0.0, radius + 0.7, 0.0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font = _font
	label.font_size = 24
	label.pixel_size = 0.085
	label.outline_size = 5
	label.modulate = Color("#e2eaf6")
	label.outline_modulate = Color("#09121d")
	label.text = body["name"].get_slice(" (", 0)
	node.add_child(label)
	return node


func _model_body(id: String) -> Dictionary:
	return _markers[id].get_meta("body")


func _orbit_ring(radius: float) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(129):
		var phase := TAU * i / 128.0
		mesh.surface_add_vertex(Vector3(cos(phase) * radius, 0.0, sin(phase) * radius))
	mesh.surface_end()
	return mesh


func _add_star_field() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 360
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_POINTS)
	for index in range(220):
		mesh.surface_add_vertex(Vector3(random.randf_range(-106, 106), -7.0, random.randf_range(-120, 120)))
	mesh.surface_end()
	var stars := MeshInstance3D.new()
	stars.mesh = mesh
	stars.material_override = _material(Color("#546988"), true)
	add_child(stars)


func _material(color: Color, unshaded: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	if unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material
