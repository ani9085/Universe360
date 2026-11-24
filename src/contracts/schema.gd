extends RefCounted

const VERSION := 1
const SPEEDS := [1, 10, 60]
const RESOURCES := ["ore", "metal", "ice", "silicon", "parts"]
const NAVIGATION_COMMANDS := ["TRAVEL", "LAND", "TAKEOFF"]
const COLONY_COMMANDS := ["BUILD", "TRANSFER"]
const ORBIT := "ORBIT"
const FLIGHT := "FLIGHT"
const SURFACE := "SURFACE"
const EARTH := "sol.earth"
const MOON := "sol.earth.moon"
const MARS := "sol.mars"

static func new_state(world_seed: int) -> Dictionary:
	return {
		"schema_version": VERSION, "world_seed": world_seed, "tick": 0,
		"speed": 1, "paused": false,
		"ship": {
			"body_id": EARTH, "mode": ORBIT, "destination_id": null,
			"travel_ticks_remaining": 0, "fuel": 100,
			"cargo": {"ore": 0, "metal": 50, "ice": 20, "silicon": 0, "parts": 20},
			"local_pose": {"position": [0.0, 0.0, 0.0], "rotation": [0.0, 0.0, 0.0]},
		},
		"colonies": {}, "research": 0, "next_entity_id": 1,
	}


static func new_colony(body_id: String, seed: int, generator_version: int) -> Dictionary:
	return {
		"id": body_id, "body_id": body_id, "seed": seed, "generator_version": generator_version,
		"inventory": {}, "capacity": 100, "buildings": [], "deposits": [],
		"research": 0, "upgrades": [],
	}


static func result(ok: bool, code: String, message: String, state: Dictionary = {}) -> Dictionary:
	return {"ok": ok, "code": code, "message": message, "state": state}


static func validate_state(state: Dictionary) -> bool:
	if state.get("schema_version") != VERSION or typeof(state.get("schema_version")) != TYPE_INT:
		return false
	if typeof(state.get("world_seed")) != TYPE_INT or typeof(state.get("paused")) != TYPE_BOOL:
		return false
	var speed: Variant = state.get("speed")
	if typeof(speed) != TYPE_INT or speed not in SPEEDS:
		return false
	if not _has_integers(state, ["tick", "research"]) or not _has_integers(state, ["next_entity_id"], 1):
		return false
	if not _valid_ship(state.get("ship")) or not state.get("colonies") is Dictionary:
		return false
	var body_ids := {}
	for colony_id: Variant in state["colonies"]:
		var colony: Variant = state["colonies"][colony_id]
		if not valid_colony(colony) or colony_id != colony["id"] or body_ids.has(colony["body_id"]):
			return false
		body_ids[colony["body_id"]] = true
	return true


static func valid_colony(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var colony: Dictionary = value
	if not _has_ids(colony, ["id", "body_id"]) or typeof(colony.get("seed")) != TYPE_INT:
		return false
	if not _has_integers(colony, ["capacity", "research"]) or not _has_integers(colony, ["generator_version"], 1):
		return false
	if not _valid_inventory(colony.get("inventory")) or not colony.get("upgrades") is Array:
		return false
	return _valid_entities(colony.get("buildings"), true) and _valid_entities(colony.get("deposits"), false)


static func _valid_ship(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var ship: Dictionary = value
	if not _has_ids(ship, ["body_id"]) or not _has_integers(ship, ["travel_ticks_remaining", "fuel"]):
		return false
	if not _valid_inventory(ship.get("cargo")) or not ship.get("local_pose") is Dictionary:
		return false
	for key: Variant in ship["local_pose"]:
		var coordinates: Variant = ship["local_pose"][key]
		if not key is String or not coordinates is Array:
			return false
		for number: Variant in coordinates:
			if typeof(number) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(number)):
				return false
	if not ship.has("destination_id"):
		return false
	match ship.get("mode"):
		FLIGHT:
			return _has_ids(ship, ["destination_id"]) and ship["travel_ticks_remaining"] > 0
		ORBIT, SURFACE:
			return ship["destination_id"] == null and ship["travel_ticks_remaining"] == 0
	return false


static func _valid_entities(value: Variant, buildings: bool) -> bool:
	if not value is Array:
		return false
	var ids := {}
	for entity: Variant in value:
		if not entity is Dictionary or not _has_ids(entity, ["id"]) or ids.has(entity["id"]):
			return false
		if typeof(entity.get("grid_x")) != TYPE_INT or typeof(entity.get("grid_y")) != TYPE_INT:
			return false
		if buildings:
			if not _has_ids(entity, ["type"]) or not entity.has("deposit_id"):
				return false
			if entity["deposit_id"] != null and not _has_ids(entity, ["deposit_id"]):
				return false
		elif entity.get("resource") not in RESOURCES or not _has_integers(entity, ["remaining"]):
			return false
		ids[entity["id"]] = true
	return true


static func _valid_inventory(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for resource: Variant in value:
		if resource not in RESOURCES or not _has_integers(value, [resource]):
			return false
	return true


static func _has_ids(data: Dictionary, keys: Array) -> bool:
	for key: String in keys:
		var value: Variant = data.get(key)
		if not value is String or value.is_empty():
			return false
	return true


static func _has_integers(data: Dictionary, keys: Array, minimum: int = 0) -> bool:
	for key: String in keys:
		var value: Variant = data.get(key)
		if typeof(value) != TYPE_INT or value < minimum:
			return false
	return true
