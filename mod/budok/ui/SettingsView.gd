extends Reference

# All budok settings as tabs, built from one field table so the same UI can be
# placed in the game's Mod List window (ui/ModMenuHook.gd) and in the F8
# overlay (ui/Panel.gd). Every value in user://budok/config.json that is safe
# to edit has a field here.

const Util = preload("res://budok/core/Util.gd")
const CONTROLLERS := ["human", "mcp", "ai", "decision"]
const PROVIDERS := ["anthropic", "openai", "openrouter", "local"]
const DECISION_PROVIDERS := [["vercel", "Vercel AI Gateway"], ["typesafe", "TypeSafe"]]
const EFFORTS := ["", "low", "medium", "high", "xhigh", "max"]
const AUTO_WHEN := [["matches", "Only before matches"], ["connect", "On boot and when a chatbot connects"]]
const ROLE_FIELDS := [
	["provider", "Provider", "option", PROVIDERS],
	["model", "Model", "string"],
	["effort", "Effort (Anthropic)", "option", EFFORTS],
	["max_tokens", "Max output tokens", "int", [256, 128000]],
	["max_steps", "Max tool steps", "int", [1, 100]],
	["request_timeout_s", "Request timeout (s)", "int", [10, 3600]],
	["temperature", "Temperature (OpenAI-compatible; empty = default)", "float_or_null"],
	["refusal_fallback", "Refusal fallback (Claude API)", "bool"],
]

var runtime = null
var _fields := {}
var _status: Label = null
var _messages := []
var _token_edit: LineEdit = null
var _char_picker: OptionButton = null
var _char_status: Label = null
var _auto_rows := []


func _init(runtime_ref) -> void:
	runtime = runtime_ref


# Adds one tab per section to `tabs` (a TabContainer).
func build_into(tabs: TabContainer) -> void:
	tabs.add_child(_connect_tab())
	tabs.add_child(_players_tab())
	tabs.add_child(_ai_tab())
	tabs.add_child(_providers_tab())
	tabs.add_child(_characters_tab())
	tabs.add_child(_advanced_tab())
	refresh()


func refresh() -> void:
	for path in _fields:
		var field = _fields[path]
		if field["type"] != "secret":
			_set_value(field, runtime.config.get_value(path))
	if Util.valid(_token_edit):
		_token_edit.text = str(runtime.config.get_value("mcp.auth_token", ""))
	_on_auto_toggled(bool(runtime.config.get_value("schemas.auto.enabled", true)))
	refresh_characters()
	refresh_status()


func refresh_status() -> void:
	if not Util.valid(_status):
		return
	var status = runtime.status()
	var match_status = status["match"]
	var lines = [
		"budok %s | game %s" % [status["budok_version"], status["game_version"]],
		"MCP: %s (%s, %d session(s))" % [status["mcp"]["url"],
			"listening" if status["mcp"]["listening"] else "NOT listening: " + str(runtime.server_state.get("error", "")),
			status["mcp"]["sessions"]],
	]
	if match_status["blocked_reason"] != "":
		lines.append("Match: not controlled (%s)" % match_status["blocked_reason"])
	elif match_status["in_match"]:
		lines.append("Match: %s vs %s, tick %d" % [match_status["characters"]["p1"], match_status["characters"]["p2"], match_status.get("tick", 0)])
	else:
		lines.append("Match: none")
	lines.append("Controllers: P1 %s%s, P2 %s%s" % [
		match_status["controllers"]["p1"], " (claimed)" if match_status["claimed_by"]["p1"] else "",
		match_status["controllers"]["p2"], " (claimed)" if match_status["claimed_by"]["p2"] else ""])
	var auto = status["ai"]["autopilot"]
	if auto["turns"] > 0 or auto["last_error"] != "":
		lines.append("AI: %d turns, %d fallbacks, %d/%d tokens in/out" % [auto["turns"], auto["fallbacks"], auto["input_tokens"], auto["output_tokens"]])
		if auto["last_error"] != "":
			lines.append("AI last error: " + auto["last_error"])
	var decider = status["ai"]["decision_player"]
	if decider["turns"] > 0 or decider["last_error"] != "":
		lines.append("Decision model: %d turns, %d calls, %d lines, %d fallbacks%s" % [decider["turns"], decider["calls"], decider["lines"], decider["fallbacks"],
			(", last: " + decider["last_decision"]) if decider["last_decision"] != "" else ""])
		if decider["last_error"] != "":
			lines.append("Decision model last error: " + decider["last_error"])
	var agent = status.get("notes_agent", {})
	if agent.get("state", "idle") != "idle":
		lines.append("Notes agent: %s%s" % [agent["state"], (": " + agent["error"]) if agent.has("error") else ""])
	for job in status["schema_jobs"]:
		if job["status"] in ["queued", "assigned", "running"]:
			lines.append("Notes for %s: %s%s %s" % [job["character"], job["status"], (" by " + {"agent": "notes agent", "player": "playing chatbot", "api": "in-game AI"}.get(job.get("worker", ""), "")) if job.get("worker", "") != "" else "", job.get("progress", "")])
	for job in status["annotation_jobs"]:
		if job["status"] == "running":
			lines.append("In-game AI writing notes for %s: %s" % [job["character"], job["progress"]])
	_status.text = PoolStringArray(lines).join("\n")


# --- tabs ---

func _connect_tab() -> Control:
	var box = _tab("Connect")
	_status = Label.new()
	_status.autowrap = true
	box.add_child(_status)
	_token_edit = LineEdit.new()
	_token_edit.secret = true
	_token_edit.editable = false
	box.add_child(_row("Token", _token_edit))
	box.add_child(_buttons([["Show / hide token", "_on_show_token"], ["Copy URL + token", "_on_copy_url"], ["New token", "_on_new_token"]]))
	box.add_child(_buttons([["Copy Claude Code command", "_on_copy_code"], ["Copy Claude Desktop config", "_on_copy_desktop"]]))
	box.add_child(_buttons([["Copy Desktop config (Node.js)", "_on_copy_desktop_node"]]))
	box.add_child(_hint("Point any MCP client at the URL with the token (Authorization: Bearer <token>, or ?token=). Web chatbots need a public HTTPS tunnel to this port; keep the token secret."))
	_field(box, "mcp.enabled", "Run MCP server", "bool")
	_field(box, "mcp.port", "Port", "int", [1024, 65535])
	_field(box, "mcp.require_token", "Require token", "bool")
	_field(box, "mcp.max_wait_s", "Max long-poll wait (s)", "int", [1, 50])
	box.add_child(_buttons([["Save and restart server", "_on_save_restart"]]))
	return _end_tab(box)


func _players_tab() -> Control:
	var box = _tab("Players")
	_field(box, "controllers.p1", "P1 controller", "option", CONTROLLERS)
	_field(box, "controllers.p2", "P2 controller", "option", CONTROLLERS)
	box.add_child(_hint("human: you play it. mcp: a connected chatbot plays it (you can still play it until one claims the slot). ai: the API-key chat model from the AI tab. "
		+ "decision: the decision model from the AI tab (such as Jev), which simulates turns ahead. Applies now and to matches started from the menu."))
	_field(box, "turns.forced_turns", "Auto-hold when Hold is the only option", "option", ["never", "skip_unless_hurt", "always"])
	_field(box, "turns.timeout_s.ai", "AI turn timeout (s, 0 = none)", "int", [0, 3600])
	_field(box, "turns.timeout_s.decision", "Decision model turn timeout (s, 0 = none)", "int", [0, 3600])
	_field(box, "turns.timeout_s.mcp", "MCP turn timeout (s, 0 = none)", "int", [0, 3600])
	_field(box, "turns.fallback_action", "Fallback move on timeout", "string")
	_field(box, "turns.hide_bot_panel", "Hide a bot's move panel", "bool")
	_field(box, "turns.history_length", "Turn history shown to bots", "int", [1, 60])
	_field(box, "simulation.enabled", "Allow simulations", "bool")
	_field(box, "simulation.max_ticks", "Simulation look-ahead (ticks)", "int", [10, 300])
	box.add_child(_save_row())
	return _end_tab(box)


func _ai_tab() -> Control:
	var box = _tab("AI")
	for role in ["play", "annotate"]:
		box.add_child(_header("Move making (token mode)" if role == "play" else "Schema creation"))
		var prefix = "ai.%s." % role
		for spec in ROLE_FIELDS:
			_field(box, prefix + spec[0], spec[1], spec[2], spec[3] if spec.size() > 3 else null)
		if role == "play":
			_field(box, prefix + "allow_simulation", "May simulate", "bool")
			_field(box, prefix + "max_simulations", "Simulations per turn", "int", [0, 20])
			_field(box, prefix + "memory_turns", "Remembered turns", "int", [0, 50])
			_field(box, prefix + "reflect_after_match", "Save lessons after each match", "bool")
			_field(box, prefix + "style", "Play style (free text)", "string")
			_field(box, prefix + "risk", "Risk", "option", ["cautious", "balanced", "reckless"])
		else:
			_field(box, prefix + "batch_size", "Moves per batch", "int", [1, 50])
			_field(box, prefix + "include_source", "Send code of code-driven moves", "bool")
			_field(box, prefix + "max_source_chars", "Max code characters per move", "int", [500, 50000])
	box.add_child(_header("Decision model (controller: decision)"))
	_field(box, "ai.decide.provider", "Provider", "option", DECISION_PROVIDERS)
	_field(box, "ai.decide.model", "Model", "string")
	_field(box, "ai.decide.depth", "Turns each line looks ahead (0 = no simulations)", "int", [0, 30])
	_field(box, "ai.decide.threads", "Lines simulated at once", "int", [1, 16])
	_field(box, "ai.decide.candidates", "Own moves compared", "int", [1, 16])
	_field(box, "ai.decide.replies", "Opponent replies tested per move", "int", [1, 8])
	_field(box, "ai.decide.max_options", "Options per question", "int", [2, 255])
	_field(box, "ai.decide.pick", "Pick", "option", [["sample", "Draw from its probabilities"], ["best", "Always the likeliest"]])
	_field(box, "ai.decide.think_s", "Thinking time per turn (s)", "int", [3, 600])
	_field(box, "ai.decide.request_timeout_s", "Request timeout (s)", "int", [2, 300])
	_field(box, "ai.decide.frame_budget_ms", "Simulation time per frame (ms; higher thinks faster, game less smooth)", "int", [1, 100])
	_field(box, "ai.decide.max_rpm", "Requests per minute (0 = no limit; free tiers: 5)", "int", [0, 10000])
	box.add_child(_hint("Each turn the model ranks your moves and guesses the opponent's, budok plays your best candidates on the real engine "
		+ "against its likeliest replies, and each line plays on with the model choosing both fighters' moves. A last call picks the move from those results. "
		+ "One call per turn of each line: depth 10 with 4 lines is about 40 calls a turn. Under a requests-per-minute limit "
		+ "(set here, or learned from the provider's rate-limit errors) the lines get shorter to fit."))
	box.add_child(_save_row())
	return _end_tab(box)


func _providers_tab() -> Control:
	var box = _tab("Providers")
	box.add_child(_hint("Keys are stored in user://budok/config.json and never shown again. Leave a key empty to keep it (or to use the environment variable)."))
	for provider in PROVIDERS + ["vercel", "typesafe"]:
		box.add_child(_header(provider))
		if provider != "local":
			_field(box, "ai.providers.%s.api_key" % provider, "API key", "secret")
			_field(box, "ai.providers.%s.api_key_env" % provider, "Key environment variable", "string")
		_field(box, "ai.providers.%s.base_url" % provider, "Base URL", "string")
	box.add_child(_save_row())
	return _end_tab(box)


func _characters_tab() -> Control:
	var box = _tab("Characters")
	_char_picker = OptionButton.new()
	_char_picker.clip_text = true
	_char_picker.connect("item_selected", self, "_on_character_selected")
	box.add_child(_row("Character", _char_picker))
	_char_status = Label.new()
	_char_status.autowrap = true
	box.add_child(_char_status)
	box.add_child(_buttons([["Generate notes with AI", "_on_generate"], ["Export", "_on_export"], ["Refresh", "_on_refresh_characters"], ["Clear memories", "_on_clear_memories"]]))
	box.add_child(_header("Automatic notes"))
	_field(box, "schemas.auto.enabled", "Write missing character notes automatically", "bool")
	_auto_rows = [
		_field(box, "schemas.auto.when", "When", "option", AUTO_WHEN),
		_field(box, "schemas.auto.match_start", "At match start, write notes for both characters if missing (bots wait for them)", "bool"),
		_field(box, "schemas.auto.use_agent", "Separate notes agent (its own context)", "bool"),
		_field(box, "schemas.auto.agent_command", "Claude Code command for it", "string"),
		_field(box, "schemas.auto.agent_model", "Agent model (empty = Claude Code default)", "string"),
		_field(box, "schemas.auto.use_api", "In-game AI with your API key", "bool"),
		_field(box, "schemas.auto.use_player", "The chatbot that is playing (only if no notes agent is available)", "bool"),
		_hint("The notes agent is Claude Code, which budok starts in the background with your Claude login (install it first), or a second chat you open "
			+ "with budok's notes_worker prompt. Either has its own context, so the chat that plays never writes notes. The in-game AI needs an API key (Providers)."),
	]
	box.add_child(_auto_rows[_auto_rows.size() - 1])
	_fields["schemas.auto.enabled"]["control"].connect("toggled", self, "_on_auto_toggled")
	_field(box, "schemas.registry_enabled", "Community registry (opt-in)", "bool")
	_field(box, "schemas.registry_url", "Registry URL (https)", "string")
	box.add_child(_buttons([["Fetch from registry", "_on_fetch_registry"], ["Save", "_on_save"]]))
	return _end_tab(box)


func _advanced_tab() -> Control:
	var box = _tab("Advanced")
	_field(box, "mcp.host", "Listen address (keep 127.0.0.1)", "string")
	_field(box, "mcp.allowed_origins", "Extra allowed browser origins (comma separated)", "list")
	_field(box, "source_access.enabled", "Bots may read game/mod scripts", "bool")
	_field(box, "source_access.max_file_bytes", "Max file size to read", "int", [1000, 5000000])
	_field(box, "logging.match_logs", "Write match logs", "bool")
	_field(box, "memory.enabled", "Bots keep memories between matches", "bool")
	_field(box, "memory.shown_per_match", "Memories shown at match start", "int", [0, 30])
	_field(box, "automation.script", "Automation script (GDScript path)", "string")
	_field(box, "ui.show_button", "Show the corner budok button", "bool")
	_field(box, "ui.toggle_key", "Overlay toggle key", "string")
	_field(box, "ui.show_on_start", "Open overlay on start", "bool")
	box.add_child(_hint("Server address changes apply after 'Save and restart server' on the Connect tab; automation changes after restarting the game."))
	box.add_child(_save_row())
	return _end_tab(box)


# --- actions ---

func _on_save() -> void:
	_save_fields()
	_say("Settings saved.")


func _on_save_restart() -> void:
	_save_fields()
	var result = runtime.restart_server()
	_say("Saved. Server: %s" % (result.get("url", "") if result.get("ok", false) else result.get("error", "")))
	refresh_status()


func _save_fields() -> void:
	for path in _fields:
		var field = _fields[path]
		var value = _get_value(field)
		if field["type"] == "secret":
			if str(value) == "":
				continue
			field["control"].text = ""
			field["control"].placeholder_text = "saved (hidden)"
		runtime.config.set_value(path, value)
	runtime.config.save()
	for slot in ["p1", "p2"]:
		runtime.matches.set_controller(slot, str(runtime.config.get_value("controllers." + slot, "human")))
	runtime.emit_signal("status_changed")


func _on_show_token() -> void:
	_token_edit.secret = not _token_edit.secret


func _on_copy_url() -> void:
	OS.set_clipboard("%s?token=%s" % [runtime.mcp.url(), runtime.config.get_value("mcp.auth_token", "")])
	_say("Copied URL with token.")


func _on_new_token() -> void:
	runtime.config.set_value("mcp.auth_token", Util.random_hex(16))
	runtime.config.save()
	_token_edit.text = str(runtime.config.get_value("mcp.auth_token", ""))
	_say("New token generated; reconnect your MCP clients.")


# Uses the bundled Python bridge (installed next to the config by Runtime),
# so no Node.js is needed.
func _on_copy_desktop() -> void:
	if runtime.bridge_path == "":
		_on_copy_desktop_node()
		return
	var python = "python" if OS.get_name() == "Windows" else "python3"
	# The bridge sits next to budok's config and reads the token and port from
	# it, so the copied config never goes stale when the token changes.
	var snippet = {"mcpServers": {"budok": {"command": python, "args": [runtime.bridge_path]}}}
	OS.set_clipboard(Util.json_str(snippet, false, "  "))
	_say("Copied a claude_desktop_config.json snippet (needs Python 3; no token inside, the bridge reads it from the game). Merge its mcpServers entry into your config and restart Claude Desktop.")


func _on_copy_desktop_node() -> void:
	var snippet = {"mcpServers": {"budok": {"command": "npx", "args": ["-y", "mcp-remote",
		"%s?token=%s" % [runtime.mcp.url(), runtime.config.get_value("mcp.auth_token", "")], "--transport", "http-only", "--allow-http"]}}}
	OS.set_clipboard(Util.json_str(snippet, false, "  "))
	_say("Copied a claude_desktop_config.json snippet (uses mcp-remote; needs Node.js on the PATH Claude sees).")


func _on_copy_code() -> void:
	OS.set_clipboard("claude mcp add --transport http budok %s --header \"Authorization: Bearer %s\"" % [
		runtime.mcp.url(), runtime.config.get_value("mcp.auth_token", "")])
	_say("Copied a `claude mcp add` command.")


func _on_generate() -> void:
	var entry = _selected_entry()
	if entry == null:
		return
	var loaded = runtime.roster.ensure_loaded(entry)
	if not loaded["ok"]:
		_say(loaded["error"])
		return
	var result = runtime.annotator.start(entry, false)
	_say(str(result.get("message", result.get("error", "started"))))


func _on_export() -> void:
	var entry = _selected_entry()
	if entry == null or not entry["loaded"]:
		_say("Load the character first (start a match with it).")
		return
	var result = runtime.schemas.export_schema(entry)
	if result.get("ok", false):
		_say("Exported to %s\n%s" % [result.get("absolute_path", ""), result.get("install_hint", "")])
	else:
		_say(str(result.get("error", "")))


func _on_fetch_registry():
	var entry = _selected_entry()
	if entry == null or not entry["loaded"]:
		_say("Load the character first (start a match with it).")
		return
	_say("Fetching...")
	var result = yield(runtime.fetch_registry(entry), "completed")
	_say("Registry: %s" % (str(result.get("coverage", "")) if result.get("ok", false) else str(result.get("error", ""))))
	_on_character_selected(_char_picker.selected)


func _on_auto_toggled(on: bool) -> void:
	for row in _auto_rows:
		if Util.valid(row):
			row.visible = on


func _on_clear_memories() -> void:
	var entry = _selected_entry()
	if entry == null:
		return
	_say("Deleted %d memories about %s." % [runtime.memory.clear_for(entry["display_name"]), entry["display_name"]])
	_on_character_selected(_char_picker.selected)


func _on_refresh_characters() -> void:
	runtime.introspector.clear_cache()
	runtime.schemas.invalidate()
	refresh_characters()


func refresh_characters() -> void:
	if not Util.valid(_char_picker):
		return
	var previous = _char_picker.get_item_text(_char_picker.selected) if _char_picker.selected >= 0 else ""
	_char_picker.clear()
	var index = 0
	for entry in runtime.roster.list():
		_char_picker.add_item(entry["display_name"])
		_char_picker.set_item_metadata(index, entry["name"])
		if entry["display_name"] == previous:
			_char_picker.select(index)
		index += 1
	_on_character_selected(_char_picker.selected)


func _on_character_selected(_index: int) -> void:
	var entry = _selected_entry()
	if entry == null:
		_char_status.text = "No characters yet (they appear once the game has loaded its roster)."
		return
	if not entry["loaded"]:
		_char_status.text = "%s (%s): not loaded yet; it loads when a match with it starts." % [entry["display_name"], entry["source"]]
		return
	var info = runtime.schemas.describe(entry)
	if not info["skeleton"].get("ok", false):
		_char_status.text = "Cannot read %s: %s" % [entry["display_name"], info["skeleton"].get("error", "")]
		return
	_char_status.text = "%s (%s)\nNotes: %s%s, %d/%d moves annotated%s\nMemories: %d\n%s" % [
		entry["display_name"], entry["source"], info["status"], " (STALE: character changed)" if info["stale"] else "",
		info["coverage"]["annotated"], info["coverage"]["total"], ", has summary" if info["coverage"]["has_summary"] else "",
		runtime.memory.count_for(entry["display_name"]), info["schema_path"]]


func _selected_entry():
	if not Util.valid(_char_picker) or _char_picker.get_item_count() == 0 or _char_picker.selected < 0:
		return null
	return runtime.roster.resolve(str(_char_picker.get_item_metadata(_char_picker.selected)))


# --- widgets ---

func _field(box: Control, path: String, label: String, type: String, options = null) -> Control:
	var control = null
	match type:
		"bool":
			control = CheckBox.new()
		"int":
			control = SpinBox.new()
			control.min_value = options[0]
			control.max_value = options[1]
		"option":
			control = OptionButton.new()
			control.clip_text = true
			for item in options:
				var item_value = item[0] if item is Array else item
				control.add_item(item[1] if item is Array else (item if item != "" else "(default)"))
				control.set_item_metadata(control.get_item_count() - 1, item_value)
		"secret":
			control = LineEdit.new()
			control.secret = true
			control.placeholder_text = "saved (hidden)" if str(runtime.config.get_value(path, "")) != "" else "not set"
		_:
			control = LineEdit.new()
	_fields[path] = {"type": type, "control": control}
	var row = _row(label, control)
	box.add_child(row)
	return row


func _set_value(field: Dictionary, value) -> void:
	var control = field["control"]
	match field["type"]:
		"bool":
			control.pressed = bool(value)
		"int":
			control.value = float(value) if value != null else control.min_value
		"option":
			for i in range(control.get_item_count()):
				if str(control.get_item_metadata(i)) == str(value if value != null else ""):
					control.select(i)
		"list":
			control.text = PoolStringArray(value if value is Array else []).join(", ")
		"float_or_null":
			control.text = "" if value == null else str(value)
		_:
			control.text = "" if value == null else str(value)


func _get_value(field: Dictionary):
	var control = field["control"]
	match field["type"]:
		"bool":
			return control.pressed
		"int":
			return int(control.value)
		"option":
			return control.get_item_metadata(control.selected)
		"list":
			var items = []
			for part in control.text.split(","):
				if part.strip_edges() != "":
					items.append(part.strip_edges())
			return items
		"float_or_null":
			return float(control.text) if control.text.strip_edges().is_valid_float() else null
	return control.text.strip_edges()


func _tab(title: String) -> VBoxContainer:
	var box = VBoxContainer.new()
	box.name = title
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return box


# Each tab is a scroll area with a message line under it, so results stay in
# view however far the tab is scrolled. Horizontal scrolling stays on so the
# content's width never stretches the window (the game draws at 640x360).
func _end_tab(box: VBoxContainer) -> Control:
	var tab = VBoxContainer.new()
	tab.name = box.name
	var scroll = ScrollContainer.new()
	scroll.follow_focus = true
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.name = "Content"
	scroll.add_child(box)
	tab.add_child(scroll)
	var message = Label.new()
	message.autowrap = true
	message.visible = false
	tab.add_child(message)
	_messages.append(message)
	return tab


func _save_row() -> Control:
	return _buttons([["Save", "_on_save"]])


# Label and control share the row, so it fits narrow windows; long labels wrap.
func _row(label_text: String, control: Control) -> HBoxContainer:
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = label_text
	label.autowrap = true
	label.valign = Label.VALIGN_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	if control is CheckBox:
		# Kept at its own size (the game's theme draws a dark box behind it).
		var holder = HBoxContainer.new()
		holder.add_child(control)
		control = holder
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


# Buttons wrap onto more lines when the window is narrow.
func _buttons(specs: Array) -> Container:
	var row = ClassDB.instance("HFlowContainer") if ClassDB.class_exists("HFlowContainer") else HBoxContainer.new()
	for spec in specs:
		var button = Button.new()
		button.text = spec[0]
		button.connect("pressed", self, spec[1])
		row.add_child(button)
	return row


func _header(text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.modulate = Color(1.0, 0.8, 0.35)
	return label


func _hint(text: String) -> Label:
	var label = Label.new()
	label.autowrap = true
	label.text = text
	return label


func _say(text: String) -> void:
	for message in _messages:
		if Util.valid(message):
			message.text = text
			message.visible = text != ""
