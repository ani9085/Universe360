extends RefCounted

signal state_changed(snapshot: Dictionary)

const Schema := preload("res://src/contracts/schema.gd")
const Clock := preload("res://src/core/clock.gd")
const GameState := preload("res://src/core/game_state.gd")
var _game: GameState
var _clock := Clock.new()
var _navigation: RefCounted
var _colony: RefCounted


func _init(game: GameState, navigation: RefCounted, colony: RefCounted) -> void:
	_game = game
	_navigation = navigation
	_colony = colony


func snapshot() -> Dictionary:
	return _game.snapshot()


func new_game(world_seed: int) -> void:
	_game.reset(world_seed)
	_clock.reset()
	state_changed.emit(snapshot())


func restore(state: Dictionary) -> bool:
	if not _game.replace(state):
		return false
	_clock.reset()
	state_changed.emit(snapshot())
	return true


func dispatch(command: Dictionary) -> Dictionary:
	var type: Variant = command.get("type")
	var next := snapshot()
	var response: Dictionary
	match type:
		"SET_SPEED":
			var speed: Variant = command.get("speed")
			if typeof(speed) != TYPE_INT or speed not in Schema.SPEEDS:
				return _failure("INVALID_SPEED", "배속은 1×, 10×, 60× 중에서 선택하세요.")
			next["speed"] = speed
			response = Schema.result(true, "OK", "", next)
		"SET_PAUSED":
			if typeof(command.get("paused")) != TYPE_BOOL:
				return _failure("INVALID_PAUSE", "일시정지 상태가 올바르지 않습니다.")
			next["paused"] = command["paused"]
			response = Schema.result(true, "OK", "", next)
		_:
			if type in Schema.NAVIGATION_COMMANDS:
				response = _navigation.apply(next, command.duplicate(true))
			elif type in Schema.COLONY_COMMANDS:
				if not _at_colony(next, command.get("colony_id")):
					return _failure("INVALID_MODE", "해당 기지의 표면에서만 사용할 수 있습니다.")
				response = _colony.apply(next, command.duplicate(true))
			else:
				return _failure("UNKNOWN_COMMAND", "지원하지 않는 명령입니다.")
	if not response.get("ok", false):
		return _failure(response["code"], response["message"])
	var candidate: Dictionary = response["state"]
	if type == "LAND" and (not Schema.validate_state(candidate) or not _create_colony_if_missing(candidate)):
		return _failure("INVALID_STATE", "착륙 상태 또는 초기 기지 상태가 올바르지 않습니다.")
	if not _game.replace(candidate):
		return _failure("INVALID_STATE", "모듈이 올바르지 않은 게임 상태를 반환했습니다.")
	var updated := snapshot()
	state_changed.emit(updated.duplicate(true))
	return Schema.result(true, "OK", response["message"], updated)


func advance(delta: float) -> int:
	var state := snapshot()
	if state["paused"]:
		return 0
	_clock.accumulate(delta, state["speed"])
	var processed := 0
	while processed < Clock.MAX_TICKS_PER_FRAME and not state["paused"] and _clock.take_tick():
		var tick: int = state["tick"] + 1
		var next: Dictionary = _navigation.step(state)
		next = _colony.step(next)
		next["tick"] = tick
		if not _game.replace(next):
			push_error("A module returned invalid state during a tick.")
			break
		processed += 1
		state_changed.emit(snapshot())
		state = snapshot()
	return processed


func _create_colony_if_missing(state: Dictionary) -> bool:
	var body_id: String = state["ship"]["body_id"]
	var colonies: Dictionary = state["colonies"]
	for base: Dictionary in colonies.values():
		if base["body_id"] == body_id:
			return true
	var colony: Dictionary = _colony.create(body_id, state["world_seed"])
	if not Schema.valid_colony(colony) or colony["body_id"] != body_id or colonies.has(colony["id"]):
		return false
	colonies[colony["id"]] = colony
	return true


func _at_colony(state: Dictionary, colony_id: Variant) -> bool:
	var ship: Dictionary = state["ship"]
	var colonies: Dictionary = state["colonies"]
	return ship["mode"] == Schema.SURFACE and colony_id is String and colonies.has(colony_id) \
			and colonies[colony_id]["body_id"] == ship["body_id"]


func _failure(code: String, message: String) -> Dictionary:
	return Schema.result(false, code, message, snapshot())
