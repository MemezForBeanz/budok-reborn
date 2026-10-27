extends Reference

# Turns the live game into a compact, deterministic snapshot from one player's
# point of view. Character-specific resources come from the generic property
# diff (Introspector.custom_properties) labelled by the character schema, so
# modded characters need no code here.

const Util = preload("res://budok/core/Util.gd")
const Introspector = preload("res://budok/core/Introspector.gd")
const ACTION_TYPES := ["Movement", "Attack", "Special", "Super", "Defense", "Hurt"]
const PROJECTILE_BASE := "res://projectile/BaseProjectile.gd"
const CORNER_DISTANCE := 60


static func fighter_of(game, slot: String):
	return Util.prop(game, "p1" if slot == "p1" else "p2", null)


static func other(slot: String) -> String:
	return "p2" if slot == "p1" else "p1"


# detail: "summary" (per-turn) or "full" (everything, including raw resources).
# motion: measured movement per tick of objects, by instance id (MatchController).
static func build(game, slot: String, infos: Dictionary, history: Array, detail: String = "summary", motion: Dictionary = {}) -> Dictionary:
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
		"objects": objects(game, me, motion),
		"stage": stage(game),
		"history": history.slice(max(0, history.size() - (12 if detail == "full" else 5)), history.size() - 1) if not history.empty() else [],
	}
	return obs


# The few fields worth reading every turn when the situation text is not enough.
static func compact(obs: Dictionary) -> Dictionary:
	var out = {"spacing": obs["spacing"], "history": obs["history"]}
	for who in ["me", "opponent"]:
		var f = obs[who]
		var slim = {"hp": f["hp"], "position": f["position"], "state": f["state"]["name"], "meter_bars": f["meter"]["bars"],
			"burst": f["burst"], "grounded": f["grounded"]}
		for key in ["hitlag", "busy", "combo_count"]:
			if f.get(key):
				slim[key] = f[key]
		if f.has("wall_distance"):
			slim["wall_distance"] = f["wall_distance"]
		out[who] = slim
	if not obs["objects"].empty():
		out["objects"] = obs["objects"]
	return out


static func fighter(f, slot: String, info: Dictionary, detail: String) -> Dictionary:
	if not Util.valid(f):
		return {"slot": slot, "missing": true, "position": {"x": 0, "y": 0}}
	var state = Util.call_or(f, "current_state")
	var bar_size = Util.as_int(Util.constant(f, "MAX_SUPER_METER", 125))
	var position = Util.xy(Util.call_or(f, "get_pos", [], Vector2.ZERO))
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
		"position": position,
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
	if obs["burst"] == 0:
		var burst_max = float(Util.as_int(Util.constant(f, "MAX_BURST_METER", 1500)))
		obs["burst_progress"] = int(100.0 * Util.as_int(Util.prop(f, "burst_meter", 0)) / burst_max) if burst_max > 0 else 0
	var walls = wall_distance(f, position)
	if not walls.empty():
		obs["wall_distance"] = walls
	var penalty = Util.as_int(Util.prop(f, "penalty_ticks", 0))
	if penalty > 0:
		obs["defense_penalty"] = penalty
	var stance = str(Util.prop(f, "stance", "Normal"))
	if stance != "Normal":
		obs["stance"] = stance
	var resources = _resources(f, info, detail)
	if not resources["values"].empty():
		obs["resources"] = resources["values"]
	if detail == "full" and resources["unchanged"] > 0:
		obs["resources_at_start_value"] = resources["unchanged"]
	return obs


# Character-specific variables. Ones still at their starting value (cooldowns at
# 0, unused flags) are left out unless the schema labels them; the full detail
# level reports how many were left out.
static func _resources(f, info: Dictionary, detail: String) -> Dictionary:
	var raw = Introspector.custom_properties(f)
	var notes = info.get("schema", {}).get("resources", {})
	var defaults = info.get("skeleton", {}).get("resources", {})
	var out = {}
	var unchanged = 0
	for key in raw:
		var meta = notes.get(key, {}) if notes is Dictionary else {}
		if bool(meta.get("hidden", false)) and detail != "full":
			continue
		var changed = not (defaults is Dictionary and defaults.has(key)) or Util.json_str(raw[key]) != Util.json_str(defaults[key])
		if not changed and meta.empty():
			unchanged += 1
			continue
		if detail == "full" or not meta.empty() or notes.empty():
			out[meta.get("label", key)] = raw[key]
	return {"values": out, "unchanged": unchanged}


# A readable type for an object: its scene or script file ("Shuriken"), since
# spawned objects are named by number.
static func object_type(obj) -> String:
	var file = str(Util.prop(obj, "filename", ""))
	if file != "":
		return file.get_file().get_basename()
	var chain = Util.script_chain(obj)
	if not chain.empty():
		return chain[0].get_file().get_basename()
	return Util.strip_trailing_digits(str(obj.name))


# Gap between the fighter's body (collision box) and each wall. Walls stand at
# -stage_width and +stage_width, and bodies stop when their edge reaches one.
static func wall_distance(f, position: Dictionary) -> Dictionary:
	var half_width = Util.as_int(Util.prop(f, "stage_width", 0))
	if half_width <= 0:
		return {}
	var box = Util.call_or(f, "get_collision_box", [], {})
	var left_edge = Util.as_int(box.get("x1", position["x"])) if box is Dictionary else position["x"]
	var right_edge = Util.as_int(box.get("x2", position["x"])) if box is Dictionary else position["x"]
	return {"left": int(max(0, left_edge + half_width)), "right": int(max(0, half_width - right_edge))}


# Velocity is the measured movement per tick when known: many projectiles move
# by setting their position directly each tick and keep a physics velocity of 0.
static func objects(game, me, motion: Dictionary = {}) -> Array:
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
			"type": object_type(obj),
			"kind": "projectile" if PROJECTILE_BASE in Util.script_chain(obj) else "object",
			"owner": owner,
			"position": Util.xy(Util.call_or(obj, "get_pos", [], Vector2.ZERO)),
			"velocity": Util.xy(Util.call_or(obj, "get_vel", [], Vector2.ZERO)),
		}
		var moved = motion.get(obj.get_instance_id())
		if moved != null and (moved["x"] != 0 or moved["y"] != 0):
			entry["velocity"] = moved
		if Util.valid(state):
			entry["state"] = str(Util.prop(state, "state_name", state.name))
		result.append(entry)
	result.sort_custom(ObjectSorter.new(), "less")
	return result


# stage_width is a half-width: the floor runs from -stage_width to +stage_width.
static func stage(game) -> Dictionary:
	var half_width = Util.as_int(Util.prop(game, "stage_width", 0))
	return {
		"left_wall": -half_width,
		"right_wall": half_width,
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
	for who in [["You are", me], ["The opponent is", opp]]:
		var walls = who[1].get("wall_distance", {})
		for side in walls:
			if walls[side] <= CORNER_DISTANCE:
				lines.append("%s %s the %s wall (%d away)." % [who[0], "against" if walls[side] <= 5 else "near", side, walls[side]])
	if (obs["spacing"]["opponent_is"] == "right" and me["facing"] == "left") or (obs["spacing"]["opponent_is"] == "left" and me["facing"] == "right"):
		lines.append("You are facing %s, away from the opponent; aim pads and reverse still count from the opponent's side." % me["facing"])
	if me["hitlag"] > 0:
		lines.append("You are in hitlag for %d more ticks: a move you pick now starts after that." % me["hitlag"])
	if opp["busy"]:
		lines.append(("The opponent is being hit (%s): no new move for them this turn, only DI or a burst." if opp["state"].get("hurt", false)
			else "The opponent is mid-move (%s) and cannot start a new move this turn.") % opp["state"]["name"])
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
