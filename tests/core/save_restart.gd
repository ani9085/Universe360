extends SceneTree

const Schema := preload("res://src/contracts/schema.gd")
const SaveStore := preload("res://src/core/save_store.gd")


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 2 or arguments[0] not in ["write", "read"]:
		printerr("Use write or read followed by an absolute test save path.")
		quit(1)
		return
	var store := SaveStore.new(arguments[1])
	var expected := Schema.new_state(9007199254740993)
	expected["tick"] = 715
	expected["speed"] = 10
	expected["ship"]["fuel"] = 95
	expected["ship"]["body_id"] = Schema.MOON
	expected["ship"]["mode"] = Schema.SURFACE
	expected["colonies"][Schema.MOON] = Schema.new_colony(Schema.MOON, 715, 1)
	var writing := arguments[0] == "write"
	var result := store.save(expected) if writing else store.load_primary()
	var ok: bool = result["ok"] and (writing or result["state"] == expected)
	if ok:
		print("A0 save restart %s: PASS" % arguments[0])
	else:
		printerr("A0 save restart %s: FAIL (%s)" % [arguments[0], result["code"]])
	quit(0 if ok else 1)
