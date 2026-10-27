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
	print("%d checks, %d failures" % [checks, failures])
	quit(failures)


func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: " + label)


# Godot 3 compares Dictionaries by reference; compare contents instead.
func same(a, b) -> bool:
	return Util.to_json(a, true) == Util.to_json(b, true)


func make(source: String, base: String = "Node"):
	var script = GDScript.new()
	script.source_code = "extends %s\n%s" % [base, source]
	script.reload()
	return script.new()


func _test_util() -> void:
	var merged = Util.deep_merge({"a": {"b": 1, "c": 2}, "d": 1}, {"a": {"b": 5}, "e": 3})
	check(merged["a"]["b"] == 5 and merged["a"]["c"] == 2 and merged["e"] == 3, "deep_merge keeps and overrides keys")
	var data = {}
	Util.set_path(data, "x.y.z", 4)
	check(Util.get_path(data, "x.y.z") == 4 and Util.get_path(data, "x.q", "d") == "d", "set_path / get_path")
	check(Util.strip_trailing_digits("Bullet12") == "Bullet" and Util.strip_trailing_digits("42") == "42", "strip_trailing_digits")
	check(same(Util.json_safe(Vector2(1.5, 2)), {"x": 1.5, "y": 2.0}), "json_safe Vector2")
	check(Util.as_int("3.6") == 4 and Util.as_int(2.0) == 2 and Util.as_int(null, 7) == 7, "as_int")
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
	var dir_spec = {"kind": "direction8", "allowed": ["N", "E", "Neutral"], "default": "Neutral"}
	check(same(PayloadSpec.coerce(dir_spec, "e")["value"], {"x": 1, "y": 0}), "direction names are case-insensitive")
	check(not PayloadSpec.coerce(dir_spec, "SW")["ok"], "disallowed direction rejected")
	check(same(PayloadSpec.coerce(dir_spec, {"x": 0, "y": -5})["value"], {"x": 0, "y": -1}), "direction from vector")
	var xy = PayloadSpec.coerce({"kind": "xy", "default": {"x": 0, "y": 0}}, {"x": 250.0, "y": -3.4})
	check(xy["ok"] and same(xy["value"], {"x": 100, "y": -3}), "xy clamps and rounds")
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
	var intro = Introspector.new()
	var info = intro._build(fighter, {"display_name": "Fake", "name": "F-1__Fake", "scene_path": "res://x/Fake.tscn"})
	var move = info["moves"].get("BigPunch", {})
	check(move.get("title") == "Big Punch" and move.get("type") == "Attack", "state title and type read")
	check(move.get("frames", {}).get("startup") == 5 and move["frames"]["active"] == 3, "startup/active from hitboxes")
	check(move["frames"]["recovery"] == 18 - 7, "recovery from iasa (negative iasa counts from the end)")
	check(move["frames"]["reach"] == 35 and move["hitboxes"][0]["height"] == "Low", "reach and hit height measured")
	check(info["fingerprint"].length() == 16, "fingerprint computed")
	fighter.free()


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
	for topic in ["gameplay", "engine", "characters", "action-ui", "modding", "annotating"]:
		check(Prompts.knowledge(topic).length() > 200, "knowledge topic %s present" % topic)
	check(Prompts.annotate_system().find("budok.character.v1") != -1, "annotation prompt includes the format")
