extends Control

const Schema := preload("res://src/contracts/schema.gd")
const GameState := preload("res://src/core/game_state.gd")
const Router := preload("res://src/core/command_router.gd")
const SaveStore := preload("res://src/core/save_store.gd")
const MockCatalog := preload("res://src/contracts/mocks/mock_catalog.gd")
const MockNavigation := preload("res://src/contracts/mocks/mock_navigation.gd")
const MockColony := preload("res://src/contracts/mocks/mock_colony.gd")
const MODES := {Schema.ORBIT: "궤도", Schema.FLIGHT: "비행 중", Schema.SURFACE: "표면"}

var _catalog := MockCatalog.new()
var _router := Router.new(GameState.new(), MockNavigation.new(_catalog), MockColony.new())
var _store := SaveStore.new()
var _active := false

@onready var _menu: VBoxContainer = %Menu
@onready var _session: VBoxContainer = %Session
@onready var _status: Label = %Status
@onready var _backup: ConfirmationDialog = %Backup
@onready var _options: AcceptDialog = %Options
@onready var _default_speed: OptionButton = %DefaultSpeed
@onready var _speed: OptionButton = %Speed
@onready var _pause: Button = %Pause
@onready var _location: Label = %Location
@onready var _resources: Label = %Resources
@onready var _time: Label = %Time


func _ready() -> void:
	get_window().min_size = Vector2i(860, 500)
	for speed: int in Schema.SPEEDS:
		_default_speed.add_item("%d×" % speed, speed)
		_speed.add_item("%d×" % speed, speed)
	%NewGame.pressed.connect(_new_game)
	%Continue.pressed.connect(_load_game)
	%Settings.pressed.connect(_options.popup_centered)
	%Quit.pressed.connect(get_tree().quit)
	%SessionQuit.pressed.connect(get_tree().quit)
	%Save.pressed.connect(_save_game)
	%Load.pressed.connect(_load_game)
	_pause.pressed.connect(_toggle_pause)
	_speed.item_selected.connect(_change_speed)
	_backup.confirmed.connect(_restore_backup)
	_backup.get_cancel_button().text = "취소"
	_backup.get_ok_button().text = "백업 불러오기"
	_options.get_ok_button().text = "닫기"
	_router.state_changed.connect(_render_state)
	%NewGame.grab_focus()


func _process(delta: float) -> void:
	if _active:
		_router.advance(delta)


func _unhandled_input(event: InputEvent) -> void:
	if _active and event.is_action_pressed("ui_cancel") and not event.is_echo():
		_toggle_pause()
		get_viewport().set_input_as_handled()


func _new_game() -> void:
	_router.new_game(360)
	_router.dispatch({"type": "SET_SPEED", "speed": _default_speed.get_selected_id()})
	_open_session("새 게임을 시작했습니다.")


func _save_game() -> void:
	var result := _store.save(_router.snapshot())
	_set_status(result["message"], not result["ok"])


func _load_game() -> void:
	var result := _store.load_primary()
	if result["ok"] and _router.restore(result["state"]):
		_open_session(result["message"])
		return
	_set_status(result["message"], true)
	if result["code"] in ["CORRUPT_SAVE", "NOT_FOUND", "READ_FAILED"] and _store.load_backup()["ok"]:
		_backup.dialog_text = result["message"] + "\n직전 정상 저장을 불러올까요?"
		_backup.popup_centered()


func _restore_backup() -> void:
	var result := _store.load_backup()
	if result["ok"] and _router.restore(result["state"]):
		_open_session("백업으로 게임을 복원했습니다.")
	else:
		_set_status(result["message"], true)


func _open_session(message: String) -> void:
	_active = true
	_menu.hide()
	_session.show()
	%Help.text = "Tab 이동   ·   Enter 선택   ·   Esc 일시정지"
	%Save.grab_focus()
	_set_status(message)


func _change_speed(index: int) -> void:
	_router.dispatch({"type": "SET_SPEED", "speed": _speed.get_item_id(index)})


func _toggle_pause() -> void:
	_router.dispatch({"type": "SET_PAUSED", "paused": not _router.snapshot()["paused"]})


func _render_state(state: Dictionary) -> void:
	var ship: Dictionary = state["ship"]
	var body := _catalog.get_body(ship["body_id"])
	var cargo: Dictionary = ship["cargo"]
	_location.text = "%s  ·  %s" % [body.get("name", ship["body_id"]), MODES[ship["mode"]]]
	_resources.text = "연료 %d    금속 %d    얼음 %d    부품 %d    연구 %d" % [
		ship["fuel"], cargo.get("metal", 0), cargo.get("ice", 0), cargo.get("parts", 0), state["research"],
	]
	_time.text = "게임 시간 %d초  ·  %s" % [state["tick"], "일시정지" if state["paused"] else "진행 중"]
	_pause.text = "재개" if state["paused"] else "일시정지"
	_speed.select(_speed.get_item_index(state["speed"]))


func _set_status(message: String, error: bool = false) -> void:
	_status.text = message
	_status.modulate = Color("#ffb7a5") if error else Color.WHITE
