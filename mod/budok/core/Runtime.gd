extends Node

# Wires every budok service together and exposes the in-process API used by
# MCP tools, the token-mode AI and automation scripts:
#   runtime.config / roster / schemas / sources / matches / simulator / mcp /
#   llm / autopilot / annotator, plus the helpers below.

signal status_changed()

const Util = preload("res://budok/core/Util.gd")
const Config = preload("res://budok/core/Config.gd")
const Roster = preload("res://budok/core/Roster.gd")
const Introspector = preload("res://budok/core/Introspector.gd")
const SchemaStore = preload("res://budok/core/SchemaStore.gd")
const SourceBrowser = preload("res://budok/core/SourceBrowser.gd")
const MatchController = preload("res://budok/core/MatchController.gd")
const Simulator = preload("res://budok/core/Simulator.gd")
const McpServer = preload("res://budok/mcp/McpServer.gd")
const LlmClient = preload("res://budok/ai/LlmClient.gd")
const AutoPilot = preload("res://budok/ai/AutoPilot.gd")
const Annotator = preload("res://budok/ai/Annotator.gd")
const OverlayPanel = preload("res://budok/ui/Panel.gd")
const ModMenuHook = preload("res://budok/ui/ModMenuHook.gd")
const Automation = preload("res://budok/automation/Automation.gd")
const METADATA_PATH := "res://budok/_metadata"
const BRIDGE_SOURCE := "res://budok/tools/budok_stdio.py"
const BRIDGE_TARGET := "user://budok/budok_stdio.py"

var config = null
var roster = null
var introspector = null
var schemas = null
var sources = null
var matches = null
var simulator = null
var mcp = null
var llm = null
var autopilot = null
var annotator = null
var panel = null
var mod_menu = null
var automation = null
var server_state := {}
var bridge_path := ""
var _version := ""


func _ready() -> void:
	config = Config.new()
	config.load_config()
	roster = Roster.new()
	introspector = Introspector.new()
	schemas = SchemaStore.new(introspector)
	sources = SourceBrowser.new()
	sources.max_file_bytes = int(config.get_value("source_access.max_file_bytes", 200000))
	simulator = _add(Simulator.new(), "Simulator")
	matches = _add(MatchController.new(), "Matches")
	matches.setup(self)
	llm = _add(LlmClient.new(), "Llm")
	llm.setup(config)
	autopilot = _add(AutoPilot.new(), "AutoPilot")
	autopilot.setup(self, llm)
	annotator = _add(Annotator.new(), "Annotator")
	annotator.setup(self, llm)
	mcp = _add(McpServer.new(), "Mcp")
	mcp.setup(self)
	restart_server()
	panel = _add(OverlayPanel.new(), "Panel")
	panel.setup(self)
	mod_menu = _add(ModMenuHook.new(), "ModMenuHook")
	mod_menu.setup(self)
	automation = _add(Automation.new(), "Automation")
	automation.setup(self)
	matches.connect("match_started", self, "_on_match_changed")
	matches.connect("match_ended", self, "_on_match_changed")
	_install_bridge()
	print("budok %s ready: MCP %s" % [version(), server_state.get("url", server_state.get("error", "?"))])


func version() -> String:
	if _version == "":
		var meta = Util.read_json(METADATA_PATH)
		_version = str(meta.get("version", "0")) if meta is Dictionary else "0"
	return _version


# Copies the stdio bridge (for MCP clients that only launch local commands)
# out of the mod zip to a real file path the client can run.
func _install_bridge() -> void:
	var source = Util.read_text(BRIDGE_SOURCE)
	if source == null:
		return
	if Util.read_text(BRIDGE_TARGET) != source and not Util.write_text(BRIDGE_TARGET, source):
		push_warning("budok: could not write %s" % BRIDGE_TARGET)
		return
	bridge_path = ProjectSettings.globalize_path(BRIDGE_TARGET)


func restart_server() -> Dictionary:
	server_state = mcp.start()
	if not server_state.get("ok", false):
		push_warning("budok: " + str(server_state.get("error", "MCP server not started")))
	emit_signal("status_changed")
	return server_state


func status() -> Dictionary:
	var global = Util.autoload("Global")
	return {
		"ok": true,
		"budok_version": version(),
		"game_version": str(Util.prop(global, "VERSION", "unknown")),
		"engine_version": str(Engine.get_version_info().get("string", "?")),
		"mcp": {"listening": server_state.get("ok", false), "url": mcp.url(), "sessions": mcp.session_count()},
		"match": matches.status(),
		"ai": {
			"play": llm.describe_role("play"),
			"annotate": llm.describe_role("annotate"),
			"autopilot": autopilot.stats,
		},
		"annotation_jobs": annotator.jobs.values(),
	}


func describe_character(entry: Dictionary, only_moves) -> Dictionary:
	var info = schemas.describe(entry)
	var skeleton = info["skeleton"]
	if not skeleton.get("ok", false):
		return {"ok": false, "error": skeleton.get("error", "cannot introspect character")}
	var schema = info["schema"]
	var notes = schema.get("moves", {})
	var wanted = only_moves if only_moves is Array and not only_moves.empty() else skeleton["moves"].keys()
	var moves = []
	for move_name in wanted:
		if not skeleton["moves"].has(move_name):
			continue
		var measured = skeleton["moves"][move_name]
		var item = {"name": move_name, "title": measured["title"], "type": measured["type"], "air": measured["air"]}
		for key in ["frames", "meter_bars", "projectile", "combo_only", "neutral_only", "has_payload"]:
			if measured.has(key) and measured[key]:
				item[key] = measured[key]
		var flags = []
		for box in measured.get("hitboxes", []):
			for flag in ["throw", "guard_break", "knockdown", "hard_knockdown", "wall_slam", "hits_otg"]:
				if box.get(flag, false) and not (flag in flags):
					flags.append(flag)
			if box.get("height", "Mid") == "Low" and not ("low" in flags):
				flags.append("low")
			if box.get("height", "Mid") == "High" and not ("overhead" in flags):
				flags.append("overhead")
		if not flags.empty():
			item["properties"] = flags
		if notes.has(move_name):
			for key in notes[move_name]:
				item[key] = notes[move_name][key]
		moves.append(item)
	var resources = {}
	var resource_notes = schema.get("resources", {})
	for key in skeleton.get("resources", {}):
		var meta = resource_notes.get(key, {})
		resources[key] = {"default": skeleton["resources"][key]}
		for field in meta:
			resources[key][field] = meta[field]
	return {
		"ok": true,
		"character": info["character"],
		"internal_name": info["internal_name"],
		"schema_status": info["status"],
		"schema_path": info["schema_path"],
		"stale": info["stale"],
		"coverage": info["coverage"],
		"summary": schema.get("summary", {}),
		"stats": skeleton.get("stats", {}),
		"resources": resources,
		"extras": schema.get("extras", {}),
		"moves": moves,
	}


func introspect_character(entry: Dictionary, only_moves, include_source: bool, offset: int, limit: int) -> Dictionary:
	var info = schemas.describe(entry)
	var skeleton = info["skeleton"]
	if not skeleton.get("ok", false):
		return {"ok": false, "error": skeleton.get("error", "cannot introspect character")}
	var names = only_moves if only_moves is Array and not only_moves.empty() else skeleton["moves"].keys()
	names.sort()
	var page = names.slice(offset, int(min(names.size(), offset + limit)) - 1) if offset < names.size() else []
	var moves = {}
	var code = {}
	for move_name in page:
		if not skeleton["moves"].has(move_name):
			continue
		moves[move_name] = skeleton["moves"][move_name]
		if include_source and moves[move_name].get("dynamic", false):
			var read = sources.read(str(moves[move_name].get("script_path", "")), 1, 300)
			if read.get("ok", false):
				code[move_name] = read["content"]
	var out = {
		"ok": true,
		"character": info["character"],
		"fingerprint": skeleton["fingerprint"],
		"scene_path": skeleton["scene_path"],
		"script_path": skeleton["script_path"],
		"stats": skeleton["stats"],
		"resources": skeleton["resources"],
		"total_moves": names.size(),
		"offset": offset,
		"returned": moves.size(),
		"moves": moves,
		"other_states": skeleton["other_states"],
		"existing_notes": info["schema"].get("moves", {}).keys(),
		"notes_status": info["status"],
	}
	if not code.empty():
		out["sources"] = code
	if offset + limit < names.size():
		out["next_offset"] = offset + limit
	return out


# Coroutine: opt-in community registry lookup by skeleton fingerprint.
func fetch_registry(entry: Dictionary) -> Dictionary:
	yield(get_tree(), "idle_frame")
	if not bool(config.get_value("schemas.registry_enabled", false)):
		return {"ok": false, "error": "the community registry is off; enable schemas.registry_enabled and set schemas.registry_url in the panel"}
	var base = str(config.get_value("schemas.registry_url", "")).trim_suffix("/")
	if not base.begins_with("https://"):
		return {"ok": false, "error": "schemas.registry_url must be an https:// URL"}
	var info = schemas.describe(entry)
	var fingerprint = str(info["skeleton"].get("fingerprint", ""))
	if fingerprint == "":
		return {"ok": false, "error": "character could not be introspected"}
	var response = yield(llm.get_json("%s/%s.json" % [base, fingerprint]), "completed")
	if not response.get("ok", false):
		return {"ok": false, "error": "registry: %s" % response.get("error", "request failed")}
	var checked = schemas.validate(response["json"], info["skeleton"])
	if not checked["ok"]:
		return {"ok": false, "error": "registry schema failed validation", "errors": checked["errors"]}
	var stored = checked["cleaned"]
	stored["format"] = "budok.character.v1"
	stored["character"] = entry["display_name"]
	stored["fingerprint"] = fingerprint
	stored["provenance"] = {"by": "registry", "url": base}
	schemas.store_registry(fingerprint, stored)
	return {"ok": true, "status": schemas.describe(entry)["status"], "coverage": schemas.describe(entry)["coverage"]}


func _on_match_changed(_value) -> void:
	emit_signal("status_changed")


func _add(node: Node, node_name: String) -> Node:
	node.name = node_name
	add_child(node)
	return node
