extends Reference

# Builds the automatic part of a character schema (the "skeleton") from the
# character scene itself: every selectable state with its frame data measured
# from hitbox nodes, meter cost, air rules and cancel categories, plus the
# character-specific script variables. Nothing here is guessed; the LLM only
# adds meaning on top (see SchemaStore).
#
# The scene is instanced off-tree so _ready() never runs: no game, sounds or
# signals are touched. Works for vanilla and modded characters alike, using
# duck typing only.

const Util = preload("res://budok/core/Util.gd")
const ACTION_TYPES := ["Movement", "Attack", "Special", "Super", "Defense", "Hurt"]
const AIR_TYPES := ["Grounded", "Aerial", "Both"]
const HIT_HEIGHTS := ["High", "Mid", "Low"]
const HITBOX_TYPES := ["Normal", "Flip", "ThrowHit", "OffensiveBurst", "Burst", "NoHitstun", "Detect"]
const BASE_CHAR_SUFFIX := "characters/BaseChar.gd"
# Source snippets that mean a move's real behaviour is decided in code.
const DYNAMIC_MARKERS := ["spawn_object", "create_hitbox", ".activate()", "projectile", ".damage =", "set_vel(", "apply_force"]
const SKELETON_VERSION := 1

var _cache := {}


func skeleton(entry: Dictionary) -> Dictionary:
	var scene_path = str(entry.get("scene_path", ""))
	if _cache.has(scene_path):
		return _cache[scene_path]
	var packed = load(scene_path) if scene_path != "" else null
	if packed == null or not packed.has_method("instance"):
		return {"ok": false, "error": "cannot load character scene %s" % scene_path}
	var fighter = packed.instance()
	if fighter == null:
		return {"ok": false, "error": "cannot instance character scene %s" % scene_path}
	var result = _build(fighter, entry)
	fighter.free()
	_cache[scene_path] = result
	return result


func clear_cache() -> void:
	_cache.clear()


func _build(fighter, entry: Dictionary) -> Dictionary:
	var moves = {}
	var other_states = []
	var sources = []
	for state in _find_states(fighter):
		var info = _describe_state(state)
		if info["selectable"] and info["type"] != "Hurt":
			moves[info["name"]] = info
		else:
			other_states.append(info["name"])
		var source = _own_source(state)
		if source != "":
			sources.append(source.sha256_text())
	other_states.sort()
	var chain = Util.script_chain(fighter)
	var skeleton = {
		"ok": true,
		"skeleton_version": SKELETON_VERSION,
		"character": entry.get("display_name", ""),
		"internal_name": entry.get("name", ""),
		"scene_path": entry.get("scene_path", ""),
		"mod_folder": entry.get("mod_folder", ""),
		"source": entry.get("source", ""),
		"script_path": chain[0] if not chain.empty() else "",
		"stats": {
			"max_health": Util.as_int(Util.prop(fighter, "MAX_HEALTH", 0)),
			"air_movements": Util.as_int(Util.prop(fighter, "num_air_movements", 0)),
			"free_cancels": Util.as_int(Util.prop(fighter, "num_feints", 0)),
			"damage_taken_modifier": Util.numeric(Util.prop(fighter, "damage_taken_modifier", "1.0")),
		},
		"resources": custom_properties(fighter),
		"moves": moves,
		"other_states": other_states,
	}
	sources.sort()
	var fingerprint_input = Util.to_json(skeleton, true) + "|" + PoolStringArray(sources).join(",")
	skeleton["fingerprint"] = fingerprint_input.sha256_text().substr(0, 16)
	return skeleton


# Script variables the character adds on top of BaseChar (ammo, stances,
# install timers...). Works on live fighters too, which is how the observation
# builder exposes modded resources without per-character code.
static func custom_properties(fighter) -> Dictionary:
	var result = {}
	var script = fighter.get_script() if Util.valid(fighter) else null
	if script == null:
		return result
	var base = script
	while base != null and not str(base.resource_path).ends_with(BASE_CHAR_SUFFIX):
		base = base.get_base_script()
	var excluded = {}
	if base != null:
		for prop_info in base.get_script_property_list():
			excluded[prop_info["name"]] = true
	for prop_info in script.get_script_property_list():
		var name = str(prop_info["name"])
		if excluded.has(name) or name.begins_with("_"):
			continue
		var value = fighter.get(name)
		if value is Object or (value is Array and value.size() > 8):
			continue
		var safe = Util.json_safe(value)
		if safe == null or (safe is Dictionary and safe.size() > 6):
			continue
		result[name] = safe
		if result.size() >= 40:
			break
	return result


func _find_states(root) -> Array:
	var found = []
	var queue = [root]
	var depth = {root: 0}
	while not queue.empty():
		var node = queue.pop_front()
		for child in node.get_children():
			if _is_character_state(child):
				found.append(child)
			elif depth[node] < 4:
				depth[child] = depth[node] + 1
				queue.append(child)
	return found


static func _is_character_state(node) -> bool:
	return (
		Util.has_prop(node, "interrupt_from_string")
		and Util.has_prop(node, "anim_length")
		and Util.has_prop(node, "data_ui_scene")
	)


func _describe_state(state) -> Dictionary:
	var anim_length = Util.as_int(Util.prop(state, "anim_length", 1))
	var iasa = Util.as_int(Util.prop(state, "iasa_at", -1))
	if iasa < 0:
		iasa = anim_length + iasa
	var hitboxes = []
	var startup = -1
	var active_end = -1
	var total_damage = 0
	var reach = -1
	for child in state.get_children():
		if not (Util.has_prop(child, "hitstun_ticks") and Util.has_prop(child, "start_tick") and Util.has_prop(child, "damage")):
			continue
		var box = _describe_hitbox(child)
		hitboxes.append(box)
		if box["type"] == "Detect":
			continue
		total_damage += box["damage"]
		reach = int(max(reach, box.get("reach", -1)))
		if startup == -1 or box["start"] < startup:
			startup = box["start"]
		active_end = int(max(active_end, box["start"] + box["active"] - 1))
	var super_level = Util.as_int(Util.prop(state, "super_level_", 0))
	var supers_used = Util.as_int(Util.prop(state, "supers_used_", -1))
	var chain = Util.script_chain(state)
	var title = str(Util.prop(state, "title", ""))
	var info = {
		"name": str(state.name),
		"title": title if title != "" else str(state.name),
		"type": Util.enum_name(ACTION_TYPES, Util.prop(state, "type", 0)),
		"selectable": bool(Util.prop(state, "show_in_menu", true)) and bool(Util.prop(state, "selectable", true)),
		"air": Util.enum_name(AIR_TYPES, Util.prop(state, "air_type", 0)),
		"uses_air_option": bool(Util.prop(state, "uses_air_movement", false)),
		"meter_bars": supers_used if supers_used >= 0 else super_level,
		"requires_bars": super_level,
		"length": anim_length,
		"actionable_at": iasa,
		"reversible": bool(Util.prop(state, "reversible", true)),
		"feintable": bool(Util.prop(state, "can_feint_if_possible", true)) or bool(Util.prop(state, "force_feintable", false)),
		"combo_only": bool(Util.prop(state, "combo_only", false)),
		"neutral_only": bool(Util.prop(state, "neutral_only", false)),
		"beats_backdash": bool(Util.prop(state, "beats_backdash", false)),
		"interrupt_from": _categories(Util.prop(state, "interrupt_from_string", "")),
		"interrupt_into": _categories(Util.prop(state, "interrupt_into_string", "")),
		"hit_cancel_into": _categories(Util.prop(state, "hit_cancel_into_string", "")),
		"has_payload": Util.prop(state, "data_ui_scene", null) != null,
		"hitboxes": hitboxes,
		"script_path": chain[0] if not chain.empty() else "",
	}
	if startup > 0:
		info["frames"] = {
			"startup": startup,
			"active": active_end - startup + 1,
			"recovery": int(max(0, iasa - active_end)),
			"hits": hitboxes.size(),
			"total_damage": total_damage,
		}
		if reach >= 0:
			info["frames"]["reach"] = reach
	var projectile = Util.prop(state, "projectile_scene", null)
	if projectile != null and Util.has_prop(projectile, "resource_path"):
		info["projectile"] = {"scene": str(projectile.resource_path), "spawn_tick": Util.as_int(Util.prop(state, "projectile_tick", 1))}
	var source = _own_source(state)
	var dynamic = []
	for marker in DYNAMIC_MARKERS:
		if source.find(marker) != -1:
			dynamic.append(marker)
	if not dynamic.empty() or (hitboxes.empty() and info["type"] in ["Attack", "Special", "Super"]):
		info["dynamic"] = true
		info["dynamic_hints"] = dynamic
	return info


func _describe_hitbox(box) -> Dictionary:
	var info = {
		"type": Util.enum_name(HITBOX_TYPES, Util.prop(box, "hitbox_type", 0)),
		"damage": Util.as_int(Util.prop(box, "damage", 0)),
		"start": Util.as_int(Util.prop(box, "start_tick", 0)),
		"active": Util.as_int(Util.prop(box, "active_ticks", 0)),
		"hitstun": Util.as_int(Util.prop(box, "hitstun_ticks", 0)),
		"height": Util.enum_name(HIT_HEIGHTS, Util.prop(box, "hit_height", 1)),
		"plus_frames": Util.as_int(Util.prop(box, "plus_frames", 0)),
		"knockback": Util.numeric(Util.prop(box, "knockback", "0")),
		"launch": {"x": Util.numeric(Util.prop(box, "dir_x", "0")), "y": Util.numeric(Util.prop(box, "dir_y", "0"))},
	}
	# CollisionBox geometry: (x, y) offset from the fighter when facing right,
	# width/height are half extents. Same units as fighter positions.
	if Util.has_prop(box, "width") and Util.has_prop(box, "x"):
		var bx = Util.as_int(box.x)
		var by = Util.as_int(Util.prop(box, "y", 0))
		var half_w = Util.as_int(box.width)
		var half_h = Util.as_int(Util.prop(box, "height", 0))
		info["reach"] = bx + half_w
		info["vertical"] = [by - half_h, by + half_h]
	if Util.has_prop(box, "throw_state"):
		info["throw"] = true
	for flag in ["guard_break", "knockdown", "hard_knockdown", "wall_slam", "hits_otg", "always_on", "looping"]:
		if bool(Util.prop(box, flag, false)):
			info[flag] = true
	if not bool(Util.prop(box, "beats_grab", true)):
		info["loses_to_grab"] = true
	var followup = str(Util.prop(box, "followup_state", ""))
	if followup != "":
		info["followup_state"] = followup
	return info


static func _categories(text) -> Array:
	var result = []
	for part in str(text).replace("\n", ",").split(","):
		var item = part.strip_edges()
		if item != "":
			result.append(item)
	return result


# Source of the state's own script when it is shipped as text (mods usually
# are). Base engine scripts are skipped: they are shared by every character.
static func _own_source(node) -> String:
	var script = node.get_script()
	if script == null or str(script.resource_path).begins_with("res://characters/states/"):
		return ""
	if script.has_method("has_source_code") and script.has_source_code():
		return str(script.source_code)
	return ""
