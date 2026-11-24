extends SceneTree

const Schema := preload("res://src/contracts/schema.gd")
const Catalog := preload("res://src/catalog/catalog.gd")
const OrbitModel := preload("res://src/navigation/orbit_model.gd")
const Navigation := preload("res://src/navigation/navigation.gd")
const GameState := preload("res://src/core/game_state.gd")
const Router := preload("res://src/core/command_router.gd")
const MockColony := preload("res://src/contracts/mocks/mock_colony.gd")
const SaveStore := preload("res://src/core/save_store.gd")
const Demo := preload("res://scenes/navigation/navigation_demo.tscn")
const MOON_TRAVEL := {"type": "TRAVEL", "body_id": Schema.MOON}
const MOON_LAND := {"type": "LAND", "body_id": Schema.MOON}
const MARS_TRAVEL := {"type": "TRAVEL", "body_id": Schema.MARS}
const MARS_LAND := {"type": "LAND", "body_id": Schema.MARS}
const TAKEOFF := {"type": "TAKEOFF"}

var _count := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_catalog()
	_test_navigation()
	_test_restore()
	await _test_scene()
	print("A1 navigation tests: %d checks, %d failures" % [_count, _failures])
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, description: String) -> void:
	_count += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + description)


func _new_router() -> Router:
	return Router.new(GameState.new(), Navigation.new(Catalog.new()), MockColony.new())


func _test_catalog() -> void:
	var catalog := Catalog.new()
	_check(catalog.error.is_empty(), "bundled catalog is valid")
	if not catalog.error.is_empty():
		return
	_check(catalog.list_bodies("sol").size() == 8 and catalog.list_bodies("").size() == 4, "eight planets, Sun and three neighbors")
	_check(catalog.list_bodies(Schema.EARTH).size() == 1 and catalog.get_body(Schema.MOON)["parent_id"] == Schema.EARTH, "Moon correctly orbits Earth")
	var earth := catalog.get_body(Schema.EARTH)
	_check(is_equal_approx(earth["radius_km"], 6371.0084) and earth["orbit_radius_km"] == 149598261, "physical Earth values transliterated from JPL")
	_check(earth["provenance"]["radius_km"]["data_status"] == "observed" and earth["provenance"]["position"]["data_status"] == "modelled", "model and observation provenance are distinct")
	earth["provenance"]["radius_km"]["source_url"] = "mutated"
	_check(catalog.get_body(Schema.EARTH)["provenance"]["radius_km"]["source_url"].begins_with("https://"), "callers cannot change provenance")
	var sirius := catalog.get_body("nearby.sirius")
	_check(is_equal_approx(sirius["distance_ly"], 8.58) and sirius["radius_km"] == null and sirius["orbit_radius_km"] == null, "stellar distance and explicit missing values")
	var orbit := OrbitModel.new(catalog)
	_check(orbit.system_bodies().size() == 10 and orbit.position_km(Schema.EARTH, 0) is PackedFloat64Array, "all solar bodies and double-precision model coordinates")
	_check(is_equal_approx(orbit.distance_km(Schema.EARTH, Schema.MOON, 0), 384400.0), "physical Earth-Moon distance uses km")
	_check(orbit.visual_position(Schema.EARTH, 0).distance_to(orbit.visual_position(Schema.MOON, 0)) < 5.0, "render distance uses exaggerated moon spacing")
	_check(orbit.distance_km("sol", "nearby.sirius", 0) == null, "stellar light-years kept outside the solar coordinate model")
	_check(orbit.position_km(Schema.EARTH, 86400) != orbit.position_km(Schema.EARTH, 0), "circular positions vary with model seconds")

	var folder := DirAccess.create_temp("universe360-a1-catalog")
	_check(folder != null, "temporary directory for catalog rejection tests")
	if folder == null:
		return
	var slot := folder.get_current_dir().path_join("body_fixture.json")
	var source: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Catalog.DEFAULT_PATH))
	var duplicate := source.duplicate(true)
	duplicate["bodies"].append(duplicate["bodies"][0])
	_check(not _parse_fixture(slot, duplicate).error.is_empty(), "duplicate IDs are rejected")
	var invalid := source.duplicate(true)
	invalid["bodies"][1]["parent_id"] = "absent"
	_check(not _parse_fixture(slot, invalid).error.is_empty(), "unknown parents are rejected")
	var cycle := source.duplicate(true)
	cycle["bodies"][1]["parent_id"] = "sol.venus"
	cycle["bodies"][2]["parent_id"] = "sol.mercury"
	_check(not _parse_fixture(slot, cycle).error.is_empty(), "parent cycles are rejected")
	var provenance := source.duplicate(true)
	provenance["bodies"][1]["provenance"]["radius_km"] = "unknown"
	_check(not _parse_fixture(slot, provenance).error.is_empty(), "unrecognized source IDs are rejected")


func _parse_fixture(path: String, data: Dictionary) -> Catalog:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data))
		file.close()
	return Catalog.new(path)


func _test_navigation() -> void:
	var router := _new_router()
	var initial := router.snapshot()
	var ship: Dictionary = initial["ship"]
	_check(ship["body_id"] == Schema.EARTH and ship["mode"] == Schema.ORBIT and ship["fuel"] == 100, "T01 start at Earth orbit with full fuel")
	_check(ship["cargo"]["metal"] == 50 and ship["cargo"]["ice"] == 20 and ship["cargo"]["parts"] == 20 and initial["research"] == 0, "T01 start resources exact")
	_check(router.dispatch({"type": "TRAVEL", "body_id": "sol.jupiter"})["code"] == "INVALID_TARGET" and router.snapshot() == initial, "exploration-only target does not change state")
	_check(router.dispatch({"type": "TRAVEL", "body_id": 13})["code"] == "INVALID_TARGET", "malformed target is rejected")
	_check(router.dispatch(TAKEOFF)["code"] == "INVALID_MODE", "cannot take off from orbit")
	_check(router.dispatch(MOON_TRAVEL)["ok"] and router.snapshot()["ship"]["fuel"] == 95, "T03 Moon launch costs five fuel")
	_check(router.dispatch(MOON_TRAVEL)["code"] == "INVALID_MODE" and router.snapshot()["ship"]["fuel"] == 95, "launch cannot be charged again midflight")
	router.advance(19.0)
	_check(router.dispatch(MOON_LAND)["code"] == "NOT_ARRIVED" and router.snapshot()["ship"]["travel_ticks_remaining"] == 1, "T04 rejects landing before twentieth tick")
	router.advance(1.0)
	_check(router.snapshot()["ship"]["body_id"] == Schema.MOON and router.snapshot()["ship"]["destination_id"] == null, "Moon orbit reached at twentieth tick")
	_check(router.dispatch(MOON_TRAVEL)["code"] == "INVALID_TARGET", "cannot travel to current orbit")
	_check(router.dispatch(MOON_LAND)["ok"] and router.snapshot()["colonies"].has(Schema.MOON), "T04 landing creates mock colony via Router")
	_check(router.dispatch(MOON_LAND)["code"] == "INVALID_MODE", "cannot land twice")
	_check(router.dispatch(TAKEOFF)["ok"] and router.dispatch(MARS_TRAVEL)["ok"], "T04 Moon takeoff and Mars launch")
	_check(router.snapshot()["ship"]["fuel"] == 75 and router.snapshot()["ship"]["travel_ticks_remaining"] == 60, "Mars costs twenty fuel and sixty ticks")
	router.advance(60.0)
	_check(router.dispatch(MARS_LAND)["ok"] and router.dispatch(TAKEOFF)["ok"] and router.snapshot()["colonies"].has(Schema.MARS), "T04 Mars landing and takeoff")
	var poor := router.snapshot()
	poor["ship"]["fuel"] = 4
	_check(router.restore(poor) and router.dispatch(MOON_TRAVEL)["code"] == "INSUFFICIENT_FUEL" and router.snapshot() == poor, "T03 insufficient fuel preserves all state")
	for planet: String in ["sol.jupiter", "sol.saturn", "sol.uranus", "sol.neptune"]:
		var gas_orbit := initial.duplicate(true)
		gas_orbit["ship"]["body_id"] = planet
		_check(router.restore(gas_orbit) and router.dispatch({"type": "LAND", "body_id": planet})["code"] == "NOT_LANDABLE" and router.snapshot() == gas_orbit, "T04 gas / ice giant landing rejected " + planet)


func _test_restore() -> void:
	var folder := DirAccess.create_temp("universe360-a1-flight")
	_check(folder != null, "isolated flight save directory")
	if folder == null:
		return
	var path := folder.get_current_dir().path_join("save_v1.json")
	var router := _new_router()
	router.dispatch(MOON_TRAVEL)
	router.advance(8.0)
	var saved := router.snapshot()
	_check(SaveStore.new(path).save(saved)["ok"], "write save mid-flight")
	var result := SaveStore.new(path).load_primary()
	var resumed := _new_router()
	_check(result["ok"] and resumed.restore(result["state"]) and resumed.snapshot() == saved, "restore target, fuel and remaining flight ticks")
	resumed.advance(12.0)
	_check(resumed.snapshot()["ship"]["fuel"] == 95 and resumed.dispatch(MOON_LAND)["ok"], "resumed flight arrives without a second charge")
	_check(SaveStore.new(path).save(resumed.snapshot())["ok"], "write landed state")
	var surface := _new_router()
	result = SaveStore.new(path).load_primary()
	_check(result["ok"] and surface.restore(result["state"]) and surface.snapshot()["colonies"].has(Schema.MOON) and surface.dispatch(TAKEOFF)["ok"], "landed save restores mock colony and permits takeoff")


func _test_scene() -> void:
	var demo := Demo.instantiate()
	root.add_child(demo)
	await process_frame
	await process_frame
	var view: Control = demo.get_node("%NavigationView")
	var selector: OptionButton = view.get("_selector")
	var chart: SubViewportContainer = view.get("_map")
	var feedback: Label = view.get("_feedback")
	var router: Router = demo.get("_router")
	var travel: Button = view.get("_travel")
	var land: Button = view.get("_land")
	var takeoff: Button = view.get("_takeoff")
	_check(selector.item_count == 13 and view.selected_body_id() == Schema.EARTH, "T02 all catalog names selectable")
	_check(not (view.get("_sources") as VBoxContainer).get_children().filter(func(node: Node) -> bool: return node is LinkButton).is_empty(), "T02 selected body shows clickable provenance")
	selector.item_selected.emit(12)
	_check(view.selected_body_id() == "nearby.sirius" and "광년" in view.get("_details").text and travel.disabled, "neighbor selection exposes light-years and remains exploration-only")
	var point: Vector2 = view.marker_position(Schema.MARS)
	_check(Rect2(Vector2.ZERO, chart.size).has_point(point), "T02 Mars marker visible in the chart")
	_button_on_map(chart, point, MOUSE_BUTTON_WHEEL_UP, true)
	var zoomed: Vector2 = view.marker_position(Schema.MARS)
	_check(not point.is_equal_approx(zoomed), "wheel zoom changes projection")
	_button_on_map(chart, zoomed, MOUSE_BUTTON_WHEEL_DOWN, true)
	point = view.marker_position(Schema.MARS)
	_button_on_map(chart, point, MOUSE_BUTTON_LEFT, true)
	_button_on_map(chart, point, MOUSE_BUTTON_LEFT, false)
	_check(view.selected_body_id() == Schema.MARS and not travel.disabled and land.disabled, "T02 chart marker click selects Mars")
	travel.pressed.emit()
	_check(router.snapshot()["ship"]["mode"] == Schema.FLIGHT and "시작" in feedback.text and land.disabled, "travel button dispatches to router")
	router.advance(60.0)
	_check(not land.disabled, "landing unlocks after arrival")
	land.pressed.emit()
	_check(not takeoff.disabled and router.snapshot()["ship"]["mode"] == Schema.SURFACE, "landing button reaches surface mode")
	takeoff.pressed.emit()
	_check(router.snapshot()["ship"]["mode"] == Schema.ORBIT, "takeoff button returns to orbit")
	await _capture(root)
	demo.free()


func _button_on_map(chart: SubViewportContainer, point: Vector2, button: MouseButton, pressed: bool) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = button
	click.position = chart.get_global_transform_with_canvas() * point
	click.global_position = click.position
	click.pressed = pressed
	root.push_input(click, true)


func _capture(window: Window) -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			await RenderingServer.frame_post_draw
			var image := window.get_texture().get_image()
			_check(image != null and image.save_png(argument.trim_prefix("--capture=")) == OK, "Windows rendered map screenshot")
			return
