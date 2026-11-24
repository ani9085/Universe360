extends RefCounted

# Godot parses JSON numbers as doubles. Tag integer tokens only for parsing
# so the file stays standard JSON and 64-bit seeds survive round trips.
var _tokens := RegEx.create_from_string(
		r'"(?:[^"\\]|\\.)*"|(?<integer>-?(?:0|[1-9][0-9]*))(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
		true
)


func parse(text: String) -> Variant:
	var pieces := PackedStringArray()
	var offset := 0
	for token: RegExMatch in _tokens.search_all(text):
		var start := token.get_start()
		var raw := token.get_string()
		pieces.append(text.substr(offset, start - offset))
		offset = token.get_end()
		if raw.begins_with('"'):
			pieces.append('"s' + raw.substr(1))
		elif raw == token.get_string("integer"):
			if not _fits_int64(raw):
				return null
			pieces.append('"i' + raw + '"')
		else:
			pieces.append(raw)
	pieces.append(text.substr(offset))
	var json := JSON.new()
	if json.parse("".join(pieces)) != OK:
		return null
	return _decode(json.data)


func _decode(value: Variant) -> Variant:
	if value is Dictionary:
		var decoded := {}
		for key: String in value:
			decoded[key.substr(1)] = _decode(value[key])
		return decoded
	if value is Array:
		var decoded: Array = []
		for item: Variant in value:
			decoded.append(_decode(item))
		return decoded
	if value is String:
		if value.begins_with("i"):
			var digits: String = value.substr(1)
			if digits == "-9223372036854775808":
				return -9223372036854775807 - 1
			return digits.to_int()
		return value.substr(1)
	return value


func _fits_int64(raw: String) -> bool:
	var negative := raw.begins_with("-")
	var magnitude := raw.substr(1) if negative else raw
	var maximum := "9223372036854775808" if negative else "9223372036854775807"
	return magnitude.length() < 19 or (magnitude.length() == 19 and magnitude <= maximum)
