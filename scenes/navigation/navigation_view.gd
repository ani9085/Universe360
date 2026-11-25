extends Control

signal command_completed(result: Dictionary)

const Schema := preload("res://src/contracts/schema.gd")
const Catalog := preload("res://src/catalog/catalog.gd")
const OrbitModel := preload("res://src/navigation/orbit_model.gd")
const Navigation := preload("res://src/navigation/navigation.gd")
const StarChart := preload("res://scenes/navigation/star_chart.gd")
const FOREGROUND := Color("#e9f1ff")
const MUTED := Color("#adbed4")
const ACCENT := Color("#8adfe9")
const SOURCE_LABELS := {
	"radius_km": "반지름", "orbit_radius_km": "공전 장반경", "distance_ly": "태양 기준 거리",
	"mass_kg": "질량", "position": "위치 모델", "landable": "착륙 규칙",
}

var _catalog: Catalog
var _orbit: OrbitModel
var _dispatch: Callable
var _state: Dictionary = {}
var _selected_id := ""
var _ids: Array[String] = []
var _star_chart := StarChart.new()
var _map: SubViewportContainer
var _selector: OptionButton
var _ship: Label
var _detail_name: Label
var _details: Label
var _route: Label
var _sources: VBoxContainer
var _feedback: Label
var _travel: Button
var _land: Button
var _takeoff: Button
var _dragging := false


func _ready() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Noto Sans CJK KR"])
	theme = Theme.new()
	theme.default_font = font
	theme.default_font_size = 17

	var background := ColorRect.new()
	background.color = Color("#080e19")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var frame := MarginContainer.new()
	add_child(frame)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge: String in ["left", "right", "top", "bottom"]:
		frame.add_theme_constant_override("margin_" + edge, 22)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	frame.add_child(page)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 20)
	page.add_child(header)
	var title := _label("태양계 항법", 35, FOREGROUND)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_ship = _label("", 16, MUTED)
	_ship.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_ship)

	var workspace := HSplitContainer.new()
	workspace.dragger_visibility = SplitContainer.DRAGGER_HIDDEN_COLLAPSED
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(workspace)
	_build_map(workspace)
	_build_details(workspace)


func attach(catalog: Catalog, dispatch: Callable) -> void:
	_catalog = catalog
	_dispatch = dispatch
	_orbit = OrbitModel.new(catalog)
	_star_chart.set_model(_orbit)
	_selector.clear()
	_ids.clear()
	for body: Dictionary in _orbit.system_bodies():
		_add_choice(body)
	for body: Dictionary in _catalog.list_bodies(""):
		if body["id"] != "sol":
			_add_choice(body)
	if not catalog.error.is_empty():
		_feedback.text = catalog.error
		return
	select_body(Schema.EARTH)


func show_state(state: Dictionary) -> void:
	_state = state.duplicate(true)
	var ship: Dictionary = _state["ship"]
	var current := _catalog.get_body(ship["body_id"])
	var mode := "궤도"
	if ship["mode"] == Schema.FLIGHT:
		var target := _catalog.get_body(ship["destination_id"])
		mode = "→ %s · %d초 남음" % [target.get("name", ship["destination_id"]), ship["travel_ticks_remaining"]]
	elif ship["mode"] == Schema.SURFACE:
		mode = "표면"
	_ship.text = "%s · %s\n연료 %d  /  경과 %d초%s" % [
		current.get("name", ship["body_id"]), mode, ship["fuel"], state["tick"],
		" · 일시정지" if state["paused"] else "",
	]
	_star_chart.show_state(_state)
	_refresh_selection()


func select_body(id: String) -> void:
	var index := _ids.find(id)
	if index < 0:
		return
	_selected_id = id
	_selector.select(index)
	_star_chart.select_body(id)
	_render_sources(_catalog.get_body(id)["provenance"])
	_refresh_selection()


func selected_body_id() -> String:
	return _selected_id


func marker_position(body_id: String) -> Vector2:
	return _star_chart.point_for_body(body_id)


func _build_map(parent: Container) -> void:
	var map_panel := _panel(Color("#0b1220"))
	map_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_panel.custom_minimum_size.x = 420
	parent.add_child(map_panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	map_panel.add_child(layout)
	var scale_note := _label("축척 왜곡 · 궤도 거리는 압축하고 천체는 확대했습니다.", 16, ACCENT)
	layout.add_child(scale_note)

	_map = SubViewportContainer.new()
	_map.stretch = true
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map.mouse_default_cursor_shape = Control.CURSOR_CROSS
	layout.add_child(_map)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	viewport.msaa_3d = Viewport.MSAA_2X
	_map.add_child(viewport)
	viewport.add_child(_star_chart)
	_map.gui_input.connect(_on_chart_input)
	layout.add_child(_label("클릭 선택  ·  우클릭 드래그 회전  ·  휠 확대  ·  WASD 기동  ·  Space 정지", 15, MUTED))


func _build_details(parent: Container) -> void:
	var options := _panel(Color("#101b2b"))
	options.custom_minimum_size.x = 352
	parent.add_child(options)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	options.add_child(scroll)
	var details := VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", 9)
	scroll.add_child(details)

	details.add_child(_label("천체 선택", 15, MUTED))
	_selector = OptionButton.new()
	_selector.custom_minimum_size.y = 42
	_selector.accessibility_name = "천체 선택"
	_selector.item_selected.connect(func(index: int) -> void: select_body(_ids[index]))
	details.add_child(_selector)
	_detail_name = _label("", 24, FOREGROUND)
	_detail_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.add_child(_detail_name)
	_details = _label("", 15, MUTED)
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.add_child(_details)

	details.add_child(HSeparator.new())
	_route = _label("", 16, ACCENT)
	_route.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.add_child(_route)
	var commands := HBoxContainer.new()
	commands.add_theme_constant_override("separation", 7)
	details.add_child(commands)
	_travel = _command_button(commands, "자동 항법", "TRAVEL")
	_land = _command_button(commands, "착륙", "LAND")
	_takeoff = _command_button(commands, "이륙", "TAKEOFF")
	_feedback = _label("", 15, FOREGROUND)
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.accessibility_live = 1
	details.add_child(_feedback)

	details.add_child(HSeparator.new())
	_sources = VBoxContainer.new()
	_sources.add_theme_constant_override("separation", 5)
	details.add_child(_sources)


func _render_sources(provenance: Dictionary) -> void:
	for node: Node in _sources.get_children():
		_sources.remove_child(node)
		node.queue_free()
	_sources.add_child(_label("데이터 출처", 16, FOREGROUND))
	for field: String in SOURCE_LABELS:
		if not provenance.has(field):
			continue
		var source: Dictionary = provenance[field]
		var url: Variant = source["source_url"]
		var status := "관측 기반" if source["data_status"] == "observed" else "모델"
		if url == null:
			_sources.add_child(_label("%s · 게임 규칙" % SOURCE_LABELS[field], 14, MUTED))
			continue
		var link := LinkButton.new()
		link.uri = url
		link.text = "%s · %s · %s" % [SOURCE_LABELS[field], status, _publisher(url)]
		link.tooltip_text = "%s\n확인일 %s\n%s" % [url, source["retrieved_at"], source["license_note"]]
		link.add_theme_color_override("font_color", ACCENT)
		link.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_sources.add_child(link)


func _refresh_selection() -> void:
	if _state.is_empty() or _selected_id.is_empty():
		return
	var body := _catalog.get_body(_selected_id)
	var ship: Dictionary = _state["ship"]
	var destination := Navigation.route(_selected_id)
	_detail_name.text = body["name"]
	var lines: Array[String] = ["반지름  %s" % _number(body["radius_km"], "km", 2)]
	if body["distance_ly"] != null:
		lines.append("태양 기준 거리  %s" % _number(body["distance_ly"], "광년", 2))
	else:
		lines.append("공전 장반경  %s" % _number(body["orbit_radius_km"], "km"))
		var distance: Variant = _orbit.distance_km(ship["body_id"], _selected_id, _state["tick"])
		lines.append("현재 천체 기준 모델 거리  %s" % _number(distance, "km"))
	var mass: Variant = _catalog.get_details(_selected_id)["mass_kg"]
	lines.append("질량  %s" % _mass(mass))
	lines.append("착륙  %s" % ("가능" if body["landable"] else "불가"))
	_details.text = "\n".join(lines)
	_route.text = "지도 탐색만 가능" if destination.is_empty() else "연료 %d · 게임 시간 %d초" % [
		destination["fuel"], destination["ticks"],
	]
	if body["distance_ly"] == null:
		_route.text += "\n원형 공전 모델 · J2000"
		_route.tooltip_text = OrbitModel.J2000
	else:
		_route.tooltip_text = ""
	var orbiting: bool = ship["mode"] == Schema.ORBIT
	var at_selected: bool = ship["body_id"] == _selected_id
	_travel.disabled = not orbiting or at_selected or destination.is_empty()
	_land.disabled = not orbiting or not at_selected or not body["landable"]
	_takeoff.disabled = ship["mode"] != Schema.SURFACE


func _on_chart_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = event.pressed
		elif event.pressed:
			match event.button_index:
				MOUSE_BUTTON_LEFT: select_body(_star_chart.pick(event.position))
				MOUSE_BUTTON_WHEEL_UP: _star_chart.zoom(0.86)
				MOUSE_BUTTON_WHEEL_DOWN: _star_chart.zoom(1.16)
	elif event is InputEventMouseMotion and _dragging:
		_star_chart.rotate_camera(event.relative)


func _process(delta: float) -> void:
	if not is_visible_in_tree() or not _map.get_global_rect().has_point(get_global_mouse_position()):
		return
	var turn := int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A))
	var thrust := int(Input.is_physical_key_pressed(KEY_W)) - int(Input.is_physical_key_pressed(KEY_S))
	if turn != 0 or thrust != 0:
		_star_chart.steer(turn, thrust, delta)


func _unhandled_key_input(event: InputEvent) -> void:
	if is_visible_in_tree() and event is InputEventKey and event.physical_keycode == KEY_SPACE and event.pressed:
		_star_chart.stop_steering()
		get_viewport().set_input_as_handled()


func _issue(type: String) -> void:
	if not _dispatch.is_valid():
		return
	var order := {"type": type}
	if type != "TAKEOFF":
		order["body_id"] = _selected_id
	var result: Dictionary = _dispatch.call(order)
	_feedback.text = result["message"]
	_feedback.modulate = Color.WHITE if result["ok"] else Color("#ffb3a3")
	command_completed.emit(result)


func _add_choice(body: Dictionary) -> void:
	_ids.append(body["id"])
	_selector.add_item(body["name"])


func _command_button(parent: HBoxContainer, title: String, command: String) -> Button:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size.y = 44
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_issue.bind(command))
	parent.add_child(button)
	return button


func _panel(color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(7)
	for side: Side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, 13.0)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _label(value: String, size_px: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", color)
	return label


func _number(value: Variant, unit: String, decimals: int = 0) -> String:
	return "자료 없음" if value == null else "%s %s" % [String.num(value, decimals), unit]


func _mass(value: Variant) -> String:
	if value == null:
		return "자료 없음"
	var exponent := floori(log(value) / log(10.0))
	return "%.4f × 10^%d kg" % [value / pow(10.0, exponent), exponent]


func _publisher(url: String) -> String:
	if url.begins_with("https://ssd.jpl.nasa.gov"):
		return "NASA/JPL"
	if url.begins_with("https://www.esa.int"):
		return "ESA"
	return "NASA"
