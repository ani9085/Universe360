extends RefCounted

const Schema := preload("res://src/contracts/schema.gd")
const SaveJson := preload("res://src/core/save_json.gd")
const DEFAULT_PATH := "user://save_v1.json"
var _path: String
var _json := SaveJson.new()


func _init(path: String = DEFAULT_PATH) -> void:
	_path = path


func load_primary() -> Dictionary:
	return _read_current(_path)


func load_backup() -> Dictionary:
	return _read_current(_path + ".bak")


func save(state: Dictionary) -> Dictionary:
	if not Schema.validate_state(state):
		return Schema.result(false, "INVALID_STATE", "저장할 게임 상태가 올바르지 않습니다.")
	var current := load_primary()
	if current["code"] in ["FUTURE_SCHEMA", "READ_FAILED"]:
		return current
	var staged := _path + ".tmp"
	var written := _stage(staged, state)
	if not written["ok"]:
		return written
	if current["ok"]:
		var backed_up := _backup(current["state"])
		if not backed_up["ok"]:
			DirAccess.remove_absolute(staged)
			return backed_up
	if not _replace(staged, _path):
		DirAccess.remove_absolute(staged)
		return Schema.result(false, "REPLACE_FAILED", "저장 파일을 교체할 수 없습니다.")
	return Schema.result(true, "OK", "게임을 저장했습니다.")


func _read_current(path: String) -> Dictionary:
	if not FileAccess.file_exists(path) and FileAccess.file_exists(path + ".previous"):
		return _read(path + ".previous")
	return _read(path)


func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return Schema.result(false, "NOT_FOUND", "저장 파일이 없습니다.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return Schema.result(false, "READ_FAILED", "저장 파일을 열 수 없습니다.")
	var size := file.get_length()
	var bytes := file.get_buffer(size)
	file.close()
	if bytes.size() != size:
		return Schema.result(false, "READ_FAILED", "저장 파일을 끝까지 읽을 수 없습니다.")
	var data: Variant = _json.parse(bytes.get_string_from_utf8())
	if data is Dictionary:
		var version: Variant = data.get("schema_version")
		if typeof(version) in [TYPE_INT, TYPE_FLOAT] and version > Schema.VERSION:
			return Schema.result(false, "FUTURE_SCHEMA", "더 최신 버전에서 만든 저장입니다. 해당 버전에서 열어 주세요.")
		if Schema.validate_state(data):
			return Schema.result(true, "OK", "저장 파일을 불러왔습니다.", data)
	return Schema.result(false, "CORRUPT_SAVE", "저장 파일이 손상되었거나 형식이 올바르지 않습니다.")


func _stage(path: String, state: Dictionary) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return Schema.result(false, "WRITE_FAILED", "임시 저장 파일을 만들 수 없습니다.")
	var written := file.store_string(JSON.stringify(state, "\t", true, true) + "\n")
	file.flush()
	var write_error := file.get_error()
	file.close()
	var verified := _read(path)
	if not written or write_error != OK or not verified["ok"] or verified["state"] != state:
		DirAccess.remove_absolute(path)
		return Schema.result(false, "WRITE_FAILED", "임시 저장 파일을 기록하고 검증할 수 없습니다.")
	return verified


func _backup(state: Dictionary) -> Dictionary:
	var path := _path + ".bak"
	var prior := load_backup()
	if prior["code"] in ["FUTURE_SCHEMA", "READ_FAILED"]:
		return prior
	var backup_stage := path + ".tmp"
	var staged := _stage(backup_stage, state)
	if not staged["ok"]:
		return Schema.result(false, "BACKUP_FAILED", "이전 저장을 백업할 수 없습니다.")
	if not _replace(backup_stage, path):
		DirAccess.remove_absolute(backup_stage)
		return Schema.result(false, "BACKUP_FAILED", "이전 저장을 백업할 수 없습니다.")
	return staged


func _replace(staged: String, path: String) -> bool:
	# Windows Godot's rename removes an existing destination first.
	# Move it aside explicitly so a failed install can restore the original.
	var previous := path + ".previous"
	if FileAccess.file_exists(previous):
		if FileAccess.file_exists(path):
			if DirAccess.remove_absolute(previous) != OK:
				return false
		elif DirAccess.rename_absolute(previous, path) != OK:
			return false
	var had_file := FileAccess.file_exists(path)
	if had_file and DirAccess.rename_absolute(path, previous) != OK:
		return false
	if DirAccess.rename_absolute(staged, path) != OK:
		if had_file:
			DirAccess.rename_absolute(previous, path)
		return false
	if had_file:
		DirAccess.remove_absolute(previous)
	return true
