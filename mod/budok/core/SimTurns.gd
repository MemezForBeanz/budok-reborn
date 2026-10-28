extends Reference

# Turn rules for preview games, which have no move panels: which moves a
# fighter may pick (a port of ActionButtons.update_buttons, the panel's own
# legality rules), what happens when a decision point is reached (the turn
# logic of Game._physics_process, which does not run in previews) and a short
# list of concrete inputs worth comparing for each move. Used by the decision
# player to play several turns ahead on the real engine.

const Util = preload("res://budok/core/Util.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const ACTION_TYPES := ["Movement", "Attack", "Special", "Super", "Defense", "Hurt"]
const BUSY_HURT := 1  # CharacterState.BusyInterrupt.Hurt
const MIRRORED := {"E": "W", "W": "E", "NE": "NW", "NW": "NE", "SE": "SW", "SW": "SE"}
# Aims tried for moves with a free aim pad: degrees above the forward line.
const AIM_ANGLES := [["fwd", 0], ["up-fwd", 45], ["up", 90], ["down-fwd", -45], ["back", 180]]
const MAX_CHOICES := 3


# Names of the moves `fighter` may pick at this decision point, Continue first.
static func legal(fighter) -> Array:
	var out = ["Continue"]
	var state = Util.prop(Util.prop(fighter, "state_machine", null), "state", null)
	var cancels = Util.prop(fighter, "action_cancels", {})
	if not Util.valid(state) or not (cancels is Dictionary):
		return out
	var busy = bool(Util.prop(fighter, "busy_interrupt", false))
	var hit_cancellable = bool(Util.prop(fighter, "state_hit_cancellable", false))
	var turbo = bool(Util.prop(fighter, "turbo_mode", false))
	var opponent_state = Util.call_or(Util.prop(fighter, "opponent", null), "current_state")
	var into = []
	if busy:
		into = _names(Util.prop(state, "busy_interrupt_into", []))
	else:
		into = _names(Util.prop(state, "hit_cancel_into" if hit_cancellable else "interrupt_into", []))
		if turbo and str(Util.prop(opponent_state, "state_name", "")) != "Grabbed":
			into.append("Grounded" if bool(Util.call_or(fighter, "is_grounded", [], true)) else "Aerial")
		if (bool(Util.prop(fighter, "feinting", false)) and bool(Util.call_or(fighter, "should_free_cancel_allow_grounded_and_aerial_states", [], false))
				and Util.as_int(Util.prop(opponent_state, "busy_interrupt_type", 0)) != BUSY_HURT):
			into += ["Grounded", "Aerial"]
	var everything = bool(Util.prop(fighter, "extremely_turbo_mode", false)) and not busy
	for category in cancels.keys() if everything else into:
		for candidate in cancels.get(category, []):
			if not Util.valid(candidate) or not bool(Util.prop(candidate, "show_in_menu", true)):
				continue
			var name = str(candidate.name)
			if name in out or str(Util.prop(candidate, "state_name", name)) != name:
				continue
			if _usable(candidate) and (everything or _cancel_allowed(fighter, state, candidate, turbo)):
				out.append(name)
	return out


static func _names(list) -> Array:
	var out = []
	for item in list if list is Array else []:
		out.append(str(item))
	return out


static func _usable(candidate) -> bool:
	if candidate.has_method("is_usable_with_grounded_check"):
		return bool(candidate.is_usable_with_grounded_check(false, false))
	return not candidate.has_method("is_usable") or bool(candidate.is_usable())


# The checks update_buttons makes for one cancel option.
static func _cancel_allowed(fighter, state, candidate, turbo: bool) -> bool:
	if candidate.has_method("allowed_in_stance") and not candidate.allowed_in_stance():
		return false
	var name = str(candidate.name)
	var hit_cancellable = bool(Util.prop(fighter, "state_hit_cancellable", false))
	var interruptable = bool(Util.prop(fighter, "state_interruptable", false))
	if name == str(Util.prop(state, "state_name", "")) and not turbo:
		if hit_cancellable and not bool(Util.prop(state, "self_hit_cancellable", false)):
			return false
		if not hit_cancellable and not bool(Util.prop(state, "self_interruptable", false)):
			return false
	var hit_exceptions = _names(Util.prop(state, "hit_cancel_exceptions", []))
	var interrupt_exceptions = _names(Util.prop(state, "interrupt_exceptions", []))
	if hit_cancellable and name in hit_exceptions:
		return false
	if interruptable and name in interrupt_exceptions:
		return false
	var interrupt_from = _names(Util.prop(candidate, "interrupt_from", []))
	for category in hit_exceptions if hit_cancellable else []:
		if category in interrupt_from:
			return false
	for category in interrupt_exceptions if interruptable else []:
		if category in interrupt_from:
			return false
	return true


static func at_decision(sim) -> bool:
	return bool(Util.prop(sim.p1, "state_interruptable", false)) or bool(Util.prop(sim.p2, "state_interruptable", false))


# What the live game does when a player becomes actionable: the other player
# gets a turn too, "busy" when they are mid-move or being hit. Returns which
# slots are busy (they may only continue, DI or burst).
static func open_decision(sim) -> Dictionary:
	if bool(Util.prop(sim.p1, "state_interruptable", false)):
		_give_turn(sim, sim.p2)
	elif bool(Util.prop(sim.p2, "state_interruptable", false)):
		_give_turn(sim, sim.p1)
	return {"p1": bool(Util.prop(sim.p1, "busy_interrupt", false)), "p2": bool(Util.prop(sim.p2, "busy_interrupt", false))}


static func _give_turn(sim, fighter) -> void:
	var state = Util.call_or(fighter, "current_state")
	var free = (bool(Util.prop(state, "interruptible_on_opponent_turn", false)) or bool(Util.prop(fighter, "feinting", false))
		or bool(Util.call_or(sim, "negative_on_hit", [fighter], false)))
	fighter.busy_interrupt = not bool(Util.prop(fighter, "state_interruptable", false)) and not free
	if not fighter.busy_interrupt and Util.valid(state) and state.has_method("on_interrupt"):
		state.on_interrupt()
	fighter.state_interruptable = true


static func is_hurt(fighter) -> bool:
	var state = Util.call_or(fighter, "current_state")
	return bool(Util.prop(state, "is_hurt_state", false)) or Util.as_int(Util.prop(state, "busy_interrupt_type", 0)) == BUSY_HURT


# Inputs worth comparing for one move: [{"label", "input"}], where input is
# what submit_action takes as data (null = the move's default) and label is ""
# for the default. forward is the side the opponent is on (+1 = right);
# spec_facing is the facing the spec's defaults were read with.
static func variants(spec: Dictionary, forward: int, spec_facing: int) -> Array:
	var flipped = forward != spec_facing
	match spec.get("kind", "none"):
		"xy":
			if bool(spec.get("limit_angle", false)) or not (spec.get("default") is Dictionary):
				return [{"label": "", "input": _mirror_xy(spec.get("default"), flipped)}]
			var aims = []
			for aim in AIM_ANGLES:
				var radians = deg2rad(aim[1])
				aims.append({"label": aim[0], "input": {"x": int(round(cos(radians) * PayloadSpec.XY_RANGE)) * forward,
					"y": -int(round(sin(radians) * PayloadSpec.XY_RANGE))}})
			return aims
		"direction8":
			var directions = []
			for name in spec.get("allowed", []):
				if name != "Neutral" or spec["allowed"].size() == 1:
					var screen = MIRRORED.get(name, name) if flipped else name
					directions.append({"label": relative_direction(screen, forward), "input": screen})
			return directions if not directions.empty() else [{"label": "", "input": null}]
		"int_field":
			var values = []
			for value in [spec["min"], int((spec["min"] + spec["max"]) / 2), spec["max"]]:
				if not (value in values):
					values.append(value)
			var numbers = []
			for value in values:
				numbers.append({"label": str(value), "input": value})
			return numbers
		"option":
			var options = []
			for choice in spec.get("choices", []):
				if not (choice in spec.get("disabled", [])) and options.size() < MAX_CHOICES:
					options.append({"label": str(choice), "input": choice})
			return options if not options.empty() else [{"label": "", "input": null}]
		"choice":
			var choices = []
			for i in range(min(spec.get("values", []).size(), MAX_CHOICES)):
				choices.append({"label": str(spec["choices"][i]), "input": spec["choices"][i]})
			return choices if not choices.empty() else [{"label": "", "input": null}]
	return [{"label": "", "input": null}]


# The spec as seen with the fighter facing `forward`, so direction pickers
# accept the mirrored names (their allowed list was read facing spec_facing).
static func facing_spec(spec: Dictionary, forward: int, spec_facing: int) -> Dictionary:
	if forward == spec_facing or spec.get("kind", "") != "direction8":
		return spec
	var mirrored = spec.duplicate(true)
	var allowed = []
	for name in spec.get("allowed", []):
		allowed.append(MIRRORED.get(name, name))
	mirrored["allowed"] = allowed
	return mirrored


static func _mirror_xy(value, flipped: bool):
	if flipped and value is Dictionary and value.has("x"):
		var out = value.duplicate()
		out["x"] = -Util.as_int(value["x"])
		return out
	return value


# "fwd", "up-back", ... for a screen direction name.
static func relative_direction(screen: String, forward: int) -> String:
	var vec = PayloadSpec.DIRECTION_VECTORS.get(screen, [0, 0])
	var parts = []
	if vec[1] != 0:
		parts.append("up" if vec[1] < 0 else "down")
	if vec[0] != 0:
		parts.append("fwd" if vec[0] * forward > 0 else "back")
	return PoolStringArray(parts).join("-") if not parts.empty() else "neutral"


static func describe_state(fighter, action: String) -> String:
	if action == "Continue":
		return "Hold: keep doing what you are doing"
	var state = Util.prop(Util.prop(fighter, "state_machine", null), "states_map", {}).get(action)
	if not Util.valid(state):
		return action
	var title = str(Util.prop(state, "title", ""))
	return "%s (%s)" % [title if title != "" else action, Util.enum_name(ACTION_TYPES, Util.prop(state, "type", 0))]


static func snapshot(fighter) -> Dictionary:
	return {
		"hp": Util.as_int(Util.prop(fighter, "hp", 0)),
		"state": str(Util.prop(Util.call_or(fighter, "current_state"), "state_name", "?")),
	}
