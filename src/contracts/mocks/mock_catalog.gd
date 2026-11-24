extends RefCounted

const Schema := preload("res://src/contracts/schema.gd")
const BODIES := {
	"sol": [null, "태양 (Sun)", "star", false],
	Schema.EARTH: ["sol", "지구 (Earth)", "planet", false],
	Schema.MOON: [Schema.EARTH, "달 (Moon)", "moon", true],
	Schema.MARS: ["sol", "화성 (Mars)", "planet", true],
}


func get_body(id: String) -> Dictionary:
	if not BODIES.has(id):
		return {}
	var fixture: Array = BODIES[id]
	return {
		"id": id, "parent_id": fixture[0], "name": fixture[1], "kind": fixture[2],
		"radius_km": null, "orbit_radius_km": null, "distance_ly": null,
		"landable": fixture[3], "provenance": {
			"source_url": null, "retrieved_at": null, "data_status": "modelled",
			"epoch": null, "license_note": "A0 mock fixture",
		},
	}


func list_bodies(parent_id: String) -> Array:
	var bodies: Array[Dictionary] = []
	for id: String in BODIES:
		var body := get_body(id)
		if (body["parent_id"] == null and parent_id.is_empty()) or body["parent_id"] == parent_id:
			bodies.append(body)
	return bodies
