extends Reference

# Turns the live game into a compact, deterministic snapshot from one player's
# point of view. Character-specific resources come from the generic property
# diff (Introspector.custom_properties) labelled by the character schema, so
# modded characters need no code here.

const Util = preload("res://budok/core/Util.gd")
const Introspector = preload("res://budok/core/Introspector.gd")
const ACTION_TYPES := ["Movement", "Attack", "Special", "Super", "Defense", "Hurt"]
const PROJECTILE_BASE := "res://projectile/BaseProjectile.gd"


static func fighter_of(game, slot: String):
	return Util.prop(game, "p1" if slot == "p1" else "p2", null)


static func other(slot: String) -> String:
	return "p2" if slot == "p1" else "p1"


# detail: "summary" (per-turn) or "full" (everything, including raw resources).
static func build(game, slot: String, infos: Dictionary, history: Array, detail: String = "summary") -> Dictionary:
	var me = fighter_of(game, slot)
	var opp = fighter_of(game, other(slot))
	var me_obs = fighter(me, slot, infos.get(slot, {}), detail)
	var opp_obs = fighter(opp, other(slot), infos.get(other(slot), {}), detail)
	var dx = opp_obs["position"]["x"] - me_obs["position"]["x"]
	var dy = opp_obs["position"]["y"] - me_obs["position"]["y"]
	var obs = {
		"you": slot,
		"tick": Util.as_int(Util.prop(game, "current_tick", 0)),
		"ticks_left": Util.as_int(Util.call_or(game, "get_ticks_left", [], 0)),
		"me": me_obs,
		"opponent": opp_obs,
		"spacing": {
			"distance_x": int(abs(dx)),
			"distance_y": int(abs(dy)),
			"opponent_is": "right" if dx > 0 else ("left" if dx < 0 else "same_x"),
			"opponent_above": dy < 0,
		},
		"objects": objects(game, me),
		"stage": stage(game),
		"history": history.slice(max(0, history.size() - (12 if detail == "full" else 5)), history.size() - 1) if not history.empty() else [],
	}
	return obs


static func fighter(f, slot: String, info: Dictionary, detail: String) -> Dictionary:
	if not Util.valid(f):
		return {"slot": slot, "missing": true, "position": {"x": 0, "y": 0}}
	var state = Util.call_or(f, "current_state")
	var bar_size = Util.as_int(Util.constant(f, "MAX_SUPER_METER", 125))
	var obs = {
		"slot": slot,
		"character": info.get("character", str(Util.prop(f, "name", ""))),
		"hp": Util.as_int(Util.prop(f, "hp", 0)),
		"max_hp": Util.as_int(Util.prop(f, "MAX_HEALTH", 0)),
		"meter": {
			"bars": Util.as_int(Util.prop(f, "supers_available", 0)),
			"partial": Util.as_int(Util.prop(f, "super_meter", 0)),
			"bar_size": bar_size,
		},
		"burst": Util.as_int(Util.prop(f, "bursts_available", 0)),
		"free_cancels": Util.as_int(Util.prop(f, "feints", 0)),
		"air_options": Util.as_int(Util.prop(f, "air_movements_left", 0)),
		"position": Util.xy(Util.call_or(f, "get_pos", [], Vector2.ZERO)),
		"velocity": Util.xy(Util.call_or(f, "get_vel", [], Vector2.ZERO)),
		"facing": "right" if Util.as_int(Util.call_or(f, "get_facing_int", [], 1)) == 1 else "left",
		"grounded": bool(Util.call_or(f, "is_grounded", [], true)),
		"state": {
			"name": str(Util.prop(state, "state_name", Util.prop(state, "name", "?"))),
			"type": Util.enum_name(ACTION_TYPES, Util.prop(state, "type", 0)),
			"tick": Util.as_int(Util.prop(state, "current_tick", 0)),
		},
		"combo_count": Util.as_int(Util.prop(f, "combo_count", 0)),
		"hitlag": Util.as_int(Util.prop(f, "hitlag_ticks", 0)),
		"blockstun": Util.as_int(Util.prop(f, "blockstun_ticks", 0)),
		"busy": bool(Util.prop(f, "busy_interrupt", false)),
		"initiative": bool(Util.prop(f, "initiative", false)),
	}
	var title = str(Util.prop(state, "title", ""))
	if title != "" and title != obs["state"]["name"]:
		obs["state"]["title"] = title
	if bool(Util.prop(state, "is_hurt_state", false)):
		obs["state"]["hurt"] = true
	var penalty = Util.as_int(Util.prop(f, "penalty_ticks", 0))
	if penalty > 0:
		obs["defense_penalty"] = penalty
	var stance = str(Util.prop(f, "stance", "Normal"))
	if stance != "Normal":
		obs["stance"] = stance
	var resources = _resources(f, info, detail)
	if not resources.empty():
		obs["resources"] = resources
	return obs


static func _resources(f, info: Dictionary, detail: String) -> Dictionary:
	var raw = Introspector.custom_properties(f)
	var notes = info.get("schema", {}).get("resources", {})
	var out = {}
	for key in raw:
		var meta = notes.get(key, {}) if notes is Dictionary else {}
		if bool(meta.get("hidden", false)) and detail != "full":
			continue
		if detail == "full" or not meta.empty() or notes.empty():
			out[meta.get("label", key)] = raw[key]
	return out


static func objects(game, me) -> Array:
	var result = []
	var list = Util.prop(game, "objects", [])
	if not (list is Array):
		return result
	for obj in list:
		if not Util.valid(obj) or bool(Util.prop(obj, "disabled", false)):
			continue
		var creator = Util.prop(obj, "creator", null)
		var owner = ""
		if Util.valid(creator):
			owner = "mine" if creator == me else "opponent"
		var state = Util.call_or(obj, "current_state")
		var entry = {
			"type": Util.strip_trailing_digits(str(obj.name)),
			"kind": "projectile" if PROJECTILE_BASE in Util.script_chain(obj) else "object",
			"owner": owner,
			"position": Util.xy(Util.call_or(obj, "get_pos", [], Vector2.ZERO)),
			"velocity": Util.xy(Util.call_or(obj, "get_vel", [], Vector2.ZERO)),
		}
		if Util.valid(state):
			entry["state"] = str(Util.prop(state, "state_name", state.name))
		result.append(entry)
	result.sort_custom(ObjectSorter.new(), "less")
	return result


static func stage(game) -> Dictionary:
	return {
		"width": Util.as_int(Util.prop(game, "stage_width", 0)),
		"has_ceiling": bool(Util.prop(game, "has_ceiling", false)),
		"ceiling_height": Util.as_int(Util.prop(game, "ceiling_height", 0)),
	}


# One-paragraph plain-language recap; chat clients read this first.
static func situation(obs: Dictionary) -> String:
	var me = obs["me"]
	var opp = obs["opponent"]
	var lines = []
	lines.append("You are %s (%s) at %d/%d HP; opponent %s at %d/%d HP." % [
		obs["you"], me["character"], me["hp"], me["max_hp"], opp["character"], opp["hp"], opp["max_hp"]])
	lines.append("Distance %d (opponent to your %s%s). You are %s, opponent is %s." % [
		obs["spacing"]["distance_x"], obs["spacing"]["opponent_is"],
		", above you" if obs["spacing"]["opponent_above"] else "",
		"grounded" if me["grounded"] else "airborne", "grounded" if opp["grounded"] else "airborne"])
	lines.append("You: state %s, %d meter bars, burst %d, %d free cancels. Opponent: state %s%s, %d bars, burst %d." % [
		me["state"]["name"], me["meter"]["bars"], me["burst"], me["free_cancels"],
		opp["state"]["name"], " (hurt)" if opp["state"].get("hurt", false) else "", opp["meter"]["bars"], opp["burst"]])
	if me["combo_count"] > 0:
		lines.append("You are comboing the opponent (%d hits)." % me["combo_count"])
	if opp["combo_count"] > 0:
		lines.append("You are being comboed (%d hits) - consider DI or burst." % opp["combo_count"])
	if not obs["objects"].empty():
		lines.append("%d object(s) on screen." % obs["objects"].size())
	lines.append("%d ticks left in the match." % obs["ticks_left"])
	return PoolStringArray(lines).join(" ")


class ObjectSorter:
	func less(a, b) -> bool:
		return "%s_%d_%d" % [a["type"], a["position"]["x"], a["position"]["y"]] < "%s_%d_%d" % [
			b["type"], b["position"]["x"], b["position"]["y"]]
