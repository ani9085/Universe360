extends RefCounted

# Loads and validates data/balance/colony_balance.json.
# All numbers are game assumptions (MVP_SPEC section 4), not observations.

const SaveJson := preload("res://src/core/save_json.gd")
const Schema := preload("res://src/contracts/schema.gd")
const PATH := "res://data/balance/colony_balance.json"
const BUILDING_TYPES := ["solar", "miner", "refiner", "warehouse", "lab"]

var data: Dictionary = {}
var error := ""


static func load_default() -> RefCounted:
	var balance: RefCounted = new()
	balance.load_file(PATH)
	return balance


func is_valid() -> bool:
	return error.is_empty() and not data.is_empty()


func load_file(path: String) -> void:
	data = {}
	error = ""
	if not FileAccess.file_exists(path):
		error = "밸런스 파일을 찾을 수 없습니다: " + path
		return
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = SaveJson.new().parse(text)
	if not parsed is Dictionary:
		error = "밸런스 파일 형식이 올바르지 않습니다: " + path
		return
	var problem := _validate(parsed)
	if not problem.is_empty():
		error = "밸런스 데이터 오류: " + problem
		return
	data = parsed


func building(type: String) -> Dictionary:
	return data.get("buildings", {}).get(type, {})


func cost(type: String) -> Dictionary:
	return building(type).get("cost", {})


func terrain_profile(body_id: String) -> Dictionary:
	var terrain: Dictionary = data.get("terrain", {})
	var profile: Dictionary = terrain.get("default", {}).duplicate(true)
	var overrides: Dictionary = terrain.get("bodies", {}).get(body_id, {})
	for key: Variant in overrides:
		profile[key] = overrides[key]
	return profile


func _validate(value: Dictionary) -> String:
	for key: String in ["grid", "storage", "deposit", "buildings", "research", "terrain", "process_order"]:
		if not value.has(key):
			return "누락된 항목 " + key
	var grid: Dictionary = value["grid"]
	for key: String in ["size_m", "cell_m", "cells"]:
		if typeof(grid.get(key)) != TYPE_INT or grid[key] <= 0:
			return "grid." + key
	if grid["cell_m"] * grid["cells"] != grid["size_m"]:
		return "grid 크기가 일치하지 않습니다"
	for type: String in BUILDING_TYPES:
		var info: Variant = value["buildings"].get(type)
		if not info is Dictionary:
			return "buildings." + type
		for resource: Variant in info.get("cost", {}):
			if resource not in Schema.RESOURCES or typeof(info["cost"][resource]) != TYPE_INT:
				return "buildings.%s.cost" % type
	for resource: Variant in value["deposit"].get("counts", {}):
		if resource not in Schema.RESOURCES:
			return "deposit.counts"
	if typeof(value["storage"].get("base_capacity")) != TYPE_INT:
		return "storage.base_capacity"
	if typeof(value["storage"].get("ship_cargo_limit")) != TYPE_INT:
		return "storage.ship_cargo_limit"
	if not value["research"].get("mining_efficiency_1") is Dictionary:
		return "research.mining_efficiency_1"
	return ""
