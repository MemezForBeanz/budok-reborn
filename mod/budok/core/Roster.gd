extends Reference

# Every character the game can start a match with: vanilla entries in
# Global.name_paths plus custom characters registered with the built-in
# character loader (CharacterSelect.addCustomChar). Custom characters are
# lazy-loaded by the game; their internal key is "F-<mod hash>__<Name>" and only
# appears in Global.name_paths once loaded.

const Util = preload("res://budok/core/Util.gd")


func list() -> Array:
	var result = []
	var seen = {}
	var name_paths = _name_paths()
	var css = _css()
	for key in name_paths:
		seen[key] = true
		result.append(_entry(key, str(name_paths[key]), true))
	if css != null:
		var char_list = Util.prop(css, "charList", [])
		var name_to_index = Util.prop(css, "name_to_index", {})
		for key in name_to_index:
			if seen.has(key):
				continue
			var index = int(name_to_index[key])
			if index < 0 or index >= char_list.size():
				continue
			seen[key] = true
			result.append(_entry(key, str(char_list[index][1]), false))
	return result


func resolve(query: String):
	var wanted = query.strip_edges().to_lower()
	if wanted == "":
		return null
	var fallback = null
	for entry in list():
		if entry["name"].to_lower() == wanted:
			return entry
		if fallback == null and entry["display_name"].to_lower() == wanted:
			fallback = entry
	return fallback


# Makes a custom character playable. Returns {"ok": bool, "error"?: String}.
func ensure_loaded(entry: Dictionary) -> Dictionary:
	if _name_paths().has(entry["name"]):
		return {"ok": true}
	var css = _css()
	if css == null or not css.has_method("loadListChar"):
		return {"ok": false, "error": "character loader is not available; open the character select screen once and retry"}
	var name_to_index = Util.prop(css, "name_to_index", {})
	if not name_to_index.has(entry["name"]):
		return {"ok": false, "error": "character %s is not registered with the character loader" % entry["name"]}
	var missing = css.loadListChar(int(name_to_index[entry["name"]]))
	# loadListChar leaves the select screen in its "loading" state; the game's
	# own caller clears it afterwards, so do the same.
	if Util.has_prop(css, "currentlyLoading"):
		css.currentlyLoading = false
	Util.call_or(css, "loadingLabel_vanish")
	if missing is Array and not missing.empty():
		return {"ok": false, "error": "character files missing: %s" % str(missing)}
	if not _name_paths().has(entry["name"]):
		return {"ok": false, "error": "character %s failed to load" % entry["name"]}
	return {"ok": true}


func entry_for_fighter(fighter):
	var scene_path = str(Util.prop(fighter, "filename", ""))
	for entry in list():
		if entry["scene_path"] == scene_path:
			return entry
	var name = str(Util.prop(fighter, "name", "?"))
	return {
		"name": name,
		"display_name": display_name(name),
		"scene_path": scene_path,
		"source": "unknown",
		"mod_folder": mod_folder(scene_path),
		"loaded": true,
	}


static func display_name(internal_name: String) -> String:
	var parts = internal_name.split("__", false, 1)
	return parts[1] if parts.size() == 2 and internal_name.begins_with("F-") else internal_name


static func mod_folder(scene_path: String) -> String:
	if not scene_path.begins_with("res://"):
		return ""
	var rest = scene_path.substr(6)
	var slash = rest.find("/")
	return "res://" + (rest.substr(0, slash) if slash != -1 else rest)


func _entry(key: String, scene_path: String, loaded: bool) -> Dictionary:
	var custom = key.begins_with("F-") or not scene_path.begins_with("res://characters/")
	return {
		"name": key,
		"display_name": display_name(key),
		"scene_path": scene_path,
		"source": "mod" if custom else "vanilla",
		"mod_folder": mod_folder(scene_path) if custom else "",
		"loaded": loaded,
	}


func _name_paths() -> Dictionary:
	var global = Util.autoload("Global")
	var paths = Util.prop(global, "name_paths", {})
	return paths if paths is Dictionary else {}


func _css():
	for singleton in ["Network", "Global"]:
		var css = Util.prop(Util.autoload(singleton), "css_instance", null)
		if Util.valid(css):
			return css
	return null
