extends Control

signal destination_selected(body_id: String)
signal destination_reached(body_id: String)

const Schema = preload("res://src/contracts/schema.gd")
const Navigation = preload("res://src/navigation/navigation.gd")
const BODIES := {
	"sol": [Vector2(0.06, 0.43), 99.0, Color("#f4a354"), "태양"],
	Schema.EARTH: [Vector2(0.30, 0.55), 66.0, Color("#2c92e5"), "지구"],
	Schema.MOON: [Vector2(0.65, 0.38), 47.0, Color("#b9cbd9"), "달"],
	Schema.MARS: [Vector2(0.87, 0.64), 54.0, Color("#e68159"), "화성"],
}
const CYAN := Color("#70e9db")
const TEXT := Color("#eaf5fd")
const SHIP_START := Vector2(0.085, 0.087)
const THRUST := 285.0

var body_id := Schema.EARTH
var target_id := Schema.MOON
var can_steer := false
var overview := false
var _ship := Vector2.ZERO
var _velocity := Vector2.ZERO
var _heading := Vector2(1.0, -0.22).normalized()
var _from := Vector2.ZERO
var _flight_position := Vector2.ZERO
var _destination := ""
var _flight_active := false
var _approached := false
var _fuel_exhaust_anim := 0.0
var _stars: Array[Vector3] = []
var _visited := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var random := RandomNumberGenerator.new()
	random.seed = 360
	for i in range(230):
		_stars.append(Vector3(random.randf(), random.randf(), random.randf()))
	resized.connect(queue_redraw)
	reset_ship(Schema.EARTH)


func reset_ship(id: String) -> void:
	body_id = id
	_ship = _body_point(id) + SHIP_START * Vector2(1.0, 1.0)
	_velocity = Vector2.ZERO
	_destination = ""
	_flight_active = false
	_approached = false
	queue_redraw()


func select_target(id: String) -> void:
	target_id = id
	_approached = false
	queue_redraw()


func show_flight(ship: Dictionary, visited: Dictionary) -> void:
	_visited = visited
	if ship["mode"] == Schema.FLIGHT:
		var destination: String = ship["destination_id"]
		var route := Navigation.route(destination)
		if route.is_empty():
			return
		if not _flight_active or destination != _destination:
			_from = _ship
			_flight_position = _from
			_velocity = Vector2.ZERO
			_destination = destination
			_flight_active = true
		var finish := _body_point(destination) + Vector2(0.049, 0.061)
		var direction := finish - _from
		if direction.length_squared() > 0.00001:
			_heading = (direction * size).normalized()
		var fraction := 1.0 - float(ship["travel_ticks_remaining"]) / float(route["ticks"])
		_flight_position = _from.lerp(finish, clampf(fraction, 0.0, 1.0))
	elif _flight_active or ship["body_id"] != body_id:
		reset_ship(ship["body_id"])
	queue_redraw()


func brake() -> void:
	_velocity = Vector2.ZERO


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_fuel_exhaust_anim += delta
	if _flight_active:
		_ship = _ship.lerp(_flight_position, 1.0 - exp(-delta * 20.0))
	if can_steer and not _flight_active and size.x > 0.0 and size.y > 0.0:
		var direction := Vector2(
			float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
			float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
		if direction != Vector2.ZERO:
			_heading = direction.normalized()
			_velocity = _velocity.move_toward(_heading * THRUST, delta * 950.0)
		else:
			_velocity = _velocity.move_toward(Vector2.ZERO, delta * 480.0)
		if Input.is_physical_key_pressed(KEY_SPACE):
			brake()
		_ship += _velocity * delta / size
		_ship = _ship.clamp(Vector2(0.025, 0.19), Vector2(0.975, 0.81))
		_check_approach()
	if _flight_active or _velocity.length_squared() > 0.1:
		queue_redraw()


func _check_approach() -> void:
	if target_id == body_id or not BODIES.has(target_id):
		return
	var radius: float = BODIES[target_id][1]
	var distance := (_ship - _body_point(target_id)).length() if size == Vector2.ZERO else +			((_ship - _body_point(target_id)) * size).length() / radius
	if not _approached and distance < 1.65:
		_approached = true
		destination_reached.emit(target_id)


func _gui_input(event: InputEvent) -> void:
	if overview or _flight_active:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		for id in [Schema.MOON, Schema.MARS]:
			var radius: float = BODIES[id][1] + 20.0
			if event.position.distance_to(_body_point(id) * size) <= radius:
				destination_selected.emit(id)
				accept_event()
				return


func _body_point(id: String) -> Vector2:
	return BODIES[id][0] if BODIES.has(id) else Vector2(0.42, 0.50)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#071322"))
	for star in _stars:
		var star_color := Color(0.72, 0.85, 1.0, 0.16 + star.z * 0.48)
		draw_circle(Vector2(star.x, star.y) * size, 0.55 + star.z * 0.77, star_color, true, -1.0, true)
	var origin := Vector2(0.06, 0.43) * size
	for radius in [186.0, 298.0, 475.0, 659.0, 859.0, 1110.0]:
		draw_arc(origin, radius * size.x / 1280.0, -2.0, 2.0, 100, Color("#1b3047"), 1.0, true)
	if not overview and BODIES.has(target_id):
		var mark := _body_point(target_id) * size
		var mark_radius: float = BODIES[target_id][1] + 17.0
		draw_arc(mark, mark_radius, 0.0, TAU, 70, Color("#4aa298"), 1.2, true)
		draw_arc(mark, mark_radius, -0.8, 0.04, 20, CYAN, 2.8, true)
		var from := _ship * size
		if from.distance_to(mark) > mark_radius + 23.0:
			_draw_course(from, mark, mark_radius)
	for id: String in BODIES:
		_draw_planet(id)
	if not overview:
		_draw_ship()


func _draw_course(from: Vector2, mark: Vector2, mark_radius: float) -> void:
	var direction := from.direction_to(mark)
	var start := from + direction * 20.0
	var finish := mark - direction * (mark_radius + 7.0)
	var distance := start.distance_to(finish)
	for step in range(0, int(distance), 14):
		draw_line(start + direction * step, start + direction * minf(step + 5.0, distance),
				Color(0.36, 0.84, 0.76, 0.40), 1.3, true)


func _draw_planet(id: String) -> void:
	var record: Array = BODIES[id]
	var point := _body_point(id) * size
	var radius: float = record[1]
	var hue: Color = record[2]
	for i in range(5, 0, -1):
		draw_circle(point, radius + i * 5.0, Color(hue, 0.049), true, -1.0, true)
	draw_circle(point, radius, hue.darkened(0.42), true, -1.0, true)
	for i in range(9, 0, -1):
		var fraction := float(i) / 9.0
		var inner := radius * fraction * 0.88
		var shift := Vector2(-0.54, -0.52) * (radius - inner)
		draw_circle(point + shift, inner, hue.darkened(0.28).lerp(hue.lightened(0.28), 1.0 - fraction),
				true, -1.0, true)
	if id == Schema.EARTH:
		for island in [Vector3(-0.33, -0.18, 0.23), Vector3(-0.21, 0.09, 0.15), Vector3(0.30, -0.32, 0.14), Vector3(0.21, 0.20, 0.10)]:
			draw_circle(point + Vector2(island.x, island.y) * radius, island.z * radius, Color("#66c4a4"), true, -1.0, true)
	elif id != "sol":
		for crater in [Vector3(-0.28, -0.28, 0.13), Vector3(0.21, 0.05, 0.12), Vector3(-0.16, 0.25, 0.08)]:
			draw_circle(point + Vector2(crater.x, crater.y) * radius, crater.z * radius,
					Color(hue.darkened(0.54), 0.38), true, -1.0, true)
	if overview:
		return
	var label: String = record[3]
	if _visited.has(id):
		label += " · 방문"
	var font := get_theme_default_font()
	var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x
	var offset := radius + (38.0 if id == target_id else 27.0)
	draw_string(font, point + Vector2(-width * 0.5, offset), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 19,
			CYAN if id == target_id else TEXT)


func _draw_ship() -> void:
	var anchor := _ship * size
	var rear := -_heading
	var right := Vector2(-_heading.y, _heading.x)
	if _flight_active or _velocity.length_squared() > 0.1:
		var exhaust := 11.0 + 3.0 * sin(_fuel_exhaust_anim * 36.0)
		draw_colored_polygon(PackedVector2Array([
			anchor + rear * (13.0 + exhaust), anchor + rear * 8.0 + right * 5.0,
			anchor + rear * 8.0 - right * 5.0]), Color("#6bd7fc"))
	draw_colored_polygon(PackedVector2Array([
		anchor + _heading * 16.0, anchor + rear * 11.0 + right * 10.0, anchor + rear * 6.0,
		anchor + rear * 11.0 - right * 10.0]), TEXT)
	draw_circle(anchor + _heading * 3.0, 3.6, Color("#1b809e"), true, -1.0, true)
