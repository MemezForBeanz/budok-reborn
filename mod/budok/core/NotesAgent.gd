extends Reference

# Starts a headless Claude Code agent that writes character notes in its own
# context, with the player's own Claude login (schemas.auto.agent_command).
# It connects to budok over MCP with only the notes tools allowed, works
# through the queue (get_schema_task {"worker": true}) and exits when the queue
# is empty. Its prompt, MCP config and log live in user://budok/agent.

const Util = preload("res://budok/core/Util.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const CliAgent = preload("res://budok/core/CliAgent.gd")
const DIR := "user://budok/agent"
const NOT_FOUND := "Claude Code (the claude command) was not found; install it, or set its full path under Automatic notes"
const TOOLS := ["get_schema_task", "finish_schema_task", "introspect_character", "describe_character", "list_characters",
	"read_source", "search_source", "list_source_files", "submit_character_schema", "recall"]


# Full path of the agent command, or "" when it cannot be found (see
# CliAgent.resolve).
static func resolve(command: String) -> String:
	return CliAgent.resolve(command if command.strip_edges() != "" else "claude")


static func spawn(runtime) -> Dictionary:
	var command = resolve(str(runtime.config.get_value("schemas.auto.agent_command", "claude")))
	if command == "":
		return {"ok": false, "error": NOT_FOUND}
	Util.ensure_dir(DIR)
	var headers = {}
	var token = str(runtime.config.get_value("mcp.auth_token", ""))
	if token != "" and bool(runtime.config.get_value("mcp.require_token", true)):
		headers["Authorization"] = "Bearer " + token
	Util.write_json(DIR + "/mcp.json", {"mcpServers": {"budok": {"type": "http", "url": runtime.mcp.url(), "headers": headers}}})
	Util.write_text(DIR + "/prompt.txt", Prompts.notes_worker_prompt(true))
	var mcp_path = ProjectSettings.globalize_path(DIR + "/mcp.json")
	var prompt_path = ProjectSettings.globalize_path(DIR + "/prompt.txt")
	var log_path = ProjectSettings.globalize_path(DIR + "/agent.log")
	var allowed = []
	for tool_name in TOOLS:
		allowed.append("mcp__budok__" + tool_name)
	var model = str(runtime.config.get_value("schemas.auto.agent_model", "")).strip_edges()
	# MCP clients may change the model, and on Windows it goes into a script.
	var plain = RegEx.new()
	plain.compile("^[A-Za-z0-9._:\\[\\]-]*$")
	if plain.search(model) == null:
		return {"ok": false, "error": "the notes agent model may only contain letters, digits and . _ : - [ ]"}
	var args = ["-p", "--strict-mcp-config", "--mcp-config", mcp_path, "--allowedTools", PoolStringArray(allowed).join(" ")]
	if model != "":
		args += ["--model", model]
	# Update checks are off: a headless run does not need them.
	var pid = CliAgent.launch(DIR, "run", command, args, {"DISABLE_AUTOUPDATER": "1"}, prompt_path, log_path)
	if pid <= 0:
		return {"ok": false, "error": "could not start %s" % command}
	return {"ok": true, "pid": pid, "log": log_path, "command": command}


# The end of the agent's log (why it stopped), or "".
static func log_tail(log_path: String, chars: int = 300) -> String:
	var text = Util.read_text(log_path)
	if not (text is String):
		return ""
	text = text.strip_edges()
	return ("..." + text.substr(text.length() - chars)) if text.length() > chars else text


static func stop(pid: int) -> void:
	CliAgent.stop(pid)
