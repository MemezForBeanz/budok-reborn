extends Reference

# Describes a move's data UI (the sliders / direction pickers under an action
# button) and converts bot input into exactly the value the game's own UI would
# produce via get_data(). Unknown or custom controls fall back to an "opaque"
# spec whose default is the UI's current value, so modded characters always
# work even when we cannot interpret their controls.
#
# Spec kinds: none, xy, direction8, int_field, bool, option, object, opaque.

const Util = preload("res://budok/core/Util.gd")
const DIRECTIONS := ["NW", "N", "NE", "W", "Neutral", "E", "SW", "S", "SE"]
const DIRECTION_VECTORS := {
	"NW": [-1, -1], "N": [0, -1], "NE": [1, -1],
	"W": [-1, 0], "Neutral": [0, 0], "E": [1, 0],
	"SW": [-1, 1], "S": [0, 1], "SE": [1, 1],
}
# Other spellings bots use for the eight directions (screen directions).
const DIRECTION_ALIASES := {
	"up": "N", "down": "S", "left": "W", "right": "E", "none": "Neutral", "center": "Neutral",
	"north": "N", "south": "S", "west": "W", "east": "E",
	"northwest": "NW", "northeast": "NE", "southwest": "SW", "southeast": "SE",
	"upleft": "NW", "upright": "NE", "downleft": "SW", "downright": "SE",
	"leftup": "NW", "rightup": "NE", "leftdown": "SW", "rightdown": "SE",
}
const XY_RANGE := 100
# How to fill each payload type; sent once per turn (payload_help), not per move.
const TYPE_HELP := {
	"xy": "{\"x\": int, \"y\": int}, each -100..100, screen space like the aim arrow on screen: +x right, -x left, -y up, +y down. It does not flip when you face left or reverse.",
	"direction8": "a direction name: N, NE, E, SE, S, SW, W, NW or Neutral (screen directions, N = up, W = left). Only the listed ones are allowed; the list is for facing the opponent and mirrors with reverse.",
	"int": "a whole number between min and max.",
	"bool": "true or false.",
	"option": "one of the choices, by name.",
	"object": "an object with one value per field, each filled by its own type.",
	"opaque": "a value shaped like the default (a custom control budok cannot interpret); omit data to use the default.",
}


static func describe_data_node(data_node) -> Dictionary:
	if not Util.valid(data_node) or not data_node.has_method("get_data"):
		return {"kind": "none"}
	var sample = data_node.get_data()
	var children = data_node.get_children()
	var spec = {}
	if children.size() == 1:
		spec = describe_control(children[0])
	elif children.size() > 1:
		var fields = {}
		for child in children:
			fields[str(child.name)] = describe_control(child)
		spec = {"kind": "object", "fields": fields}
	else:
		spec = {"kind": "none"}
	# A data node that overrides get_data() can return a different shape than
	# its children suggest; trust the game's sample in that case.
	if sample == null and spec["kind"] == "none":
		return spec
	if not _same_shape(sample, _default_of(spec)):
		return _opaque(sample, "custom data UI")
	return spec


static func describe_control(control) -> Dictionary:
	if not Util.valid(control) or not control.has_method("get_data"):
		return {"kind": "none"}
	var sample = control.get_data()
	if control.has_method("get_value_float") and Util.has_prop(control, "panel_radius"):
		var spec = {"kind": "xy", "range": XY_RANGE, "default": Util.json_safe(sample)}
		for hint in ["limit_angle", "limit_center_degrees", "limit_range_degrees"]:
			if Util.has_prop(control, hint):
				spec[hint] = Util.json_safe(control.get(hint))
		return spec
	if Util.has_prop(control, "NE") and Util.has_prop(control, "SW") and control.has_method("get_value"):
		var allowed = []
		for dir_name in DIRECTIONS:
			if bool(Util.prop(control, dir_name, true)):
				allowed.append(dir_name)
		return {"kind": "direction8", "allowed": allowed, "default": Util.json_safe(sample)}
	if sample is bool:
		return {"kind": "bool", "default": sample}
	if sample is Dictionary and sample.has("id") and sample.has("name") and control.has_method("get_item_count"):
		var choices = []
		var disabled = []
		for i in range(control.get_item_count()):
			choices.append(str(control.get_item_text(i)))
			if control.is_item_disabled(i):
				disabled.append(str(control.get_item_text(i)))
		return {"kind": "option", "choices": choices, "disabled": disabled, "default": Util.json_safe(sample)}
	if sample is Dictionary and sample.size() == 1 and Util.has_prop(control, "min_value") and Util.has_prop(control, "max_value"):
		var key = str(sample.keys()[0])
		return {
			"kind": "int_field",
			"key": key,
			"min": Util.as_int(control.min_value),
			"max": Util.as_int(control.max_value),
			"default": Util.json_safe(sample),
		}
	return _opaque(sample, "unrecognised control %s" % control.name)


# Public, compact form shown to bots.
static func public_spec(spec: Dictionary):
	match spec.get("kind", "none"):
		"none":
			return null
		"xy":
			var out = {"type": "xy", "default": spec["default"]}
			if bool(spec.get("limit_angle", false)):
				out["note"] = "aim limited to +/- %s deg around your forward side (the side you face after reverse); values outside are clamped" % [
					spec.get("limit_range_degrees", 0)]
			return out
		"direction8":
			return {"type": "direction8", "allowed": spec["allowed"], "default": spec["default"]}
		"int_field":
			return {"type": "int", "min": spec["min"], "max": spec["max"], "default": spec["default"][spec["key"]],
				"wraps_as": spec["key"]}
		"bool":
			return {"type": "bool", "default": spec["default"]}
		"option":
			return {"type": "option", "choices": spec["choices"], "disabled": spec["disabled"],
				"default": spec["default"].get("name")}
		"object":
			var fields = {}
			for field_name in spec["fields"]:
				fields[field_name] = public_spec(spec["fields"][field_name])
			return {"type": "object", "fields": fields}
		"opaque":
			return {"type": "opaque", "default": spec.get("default"), "note": spec.get("note", "")}
	return null


# TYPE_HELP for the payload types used by these public action entries.
static func help_for(actions: Array) -> Dictionary:
	var help = {}
	for action in actions:
		_collect_help(action.get("payload"), help)
	return help


static func _collect_help(payload, help: Dictionary) -> void:
	if not (payload is Dictionary) or not payload.has("type"):
		return
	help[payload["type"]] = TYPE_HELP.get(payload["type"], "")
	for field in payload.get("fields", {}).values():
		_collect_help(field, help)


# Returns {"ok": true, "value": v} or {"ok": false, "error": msg}. `control` is
# the live UI node for this spec (used to clamp values exactly like the game).
static func coerce(spec: Dictionary, value, control = null) -> Dictionary:
	var kind = spec.get("kind", "none")
	if kind == "none":
		return {"ok": true, "value": null}
	value = _unwrap(value)
	if value == null:
		if kind == "object":
			value = {}
		else:
			return {"ok": true, "value": _default_of(spec)}
	match kind:
		"xy":
			if value is Array and value.size() == 2:
				value = {"x": value[0], "y": value[1]}
			if not (value is Dictionary) or not value.has("x") or not value.has("y"):
				return _err("expected {\"x\": int, \"y\": int} in [-100, 100], got %s" % _shown(value))
			var x = clamp(Util.as_int(Util.numeric(value["x"])), -XY_RANGE, XY_RANGE)
			var y = clamp(Util.as_int(Util.numeric(value["y"])), -XY_RANGE, XY_RANGE)
			if Util.valid(control) and control.has_method("set_value_float") and Util.has_prop(control, "panel_radius"):
				var radius = float(control.panel_radius)
				control.set_value_float(Vector2(x, y) / float(XY_RANGE) * radius)
				return {"ok": true, "value": control.get_data()}
			return {"ok": true, "value": {"x": int(x), "y": int(y)}}
		"direction8":
			var dir_name = _direction_name(value)
			# The live picker knows the current allowed set (it mirrors with reverse).
			var allowed = spec["allowed"]
			if Util.valid(control) and control.has_method("get_value"):
				allowed = []
				for name in DIRECTIONS:
					if bool(Util.prop(control, name, false)):
						allowed.append(name)
			if dir_name == "":
				return _err("expected a direction name, one of %s, got %s" % [str(allowed), _shown(value)])
			if not (dir_name in allowed):
				return _err("direction %s is not allowed here; allowed: %s" % [dir_name, str(allowed)])
			if Util.valid(control) and control.has_method("get_value"):
				return {"ok": true, "value": control.get_value(dir_name)}
			var vec = DIRECTION_VECTORS[dir_name]
			return {"ok": true, "value": {"x": vec[0], "y": vec[1]}}
		"int_field":
			var raw = value.get(spec["key"]) if value is Dictionary else value
			if not (raw is int or raw is float or (raw is String and raw.is_valid_float())):
				return _err("expected an integer between %d and %d" % [spec["min"], spec["max"]])
			var clamped = int(clamp(Util.as_int(Util.numeric(raw)), spec["min"], spec["max"]))
			return {"ok": true, "value": {spec["key"]: clamped}}
		"bool":
			if value is bool:
				return {"ok": true, "value": value}
			if value is String and value.to_lower() in ["true", "false"]:
				return {"ok": true, "value": value.to_lower() == "true"}
			return _err("expected true or false")
		"option":
			var wanted = value.get("name", value.get("id")) if value is Dictionary else value
			for i in range(spec["choices"].size()):
				var choice = spec["choices"][i]
				if str(wanted).to_lower() == choice.to_lower() or ((wanted is int or wanted is float) and int(wanted) == i):
					if choice in spec["disabled"]:
						return _err("option %s is disabled right now" % choice)
					return {"ok": true, "value": {"id": i, "name": choice}}
			return _err("expected one of %s" % str(spec["choices"]))
		"object":
			if not (value is Dictionary):
				return _err("expected an object with fields %s" % str(spec["fields"].keys()))
			for key in value:
				if not spec["fields"].has(key):
					return _err("unknown field %s; fields are %s" % [key, str(spec["fields"].keys())])
			var out = {}
			for field_name in spec["fields"]:
				var child = control.get_node_or_null(field_name) if Util.valid(control) else null
				var field_result = coerce(spec["fields"][field_name], value.get(field_name), child)
				if not field_result["ok"]:
					return _err("%s: %s" % [field_name, field_result["error"]])
				out[field_name] = field_result["value"]
			return {"ok": true, "value": out}
		"opaque":
			var default_value = spec.get("default")
			if default_value != null and typeof(_ints(value)) != typeof(default_value):
				return _err("expected a value shaped like %s" % Util.json_str(default_value))
			return {"ok": true, "value": _ints(value)}
	return _err("unsupported payload kind %s" % kind)


static func _default_of(spec: Dictionary):
	match spec.get("kind", "none"):
		"none":
			return null
		"object":
			var out = {}
			for field_name in spec["fields"]:
				out[field_name] = _default_of(spec["fields"][field_name])
			return out
	return spec.get("default")


static func _opaque(sample, note: String) -> Dictionary:
	return {"kind": "opaque", "default": Util.json_safe(sample), "note": note}


# JSON numbers arrive as floats; the game's UI produces ints. Convert whole
# floats back so state scripts and fixed-point math see the usual types.
static func _ints(value):
	if value is float and value == floor(value):
		return int(value)
	if value is Dictionary:
		var out = {}
		for key in value:
			out[key] = _ints(value[key])
		return out
	if value is Array:
		var out_array = []
		for item in value:
			out_array.append(_ints(item))
		return out_array
	return value


static func _same_shape(a, b) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _same_shape(a[key], b[key]):
				return false
	return true


# Some clients send structured values as JSON text ("{\"x\": 10, ...}" or
# "\"NW\""), because the data argument has no fixed type.
static func _unwrap(value):
	if value is String:
		var text = value.strip_edges()
		if text.begins_with("{") or text.begins_with("[") or text.begins_with("\""):
			var parsed = Util.json_parse(text)
			if parsed["ok"]:
				return parsed["value"]
	return value


static func _shown(value) -> String:
	return Util.truncate(Util.json_str(value), 80)


static func _direction_name(value) -> String:
	if value is Dictionary:
		for key in ["direction", "dir", "value", "name"]:
			if value.has(key):
				return _direction_name(value[key])
	if value is String:
		var key = value.strip_edges().to_lower()
		for dir_name in DIRECTIONS:
			if dir_name.to_lower() == key:
				return dir_name
		for separator in ["-", "_", " "]:
			key = key.replace(separator, "")
		return DIRECTION_ALIASES.get(key, "")
	if value is Dictionary and value.has("x") and value.has("y"):
		var x = int(sign(Util.as_int(Util.numeric(value["x"]))))
		var y = int(sign(Util.as_int(Util.numeric(value["y"]))))
		for dir_name in DIRECTION_VECTORS:
			if DIRECTION_VECTORS[dir_name] == [x, y]:
				return dir_name
	return ""


static func _err(message: String) -> Dictionary:
	return {"ok": false, "error": message}
