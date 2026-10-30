extends Reference

# Starts command-line AI agents that work through budok's MCP server with
# the player's own login of that program (a Claude, ChatGPT or Google
# subscription): Claude Code, Codex CLI, Gemini CLI, or a command of your
# own. They run headless and without a window, the prompt goes in on stdin
# and everything they print goes to a log. Used by the notes agent
# (core/NotesAgent.gd) and the agents that play (ai/AgentDispatch.gd).

const Util = preload("res://budok/core/Util.gd")
# [id, label, command]. Claude Code is the tested one; the others follow
# their documented headless use.
const PRESETS := [["claude", "Claude Code (Claude subscription)", "claude"], ["codex", "Codex CLI (ChatGPT subscription)", "codex"],
	["gemini", "Gemini CLI (Google account)", "gemini"], ["custom", "Your own command", ""]]
# The name budok's server has in the Codex CLI runs it starts.
const CODEX_SERVER := "budok_agent"
# Placeholders a custom command may use.
const PLACEHOLDERS := ["{mcp_url}", "{mcp_config}", "{model}", "{prompt_file}", "{dir}"]


# Full path of an agent command, or "" when it cannot be found. A game
# started by Steam often has a shorter PATH than your shell, so the usual
# install folders are searched too.
static func resolve(command: String) -> String:
	command = command.strip_edges()
	if command == "":
		return ""
	if command.find("/") != -1 or command.find("\\") != -1:
		return command if Util.file_exists(command) else ""
	var windows = OS.get_name() == "Windows"
	var dirs = []
	for dir in OS.get_environment("PATH").split(";" if windows else ":"):
		if dir != "":
			dirs.append(dir)
	var home = OS.get_environment("USERPROFILE" if windows else "HOME")
	if home != "":
		for dir in [".local/bin", ".claude/local", ".npm-global/bin", "bin", "AppData/Roaming/npm", ".bun/bin"]:
			dirs.append(home.plus_file(dir))
	for dir in ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]:
		dirs.append(dir)
	var names = [command + ".exe", command + ".cmd", command] if windows else [command]
	for dir in dirs:
		for name in names:
			if Util.file_exists(dir.plus_file(name)):
				return dir.plus_file(name)
	return ""


static func default_command(cli: String) -> String:
	for preset in PRESETS:
		if preset[0] == cli:
			return preset[2]
	return ""


static func label(cli: String) -> String:
	for preset in PRESETS:
		if preset[0] == cli:
			return preset[1]
	return cli


# The program and arguments for one agent run, and the files it needs
# written: {"ok", "command", "args", "env", "cwd", "files": {path: text}} or
# {"ok": false, "error"}. spec: {"cli", "command" (its full path), "model",
# "url" (budok's MCP address, with the agent's ticket), "token" (the MCP
# token, or ""), "dir" (a user:// folder of its own), "tools" (budok tools it
# may use, for Claude Code), "custom" (the custom command template)}.
static func command_line(spec: Dictionary) -> Dictionary:
	var model = str(spec.get("model", "")).strip_edges()
	var plain = RegEx.new()
	plain.compile("^[A-Za-z0-9._:\\[\\]/-]*$")
	if plain.search(model) == null:
		return {"ok": false, "error": "the agent model may only contain letters, digits and . _ : - / [ ]"}
	var dir = ProjectSettings.globalize_path(str(spec["dir"]))
	var url = str(spec["url"])
	var token = str(spec.get("token", ""))
	# Clients that cannot send headers pass the token in the address.
	var url_with_token = url + ("&token=" + token if token != "" else "")
	var headers = {"Authorization": "Bearer " + token} if token != "" else {}
	var mcp_config = dir.plus_file("mcp.json")
	var files = {mcp_config: Util.json_str({"mcpServers": {"budok": {"type": "http", "url": url, "headers": headers}}})}
	var out = {"ok": true, "command": str(spec["command"]), "args": [], "env": {}, "cwd": dir, "files": files}
	match str(spec.get("cli", "claude")):
		"claude":
			var allowed = []
			for tool_name in spec.get("tools", []):
				allowed.append("mcp__budok__" + tool_name)
			out["args"] = ["-p", "--strict-mcp-config", "--mcp-config", mcp_config, "--allowedTools", PoolStringArray(allowed).join(" "),
				"--output-format", "stream-json", "--verbose"]
			if model != "":
				out["args"] += ["--model", model]
			out["env"] = {"DISABLE_AUTOUPDATER": "1"}
		"codex":
			# budok's server gets a name of its own: the player's config.toml may
			# have a "budok" entry of its own (say the stdio bridge), which -c would
			# merge into. Entries there that lead to budok are off for this run, so
			# the agent has only its own session. A value -c cannot read as TOML is
			# taken as a plain string.
			out["args"] = ["exec", "--skip-git-repo-check", "--json", "--sandbox", "read-only", "-c", "approval_policy=never",
				"-c", "mcp_servers.%s.url=%s" % [CODEX_SERVER, url_with_token], "-c", "mcp_servers.%s.tool_timeout_sec=180" % CODEX_SERVER]
			for name in codex_budok_servers(_read_codex_config()):
				out["args"] += ["-c", "mcp_servers.%s.enabled=false" % name]
			if model != "":
				out["args"] += ["-m", model]
			out["args"].append("-")
		"gemini":
			# Its MCP servers come from a settings file: the run's own folder's, and the
			# same file as system settings where that is supported.
			var settings = dir.plus_file(".gemini").plus_file("settings.json")
			files[settings] = Util.json_str({"mcpServers": {"budok": {"httpUrl": url_with_token, "trust": true, "timeout": 180000}}})
			out["args"] = ["--output-format", "stream-json", "--allowed-mcp-server-names", "budok"]
			if model != "":
				out["args"] += ["-m", model]
			out["env"] = {"GEMINI_CLI_SYSTEM_SETTINGS_PATH": settings}
		"custom":
			var words = split_words(str(spec.get("custom", "")))
			if words.empty():
				return {"ok": false, "error": "set the custom agent command (agents.custom_command)"}
			var values = {"{mcp_url}": url_with_token, "{mcp_config}": mcp_config, "{model}": model,
				"{prompt_file}": dir.plus_file("prompt.txt"), "{dir}": dir}
			for i in range(words.size()):
				for key in values:
					words[i] = words[i].replace(key, values[key])
			out["command"] = resolve(words[0])
			if out["command"] == "":
				return {"ok": false, "error": "%s was not found" % words[0]}
			out["args"] = words.slice(1, words.size() - 1) if words.size() > 1 else []
		_:
			return {"ok": false, "error": "unknown agent program %s" % str(spec.get("cli"))}
	return out


# The player's Codex config.toml ($CODEX_HOME, else ~/.codex), or "".
static func _read_codex_config() -> String:
	var home = OS.get_environment("CODEX_HOME")
	if home == "":
		var user = OS.get_environment("USERPROFILE" if OS.get_name() == "Windows" else "HOME")
		home = user.plus_file(".codex") if user != "" else ""
	var text = Util.read_text(home.plus_file("config.toml")) if home != "" else null
	return text if text is String else ""


# The MCP servers in a Codex config.toml that lead to budok: named budok, or
# running its bridge or pointing at its port.
static func codex_budok_servers(toml: String) -> Array:
	var out = []
	var current = ""
	var header = RegEx.new()
	header.compile("^\\s*\\[\\s*mcp_servers\\.(\"?)([A-Za-z0-9_-]+)\\1\\s*(\\.[^\\]]*)?\\]")
	for line in toml.split("\n"):
		var stripped = line.strip_edges()
		if stripped.begins_with("["):
			var found = header.search(stripped)
			current = found.get_string(2) if found != null and found.get_string(3) == "" else ""
			if current != "" and current != CODEX_SERVER and current.to_lower().find("budok") != -1 and not (current in out):
				out.append(current)
			continue
		if current != "" and current != CODEX_SERVER and not (current in out):
			var lower = stripped.to_lower()
			if lower.find("budok_stdio") != -1 or lower.find(":8765") != -1:
				out.append(current)
	return out


# A command line split into words: spaces separate them, "double quotes"
# keep spaces inside one.
static func split_words(text: String) -> Array:
	var words = []
	var word = ""
	var quoted = false
	var started = false
	for i in range(text.length()):
		var c = text[i]
		if c == "\"":
			quoted = not quoted
			started = true
		elif (c == " " or c == "\t") and not quoted:
			if started:
				words.append(word)
			word = ""
			started = false
		else:
			word += c
			started = true
	if started:
		words.append(word)
	return words


# Starts `command` with `args` and `env`, in `cwd`, its stdin from
# stdin_path and its output (both streams) to log_path, without a window.
# name: the launcher's file name in dir. Returns the pid, or -1.
static func launch(dir: String, name: String, command: String, args: Array, env: Dictionary, stdin_path: String, log_path: String,
		cwd: String = "") -> int:
	Util.ensure_dir(dir)
	if OS.get_name() == "Windows":
		var lines = ["@echo off", "chcp 65001 >nul"]
		if cwd != "":
			lines.append("cd /d %s" % _quoted(_win(cwd)))
		for key in env:
			lines.append("set %s" % _quoted("%s=%s" % [key, env[key]]))
		var line = _quoted(_win(command))
		for arg in args:
			line += " " + _quoted(str(arg))
		line += " < %s > %s 2>&1" % [_quoted(_win(stdin_path)), _quoted(_win(log_path))]
		lines.append(line)
		# Its lines are read as UTF-8 (a user folder with accents).
		var launcher = _win(ProjectSettings.globalize_path(dir.plus_file(name + ".cmd")))
		Util.write_text(dir.plus_file(name + ".cmd"), PoolStringArray(lines).join("\r\n") + "\r\n")
		# wscript has no console of its own: it runs the launcher with its window
		# hidden and waits for it, so no terminal window opens. cmd.exe directly
		# when it cannot start.
		Util.write_text(dir.plus_file("run.vbs"), "CreateObject(\"WScript.Shell\").Run \"\"\"\" & WScript.Arguments(0) & \"\"\"\", 0, True\r\n")
		var pid = OS.execute("wscript.exe", ["//B", "//Nologo", _win(ProjectSettings.globalize_path(dir.plus_file("run.vbs"))), launcher], false)
		if pid <= 0:
			pid = OS.execute("cmd.exe", ["/c", launcher], false)
		return pid
	# sh gets every value as a separate argument, so nothing in them is parsed
	# as shell code; env sets the variables.
	var script = "cd \"$1\" 2>/dev/null; input=\"$2\"; output=\"$3\"; shift 3; exec \"$@\" < \"$input\" > \"$output\" 2>&1"
	var argv = ["-c", script, "sh", cwd if cwd != "" else ".", stdin_path, log_path, "env"]
	for key in env:
		argv.append("%s=%s" % [key, env[key]])
	argv.append(command)
	argv += args
	return OS.execute("/bin/sh", argv, false)


# On Windows the pid is the launcher's, so the whole process tree goes.
static func stop(pid: int) -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		OS.execute("taskkill", ["/T", "/F", "/PID", str(pid)], false)
	else:
		OS.kill(pid)


static func _win(path: String) -> String:
	return path.replace("/", "\\")


# One argument for a Windows launcher line: quoted, quotes escaped for the
# program, and % doubled for the batch file.
static func _quoted(value: String) -> String:
	value = value.replace("\"", "\\\"").replace("%", "%%")
	if value.ends_with("\\"):
		value += "\\"
	return "\"%s\"" % value


# What one line of an agent's log says, for the agent window: {"kind": text
# (the agent's own words), status (a run ended) or log (anything else it
# printed, such as an error), "text", "delta"? (part of a message that
# continues)}, or {} for lines with nothing to show (tool calls are shown
# from the server's side). Reads Claude Code, Codex CLI and Gemini CLI JSON
# lines, and plain text.
static func text_of(line: String) -> Dictionary:
	line = line.strip_edges()
	if line == "":
		return {}
	if not line.begins_with("{"):
		return {"kind": "log", "text": line}
	var parsed = JSON.parse(line)
	if parsed.error != OK:
		return {"kind": "log", "text": line}
	var value = parsed.result
	if not (value is Dictionary):
		return {}
	var kind = str(value.get("type", ""))
	# Claude Code: assistant messages with text blocks, and the run's result.
	if kind == "assistant" and value.get("message") is Dictionary:
		var texts = []
		for block in value["message"].get("content", []):
			if block is Dictionary and str(block.get("type", "")) == "text" and str(block.get("text", "")).strip_edges() != "":
				texts.append(str(block["text"]).strip_edges())
		return {"kind": "text", "text": PoolStringArray(texts).join("\n")} if not texts.empty() else {}
	if kind == "result":
		var turns = Util.as_int(value.get("num_turns", 0))
		var failed = bool(value.get("is_error", false)) or str(value.get("subtype", "success")) != "success"
		return {"kind": "status", "text": "the run ended%s%s" % [(" after %d turns" % turns) if turns > 0 else "",
			(": " + Util.truncate(str(value.get("result", value.get("subtype", ""))), 200)) if failed else ""]}
	# Codex CLI: completed items (newer) or msg events (older).
	var item = value.get("item")
	if item is Dictionary and str(item.get("type", "")) in ["agent_message", "assistant_message"]:
		return {"kind": "text", "text": str(item.get("text", "")).strip_edges()}
	var msg = value.get("msg")
	if msg is Dictionary:
		if str(msg.get("type", "")) == "agent_message":
			return {"kind": "text", "text": str(msg.get("message", "")).strip_edges()}
		if str(msg.get("type", "")) == "error":
			return {"kind": "log", "text": str(msg.get("message", ""))}
	if kind == "error":
		return {"kind": "log", "text": str(value.get("message", value.get("error", line)))}
	# Gemini CLI: assistant messages, often in parts.
	if kind == "message" and str(value.get("role", "")) == "assistant":
		return {"kind": "text", "text": str(value.get("content", "")), "delta": bool(value.get("delta", false))}
	return {}
