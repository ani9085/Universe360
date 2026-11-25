extends Control

const Schema = preload("res://src/contracts/schema.gd")
const Catalog = preload("res://src/catalog/catalog.gd")
const Navigation = preload("res://src/navigation/navigation.gd")
const Colony = preload("res://src/colony/colony.gd")
const GameState = preload("res://src/core/game_state.gd")
const Router = preload("res://src/core/command_router.gd")
const SaveStore = preload("res://src/core/save_store.gd")
const PilotView = preload("res://scenes/expedition/pilot_view.gd")
const FirstMine = preload("res://scenes/expedition/first_mine.gd")
const SurfaceView = preload("res://scenes/colony/colony_view.gd")
const SurfaceScene = preload("res://scenes/colony/colony_view.tscn")
const BODY_NAMES := {Schema.EARTH: "지구", Schema.MOON: "달", Schema.MARS: "화성"}
const FLIGHT_RATE := 6.0
const LIGHT := Color("#edf6ff")
const MUTED := Color("#b1c4d6")
const MINT := Color("#73e8da")
const ORE := Color("#ffd181")

var _catalog := Catalog.new()
var _colony := Colony.new()
var _router := Router.new(GameState.new(), Navigation.new(_catalog), _colony)
var _store := SaveStore.new("user://expedition_v1.json")
var _pilot: PilotView
var _surface: SurfaceView
var _surface_id := ""
var _snapshot: Dictionary = {}
var _target := Schema.MOON
var _ore_deposit: Dictionary = {}
var _action := ""
var _playing := false
var _managing := false
var _dirty := true
var _intro: PanelContainer
var _launch_button: Button
var _resume: Button
var _intro_status: Label
var _top: HBoxContainer
var _location: Label
var _map_buttons: HBoxContainer
var _mission: PanelContainer
var _tag: Label
var _heading: Label
var _help: Label
var _feedback: Label
var _primary: Button
var _management: Button
var _return_button: Button


func _ready() -> void:
	_build_ui()
	_router.state_changed.connect(_state_changed)
	_snapshot = _router.snapshot()
	_show_intro()


func _process(delta: float) -> void:
	if _playing:
		var fast: bool = _snapshot["ship"]["mode"] == Schema.FLIGHT and _snapshot["speed"] == 1
		_router.advance(delta * FLIGHT_RATE if fast else delta)
	if _dirty:
		_dirty = false
		_render()


func _unhandled_key_input(event: InputEvent) -> void:
	if not _playing or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		if _managing:
			_manage(false)
		else:
			_show_intro()
		get_viewport().set_input_as_handled()


func _show_intro() -> void:
	if _playing:
		_save(false)
	_playing = false
	_managing = false
	_drop_surface()
	var saved := _store.load_primary()
	var backup := _store.load_backup() if not saved["ok"] else {}
	_resume.visible = bool(saved["ok"]) or bool(backup.get("ok", false))
	_intro_status.text = "" if saved["ok"] or saved["code"] == "NOT_FOUND" else saved["message"]
	_launch_button.call_deferred("grab_focus")
	_dirty = true


func _start_new() -> void:
	_start(Schema.new_state(360))


func _continue() -> void:
	var result := _store.load_primary()
	if not result["ok"] and result["code"] != "FUTURE_SCHEMA":
		result = _store.load_backup()
	if not result["ok"]:
		_intro_status.text = result["message"]
		return
	_start(result["state"])


func _start(state: Dictionary) -> void:
	if not Schema.validate_state(state):
		_intro_status.text = "저장한 탐험을 불러오지 못했어요."
		return
	_drop_surface()
	_snapshot = {}
	_playing = true
	_managing = false
	_target = _initial_target(state)
	_pilot.reset_ship(state["ship"]["body_id"])
	_pilot.select_target(_target)
	_feedback.text = ""
	_action = ""
	_router.restore(state)
	if state["paused"]:
		_router.dispatch({"type": "SET_PAUSED", "paused": false})


func _initial_target(state: Dictionary) -> String:
	var ship: Dictionary = state["ship"]
	if ship["mode"] == Schema.FLIGHT:
		return ship["destination_id"]
	var current: String = ship["body_id"]
	if current in [Schema.MOON, Schema.MARS] and not state["colonies"].has(current):
		return current
	return Schema.MARS if current == Schema.MOON else Schema.MOON


func _state_changed(state: Dictionary) -> void:
	var before := _snapshot
	_snapshot = state
	_dirty = true
	if not _playing or before.is_empty():
		return
	var previous: Dictionary = before["ship"]
	var ship: Dictionary = state["ship"]
	if previous["mode"] == Schema.FLIGHT and ship["mode"] == Schema.ORBIT:
		_target = ship["body_id"]
		_pilot.select_target(_target)
		_feedback.text = ""
	if previous["mode"] == Schema.SURFACE and ship["mode"] == Schema.ORBIT:
		_target = Schema.MARS if ship["body_id"] == Schema.MOON else Schema.MOON
		_pilot.reset_ship(ship["body_id"])
		_pilot.select_target(_target)
		_feedback.text = ""
		_save(false)
	elif previous["mode"] == Schema.ORBIT and ship["mode"] == Schema.SURFACE:
		_save(false)
	elif ship["mode"] == Schema.SURFACE:
		var id: String = ship["body_id"]
		var old_ore := _ore_count(before["colonies"].get(id, {}))
		if old_ore < 2 and _ore_count(state["colonies"].get(id, {})) >= 2:
			_save(false)


func _select_body(id: String) -> void:
	if not _playing or _snapshot["ship"]["mode"] != Schema.ORBIT:
		return
	_target = id
	_pilot.select_target(id)
	_feedback.text = ""
	_dirty = true


func _travel(id: String) -> void:
	if _snapshot["ship"]["mode"] != Schema.ORBIT or _snapshot["ship"]["body_id"] == id:
		return
	var result := _router.dispatch({"type": "TRAVEL", "body_id": id})
	if not result["ok"]:
		_feedback.text = result["message"]
	else:
		_target = id
		_feedback.text = ""
		_pilot.select_target(id)


func _act() -> void:
	var id: String = _snapshot["ship"]["body_id"]
	match _action:
		"travel":
			_travel(_target)
		"land":
			_send({"type": "LAND", "body_id": id})
		"find":
			_find_ore(id)
		"mine":
			_start_mining(id)
		"takeoff":
			_send({"type": "TAKEOFF"})
		"resume":
			_send({"type": "SET_PAUSED", "paused": false})


func _send(command: Dictionary) -> bool:
	var result := _router.dispatch(command)
	if not result["ok"]:
		_feedback.text = result["message"]
	return result["ok"]


func _find_ore(id: String) -> void:
	var pad: Array = _colony.balance.data["grid"]["landing_pad_cell"]
	_ore_deposit = FirstMine.find_deposit(_snapshot["colonies"][id], Vector2i(pad[0], pad[1]))
	if _ore_deposit.is_empty():
		_feedback.text = "캘 수 있는 광석이 없어요. 다른 곳을 탐험해 봐요."
		return
	_surface.focus_deposit(_ore_deposit["id"])
	_feedback.text = ""
	_dirty = true


func _start_mining(id: String) -> void:
	var result := FirstMine.plan(_colony, _snapshot, id, _ore_deposit)
	if not result["ok"]:
		_feedback.text = result["message"]
		return
	_feedback.text = ""
	for command: Dictionary in result["orders"]:
		if not _send(command):
			return
	_save(false)


func _save(show_message: bool) -> void:
	var result := _store.save(_snapshot)
	if show_message or not result["ok"]:
		_feedback.text = result["message"]


func _ore_count(colony: Dictionary) -> int:
	if not _colony.balance.is_valid():
		return 0
	return FirstMine.ore_mined(colony, _colony.balance.data["deposit"]["initial_remaining"])


func _manage(details: bool) -> void:
	if _surface == null:
		return
	_managing = details
	_surface.show_management(details)
	_dirty = true


func _drop_surface() -> void:
	if _surface != null:
		_surface.show_management(false)
		_surface.hide()
		_surface.process_mode = Node.PROCESS_MODE_DISABLED
		_surface.queue_free()
		_surface = null
	_surface_id = ""
	_ore_deposit = {}
	_managing = false


func _show_surface(id: String) -> void:
	if _surface_id == id:
		return
	_drop_surface()
	_surface = SurfaceScene.instantiate()
	_surface.configure(_router, _colony, id)
	_surface.show_management(false)
	add_child(_surface)
	_surface_id = id


func _render() -> void:
	var ship: Dictionary = _snapshot["ship"]
	var surface: bool = _playing and ship["mode"] == Schema.SURFACE
	if surface:
		_show_surface(ship["body_id"])
	else:
		_drop_surface()
	_intro.visible = not _playing
	_pilot.visible = not surface
	_pilot.overview = not _playing
	_pilot.can_steer = _playing and ship["mode"] == Schema.ORBIT and not _snapshot["paused"]
	_map_buttons.visible = _playing and not surface and ship["mode"] == Schema.ORBIT
	_top.visible = _playing and not _managing
	_mission.visible = _playing and not _managing
	_return_button.visible = _playing and _managing
	_management.visible = surface
	_pilot.show_flight(ship, _snapshot["colonies"])
	if not _playing:
		return
	_location.text = "%s  ·  %s  /  연료 %d" % [
		_name(ship["body_id"]), "표면" if surface else ("비행 중" if ship["mode"] == Schema.FLIGHT else "궤도"),
		ship["fuel"]]
	if _snapshot["paused"]:
		_tag.text = "일시정지"
		_tag.modulate = MINT
		_mission_text("잠깐 멈췄어요", "준비되면 탐험을 이어갈 수 있어요.", "다시 움직이기", "resume")
	elif surface:
		_render_surface(ship["body_id"])
	else:
		_render_flight(ship)


func _render_flight(ship: Dictionary) -> void:
	_tag.modulate = MINT
	_tag.text = "우주 비행"
	if ship["mode"] == Schema.FLIGHT:
		_mission_text("%s 가는 중" % _toward(ship["destination_id"]),
				"우주선이 목적지에 가까워지고 있어요.", "", "")
	elif ship["body_id"] == _target:
		_mission_text("%s에 도착했어요!" % _name(_target),
				"표면에 내려가서 광석을 찾아봐요.", "착륙하기", "land")
	else:
		var heading := _toward(_target)
		_mission_text("%s 가 볼까요?" % heading,
				"WASD로 우주선을 움직여 고리에 다가가요. Space는 멈추기.",
				"%s 날아가기" % heading, "travel")


func _render_surface(id: String) -> void:
	_tag.modulate = ORE
	_tag.text = "%s 표면 · 생성 지형" % _name(id)
	var colony: Dictionary = _snapshot["colonies"][id]
	var count := _ore_count(colony)
	if count >= 2:
		_mission_text("광석 %d개를 모았어요!" % count,
				"우주로 돌아가도 채굴기는 계속 일해요.", "이륙하기", "takeoff")
	elif FirstMine.has_miner(colony):
		var report := _colony.summarize(_snapshot, id)
		for entry: Dictionary in report["buildings"]:
			if entry["type"] == "miner" and entry["status"] == "RUNNING":
				_mission_text("광석을 캐는 중이에요", "채굴기에서 광석이 나오고 있어요.", "", "")
				return
		_mission_text("채굴기가 멈춰 있어요", "기지 관리에서 전력과 저장 공간을 살펴봐요.", "이륙하기", "takeoff")
	elif _ore_deposit.is_empty():
		_mission_text("여기서 광석을 찾아봐요", "광석은 기지를 만드는 데 쓰는 돌이에요.", "광석 찾기", "find")
	else:
		_mission_text("광석을 찾았어요!", "우주선의 재료로 태양광 발전기와 채굴기를 놓아요.", "채굴 시작하기", "mine")


func _mission_text(title: String, description: String, button: String, action: String) -> void:
	_heading.text = title
	_help.text = description
	_primary.text = button
	_primary.visible = not action.is_empty()
	if _action != action and _primary.visible and not _managing:
		_primary.grab_focus()
	_action = action


func _name(id: String) -> String:
	return BODY_NAMES.get(id, id)


func _toward(id: String) -> String:
	return "화성으로" if id == Schema.MARS else "달로"


func _build_ui() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Malgun Gothic", "Noto Sans CJK KR"])
	theme = Theme.new()
	theme.default_font = font
	theme.default_font_size = 17
	_pilot = PilotView.new()
	add_child(_pilot)
	_pilot.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_pilot.destination_selected.connect(_select_body)
	_pilot.destination_reached.connect(_travel)

	var overlay := CanvasLayer.new()
	overlay.layer = 3
	add_child(overlay)
	var frame := MarginContainer.new()
	frame.theme = theme
	frame.mouse_filter = MOUSE_FILTER_IGNORE
	overlay.add_child(frame)
	frame.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for edge: String in ["left", "right", "top", "bottom"]:
		frame.add_theme_constant_override("margin_" + edge, 24)
	var column := VBoxContainer.new()
	column.mouse_filter = MOUSE_FILTER_IGNORE
	frame.add_child(column)

	_top = HBoxContainer.new()
	_top.mouse_filter = MOUSE_FILTER_IGNORE
	_top.add_theme_constant_override("separation", 8)
	column.add_child(_top)
	var location_chip := _panel(9.0)
	_location = _label("", 18, LIGHT)
	_location.autowrap_mode = TextServer.AUTOWRAP_OFF
	location_chip.add_child(_location)
	_top.add_child(location_chip)
	var top_gap := Control.new()
	top_gap.mouse_filter = MOUSE_FILTER_IGNORE
	top_gap.size_flags_horizontal = SIZE_EXPAND_FILL
	_top.add_child(top_gap)
	_map_buttons = HBoxContainer.new()
	_map_buttons.add_theme_constant_override("separation", 8)
	_top.add_child(_map_buttons)
	_map_buttons.add_child(_button("달", _select_body.bind(Schema.MOON)))
	_map_buttons.add_child(_button("화성", _select_body.bind(Schema.MARS)))
	_top.add_child(_button("저장", _save.bind(true)))
	_top.add_child(_button("메뉴", _show_intro))

	var space := Control.new()
	space.mouse_filter = MOUSE_FILTER_IGNORE
	space.size_flags_vertical = SIZE_EXPAND_FILL
	column.add_child(space)
	_mission = _panel()
	column.add_child(_mission)
	var mission_row := HBoxContainer.new()
	mission_row.add_theme_constant_override("separation", 20)
	_mission.add_child(mission_row)
	var words := VBoxContainer.new()
	words.size_flags_horizontal = SIZE_EXPAND_FILL
	words.add_theme_constant_override("separation", 3)
	mission_row.add_child(words)
	_tag = _label("", 15, LIGHT)
	words.add_child(_tag)
	_heading = _label("", 31, LIGHT)
	words.add_child(_heading)
	_help = _label("", 18, MUTED)
	words.add_child(_help)
	_feedback = _label("", 16, ORE)
	_feedback.accessibility_live = 1
	words.add_child(_feedback)
	var actions := VBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 6)
	mission_row.add_child(actions)
	_primary = _button("", _act, true)
	_primary.custom_minimum_size.x = 194
	actions.add_child(_primary)
	_management = _button("기지 관리", _manage.bind(true))
	actions.add_child(_management)

	var center := CenterContainer.new()
	center.mouse_filter = MOUSE_FILTER_IGNORE
	overlay.add_child(center)
	center.set_anchors_and_offsets_preset(PRESET_CENTER_TOP)
	center.offset_left = -150.0
	center.offset_right = 150.0
	center.offset_top = 18.0
	_return_button = _button("탐험 안내로", _manage.bind(false), true)
	_return_button.theme = theme
	center.add_child(_return_button)
	_build_intro(overlay)


func _build_intro(overlay: CanvasLayer) -> void:
	_intro = _panel()
	_intro.theme = theme
	overlay.add_child(_intro)
	_intro.anchor_top = 0.5
	_intro.anchor_bottom = 0.5
	_intro.offset_left = 82.0
	_intro.offset_right = 484.0
	_intro.offset_top = -168.0
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_intro.add_child(column)
	column.add_child(_label("UNIVERSE 360", 16, MINT))
	column.add_child(_label("달까지 가 볼래요?", 40, LIGHT))
	column.add_child(_label("우주선을 몰고 달에 내려서 첫 광석을 모아요.", 18, MUTED))
	_launch_button = _button("새로 출발하기", _start_new, true)
	column.add_child(_launch_button)
	_resume = _button("이어하기", _continue)
	column.add_child(_resume)
	_intro_status = _label("", 15, ORE)
	column.add_child(_intro_status)


func _panel(padding := 18.0) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#101f30")
	style.set_border_width_all(1)
	style.border_color = Color("#31495e")
	style.set_corner_radius_all(15)
	for side: Side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_content_margin(side, padding)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, callback: Callable, primary := false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 49 if primary else 38
	button.mouse_default_cursor_shape = CURSOR_POINTING_HAND
	button.pressed.connect(callback)
	var states := {
		"normal": MINT if primary else Color("#233b52"),
		"hover": Color("#aaf5ea") if primary else Color("#365970"),
		"pressed": Color("#56c6bb") if primary else Color("#425f78"),
	}
	for name: String in states:
		var style := StyleBoxFlat.new()
		style.bg_color = states[name]
		style.set_corner_radius_all(10)
		style.set_content_margin(SIDE_LEFT, 13.0)
		style.set_content_margin(SIDE_RIGHT, 13.0)
		button.add_theme_stylebox_override(name, style)
	if primary:
		for name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(name, Color("#091c27"))
		button.add_theme_font_size_override("font_size", 20)
	return button
