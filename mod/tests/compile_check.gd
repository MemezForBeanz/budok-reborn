extends SceneTree

# Loads every budok script with the real compiler; parse/compile errors are
# printed by the engine and counted here. Exit code = number of failures.
#   godot --no-window --path mod -s res://tests/compile_check.gd


func _init() -> void:
	var failures = 0
	var scripts = []
	_collect("res://budok", scripts)
	for path in scripts:
		var script = ResourceLoader.load(path, "", true)
		if script == null or not script.can_instance():
			failures += 1
			printerr("COMPILE FAIL: " + path)
	print("%d scripts checked, %d failures" % [scripts.size(), failures])
	quit(failures)


func _collect(dir_path: String, out: Array) -> void:
	var dir = Directory.new()
	if dir.open(dir_path) != OK:
		return
	dir.list_dir_begin(true, true)
	var entry = dir.get_next()
	while entry != "":
		var full = dir_path + "/" + entry
		if dir.current_is_dir():
			_collect(full, out)
		elif entry.get_extension() == "gd":
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
