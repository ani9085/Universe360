extends RefCounted

const Schema := preload("res://src/contracts/schema.gd")
const ROUTES := {Schema.MOON: [5, 20], Schema.MARS: [20, 60]}
var _catalog: RefCounted


func _init(catalog: RefCounted) -> void:
	_catalog = catalog


func apply(state: Dictionary, command: Dictionary) -> Dictionary:
	var next := state.duplicate(true)
	var ship: Dictionary = next["ship"]
	var target: Variant = command.get("body_id")
	match command.get("type"):
		"TRAVEL":
			if ship["mode"] != Schema.ORBIT:
				return Schema.result(false, "INVALID_MODE", "궤도에서 항법을 시작할 수 있습니다.", state)
			if target not in ROUTES or target == ship["body_id"]:
				return Schema.result(false, "INVALID_TARGET", "이 시험 목적지로 이동할 수 없습니다.", state)
			var route: Array = ROUTES[target]
			if ship["fuel"] < route[0]:
				return Schema.result(false, "INSUFFICIENT_FUEL", "연료가 부족합니다.", state)
			ship["fuel"] -= route[0]
			ship["mode"] = Schema.FLIGHT
			ship["destination_id"] = target
			ship["travel_ticks_remaining"] = route[1]
		"LAND":
			if ship["mode"] == Schema.FLIGHT or target != ship["body_id"]:
				return Schema.result(false, "NOT_ARRIVED", "목적지 궤도에 도착해야 착륙할 수 있습니다.", state)
			if ship["mode"] != Schema.ORBIT:
				return Schema.result(false, "INVALID_MODE", "궤도에서 착륙할 수 있습니다.", state)
			var body: Dictionary = _catalog.get_body(target)
			if not body.get("landable", false):
				return Schema.result(false, "NOT_LANDABLE", "이 천체에는 착륙할 수 없습니다.", state)
			ship["mode"] = Schema.SURFACE
		"TAKEOFF":
			if ship["mode"] != Schema.SURFACE:
				return Schema.result(false, "INVALID_MODE", "표면에서 이륙할 수 있습니다.", state)
			ship["mode"] = Schema.ORBIT
		_:
			return Schema.result(false, "UNKNOWN_COMMAND", "지원하지 않는 항법 명령입니다.", state)
	return Schema.result(true, "OK", "", next)


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
