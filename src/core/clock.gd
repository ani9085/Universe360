extends RefCounted

const MAX_TICKS_PER_FRAME := 120
const SECONDS_PER_TICK := 1.0
const TICK_EPSILON := 1.0e-9
var _pending_seconds := 0.0


func accumulate(delta: float, speed: int) -> void:
	if is_finite(delta) and delta >= 0.0:
		_pending_seconds += delta * speed


func take_tick() -> bool:
	if _pending_seconds + TICK_EPSILON < SECONDS_PER_TICK:
		return false
	_pending_seconds = maxf(0.0, _pending_seconds - SECONDS_PER_TICK)
	return true


func reset() -> void:
	_pending_seconds = 0.0
