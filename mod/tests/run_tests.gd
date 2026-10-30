extends SceneTree

# Headless unit tests for budok's pure logic (no game needed):
#   godot --no-window --path mod -s res://tests/run_tests.gd
# (use the Godot 3.5.x editor/headless binary; exit code is the failure count)

const Util = preload("res://budok/core/Util.gd")
const PayloadSpec = preload("res://budok/core/PayloadSpec.gd")
const SchemaStore = preload("res://budok/core/SchemaStore.gd")
const Introspector = preload("res://budok/core/Introspector.gd")
const HttpServer = preload("res://budok/mcp/HttpServer.gd")
const Tools = preload("res://budok/mcp/Tools.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const Memory = preload("res://budok/core/Memory.gd")
const NotesAgent = preload("res://budok/core/NotesAgent.gd")
const LlmClient = preload("res://budok/ai/LlmClient.gd")
const SimTurns = preload("res://budok/core/SimTurns.gd")
const DecisionCore = preload("res://budok/ai/DecisionCore.gd")
const DecisionPilot = preload("res://budok/ai/DecisionPilot.gd")
const Config = preload("res://budok/core/Config.gd")
# Preloaded so a parse error in the settings UI fails the tests.
const SettingsView = preload("res://budok/ui/SettingsView.gd")
const SpeechBubbles = preload("res://budok/ui/SpeechBubbles.gd")
const Lookahead = preload("res://budok/core/Lookahead.gd")
const ComboSolver = preload("res://budok/core/ComboSolver.gd")
const Evidence = preload("res://budok/ai/Evidence.gd")
const LookAheadReport = preload("res://budok/ai/LookAheadReport.gd")
const Simulator = preload("res://budok/core/Simulator.gd")
const AutoPilot = preload("res://budok/ai/AutoPilot.gd")
const CliAgent = preload("res://budok/core/CliAgent.gd")

var failures := 0
var checks := 0


func _init() -> void:
	_test_util()
	_test_payload_spec()
	_test_schema_validation()
	_test_bundled_schemas()
	_test_introspector()
	_test_http_parsing()
	_test_tool_catalogue()
	_test_knowledge()
	_test_memory()
	_test_notes_agent()
	_test_decisions()
	_test_sim_turns()
	_test_combo_helpers()
	_test_previews()
	_test_chat_fallbacks()
	_test_cli_agents()
	_test_talk_and_playbook()
	print("%d checks, %d failures" % [checks, failures])
	quit(failures)


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + label)


# Godot 3 compares Dictionaries by reference; compare contents instead.
func same(a, b) -> bool:
	return Util.json_str(a, true) == Util.json_str(b, true)


func make(source: String, base: String = "Node"):
	var script = GDScript.new()
	script.source_code = "extends %s\n%s" % [base, source]
	script.reload()
	return script.new()


func _test_util() -> void:
	var merged = Util.deep_merge({"a": {"b": 1, "c": 2}, "d": 1}, {"a": {"b": 5}, "e": 3})
	check(merged["a"]["b"] == 5 and merged["a"]["c"] == 2 and merged["e"] == 3, "deep_merge keeps and overrides keys")
	var data = {}
	Util.plant(data, "x.y.z", 4)
	check(Util.dig(data, "x.y.z") == 4 and Util.dig(data, "x.q", "d") == "d", "set_path / get_path")
	check(Util.strip_trailing_digits("Bullet12") == "Bullet" and Util.strip_trailing_digits("42") == "42", "strip_trailing_digits")
	check(same(Util.json_safe(Vector2(1.5, 2)), {"x": 1.5, "y": 2.0}), "json_safe Vector2")
	check(Util.as_int("3.6") == 4 and Util.as_int(2.0) == 2 and Util.as_int(null, 7) == 7, "as_int")
	# Godot prints NaN / infinity as bare nan / inf; replies must stay valid JSON.
	var printed = Util.json_str({"a": NAN, "b": [INF, -INF, 1.5], "c": "info: inf, nan"})
	check(JSON.parse(printed).error == OK and printed.find("null") != -1 and printed.find("info: inf, nan") != -1, "json_str nulls NaN and infinity: %s" % printed)
	check(Util.json_str({"info": "infinite"}) == JSON.print({"info": "infinite"}), "json_str leaves ordinary text alone")
	var root = Control.new()
	var middle = Control.new()
	var leaf = Control.new()
	root.add_child(middle)
	middle.add_child(leaf)
	root.visible = false
	check(Util.visible_within(leaf, root, false), "visible_within ignores hidden root when asked")
	check(not Util.visible_within(leaf, root, true), "visible_within respects hidden root")
	middle.visible = false
	check(not Util.visible_within(leaf, root, false), "visible_within sees hidden parent")
	root.free()


func _test_payload_spec() -> void:
	var check_button = make("func get_data():\n\treturn true\n")
	check_button.name = "Toggle"
	var count = make("var min_value = 0\nvar max_value = 3\nfunc get_data():\n\treturn {\"count\": 1}\n")
	count.name = "Spend"
	var data_node = make("func get_data():\n\tvar c = get_children()\n\tif c.size() == 1:\n\t\treturn c[0].get_data()\n\tvar d = {}\n\tfor x in c:\n\t\td[x.name] = x.get_data()\n\treturn d\n", "Control")
	data_node.add_child(count)
	var single = PayloadSpec.describe_data_node(data_node)
	check(single["kind"] == "int_field" and single["max"] == 3, "single CountOption child is an int field")
	var clamped = PayloadSpec.coerce(single, 9)
	check(clamped["ok"] and same(clamped["value"], {"count": 3}), "int field clamps and wraps")
	check(not PayloadSpec.coerce(single, "lots")["ok"], "int field rejects text")
	check(same(PayloadSpec.coerce(single, null)["value"], {"count": 1}), "missing data uses the UI default")
	data_node.add_child(check_button)
	var multi = PayloadSpec.describe_data_node(data_node)
	check(multi["kind"] == "object" and multi["fields"].has("Toggle"), "several children form an object")
	var obj = PayloadSpec.coerce(multi, {"Spend": 2})
	check(obj["ok"] and same(obj["value"], {"Spend": {"count": 2}, "Toggle": true}), "object fills defaults")
	check(not PayloadSpec.coerce(multi, {"Nope": 1})["ok"], "object rejects unknown fields")
	var custom = make("func get_data():\n\treturn \"homing\"\n", "Control")
	custom.add_child(make("func get_data():\n\treturn {\"x\": 1, \"y\": 0}\n"))
	var opaque = PayloadSpec.describe_data_node(custom)
	check(opaque["kind"] == "opaque" and opaque["default"] == "homing", "overridden get_data becomes opaque")
	check(not PayloadSpec.coerce(opaque, 5)["ok"] and PayloadSpec.coerce(opaque, "x")["ok"], "opaque keeps the JSON type")
	# SuperJump outside a combo: the aim pad is hidden and the move sends "homing".
	var jump = make("func get_data():\n\treturn \"homing\"\n", "Control")
	var arc = make("func get_data():\n\treturn {\"x\": 1, \"y\": 0}\n", "Control")
	arc.visible = false
	jump.add_child(arc)
	var fixed = PayloadSpec.describe_data_node(jump)
	var fixed_use = PayloadSpec.coerce(fixed, {"x": 5, "y": 5})
	check(fixed["kind"] == "fixed" and fixed_use["value"] == "homing" and fixed_use.has("note"), "hidden controls mean a fixed value")
	jump.free()
	# The parry's Block Height: two toggle buttons, value derived from them.
	var height = make("func get_data():\n\treturn {\"x\": 0, \"y\": 0 if get_node(\"High\").pressed else 1}\nfunc on_low(_on):\n\tget_node(\"High\").set_pressed_no_signal(false)\n\tget_node(\"Low\").set_pressed_no_signal(true)\n", "VBoxContainer")
	for label in ["High", "Low"]:
		var button = Button.new()
		button.name = label
		button.text = label
		button.toggle_mode = true
		height.add_child(button)
	height.get_node("High").pressed = true
	height.get_node("Low").connect("toggled", height, "on_low")
	var choice = PayloadSpec.describe_control(height)
	check(choice["kind"] == "choice" and choice["choices"] == ["High", "Low"] and choice["default_choice"] == "High", "button group becomes a choice")
	check(height.get_node("High").pressed and not height.get_node("Low").pressed, "probing leaves the buttons as they were")
	check(same(PayloadSpec.coerce(choice, "High")["value"], {"x": 0, "y": 0}), "choice value without touching the UI")
	var low = PayloadSpec.coerce(choice, "low", height)
	check(same(low["value"], {"x": 0, "y": 1}) and same(height.get_data(), {"x": 0, "y": 1}), "choice presses the button")
	check(PayloadSpec.public_spec(choice)["choices"] == ["High", "Low"], "choice public spec")
	height.free()
	var dir_spec = {"kind": "direction8", "allowed": ["N", "E", "Neutral"], "default": "Neutral"}
	check(same(PayloadSpec.coerce(dir_spec, "e")["value"], {"x": 1, "y": 0}), "direction names are case-insensitive")
	check(not PayloadSpec.coerce(dir_spec, "SW")["ok"], "disallowed direction rejected")
	check(same(PayloadSpec.coerce(dir_spec, {"x": 0, "y": -5})["value"], {"x": 0, "y": -1}), "direction from vector")
	var xy = PayloadSpec.coerce({"kind": "xy", "default": {"x": 0, "y": 0}}, {"x": 250.0, "y": -3.4})
	check(xy["ok"] and same(xy["value"], {"x": 100, "y": -3}), "xy clamps and rounds")
	# Clients without a fixed type for data send JSON text or wrappers.
	var west = {"kind": "direction8", "allowed": ["NW", "W"], "default": "Neutral"}
	check(same(PayloadSpec.coerce(west, "\"NW\"")["value"], {"x": -1, "y": -1}), "direction as JSON text")
	check(same(PayloadSpec.coerce(west, {"direction": "nw"})["value"], {"x": -1, "y": -1}), "direction in a wrapper object")
	check(same(PayloadSpec.coerce(west, "up-left")["value"], {"x": -1, "y": -1}), "direction aliases")
	var wrong = PayloadSpec.coerce(west, "sideways")
	check(not wrong["ok"] and wrong["error"].find("sideways") != -1, "direction error shows what was sent")
	check(same(PayloadSpec.coerce({"kind": "xy", "default": {}}, "{\"x\": 10, \"y\": -20}")["value"], {"x": 10, "y": -20}), "xy as JSON text")
	check(same(PayloadSpec.coerce({"kind": "xy", "default": {}}, [30, 40])["value"], {"x": 30, "y": 40}), "xy as [x, y]")
	var help = PayloadSpec.help_for([{"action": "A", "payload": {"type": "object", "fields": {"Dir": {"type": "direction8"}}}}, {"action": "B"}])
	check(help.has("object") and help.has("direction8") and help.size() == 2, "payload help lists the types in use once")
	data_node.free()
	custom.free()


class FakeIntrospector:
	var data = {}

	func skeleton(_entry):
		return data


func _test_schema_validation() -> void:
	var fake = FakeIntrospector.new()
	fake.data = {"ok": true, "fingerprint": "abc", "resources": {"charge_level": 0},
		"moves": {"ChargeBlast": {"title": "Charge Blast"}, "Grab": {"title": "Grab"}}}
	var store = SchemaStore.new(fake)
	var result = store.validate({"moves": {"Charge Blast": {"category": "attack", "summary": "big hit", "startup": 3}}}, fake.data)
	check(result["ok"] and result["cleaned"]["moves"].has("ChargeBlast"), "button titles are remapped to state names")
	check(str(result["warnings"]).find("measured") != -1, "measured fields are ignored with a warning")
	var bad = store.validate({"moves": {"ChargBlast": {"category": "nuke"}}}, fake.data)
	check(not bad["ok"] and str(bad["errors"]).find("did you mean 'ChargeBlast'") != -1, "unknown move suggests a close name")
	var bad_enum = store.validate({"moves": {"Grab": {"category": "nuke"}}}, fake.data)
	check(not bad_enum["ok"], "invalid category rejected")
	var long_text = ""
	for _i in range(700):
		long_text += "a"
	check(not store.validate({"summary": {"archetype": long_text}}, fake.data)["ok"], "overlong text rejected")
	check(not store.validate({"resources": {"mana": {"meaning": "x"}}}, fake.data)["ok"], "unknown resource rejected")
	var cover = store.coverage({"moves": {"Grab": {"category": "grab"}}}, fake.data)
	check(cover["annotated"] == 1 and cover["missing"] == ["ChargeBlast"], "coverage counts missing moves")


func _test_bundled_schemas() -> void:
	var dir = Directory.new()
	check(dir.open("res://budok/schemas/vanilla") == OK, "bundled schema folder exists")
	dir.list_dir_begin(true, true)
	var name = dir.get_next()
	var count = 0
	while name != "":
		var schema = Util.read_json("res://budok/schemas/vanilla/" + name)
		check(schema is Dictionary and schema.get("format") == "budok.character.v1", "%s is a v1 schema" % name)
		if schema is Dictionary:
			var skeleton = {"ok": true, "moves": {}, "resources": {}}
			for move_name in schema.get("moves", {}):
				skeleton["moves"][move_name] = {"title": move_name}
			var result = SchemaStore.new(FakeIntrospector.new()).validate(schema, skeleton)
			check(result["ok"], "%s validates: %s" % [name, str(result["errors"]).substr(0, 300)])
		count += 1
		name = dir.get_next()
	check(count >= 5, "all vanilla characters have bundled schemas")


func _test_introspector() -> void:
	var state_source = "var interrupt_from_string = \"Grounded\"\nvar anim_length = 20\nvar data_ui_scene = null\nvar iasa_at = -2\nvar title = \"Big Punch\"\nvar type = 1\nvar show_in_menu = true\nvar selectable = true\n"
	var box_source = "var hitstun_ticks = 20\nvar start_tick = 5\nvar active_ticks = 3\nvar damage = 40\nvar x = 20\nvar y = -10\nvar width = 15\nvar height = 8\nvar hitbox_type = 0\nvar hit_height = 2\n"
	var fighter = make("var MAX_HEALTH = 1000\n")
	var machine = Node.new()
	machine.name = "StateMachine"
	fighter.add_child(machine)
	var state = make(state_source)
	state.name = "BigPunch"
	machine.add_child(state)
	var box = make(box_source)
	box.name = "Hitbox"
	state.add_child(box)
	# A super extending SuperMove: its own super_level counts on top of CharState's.
	var super_state = make(state_source + "var super_level_ = 0\nvar supers_used_ = -1\nvar super_level = 1\nvar supers_used = -1\n")
	super_state.name = "BigSuper"
	machine.add_child(super_state)
	var intro = Introspector.new()
	var info = intro._build(fighter, {"display_name": "Fake", "name": "F-1__Fake", "scene_path": "res://x/Fake.tscn"})
	var move = info["moves"].get("BigPunch", {})
	check(move.get("title") == "Big Punch" and move.get("type") == "Attack", "state title and type read")
	check(move.get("frames", {}).get("startup") == 5 and move["frames"]["active"] == 3, "startup/active from hitboxes")
	check(move["frames"]["recovery"] == 18 - 7, "recovery from iasa (negative iasa counts from the end)")
	check(move["frames"]["reach"] == 35 and move["hitboxes"][0]["height"] == "Low", "reach and hit height measured")
	check(info["fingerprint"].length() == 16, "fingerprint computed")
	check(info["moves"]["BigSuper"]["meter_bars"] == 1 and info["moves"]["BigSuper"]["requires_bars"] == 1, "SuperMove meter cost measured")
	check(move["frames"]["damage"] == 40 and move["frames"]["hits"] == 1 and not move["frames"].has("max_damage"), "single hit damage")
	fighter.free()
	# Same group = one hit for the whole move (QuickSlash's 12 boxes); other groups add hits.
	var groups = [{"start": 7, "damage": 120, "combo": 40}]
	var one = Introspector._damage_summary(groups, [])
	check(one["damage"] == 120 and one["hits"] == 1 and one["damage_in_combo"] == 40, "grouped hitboxes hit once")
	groups.append({"start": 12, "damage": 60, "combo": 60})
	var two = Introspector._damage_summary(groups, [{"looping": true}])
	check(two["hits"] == 2 and two["damage"] == 120 and two["max_damage"] == 180 and two["looping"], "separate groups add up")
	var text = Introspector.frames_text({"frames": {"startup": 7, "active": 1, "recovery": 12, "damage": 120, "hits": 1, "damage_in_combo": 40, "reach": 60}})
	check(text == "startup 7, active 1, recovery 12, 120 dmg (40 in a combo), reach 60", "frames text: %s" % text)
	check(Introspector.frames_text({"damage": {"damage": 200, "hits": 1}}) == "timing set by its code (simulate it), 200 dmg", "code-timed moves still show damage")


func _test_memory() -> void:
	var memory = Memory.new()
	for name in ["Zed", "Yan"]:
		memory.clear_for(name)
	var saved = memory.remember("Zed", "", "Zed's teleport leaves him open for 10 ticks", ["punish"], "mcp:test")
	check(saved["ok"] and saved["subject"] == "character:Zed", "memory saved under the character")
	memory.remember("Zed", "Yan", "As Zed, zone Yan out with knives", [], "ai:model")
	memory.remember("Yan", "", "Yan blocks low a lot", [], "mcp:other")
	check(not memory.remember("Zed", "", "", [], "x")["ok"], "empty memory refused")
	var long_text = ""
	for _i in range(61):
		long_text += "0123456789"
	check(not memory.remember("Zed", "", long_text, [], "x")["ok"], "overlong memory refused")
	var both = memory.recall(["Zed", "Yan"])
	check(both.size() >= 3, "recall covers both characters and their matchup")
	check(memory.recall(["Zed"], "knives").size() == 1, "recall finds the matchup of one character, filtered by text")
	check(memory.recall(["Zed", "Yan"], "", 20, "mcp:test").size() == 1, "recall can be limited to one author")
	check(memory.count_for("Zed") == 2, "count includes matchups")
	check(memory.forget(saved["id"])["ok"] and memory.count_for("Zed") == 1, "forget removes one memory")
	memory.max_per_subject = 2
	for i in range(3):
		memory.remember("Yan", "", "note %d" % i, [], "x")
	check(memory.recall(["Yan"], "note").size() == 2, "oldest memories drop past the limit")
	check(memory.clear_for("Yan") >= 2 and memory.count_for("Yan") == 0, "clear deletes a character's memories")
	memory.clear_for("Zed")


func _test_notes_agent() -> void:
	check(NotesAgent.resolve("/nonexistent/claude") == "", "a missing agent command is reported as not found")
	check(NotesAgent.resolve(OS.get_executable_path()) == OS.get_executable_path(), "a full agent path is used as is")
	var tools = Tools.new(null)
	var allowed = true
	for tool_name in NotesAgent.TOOLS:
		allowed = allowed and tools.has_method("_t_" + tool_name) and not (tool_name in ["start_match", "submit_action", "claim_slot", "update_setting", "forget"])
	check(allowed, "the notes agent may only use existing notes tools")
	check(Prompts.notes_worker_prompt(true).find("you are done: stop") != -1, "the headless notes agent stops when the queue is empty")
	check(Prompts.notes_worker_prompt().find("wait_s") != -1, "a notes chat waits for the next character")


func _test_decisions() -> void:
	var questions = {"you": {"instructions": "pick", "options": {"Slash": "a", "Grab": "b", "Continue": "c"}}}
	var gateway = LlmClient.parse_decision({"answers": {"you": {"type": "choice", "choice": "Grab", "probabilities": {"Slash": 0.2, "Grab": 0.6, "Continue": 0.2}}},
		"usage": {"inputTokens": 120, "outputTokens": 3}}, questions)
	check(gateway["ok"] and gateway["answers"]["you"]["choice"] == "Grab" and abs(gateway["answers"]["you"]["probabilities"]["Grab"] - 0.6) < 0.001,
		"gateway decision answers are read")
	check(gateway["usage"]["input_tokens"] == 120, "gateway usage is read")
	var bare = LlmClient.parse_decision({"answers": {"you": {"type": "choice", "choice": "Slash"}}, "usage": {"input_tokens": 9}}, questions)
	check(bare["ok"] and bare["answers"]["you"]["probabilities"]["Slash"] == 1.0 and bare["answers"]["you"]["probabilities"]["Grab"] == 0.0,
		"a choice without probabilities counts as certain")
	var skewed = LlmClient.parse_decision({"answers": {"you": {"type": "choice", "choice": "Slash", "probabilities": {"Slash": 2, "Grab": 2, "Jump": 5}}}}, questions)
	check(skewed["ok"] and abs(skewed["answers"]["you"]["probabilities"]["Slash"] - 0.5) < 0.001, "probabilities are renormalised over the asked options")
	check(not LlmClient.parse_decision({"answers": {"you": {"type": "refusal"}}}, questions)["ok"], "a refusal is an error")
	check(not LlmClient.parse_decision({"answers": {"you": {"type": "choice", "choice": "Fly"}}}, questions)["ok"], "an unknown option is an error")
	check(not LlmClient.parse_decision({"answers": {}}, questions)["ok"], "a missing answer is an error")
	var options = []
	for label in ["A", "B", "C", "D"]:
		options.append({"label": label})
	var ranked = DecisionCore._top(options, {"A": 0.1, "B": 0.5, "C": 0.3, "D": 0.1}, 2)
	check(ranked.size() == 2 and ranked[0]["label"] == "B" and ranked[1]["label"] == "C", "candidates are the likeliest options")
	check(DecisionCore.depth_for_rate(10, 4, 0, 30000, 1) == 10, "no rate limit keeps the depth")
	check(DecisionCore.depth_for_rate(10, 4, 5, 30000, 1) == 1, "5 requests a minute leave no calls for deep lines")
	check(DecisionCore.depth_for_rate(10, 4, 60, 30000, 1) == 8 and DecisionCore.depth_for_rate(10, 4, 60, 30000, 2) == 4, "deep lines share what the limit allows")
	check(DecisionCore.depth_for_rate(10, 4, 60, 30000, 1, 0) == 8 and DecisionCore.depth_for_rate(10, 4, 20, 30000, 1, 0) == 3,
		"look-aheads without their own questions keep more for lines")
	_test_sweep_analysis()
	check(DecisionCore._problem({"enabled": true, "provider": "typesafe", "key": "", "model": "jev-latest"}) == "no API key"
		and DecisionCore._problem({"enabled": true, "provider": "vercel", "key": "k", "model": ""}) == "no model"
		and DecisionCore._problem({"enabled": true, "provider": "typesafe", "key": "k", "model": ""}) == ""
		and DecisionCore._problem({"enabled": false, "provider": "typesafe", "key": "k", "model": ""}) == "turned off", "unusable decision endpoints are explained")
	var state = {"call_times": [], "blocked_until": 0}
	for i in range(4):
		state["call_times"].append(Util.now_ms() - 1000 * (4 - i))
	check(DecisionCore._rate_wait_ms(state, 5, 0) == 0 and DecisionCore._rate_wait_ms(state, 5, 1) > 50000, "a line keeps the last free request in reserve")
	var config = Config.new()
	config.data = {"ai": {"core": {"endpoints": [{"model": "jev-latest", "api_key": "secret"}]}, "providers": {"x": {"api_key": "y"}}}}
	var redacted = config.redacted()
	check(redacted["ai"]["core"]["endpoints"][0]["api_key"] == "(set)" and redacted["ai"]["providers"]["x"]["api_key"] == "(set)", "keys inside lists are hidden too")
	config._user = {"ai": {"decide": {"provider": "typesafe", "model": "jev-latest", "depth": 6, "threads": 2, "pick": "best"}}}
	config.data = Util.deep_merge({"ai": {"decide": {"pick": "sample"}, "core": {"depth": 10, "endpoints": []}}}, config._user)
	check(config._migrate_decision_settings() and config.get_value("ai.core.depth") == 6 and config.get_value("ai.core.endpoints")[0]["model"] == "jev-latest"
		and config.get_value("ai.core.endpoints")[0]["threads"] == 2 and config.get_value("ai.decide.pick") == "best" and not config.get_value("ai.decide").has("model"),
		"1.3.0 decision settings move to the decision core")


func _test_sweep_analysis() -> void:
	var jumps = [{"label": "Jump", "action": "Jump"}, {"label": "Jump up-fwd", "action": "Jump"}, {"label": "Grab", "action": "Grab"}]
	var guessed = DecisionCore.reply_weights(jumps, {"Jump": 0.5, "Grab": 0.5}, false)
	check(abs(guessed[0] - 0.25) < 0.001 and abs(guessed[1] - 0.25) < 0.001 and abs(guessed[2] - 0.5) < 0.001, "a move's guess is shared by its variants")
	var even = DecisionCore.reply_weights(jumps, {}, false)
	check(abs(even[2] - 0.5) < 0.001, "with no guess every move counts the same, not every variant")
	check(abs(DecisionCore.reply_weights(jumps, {}, true)[2] - 1.0 / 3.0) < 0.001, "named replies count the same")
	check(Util.json_str(DecisionCore.sweep_order(2, [0.2, 0.5, 0.3])) == Util.json_str([[0, 1], [1, 1], [0, 2], [1, 2], [0, 0], [1, 0]]),
		"the sweep plays the likeliest replies first, against every candidate")
	var played = {"move": "A", "action": {"action": "A"}, "engine_data": null}
	var hit = {"dealt": 100, "taken": 0, "ko": "", "next_turn": "you act first", "stop": "decision", "step": {"you": played}}
	var hurt = {"dealt": 0, "taken": 150, "ko": "", "next_turn": "they act first", "stop": "decision", "step": {"you": played}}
	var replies = [{"label": "x", "action": "x", "input": null, "di": null}, {"label": "y high", "action": "y", "input": {"x": 0, "y": 1}, "di": null}]
	var weights = DecisionCore.reply_weights(replies, {"x": 0.9, "y": 0.1}, false)
	var candidate = {"label": "A", "action": "A", "input": null, "di": null, "description": "Slash (Attack)"}
	var facts = DecisionCore.facts([candidate, candidate], replies, weights, [[hit, hurt], [null, hit]])
	check(abs(facts[0]["average"] - 75.0) < 0.01 and facts[0]["worst"]["index"] == 1 and facts[0]["best"]["index"] == 0 and facts[0]["tested"] == 2,
		"each move gets its weighted average, worst and best reply")
	check(facts[1]["tested"] == 1 and facts[1]["worst"]["index"] == 1, "replies the sweep did not reach are left out")
	var both = [{"index": 0}, {"index": 1}]
	var entries = [{"score": 10.0, "worst": {"index": 1}, "option": candidate, "tested": 2, "replies": both},
		{"score": 50.0, "worst": {"index": 0}, "option": candidate, "tested": 2, "replies": both},
		{"score": 90.0, "worst": {}, "option": candidate, "tested": 0, "replies": []}]
	var lines = DecisionCore.deep_plan(entries, replies, [0.2, 0.8], 3, 10)
	check(lines.size() == 3 and lines[0]["candidate"] == 1 and lines[0]["reply"] == 1 and lines[1]["candidate"] == 0 and lines[1]["reply"] == 1
		and lines[2]["candidate"] == 1 and lines[2]["reply"] == 0 and lines[2]["depth"] == 10,
		"deep lines: every move played against the likeliest reply first (best first), then against its worst")
	_test_followup(candidate, replies, weights, hit, hurt)
	facts[0]["lines"] = [{"reply": 0, "turns": 2, "dealt": 50, "taken": 0, "ko": "", "stop": "model", "stop_detail": "rate limited", "steps": [
		{"you": played, "opponent": {"move": "x", "action": {"action": "x"}, "engine_data": null}},
		{"you": {"move": "Jump up-fwd", "action": {"action": "Jump", "data": {"x": 71, "y": -71}}, "engine_data": {"x": 71, "y": -71}}}]}]
	var summary = LookAheadReport.summarize({"candidates": [facts[0]], "replies": [{"option": replies[0], "p": 0.9}, {"option": replies[1], "p": 0.1}],
		"replies_named": false, "ranking": {"A": 1.0}, "ranking_by": "decision models", "engine": {"best": "A", "close": ["A"], "unsafe": []},
		"depth": 10, "lines_played": 1, "lines_planned": 1, "notes": [], "start": {"tick": 5, "you": {"hp": 1000}, "opponent": {"hp": 1000}},
		"sweep": {"pairs": 2, "played": 2, "check": {}}})
	var move = summary["moves"][0]
	check(summary["recommended"]["move"] == "A" and summary["decision_model_pick"] == "A" and not summary.has("close_calls"),
		"look_ahead says what the engine recommends and what the models picked")
	check(move["action"] == "A" and not move.has("data") and move["average"] == 75
		and move["worst"]["reply"] == "y high" and move["worst"]["reply_action"]["data"]["y"] == 1 and move["worst"]["result"].find("take 150") != -1,
		"look_ahead shows the worst case with the reply to submit as opponent_moves")
	check(move["dangerous"][0].find("vs y high (10%)") != -1 and move["likely"][0].find("vs x (90%): deal 100, you act first") != -1,
		"look_ahead lists the likeliest and the most dangerous replies")
	var line = move["lines"][0]
	check(line["stopped"].find("gave no move (rate limited)") != -1 and line["steps"][1]["you"]["data"]["x"] == 71 and not line["steps"][1]["you"].has("engine_data")
		and str(line["steps"][1]["opponent"]).find("busy") != -1, "line steps are executable and a short line says why it stopped")
	check(summary["coverage"].find("all 2 opponent replies (2 moves") != -1 and summary["start"]["preview"] == "matches the live match",
		"look_ahead says what it covered and where it started")
	check(LookAheadReport.stop_text("stuck", "", 3, 10).find("tick limit") != -1 and LookAheadReport.stop_text("depth", "", 10, 10) == "played all 10 turns",
		"every way a line ends is explained")


# Scores: next exchange plus the follow-up, never the first exchange twice.
func _test_followup(candidate: Dictionary, replies: Array, weights: Array, hit: Dictionary, hurt: Dictionary) -> void:
	var core = DecisionCore.new()
	var result = {"candidates": DecisionCore.facts([candidate, candidate], replies, weights, [[hit, hurt], [hurt, hit]]), "lines_planned": 0,
		"lines_played": 0, "notes": []}
	var lines = [{"candidate": 0, "reply": 0}, {"candidate": 1, "reply": 0}]
	var results = [{"ok": true, "turns": 3, "dealt": 250, "taken": 0, "ko": "", "stop": "depth", "steps": [], "first": hit, "unresolved": false},
		{"ok": true, "turns": 2, "dealt": 0, "taken": 300, "ko": "", "stop": "out_of_time", "steps": [], "first": hurt, "unresolved": true}]
	core._add_lines(result, lines, results)
	var a = result["candidates"][0]
	var b = result["candidates"][1]
	check(result["lines_played"] == 2 and abs(a["followup"] - 135.0) < 0.01 and abs(a["score"] - 210.0) < 0.01,
		"a line's follow-up is what came after its first exchange, weighted by the reply's chance (not the first exchange again)")
	check(abs(b["followup"] - 15.0) < 0.01 and b["followup_from"]["measured"] == 0 and b["followup_from"]["estimated"] == 1 and b["lines"][0]["unresolved"],
		"a line cut short does not count; replies without a line borrow from lines that started from the same kind of position")
	core.free()
	var safe = {"tested": 2, "score": 20.0, "worst": {"outcome": {"ko": ""}}, "option": {"label": "Block"}}
	var greedy = {"tested": 2, "score": 90.0, "worst": {"outcome": {"ko": "you"}}, "option": {"label": "Super"}}
	var near = {"tested": 2, "score": 0.0, "worst": {"outcome": {"ko": ""}}, "option": {"label": "Jump"}}
	var pick = Evidence.engine_labels([safe, greedy, near], Evidence.engine_pick([safe, greedy, near]))
	check(pick["best"] == "Block" and pick["unsafe"] == ["Super"] and pick["close"] == ["Block", "Jump"],
		"the engine's pick avoids a KO in the worst case; moves close to it are left to judgement")
	check(Evidence.engine_pick([{"tested": 0}]).empty(), "nothing simulated, no pick")


func _test_talk_and_playbook() -> void:
	check(SpeechBubbles.clean("  Too\nslow!\t ") == "Too slow!", "speech is one clean line")
	var long_line = ""
	for _i in range(30):
		long_line += "abcde"
	check(SpeechBubbles.clean(long_line).length() == SpeechBubbles.MAX_CHARS and SpeechBubbles.clean(long_line).ends_with("..."), "long speech is cut")
	var playbook = Prompts.knowledge("playbook")
	check(playbook.find("What kind of turn is it?") != -1 and playbook.find("Reading look_ahead") != -1, "the playbook covers turn types and look_ahead")
	check(Prompts.QUICK_START.size() >= 3 and Prompts.QUICK_START[0].find("kind of turn") != -1, "chatbots get a quick start")


func _test_sim_turns() -> void:
	check(SimTurns.relative_direction("NE", 1) == "up-fwd" and SimTurns.relative_direction("NE", -1) == "up-back", "screen directions read relative to the opponent")
	var aims = SimTurns.variants({"kind": "xy", "panel": "full", "default": {"x": 50, "y": 0}}, -1, 1)
	check(aims.size() == 9 and aims[0]["label"] == "" and aims[0]["input"]["x"] == -50 and aims[1]["label"] == "fwd" and aims[1]["input"]["x"] == -100
		and aims[3]["input"]["y"] == -100, "free aims: the default, then all eight compass aims toward the opponent")
	var jump = {"kind": "xy", "panel": "half", "limit_angle": true, "limit_center_degrees": -90, "limit_range_degrees": 120, "default": {"x": 0, "y": -50}}
	var arcs = []
	for aim in SimTurns.variants(jump, 1, 1):
		arcs.append(aim["label"])
	check(Util.json_str(arcs) == Util.json_str(["", "up-fwd", "up", "up-back", "up-fwd half", "up-back half"]),
		"a limited pad tries the aims inside its arc at full and half strength (up half is the default)")
	var limited = SimTurns.variants({"kind": "xy", "limit_angle": true, "limit_center_degrees": 0, "limit_range_degrees": 90, "default": {"x": 70, "y": -20}}, -1, 1)
	var backward = false
	for aim in limited:
		backward = backward or aim["input"]["x"] > 0
	check(limited[0]["input"]["x"] == -70 and not backward, "a limited aim is mirrored and stays on the forward side")
	var quarter = SimTurns.variants({"kind": "xy", "panel": "quarter", "always_max": true, "default": {"x": 100, "y": 0}}, 1, 1)
	check(quarter.size() == 3 and not SimTurns.aim_allowed({"panel": "quarter"}, 180) and not SimTurns.aim_allowed({"panel": "half"}, 90),
		"quarter and half pads only aim where the mouse can (full length only when the move always uses it)")
	var eight = {"kind": "direction8", "allowed": ["E", "NE", "Neutral"], "default": {"x": 1, "y": 0}}
	var mirrored = SimTurns.variants(eight, -1, 1)
	check(mirrored.size() == 2 and mirrored[0]["input"] == "W" and mirrored[0]["label"] == "fwd", "direction pickers mirror with facing")
	check(PayloadSpec.coerce(SimTurns.facing_spec(eight, -1, 1), "W")["ok"], "mirrored directions are accepted")
	var numbers = SimTurns.variants({"kind": "int_field", "key": "v", "min": 0, "max": 10, "default": {"v": 0}}, 1, 1)
	check(numbers.size() == 3 and numbers[0]["input"] == null and numbers[1]["input"] == 5 and numbers[2]["input"] == 10, "sliders try their default, middle and max")
	var sticky = SimTurns.variants({"kind": "bool", "default": true, "path": "Jump"}, 1, 1)
	check(sticky.size() == 2 and sticky[1]["label"] == "Jump off" and sticky[1]["input"] == false, "switches try both ways")
	var parry = {"kind": "object", "fields": {
		"Block Height": {"kind": "choice", "choices": ["High", "Low"], "values": [{"x": 0, "y": 0}, {"x": 0, "y": 1}], "default_choice": "High"},
		"Melee Parry Timing": {"kind": "int_field", "key": "count", "min": 1, "max": 20, "default": {"count": 1}}}}
	var blocks = SimTurns.variants(parry, 1, 1)
	check(blocks.size() == 4 and blocks[1]["label"] == "Low" and blocks[1]["input"]["Block Height"] == "Low" and blocks[2]["label"] == "Melee Parry Timing 10",
		"moves with several inputs vary one at a time (a low block)")
	check(PayloadSpec.coerce(parry, blocks[1]["input"])["value"]["Block Height"]["y"] == 1, "a field variant is valid data")
	check(SimTurns.variants({"kind": "none"}, 1, 1)[0]["input"] == null, "moves without input have one option")
	var clamped = PayloadSpec.coerce(SimTurns.facing_spec({"kind": "xy", "limit_angle": true, "limit_center_degrees": 0, "limit_range_degrees": 90}, -1, 1), {"x": 100, "y": 0})
	check(clamped["value"]["x"] < 0 and clamped.has("note"), "an aim outside the limit is clamped like the pad does, and said so")
	check(PayloadSpec.clamp_aim({"always_max": true}, 30, 0)["x"] == 100, "always-full aims are stretched")


func _test_http_parsing() -> void:
	var raw = "POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".to_utf8()
	check(HttpServer._find_header_end(raw) == 37, "header terminator found")
	check(HttpServer._find_header_end("GET / HTTP/1.1\r\n".to_utf8()) == -1, "incomplete headers detected")


func _test_tool_catalogue() -> void:
	var tools = Tools.new(null)
	for definition in tools.definitions():
		check(tools.has_method("_t_" + definition["name"]), "tool %s has a handler" % definition["name"])
		check(definition["inputSchema"]["type"] == "object", "tool %s has an object input schema" % definition["name"])


func _test_knowledge() -> void:
	for topic in ["gameplay", "playbook", "engine", "characters", "action-ui", "modding", "annotating"]:
		check(Prompts.knowledge(topic).length() > 200, "knowledge topic %s present" % topic)
	check(Prompts.annotate_system().find("budok.character.v1") != -1, "annotation prompt includes the format")


func _test_combo_helpers() -> void:
	check(Lookahead.DI_VARIANTS.size() == 8 and SimTurns.aim_input(-135, 1.0, -1)["x"] == 71 and SimTurns.aim_input(-135, 1.0, -1)["y"] == -71,
		"DI is tried in the four main directions and the diagonals (up-away facing left is up and to the right)")
	var free_pad = {"kind": "xy", "panel": "full"}
	var aims = ComboSolver._neighbours({"action": "Slash", "input": {"x": 100, "y": 0}, "description": "Slash (Attack)"}, free_pad, 1)
	var inputs = []
	for aim in aims:
		inputs.append([aim["input"]["x"], aim["input"]["y"]])
	check(Util.json_str(inputs) == Util.json_str([[92, -38], [92, 38], [50, 0], [75, 0]]) and aims[0]["label"] == "Slash aim 92,-38",
		"finer aims: 22.5 degrees either side, then half and three-quarter strength")
	check(ComboSolver._neighbours({"action": "Dash", "input": {"x": 100, "y": 0}, "description": ""}, {"kind": "xy", "always_max": true}, 1).size() == 2,
		"a move that always uses full length gets no weaker aims")
	var di_away = {"label": "Continue DI away", "action": "Continue", "input": null, "di": {"x": -100, "y": 0}}
	var plain = {"label": "Continue", "action": "Continue", "input": null, "di": null}
	var burst = {"label": "Burst", "action": "Burst", "input": null, "di": null}
	check(ComboSolver._defense([plain, di_away, burst], {"option": di_away}) == di_away and ComboSolver._defense([plain, burst], {"option": di_away}) == plain
		and ComboSolver._escapes([plain, di_away, burst]) == [burst], "the defender holds its DI where it can, else no DI; bursts are escapes")
	var block = {"label": "Block", "action": "Block", "description": "Block (Defense)"}
	var kick = {"label": "Kick", "action": "Kick", "description": "Kick (Attack)"}
	check(ComboSolver._attacks([block, kick]) == [kick] and ComboSolver._attacks([block]) == [block], "defensive moves are left out of combos while anything else is legal")
	var live = {"p1": {"hp": 900, "state": "Kick", "position": {"x": 10, "y": 0}}, "p2": {"hp": 700, "state": "HurtAerial", "position": {"x": 40, "y": -20}}}
	var near = {"p1": {"hp": 900, "state": "Kick", "position": {"x": 12, "y": 0}}, "p2": {"hp": 700, "state": "HurtAerial", "position": {"x": 45, "y": -20}}}
	var other = {"p1": {"hp": 900, "state": "Kick", "position": {"x": 10, "y": 0}}, "p2": {"hp": 650, "state": "HurtAerial", "position": {"x": 40, "y": -20}}}
	check(DecisionCore._drift(near, live) == 7 and DecisionCore._drift(other, live) == -1, "a remembered route's prediction is matched by state and hp, then distance")
	check(LookAheadReport.branch_end({"path": [1, 2, 3], "status": "ended", "end": "defender acts first"}, true) == "the opponent can act first after 3 steps"
		and LookAheadReport.branch_end({"path": [1], "status": "open", "cut": "step limit (24)", "broke": "Kick is not possible at step 2"}, true).find("broke") != -1,
		"every way a route ends is explained")
	_test_di_refinement()
	_test_reversed_options()


func _test_di_refinement() -> void:
	check(ComboSolver._between(315.0, 0.0) == 337.5 and ComboSolver._between(0.0, 45.0) == 22.5 and ComboSolver._between(180.0, 225.0) == 202.5,
		"DI refinement bisects neighbouring directions, across 0 too")
	var names = []
	for degrees in [0.0, 225.0, 337.5, 247.5, 101.25, 168.75]:
		names.append(ComboSolver.di_name(degrees))
	check(Util.json_str(names) == Util.json_str(["toward", "up-away", "toward 23° up", "up 23° away", "down 11° away", "away 11° down"]),
		"finer directions are named from the nearest main one: %s" % Util.json_str(names))
	var plain = {"label": "Continue", "action": "Continue", "input": null, "di": null}
	var di_away = {"label": "Continue DI away", "action": "Continue", "input": null, "di": {"x": -100, "y": 0}}
	var burst = {"label": "Burst", "action": "Burst", "input": null, "di": null}
	var finer = {"label": "DI toward 23° up", "degrees": 337.5, "refined": true}
	finer["option"] = ComboSolver._di_option(finer, 1)
	var facing_right = ComboSolver._defense([plain, di_away, burst], finer, 1)
	var facing_left = ComboSolver._defense([plain, di_away, burst], finer, -1)
	check(facing_right["di"]["x"] == 92 and facing_right["di"]["y"] == -38 and facing_left["di"]["x"] == -92 and facing_right["label"] == "Continue DI toward 23° up",
		"a finer DI is aimed from where the attacker is at each hit")
	check(ComboSolver._defense([plain, burst], finer, 1) == plain, "a finer DI falls back to no DI where the defender cannot DI")


func _test_reversed_options() -> void:
	var dash = make("var reversible = true\nvar title = \"Dash\"\nvar type = 0\nfunc flip_allowed():\n\treturn true\n")
	var grab = make("var reversible = true\nvar title = \"Grab\"\nvar type = 0\nfunc flip_allowed():\n\treturn false\n")
	var slash = make("var reversible = false\nvar title = \"Slash\"\nvar type = 0\n")
	var machine = make("var states_map = {}\n")
	machine.states_map = {"Dash": dash, "Grab": grab, "Slash": slash}
	var fighter = make("var state_machine = null\nfunc get_opponent_dir():\n\treturn 1\n")
	fighter.state_machine = machine
	check(Lookahead.can_flip(fighter, "Dash") and not Lookahead.can_flip(fighter, "Grab") and not Lookahead.can_flip(fighter, "Slash")
		and not Lookahead.can_flip(fighter, "Missing"), "a move can be reversed when its state is reversible and allows flipping now")
	var lookahead = Lookahead.new()
	var legal = ["Dash", "Grab", "Slash"]
	var specs = {"Dash": {"kind": "bool", "path": "Fast", "default": false}, "Grab": {"kind": "none"}, "Slash": {"kind": "none"}}
	var counts = []
	for reversed in ["", "default", "all"]:
		var labels = []
		for option in lookahead._options(fighter, legal, specs, 1, false, 0, reversed):
			if option["reverse"]:
				labels.append(option["label"])
		counts.append(labels)
	check(Util.json_str(counts) == Util.json_str([[], ["Dash reversed"], ["Dash reversed", "Dash Fast on reversed"]]),
		"reversed variants: none, the move as it stands, or every variant: %s" % Util.json_str(counts))
	var order = []
	for option in lookahead._options(fighter, legal, specs, 1, false, 0, "all"):
		order.append(option["label"])
	check(order[3] == "Dash reversed" and order.back() == "Dash Fast on reversed", "each move as it stands comes first, then reversed, then the other variants")
	lookahead.free()
	for node in [dash, grab, slash, machine, fighter]:
		node.free()
	var turned = {"label": "Dash reversed", "action": "Dash", "input": null, "di": null, "reverse": true}
	var straight = {"label": "Dash", "action": "Dash", "input": null, "di": null, "reverse": false}
	check(Util.json_str(Lookahead._move_key(turned)) != Util.json_str(Lookahead._move_key(straight))
		and Util.json_str(Lookahead._move_key(straight)) == Util.json_str(["Dash", null, null]), "a reversed move is another move; others keep their key")
	check(Util.json_str(Lookahead.action_of(turned)) == Util.json_str({"action": "Dash", "extra": {"reverse": true}})
		and Util.json_str(Lookahead.action_of(straight)) == Util.json_str({"action": "Dash"})
		and Util.json_str(Lookahead.extra_of({"di": {"x": 1, "y": 0}, "reverse": true})) == Util.json_str({"di": {"x": 1, "y": 0}, "reverse": true}),
		"reverse is submitted as extra.reverse")
	var aims = ComboSolver._neighbours({"action": "Slash", "input": {"x": -100, "y": 0}, "description": "", "reverse": true}, {"kind": "xy", "always_max": true}, -1)
	check(aims.size() == 2 and aims[0]["reverse"] and aims[0]["input"]["x"] == -92 and aims[0]["label"].ends_with(" reversed")
		and ComboSolver._family(turned) == "Dash reversed" and ComboSolver._family(straight) == "Dash", "finer aims of a reversed move stay reversed, turned with it")


func _test_previews() -> void:
	var root = Node.new()
	var menu = Node.new()
	menu.name = "Menu"
	var target = Node.new()
	target.name = "OptionsContainer"
	menu.add_child(target)
	var world = Node.new()
	world.name = "World"
	var buried = Node.new()
	buried.name = "Buried"
	world.add_child(buried)
	root.add_child(world)
	root.add_child(menu)
	check(Util.find_named(root, "OptionsContainer", [world]) == target and Util.find_named(root, "Buried", [world]) == null
		and Util.find_named(root, "Buried") == buried, "UI searches skip the game worlds they are told to")
	root.free()
	var game = make("var p1\nvar p2\nfunc get_player(id):\n\treturn p1 if id == 1 else p2\n")
	game.p1 = Node.new()
	game.p2 = Node.new()
	game.p1.filename = "res://characters/stickman/NinjaGuy.tscn"
	game.p2.filename = "res://characters/swordandgun/SwordGuy.tscn"
	var simulator = Simulator.new()
	var vanilla = Simulator.vanilla(game) and simulator.reusable(game)
	game.p2.filename = "res://budok_test_char/Tester.tscn"
	check(vanilla and not Simulator.vanilla(game) and not simulator.reusable(game),
		"previews are reused only when both fighters are the game's own characters")
	var started = OS.get_ticks_usec()
	simulator.charge(started - 5000)
	var under = not simulator.over_budget()
	simulator.charge(OS.get_ticks_usec() - 8000)
	check(under and simulator.over_budget(), "preview work shares one frame budget (12 ms by default)")
	for node in [game.p1, game.p2, game, simulator]:
		node.free()


func _test_chat_fallbacks() -> void:
	check(AutoPilot._transient({"status": 0}) and AutoPilot._transient({"status": 529}) and AutoPilot._transient({"status": 429})
		and not AutoPilot._transient({"status": 400}) and not AutoPilot._transient({"status": 401}) and not AutoPilot._transient({"error": "no API key"}),
		"a failed chat request is sent again only when it may work later (no connection, busy, rate limit)")
	var slash = {"label": "Slash", "action": "Slash"}
	var analysis = {"engine": {"best": "Slash"}, "candidates": [{"option": {"label": "Kick", "action": "Kick"}}, {"option": slash}]}
	check(DecisionCore.pick_of(analysis) == slash and DecisionCore.pick_of({"candidates": []}) == null,
		"the engine's pick is the analysis's best move, if any")


func _test_cli_agents() -> void:
	var spec = {"command": "/bin/claude", "model": "", "url": "http://127.0.0.1:8765/mcp?agent=abc", "token": "tok", "dir": "user://budok/agents/p1",
		"tools": ["wait_for_turn", "submit_action"]}
	spec["cli"] = "claude"
	var claude = CliAgent.command_line(spec)
	check(claude["ok"] and claude["args"].slice(0, 1) == ["-p", "--strict-mcp-config"] and "--output-format" in claude["args"]
		and claude["args"][5] == "mcp__budok__wait_for_turn mcp__budok__submit_action" and claude["env"].get("DISABLE_AUTOUPDATER") == "1",
		"Claude Code runs headless with only budok's tools and stream-json output")
	var config = JSON.parse(claude["files"].values()[0]).result
	check(config["mcpServers"]["budok"]["url"].ends_with("?agent=abc") and config["mcpServers"]["budok"]["headers"]["Authorization"] == "Bearer tok",
		"its MCP config carries the agent's ticket and the token")
	spec["cli"] = "codex"
	spec["model"] = "gpt-5-codex"
	var codex = CliAgent.command_line(spec)
	check(codex["ok"] and codex["args"][0] == "exec" and "mcp_servers.budok_agent.url=http://127.0.0.1:8765/mcp?agent=abc&token=tok" in codex["args"]
		and codex["args"].back() == "-" and "gpt-5-codex" in codex["args"], "Codex CLI gets budok's address with the token, the prompt on stdin")
	var toml = PoolStringArray(["model = \"o4\"", "[mcp_servers.budok]", "command = \"python\"", "args = [\"budok_stdio.py\"]",
		"[mcp_servers.budok.env]", "X = \"1\"", "[mcp_servers.\"yomi\"]", "url = \"http://127.0.0.1:8765/mcp\"",
		"[mcp_servers.github]", "command = \"gh-mcp\"", "[mcp_servers.budok_agent]", "url = \"x\""]).join("\n")
	check(CliAgent.codex_budok_servers(toml) == ["budok", "yomi"],
		"budok entries of the player's Codex config are found (by name, bridge or port), others are not: %s" % str(CliAgent.codex_budok_servers(toml)))
	spec["cli"] = "gemini"
	var gemini = CliAgent.command_line(spec)
	var settings = JSON.parse(gemini["files"][gemini["env"]["GEMINI_CLI_SYSTEM_SETTINGS_PATH"]]).result
	check(gemini["ok"] and settings["mcpServers"]["budok"]["trust"] and "--allowed-mcp-server-names" in gemini["args"],
		"Gemini CLI gets budok as a trusted MCP server from its settings file")
	spec["model"] = "bad model; rm"
	check(not CliAgent.command_line(spec)["ok"], "a model name with spaces or shell characters is refused")
	check(CliAgent.split_words("tool --flag \"a b\" {mcp_url}") == ["tool", "--flag", "a b", "{mcp_url}"], "a custom command splits into words, quotes kept together")
	check(CliAgent._quoted("50%\"x\\") == "\"50%%\\\"x\\\\\"", "Windows launcher arguments are quoted and escaped")
	var said = [CliAgent.text_of("{\"type\": \"assistant\", \"message\": {\"content\": [{\"type\": \"text\", \"text\": \"hi\"}, {\"type\": \"tool_use\"}]}}"),
		CliAgent.text_of("{\"type\": \"item.completed\", \"item\": {\"type\": \"agent_message\", \"text\": \"codex says\"}}"),
		CliAgent.text_of("{\"type\": \"message\", \"role\": \"assistant\", \"content\": \"gem\", \"delta\": true}"),
		CliAgent.text_of("Error: not logged in"), CliAgent.text_of("{\"type\": \"user\"}"),
		CliAgent.text_of("{\"type\": \"result\", \"subtype\": \"success\", \"num_turns\": 12}")]
	check(said[0]["text"] == "hi" and said[1]["text"] == "codex says" and said[2]["delta"] and said[3]["kind"] == "log" and said[4].empty()
		and said[5]["text"] == "the run ended after 12 turns", "agent logs are read for Claude Code, Codex CLI and Gemini CLI: %s" % Util.json_str(said))
