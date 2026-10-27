extends Reference

# Legal actions and extras for one player, read from that player's native
# ActionButtons panel after the game activated it for the turn. The panel is
# the game's own legality authority (cancel rules, stances, meter, air
# options), so we mirror it instead of re-implementing those rules.
#
# Applying a decision goes through ActionButtons.on_action_submitted(), the
# same call the Lock In button makes. That keeps undo, replays and turn timers
# consistent and never touches the ghost preview, so a human opponent cannot
# see the bot's pick.

const Util = preload("res://budok/core/Util.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const ACTION_TYPES := ["Movement", "Attack", "Special", "Super", "Defense", "Hurt"]
const BASE_EXTRA_KEYS := ["DI", "reverse", "feint", "prediction"]


static func find_buttons(slot: String):
	var tree = Engine.get_main_loop()
	if tree == null:
		return null
	return tree.root.find_node("P1ActionButtons" if slot == "p1" else "P2ActionButtons", true, false)


static func is_awaiting(buttons, fighter) -> bool:
	return (
		Util.valid(buttons)
		and bool(Util.prop(buttons, "active", false))
		and Util.valid(fighter)
		and bool(Util.prop(fighter, "state_interruptable", false))
		and not bool(Util.prop(fighter, "game_over", false))
	)


# Returns {"actions": [...public entries], "specs": {action: spec}, "controls":
# {action: data_node}, "states": {action: state}, "extras": public extras,
# "extra_controls": {...}}
static func enumerate(buttons, fighter) -> Dictionary:
	var actions = []
	var specs = {}
	var controls = {}
	var states = {}
	for button in Util.prop(buttons, "buttons", []):
		if not Util.valid(button) or not button.visible or bool(Util.prop(button, "disabled", false)):
			continue
		var action = str(Util.prop(button, "action_name", ""))
		if action == "" or specs.has(action):
			continue
		var state = Util.prop(button, "state", null)
		var data_node = Util.prop(button, "data_node", null)
		var spec = PayloadSpec.describe_data_node(data_node)
		specs[action] = spec
		controls[action] = data_node
		states[action] = state
		var entry = {
			"action": action,
			"title": str(Util.prop(state, "title", action)) if Util.valid(state) else ("Hold" if action == "Continue" else action),
			"type": Util.enum_name(ACTION_TYPES, Util.prop(state, "type", 0)) if Util.valid(state) else "Movement",
			"reversible": bool(Util.prop(button, "reversible", false)),
			"feintable": _can_feint(buttons, state),
		}
		var payload = PayloadSpec.public_spec(spec)
		if payload != null:
			entry["payload"] = payload
		actions.append(entry)
	var extras = _extras(buttons, fighter)
	return {
		"actions": actions,
		"specs": specs,
		"controls": controls,
		"states": states,
		"extras": extras["public"],
		"extra_controls": extras["controls"],
	}


# Builds the exact (data, extra) pair to submit. `catalog` is enumerate()'s
# result for this turn. Returns {"ok", "data", "extra"} or {"ok": false, "error"}.
# touch_ui=false validates without moving any of that player's UI controls
# (used when simulating an assumed move for the opponent).
static func resolve(buttons, fighter, catalog: Dictionary, action: String, data, extra, touch_ui: bool = true) -> Dictionary:
	if not catalog["specs"].has(action):
		return {"ok": false, "error": "action '%s' is not legal right now; legal: %s" % [action, str(catalog["specs"].keys())]}
	var state = catalog["states"][action]
	if Util.valid(state) and state.has_method("is_usable") and not state.is_usable():
		return {"ok": false, "error": "action '%s' is not usable right now (resources or requirements)" % action}
	var data_result = PayloadSpec.coerce(catalog["specs"][action], data, catalog["controls"][action] if touch_ui else null)
	if not data_result["ok"]:
		return {"ok": false, "error": "data: %s" % data_result["error"]}
	var fighter_extra = Util.prop(buttons, "fighter_extra", null)
	if touch_ui and Util.valid(fighter_extra) and fighter_extra.has_method("update_selected_move"):
		fighter_extra.update_selected_move(state)
	var extra_result = _resolve_extra(buttons, fighter, catalog, action, state, extra if extra is Dictionary else {}, touch_ui)
	if not extra_result["ok"]:
		return extra_result
	return {"ok": true, "data": data_result["value"], "extra": extra_result["value"]}


static func submit(buttons, action: String, data, extra: Dictionary) -> void:
	buttons.on_action_submitted(action, data, extra)


static func _resolve_extra(buttons, _fighter, catalog: Dictionary, action: String, state, requested: Dictionary, touch_ui: bool) -> Dictionary:
	# Passive resolution must not read the other player's in-progress UI
	# choices, so it starts from neutral extras instead of the panel's.
	var base = {"DI": {"x": 0, "y": 0}, "reverse": false, "feint": false, "prediction": -1}
	if touch_ui and buttons.has_method("get_extra"):
		base = buttons.get_extra()
	var extra = base.duplicate(true) if base is Dictionary else {}
	if not touch_ui:
		for key in catalog["extras"].get("character", {}):
			var default_value = catalog["extras"]["character"][key]["default"]
			extra[key] = false if default_value is bool else default_value
	var public = catalog["extras"]
	var char_controls = catalog["extra_controls"].get("character", {})
	# Feint defaults to the panel's auto free-cancel setting; only keep it when
	# this move can actually feint.
	extra["feint"] = bool(extra.get("feint", false)) and _can_feint(buttons, state)
	extra["reverse"] = false
	for key in requested:
		var value = requested[key]
		var lower = str(key).to_lower()
		if lower == "di":
			if value == null:
				continue
			if public.get("di") == null:
				return {"ok": false, "error": "DI is not available right now"}
			var di = PayloadSpec.coerce({"kind": "xy"}, value, catalog["extra_controls"].get("di") if touch_ui else null)
			if not di["ok"]:
				return {"ok": false, "error": "extra.di: %s" % di["error"]}
			extra["DI"] = di["value"]
		elif lower == "reverse":
			if bool(value) and not bool(Util.prop(_button_for(buttons, action), "reversible", false)):
				return {"ok": false, "error": "'%s' cannot be reversed" % action}
			extra["reverse"] = bool(value)
		elif lower == "feint":
			if bool(value) and not _can_feint(buttons, state):
				return {"ok": false, "error": "'%s' cannot be feinted right now (needs a free cancel or a full meter bar)" % action}
			extra["feint"] = bool(value)
		elif lower == "prediction":
			continue
		elif public.get("character", {}).has(key):
			var spec = public["character"][key]
			if spec["type"] == "bool":
				if bool(value):
					var control = char_controls.get(key)
					var usable = spec["available"]
					if touch_ui:
						usable = _toggle_usable(control, Util.prop(buttons, "fighter_extra", null))
					if not usable:
						return {"ok": false, "error": "extra '%s' is not available with '%s' right now" % [key, action]}
				extra[key] = bool(value)
			else:
				var coerced = PayloadSpec.coerce(_extra_value_spec(spec), value)
				if not coerced["ok"]:
					return {"ok": false, "error": "extra.%s: %s" % [key, coerced["error"]]}
				extra[key] = coerced["value"]
		else:
			return {"ok": false, "error": "unknown extra '%s'; available: di, reverse, feint%s" % [
				key, "" if public.get("character", {}).empty() else ", " + PoolStringArray(public["character"].keys()).join(", ")]}
	return {"ok": true, "value": extra}


static func _extras(buttons, fighter) -> Dictionary:
	var public = {"di": null, "character": {}}
	var controls = {"di": null, "character": {}}
	var di_node = buttons.get_node_or_null("%DI")
	if Util.valid(di_node) and Util.visible_within(di_node, buttons, false) and bool(Util.prop(fighter, "di_enabled", true)):
		public["di"] = {"type": "xy", "x": [-100, 100], "y": [-100, 100], "default": Util.json_safe(di_node.get_data()),
			"note": "directional influence while being hit; screen space, +x right, +y down"}
		controls["di"] = di_node
	var fighter_extra = Util.prop(buttons, "fighter_extra", null)
	if not Util.valid(fighter_extra) or not fighter_extra.has_method("get_extra"):
		return {"public": public, "controls": controls}
	var sample = fighter_extra.get_extra()
	if not (sample is Dictionary):
		return {"public": public, "controls": controls}
	var mapping = _map_toggles(fighter_extra, sample)
	for key in sample:
		if key in BASE_EXTRA_KEYS:
			continue
		var value = sample[key]
		if value is bool:
			var control = mapping.get(key)
			var available = _toggle_usable(control, fighter_extra)
			public["character"][key] = {"type": "bool", "available": available, "default": value}
			controls["character"][key] = control
		else:
			public["character"][key] = {"type": "value", "default": Util.json_safe(value),
				"note": "only used together with its related toggle"}
	return {"public": public, "controls": controls}


# Character extra panels (e.g. Ninja's bomb / momentum buttons) are arbitrary
# scenes. Find which toggle drives which get_extra() key by flipping each
# toggle silently and diffing the result, then restoring it.
static func _map_toggles(fighter_extra, sample: Dictionary) -> Dictionary:
	var mapping = {}
	var before = Util.json_str(sample, true)
	for button in _toggles(fighter_extra):
		var original = bool(button.pressed)
		button.set_pressed_no_signal(not original)
		var after = fighter_extra.get_extra()
		button.set_pressed_no_signal(original)
		if not (after is Dictionary) or Util.json_str(after, true) == before:
			continue
		for key in after:
			if sample.has(key) and Util.json_str(after[key]) != Util.json_str(sample[key]) and not mapping.has(key):
				mapping[key] = button
	return mapping


static func _toggles(root) -> Array:
	var found = []
	var queue = [root]
	while not queue.empty():
		var node = queue.pop_front()
		for child in node.get_children():
			if child is BaseButton and child.toggle_mode:
				found.append(child)
			queue.append(child)
	return found


# Visibility is checked inside the extras panel only, so options stay usable
# while budok hides a bot's whole move panel from the human.
static func _toggle_usable(control, fighter_extra) -> bool:
	return Util.valid(control) and Util.visible_within(control, fighter_extra) and not bool(Util.prop(control, "disabled", false))


static func _can_feint(buttons, state) -> bool:
	if not Util.valid(state) or not state.has_method("can_feint"):
		return false
	var fighter_extra = Util.prop(buttons, "fighter_extra", null)
	return bool(state.can_feint()) and bool(Util.prop(fighter_extra, "can_feint", true))


static func _button_for(buttons, action: String):
	for button in Util.prop(buttons, "buttons", []):
		if Util.valid(button) and str(Util.prop(button, "action_name", "")) == action:
			return button
	return null


static func _extra_value_spec(spec: Dictionary) -> Dictionary:
	var default_value = spec.get("default")
	if default_value is Dictionary and default_value.has("x") and default_value.has("y"):
		return {"kind": "xy"}
	return {"kind": "opaque", "default": default_value}
