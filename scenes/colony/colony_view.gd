extends Node3D

# Standalone planetary-surface view for the colony module (B1).
# - Run this scene directly: it creates its own Router with the G0 mock navigation, lands on the Moon
#   (or Mars) and advances the fixed 1 s tick itself.
# - Integration: call configure(router, colony_module, colony_id) before/after adding it to the tree.
#   The view then only reads router snapshots and sends commands via router.dispatch();
#   it never edits game state directly, and does not advance the clock.
# The terrain is procedurally GENERATED (not surveyed data) and says so on screen.

signal takeoff_completed

const Schema := preload("res://src/contracts/schema.gd")
const Router := preload("res://src/core/command_router.gd")
const GameState := preload("res://src/core/game_state.gd")
const MockCatalog := preload("res://src/contracts/mocks/mock_catalog.gd")
const MockNavigation := preload("res://src/contracts/mocks/mock_navigation.gd")
const Colony := preload("res://src/colony/colony.gd")
const Terrain := preload("res://src/colony/terrain_generator.gd")

const BODIES := [["sol.earth.moon", "달 (Moon)"], ["sol.mars", "화성 (Mars)"]]
const BUILD_ORDER := ["solar", "miner", "refiner", "warehouse", "lab"]
const BUILD_COLORS := {
	"solar": Color(0.2, 0.4, 0.9), "miner": Color(0.95, 0.75, 0.15), "refiner": Color(0.9, 0.35, 0.2),
	"warehouse": Color(0.65, 0.65, 0.7), "lab": Color(0.25, 0.8, 0.45),
}
const BUILD_SIZES := {
	"solar": Vector3(5.0, 0.6, 5.0), "miner": Vector3(5.0, 4.0, 5.0), "refiner": Vector3(6.0, 5.0, 6.0),
	"warehouse": Vector3(7.0, 4.0, 7.0), "lab": Vector3(5.5, 5.5, 5.5),
}
const RESOURCE_COLORS := {
	"ore": Color(0.85, 0.5, 0.2), "ice": Color(0.6, 0.9, 1.0), "silicon": Color(0.7, 0.5, 0.9),
}
const RESOURCE_KO := {"ore": "광석", "metal": "금속", "ice": "얼음", "silicon": "실리콘", "parts": "부품"}
const HELP_TEXT := "WASD 이동 · Q/E 또는 우클릭 드래그 회전 · 휠 확대/축소 · Shift 빠르게\n" \
		+ "1–5 시설 선택 · 좌클릭 건설 · Esc 선택 해제 · G 격자 · Space 일시정지\n" \
		+ "건설 비용은 기지 재고에서 차감됩니다. 먼저 우주선 화물을 기지로 이전하세요.\n" \
		+ "채굴기는 광석 노드(주황) 위에만 건설합니다. 얼음·실리콘은 정보 표시용입니다."
const TERRAIN_NOTICE := "지형과 자원 매장량은 절차 생성값입니다."

var _router: RefCounted
var _colony_module: RefCounted
var _colony_id := ""
var _owns_router := false
var _state: Dictionary = {}
var _summary: Dictionary = {}
var _dirty := true

var _heights := PackedFloat32Array()
var _cells := 64
var _cell_m := 8.0
var _terrain_node: MeshInstance3D
var _grid_node: MeshInstance3D
var _pad_node: MeshInstance3D
var _sun: DirectionalLight3D
var _entity_root: Node3D
var _deposit_nodes := {}
var _building_nodes := {}
var _ghost: MeshInstance3D
var _camera: Camera3D
var _yaw := 0.6
var _pitch := 0.95
var _distance := 150.0
var _target := Vector3.ZERO
var _dragging := false
var _hover := Vector2i(-1, -1)
var _selected := ""

var _body_option: OptionButton
var _build_buttons := {}
var _preview_label: Label
var _resource_option: OptionButton
var _amount_box: SpinBox
var _transfer_buttons: Array[Button] = []
var _summary_text: RichTextLabel
var _message_label: Label
var _hover_label: Label
var _title_label: Label
var _pause_button: Button
var _land_button: Button
var _takeoff_button: Button


func _ready() -> void:
	_build_world()
	_build_ui()
	if _router == null:
		_start_standalone(BODIES[0][0])
	else:
		_attach()


# Integration entry point. The router must already contain the colony and own the clock.
func configure(router: RefCounted, colony_module: RefCounted, colony_id: String) -> void:
	_router = router
	_colony_module = colony_module
	_colony_id = colony_id
	_owns_router = false
	if is_node_ready():
		_attach()


func _process(delta: float) -> void:
	if _router == null:
		return
	if _owns_router:
		_router.advance(delta)
	if _heights.is_empty():
		return
	_update_camera(delta)
	_update_hover()
	if _dirty:
		_dirty = false
		_refresh()


# ---- session ---------------------------------------------------------------------------------

func _start_standalone(body_id: String) -> void:
	_colony_module = Colony.new()
	var colony: Dictionary = _colony_module.create(body_id, 360)
	if colony.is_empty():
		_show_text("밸런스 데이터를 불러오지 못했습니다. data/balance/colony_balance.json을 확인하세요.", false)
		return
	var state := Schema.new_state(360)
	state["colonies"][colony["id"]] = colony
	state["ship"]["body_id"] = body_id
	state["ship"]["mode"] = Schema.SURFACE
	var game := GameState.new(360)
	_router = Router.new(game, MockNavigation.new(MockCatalog.new()), _colony_module)
	if not _router.restore(state):
		_show_text("독립 실행 상태를 만들지 못했습니다.", false)
		return
	_owns_router = true
	_colony_id = colony["id"]
	_attach()
	_show_text("달/화성 표면 독립 실행입니다. 우주선 화물을 이전한 뒤 시설을 건설하세요.", true)


func _attach() -> void:
	if not _router.state_changed.is_connected(_on_state_changed):
		_router.state_changed.connect(_on_state_changed)
	_state = _router.snapshot()
	_clear_entities()
	_rebuild_terrain()
	_set_selected("")
	_dirty = true


func _on_state_changed(snapshot: Dictionary) -> void:
	_state = snapshot
	_dirty = true


func _colony() -> Dictionary:
	return _state.get("colonies", {}).get(_colony_id, {})


func _on_surface() -> bool:
	var colony := _colony()
	return not colony.is_empty() and _state["ship"]["mode"] == Schema.SURFACE \
			and _state["ship"]["body_id"] == colony["body_id"]


func _send(command: Dictionary) -> Dictionary:
	var result: Dictionary = _router.dispatch(command)
	_show_text(result["message"] if not result["message"].is_empty() else "완료", result["ok"])
	return result


func _show_text(text: String, ok: bool) -> void:
	_message_label.text = text if ok else "오류 · " + text
	_message_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7) if ok else Color(1.0, 0.55, 0.5))


# ---- world -----------------------------------------------------------------------------------

func _build_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02, 0.03, 0.06)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.55, 0.58, 0.68)
	environment.ambient_light_energy = 0.6
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	_sun.shadow_enabled = true
	add_child(_sun)
	_camera = Camera3D.new()
	_camera.far = 4000.0
	_camera.current = true
	add_child(_camera)
	_terrain_node = MeshInstance3D.new()
	add_child(_terrain_node)
	_grid_node = MeshInstance3D.new()
	_grid_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_grid_node)
	_pad_node = MeshInstance3D.new()
	add_child(_pad_node)
	_entity_root = Node3D.new()
	add_child(_entity_root)
	_ghost = MeshInstance3D.new()
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost.visible = false
	add_child(_ghost)


func _rebuild_terrain() -> void:
	var colony := _colony()
	if colony.is_empty():
		return
	var balance: RefCounted = _colony_module.balance
	_cells = balance.data["grid"]["cells"]
	_cell_m = float(balance.data["grid"]["cell_m"])
	_heights = Terrain.generate_heights(colony["seed"], colony["generator_version"], colony["body_id"], balance)
	var profile: Dictionary = balance.terrain_profile(colony["body_id"])
	var ground := _color_of(profile["ground_color"])
	var shade := _color_of(profile["shade_color"])
	var low := 0.0
	var high := 0.0
	for height: float in _heights:
		low = minf(low, height)
		high = maxf(high, height)
	var half := _cells * _cell_m * 0.5
	var stride := _cells + 1
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for vy in range(_cells):
		for vx in range(_cells):
			var a := _vertex(vx, vy, half, stride)
			var b := _vertex(vx + 1, vy, half, stride)
			var c := _vertex(vx, vy + 1, half, stride)
			var d := _vertex(vx + 1, vy + 1, half, stride)
			for triangle: Array in [[a, b, c], [b, d, c]]:
				for point: Vector3 in triangle:
					var t := inverse_lerp(low, high, point.y) if high > low else 0.5
					surface.set_color(shade.lerp(ground, clampf(t * 1.1, 0.0, 1.0)))
					surface.add_vertex(point)
	surface.generate_normals()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_terrain_node.mesh = surface.commit()
	_terrain_node.material_override = material
	_build_grid_lines(half)
	_build_pad(balance)
	_target = Vector3(_pad_position(balance).x, 0.0, _pad_position(balance).z)
	_title_label.text = "기지 · " + str(profile.get("name_ko", colony["body_id"]))


func _vertex(vx: int, vy: int, half: float, stride: int) -> Vector3:
	return Vector3(vx * _cell_m - half, _heights[vy * stride + vx], vy * _cell_m - half)


func _color_of(values: Array) -> Color:
	return Color(float(values[0]), float(values[1]), float(values[2]))


func _build_grid_lines(half: float) -> void:
	var stride := _cells + 1
	var points := PackedVector3Array()
	for line in range(_cells + 1):
		for segment in range(_cells):
			var p1 := _vertex(segment, line, half, stride) + Vector3.UP * 0.12
			var p2 := _vertex(segment + 1, line, half, stride) + Vector3.UP * 0.12
			points.append_array([p1, p2])
			var q1 := _vertex(line, segment, half, stride) + Vector3.UP * 0.12
			var q2 := _vertex(line, segment + 1, half, stride) + Vector3.UP * 0.12
			points.append_array([q1, q2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.16)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_grid_node.mesh = mesh
	_grid_node.material_override = material


func _pad_position(balance: RefCounted) -> Vector3:
	var pad: Array = balance.data["grid"]["landing_pad_cell"]
	return _cell_center(pad[0], pad[1])


func _build_pad(balance: RefCounted) -> void:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = _cell_m * 1.6
	cylinder.bottom_radius = _cell_m * 1.6
	cylinder.height = 0.3
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.85, 0.9)
	_pad_node.mesh = cylinder
	_pad_node.material_override = material
	_pad_node.position = _pad_position(balance) + Vector3.UP * 0.2


func _cell_center(gx: int, gy: int) -> Vector3:
	var half := _cells * _cell_m * 0.5
	var x := (gx + 0.5) * _cell_m - half
	var z := (gy + 0.5) * _cell_m - half
	return Vector3(x, Terrain.height_at(_heights, _cells, _cell_m, x, z), z)


func _clear_entities() -> void:
	for child in _entity_root.get_children():
		child.queue_free()
	_deposit_nodes.clear()
	_building_nodes.clear()


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	return material


func _make_label3d(text: String, height: float) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.095
	label.font_size = 48
	label.outline_size = 12
	label.position = Vector3(0.0, height, 0.0)
	return label


func _sync_entities() -> void:
	var colony := _colony()
	if colony.is_empty():
		return
	var initial: int = _colony_module.balance.data["deposit"]["initial_remaining"]
	for deposit: Dictionary in colony["deposits"]:
		var node: Node3D = _deposit_nodes.get(deposit["id"])
		if node == null:
			node = Node3D.new()
			var mesh := MeshInstance3D.new()
			var cone := CylinderMesh.new()
			cone.top_radius = 0.8
			cone.bottom_radius = 3.2
			cone.height = 3.0
			mesh.mesh = cone
			mesh.material_override = _make_material(RESOURCE_COLORS.get(deposit["resource"], Color.WHITE))
			mesh.position = Vector3(0.0, 1.5, 0.0)
			mesh.name = "Body"
			node.add_child(mesh)
			var label := _make_label3d("", 7.0)
			label.name = "Label"
			node.add_child(label)
			node.position = _cell_center(deposit["grid_x"], deposit["grid_y"])
			_entity_root.add_child(node)
			_deposit_nodes[deposit["id"]] = node
		var fraction := clampf(float(deposit["remaining"]) / float(initial), 0.0, 1.0)
		node.get_node("Body").scale = Vector3(1.0, lerpf(0.25, 1.0, fraction), 1.0)
		var note := "" if deposit["resource"] == "ore" else " (정보용)"
		node.get_node("Label").text = "%s %d%s" % [RESOURCE_KO[deposit["resource"]], deposit["remaining"], note]
	var status := {}
	for entry: Dictionary in _summary.get("buildings", []):
		status[entry["id"]] = entry["status"]
	for building: Dictionary in colony["buildings"]:
		var node: Node3D = _building_nodes.get(building["id"])
		if node == null:
			node = Node3D.new()
			var size: Vector3 = BUILD_SIZES[building["type"]]
			var mesh := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = size
			mesh.mesh = box
			mesh.material_override = _make_material(BUILD_COLORS[building["type"]])
			mesh.position = Vector3(0.0, size.y * 0.5, 0.0)
			mesh.name = "Body"
			node.add_child(mesh)
			var name_ko: String = _colony_module.balance.building(building["type"]).get("name_ko", building["type"])
			var label := _make_label3d(name_ko, size.y + 3.0)
			node.add_child(label)
			node.position = _cell_center(building["grid_x"], building["grid_y"])
			_entity_root.add_child(node)
			_building_nodes[building["id"]] = node
		var material: StandardMaterial3D = node.get_node("Body").material_override
		var stopped: bool = status.get(building["id"], "RUNNING") == "STOPPED"
		material.emission_enabled = stopped
		material.emission = Color(0.9, 0.1, 0.1)
		material.emission_energy_multiplier = 0.7


# ---- camera and picking -----------------------------------------------------------------------

func _update_camera(delta: float) -> void:
	var move := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		move.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		move.y += 1.0
	if Input.is_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		move.x += 1.0
	if Input.is_key_pressed(KEY_Q):
		_yaw -= 1.2 * delta
	if Input.is_key_pressed(KEY_E):
		_yaw += 1.2 * delta
	var speed := _distance * 0.9 * (2.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
	_target += (right * move.x - forward * move.y) * speed * delta
	var half := _cells * _cell_m * 0.5
	_target.x = clampf(_target.x, -half, half)
	_target.z = clampf(_target.z, -half, half)
	_target.y = Terrain.height_at(_heights, _cells, _cell_m, _target.x, _target.z)
	var offset := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	_camera.look_at_from_position(_target + offset, _target, Vector3.UP)


func _pick_cell() -> Vector2i:
	var mouse := get_viewport().get_mouse_position()
	var origin := _camera.project_ray_origin(mouse)
	var direction := _camera.project_ray_normal(mouse)
	var half := _cells * _cell_m * 0.5
	var previous := 0.0
	var distance := 0.0
	while distance < 2500.0:
		var point := origin + direction * distance
		if point.y <= Terrain.height_at(_heights, _cells, _cell_m, point.x, point.z):
			var near := previous
			var far := distance
			for _i in range(10):
				var middle := (near + far) * 0.5
				var probe := origin + direction * middle
				if probe.y <= Terrain.height_at(_heights, _cells, _cell_m, probe.x, probe.z):
					far = middle
				else:
					near = middle
			var hit := origin + direction * far
			if absf(hit.x) >= half or absf(hit.z) >= half:
				return Vector2i(-1, -1)
			return Vector2i(int((hit.x + half) / _cell_m), int((hit.z + half) / _cell_m))
		previous = distance
		distance += 2.0
	return Vector2i(-1, -1)


func _update_hover() -> void:
	if _heights.is_empty():
		return
	if get_viewport().gui_get_hovered_control() != null or _dragging:
		if not _dragging:
			_hover = Vector2i(-1, -1)
	else:
		_hover = _pick_cell()
	_update_ghost()


func _cell_deposit(cell: Vector2i) -> Dictionary:
	for deposit: Dictionary in _colony().get("deposits", []):
		if deposit["grid_x"] == cell.x and deposit["grid_y"] == cell.y:
			return deposit
	return {}


func _cell_problem(cell: Vector2i) -> Dictionary:
	if _selected.is_empty() or _hover.x < 0:
		return {}
	var deposit := _cell_deposit(cell)
	var deposit_id: Variant = deposit.get("id") if _selected == "miner" else null
	var problem: Dictionary = _colony_module.placement_problem(_colony(), _selected, cell.x, cell.y, deposit_id)
	if problem.is_empty():
		var shortage: Dictionary = _colony_module.cost_shortage(_colony(), _selected)
		if not shortage.is_empty():
			return {"code": "INSUFFICIENT_RESOURCE", "message": "기지 재고가 부족합니다. 우주선에서 이전하세요."}
	return problem


func _update_ghost() -> void:
	var colony := _colony()
	if colony.is_empty() or _hover.x < 0:
		_ghost.visible = false
		_hover_label.text = "칸을 가리키면 정보가 표시됩니다."
		return
	var pad: Array = _colony_module.balance.data["grid"]["landing_pad_cell"]
	var text := "칸 (%d, %d) · 착륙대 기준 (%d m, %d m)" % [
		_hover.x, _hover.y, (_hover.x - pad[0]) * int(_cell_m), (_hover.y - pad[1]) * int(_cell_m)]
	var deposit := _cell_deposit(_hover)
	if not deposit.is_empty():
		text += " · %s 노드 %s 잔량 %d" % [RESOURCE_KO[deposit["resource"]], deposit["id"], deposit["remaining"]]
	for building: Dictionary in colony["buildings"]:
		if building["grid_x"] == _hover.x and building["grid_y"] == _hover.y:
			text += " · 시설 %s (%s)" % [building["id"], building["type"]]
	_hover_label.text = text
	if _selected.is_empty():
		_ghost.visible = false
		return
	var problem := _cell_problem(_hover)
	var box := BoxMesh.new()
	var size: Vector3 = BUILD_SIZES[_selected]
	box.size = size
	_ghost.mesh = box
	var color: Color = Color(0.3, 1.0, 0.4, 0.45) if problem.is_empty() else Color(1.0, 0.3, 0.25, 0.45)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost.material_override = material
	_ghost.position = _cell_center(_hover.x, _hover.y) + Vector3(0.0, size.y * 0.5, 0.0)
	_ghost.visible = true
	if not problem.is_empty():
		_hover_label.text += " · 건설 불가: " + problem["message"]


# ---- input ----------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _router == null:
		return
	if event is InputEventMouseMotion and _dragging:
		_yaw -= event.relative.x * 0.005
		_pitch = clampf(_pitch + event.relative.y * 0.005, 0.25, 1.45)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_distance = clampf(_distance * 0.9, 30.0, 700.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				_distance = clampf(_distance * 1.1, 30.0, 700.0)
			MOUSE_BUTTON_LEFT:
				_place_at_hover()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_dragging = event.pressed
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
				_set_selected(BUILD_ORDER[event.keycode - KEY_1])
			KEY_ESCAPE:
				_set_selected("")
			KEY_G:
				_grid_node.visible = not _grid_node.visible
			KEY_SPACE:
				_toggle_pause()


func _place_at_hover() -> void:
	if _selected.is_empty() or _hover.x < 0:
		return
	var deposit := _cell_deposit(_hover)
	var deposit_id: Variant = deposit.get("id") if _selected == "miner" else null
	_send({
		"type": "BUILD", "colony_id": _colony_id, "building_type": _selected,
		"grid_x": _hover.x, "grid_y": _hover.y, "deposit_id": deposit_id,
	})


func _set_selected(type: String) -> void:
	_selected = type
	for key: String in _build_buttons:
		_build_buttons[key].set_pressed_no_signal(key == type)
	_update_preview()
	_dirty = true


func _toggle_pause() -> void:
	_send({"type": "SET_PAUSED", "paused": not _state.get("paused", false)})


# ---- ui ------------------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	layer.add_child(margin)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(column)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(row)
	row.add_child(_build_left_panel())
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_build_right_panel())
	var status_panel := _ui_panel()
	status_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(status_panel)
	var status_box := VBoxContainer.new()
	status_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_panel.add_child(status_box)
	_hover_label = Label.new()
	_hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	status_box.add_child(_hover_label)
	_message_label = Label.new()
	_message_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.accessibility_live = 1
	status_box.add_child(_message_label)


func _button(text: String, callback: Callable, toggle: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = toggle
	if not toggle:
		button.pressed.connect(callback)
	return button


func _panel(width: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(width, 0.0)
	return box


func _ui_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#111b2a")
	style.border_color = Color("#33455c")
	style.set_corner_radius_all(7)
	for side: Side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, 9.0)
		style.set_border_width(side, 1)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _build_left_panel() -> Control:
	var panel := _ui_panel()
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var box := _panel(330.0)
	panel.add_child(box)
	_title_label = Label.new()
	_title_label.text = "기지"
	box.add_child(_title_label)
	box.add_child(_notice(TERRAIN_NOTICE))
	var heading := Label.new()
	heading.text = "건설 (1–5, 좌클릭으로 배치)"
	box.add_child(heading)
	for index in range(BUILD_ORDER.size()):
		var type: String = BUILD_ORDER[index]
		var button := _button("", Callable(), true)
		button.toggled.connect(_on_build_toggled.bind(type))
		_build_buttons[type] = button
		box.add_child(button)
	_preview_label = Label.new()
	_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_preview_label)
	box.add_child(HSeparator.new())
	var transfer := Label.new()
	transfer.text = "자원 이전 (우주선 ⇄ 기지)"
	box.add_child(transfer)
	var transfer_row := HBoxContainer.new()
	_resource_option = OptionButton.new()
	var resources: Array = Schema.RESOURCES
	for index in range(resources.size()):
		_resource_option.add_item(RESOURCE_KO[resources[index]], index)
		_resource_option.set_item_metadata(index, resources[index])
	transfer_row.add_child(_resource_option)
	_amount_box = SpinBox.new()
	_amount_box.min_value = 1
	_amount_box.max_value = 200
	_amount_box.step = 1
	_amount_box.value = 10
	transfer_row.add_child(_amount_box)
	box.add_child(transfer_row)
	var direction_row := HBoxContainer.new()
	var to_colony := _button("→ 기지로", _transfer.bind("ship_to_colony"))
	var to_ship := _button("← 우주선으로", _transfer.bind("colony_to_ship"))
	_transfer_buttons = [to_colony, to_ship]
	direction_row.add_child(to_colony)
	direction_row.add_child(to_ship)
	box.add_child(direction_row)
	box.add_child(HSeparator.new())
	var help := Label.new()
	help.text = HELP_TEXT
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", 12)
	box.add_child(help)
	return panel


func _build_right_panel() -> Control:
	var panel := _ui_panel()
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var box := _panel(380.0)
	panel.add_child(box)
	var top := HBoxContainer.new()
	for speed in Schema.SPEEDS:
		top.add_child(_button("%d×" % speed, _set_speed.bind(speed)))
	_pause_button = _button("일시정지", _toggle_pause)
	top.add_child(_pause_button)
	box.add_child(top)
	var action_row := HBoxContainer.new()
	_takeoff_button = _button("이륙 (TAKEOFF)", _takeoff)
	_land_button = _button("착륙 (LAND)", _land)
	action_row.add_child(_takeoff_button)
	action_row.add_child(_land_button)
	_body_option = OptionButton.new()
	for index in range(BODIES.size()):
		_body_option.add_item("독립 실행: " + BODIES[index][1], index)
	_body_option.item_selected.connect(_on_body_selected)
	action_row.add_child(_body_option)
	box.add_child(action_row)
	_summary_text = RichTextLabel.new()
	_summary_text.bbcode_enabled = true
	_summary_text.custom_minimum_size = Vector2(380.0, 470.0)
	_summary_text.scroll_following = false
	box.add_child(_summary_text)
	return panel


func _notice(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	label.add_theme_font_size_override("font_size", 12)
	return label


func _on_build_toggled(pressed: bool, type: String) -> void:
	if pressed:
		_set_selected(type)
	elif _selected == type:
		_set_selected("")


func _on_body_selected(index: int) -> void:
	if _owns_router:
		_start_standalone(BODIES[index][0])


func _set_speed(speed: int) -> void:
	_send({"type": "SET_SPEED", "speed": speed})


func _transfer(direction: String) -> void:
	var resource: String = _resource_option.get_item_metadata(_resource_option.selected)
	_send({
		"type": "TRANSFER", "colony_id": _colony_id, "resource": resource,
		"amount": int(_amount_box.value), "direction": direction,
	})


func _takeoff() -> void:
	if _send({"type": "TAKEOFF"})["ok"]:
		takeoff_completed.emit()


func _land() -> void:
	_send({"type": "LAND", "body_id": _colony()["body_id"]})


func _update_preview() -> void:
	if _colony_module == null:
		return
	if _selected.is_empty():
		_preview_label.text = "시설을 선택하면 비용과 효과가 표시됩니다."
		return
	var info: Dictionary = _colony_module.balance.building(_selected)
	var lines: PackedStringArray = ["%s — 비용: %s" % [info["name_ko"], _format_amounts(info["cost"])]]
	if info.has("power_supply"):
		lines.append("전력 +%d/tick" % info["power_supply"])
	if info.has("power_use"):
		lines.append("전력 -%d/tick" % info["power_use"])
	if info.has("capacity_bonus"):
		lines.append("저장 용량 +%d" % info["capacity_bonus"])
	if info.has("mine_rate"):
		lines.append("광석 +%d/tick (노드 잔량 차감)" % info["mine_rate"])
	if info.has("input") and info.has("output"):
		lines.append("%s → %s" % [_format_amounts(info["input"]), _format_amounts(info["output"])])
	if info.has("research_output"):
		lines.append("%s → 연구 +%d" % [_format_amounts(info["input"]), info["research_output"]])
	var colony := _colony()
	if not colony.is_empty():
		var shortage: Dictionary = _colony_module.cost_shortage(colony, _selected)
		lines.append("기지 재고 충분" if shortage.is_empty() else "재고 부족: " + _format_amounts(shortage))
	_preview_label.text = "\n".join(lines)


func _format_amounts(amounts: Dictionary) -> String:
	var parts: PackedStringArray = []
	for resource: String in amounts:
		parts.append("%s %d" % [RESOURCE_KO.get(resource, resource), amounts[resource]])
	return ", ".join(parts)


func _refresh() -> void:
	var colony := _colony()
	if colony.is_empty():
		return
	_summary = _colony_module.summarize(_state, _colony_id)
	_sync_entities()
	_update_preview()
	var surface := _on_surface()
	for key: String in _build_buttons:
		var info: Dictionary = _colony_module.balance.building(key)
		var button: Button = _build_buttons[key]
		button.text = "%d  %s  (%s)" % [BUILD_ORDER.find(key) + 1, info["name_ko"], _format_amounts(info["cost"])]
		button.disabled = not surface
	for button in _transfer_buttons:
		button.disabled = not surface
	_takeoff_button.disabled = not surface
	_land_button.disabled = _state["ship"]["mode"] != Schema.ORBIT
	_body_option.visible = _owns_router
	_pause_button.text = "재개" if _state["paused"] else "일시정지"
	_summary_text.text = _summary_bbcode()


func _summary_bbcode() -> String:
	var s := _summary
	var ship: Dictionary = _state["ship"]
	var lines: PackedStringArray = []
	var mode_text := {"SURFACE": "표면", "ORBIT": "궤도", "FLIGHT": "비행 중"}
	lines.append("[b]기지 요약[/b]  tick %d · %d× %s · 우주선: %s" % [
		_state["tick"], _state["speed"], "(일시정지)" if _state["paused"] else "", mode_text.get(ship["mode"], ship["mode"])])
	if ship["mode"] != Schema.SURFACE:
		lines.append("[color=orange]우주선이 표면에 없어도 기지는 계속 생산합니다. 건설·이전은 착륙 후 가능합니다.[/color]")
	lines.append("")
	lines.append("[b]재고[/b] (기지 / 우주선)")
	for resource: String in Schema.RESOURCES:
		lines.append("  %s  %d / %d" % [RESOURCE_KO[resource], s["inventory"][resource], ship["cargo"].get(resource, 0)])
	lines.append("저장 공간 %d / %d · 우주선 화물 %d / %d" % [
		s["used_storage"], s["capacity"], s["ship_cargo_total"], s["ship_cargo_limit"]])
	lines.append("")
	lines.append("[b]전력[/b] 공급 %d · 사용 %d (다음 tick 예측)" % [s["power_supply"], s["power_used"]])
	lines.append("[b]연구[/b] 전역 %d / 해금 %d · 이 기지 기여 %d · 채굴 속도 %d/tick%s" % [
		s["research_global"], s["research_threshold"], s["research_colony"], s["miner_rate"],
		" [color=lime](채굴 효율 해금)[/color]" if s["mining_unlocked"] else ""])
	lines.append("")
	lines.append("[b]노드 잔량[/b]")
	for resource: String in ["ore", "ice", "silicon"]:
		var note := "" if resource == "ore" else " (정보용, P0 채굴 불가)"
		lines.append("  %s %d%s" % [RESOURCE_KO[resource], s["deposit_remaining"].get(resource, 0), note])
	lines.append("")
	lines.append("[b]시설 %d기[/b]" % s["buildings"].size())
	for entry: Dictionary in s["buildings"]:
		var state_text := "[color=#ffad9d]정지 · %s[/color]" % entry["reason_ko"]
		if entry["status"] == "PASSIVE":
			state_text = "보관 중"
		elif entry["status"] == "RUNNING":
			state_text = "[color=#91edac]가동 중[/color]"
			if not entry["produced"].is_empty():
				state_text += " · " + _format_amounts(entry["produced"]) + "/tick"
			elif entry["research_output"] > 0:
				state_text += " · 연구 %d/tick" % entry["research_output"]
		lines.append("  %s %s (%d,%d) %s" % [entry["id"], entry["name_ko"], entry["grid_x"], entry["grid_y"], state_text])
	return "\n".join(lines)
