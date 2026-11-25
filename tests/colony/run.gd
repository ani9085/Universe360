extends SceneTree

# B1 colony contract tests (headless). Covers MVP_SPEC T05-T08 (economy), T09/T10 (tick behavior through
# the real Router with G0 mock navigation) and the T11 JSON and file round trips.
#   godot --headless --path . --script res://tests/colony/run.gd

const Schema := preload("res://src/contracts/schema.gd")
const GameState := preload("res://src/core/game_state.gd")
const Router := preload("res://src/core/command_router.gd")
const SaveJson := preload("res://src/core/save_json.gd")
const SaveStore := preload("res://src/core/save_store.gd")
const MockCatalog := preload("res://src/contracts/mocks/mock_catalog.gd")
const MockNavigation := preload("res://src/contracts/mocks/mock_navigation.gd")
const Colony := preload("res://src/colony/colony.gd")
const Terrain := preload("res://src/colony/terrain_generator.gd")
const ViewScene := preload("res://scenes/colony/colony_view.tscn")

const MOON := Schema.MOON
const MARS := Schema.MARS

var _module: Colony
var _failures := 0
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_module = Colony.new()
	_check(_module.balance.is_valid(), "balance data loads: " + _module.balance.error)
	if _module.balance.is_valid():
		_test_generation()
		_test_power_gate()
		_test_refine_chain()
		_test_rejections()
		_test_router_rejections()
		_test_numeric_id_order()
		_test_research_unlock()
		_test_storage_and_depletion()
		_test_all_colonies()
		_test_tick_through_router()
		_test_roundtrip()
		await _test_scene()
	print("B1 colony tests: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("FAIL: " + description)


# ---- helpers ---------------------------------------------------------------------------------

func _surface_state(body_id: String) -> Dictionary:
	var state := Schema.new_state(360)
	var colony: Dictionary = _module.create(body_id, 360)
	state["colonies"][colony["id"]] = colony
	state["ship"]["body_id"] = body_id
	state["ship"]["mode"] = Schema.SURFACE
	return state


func _move(state: Dictionary, colony_id: String, resource: String, amount: int) -> Dictionary:
	var result: Dictionary = _module.apply(state, {
		"type": "TRANSFER", "colony_id": colony_id, "resource": resource, "amount": amount,
		"direction": "ship_to_colony",
	})
	_check(result["ok"], "transfer %s %d: %s" % [resource, amount, result["message"]])
	return result["state"] if result["ok"] else state


func _build(state: Dictionary, colony_id: String, type: String, cell: Vector2i, deposit_id: Variant = null) -> Dictionary:
	var result: Dictionary = _module.apply(state, {
		"type": "BUILD", "colony_id": colony_id, "building_type": type,
		"grid_x": cell.x, "grid_y": cell.y, "deposit_id": deposit_id,
	})
	_check(result["ok"], "build %s at %s: %s" % [type, cell, result["message"]])
	return result["state"] if result["ok"] else state


func _deposits_of(colony: Dictionary, resource: String) -> Array:
	var found: Array = []
	for deposit: Dictionary in colony["deposits"]:
		if deposit["resource"] == resource:
			found.append(deposit)
	return found


func _cell_of(deposit: Dictionary) -> Vector2i:
	return Vector2i(deposit["grid_x"], deposit["grid_y"])


func _free_cells(colony: Dictionary, count: int) -> Array:
	var taken := {}
	for deposit: Dictionary in colony["deposits"]:
		taken[_cell_of(deposit)] = true
	for building: Dictionary in colony["buildings"]:
		taken[Vector2i(building["grid_x"], building["grid_y"])] = true
	var cells: Array = []
	for y in range(8, 24):
		for x in range(8, 24):
			if cells.size() < count and not taken.has(Vector2i(x, y)):
				cells.append(Vector2i(x, y))
	return cells


func _run_ticks(state: Dictionary, ticks: int) -> Dictionary:
	var current := state
	for _i in range(ticks):
		current = _module.step(current)
	return current


func _inventory(state: Dictionary, colony_id: String, resource: String) -> int:
	return state["colonies"][colony_id]["inventory"].get(resource, 0)


func _set_inventory(state: Dictionary, colony_id: String, inventory: Dictionary) -> void:
	state["colonies"][colony_id]["inventory"] = inventory


# Moon colony with solar + miner + refiner + lab, paid for through real TRANSFER and BUILD commands.
func _built_state(body_id: String) -> Dictionary:
	var state := _surface_state(body_id)
	state = _move(state, body_id, "metal", 50)
	state = _move(state, body_id, "parts", 20)
	var colony: Dictionary = state["colonies"][body_id]
	var ore: Dictionary = _deposits_of(colony, "ore")[0]
	var cells := _free_cells(colony, 3)
	state = _build(state, body_id, "solar", cells[0])
	state = _build(state, body_id, "miner", _cell_of(ore), ore["id"])
	state = _build(state, body_id, "refiner", cells[1])
	state = _build(state, body_id, "lab", cells[2])
	return state


# ---- T05: deterministic generation ------------------------------------------------------------

func _test_generation() -> void:
	var a: Dictionary = _module.create(MOON, 360)
	var b: Dictionary = _module.create(MOON, 360)
	_check(a == b, "T05 same seed, generator version and body give identical colony")
	_check(Schema.valid_colony(a), "created colony satisfies the schema")
	_check(a["generator_version"] == 1 and a["capacity"] == 100 and a["inventory"].is_empty(), "base colony fields")
	_check(a["id"] == MOON and a["body_id"] == MOON and a["buildings"].is_empty(), "colony id is the body id")
	_check(a["seed"] == Terrain.colony_seed(360, MOON), "colony seed uses the stable body hash")
	var mars: Dictionary = _module.create(MARS, 360)
	var other_seed: Dictionary = _module.create(MOON, 361)
	_check(mars["deposits"] != a["deposits"] and mars["seed"] != a["seed"], "different body gives different layout")
	_check(other_seed["deposits"] != a["deposits"], "different world seed gives different layout")
	var deposits: Array = a["deposits"]
	_check(deposits.size() == 8, "eight deposits")
	_check(_deposits_of(a, "ore").size() == 4 and _deposits_of(a, "ice").size() == 2
			and _deposits_of(a, "silicon").size() == 2, "three resource kinds: ore 4, ice 2, silicon 2")
	var spacing_ok := true
	var bounds_ok := true
	var ids_ok := true
	for i in range(deposits.size()):
		var one: Dictionary = deposits[i]
		ids_ok = ids_ok and one["id"] == "d%d" % (i + 1) and one["remaining"] == 1000
		bounds_ok = bounds_ok and one["grid_x"] >= 2 and one["grid_x"] <= 61 and one["grid_y"] >= 2 and one["grid_y"] <= 61
		bounds_ok = bounds_ok and maxi(absi(one["grid_x"] - 32), absi(one["grid_y"] - 32)) >= 5
		for j in range(i):
			var two: Dictionary = deposits[j]
			spacing_ok = spacing_ok and maxi(absi(one["grid_x"] - two["grid_x"]), absi(one["grid_y"] - two["grid_y"])) >= 4
	_check(ids_ok, "deposit ids d1..d8, 1000 remaining each")
	_check(bounds_ok, "deposits stay inside the 64x64 grid, off the landing pad")
	_check(spacing_ok, "deposit cells are distinct and spaced")
	var balance: RefCounted = _module.balance
	_check(balance.data["grid"]["size_m"] == 512 and balance.data["grid"]["cells"] * balance.data["grid"]["cell_m"] == 512, "zone is 512 m")
	var heights := Terrain.generate_heights(a["seed"], a["generator_version"], MOON, balance)
	var again := Terrain.generate_heights(a["seed"], a["generator_version"], MOON, balance)
	var mars_heights := Terrain.generate_heights(mars["seed"], mars["generator_version"], MARS, balance)
	_check(heights.size() == 65 * 65 and heights == again, "T05 height field is reproducible")
	_check(heights != mars_heights, "height field differs per body")
	_check(absf(Terrain.height_at(heights, 64, 8.0, 4.0, 4.0)) < 0.05, "landing pad is flat")


# ---- T06/T07: power gate and production chain -------------------------------------------------

func _test_power_gate() -> void:
	var state := _surface_state(MOON)
	state = _move(state, MOON, "metal", 50)
	state = _move(state, MOON, "parts", 20)
	var ore: Dictionary = _deposits_of(state["colonies"][MOON], "ore")[0]
	state = _build(state, MOON, "miner", _cell_of(ore), ore["id"])
	var idle := _run_ticks(state, 5)
	_check(_inventory(idle, MOON, "ore") == 0, "T06 miner without solar produces nothing")
	_check(idle["colonies"][MOON]["deposits"][0]["remaining"] == 1000, "T06 deposit untouched without power")
	var summary: Dictionary = _module.summarize(idle, MOON)
	_check(summary["buildings"][0]["status"] == "STOPPED" and summary["buildings"][0]["reason"] == "NO_POWER", "stop reason NO_POWER")
	state = _build(state, MOON, "solar", _free_cells(state["colonies"][MOON], 1)[0])
	var running := _run_ticks(state, 3)
	var after: Dictionary = running["colonies"][MOON]
	var ore_after: Dictionary = after["deposits"][0]
	_check(_inventory(running, MOON, "ore") == 6, "T06 ore +2 per tick after power")
	_check(ore_after["remaining"] == 994 and ore_after["id"] == ore["id"], "T06 deposit remaining decreases")
	_check(state["colonies"][MOON]["deposits"][0]["remaining"] == 1000, "step does not mutate its input")


func _test_refine_chain() -> void:
	var state := _surface_state(MOON)
	state = _move(state, MOON, "metal", 50)
	state = _move(state, MOON, "parts", 20)
	var ore: Dictionary = _deposits_of(state["colonies"][MOON], "ore")[0]
	var cells := _free_cells(state["colonies"][MOON], 2)
	state = _build(state, MOON, "solar", cells[0])
	state = _build(state, MOON, "miner", _cell_of(ore), ore["id"])
	state = _build(state, MOON, "refiner", cells[1])
	var metal_before := _inventory(state, MOON, "metal")
	_check(metal_before == 15 and _inventory(state, MOON, "parts") == 13, "build costs came out of colony inventory")
	_check(state["ship"]["cargo"]["metal"] == 0, "ship cargo was reduced by the transfer, not by building")
	var done := _run_ticks(state, 10)
	_check(_inventory(done, MOON, "metal") == metal_before + 10, "T07 miner + refiner give +10 metal in 10 ticks")
	_check(_inventory(done, MOON, "ore") == 0, "T07 refiner consumes all mined ore")
	_check(done["colonies"][MOON]["deposits"][0]["remaining"] == 980 and done["research"] == 0, "T07 deposit -20, no research without lab")
	var report := _module.summarize(done, MOON)
	_check(report["buildings"][1]["produced"] == {"ore": 2}
			and report["buildings"][2]["produced"] == {"metal": 1}, "T07 preview lists per-tick production")


# ---- T08: rejected commands never lose resources ---------------------------------------------

func _expect_rejection(state: Dictionary, command: Dictionary, code: String, description: String) -> void:
	var before := state.duplicate(true)
	var result: Dictionary = _module.apply(state, command)
	_check(not result["ok"] and result["code"] == code, "%s -> %s (got %s)" % [description, code, result["code"]])
	_check(not result["message"].is_empty(), description + " has a user-facing message")
	_check(state == before and result["state"] == before, description + " leaves state untouched")


func _build_command(type: String, cell: Vector2i, deposit_id: Variant = null) -> Dictionary:
	return {"type": "BUILD", "colony_id": MOON, "building_type": type, "grid_x": cell.x, "grid_y": cell.y, "deposit_id": deposit_id}


func _transfer_command(resource: Variant, amount: Variant, direction: Variant) -> Dictionary:
	return {"type": "TRANSFER", "colony_id": MOON, "resource": resource, "amount": amount, "direction": direction}


func _test_rejections() -> void:
	var state := _surface_state(MOON)
	var colony: Dictionary = state["colonies"][MOON]
	var ore: Dictionary = _deposits_of(colony, "ore")[0]
	var ice: Dictionary = _deposits_of(colony, "ice")[0]
	var silicon: Dictionary = _deposits_of(colony, "silicon")[0]
	var spots: Array = _free_cells(colony, 3)
	_expect_rejection(state, _build_command("solar", spots[0]), "INSUFFICIENT_RESOURCE", "T08 build with empty colony inventory")
	var stocked := _move(state, MOON, "metal", 50)
	stocked = _move(stocked, MOON, "parts", 20)
	_expect_rejection(_move(state, MOON, "metal", 50), _build_command("solar", spots[0]), "INSUFFICIENT_RESOURCE", "T08 metal but no parts")
	var partial := _move(state, MOON, "metal", 9)
	partial = _move(partial, MOON, "parts", 2)
	_expect_rejection(partial, _build_command("solar", spots[0]), "INSUFFICIENT_RESOURCE", "T08 metal 9 of 10")
	_expect_rejection(stocked, _build_command("solar", Vector2i(-1, 5)), "INVALID_PLACEMENT", "T08 negative grid")
	_expect_rejection(stocked, _build_command("solar", Vector2i(64, 5)), "INVALID_PLACEMENT", "T08 grid x past 512 m")
	_expect_rejection(stocked, _build_command("solar", Vector2i(5, 64)), "INVALID_PLACEMENT", "T08 grid y past 512 m")
	var fractional := _build_command("solar", spots[0])
	fractional["grid_x"] = 9.5
	_expect_rejection(stocked, fractional, "INVALID_PLACEMENT", "T08 non-integer grid")
	_expect_rejection(stocked, _build_command("solar", Vector2i(32, 32)), "INVALID_PLACEMENT", "T08 landing pad")
	_expect_rejection(stocked, _build_command("solar", Vector2i(33, 31)), "INVALID_PLACEMENT", "T08 landing pad edge")
	_expect_rejection(stocked, _build_command("tower", spots[0]), "INVALID_TARGET", "T08 unknown building type")
	_expect_rejection(stocked, _build_command("miner", spots[0], ore["id"]), "INVALID_PLACEMENT", "miner away from node")
	_expect_rejection(stocked, _build_command("miner", _cell_of(ice), ice["id"]), "INVALID_PLACEMENT", "miner on ice node")
	_expect_rejection(stocked, _build_command("miner", _cell_of(silicon), silicon["id"]), "INVALID_PLACEMENT", "miner on silicon node")
	_expect_rejection(stocked, _build_command("miner", _cell_of(ore), null), "INVALID_PLACEMENT", "miner without deposit id")
	_expect_rejection(stocked, _build_command("miner", _cell_of(ore), "d99"), "INVALID_PLACEMENT", "miner with wrong deposit id")
	_expect_rejection(stocked, _build_command("solar", _cell_of(ore)), "INVALID_PLACEMENT", "non-miner on a node")
	_expect_rejection(stocked, _build_command("solar", spots[0], ore["id"]), "INVALID_PLACEMENT", "non-miner with deposit id")
	var built := _build(stocked, MOON, "miner", _cell_of(ore), ore["id"])
	_expect_rejection(built, _build_command("miner", _cell_of(ore), ore["id"]), "INVALID_PLACEMENT", "second miner on the same node")
	built = _build(built, MOON, "solar", spots[0])
	_expect_rejection(built, _build_command("lab", spots[0]), "INVALID_PLACEMENT", "duplicate cell")
	_check(built["colonies"][MOON]["buildings"].size() == 2 and built["next_entity_id"] == 3, "entity ids advance only on success")
	var depleted := stocked.duplicate(true)
	depleted["colonies"][MOON]["deposits"][_deposit_index(depleted, ore["id"])]["remaining"] = 0
	_expect_rejection(depleted, _build_command("miner", _cell_of(ore), ore["id"]), "INVALID_PLACEMENT", "miner on depleted node")
	# transfers
	_expect_rejection(state, _transfer_command("ore", 1, "ship_to_colony"), "INSUFFICIENT_RESOURCE", "T08 ship has no ore")
	_expect_rejection(state, _transfer_command("metal", 51, "ship_to_colony"), "INSUFFICIENT_RESOURCE", "transfer more than ship holds")
	_expect_rejection(state, _transfer_command("metal", 1, "colony_to_ship"), "INSUFFICIENT_RESOURCE", "colony has nothing to send")
	_expect_rejection(state, _transfer_command("metal", 0, "ship_to_colony"), "INVALID_TARGET", "zero amount")
	_expect_rejection(state, _transfer_command("metal", -3, "ship_to_colony"), "INVALID_TARGET", "negative amount")
	_expect_rejection(state, _transfer_command("metal", 2.5, "ship_to_colony"), "INVALID_TARGET", "fractional amount")
	_expect_rejection(state, _transfer_command("gold", 1, "ship_to_colony"), "INVALID_TARGET", "unknown resource")
	_expect_rejection(state, _transfer_command("metal", 1, "sideways"), "INVALID_TARGET", "unknown direction")
	var nearly_full := state.duplicate(true)
	_set_inventory(nearly_full, MOON, {"silicon": 95})
	_expect_rejection(nearly_full, _transfer_command("metal", 10, "ship_to_colony"), "CAPACITY_EXCEEDED", "T08 colony storage full")
	var heavy := state.duplicate(true)
	heavy["ship"]["cargo"] = {"metal": 195}
	_set_inventory(heavy, MOON, {"ore": 10})
	_expect_rejection(heavy, _transfer_command("ore", 10, "colony_to_ship"), "CAPACITY_EXCEEDED", "ship cargo limit 200")
	var moved: Dictionary = _module.apply(state, _transfer_command("metal", 50, "ship_to_colony"))
	_check(moved["ok"] and moved["state"]["ship"]["cargo"]["metal"] == 0 and _inventory(moved["state"], MOON, "metal") == 50, "transfer moves exactly the amount")
	var back: Dictionary = _module.apply(moved["state"], _transfer_command("metal", 20, "colony_to_ship"))
	_check(back["ok"] and back["state"]["ship"]["cargo"]["metal"] == 20 and _inventory(back["state"], MOON, "metal") == 30, "transfer back to the ship")
	_expect_rejection(state, {"type": "REFUEL"}, "UNKNOWN_COMMAND", "unknown colony command")
	var orbit := state.duplicate(true)
	orbit["ship"]["mode"] = Schema.ORBIT
	_expect_rejection(orbit, _transfer_command("metal", 5, "ship_to_colony"), "INVALID_MODE", "transfer from orbit")
	_expect_rejection(orbit, _build_command("solar", spots[0]), "INVALID_MODE", "build from orbit")
	var elsewhere := state.duplicate(true)
	elsewhere["ship"]["body_id"] = MARS
	_expect_rejection(elsewhere, _transfer_command("metal", 5, "ship_to_colony"), "INVALID_MODE", "ship at a different body")
	var missing := _transfer_command("metal", 5, "ship_to_colony")
	missing["colony_id"] = "sol.venus"
	_expect_rejection(state, missing, "INVALID_TARGET", "unknown colony id")


func _deposit_index(state: Dictionary, deposit_id: String) -> int:
	var deposits: Array = state["colonies"][MOON]["deposits"]
	for index in range(deposits.size()):
		if deposits[index]["id"] == deposit_id:
			return index
	return -1


func _test_router_rejections() -> void:
	var router := _router_with(_surface_state(MOON))
	var before := router.snapshot()
	var result: Dictionary = router.dispatch(_build_command("solar", Vector2i(10, 10)))
	_check(not result["ok"] and result["code"] == "INSUFFICIENT_RESOURCE", "router relays BUILD rejection code")
	_check(router.snapshot() == before, "router state unchanged after rejected BUILD")
	var moved: Dictionary = router.dispatch(_transfer_command("metal", 50, "ship_to_colony"))
	_check(moved["ok"] and moved["state"]["colonies"][MOON]["inventory"]["metal"] == 50, "router TRANSFER succeeds")
	var takeoff: Dictionary = router.dispatch({"type": "TAKEOFF"})
	_check(takeoff["ok"], "mock TAKEOFF works")
	var orbit: Dictionary = router.dispatch(_build_command("solar", Vector2i(10, 10)))
	_check(not orbit["ok"] and orbit["code"] == "INVALID_MODE", "router blocks BUILD while in orbit")
	var land: Dictionary = router.dispatch({"type": "LAND", "body_id": MOON})
	_check(land["ok"] and land["state"]["colonies"].size() == 1, "re-landing keeps the existing colony")
	_check(land["state"]["colonies"][MOON]["inventory"]["metal"] == 50, "existing colony inventory preserved on re-landing")


func _router_with(state: Dictionary) -> Router:
	var router := Router.new(GameState.new(), MockNavigation.new(MockCatalog.new()), _module)
	_check(router.restore(state), "router accepts the colony test state")
	return router


# ---- ordering, research, storage ------------------------------------------------------------

func _test_numeric_id_order() -> void:
	var state := _surface_state(MOON)
	_set_inventory(state, MOON, {"metal": 85, "parts": 10})
	var colony: Dictionary = state["colonies"][MOON]
	var ores: Array = _deposits_of(colony, "ore")
	var cells := _free_cells(colony, 8)
	for index in range(7):
		state = _build(state, MOON, "warehouse", cells[index])
	state = _build(state, MOON, "solar", cells[7])
	for ore: Dictionary in ores:
		state = _build(state, MOON, "miner", _cell_of(ore), ore["id"])
	var ids: Array = []
	for building: Dictionary in state["colonies"][MOON]["buildings"]:
		ids.append(building["id"])
	_check("b10" in ids and "b12" in ids, "building ids pass b9 -> b10")
	_check(state["colonies"][MOON]["capacity"] == 800, "seven warehouses raise capacity to base 100 + 700")
	var next := _module.step(state)
	var report: Dictionary = _module.summarize(state, MOON)
	var by_id := {}
	for entry: Dictionary in report["buildings"]:
		by_id[entry["id"]] = entry
	_check(by_id["b9"]["status"] == "RUNNING" and by_id["b10"]["status"] == "RUNNING" and by_id["b11"]["status"] == "RUNNING",
			"three miners fit in 10 power (numeric id order b9, b10, b11)")
	_check(by_id["b12"]["status"] == "STOPPED" and by_id["b12"]["reason"] == "NO_POWER", "fourth miner b12 waits for power")
	_check(_inventory(next, MOON, "ore") == 6, "only three miners produced ore")
	var idle_deposit: Dictionary = next["colonies"][MOON]["deposits"][_deposit_index(next, ores[3]["id"])]
	_check(idle_deposit["remaining"] == 1000, "stopped miner did not touch its node")
	_check(report["power_supply"] == 10 and report["power_used"] == 9, "power summary 10 supply, 9 used")


func _test_research_unlock() -> void:
	var state := _surface_state(MOON)
	_set_inventory(state, MOON, {"metal": 70, "parts": 10})
	var colony: Dictionary = state["colonies"][MOON]
	var ore: Dictionary = _deposits_of(colony, "ore")[0]
	var cells := _free_cells(colony, 2)
	state = _build(state, MOON, "solar", cells[0])
	state = _build(state, MOON, "miner", _cell_of(ore), ore["id"])
	state = _build(state, MOON, "lab", cells[1])
	var at_twenty := _run_ticks(state, 20)
	_check(at_twenty["research"] == 20 and at_twenty["colonies"][MOON]["research"] == 20, "lab turns 1 metal into 1 research per tick")
	_check(_inventory(at_twenty, MOON, "ore") == 40 and at_twenty["colonies"][MOON]["upgrades"].is_empty(), "rate stays 2 until research 20 is reached")
	var after := _module.step(at_twenty)
	_check("mining_efficiency_1" in after["colonies"][MOON]["upgrades"], "research 20 unlocks mining efficiency")
	_check(_inventory(after, MOON, "ore") == 43, "mining rate becomes 3 on the tick after the threshold")
	var summary: Dictionary = _module.summarize(at_twenty, MOON)
	_check(summary["mining_unlocked"] and summary["miner_rate"] == 3, "summary reports the unlock")
	var starved := _surface_state(MOON)
	_set_inventory(starved, MOON, {"metal": 25, "parts": 7})
	starved = _build(starved, MOON, "solar", cells[0])
	starved = _build(starved, MOON, "lab", cells[1])
	_set_inventory(starved, MOON, {})
	var idle := _module.step(starved)
	_check(idle["research"] == 0, "lab without metal does not research")
	_check(_module.summarize(starved, MOON)["buildings"][1]["reason"] == "NO_INPUT", "stop reason NO_INPUT")


func _test_storage_and_depletion() -> void:
	var state := _surface_state(MOON)
	_set_inventory(state, MOON, {"metal": 30, "parts": 6})
	var ore: Dictionary = _deposits_of(state["colonies"][MOON], "ore")[0]
	state = _build(state, MOON, "solar", _free_cells(state["colonies"][MOON], 1)[0])
	state = _build(state, MOON, "miner", _cell_of(ore), ore["id"])
	var index := _deposit_index(state, ore["id"])
	var full := state.duplicate(true)
	_set_inventory(full, MOON, {"metal": 10, "parts": 2, "ore": 87})
	var blocked := _module.step(full)
	_check(_inventory(blocked, MOON, "ore") == 87 and blocked["colonies"][MOON]["deposits"][index]["remaining"] == 1000,
			"full storage stops the miner completely (no partial mining)")
	_check(_module.summarize(full, MOON)["buildings"][1]["reason"] == "STORAGE_FULL", "stop reason STORAGE_FULL")
	var almost := state.duplicate(true)
	_set_inventory(almost, MOON, {"metal": 10, "parts": 2, "ore": 86})
	_check(_inventory(_module.step(almost), MOON, "ore") == 88, "exactly full storage still accepts the batch")
	var nearly_empty := state.duplicate(true)
	nearly_empty["colonies"][MOON]["deposits"][index]["remaining"] = 1
	var one := _module.step(nearly_empty)
	_check(_inventory(one, MOON, "ore") == _inventory(nearly_empty, MOON, "ore") + 1, "mines only what remains")
	_check(one["colonies"][MOON]["deposits"][index]["remaining"] == 0, "node reaches 0, never negative")
	var empty := _module.step(one)
	_check(_inventory(empty, MOON, "ore") == _inventory(one, MOON, "ore"), "depleted node yields nothing")
	_check(_module.summarize(one, MOON)["buildings"][1]["reason"] == "DEPOSIT_EMPTY", "stop reason DEPOSIT_EMPTY")
	var with_warehouse := _build(state, MOON, "warehouse", _free_cells(state["colonies"][MOON], 2)[1])
	_check(_module.capacity_of(with_warehouse["colonies"][MOON]) == 200 and with_warehouse["colonies"][MOON]["capacity"] == 200, "warehouse +100 capacity")
	var warehouse_report := _module.summarize(with_warehouse, MOON)
	_check(warehouse_report["counts"].get("warehouse") == 1
			and warehouse_report["buildings"].back()["status"] == "PASSIVE", "warehouse appears in the facility summary")


# ---- every colony ticks ---------------------------------------------------------------------

func _test_all_colonies() -> void:
	var moon_state := _built_state(MOON)
	var mars_state := _built_state(MARS)
	var both := moon_state.duplicate(true)
	both["colonies"][MARS] = mars_state["colonies"][MARS].duplicate(true)
	both["next_entity_id"] = 100
	both["ship"]["body_id"] = Schema.EARTH
	both["ship"]["mode"] = Schema.ORBIT
	_check(Schema.validate_state(both), "two-colony state is valid")
	# Fewer than 10 ticks: combined research stays below the unlock threshold, so colonies are independent.
	var after := _run_ticks(both, 8)
	var moon_alone := _run_ticks(moon_state, 8)
	var mars_alone := _run_ticks(mars_state, 8)
	_check(after["colonies"][MOON] == moon_alone["colonies"][MOON], "moon colony ticks the same with or without other colonies")
	_check(after["colonies"][MARS] == mars_alone["colonies"][MARS], "mars colony ticks independently")
	_check(after["research"] == 16 and after["research"] == moon_alone["research"] + mars_alone["research"], "global research adds every colony's lab output")
	_check(after["colonies"][MOON]["deposits"][_deposit_index(after, _deposits_of(moon_state["colonies"][MOON], "ore")[0]["id"])]["remaining"] < 1000
			and _deposits_of(after["colonies"][MARS], "ore")[0]["remaining"] < 1000, "both colonies mined while the ship is in Earth orbit")
	# Shared research: two labs reach 20 earlier than one, and the unlock reaches every colony.
	var shared := _run_ticks(both, 15)
	_check("mining_efficiency_1" in shared["colonies"][MOON]["upgrades"] and "mining_efficiency_1" in shared["colonies"][MARS]["upgrades"],
			"global research unlock applies to every colony")
	_check(_run_ticks(moon_state, 15)["colonies"][MOON]["upgrades"].is_empty(), "one lab alone has not unlocked it at tick 15")
	var lone_research := _surface_state(MARS)
	lone_research["research"] = 20
	_check("mining_efficiency_1" in _module.step(lone_research)["colonies"][MARS]["upgrades"], "global research unlocks new colonies")


# ---- T09/T10 through the real Router -------------------------------------------------------

func _test_tick_through_router() -> void:
	var state := _built_state(MOON)
	var expected := _run_ticks(state, 60)
	var away := _router_with(state)
	_check(away.dispatch({"type": "TAKEOFF"})["ok"], "T09 take off")
	_check(away.dispatch({"type": "TRAVEL", "body_id": MARS})["ok"], "T09 travel to Mars")
	_check(away.advance(60.0) == 60, "T09 60 ticks pass")
	var snapshot := away.snapshot()
	_check(snapshot["ship"]["body_id"] == MARS and snapshot["ship"]["mode"] == Schema.ORBIT, "T09 ship now orbits Mars")
	_check(snapshot["colonies"][MOON] == expected["colonies"][MOON], "T09 Moon production while away equals the local 60-tick run")
	_check(snapshot["research"] == expected["research"] and snapshot["tick"] == 60, "T09 research and tick counter")
	var speeds := {}
	for speed in [1, 10, 60]:
		var router := _router_with(state)
		_check(router.dispatch({"type": "SET_SPEED", "speed": speed})["ok"], "T10 set speed %d" % speed)
		var processed := router.advance(60.0 / speed)
		speeds[speed] = router.snapshot()
		_check(processed == 60 and speeds[speed]["tick"] == 60, "T10 %dx gives 60 ticks" % speed)
		_check(speeds[speed]["colonies"] == expected["colonies"] and speeds[speed]["research"] == expected["research"], "T10 %dx colony result identical" % speed)
	var paused := _router_with(state)
	_check(paused.dispatch({"type": "SET_PAUSED", "paused": true})["ok"], "T10 pause")
	var frozen := paused.snapshot()
	_check(paused.advance(30.0) == 0 and paused.snapshot() == frozen, "T10 inventory and ticks stay frozen while paused")


# ---- T11: JSON round trip ------------------------------------------------------------------

func _test_roundtrip() -> void:
	var state := _run_ticks(_built_state(MOON), 25)
	var parsed: Variant = SaveJson.new().parse(JSON.stringify(state))
	_check(parsed is Dictionary and Schema.validate_state(parsed), "T11 saved colony state parses and validates")
	_check(parsed == state, "T11 JSON round trip is lossless (buildings, deposits, inventory, research, upgrades, seed)")
	var continued_a := _run_ticks(state, 15)
	var continued_b := _run_ticks(parsed, 15)
	_check(continued_a == continued_b, "T11 simulation continues identically after reload")
	var recreated: Dictionary = _module.create(MOON, 360)
	_check(recreated["deposits"] == _surface_state(MOON)["colonies"][MOON]["deposits"], "T11 regenerated layout matches the saved seed")
	var heights := Terrain.generate_heights(state["colonies"][MOON]["seed"], state["colonies"][MOON]["generator_version"], MOON, _module.balance)
	_check(heights == Terrain.generate_heights(parsed["colonies"][MOON]["seed"], parsed["colonies"][MOON]["generator_version"], MOON, _module.balance),
			"T11 terrain regenerates from the saved seed and generator version")
	var folder := DirAccess.create_temp("universe360-colony")
	_check(folder != null, "T11 temporary save directory")
	if folder == null:
		return
	var path := folder.get_current_dir().path_join("colony.json")
	var saved := SaveStore.new(path).save(state)
	_check(saved["ok"], "T11 writes the colony save through SaveStore")
	if saved["ok"]:
		var loaded := SaveStore.new(path).load_primary()
		_check(loaded["ok"] and loaded["state"] == state, "T11 fresh SaveStore reads the same colony state")


# ---- standalone scene smoke test -----------------------------------------------------------

func _test_scene() -> void:
	var view: Node = ViewScene.instantiate()
	root.add_child(view)
	for _i in range(3):
		await process_frame
	var router: RefCounted = view.get("_router")
	var colony_id: String = view.get("_colony_id")
	_check(router != null and colony_id == MOON, "scene starts a standalone Moon session")
	var snapshot: Dictionary = router.snapshot()
	_check(snapshot["ship"]["mode"] == Schema.SURFACE and snapshot["colonies"].has(MOON), "scene session is landed on the Moon")
	_check(view.get("_deposit_nodes").size() == 8, "scene shows all eight deposits")
	var options: OptionButton = view.get("_resource_option")
	options.select(1)
	var amount: SpinBox = view.get("_amount_box")
	amount.value = 20
	view.call("_transfer", "ship_to_colony")
	_check(router.snapshot()["colonies"][MOON]["inventory"].get("metal", 0) == 20, "UI transfer reaches the colony through the router")
	options.select(4)
	amount.value = 10
	view.call("_transfer", "ship_to_colony")
	var spot: Vector2i = _free_cells(router.snapshot()["colonies"][MOON], 1)[0]
	view.set("_hover", spot)
	view.call("_set_selected", "solar")
	view.call("_place_at_hover")
	_check(router.snapshot()["colonies"][MOON]["buildings"].size() == 1, "UI build goes through router.dispatch")
	view.call("_set_selected", "miner")
	view.call("_place_at_hover")
	_check(router.snapshot()["colonies"][MOON]["buildings"].size() == 1, "UI build on a bad cell is rejected")
	for _i in range(3):
		await process_frame
	_check(view.get("_building_nodes").size() == 1, "scene draws the new building")
	view.queue_free()
	await process_frame
