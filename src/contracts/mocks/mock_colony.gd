extends RefCounted

const Schema := preload("res://src/contracts/schema.gd")
const GENERATOR_VERSION := 1


func create(body_id: String, world_seed: int) -> Dictionary:
	return Schema.new_colony(body_id, world_seed ^ body_id.hash(), GENERATOR_VERSION)


func apply(state: Dictionary, _command: Dictionary) -> Dictionary:
	return Schema.result(false, "MODULE_STUB", "건설과 자원 이전은 후속 단계에서 제공됩니다.", state.duplicate(true))


func step(state: Dictionary) -> Dictionary:
	return state.duplicate(true)
