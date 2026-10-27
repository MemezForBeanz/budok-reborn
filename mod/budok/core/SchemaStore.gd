extends Reference

# Character schemas = measured skeleton (Introspector) + human/LLM-written notes.
# This store only persists the notes; frame data is always re-measured, so a
# schema can never contradict the game.
#
# Lookup order for a character's notes:
#   1. user://budok/schemas/<mod folder>__<Character>.json with "override": true
#   2. shipped inside the character's own mod (no generation needed):
#        <scene dir>/<scene name>.budok.json
#        <mod folder>/budok/<Character>.json
#        <mod folder>/budok_schema.json   (single schema, or {"characters": {...}})
#   3. bundled with budok (vanilla characters): res://budok/schemas/vanilla/<Character>.json
#   4. user://budok/schemas/<mod folder>__<Character>.json (generated or player-written)
#   5. user://budok/registry/<fingerprint>.json (opt-in community registry cache)

const Util = preload("res://budok/core/Util.gd")
const FORMAT := "budok.character.v1"
const USER_DIR := "user://budok/schemas"
const REGISTRY_DIR := "user://budok/registry"
const EXPORT_DIR := "user://budok/export"
const BUNDLED_DIR := "res://budok/schemas/vanilla"
const CATEGORIES := ["attack", "grab", "projectile", "movement", "defense", "super", "special", "utility", "install", "counter"]
const RANGES := ["close", "mid", "far", "fullscreen", "any"]
const RISKS := ["low", "medium", "high"]
const MOVE_TEXT_FIELDS := ["summary", "beats", "loses_to", "use_when", "avoid_when", "payload_hint", "combo_hint"]
const SUMMARY_TEXT_FIELDS := ["archetype", "game_plan"]
const SUMMARY_LIST_FIELDS := ["strengths", "weaknesses", "tips"]
const MEASURED_FIELDS := ["startup", "active", "recovery", "damage", "total_damage", "frames", "hitboxes", "meter", "meter_bars", "length", "hits"]
const MAX_TEXT := 600

var _introspector = null
var _cache := {}


func _init(introspector) -> void:
	_introspector = introspector


# Everything a caller needs about one character. Cached until invalidate().
func describe(entry: Dictionary) -> Dictionary:
	var key = entry["name"]
	if _cache.has(key):
		return _cache[key]
	var skeleton = _introspector.skeleton(entry)
	var found = _lookup(entry, skeleton)
	var schema = found.get("schema", {})
	var result = {
		"character": entry["display_name"],
		"internal_name": entry["name"],
		"skeleton": skeleton,
		"schema": schema,
		"status": found.get("status", "missing"),
		"schema_path": found.get("path", ""),
		"stale": skeleton.get("ok", false) and schema.has("fingerprint") and str(schema["fingerprint"]) != str(skeleton.get("fingerprint", "")),
		"coverage": coverage(schema, skeleton),
	}
	_cache[key] = result
	return result


func invalidate(entry_name: String = "") -> void:
	if entry_name == "":
		_cache.clear()
	else:
		_cache.erase(entry_name)


func move_notes(info: Dictionary, move_name: String) -> Dictionary:
	var moves = info.get("schema", {}).get("moves", {})
	return moves.get(move_name, {}) if moves is Dictionary else {}


func coverage(schema: Dictionary, skeleton: Dictionary) -> Dictionary:
	var moves = skeleton.get("moves", {})
	var notes = schema.get("moves", {})
	var missing = []
	for move_name in moves:
		if not (notes is Dictionary) or not notes.has(move_name):
			missing.append(move_name)
	missing.sort()
	return {
		"annotated": moves.size() - missing.size(),
		"total": moves.size(),
		"missing": missing,
		"has_summary": schema.get("summary", {}) is Dictionary and not schema.get("summary", {}).empty(),
	}


# Validates a (possibly partial) submission and merges it into the user schema
# file. Returns {"ok", "errors", "warnings", "coverage", "path"}.
func submit(entry: Dictionary, submission, provenance: Dictionary, replace: bool = false, override: bool = false) -> Dictionary:
	var info = describe(entry)
	var skeleton = info["skeleton"]
	if not skeleton.get("ok", false):
		return {"ok": false, "errors": [skeleton.get("error", "character could not be introspected")], "warnings": []}
	var checked = validate(submission, skeleton)
	if not checked["ok"]:
		return checked
	var path = _user_path(entry)
	var existing = Util.read_json(path)
	if replace or not (existing is Dictionary):
		existing = {}
	var merged = _merge(existing, checked["cleaned"])
	merged["format"] = FORMAT
	merged["character"] = entry["display_name"]
	merged["fingerprint"] = skeleton["fingerprint"]
	merged["provenance"] = provenance
	if override:
		merged["override"] = true
	if not Util.write_json(path, merged):
		return {"ok": false, "errors": ["could not write %s" % path], "warnings": checked["warnings"]}
	invalidate(entry["name"])
	var cover = coverage(merged, skeleton)
	var effective = describe(entry)
	var warnings = checked["warnings"]
	if effective["schema_path"] != path:
		warnings.append("saved to %s, but %s (%s) takes precedence; pass override=true to prefer yours" % [
			path, effective["schema_path"], effective["status"]])
	return {"ok": true, "errors": [], "warnings": warnings, "coverage": cover, "path": path}


func validate(submission, skeleton: Dictionary) -> Dictionary:
	var errors = []
	var warnings = []
	var cleaned = {}
	if not (submission is Dictionary):
		return {"ok": false, "errors": ["schema must be a JSON object"], "warnings": []}
	for key in submission:
		if not (key in ["format", "character", "fingerprint", "provenance", "summary", "resources", "extras", "moves", "override"]):
			warnings.append("ignored unknown top-level field '%s'" % key)
	if submission.has("summary"):
		cleaned["summary"] = _clean_summary(submission["summary"], errors)
	if submission.has("moves"):
		cleaned["moves"] = _clean_moves(submission["moves"], skeleton, errors, warnings)
	if submission.has("resources"):
		cleaned["resources"] = _clean_resources(submission["resources"], skeleton, errors, warnings)
	if submission.has("extras"):
		cleaned["extras"] = _clean_extras(submission["extras"], errors)
	return {"ok": errors.empty(), "errors": errors, "warnings": warnings, "cleaned": cleaned}


func export_schema(entry: Dictionary) -> Dictionary:
	var info = describe(entry)
	if info["schema"].empty():
		return {"ok": false, "error": "no schema to export for %s" % entry["display_name"]}
	var schema = info["schema"].duplicate(true)
	schema.erase("override")
	var path = "%s/%s.budok.json" % [EXPORT_DIR, Util.safe_file_name(entry["display_name"])]
	Util.write_json(path, schema)
	return {
		"ok": true,
		"path": path,
		"absolute_path": ProjectSettings.globalize_path(path),
		"install_hint": "mod authors: ship this file next to the character scene as %s" % (
			str(entry["scene_path"]).get_basename() + ".budok.json"),
	}


func store_registry(fingerprint: String, schema: Dictionary) -> void:
	Util.write_json("%s/%s.json" % [REGISTRY_DIR, Util.safe_file_name(fingerprint)], schema)
	_cache.clear()


func _lookup(entry: Dictionary, skeleton: Dictionary) -> Dictionary:
	var user_path = _user_path(entry)
	var user_schema = Util.read_json(user_path)
	if user_schema is Dictionary and bool(user_schema.get("override", false)):
		return {"status": "override", "path": user_path, "schema": user_schema}
	for candidate in _mod_candidates(entry):
		var shipped = _read_shipped(candidate, entry["display_name"])
		if shipped is Dictionary:
			return {"status": "mod", "path": candidate, "schema": shipped}
	if entry.get("source", "") == "vanilla":
		var bundled_path = "%s/%s.json" % [BUNDLED_DIR, entry["display_name"]]
		var bundled = Util.read_json(bundled_path)
		if bundled is Dictionary:
			return {"status": "curated", "path": bundled_path, "schema": bundled}
	if user_schema is Dictionary:
		return {"status": "generated", "path": user_path, "schema": user_schema}
	var fingerprint = str(skeleton.get("fingerprint", ""))
	if fingerprint != "":
		var registry_path = "%s/%s.json" % [REGISTRY_DIR, fingerprint]
		var cached = Util.read_json(registry_path)
		if cached is Dictionary:
			return {"status": "registry", "path": registry_path, "schema": cached}
	return {"status": "missing"}


func _mod_candidates(entry: Dictionary) -> Array:
	var candidates = []
	var scene_path = str(entry.get("scene_path", ""))
	if scene_path != "":
		candidates.append(scene_path.get_basename() + ".budok.json")
	var folder = str(entry.get("mod_folder", ""))
	if folder != "":
		candidates.append("%s/budok/%s.json" % [folder, entry["display_name"]])
		candidates.append("%s/budok_schema.json" % folder)
	return candidates


func _read_shipped(path: String, display_name: String):
	var data = Util.read_json(path)
	if not (data is Dictionary):
		return null
	if data.get("characters") is Dictionary:
		return data["characters"].get(display_name)
	var named = str(data.get("character", ""))
	if named != "" and named.to_lower() != display_name.to_lower():
		return null
	return data


# Keyed by mod folder + display name: the character loader's internal name
# embeds the MD5 of the mod zip, which changes with every mod update.
func _user_path(entry: Dictionary) -> String:
	var folder = str(entry.get("mod_folder", "")).replace("res://", "")
	var key = entry["display_name"] if folder == "" else "%s__%s" % [folder, entry["display_name"]]
	return "%s/%s.json" % [USER_DIR, Util.safe_file_name(key)]


func _merge(base: Dictionary, update: Dictionary) -> Dictionary:
	var result = base.duplicate(true)
	for section in ["moves", "resources", "extras"]:
		if update.has(section):
			var target = result.get(section, {})
			for key in update[section]:
				target[key] = update[section][key]
			result[section] = target
	if update.has("summary"):
		var summary = result.get("summary", {})
		for key in update["summary"]:
			summary[key] = update["summary"][key]
		result["summary"] = summary
	return result


func _clean_summary(value, errors: Array) -> Dictionary:
	var out = {}
	if not (value is Dictionary):
		errors.append("summary must be an object with %s" % str(SUMMARY_TEXT_FIELDS + SUMMARY_LIST_FIELDS))
		return out
	for key in value:
		if key in SUMMARY_TEXT_FIELDS:
			var text = _text(value[key], "summary.%s" % key, errors)
			if text != "":
				out[key] = text
		elif key in SUMMARY_LIST_FIELDS:
			var items = _text_list(value[key], "summary.%s" % key, errors)
			if not items.empty():
				out[key] = items
		else:
			errors.append("summary.%s is not a known field; use %s" % [key, str(SUMMARY_TEXT_FIELDS + SUMMARY_LIST_FIELDS)])
	return out


func _clean_moves(value, skeleton: Dictionary, errors: Array, warnings: Array) -> Dictionary:
	var out = {}
	if not (value is Dictionary):
		errors.append("moves must be an object keyed by move (state) name")
		return out
	var known = skeleton.get("moves", {})
	var by_title = {}
	for move_name in known:
		by_title[str(known[move_name].get("title", "")).to_lower()] = move_name
	for key in value:
		var move_name = str(key)
		if not known.has(move_name):
			if by_title.has(move_name.to_lower()):
				warnings.append("'%s' is a button title; stored under state name '%s'" % [move_name, by_title[move_name.to_lower()]])
				move_name = by_title[move_name.to_lower()]
			else:
				errors.append("unknown move '%s'%s" % [move_name, _suggest(move_name, known.keys())])
				continue
		var notes = value[key]
		if not (notes is Dictionary):
			errors.append("moves.%s must be an object" % move_name)
			continue
		var clean = {}
		for field in notes:
			var path = "moves.%s.%s" % [move_name, field]
			if field in MEASURED_FIELDS:
				warnings.append("%s is measured automatically from the game and was ignored" % path)
			elif field == "category":
				var category = str(notes[field]).to_lower()
				if category in CATEGORIES:
					clean["category"] = category
				else:
					errors.append("%s must be one of %s" % [path, str(CATEGORIES)])
			elif field == "range":
				var move_range = str(notes[field]).to_lower()
				if move_range in RANGES:
					clean["range"] = move_range
				else:
					errors.append("%s must be one of %s" % [path, str(RANGES)])
			elif field == "risk":
				var risk = str(notes[field]).to_lower()
				if risk in RISKS:
					clean["risk"] = risk
				else:
					errors.append("%s must be one of %s" % [path, str(RISKS)])
			elif field == "tags":
				var tags = _text_list(notes[field], path, errors)
				if not tags.empty():
					clean["tags"] = tags
			elif field in MOVE_TEXT_FIELDS:
				var text = _text(notes[field], path, errors)
				if text != "":
					clean[field] = text
			else:
				warnings.append("ignored unknown field %s" % path)
		if not clean.empty():
			out[move_name] = clean
	return out


func _clean_resources(value, skeleton: Dictionary, errors: Array, warnings: Array) -> Dictionary:
	var out = {}
	if not (value is Dictionary):
		errors.append("resources must be an object keyed by character variable name")
		return out
	var known = skeleton.get("resources", {})
	for key in value:
		if not known.has(key):
			errors.append("unknown resource '%s'%s" % [key, _suggest(key, known.keys())])
			continue
		var notes = value[key]
		if not (notes is Dictionary):
			errors.append("resources.%s must be an object like {\"label\": ..., \"meaning\": ..., \"hidden\": false}" % key)
			continue
		var clean = {}
		for field in ["label", "meaning"]:
			if notes.has(field):
				var text = _text(notes[field], "resources.%s.%s" % [key, field], errors)
				if text != "":
					clean[field] = text
		if notes.has("hidden"):
			clean["hidden"] = bool(notes["hidden"])
		for field in notes:
			if not (field in ["label", "meaning", "hidden"]):
				warnings.append("ignored unknown field resources.%s.%s" % [key, field])
		out[key] = clean
	return out


func _clean_extras(value, errors: Array) -> Dictionary:
	var out = {}
	if not (value is Dictionary):
		errors.append("extras must be an object keyed by extra option name")
		return out
	for key in value:
		var meaning = value[key].get("meaning", "") if value[key] is Dictionary else value[key]
		var text = _text(meaning, "extras.%s" % key, errors)
		if text != "":
			out[key] = {"meaning": text}
	return out


func _text(value, path: String, errors: Array) -> String:
	if not (value is String):
		errors.append("%s must be a string" % path)
		return ""
	var text = value.strip_edges()
	if text.length() > MAX_TEXT:
		errors.append("%s is %d characters; keep it under %d" % [path, text.length(), MAX_TEXT])
		return ""
	return text


func _text_list(value, path: String, errors: Array) -> Array:
	if value is String:
		value = [value]
	if not (value is Array):
		errors.append("%s must be a list of strings" % path)
		return []
	var out = []
	for item in value:
		var text = _text(item, path, errors)
		if text != "":
			out.append(text)
	if out.size() > 8:
		errors.append("%s has %d entries; keep it to 8 or fewer" % [path, out.size()])
		return []
	return out


func _suggest(name: String, options: Array) -> String:
	var lower = name.to_lower()
	var best = ""
	var best_score = 0.0
	for option in options:
		var score = lower.similarity(str(option).to_lower())
		if score > best_score:
			best_score = score
			best = str(option)
	return " (did you mean '%s'?)" % best if best_score > 0.5 else ""
