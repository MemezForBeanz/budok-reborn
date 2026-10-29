extends Reference

# Starts a headless Claude Code agent that writes character notes in its own
# context, with the player's own Claude login (schemas.auto.agent_command).
# It connects to budok over MCP with only the notes tools allowed, works
# through the queue (get_schema_task {"worker": true}) and exits when the queue
# is empty. Its prompt, MCP config and log live in user://budok/agent.

const Util = preload("res://budok/core/Util.gd")
const Prompts = preload("res://budok/ai/Prompts.gd")
const DIR := "user://budok/agent"
const NOT_FOUND := "Claude Code (the claude command) was not found; install it, or set its full path under Automatic notes"
const TOOLS := ["get_schema_task", "finish_schema_task", "introspect_character", "describe_character", "list_characters",
	"read_source", "search_source", "list_source_files", "submit_character_schema", "recall"]


# Full path of the agent command, or "" when it cannot be found. A game
# started by Steam often has a shorter PATH than your shell, so the usual
# install folders are searched too.
static func resolve(command: String) -> String:
	command = command.strip_edges()
	if command == "":
		command = "claude"
	if command.find("/") != -1 or command.find("\\") != -1:
		return command if Util.file_exists(command) else ""
	var windows = OS.get_name() == "Windows"
	var dirs = []
	for dir in OS.get_environment("PATH").split(";" if windows else ":"):
		if dir != "":
			dirs.append(dir)
	var home = OS.get_environment("USERPROFILE" if windows else "HOME")
	if home != "":
		for dir in [".local/bin", ".claude/local", ".npm-global/bin", "bin", "AppData/Roaming/npm"]:
			dirs.append(home.plus_file(dir))
	for dir in ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]:
		dirs.append(dir)
	var names = [command + ".exe", command + ".cmd", command] if windows else [command]
	for dir in dirs:
		for name in names:
			if Util.file_exists(dir.plus_file(name)):
				return dir.plus_file(name)
	return ""


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
	# The prompt goes in on stdin and the output to the log, so a launcher
	# script does the redirects (and turns off update checks, which a headless
	# run does not need). On Windows that is a .cmd file, since Godot does not
	# escape quotes inside arguments; on other systems sh gets every value as a
	# separate argument, so nothing in them is parsed as shell code.
	var pid = -1
	if OS.get_name() == "Windows":
		var line = "\"%s\" -p --strict-mcp-config --mcp-config \"%s\" --allowedTools \"%s\"" % [_win(command), _win(mcp_path), PoolStringArray(allowed).join(" ")]
		if model != "":
			line += " --model \"%s\"" % model
		line += " < \"%s\" > \"%s\" 2>&1" % [_win(prompt_path), _win(log_path)]
		# Its lines are read as UTF-8 (a user folder with accents).
		Util.write_text(DIR + "/run.cmd", "@echo off\r\nchcp 65001 >nul\r\nset DISABLE_AUTOUPDATER=1\r\n" + line + "\r\n")
		# wscript has no console of its own: it runs the launcher with its window
		# hidden and waits for it, so no terminal window opens. cmd.exe directly
		# when it cannot start.
		Util.write_text(DIR + "/run.vbs", "CreateObject(\"WScript.Shell\").Run \"\"\"\" & WScript.Arguments(0) & \"\"\"\", 0, True\r\n")
		var launcher = _win(ProjectSettings.globalize_path(DIR + "/run.cmd"))
		pid = OS.execute("wscript.exe", ["//B", "//Nologo", _win(ProjectSettings.globalize_path(DIR + "/run.vbs")), launcher], false)
		if pid <= 0:
			pid = OS.execute("cmd.exe", ["/c", launcher], false)
	else:
		var script = "export DISABLE_AUTOUPDATER=1; exec \"$0\" -p --strict-mcp-config --mcp-config \"$1\" --allowedTools \"$2\" ${3:+--model \"$3\"} < \"$4\" > \"$5\" 2>&1"
		pid = OS.execute("/bin/sh", ["-c", script, command, mcp_path, PoolStringArray(allowed).join(" "), model, prompt_path, log_path], false)
	if pid <= 0:
		return {"ok": false, "error": "could not start %s" % command}
	return {"ok": true, "pid": pid, "log": log_path, "command": command}


static func _win(path: String) -> String:
	return path.replace("/", "\\")


# The end of the agent's log (why it stopped), or "".
static func log_tail(log_path: String, chars: int = 300) -> String:
	var text = Util.read_text(log_path)
	if not (text is String):
		return ""
	text = text.strip_edges()
	return ("..." + text.substr(text.length() - chars)) if text.length() > chars else text


# On Windows the pid is the launcher's, so the whole process tree goes.
static func stop(pid: int) -> void:
	if OS.get_name() == "Windows":
		OS.execute("taskkill", ["/T", "/F", "/PID", str(pid)], false)
	else:
		OS.kill(pid)
