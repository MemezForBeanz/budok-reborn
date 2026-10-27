extends Reference

# Read-only access to scripts and scenes inside the running game (res://),
# so a bot can read a modded character's code while annotating it or answer
# modding questions. user:// is never readable: that is where API keys live.
# Exported games may ship scripts compiled (.gdc) and scenes as binary (.scn);
# those are reported as unavailable rather than dumped.

const Util = preload("res://budok/core/Util.gd")
const TEXT_EXTENSIONS := ["gd", "tscn", "tres", "json", "md", "txt", "cfg", "gdshader", "shader"]
const SKIP_DIRS := [".import", ".git", "addons", "sound", "assets", "fx"]
const MAX_FILES_SCANNED := 5000

var max_file_bytes := 200000


func check_path(path: String) -> String:
	if not path.begins_with("res://"):
		return "only res:// paths can be read"
	if path.find("..") != -1:
		return "path must not contain '..'"
	return ""


func read(path: String, start_line: int = 1, max_lines: int = 400) -> Dictionary:
	var problem = check_path(path)
	if problem != "":
		return {"ok": false, "error": problem}
	var text = _text_of(path, true)
	if text == null:
		return {"ok": false, "error": "%s is not available as text (missing, binary or compiled in this build)" % path}
	var lines = text.split("\n")
	var first = int(max(1, start_line))
	var last = int(min(lines.size(), first + int(clamp(max_lines, 1, 2000)) - 1))
	var numbered = []
	for i in range(first - 1, last):
		numbered.append("%5d  %s" % [i + 1, lines[i]])
	return {
		"ok": true,
		"path": path,
		"total_lines": lines.size(),
		"start_line": first,
		"end_line": last,
		"content": PoolStringArray(numbered).join("\n"),
	}


func list(prefix: String, max_entries: int = 300) -> Dictionary:
	var problem = check_path(prefix)
	if problem != "":
		return {"ok": false, "error": problem}
	var dir = Directory.new()
	if dir.open(prefix) != OK:
		return {"ok": false, "error": "cannot open %s" % prefix}
	var dirs = []
	var files = []
	dir.list_dir_begin(true, true)
	var name = dir.get_next()
	while name != "" and dirs.size() + files.size() < max_entries:
		if dir.current_is_dir():
			dirs.append(name + "/")
		else:
			files.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	dirs.sort()
	files.sort()
	return {"ok": true, "path": prefix, "directories": dirs, "files": files}


func search(query: String, prefix: String = "res://", max_results: int = 40) -> Dictionary:
	var problem = check_path(prefix)
	if problem != "":
		return {"ok": false, "error": problem}
	if query.strip_edges().length() < 2:
		return {"ok": false, "error": "query must be at least 2 characters"}
	var needle = query.to_lower()
	var results = []
	var scanned = 0
	var unreadable = 0
	var queue = [prefix.trim_suffix("/")]
	while not queue.empty() and results.size() < max_results and scanned < MAX_FILES_SCANNED:
		var current = queue.pop_front()
		var dir = Directory.new()
		if dir.open(current) != OK:
			continue
		dir.list_dir_begin(true, true)
		var name = dir.get_next()
		while name != "":
			var full = current + "/" + name
			if dir.current_is_dir():
				if not (name in SKIP_DIRS):
					queue.append(full)
			else:
				var ext = name.get_extension().to_lower()
				var logical = full.trim_suffix(".remap") if ext == "remap" else full
				if logical.get_extension().to_lower() in TEXT_EXTENSIONS:
					scanned += 1
					var text = _text_of(logical, false)
					if text == null:
						unreadable += 1
					else:
						_collect(logical, text, needle, results, max_results)
			name = dir.get_next()
		dir.list_dir_end()
		if results.size() >= max_results:
			break
	return {"ok": true, "query": query, "matches": results, "files_scanned": scanned, "files_unreadable": unreadable}


func _collect(path: String, text: String, needle: String, results: Array, max_results: int) -> void:
	var lines = text.split("\n")
	for i in range(lines.size()):
		if lines[i].to_lower().find(needle) != -1:
			results.append({"path": path, "line": i + 1, "text": Util.truncate(lines[i].strip_edges(), 200)})
			if results.size() >= max_results:
				return


# allow_load: fall back to loading the script resource to get its source
# (needed when only a .remap entry exists). Too costly for bulk search.
func _text_of(path: String, allow_load: bool):
	if allow_load and path.get_extension() == "gd":
		var script = load(path) if ResourceLoader.exists(path) else null
		if script != null and script.has_method("has_source_code") and script.has_source_code():
			return str(script.source_code)
	if not Util.file_exists(path):
		return null
	var text = Util.read_text(path, max_file_bytes)
	if text == null or text.find(char(0)) != -1:
		return null
	return text
