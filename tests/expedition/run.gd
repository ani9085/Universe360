extends SceneTree

const Game = preload("res://scenes/expedition/expedition.tscn")
const Schema = preload("res://src/contracts/schema.gd")
const SaveStore = preload("res://src/core/save_store.gd")
const FirstMine = preload("res://scenes/expedition/first_mine.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var folder := DirAccess.create_temp("universe360-expedition")
	if folder == null:
		printerr("Cannot create an isolated test save.")
		quit(1)
		return
	var save_path := folder.get_current_dir().path_join("flight.json")
	var store := SaveStore.new(save_path)
	var game = Game.instantiate()
	game.set("_store", store)
	root.add_child(game)
	await _settle()
	var router: RefCounted = game.get("_router")
	var action: Button = game.get("_primary")
	var launch: Button = game.get("_launch_button")
	_expect(launch.is_visible_in_tree() and not game.get("_resume").visible, "start screen has one entry action")
	await _capture("01-start")
	launch.pressed.emit()
	await _settle()
	_expect(router.snapshot()["ship"]["body_id"] == Schema.EARTH and action.text == "달로 날아가기",
			"launch opens a visible Moon goal from Earth")
	_expect(game.get("_top").size.y < 80.0 and game.get("_location").size.x > 120.0,
			"the location and fuel stay on one line")
	await _capture("02-flight")
	var pilot: Control = game.get("_pilot")
	var first_anchor: Vector2 = pilot.get("_ship")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_D
	key.pressed = true
	Input.parse_input_event(key)
	for frame in range(10):
		await process_frame
	_expect(pilot.get("_ship").x > first_anchor.x, "D moves the actual displayed spacecraft")
	key = InputEventKey.new()
	key.physical_keycode = KEY_D
	Input.parse_input_event(key)
	pilot.call("brake")

	action.pressed.emit()
	_expect(router.snapshot()["ship"]["fuel"] == 95 and router.snapshot()["ship"]["mode"] == Schema.FLIGHT,
			"Moon route charges five fuel once")
	_expect(not router.dispatch({"type": "LAND", "body_id": Schema.MOON})["ok"], "cannot land before arrival")
	router.advance(20.0)
	await _settle()
	_expect(action.text == "착륙하기", "arrival offers landing")
	action.pressed.emit()
	await _settle()
	_expect(game.get("_surface") != null and action.text == "광석 찾기", "landing opens the simplified surface")
	_expect(store.load_primary()["state"]["ship"]["mode"] == Schema.SURFACE, "landing automatically saves")
	_expect(not game.get("_surface").get("_management_layer").visible, "management starts hidden")
	game.get("_management").pressed.emit()
	await _settle()
	_expect(game.get("_surface").get("_management_layer").visible and game.get("_return_button").visible,
			"optional colony management is reachable")
	game.get("_return_button").pressed.emit()
	await _settle()
	action.pressed.emit()
	await _settle()
	_expect(action.text == "채굴 시작하기" and game.get("_surface").get("_guide_ring") != null,
			"finding ore centers and marks the deposit")
	await _capture("03-found-ore")

	var initial: Dictionary = router.snapshot()
	var no_supplies := initial.duplicate(true)
	no_supplies["ship"]["cargo"]["parts"] = 0
	var failed_plan := FirstMine.plan(game.get("_colony"), no_supplies, Schema.MOON, game.get("_ore_deposit"))
	_expect(not failed_plan["ok"] and no_supplies["colonies"][Schema.MOON]["buildings"].is_empty(),
			"missing parts leave the first mine untouched")
	action.pressed.emit()
	var after_placement: Dictionary = router.snapshot()
	_expect(initial["ship"]["cargo"]["metal"] - after_placement["ship"]["cargo"]["metal"] == 20
			and after_placement["colonies"][Schema.MOON]["buildings"].size() == 2,
			"guided mining installs and pays for solar and miner through the router")
	router.advance(1.0)
	await _settle()
	_expect(_stock(router, Schema.MOON) == 2 and action.text == "이륙하기", "first production unlocks the next action")
	_expect(store.load_primary()["state"]["colonies"][Schema.MOON]["inventory"]["ore"] == 2,
			"first ore automatically saves")
	await _capture("04-first-ore")

	action.pressed.emit()
	await _settle()
	_expect(action.text == "화성으로 날아가기" and game.get("_surface") == null, "takeoff points toward Mars")
	_expect(store.load_primary()["state"]["ship"]["mode"] == Schema.ORBIT, "takeoff automatically saves")
	var moon_stock := _stock(router, Schema.MOON)
	action.pressed.emit()
	router.advance(60.0)
	await _settle()
	_expect(_stock(router, Schema.MOON) > moon_stock and router.snapshot()["ship"]["body_id"] == Schema.MARS,
			"Moon production continues while flying to Mars")
	action.pressed.emit()
	await _settle()
	_expect(router.snapshot()["colonies"].size() == 2 and action.text == "광석 찾기", "Mars has its own surface")
	game.call("_show_intro")
	await _settle()
	_expect(game.get("_resume").visible, "expedition can be continued from the menu")
	game.get("_resume").pressed.emit()
	await _settle()
	_expect(router.snapshot()["ship"]["body_id"] == Schema.MARS and router.snapshot()["ship"]["mode"] == Schema.SURFACE
			and _stock(router, Schema.MOON) > 2 and game.get("_surface") != null,
			"continue restores the surface and both colonies")
	game.queue_free()
	await process_frame
	print("Expedition tests: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _stock(router: RefCounted, body: String) -> int:
	return router.snapshot()["colonies"][body]["inventory"].get("ore", 0)


func _settle() -> void:
	await process_frame
	await process_frame


func _capture(label: String) -> void:
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--capture-dir="):
			continue
		await RenderingServer.frame_post_draw
		var path := arg.trim_prefix("--capture-dir=").path_join(label + ".png")
		var picture := root.get_texture().get_image()
		_expect(picture != null and picture.save_png(path) == OK, "capture " + label)
		return


func _expect(condition: bool, name: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + name)
