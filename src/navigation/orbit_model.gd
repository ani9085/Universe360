extends RefCounted

const Catalog := preload("res://src/catalog/catalog.gd")
const AU_KM := 149597870.7
const J2000 := "J2000 · 2000-01-01 12:00 TDB"
const SECONDS_PER_DAY := 86400.0

var _catalog: Catalog


func _init(catalog: Catalog) -> void:
	_catalog = catalog


func system_bodies() -> Array[Dictionary]:
	var bodies: Array[Dictionary] = []
	_append_children("sol", bodies)
	return bodies


func position_km(body_id: String, tick: int) -> PackedFloat64Array:
	var body := _catalog.get_body(body_id)
	if body.is_empty() or body["distance_ly"] != null:
		return PackedFloat64Array()
	if body["parent_id"] == null:
		return PackedFloat64Array([0.0, 0.0, 0.0]) if body_id == "sol" else PackedFloat64Array()
	var parent := position_km(body["parent_id"], tick)
	if parent.is_empty():
		return PackedFloat64Array()
	var phase := _phase(body_id, tick)
	var radius: float = body["orbit_radius_km"]
	return PackedFloat64Array([parent[0] + cos(phase) * radius, parent[1], parent[2] - sin(phase) * radius])


func distance_km(from_id: String, to_id: String, tick: int) -> Variant:
	var start := position_km(from_id, tick)
	var finish := position_km(to_id, tick)
	if start.is_empty() or finish.is_empty():
		return null
	var dx := start[0] - finish[0]
	var dy := start[1] - finish[1]
	var dz := start[2] - finish[2]
	return sqrt(dx * dx + dy * dy + dz * dz)


func visual_orbit_radius(body: Dictionary) -> float:
	if body.get("orbit_radius_km") == null:
		return 0.0
	if body["kind"] == "moon":
		return 4.4
	return 8.0 + 9.5 * log(1.0 + 4.0 * body["orbit_radius_km"] / AU_KM)


func visual_body_radius(body: Dictionary) -> float:
	if body["id"] == "sol":
		return 3.05
	var radius_km: float = body.get("radius_km", 0.0) if body.get("radius_km") != null else 0.0
	return clampf(0.68 + radius_km / 28000.0, 0.68, 2.1)


func visual_position(body_id: String, tick: int) -> Vector3:
	var body := _catalog.get_body(body_id)
	if body.is_empty() or body["parent_id"] == null:
		return Vector3.ZERO
	var parent := visual_position(body["parent_id"], tick)
	var phase := _phase(body_id, tick)
	return parent + Vector3(cos(phase), 0.0, -sin(phase)) * visual_orbit_radius(body)


func _phase(body_id: String, tick: int) -> float:
	var orbit := _catalog.get_details(body_id)
	var seconds: float = orbit["period_days"] * SECONDS_PER_DAY
	return deg_to_rad(orbit["phase_deg"]) + TAU * fposmod(float(tick), seconds) / seconds


func _append_children(id: String, bodies: Array[Dictionary]) -> void:
	var body := _catalog.get_body(id)
	if body.is_empty():
		return
	bodies.append(body)
	for child: Dictionary in _catalog.list_bodies(id):
		_append_children(child["id"], bodies)
