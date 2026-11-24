extends Control

const Catalog := preload("res://src/catalog/catalog.gd")
const Navigation := preload("res://src/navigation/navigation.gd")
const View := preload("res://scenes/navigation/navigation_view.gd")
const Schema := preload("res://src/contracts/schema.gd")
const GameState := preload("res://src/core/game_state.gd")
const Router := preload("res://src/core/command_router.gd")
const MockColony := preload("res://src/contracts/mocks/mock_colony.gd")
const SaveStore := preload("res://src/core/save_store.gd")

var _catalog := Catalog.new()
var _router := Router.new(GameState.new(), Navigation.new(_catalog), MockColony.new())
var _store := SaveStore.new("user://navigation_demo_v1.json")
@onready var _view: View = %NavigationView
@onready var _pause: Button = %Pause
@onready var _speed: OptionButton = %Speed


func _ready() -> void:
	get_window().min_size = Vector2i(940, 560)
	_view.attach(_catalog, _router.dispatch)
	for speed: int in Schema.SPEEDS:
		_speed.add_item("%d×" % speed, speed)
	_speed.item_selected.connect(func(index: int) -> void:
		_router.dispatch({"type": "SET_SPEED", "speed": _speed.get_item_id(index)})
	)
	_pause.pressed.connect(_toggle_pause)
	%Save.pressed.connect(_save)
	%Load.pressed.connect(_load)
	_router.state_changed.connect(_render)
	_render(_router.snapshot())


func _process(delta: float) -> void:
	_router.advance(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not event.is_echo():
		_toggle_pause()
		get_viewport().set_input_as_handled()


func _toggle_pause() -> void:
	_router.dispatch({"type": "SET_PAUSED", "paused": not _router.snapshot()["paused"]})


func _save() -> void:
	_set_status(_store.save(_router.snapshot()))


func _load() -> void:
	var result := _store.load_primary()
	if result["ok"]:
		_router.restore(result["state"])
	_set_status(result)


func _set_status(result: Dictionary) -> void:
	%Status.text = result["message"]
	%Status.modulate = Color.WHITE if result["ok"] else Color("#ffb3a3")


func _render(state: Dictionary) -> void:
	_view.show_state(state)
	_pause.text = "재개" if state["paused"] else "일시정지"
	_speed.select(_speed.get_item_index(state["speed"]))
