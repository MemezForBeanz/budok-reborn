extends Reference

# Shipped defaults (res://budok/config/default_config.json) deep-merged with the
# player's own settings (user://budok/config.json). Only the user file is ever
# written; it is the one place API keys and the MCP token live.

const Util = preload("res://budok/core/Util.gd")
const DEFAULTS_PATH := "res://budok/config/default_config.json"
const USER_PATH := "user://budok/config.json"
const SECRET_KEYS := ["api_key", "auth_token"]

var data := {}
var _user := {}


func load_config() -> void:
	var defaults = Util.read_json(DEFAULTS_PATH)
	if not (defaults is Dictionary):
		push_error("budok: missing or invalid %s" % DEFAULTS_PATH)
		defaults = {}
	var user = Util.read_json(USER_PATH)
	_user = user if user is Dictionary else {}
	data = Util.deep_merge(defaults, _user)
	if str(get_value("mcp.auth_token", "")) == "":
		set_value("mcp.auth_token", Util.random_hex(16))
		save()


func get_value(path: String, default_value = null):
	return Util.dig(data, path, default_value)


# Writes go to both the merged view and the user overlay so that save() only
# persists what the player actually changed.
func set_value(path: String, value) -> void:
	Util.plant(data, path, value)
	Util.plant(_user, path, value)


func save() -> bool:
	return Util.write_json(USER_PATH, _user)


func api_key(provider: String) -> String:
	var provider_cfg = get_value("ai.providers." + provider, {})
	if not (provider_cfg is Dictionary):
		return ""
	var key = str(provider_cfg.get("api_key", ""))
	if key != "":
		return key
	var env_name = str(provider_cfg.get("api_key_env", ""))
	return OS.get_environment(env_name) if env_name != "" else ""


func redacted() -> Dictionary:
	return _redact(data)


func _redact(value):
	if value is Dictionary:
		var out = {}
		for key in value:
			if key in SECRET_KEYS:
				out[key] = "(set)" if str(value[key]) != "" else ""
			else:
				out[key] = _redact(value[key])
		return out
	return value
