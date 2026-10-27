extends Node

# Token-mode schema writer: uses the ai.annotate model to add notes to a
# character's measured skeleton, batch by batch, then a summary pass.
# Validation errors from SchemaStore are fed back to the model until it
# produces valid notes or runs out of steps.

signal job_changed(job)

const Util = preload("res://budok/core/Util.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const TOOLS := [
	{
		"name": "submit_character_schema",
		"description": "Save notes (partial is fine; merges). Fields per knowledge 'annotating'. Returns errors to fix.",
		"parameters": {"type": "object", "properties": {"schema": {"type": "object"}}, "required": ["schema"]},
	},
	{
		"name": "read_source",
		"description": "Read a res:// script or scene (line numbered).",
		"parameters": {"type": "object", "properties": {
			"path": {"type": "string"}, "start_line": {"type": "integer"}, "max_lines": {"type": "integer"}}, "required": ["path"]},
	},
	{
		"name": "search_source",
		"description": "Search res:// text files (case-insensitive).",
		"parameters": {"type": "object", "properties": {
			"query": {"type": "string"}, "path_prefix": {"type": "string"}}, "required": ["query"]},
	},
]

var runtime = null
var llm = null
var jobs := {}


func setup(runtime_ref, llm_ref) -> void:
	runtime = runtime_ref
	llm = llm_ref


func start(entry: Dictionary, force: bool = false) -> Dictionary:
	var role = llm.describe_role("annotate")
	if not role["has_key"]:
		return {"ok": false, "error": "no API key for ai.annotate provider '%s'; add one in the budok panel (F8), or write the schema yourself with introspect_character + submit_character_schema" % role["provider"]}
	var key = entry["name"]
	if jobs.has(key) and jobs[key]["status"] == "running":
		return {"ok": true, "job": jobs[key]}
	var info = runtime.schemas.describe(entry)
	if not info["skeleton"].get("ok", false):
		return {"ok": false, "error": info["skeleton"].get("error", "cannot introspect character")}
	if not force and info["coverage"]["missing"].empty() and info["coverage"]["has_summary"]:
		return {"ok": true, "message": "%s already has complete notes (%s); pass force=true to regenerate" % [entry["display_name"], info["status"]]}
	jobs[key] = {"character": entry["display_name"], "status": "running", "progress": "starting", "model": role["model"],
		"started": Time.get_datetime_string_from_system(), "errors": []}
	emit_signal("job_changed", jobs[key])
	_run(entry, force)
	return {"ok": true, "job": jobs[key], "message": "annotation started; poll get_status"}


func _run(entry: Dictionary, force: bool) -> void:
	yield(get_tree(), "idle_frame")
	var job = jobs[entry["name"]]
	var cfg = runtime.config.get_value("ai.annotate", {})
	var info = runtime.schemas.describe(entry)
	var skeleton = info["skeleton"]
	var todo = skeleton["moves"].keys() if force else info["coverage"]["missing"]
	todo.sort()
	var batch_size = int(max(1, int(cfg.get("batch_size", 10))))
	var system = Prompts.annotate_system()
	var provenance = {"by": "budok-annotator", "provider": cfg.get("provider", ""), "model": cfg.get("model", ""), "at": Time.get_datetime_string_from_system()}
	var batch_start = 0
	while batch_start < todo.size():
		var batch = todo.slice(batch_start, int(min(todo.size(), batch_start + batch_size)) - 1)
		job["progress"] = "moves %d-%d of %d" % [batch_start + 1, batch_start + batch.size(), todo.size()]
		emit_signal("job_changed", job)
		var prompt = _batch_prompt(entry, skeleton, batch, cfg)
		var ok = yield(_converse(entry, system, prompt, provenance, cfg, job), "completed")
		if not ok:
			break
		batch_start += batch_size
	if job["status"] == "running":
		job["progress"] = "summary"
		emit_signal("job_changed", job)
		var summary_prompt = _summary_prompt(entry, skeleton)
		yield(_converse(entry, system, summary_prompt, provenance, cfg, job), "completed")
	runtime.schemas.invalidate(entry["name"])
	var final_info = runtime.schemas.describe(entry)
	job["coverage"] = "%d/%d moves" % [final_info["coverage"]["annotated"], final_info["coverage"]["total"]]
	if job["status"] == "running":
		job["status"] = "done" if final_info["coverage"]["missing"].empty() else "partial"
	job["progress"] = "finished"
	emit_signal("job_changed", job)


# One tool-use conversation; returns true when the model saved valid notes.
func _converse(entry: Dictionary, system: String, prompt: String, provenance: Dictionary, cfg: Dictionary, job: Dictionary) -> bool:
	yield(get_tree(), "idle_frame")
	var messages = [llm.user_message(prompt)]
	var saved = false
	for _step in range(int(cfg.get("max_steps", 30))):
		var reply = yield(llm.chat("annotate", system, messages, TOOLS), "completed")
		if not reply.get("ok", false):
			job["status"] = "error"
			job["errors"].append(str(reply.get("error", "unknown error")))
			return false
		messages.append(reply["assistant"])
		if reply["tool_calls"].empty():
			if saved:
				return true
			messages.append(llm.user_message("Call submit_character_schema with your notes."))
			continue
		var results = []
		for tool_call in reply["tool_calls"]:
			var input = tool_call["input"] if tool_call["input"] is Dictionary else {}
			var output = {}
			match str(tool_call["name"]):
				"submit_character_schema":
					output = runtime.schemas.submit(entry, input.get("schema"), provenance)
					if output.get("ok", false):
						saved = true
				"read_source":
					output = runtime.sources.read(str(input.get("path", "")), Util.as_int(input.get("start_line", 1), 1), Util.as_int(input.get("max_lines", 300), 300))
				"search_source":
					var prefix = str(input.get("path_prefix", ""))
					if prefix == "":
						prefix = entry["mod_folder"] if str(entry.get("mod_folder", "")) != "" else "res://"
					output = runtime.sources.search(str(input.get("query", "")), prefix)
				_:
					output = {"ok": false, "error": "unknown tool"}
			results.append({"id": tool_call["id"], "content": Util.truncate(Util.json_str(output), 20000), "is_error": not output.get("ok", true)})
		messages += llm.tool_results("annotate", results)
		if saved and _all_ok(results):
			return true
	return saved


func _batch_prompt(entry: Dictionary, skeleton: Dictionary, batch: Array, cfg: Dictionary) -> String:
	var moves = {}
	var sources = []
	var max_chars = int(cfg.get("max_source_chars", 6000))
	var budget = max_chars * 3
	for move_name in batch:
		var move = skeleton["moves"][move_name].duplicate(true)
		moves[move_name] = move
		if bool(cfg.get("include_source", true)) and move.get("dynamic", false) and budget > 0 and str(move.get("script_path", "")) != "":
			var read = runtime.sources.read(move["script_path"], 1, 400)
			if read.get("ok", false):
				var excerpt = Util.truncate(read["content"], int(min(max_chars, budget)))
				budget -= excerpt.length()
				sources.append("### %s (%s)\n%s" % [move_name, move["script_path"], excerpt])
	var parts = [
		"Character: %s (scene %s, %s)." % [entry["display_name"], entry["scene_path"], entry["source"]],
		"Stats: " + Util.json_str(skeleton.get("stats", {})),
		"Character resources (script variables): " + Util.json_str(skeleton.get("resources", {})),
		"Fighter script: %s" % skeleton.get("script_path", ""),
		"Moves to annotate now (measured data):\n" + Util.json_str(moves),
	]
	if not sources.empty():
		parts.append("Scripts of code-driven moves:\n" + PoolStringArray(sources).join("\n\n"))
	var learned = _learned(entry)
	if learned != "":
		parts.append(learned)
	parts.append("Write notes for exactly these moves and save them with submit_character_schema {\"schema\": {\"moves\": {...}}}. Use read_source if something is unclear. Keep each text short and concrete.")
	return PoolStringArray(parts).join("\n\n")


func _summary_prompt(entry: Dictionary, skeleton: Dictionary) -> String:
	var info = runtime.schemas.describe(entry)
	return PoolStringArray([
		"Character: %s. All move notes so far:" % entry["display_name"],
		Util.json_str(info["schema"].get("moves", {})),
		"Stats: " + Util.json_str(skeleton.get("stats", {})),
		"Resources: " + Util.json_str(skeleton.get("resources", {})),
		"Fighter script: %s (read it for passives and resource rules)." % skeleton.get("script_path", ""),
		_learned(entry),
		"Now submit the summary (archetype, game_plan, strengths, weaknesses, tips) and a meaning/label for each gameplay-relevant resource (hide internal bookkeeping ones with hidden=true), via submit_character_schema.",
	]).join("\n\n")


# What bots wrote down about this character in real matches (their memories):
# evidence to check against the code, not facts to copy.
func _learned(entry: Dictionary) -> String:
	if not bool(runtime.config.get_value("memory.enabled", true)):
		return ""
	var entries = runtime.memory.recall([entry["display_name"]], "", 15)
	if entries.empty():
		return ""
	return "What players' bots noted about this character in matches (verify against the code before using):\n- " + PoolStringArray(runtime.memory.lines(entries)).join("\n- ")


static func _all_ok(results: Array) -> bool:
	for result in results:
		if result["is_error"]:
			return false
	return true
