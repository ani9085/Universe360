extends RefCounted

const Colony = preload("res://src/colony/colony.gd")


static func ore_mined(colony: Dictionary, initial_stock: int) -> int:
	var extracted := 0
	for deposit: Dictionary in colony.get("deposits", []):
		if deposit["resource"] == "ore":
			extracted += maxi(initial_stock - deposit["remaining"], 0)
	return extracted


static func find_deposit(colony: Dictionary, pad: Vector2i) -> Dictionary:
	var occupied: Array = []
	for building: Dictionary in colony.get("buildings", []):
		occupied.append(building["deposit_id"])
	var nearest := {}
	var best_distance := INF
	for deposit: Dictionary in colony.get("deposits", []):
		if deposit["resource"] != "ore" or deposit["remaining"] <= 0 or deposit["id"] in occupied:
			continue
		var distance := Vector2(pad).distance_squared_to(Vector2(deposit["grid_x"], deposit["grid_y"]))
		if distance < best_distance:
			nearest = deposit
			best_distance = distance
	return nearest


static func has_miner(colony: Dictionary) -> bool:
	for building: Dictionary in colony.get("buildings", []):
		if building["type"] == "miner":
			return true
	return false


static func plan(module: Colony, state: Dictionary, colony_id: String, deposit: Dictionary) -> Dictionary:
	var colony: Dictionary = state["colonies"].get(colony_id, {})
	if colony.is_empty() or deposit.is_empty():
		return {"ok": false, "message": "채굴할 광석을 찾지 못했어요."}
	var draft := state.duplicate(true)
	var orders: Array[Dictionary] = []
	var origin := Vector2i(deposit["grid_x"], deposit["grid_y"])
	var power_available: bool = module.summarize(state, colony_id)["power_supply"] > 0
	if not power_available:
		var solar := _solar_cell(module, colony, origin)
		if solar.x < 0:
			return {"ok": false, "message": "발전기를 놓을 빈칸이 필요해요."}
		var result := _prepare(module, draft, orders, colony_id, "solar", solar)
		if not result["ok"]:
			return result
		draft = result["state"]
	var miner := _prepare(module, draft, orders, colony_id, "miner", origin, deposit["id"])
	if not miner["ok"]:
		return miner
	return {"ok": true, "orders": orders}


static func _solar_cell(module: Colony, colony: Dictionary, origin: Vector2i) -> Vector2i:
	for distance in range(1, 9):
		for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP,
				Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)]:
			var cell: Vector2i = origin + direction * distance
			if module.placement_problem(colony, "solar", cell.x, cell.y, null).is_empty():
				return cell
	return Vector2i(-1, -1)


static func _prepare(module: Colony, state: Dictionary, orders: Array[Dictionary], colony_id: String,
		type: String, cell: Vector2i, deposit_id: Variant = null) -> Dictionary:
	var shortage := module.cost_shortage(state["colonies"][colony_id], type)
	var draft := state
	for resource: String in shortage:
		var transfer := {"type": "TRANSFER", "colony_id": colony_id, "resource": resource,
				"amount": shortage[resource], "direction": "ship_to_colony"}
		var moved := module.apply(draft, transfer)
		if not moved["ok"]:
			return _supplies_error(moved)
		orders.append(transfer)
		draft = moved["state"]
	var build := {"type": "BUILD", "colony_id": colony_id, "building_type": type,
			"grid_x": cell.x, "grid_y": cell.y, "deposit_id": deposit_id}
	var outcome := module.apply(draft, build)
	if outcome["ok"]:
		orders.append(build)
	return outcome


static func _supplies_error(result: Dictionary) -> Dictionary:
	var message: String = result["message"]
	if result["code"] == "INSUFFICIENT_RESOURCE":
		message = "우주선에 건설 재료가 부족해요. 기지 관리에서 재고를 확인해 보세요."
	elif result["code"] == "CAPACITY_EXCEEDED":
		message = "기지 저장고에 빈자리가 필요해요. 기지 관리에서 재고를 확인해 보세요."
	return {"ok": false, "message": message}
