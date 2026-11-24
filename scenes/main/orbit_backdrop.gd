extends Control

const CENTER := Vector2(0.76, 0.49)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	var center := size * CENTER
	var scale_factor := minf(size.x / 1280.0, size.y / 720.0)
	var random := RandomNumberGenerator.new()
	random.seed = 360
	for index in range(116):
		var x := random.randf_range(size.x * 0.43, size.x)
		var y := random.randf_range(0.0, size.y)
		var alpha := random.randf_range(0.15, 0.62)
		draw_circle(Vector2(x, y), 1.35 if index % 15 == 0 else 0.7, Color(0.62, 0.74, 0.9, alpha))
	for radius in [92.0, 143.0, 205.0, 272.0]:
		var points := PackedVector2Array()
		for index in range(121):
			points.append(center + _orbit_point(radius * scale_factor, TAU * index / 120.0))
		draw_polyline(points, Color("#26394f"), 1.0, true)
	for radius in [46.0, 38.0, 30.0]:
		draw_circle(center, radius * scale_factor, Color(0.76, 0.32, 0.10, 0.08), true, -1.0, true)
	draw_circle(center, 23.0 * scale_factor, Color("#e79c57"), true, -1.0, true)
	draw_circle(center + Vector2(-5.0, -4.0) * scale_factor, 16.0 * scale_factor, Color("#f7bd79"), true, -1.0, true)
	var earth := center + _orbit_point(143.0 * scale_factor, -0.72)
	draw_circle(earth, 8.0 * scale_factor, Color("#6ca6eb"), true, -1.0, true)
	draw_arc(earth, 20.0 * scale_factor, 0.0, TAU, 42, Color("#2d4c6e"), 1.0, true)
	draw_circle(earth + Vector2(18.0, -9.0) * scale_factor, 3.0 * scale_factor, Color("#b8c9d9"), true, -1.0, true)
	draw_circle(center + _orbit_point(205.0 * scale_factor, 1.12), 5.0 * scale_factor, Color("#c0745c"), true, -1.0, true)


func _orbit_point(radius: float, angle: float) -> Vector2:
	return Vector2(cos(angle) * radius, sin(angle) * radius * 0.66).rotated(-0.30)
