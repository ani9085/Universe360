extends RefCounted

# Colony module (B1). Implements the CONTRACT.md Colony interface:
#   create(body_id, world_seed) -> colony Dictionary
#   apply(state, command)       -> {ok, code, message, state}   (BUILD, TRANSFER)
#   step(state)                 -> state                         (fixed 1 s tick, every colony)
# plus read-only helpers for UI (summarize, placement_problem, cost_shortage).
#
# Rules (MVP_SPEC section 4, all game assumptions):
#  * Colony inventory starts empty. Build costs are paid from the COLONY inventory,
#    so resources must be moved from the ship with TRANSFER first.
#  * Only ore deposits can be mined in P0; ice/silicon deposits are info-only.
#  * apply() never mutates its input. Failure returns the unchanged state and a Korean message.
#  * step() processes colonies in id order, buildings in solar -> miner -> refiner -> lab order,
#    and equal types in numeric building-id order. Power is not stored; it is allocated every tick
#    in that order. A building draws power only if it actually runs (no partial consumption).
#  * Research unlocks are decided from the global research at the START of the tick, so the result
#    does not depend on colony processing order.

const Schema := preload("res://src/contracts/schema.gd")
const Balance := preload("res://src/colony/balance.gd")
const Terrain := preload("res://src/colony/terrain_generator.gd")

const GENERATOR_VERSION := Terrain.GENERATOR_VERSION
const UPGRADE_MINING := "mining_efficiency_1"
const RESOURCE_KO := {"ore": "광석", "metal": "금속", "ice": "얼음", "silicon": "실리콘", "parts": "부품"}
const REASON_TEXT := {
	"": "가동 중",
	"NO_POWER": "전력 부족",
	"NO_INPUT": "재료 부족",
	"STORAGE_FULL": "저장 공간 부족",
	"DEPOSIT_EMPTY": "노드 고갈",
}

var balance: RefCounted


func _init(custom_balance: RefCounted = null) -> void:
	balance = custom_balance if custom_balance != null else Balance.load_default()


func create(body_id: String, world_seed: int) -> Dictionary:
	if not balance.is_valid():
		push_error(balance.error)
		return {}
	var seed := Terrain.colony_seed(world_seed, body_id)
	var colony := Schema.new_colony(body_id, seed, GENERATOR_VERSION)
	colony["capacity"] = balance.data["storage"]["base_capacity"]
	colony["deposits"] = Terrain.generate_deposits(seed, GENERATOR_VERSION, balance)
	return colony


func apply(state: Dictionary, command: Dictionary) -> Dictionary:
	if not balance.is_valid():
		return _fail(state, "INVALID_STATE", "기지 밸런스 데이터를 불러오지 못했습니다. " + balance.error)
	match command.get("type"):
		"BUILD":
			return _build(state, command)
		"TRANSFER":
			return _transfer(state, command)
	return _fail(state, "UNKNOWN_COMMAND", "지원하지 않는 기지 명령입니다.")


func step(state: Dictionary) -> Dictionary:
	var next := state.duplicate(true)
	if not balance.is_valid():
		return next
	var research_at_start: int = next["research"]
	var ids: Array = next["colonies"].keys()
	ids.sort()
	for colony_id: String in ids:
		var result := _run_colony(next["colonies"][colony_id], research_at_start, false)
		next["research"] += result["research_gained"]
	return next


# ---- read-only helpers for UI and tests ------------------------------------------------------

func capacity_of(colony: Dictionary) -> int:
	var count := 0
	for building: Dictionary in colony["buildings"]:
		if building["type"] == "warehouse":
			count += 1
	var bonus: int = balance.building("warehouse").get("capacity_bonus", 0)
	return balance.data["storage"]["base_capacity"] + count * bonus


func used_storage(colony: Dictionary) -> int:
	return _total(colony["inventory"])


func cost_shortage(colony: Dictionary, building_type: String) -> Dictionary:
	var shortage := {}
	var cost: Dictionary = balance.cost(building_type)
	for resource: String in cost:
		var missing: int = cost[resource] - colony["inventory"].get(resource, 0)
		if missing > 0:
			shortage[resource] = missing
	return shortage


# Returns {} when the placement is valid, otherwise {"code", "message"}.
func placement_problem(colony: Dictionary, building_type: String, grid_x: Variant, grid_y: Variant,
		deposit_id: Variant) -> Dictionary:
	var grid: Dictionary = balance.data["grid"]
	var cells: int = grid["cells"]
	if typeof(grid_x) != TYPE_INT or typeof(grid_y) != TYPE_INT:
		return _problem("INVALID_PLACEMENT", "격자 좌표는 정수여야 합니다.")
	if grid_x < 0 or grid_y < 0 or grid_x >= cells or grid_y >= cells:
		return _problem("INVALID_PLACEMENT", "건설 구역(%d m × %d m) 밖입니다." % [grid["size_m"], grid["size_m"]])
	var pad: Array = grid["landing_pad_cell"]
	var reserved: int = grid.get("landing_pad_reserved_radius_cells", 0)
	if maxi(absi(grid_x - pad[0]), absi(grid_y - pad[1])) <= reserved:
		return _problem("INVALID_PLACEMENT", "착륙대에는 건설할 수 없습니다.")
	for building: Dictionary in colony["buildings"]:
		if building["grid_x"] == grid_x and building["grid_y"] == grid_y:
			return _problem("INVALID_PLACEMENT", "이미 시설이 있는 칸입니다.")
	var deposit := _deposit_at(colony, grid_x, grid_y)
	if building_type == "miner":
		var needed: String = balance.building("miner")["requires_deposit_resource"]
		if deposit.is_empty():
			return _problem("INVALID_PLACEMENT", "채굴기는 광석 노드 위에만 건설할 수 있습니다.")
		if deposit["resource"] != needed:
			return _problem("INVALID_PLACEMENT", "이 노드는 정보 표시용입니다. P0에서는 광석 노드만 채굴할 수 있습니다.")
		if deposit_id == null:
			return _problem("INVALID_PLACEMENT", "채굴기는 광석 노드를 지정해야 합니다.")
		if deposit_id != deposit["id"]:
			return _problem("INVALID_PLACEMENT", "지정한 노드가 선택한 칸의 노드와 다릅니다.")
		if deposit["remaining"] <= 0:
			return _problem("INVALID_PLACEMENT", "고갈된 노드에는 건설할 수 없습니다.")
		for building: Dictionary in colony["buildings"]:
			if building["deposit_id"] == deposit["id"]:
				return _problem("INVALID_PLACEMENT", "이미 채굴기가 배치된 노드입니다.")
		return {}
	if not deposit.is_empty():
		return _problem("INVALID_PLACEMENT", "자원 노드 위에는 채굴기만 건설할 수 있습니다.")
	if deposit_id != null:
		return _problem("INVALID_PLACEMENT", "이 시설은 노드를 지정할 수 없습니다.")
	return {}


# Dry-run of the NEXT tick for the colony summary UI. Does not change state.
func summarize(state: Dictionary, colony_id: String) -> Dictionary:
	if not balance.is_valid() or not state["colonies"].has(colony_id):
		return {}
	var colony: Dictionary = state["colonies"][colony_id].duplicate(true)
	var predicted := _run_colony(colony, state["research"], true)
	var source: Dictionary = state["colonies"][colony_id]
	var counts := {}
	var entries: Array = []
	for entry: Dictionary in predicted["buildings"]:
		counts[entry["type"]] = counts.get(entry["type"], 0) + 1
		entry["name_ko"] = balance.building(entry["type"]).get("name_ko", entry["type"])
		entry["reason_ko"] = REASON_TEXT.get(entry["reason"], entry["reason"])
		entries.append(entry)
	var remaining := {}
	for deposit: Dictionary in source["deposits"]:
		remaining[deposit["resource"]] = remaining.get(deposit["resource"], 0) + deposit["remaining"]
	var inventory := {}
	for resource: String in Schema.RESOURCES:
		inventory[resource] = source["inventory"].get(resource, 0)
	var unlock: Dictionary = balance.data["research"][UPGRADE_MINING]
	var mining_unlocked: bool = UPGRADE_MINING in source["upgrades"] or state["research"] >= unlock["threshold"]
	return {
		"colony_id": colony_id, "body_id": source["body_id"], "inventory": inventory,
		"used_storage": _total(source["inventory"]), "capacity": capacity_of(source),
		"power_supply": predicted["power_supply"], "power_used": predicted["power_used"],
		"buildings": entries, "counts": counts, "deposit_remaining": remaining,
		"research_global": state["research"], "research_colony": source["research"],
		"research_threshold": unlock["threshold"], "mining_unlocked": mining_unlocked,
		"miner_rate": balance.building("miner")["mine_rate"]
				+ (unlock["miner_rate_bonus"] if mining_unlocked else 0),
		"ship_cargo": state["ship"]["cargo"].duplicate(true), "ship_cargo_total": _total(state["ship"]["cargo"]),
		"ship_cargo_limit": balance.data["storage"]["ship_cargo_limit"],
	}


# ---- commands ---------------------------------------------------------------------------------

func _build(state: Dictionary, command: Dictionary) -> Dictionary:
	var located := _locate(state, command.get("colony_id"))
	if not located.is_empty():
		return _fail(state, located["code"], located["message"])
	var building_type: Variant = command.get("building_type")
	if not building_type is String or building_type not in Balance.BUILDING_TYPES:
		return _fail(state, "INVALID_TARGET", "알 수 없는 시설 종류입니다.")
	var next := state.duplicate(true)
	var colony: Dictionary = next["colonies"][command["colony_id"]]
	var grid_x: Variant = command.get("grid_x")
	var grid_y: Variant = command.get("grid_y")
	var deposit_id: Variant = command.get("deposit_id")
	var problem := placement_problem(colony, building_type, grid_x, grid_y, deposit_id)
	if not problem.is_empty():
		return _fail(state, problem["code"], problem["message"])
	var shortage := cost_shortage(colony, building_type)
	if not shortage.is_empty():
		return _fail(state, "INSUFFICIENT_RESOURCE", "기지 재고가 부족합니다: " + _describe(shortage) + " 더 필요합니다. 우주선에서 먼저 이전하세요.")
	var cost: Dictionary = balance.cost(building_type)
	for resource: String in cost:
		colony["inventory"][resource] = colony["inventory"].get(resource, 0) - cost[resource]
	var building := {
		"id": "b%d" % next["next_entity_id"], "type": building_type,
		"grid_x": grid_x, "grid_y": grid_y, "deposit_id": deposit_id,
	}
	next["next_entity_id"] += 1
	colony["buildings"].append(building)
	colony["capacity"] = capacity_of(colony)
	var name_ko: String = balance.building(building_type).get("name_ko", building_type)
	return Schema.result(true, "OK", "%s을(를) 건설했습니다." % name_ko, next)


func _transfer(state: Dictionary, command: Dictionary) -> Dictionary:
	var located := _locate(state, command.get("colony_id"))
	if not located.is_empty():
		return _fail(state, located["code"], located["message"])
	var resource: Variant = command.get("resource")
	var amount: Variant = command.get("amount")
	var direction: Variant = command.get("direction")
	if not resource is String or resource not in Schema.RESOURCES:
		return _fail(state, "INVALID_TARGET", "알 수 없는 자원입니다.")
	if typeof(amount) != TYPE_INT or amount <= 0:
		return _fail(state, "INVALID_TARGET", "이전 수량은 1 이상의 정수여야 합니다.")
	if direction not in ["ship_to_colony", "colony_to_ship"]:
		return _fail(state, "INVALID_TARGET", "이전 방향이 올바르지 않습니다.")
	var next := state.duplicate(true)
	var colony: Dictionary = next["colonies"][command["colony_id"]]
	var ship_cargo: Dictionary = next["ship"]["cargo"]
	var inventory: Dictionary = colony["inventory"]
	var to_colony: bool = direction == "ship_to_colony"
	var source: Dictionary = ship_cargo if to_colony else inventory
	var target: Dictionary = inventory if to_colony else ship_cargo
	var limit: int = capacity_of(colony) if to_colony else balance.data["storage"]["ship_cargo_limit"]
	if source.get(resource, 0) < amount:
		var where := "우주선 화물" if to_colony else "기지 재고"
		return _fail(state, "INSUFFICIENT_RESOURCE", "%s이(가) 부족합니다 (보유 %d, 요청 %d)." % [where, source.get(resource, 0), amount])
	if _total(target) + amount > limit:
		var what := "기지 저장 공간" if to_colony else "우주선 화물 한도"
		return _fail(state, "CAPACITY_EXCEEDED", "%s이(가) 부족합니다 (한도 %d, 이전 후 %d)." % [what, limit, _total(target) + amount])
	source[resource] = source.get(resource, 0) - amount
	target[resource] = target.get(resource, 0) + amount
	var text := "%s %d 단위를 %s(으)로 이전했습니다." % [RESOURCE_KO.get(resource, resource), amount, "기지" if to_colony else "우주선"]
	return Schema.result(true, "OK", text, next)


func _locate(state: Dictionary, colony_id: Variant) -> Dictionary:
	if not colony_id is String or not state["colonies"].has(colony_id):
		return _problem("INVALID_TARGET", "기지를 찾을 수 없습니다.")
	var ship: Dictionary = state["ship"]
	if ship["mode"] != Schema.SURFACE or ship["body_id"] != state["colonies"][colony_id]["body_id"]:
		return _problem("INVALID_MODE", "해당 기지의 표면에 착륙해 있어야 합니다.")
	return {}


# ---- production tick --------------------------------------------------------------------------

# Mutates `colony` in place. Returns {research_gained, power_supply, power_used, buildings}.
func _run_colony(colony: Dictionary, research_at_start: int, preview: bool) -> Dictionary:
	var unlock: Dictionary = balance.data["research"][UPGRADE_MINING]
	if research_at_start >= unlock["threshold"] and UPGRADE_MINING not in colony["upgrades"]:
		colony["upgrades"].append(UPGRADE_MINING)
	colony["capacity"] = capacity_of(colony)
	var capacity: int = colony["capacity"]
	var inventory: Dictionary = colony["inventory"]
	var bonus: int = unlock["miner_rate_bonus"] if UPGRADE_MINING in colony["upgrades"] else 0
	var by_type := {}
	for building: Dictionary in colony["buildings"]:
		if not by_type.has(building["type"]):
			by_type[building["type"]] = []
		by_type[building["type"]].append(building)
	for list: Array in by_type.values():
		list.sort_custom(_building_before)
	var report: Array = []
	var gained := 0
	var power_supply := 0
	var power_left := 0
	var power_used := 0
	for type: String in balance.data["process_order"]:
		for building: Dictionary in by_type.get(type, []):
			var info: Dictionary = balance.building(type)
			var reason := ""
			var produced := {}
			var research_output := 0
			match type:
				"solar":
					power_supply += info["power_supply"]
					power_left += info["power_supply"]
				"miner":
					var deposit := _deposit_by_id(colony, building["deposit_id"])
					var amount := 0
					if power_left < info["power_use"]:
						reason = "NO_POWER"
					elif deposit.is_empty() or deposit["remaining"] <= 0:
						reason = "DEPOSIT_EMPTY"
					else:
						amount = mini(info["mine_rate"] + bonus, deposit["remaining"])
						if _total(inventory) + amount > capacity:
							reason = "STORAGE_FULL"
					if reason.is_empty():
						power_left -= info["power_use"]
						power_used += info["power_use"]
						deposit["remaining"] -= amount
						inventory["ore"] = inventory.get("ore", 0) + amount
						if preview:
							produced["ore"] = amount
				"refiner", "lab":
					var input: Dictionary = info["input"]
					var output: Dictionary = info.get("output", {})
					if power_left < info["power_use"]:
						reason = "NO_POWER"
					elif not _has_all(inventory, input):
						reason = "NO_INPUT"
					elif _total(inventory) - _total(input) + _total(output) > capacity:
						reason = "STORAGE_FULL"
					if reason.is_empty():
						power_left -= info["power_use"]
						power_used += info["power_use"]
						for resource: String in input:
							inventory[resource] -= input[resource]
						for resource: String in output:
							inventory[resource] = inventory.get(resource, 0) + output[resource]
						if preview:
							produced = output
						if type == "lab":
							research_output = info["research_output"]
							gained += research_output
							colony["research"] += research_output
			if preview:
				var status := "RUNNING" if reason.is_empty() else "STOPPED"
				report.append(_report_building(building, status, reason, produced, research_output))
	if preview:
		for warehouse: Dictionary in by_type.get("warehouse", []):
			report.append(_report_building(warehouse, "PASSIVE", "", {}, 0))
	return {"research_gained": gained, "power_supply": power_supply, "power_used": power_used, "buildings": report}


static func _report_building(building: Dictionary, status: String, reason: String, produced: Dictionary,
		research_output: int) -> Dictionary:
	return {
		"id": building["id"], "type": building["type"], "grid_x": building["grid_x"], "grid_y": building["grid_y"],
		"status": status, "reason": reason, "produced": produced.duplicate(), "research_output": research_output,
	}


static func _building_before(a: Dictionary, b: Dictionary) -> bool:
	var number_a := _id_number(a["id"])
	var number_b := _id_number(b["id"])
	if number_a != number_b:
		return number_a < number_b
	return a["id"] < b["id"]


static func _id_number(id: String) -> int:
	var digits := ""
	for character in id:
		if character >= "0" and character <= "9":
			digits += character
	return digits.to_int() if not digits.is_empty() else 0


static func _total(items: Dictionary) -> int:
	var sum := 0
	for amount: Variant in items.values():
		sum += amount
	return sum


static func _has_all(inventory: Dictionary, needs: Dictionary) -> bool:
	for resource: String in needs:
		if inventory.get(resource, 0) < needs[resource]:
			return false
	return true


static func _deposit_at(colony: Dictionary, grid_x: int, grid_y: int) -> Dictionary:
	for deposit: Dictionary in colony["deposits"]:
		if deposit["grid_x"] == grid_x and deposit["grid_y"] == grid_y:
			return deposit
	return {}


static func _deposit_by_id(colony: Dictionary, deposit_id: Variant) -> Dictionary:
	for deposit: Dictionary in colony["deposits"]:
		if deposit["id"] == deposit_id:
			return deposit
	return {}


static func _describe(amounts: Dictionary) -> String:
	var parts: PackedStringArray = []
	var keys: Array = amounts.keys()
	keys.sort()
	for resource: String in keys:
		parts.append("%s %d" % [RESOURCE_KO.get(resource, resource), amounts[resource]])
	return ", ".join(parts)


static func _problem(code: String, message: String) -> Dictionary:
	return {"code": code, "message": message}


static func _fail(state: Dictionary, code: String, message: String) -> Dictionary:
	return Schema.result(false, code, message, state.duplicate(true))
