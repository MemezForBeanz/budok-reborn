extends Node

# Native automation hook. Set automation.script in user://budok/config.json to
# a GDScript (user:// or res://) that defines `func run(runtime)`; it is loaded
# once the game has finished booting and receives the same API the MCP tools
# use (runtime.matches, runtime.schemas, MatchStarter, ...). `run` may be a
# coroutine. External automation can drive the same API over MCP instead (see
# connectors/python in the repository).

const Util = preload("res://budok/core/Util.gd")

var runtime = null
var instance = null
var last_error := ""


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	var path = str(runtime.config.get_value("automation.script", ""))
	if path != "":
		call_deferred("_start", path)


func _start(path: String) -> void:
	# Let the main menu and character loader finish initialising first.
	var waited = 0
	while Util.prop(Util.autoload("Network"), "css_instance", null) == null and waited < 600:
		yield(get_tree(), "idle_frame")
		waited += 1
	var script = load(path) if ResourceLoader.exists(path) or Util.file_exists(path) else null
	if script == null or not script.can_instance():
		last_error = "cannot load automation script %s" % path
		push_warning("budok: " + last_error)
		return
	instance = script.new()
	if instance is Node:
		add_child(instance)
	if instance.has_method("run"):
		print("budok: running automation script %s" % path)
		instance.run(runtime)
	else:
		last_error = "%s has no run(runtime) function" % path
		push_warning("budok: " + last_error)
