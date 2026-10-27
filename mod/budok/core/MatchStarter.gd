extends Reference

# Starts a local singleplayer match the same way the character select screen
# does (main._on_match_ready(match_data)). main.setup_game() frees any game in
# progress, so this works from the menu or mid-match.

const Util = preload("res://budok/core/Util.gd")
const SETTING_KEYS := ["stage_width", "game_length", "di_enabled", "turbo_mode", "infinite_resources",
	"one_hit_ko", "burst_enabled", "always_perfect_parry", "char_distance", "frame_by_frame"]
const DEFAULT_STAGE_WIDTH := 1100


# Coroutine. options: {p1, p2, controllers?, starting_hp?, settings?}
static func start(runtime, options: Dictionary) -> Dictionary:
	yield(runtime.get_tree(), "idle_frame")
	var entries = {}
	for slot in ["p1", "p2"]:
		var query = str(options.get(slot, ""))
		var entry = runtime.roster.resolve(query) if query != "" else null
		if entry == null:
			return {"ok": false, "error": "unknown character '%s' for %s; call list_characters" % [query, slot]}
		var loaded = runtime.roster.ensure_loaded(entry)
		if not loaded["ok"]:
			return {"ok": false, "error": "%s: %s" % [entry["display_name"], loaded["error"]]}
		entries[slot] = entry
	var main = runtime.get_tree().root.get_node_or_null("Main")
	if main == null or not main.has_method("_on_match_ready"):
		return {"ok": false, "error": "the game's main scene is not ready yet; try again from the main menu"}
	var controllers = runtime.matches.controllers.duplicate()
	var requested = options.get("controllers", {})
	if requested is Dictionary:
		for slot in requested:
			if slot in ["p1", "p2"]:
				controllers[slot] = str(requested[slot])
	var data = {
		"singleplayer": true,
		"selected_characters": {1: {"name": entries["p1"]["name"]}, 2: {"name": entries["p2"]["name"]}},
		"selected_styles": {1: null, 2: null},
		"seed": randi(),
		# game.start_game() reads stage_width unconditionally.
		"stage_width": DEFAULT_STAGE_WIDTH,
		"p2_dummy": false,
		"user_data": {
			"p1": "%s (%s)" % [controllers["p1"], entries["p1"]["display_name"]],
			"p2": "%s (%s)" % [controllers["p2"], entries["p2"]["display_name"]],
		},
	}
	var settings = options.get("settings", {})
	if settings is Dictionary:
		for key in settings:
			if key in SETTING_KEYS:
				data[key] = settings[key]
	var starting_hp = Util.as_int(options.get("starting_hp", 0))
	if starting_hp > 0:
		data["budok_starting_hp"] = starting_hp
		if not data.has("game_length"):
			data["game_length"] = starting_hp * 3
	runtime.matches.set_next_match_controllers(controllers)
	runtime.matches.prepare_new_match()
	main._on_match_ready(data)
	var deadline = Util.now_ms() + 15000
	while Util.now_ms() < deadline:
		yield(runtime.get_tree().create_timer(0.2), "timeout")
		if runtime.matches.status()["in_match"]:
			return {"ok": true, "characters": {"p1": entries["p1"]["display_name"], "p2": entries["p2"]["display_name"]},
				"controllers": runtime.matches.controllers.duplicate()}
	return {"ok": false, "error": "the match did not start within 15 s"}
