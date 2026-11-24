extends RefCounted

const Schema := preload("res://src/contracts/schema.gd")
var _state: Dictionary


func _init(world_seed: int = 360) -> void:
	_state = Schema.new_state(world_seed)


func snapshot() -> Dictionary:
	return _state.duplicate(true)


func reset(world_seed: int) -> void:
	_state = Schema.new_state(world_seed)


func replace(candidate: Dictionary) -> bool:
	if not Schema.validate_state(candidate):
		return false
	_state = candidate.duplicate(true)
	return true
