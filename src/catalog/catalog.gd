extends RefCounted

const DEFAULT_PATH := "res://data/catalog/bodies.json"
const KINDS := ["star", "planet", "moon"]
const MEASUREMENTS := ["radius_km", "orbit_radius_km", "distance_ly", "mass_kg"]
const DETAILS := ["mass_kg", "phase_deg", "period_days"]
const PROVENANCE_KEYS := ["source_url", "retrieved_at", "data_status", "epoch", "license_note"]

var error := ""
var _bodies := {}
var _details := {}


func _init(path: String = DEFAULT_PATH) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		error = "천체 카탈로그 파일을 열 수 없습니다."
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		error = "천체 카탈로그 JSON 형식이 올바르지 않습니다."
		return
	error = _import(json.data)
	if not error.is_empty():
		_bodies.clear()
		_details.clear()


func get_body(id: String) -> Dictionary:
	return _bodies.get(id, {}).duplicate(true)


func list_bodies(parent_id: String) -> Array:
	var result: Array[Dictionary] = []
	for body: Dictionary in _bodies.values():
		if body["parent_id"] == parent_id or (parent_id.is_empty() and body["parent_id"] == null):
			result.append(body.duplicate(true))
	return result


func get_details(id: String) -> Dictionary:
	return _details.get(id, {}).duplicate(true)


func _import(data: Dictionary) -> String:
	var sources: Variant = data.get("sources")
	var rows: Variant = data.get("bodies")
	if not sources is Dictionary or not rows is Array or rows.is_empty():
		return "천체 카탈로그에 천체 또는 출처가 없습니다."
	for source: Variant in sources.values():
		if not _valid_source(source):
			return "천체 카탈로그의 출처 정보가 올바르지 않습니다."
	for row: Variant in rows:
		if not row is Dictionary:
			return "천체 레코드 형식이 올바르지 않습니다."
		var row_error := _import_body(row, sources)
		if not row_error.is_empty():
			return row_error
	for id: String in _bodies:
		if not _valid_parent_chain(id):
			return "존재하지 않거나 순환하는 부모 천체: %s" % id
	return ""


func _import_body(row: Dictionary, sources: Dictionary) -> String:
	var id: Variant = row.get("id")
	var name: Variant = row.get("name")
	var parent: Variant = row.get("parent_id")
	var kind: Variant = row.get("kind")
	var landable: Variant = row.get("landable")
	if not id is String or id.is_empty() or _bodies.has(id) or not name is String or name.is_empty():
		return "천체 ID 또는 이름이 올바르지 않습니다."
	if not row.has("parent_id") or (parent != null and (not parent is String or parent.is_empty())):
		return "부모 천체 ID가 올바르지 않습니다: %s" % id
	if kind not in KINDS or typeof(landable) != TYPE_BOOL:
		return "천체 종류 또는 착륙 규칙이 올바르지 않습니다: %s" % id
	var references: Variant = row.get("provenance")
	if not references is Dictionary or not references.has("landable"):
		return "천체 출처가 누락되었습니다: %s" % id
	var provenance := {}
	for key: String in references:
		var source_id: Variant = references[key]
		if not source_id is String or not sources.has(source_id):
			return "알 수 없는 출처입니다: %s / %s" % [id, key]
		provenance[key] = sources[source_id]

	for field: String in MEASUREMENTS:
		var value: Variant = row.get(field)
		if value != null and (not _finite_number(value) or value <= 0.0 or not provenance.has(field)):
			return "천체 측정값 또는 출처가 올바르지 않습니다: %s / %s" % [id, field]

	var phase: Variant = row.get("phase_deg")
	var period: Variant = row.get("period_days")
	if parent != null and (row.get("orbit_radius_km") == null or not _finite_number(phase) \
			or not _finite_number(period) or period <= 0.0 or not provenance.has("position")):
		return "공전 모델이 누락되었거나 올바르지 않습니다: %s" % id
	_bodies[id] = {
		"id": id, "parent_id": parent, "name": name, "kind": kind,
		"radius_km": row.get("radius_km"), "orbit_radius_km": row.get("orbit_radius_km"),
		"distance_ly": row.get("distance_ly"), "landable": landable, "provenance": provenance,
	}
	var details := {}
	for key: String in DETAILS:
		details[key] = row.get(key)
	_details[id] = details
	return ""


func _valid_parent_chain(id: String) -> bool:
	var visited := {}
	var current: Variant = id
	while current != null:
		if visited.has(current) or not _bodies.has(current):
			return false
		visited[current] = true
		current = _bodies[current]["parent_id"]
	return true


func _valid_source(source: Variant) -> bool:
	if not source is Dictionary or not source.has_all(PROVENANCE_KEYS):
		return false
	if source["data_status"] not in ["observed", "modelled", "generated"]:
		return false
	if not source["license_note"] is String or source["license_note"].is_empty():
		return false
	if source["source_url"] == null:
		return source["data_status"] != "observed" and source["retrieved_at"] == null
	return source["source_url"] is String and source["source_url"].begins_with("https://") \
			and source["retrieved_at"] is String and not source["retrieved_at"].is_empty()


func _finite_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value))
