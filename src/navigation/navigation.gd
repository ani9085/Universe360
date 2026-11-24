extends RefCounted

const Schema := preload("res://src/contracts/schema.gd")
const ROUTES := {
	Schema.MOON: {"fuel": 5, "ticks": 20},
	Schema.MARS: {"fuel": 20, "ticks": 60},
}

var _catalog: RefCounted


func _init(catalog: RefCounted) -> void:
	_catalog = catalog


static func route(body_id: String) -> Dictionary:
	return ROUTES.get(body_id, {}).duplicate()


func apply(state: Dictionary, command: Dictionary) -> Dictionary:
	var next := state.duplicate(true)
	var ship: Dictionary = next["ship"]
	match command.get("type"):
		"TRAVEL":
			if ship["mode"] != Schema.ORBIT:
				return _error(state, "INVALID_MODE", "궤도에서 자동 항법을 시작할 수 있습니다.")
			var target: Variant = command.get("body_id")
			if not target is String or not ROUTES.has(target) or target == ship["body_id"] \
					or _catalog.get_body(target).is_empty():
				return _error(state, "INVALID_TARGET", "이 목적지로 이동할 수 없습니다. 달 또는 화성을 선택하세요.")
			var planned := route(target)
			if ship["fuel"] < planned["fuel"]:
				return _error(state, "INSUFFICIENT_FUEL", "자동 항법을 시작하기에 연료가 부족합니다.")
			ship["fuel"] -= planned["fuel"]
			ship["destination_id"] = target
			ship["travel_ticks_remaining"] = planned["ticks"]
			ship["mode"] = Schema.FLIGHT
			return Schema.result(true, "OK", "자동 항법을 시작했습니다.", next)
		"LAND":
			var target: Variant = command.get("body_id")
			if not target is String or _catalog.get_body(target).is_empty():
				return _error(state, "INVALID_TARGET", "올바른 착륙 목적지를 선택하세요.")
			if ship["mode"] == Schema.FLIGHT or target != ship["body_id"]:
				return _error(state, "NOT_ARRIVED", "목적지 궤도에 도착한 뒤 착륙할 수 있습니다.")
			if ship["mode"] != Schema.ORBIT:
				return _error(state, "INVALID_MODE", "궤도에서만 착륙할 수 있습니다.")
			if not _catalog.get_body(target)["landable"]:
				return _error(state, "NOT_LANDABLE", "이 천체에는 착륙할 수 없습니다.")
			ship["mode"] = Schema.SURFACE
			return Schema.result(true, "OK", "착륙했습니다.", next)
		"TAKEOFF":
			if ship["mode"] != Schema.SURFACE:
				return _error(state, "INVALID_MODE", "표면에서만 이륙할 수 있습니다.")
			ship["mode"] = Schema.ORBIT
			return Schema.result(true, "OK", "궤도로 이륙했습니다.", next)
	return _error(state, "UNKNOWN_COMMAND", "지원하지 않는 항법 명령입니다.")


func step(state: Dictionary) -> Dictionary:
	var next := state.duplicate(true)
	var ship: Dictionary = next["ship"]
	if ship["mode"] == Schema.FLIGHT:
		ship["travel_ticks_remaining"] -= 1
		if ship["travel_ticks_remaining"] == 0:
			ship["body_id"] = ship["destination_id"]
			ship["destination_id"] = null
			ship["mode"] = Schema.ORBIT
	return next


func _error(state: Dictionary, code: String, message: String) -> Dictionary:
	return Schema.result(false, code, message, state.duplicate(true))
