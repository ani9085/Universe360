extends SceneTree

const Schema := preload("res://src/contracts/schema.gd")
const GameState := preload("res://src/core/game_state.gd")
const Router := preload("res://src/core/command_router.gd")
const SaveStore := preload("res://src/core/save_store.gd")
const MockCatalog := preload("res://src/contracts/mocks/mock_catalog.gd")
const MockNavigation := preload("res://src/contracts/mocks/mock_navigation.gd")
const MockColony := preload("res://src/contracts/mocks/mock_colony.gd")
const MainScene := preload("res://scenes/main/main.tscn")

class TickProbe extends RefCounted:
	var stage: String
	var trace: Array[String]

	func _init(stage_name: String, trace_log: Array[String]) -> void:
		stage = stage_name
		trace = trace_log

	func step(state: Dictionary) -> Dictionary:
		trace.append("%s:%d:%d" % [stage, state["tick"], state["research"]])
		var next := state.duplicate(true)
		next["research"] += 1
		return next

	func apply(state: Dictionary, _command: Dictionary) -> Dictionary:
		state["ship"]["fuel"] = 0
		return Schema.result(false, "TEST_FAILURE", "", state)

class InvalidColony extends RefCounted:
	func create(_body_id: String, _world_seed: int) -> Dictionary:
		return {}

var _failures := 0
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_state()
	_test_catalog()
	_test_commands()
	_test_clock()
	_test_save()
	await _test_main()
	print("A0 core tests: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + description)


func _router() -> Router:
	return Router.new(GameState.new(), MockNavigation.new(MockCatalog.new()), MockColony.new())


func _test_state() -> void:
	var model := GameState.new(720)
	var state := model.snapshot()
	var ship: Dictionary = state["ship"]
	_check(state["world_seed"] == 720 and state["schema_version"] == 1 and state["tick"] == 0, "initial seed, schema and tick")
	_check(ship["body_id"] == Schema.EARTH and ship["mode"] == Schema.ORBIT and ship["fuel"] == 100, "Earth orbit and fuel")
	_check(ship["cargo"] == {"metal": 50, "ice": 20, "parts": 20, "ore": 0, "silicon": 0}, "initial cargo")
	_check(state["research"] == 0 and state["colonies"].is_empty() and state["speed"] == 1 and not state["paused"], "initial session state")
	ship["cargo"]["metal"] = 7
	ship["local_pose"]["position"][0] = 7.5
	_check(model.snapshot()["ship"]["cargo"]["metal"] == 50 and model.snapshot()["ship"]["local_pose"]["position"][0] == 0.0, "nested snapshots are detached")
	_check(model.replace(state), "valid state replaces")
	ship["cargo"]["metal"] = -1
	_check(not model.replace(state) and model.snapshot()["ship"]["cargo"]["metal"] == 7, "invalid state and caller mutations are isolated")


func _test_catalog() -> void:
	var catalog := MockCatalog.new()
	var moon := catalog.get_body(Schema.MOON)
	_check(moon["parent_id"] == Schema.EARTH and moon["landable"] and moon["radius_km"] == null, "mock body shape and no invented astronomical values")
	moon["provenance"]["data_status"] = "observed"
	_check(catalog.get_body(Schema.MOON)["provenance"]["data_status"] == "modelled", "catalog bodies are independent")
	_check(catalog.get_body("missing").is_empty() and catalog.list_bodies(Schema.EARTH).size() == 1 and catalog.list_bodies("").size() == 1, "catalog lookup and root query")


func _test_commands() -> void:
	var router := _router()
	var before := router.snapshot()
	_check(router.dispatch({})["code"] == "UNKNOWN_COMMAND" and router.snapshot() == before, "unknown command is inert")
	_check(router.dispatch({"type": "SET_SPEED", "speed": 3})["code"] == "INVALID_SPEED", "unsupported speed is rejected")
	_check(router.dispatch({"type": "SET_PAUSED", "paused": "true"})["code"] == "INVALID_PAUSE", "pause requires boolean")
	_check(router.dispatch({"type": "LAND", "body_id": Schema.EARTH})["code"] == "NOT_LANDABLE", "fixture rejects non-landable Earth")
	_check(router.dispatch({"type": "BUILD", "colony_id": Schema.MOON})["code"] == "INVALID_MODE", "colony commands require local surface")
	var moon := {"type": "TRAVEL", "body_id": Schema.MOON}
	var flight := router.dispatch(moon)
	_check(flight["ok"] and flight["state"]["ship"]["fuel"] == 95, "mock travel charges fuel once")
	flight["state"]["ship"]["fuel"] = 0
	_check(not router.dispatch(moon)["ok"] and router.snapshot()["ship"]["fuel"] == 95, "result mutation and rejected travel leave internal fuel unchanged")
	var land := {"type": "LAND", "body_id": Schema.MOON}
	router.advance(19.0)
	_check(router.dispatch(land)["code"] == "NOT_ARRIVED" and router.snapshot()["colonies"].is_empty(), "before arrival no landing or colony creation")
	router.advance(1.0)
	_check(router.snapshot()["ship"]["mode"] == Schema.ORBIT and router.snapshot()["ship"]["body_id"] == Schema.MOON, "arrival after twentieth tick")
	var landed := router.dispatch(land)
	_check(landed["ok"] and landed["state"]["ship"]["mode"] == Schema.SURFACE and landed["state"]["colonies"].has(Schema.MOON), "landing creates the mock colony")
	_check(router.dispatch({"type": "TRANSFER", "colony_id": Schema.MARS})["code"] == "INVALID_MODE", "another colony cannot receive local orders")
	_check(router.dispatch({"type": "BUILD", "colony_id": Schema.MOON})["code"] == "MODULE_STUB", "local build is delegated to the fixture")
	var modified := router.snapshot()
	modified["colonies"][Schema.MOON]["inventory"]["ore"] = 9
	router.restore(modified)
	_check(router.dispatch({"type": "TAKEOFF"})["ok"] and router.dispatch(land)["state"]["colonies"][Schema.MOON]["inventory"]["ore"] == 9, "relanding preserves an existing colony")
	var poor := router.snapshot()
	poor["ship"]["mode"] = Schema.ORBIT
	poor["ship"]["fuel"] = 1
	router.restore(poor)
	_check(router.dispatch({"type": "TRAVEL", "body_id": Schema.MARS})["code"] == "INSUFFICIENT_FUEL" and router.snapshot() == poor, "rejected fuel cost preserves state")
	var invalid := Router.new(GameState.new(), MockNavigation.new(MockCatalog.new()), InvalidColony.new())
	var unvisited := poor.duplicate(true)
	unvisited["colonies"] = {}
	invalid.restore(unvisited)
	_check(invalid.dispatch(land)["code"] == "INVALID_STATE" and invalid.snapshot() == unvisited, "invalid colony rolls back landing")
	var trace: Array[String] = []
	var probe := Router.new(GameState.new(), TickProbe.new("nav", trace), TickProbe.new("colony", trace))
	_check(not probe.dispatch(moon)["ok"] and probe.snapshot()["ship"]["fuel"] == 100, "mutation in a failing adapter does not leak")


func _test_clock() -> void:
	var trace: Array[String] = []
	var router := Router.new(GameState.new(), TickProbe.new("nav", trace), TickProbe.new("colony", trace))
	router.state_changed.connect(func(state: Dictionary) -> void:
		trace.append("event:%d:%d" % [state["tick"], state["research"]])
		state["research"] = 404
	)
	router.advance(0.4)
	_check(trace.is_empty(), "fractional time waits")
	router.advance(0.6)
	_check(trace == ["nav:0:0", "colony:0:1", "event:1:2"] and router.snapshot()["research"] == 2, "tick order and signal isolation")
	var results: Array[Dictionary] = []
	for speed: int in Schema.SPEEDS:
		var session := _router()
		session.dispatch({"type": "SET_SPEED", "speed": speed})
		session.dispatch({"type": "TRAVEL", "body_id": Schema.MARS})
		for frame in range(60):
			session.advance(1.0 / float(speed))
		var state := session.snapshot()
		state.erase("speed")
		results.append(state)
	_check(results[0] == results[1] and results[0] == results[2] and results[0]["tick"] == 60 and results[0]["ship"]["body_id"] == Schema.MARS, "60 ticks give equal state across speeds")
	router.dispatch({"type": "SET_SPEED", "speed": 60})
	_check(router.advance(3.25) == 120 and router.snapshot()["tick"] == 121, "120 tick frame cap")
	router.dispatch({"type": "SET_PAUSED", "paused": true})
	var paused := router.snapshot()
	_check(router.advance(50.0) == 0 and router.snapshot() == paused, "pause leaves state unchanged and adds no time")
	router.dispatch({"type": "SET_PAUSED", "paused": false})
	_check(router.advance(0.0) == 75 and router.snapshot()["tick"] == 196, "pending ticks survive frame cap and pause")
	router.advance(0.01)
	router.restore(router.snapshot())
	_check(router.advance(0.01) == 0, "restore discards transient clock accumulator")


func _test_save() -> void:
	var directory := DirAccess.create_temp("universe360-a0")
	_check(directory != null, "temporary save directory opened")
	if directory == null:
		return
	var path := directory.get_current_dir().path_join("save_v1.json")
	var store := SaveStore.new(path)
	_check(store.load_primary()["code"] == "NOT_FOUND", "missing save is reported")
	var state := Schema.new_state(9223372036854775807)
	var colony := Schema.new_colony(Schema.MOON, -9223372036854775807 - 1, 1)
	colony["inventory"]["metal"] = 12
	colony["buildings"].append({"id": "b1", "type": "miner", "grid_x": -1, "grid_y": 8, "deposit_id": "d1"})
	colony["deposits"].append({"id": "d1", "resource": "ore", "remaining": 998, "grid_x": -1, "grid_y": 8})
	colony["upgrades"].append("i123 \"\\\n 한글")
	state["colonies"][Schema.MOON] = colony
	state["ship"]["local_pose"]["position"] = [0.12345678901234567, 0.0, -12.5]
	state["ship"]["mode"] = Schema.FLIGHT
	state["ship"]["destination_id"] = Schema.MARS
	state["ship"]["travel_ticks_remaining"] = 10
	state["ship"]["fuel"] = 75
	state["paused"] = true
	state["tick"] = 70
	state["research"] = 20
	_check(store.save(state)["ok"], "full state saves")
	var reopened := SaveStore.new(path).load_primary()
	_check(reopened["ok"] and reopened["state"] == state, "JSON round trip preserves nested state, Unicode and int64 limits")
	_check(store.load_backup()["code"] == "NOT_FOUND", "first save has no older backup")
	var newer := state.duplicate(true)
	newer["tick"] = 71
	var raw := FileAccess.get_file_as_string(path)
	_check(directory.make_dir("save_v1.json.bak.tmp") == OK, "create backup write failure fixture")
	_check(not store.save(newer)["ok"] and FileAccess.get_file_as_string(path) == raw, "failed backup leaves primary intact")
	_check(directory.remove("save_v1.json.bak.tmp") == OK, "remove backup write failure fixture")
	_check(directory.make_dir("save_v1.json.previous") == OK, "create primary replacement failure fixture")
	_check(store.save(newer)["code"] == "REPLACE_FAILED" and FileAccess.get_file_as_string(path) == raw, "failed replacement leaves primary intact")
	_check(directory.remove("save_v1.json.previous") == OK, "remove primary replacement failure fixture")
	_check(store.save(newer)["ok"] and store.load_backup()["state"] == state and store.load_primary()["state"] == newer, "replace keeps previous valid save")
	var future := '{"schema_version":2}'
	_write(path, future)
	_check(store.load_primary()["code"] == "FUTURE_SCHEMA" and store.save(newer)["code"] == "FUTURE_SCHEMA" and FileAccess.get_file_as_string(path) == future, "future save is reported and protected")
	_write(path, '{"schema_version":1, "ship":')
	_check(store.load_primary()["code"] == "CORRUPT_SAVE" and store.load_backup()["state"] == state, "corrupt primary and explicit backup load")
	_check(store.save(newer)["ok"] and store.load_backup()["state"] == state, "corrupt primary does not replace valid backup")
	_check(directory.rename("save_v1.json", "save_v1.json.previous") == OK, "simulate interrupted replacement")
	_check(store.load_primary()["state"] == newer and store.save(state)["ok"] and store.load_backup()["state"] == newer, "interrupted replacement retains last valid primary")


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(content)
		file.close()


func _test_main() -> void:
	var directory := DirAccess.create_temp("universe360-ui")
	_check(directory != null, "temporary UI save directory opened")
	if directory == null:
		return
	var path := directory.get_current_dir().path_join("save_v1.json")
	var menu := MainScene.instantiate()
	menu.set("_store", SaveStore.new(path))
	root.add_child(menu)
	await process_frame
	_check(menu.get_node("%Menu").visible and not menu.get_node("%Session").visible and menu.get_node("%NewGame").has_focus(), "main scene starts with keyboard-focused new game")
	await _capture("01-start")
	menu.get_node("%Continue").pressed.emit()
	_check(menu.get_node("%Status").text.contains("없습니다"), "continue reports missing save in Korean")
	menu.get_node("%Settings").pressed.emit()
	_check(menu.get_node("%Options").visible, "options opens the default speed dialog")
	menu.get_node("%DefaultSpeed").select(1)
	menu.get_node("%Options").get_ok_button().pressed.emit()
	_check(not menu.get_node("%Options").visible, "options dialog can be closed")
	menu.get_node("%NewGame").pressed.emit()
	_check(menu.get_node("%Session").visible and menu.get_node("%Location").text.contains("지구"), "new game opens Earth session")
	_check(menu.get_node("%Speed").get_selected_id() == 10, "new game uses the selected default speed")
	menu.get_node("%Pause").pressed.emit()
	await _capture("02-session")
	menu.get_node("%Save").pressed.emit()
	menu.get_node("%Save").pressed.emit()
	_check(SaveStore.new(path).load_primary()["state"]["paused"], "session pause and save controls are wired")
	menu.free()
	menu = MainScene.instantiate()
	menu.set("_store", SaveStore.new(path))
	root.add_child(menu)
	await process_frame
	menu.get_node("%Continue").pressed.emit()
	_check(menu.get_node("%Session").visible and menu.get_node("%Pause").text == "재개", "reopened scene continues a paused save")
	_write(path, "{damaged")
	menu.get_node("%Load").pressed.emit()
	_check(menu.get_node("%Backup").visible, "corrupt save offers an explicit backup choice")
	menu.get_node("%Backup").get_ok_button().pressed.emit()
	_check(menu.get_node("%Status").text.contains("복원"), "backup choice restores the session")
	menu.free()


func _capture(name: String) -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var path := argument.trim_prefix("--capture-dir=").path_join(name + ".png")
			_check(image != null and image.save_png(path) == OK, "Windows viewport capture: " + name)
			return
