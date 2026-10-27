extends Reference

# MCP resources (knowledge pack, schema format, character schemas, match log)
# and prompts (play_match, annotate_character, modding_help).

const Util = preload("res://budok/core/Util.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const KNOWLEDGE_DIR := "res://budok/knowledge"
const FORMAT_PATH := "res://budok/schemas/character.v1.json"

var runtime = null


func _init(runtime_ref) -> void:
	runtime = runtime_ref


func list() -> Array:
	var out = []
	for topic in knowledge_topics():
		var text = Prompts.knowledge(topic)
		out.append({
			"uri": "yomi://knowledge/" + topic,
			"name": topic,
			"title": _title(text, topic),
			"description": "YOMI Hustle / budok knowledge: " + topic,
			"mimeType": "text/markdown",
		})
	out.append({"uri": "yomi://schema/format", "name": "schema-format", "title": "Character schema format (JSON Schema)", "mimeType": "application/json"})
	out.append({"uri": "yomi://match/log", "name": "match-log", "title": "Current match log", "mimeType": "application/json"})
	for slot in ["p1", "p2"]:
		var entry = runtime.matches.match_info.get("characters", {}).get(slot)
		if entry is Dictionary:
			out.append({"uri": "yomi://characters/%s/schema" % entry["display_name"].percent_encode(), "name": "%s-schema" % slot,
				"title": "%s schema (%s)" % [entry["display_name"], slot], "mimeType": "application/json"})
	return out


func templates() -> Array:
	return [
		{"uriTemplate": "yomi://characters/{name}/schema", "name": "character-schema", "title": "Character schema (measured + notes)", "mimeType": "application/json"},
		{"uriTemplate": "yomi://characters/{name}/skeleton", "name": "character-skeleton", "title": "Character skeleton (measured only)", "mimeType": "application/json"},
		{"uriTemplate": "yomi://knowledge/{topic}", "name": "knowledge", "title": "Knowledge pack topic", "mimeType": "text/markdown"},
	]


func read(uri: String) -> Dictionary:
	if uri.begins_with("yomi://knowledge/"):
		var topic = uri.substr("yomi://knowledge/".length())
		if not (topic in knowledge_topics()):
			return {"ok": false, "error": "unknown knowledge topic %s; topics: %s" % [topic, str(knowledge_topics())]}
		return _contents(uri, "text/markdown", Prompts.knowledge(topic))
	if uri == "yomi://schema/format":
		return _contents(uri, "application/json", str(Util.read_text(FORMAT_PATH)))
	if uri == "yomi://match/log":
		return _contents(uri, "application/json", Util.json_str(runtime.matches.match_log(50)))
	if uri.begins_with("yomi://characters/"):
		var rest = uri.substr("yomi://characters/".length()).split("/")
		if rest.size() != 2:
			return {"ok": false, "error": "expected yomi://characters/{name}/schema or /skeleton"}
		var entry = runtime.roster.resolve(rest[0].percent_decode())
		if entry == null:
			return {"ok": false, "error": "unknown character %s" % rest[0]}
		var loaded = runtime.roster.ensure_loaded(entry)
		if not loaded["ok"]:
			return {"ok": false, "error": loaded["error"]}
		if rest[1] == "skeleton":
			return _contents(uri, "application/json", Util.json_str(runtime.schemas.describe(entry)["skeleton"]))
		return _contents(uri, "application/json", Util.json_str(runtime.describe_character(entry, [])))
	return {"ok": false, "error": "unknown resource %s" % uri}


func prompts() -> Array:
	return [
		{"name": "play_match", "title": "Play the current match",
			"description": "Rules, both characters' notes and the tool loop for playing as a slot.",
			"arguments": [{"name": "slot", "description": "p1 or p2 (default p2)", "required": false}]},
		{"name": "annotate_character", "title": "Write a character schema",
			"description": "Guided workflow for writing notes for a (modded) character.",
			"arguments": [{"name": "character", "description": "Character name", "required": true}]},
		{"name": "notes_worker", "title": "Write character notes in the background",
			"description": "Run this in a separate chat: it works through budok's queue of characters without notes, so the chat that plays never has to.",
			"arguments": []},
		{"name": "modding_help", "title": "YOMI modding help",
			"description": "Engine and modding conventions primer, for questions about game or mod code.",
			"arguments": [{"name": "question", "description": "What you want to know", "required": false}]},
	]


func get_prompt(name: String, args) -> Dictionary:
	if not (args is Dictionary):
		args = {}
	match name:
		"play_match":
			var slot = str(args.get("slot", "p2"))
			if not (slot in ["p1", "p2"]):
				slot = "p2"
			return _prompt("Play %s" % slot, Prompts.play_match_prompt(runtime, slot))
		"annotate_character":
			var character = str(args.get("character", ""))
			if character == "":
				return {"ok": false, "error": "argument 'character' is required"}
			return _prompt("Annotate %s" % character, Prompts.annotate_prompt(character))
		"notes_worker":
			return _prompt("budok notes writer", Prompts.notes_worker_prompt())
		"modding_help":
			var text = PoolStringArray([Prompts.knowledge("engine"), Prompts.knowledge("modding"), Prompts.knowledge("characters"),
				"Use search_source / read_source to look at the actual game and mod code before answering.",
				"Question: " + str(args.get("question", "(none yet)"))]).join("\n\n")
			return _prompt("YOMI modding help", text)
	return {"ok": false, "error": "unknown prompt %s" % name}


func knowledge_topics() -> Array:
	var topics = []
	var dir = Directory.new()
	if dir.open(KNOWLEDGE_DIR) == OK:
		dir.list_dir_begin(true, true)
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.get_extension() == "md":
				topics.append(file_name.get_basename())
			file_name = dir.get_next()
		dir.list_dir_end()
	topics.sort()
	return topics


func _prompt(description: String, text: String) -> Dictionary:
	return {"ok": true, "result": {"description": description, "messages": [{"role": "user", "content": {"type": "text", "text": text}}]}}


static func _contents(uri: String, mime: String, text: String) -> Dictionary:
	return {"ok": true, "contents": [{"uri": uri, "mimeType": mime, "text": text}]}


static func _title(text: String, fallback: String) -> String:
	for line in text.split("\n"):
		if line.begins_with("# "):
			return line.substr(2).strip_edges()
	return fallback
