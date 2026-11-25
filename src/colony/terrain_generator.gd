extends RefCounted

# Deterministic 512 m x 512 m landing zone generator.
# Same (colony seed, generator_version, body_id, balance) -> identical deposits and heights.
# The terrain is procedurally GENERATED, not surveyed data (MVP_SPEC section 5).
# No global RNG, clock or network is used.

const GENERATOR_VERSION := 1
const DEPOSIT_ORDER := ["ore", "ice", "silicon"]
const PLACEMENT_TRIES := 200


# Stable 32-bit FNV-1a so the seed does not depend on the engine's String.hash().
static func colony_seed(world_seed: int, body_id: String) -> int:
	var h := 2166136261
	for byte: int in body_id.to_utf8_buffer():
		h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
	return world_seed ^ h


static func generate_deposits(seed: int, generator_version: int, balance: RefCounted) -> Array:
	var data: Dictionary = balance.data
	var grid: Dictionary = data["grid"]
	var settings: Dictionary = data["deposit"]
	var cells: int = grid["cells"]
	var margin: int = settings["edge_margin_cells"]
	var spacing: int = settings["min_spacing_cells"]
	var pad: Array = grid["landing_pad_cell"]
	var pad_cell := Vector2i(pad[0], pad[1])
	var clear: int = settings["landing_clear_radius_cells"]
	var rng := RandomNumberGenerator.new()
	rng.seed = (seed ^ (generator_version * 2654435761)) & 0x7FFFFFFFFFFFFFFF
	var counts: Dictionary = settings["counts"]
	var resources: Array = []
	for resource: String in DEPOSIT_ORDER:
		if counts.has(resource):
			resources.append(resource)
	var extra: Array = counts.keys()
	extra.sort()
	for resource: String in extra:
		if resource not in resources:
			resources.append(resource)
	var placed: Array[Vector2i] = []
	var deposits: Array = []
	var number := 1
	for resource: String in resources:
		for _i in range(counts[resource]):
			var cell := _pick_cell(rng, placed, cells, margin, spacing, pad_cell, clear)
			if cell.x < 0:
				continue
			placed.append(cell)
			deposits.append({
				"id": "d%d" % number, "resource": resource, "remaining": settings["initial_remaining"],
				"grid_x": cell.x, "grid_y": cell.y,
			})
			number += 1
	return deposits


static func _pick_cell(rng: RandomNumberGenerator, placed: Array[Vector2i], cells: int, margin: int,
		spacing: int, pad: Vector2i, clear: int) -> Vector2i:
	var low := margin
	var high := cells - 1 - margin
	for _try in range(PLACEMENT_TRIES):
		var candidate := Vector2i(rng.randi_range(low, high), rng.randi_range(low, high))
		if _cell_ok(candidate, placed, spacing, pad, clear):
			return candidate
	for y in range(low, high + 1):
		for x in range(low, high + 1):
			var candidate := Vector2i(x, y)
			if _cell_ok(candidate, placed, spacing, pad, clear):
				return candidate
	return Vector2i(-1, -1)


static func _cell_ok(cell: Vector2i, placed: Array[Vector2i], spacing: int, pad: Vector2i, clear: int) -> bool:
	if maxi(absi(cell.x - pad.x), absi(cell.y - pad.y)) < clear:
		return false
	for other: Vector2i in placed:
		if maxi(absi(cell.x - other.x), absi(cell.y - other.y)) < spacing:
			return false
	return true


# Vertex height grid, (cells + 1)^2 entries, index = vy * (cells + 1) + vx.
# Vertex (vx, vy) sits at the corner of cell (vx, vy); world position = vertex * cell_m - size / 2.
static func generate_heights(seed: int, generator_version: int, body_id: String, balance: RefCounted) -> PackedFloat32Array:
	var data: Dictionary = balance.data
	var cells: int = data["grid"]["cells"]
	var profile: Dictionary = balance.terrain_profile(body_id)
	var pad: Array = data["grid"]["landing_pad_cell"]
	var clear: float = float(data["deposit"]["landing_clear_radius_cells"])
	var rng := RandomNumberGenerator.new()
	rng.seed = (seed ^ (generator_version * 40503) ^ 0x5BD1E995) & 0x7FFFFFFFFFFFFFFF
	var craters: Array = []
	var radius_range: Array = profile["crater_radius_cells"]
	for _i in range(int(profile["crater_count"])):
		craters.append([
			rng.randf_range(4.0, cells - 4.0), rng.randf_range(4.0, cells - 4.0),
			rng.randf_range(float(radius_range[0]), float(radius_range[1])),
		])
	var relief: float = profile["relief_m"]
	var depth: float = profile["crater_depth_m"]
	var base: float = profile["base_height_m"]
	var lattice_seed := seed & 0xFFFFFFFF
	var heights := PackedFloat32Array()
	heights.resize((cells + 1) * (cells + 1))
	for vy in range(cells + 1):
		for vx in range(cells + 1):
			var noise := _fbm(lattice_seed, float(vx), float(vy))
			var h := base + relief * (noise - 0.5) * 2.0
			for crater: Array in craters:
				var t: float = Vector2(vx - crater[0], vy - crater[1]).length() / crater[2]
				if t < 1.0:
					h -= depth * (1.0 - t * t)
				elif t < 1.3:
					h += depth * 0.25 * (1.0 - (t - 1.0) / 0.3)
			var pad_distance := Vector2(vx - pad[0], vy - pad[1]).length()
			h *= smoothstep(clear * 0.5, clear * 1.5, pad_distance)
			heights[vy * (cells + 1) + vx] = h
	return heights


static func height_at(heights: PackedFloat32Array, cells: int, cell_m: float, x: float, z: float) -> float:
	var half := cells * cell_m * 0.5
	var fx := clampf((x + half) / cell_m, 0.0, float(cells) - 0.0001)
	var fy := clampf((z + half) / cell_m, 0.0, float(cells) - 0.0001)
	var ix := int(fx)
	var iy := int(fy)
	var tx := fx - ix
	var ty := fy - iy
	var stride := cells + 1
	var top := lerpf(heights[iy * stride + ix], heights[iy * stride + ix + 1], tx)
	var bottom := lerpf(heights[(iy + 1) * stride + ix], heights[(iy + 1) * stride + ix + 1], tx)
	return lerpf(top, bottom, ty)


static func _fbm(lattice_seed: int, x: float, y: float) -> float:
	var total := 0.0
	var weight := 0.55
	var norm := 0.0
	for octave in range(3):
		var size := 24.0 / pow(2.0, octave)
		total += weight * _value_noise(lattice_seed + octave * 7919, x / size, y / size)
		norm += weight
		weight *= 0.5
	return total / norm


static func _value_noise(lattice_seed: int, x: float, y: float) -> float:
	var ix := floori(x)
	var iy := floori(y)
	var tx := smoothstep(0.0, 1.0, x - ix)
	var ty := smoothstep(0.0, 1.0, y - iy)
	var a := _lattice(lattice_seed, ix, iy)
	var b := _lattice(lattice_seed, ix + 1, iy)
	var c := _lattice(lattice_seed, ix, iy + 1)
	var d := _lattice(lattice_seed, ix + 1, iy + 1)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)


static func _lattice(lattice_seed: int, x: int, y: int) -> float:
	var h := (lattice_seed ^ ((x * 374761393) & 0xFFFFFFFF) ^ ((y * 668265263) & 0xFFFFFFFF)) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	h = h ^ (h >> 16)
	return float(h & 0xFFFF) / 65535.0
