extends SceneTree

# Boots the full budok runtime outside the game (no match, no Global), so the
# MCP server, panel and services can be exercised over real HTTP:
#   godot --no-window --path mod -s res://tests/runtime_smoke.gd
# Runs until killed or for BUDOK_SMOKE_SECONDS (default 60).

var _deadline := 0


func _init() -> void:
	var seconds = int(OS.get_environment("BUDOK_SMOKE_SECONDS")) if OS.get_environment("BUDOK_SMOKE_SECONDS") != "" else 60
	_deadline = OS.get_ticks_msec() + seconds * 1000
	var mod = load("res://budok/ModMain.gd").new(null)
	root.call_deferred("add_child", mod)


func _idle(_delta: float) -> bool:
	return OS.get_ticks_msec() > _deadline
