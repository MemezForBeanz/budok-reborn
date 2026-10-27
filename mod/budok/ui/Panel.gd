extends CanvasLayer

# In-game control panel (toggle with F8 or the corner button):
#   Connect     - MCP URL, token, ready-to-paste client configs
#   Players     - controller per slot (human / mcp / ai)
#   AI          - provider, model and behaviour for move making and for schema writing, API keys
#   Characters  - schema status, generate / export, community registry

const Util = preload("res://budok/core/Util.gd")
const CONTROLLERS := ["human", "mcp", "ai"]
const PROVIDERS := ["anthropic", "openai", "openrouter", "local"]
const EFFORTS := ["", "low", "medium", "high", "xhigh", "max"]

var runtime = null
var _root: PanelContainer = null
var _toggle: Button = null
var _status: Label = null
var _token_edit: LineEdit = null
var _controller_pickers := {}
var _fields := {}
var _char_picker: OptionButton = null
var _char_status: Label = null
var _message: Label = null
var _refresh_timer := 0.0


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	layer = 120
	_build()
	_root.visible = bool(runtime.config.get_value("ui.show_on_start", false))
	runtime.connect("status_changed", self, "_refresh")
	runtime.matches.connect("match_started", self, "_on_match_event")
	runtime.matches.connect("match_ended", self, "_on_match_event")
	_refresh()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key = OS.find_scancode_from_string(str(runtime.config.get_value("ui.toggle_key", "F8")))
		if key != 0 and event.scancode == key:
			_toggle_panel()
			get_tree().set_input_as_handled()


func _process(delta: float) -> void:
	if _root == null or not _root.visible:
		return
	_refresh_timer += delta
	if _refresh_timer >= 1.0:
		_refresh_timer = 0.0
		_refresh_status()


func _toggle_panel() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		_refresh()


func _on_match_event(_value) -> void:
	_refresh()


# --- layout ---

func _build() -> void:
	_toggle = Button.new()
	_toggle.text = "budok"
	_toggle.anchor_left = 1.0
	_toggle.anchor_right = 1.0
	_toggle.margin_left = -70
	_toggle.margin_right = -4
	_toggle.margin_top = 4
	_toggle.margin_bottom = 26
	_toggle.connect("pressed", self, "_toggle_panel")
	add_child(_toggle)

	_root = PanelContainer.new()
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.margin_left = -470
	_root.margin_right = -4
	_root.margin_top = 30
	_root.margin_bottom = 560
	add_child(_root)
	var outer = VBoxContainer.new()
	_root.add_child(outer)
	var tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(tabs)
	_message = Label.new()
	_message.autowrap = true
	outer.add_child(_message)

	tabs.add_child(_build_connect())
	tabs.add_child(_build_players())
	tabs.add_child(_build_ai())
	tabs.add_child(_build_characters())


func _build_connect() -> Control:
	var box = _tab("Connect")
	_status = Label.new()
	_status.autowrap = true
	box.add_child(_status)
	_token_edit = LineEdit.new()
	_token_edit.secret = true
	_token_edit.editable = false
	box.add_child(_row("Token", _token_edit))
	var buttons = HBoxContainer.new()
	box.add_child(buttons)
	buttons.add_child(_button("Show", "_on_show_token"))
	buttons.add_child(_button("Copy URL+token", "_on_copy_url"))
	buttons.add_child(_button("New token", "_on_new_token"))
	var configs = HBoxContainer.new()
	box.add_child(configs)
	configs.add_child(_button("Copy Claude Desktop config", "_on_copy_desktop"))
	configs.add_child(_button("Copy Claude Code command", "_on_copy_code"))
	var hint = Label.new()
	hint.autowrap = true
	hint.text = "Point any MCP client at the URL with the token (Authorization: Bearer <token>, or ?token=). Web chatbots need a public HTTPS tunnel to this port; keep the token secret."
	box.add_child(hint)
	box.add_child(_button("Restart server", "_on_restart_server"))
	return box


func _build_players() -> Control:
	var box = _tab("Players")
	for slot in ["p1", "p2"]:
		var picker = OptionButton.new()
		for controller in CONTROLLERS:
			picker.add_item(controller)
		picker.connect("item_selected", self, "_on_controller_selected", [slot])
		_controller_pickers[slot] = picker
		box.add_child(_row("%s controller" % slot.to_upper(), picker))
	var hint = Label.new()
	hint.autowrap = true
	hint.text = "human: you play it.  mcp: a connected chatbot plays it (you can still play it until one claims the slot).  ai: the API-key model from the AI tab plays it. Applies now and to matches you start from the menu."
	box.add_child(hint)
	_fields["turns.timeout_s.ai"] = _spin(0, 3600)
	box.add_child(_row("AI turn timeout (s, 0 = none)", _fields["turns.timeout_s.ai"]))
	_fields["turns.timeout_s.mcp"] = _spin(0, 3600)
	box.add_child(_row("MCP turn timeout (s, 0 = none)", _fields["turns.timeout_s.mcp"]))
	_fields["turns.hide_bot_panel"] = CheckBox.new()
	box.add_child(_row("Hide bot's move panel", _fields["turns.hide_bot_panel"]))
	_fields["simulation.enabled"] = CheckBox.new()
	box.add_child(_row("Allow simulations", _fields["simulation.enabled"]))
	box.add_child(_button("Save", "_on_save_settings"))
	return box


func _build_ai() -> Control:
	var scroll = ScrollContainer.new()
	scroll.name = "AI"
	var box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	for role in ["play", "annotate"]:
		var header = Label.new()
		header.text = "Move making (token mode)" if role == "play" else "Schema creation"
		box.add_child(header)
		var prefix = "ai.%s." % role
		_fields[prefix + "provider"] = _options(PROVIDERS)
		box.add_child(_row("Provider", _fields[prefix + "provider"]))
		_fields[prefix + "model"] = LineEdit.new()
		box.add_child(_row("Model", _fields[prefix + "model"]))
		_fields[prefix + "effort"] = _options(EFFORTS)
		box.add_child(_row("Effort (Anthropic)", _fields[prefix + "effort"]))
		_fields[prefix + "max_steps"] = _spin(1, 100)
		box.add_child(_row("Max tool steps", _fields[prefix + "max_steps"]))
		if role == "play":
			_fields[prefix + "max_simulations"] = _spin(0, 20)
			box.add_child(_row("Simulations per turn", _fields[prefix + "max_simulations"]))
			_fields[prefix + "style"] = LineEdit.new()
			_fields[prefix + "style"].placeholder_text = "e.g. aggressive rushdown, never turtle"
			box.add_child(_row("Play style", _fields[prefix + "style"]))
			_fields[prefix + "risk"] = _options(["cautious", "balanced", "reckless"])
			box.add_child(_row("Risk", _fields[prefix + "risk"]))
		else:
			_fields[prefix + "batch_size"] = _spin(1, 50)
			box.add_child(_row("Moves per batch", _fields[prefix + "batch_size"]))
			_fields[prefix + "auto_generate_missing"] = CheckBox.new()
			box.add_child(_row("Auto-generate for new characters", _fields[prefix + "auto_generate_missing"]))
	var keys_header = Label.new()
	keys_header.text = "API keys (stored in user://budok/config.json)"
	box.add_child(keys_header)
	for provider in ["anthropic", "openai", "openrouter"]:
		var key_edit = LineEdit.new()
		key_edit.secret = true
		key_edit.placeholder_text = "unchanged" if runtime.config.api_key(provider) != "" else "not set (or env %s)" % runtime.config.get_value("ai.providers.%s.api_key_env" % provider, "")
		_fields["key:" + provider] = key_edit
		box.add_child(_row(provider, key_edit))
	_fields["ai.providers.local.base_url"] = LineEdit.new()
	box.add_child(_row("Local server URL", _fields["ai.providers.local.base_url"]))
	box.add_child(_button("Save", "_on_save_settings"))
	return scroll


func _build_characters() -> Control:
	var box = _tab("Characters")
	_char_picker = OptionButton.new()
	_char_picker.connect("item_selected", self, "_on_character_selected")
	box.add_child(_row("Character", _char_picker))
	_char_status = Label.new()
	_char_status.autowrap = true
	box.add_child(_char_status)
	var buttons = HBoxContainer.new()
	box.add_child(buttons)
	buttons.add_child(_button("Generate with AI", "_on_generate"))
	buttons.add_child(_button("Export", "_on_export"))
	buttons.add_child(_button("Refresh", "_on_refresh_characters"))
	_fields["schemas.registry_enabled"] = CheckBox.new()
	box.add_child(_row("Community registry (opt-in)", _fields["schemas.registry_enabled"]))
	_fields["schemas.registry_url"] = LineEdit.new()
	_fields["schemas.registry_url"].placeholder_text = "https://..."
	box.add_child(_row("Registry URL", _fields["schemas.registry_url"]))
	var registry_buttons = HBoxContainer.new()
	box.add_child(registry_buttons)
	registry_buttons.add_child(_button("Fetch from registry", "_on_fetch_registry"))
	registry_buttons.add_child(_button("Save", "_on_save_settings"))
	return box


# --- refresh ---

func _refresh() -> void:
	if _root == null:
		return
	for slot in _controller_pickers:
		_controller_pickers[slot].select(CONTROLLERS.find(runtime.matches.controllers.get(slot, "human")))
	for path in _fields:
		if path.begins_with("key:"):
			continue
		_set_field(_fields[path], runtime.config.get_value(path))
	_token_edit.text = str(runtime.config.get_value("mcp.auth_token", ""))
	_refresh_characters()
	_refresh_status()


func _refresh_status() -> void:
	var status = runtime.status()
	var match_status = status["match"]
	var lines = [
		"budok %s  |  game %s" % [status["budok_version"], status["game_version"]],
		"MCP: %s  (%s, %d session(s))" % [status["mcp"]["url"], "listening" if status["mcp"]["listening"] else "NOT listening: " + str(runtime.server_state.get("error", "")), status["mcp"]["sessions"]],
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
		lines.append("AI: %d turns, %d fallbacks, %d/%d tokens in/out%s" % [auto["turns"], auto["fallbacks"], auto["input_tokens"], auto["output_tokens"],
			("\nLast error: " + auto["last_error"]) if auto["last_error"] != "" else ""])
	for job in status["annotation_jobs"]:
		lines.append("Schema job %s: %s %s" % [job["character"], job["status"], job["progress"]])
	_status.text = PoolStringArray(lines).join("\n")


func _refresh_characters() -> void:
	var previous = _char_picker.get_item_text(_char_picker.selected) if _char_picker.get_item_count() > 0 else ""
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
		_char_status.text = ""
		return
	if not entry["loaded"]:
		_char_status.text = "%s (%s): not loaded yet; it loads when a match with it starts." % [entry["display_name"], entry["source"]]
		return
	var info = runtime.schemas.describe(entry)
	if not info["skeleton"].get("ok", false):
		_char_status.text = "Cannot read %s: %s" % [entry["display_name"], info["skeleton"].get("error", "")]
		return
	_char_status.text = "%s (%s)\nNotes: %s%s, %d/%d moves annotated%s\n%s" % [
		entry["display_name"], entry["source"], info["status"], " (STALE: character changed)" if info["stale"] else "",
		info["coverage"]["annotated"], info["coverage"]["total"], ", has summary" if info["coverage"]["has_summary"] else "",
		info["schema_path"]]


# --- actions ---

func _on_controller_selected(index: int, slot: String) -> void:
	var controller = CONTROLLERS[index]
	runtime.matches.set_controller(slot, controller)
	runtime.config.set_value("controllers." + slot, controller)
	runtime.config.save()
	_say("%s is now controlled by %s" % [slot.to_upper(), controller])


func _on_save_settings() -> void:
	for path in _fields:
		if path.begins_with("key:"):
			var key_text = _fields[path].text.strip_edges()
			if key_text != "":
				runtime.config.set_value("ai.providers.%s.api_key" % path.substr(4), key_text)
				_fields[path].text = ""
				_fields[path].placeholder_text = "unchanged"
			continue
		runtime.config.set_value(path, _get_field(_fields[path], runtime.config.get_value(path)))
	runtime.config.save()
	runtime.matches.set_controller("p1", runtime.matches.controllers["p1"])
	runtime.matches.set_controller("p2", runtime.matches.controllers["p2"])
	_say("Settings saved.")
	_refresh()


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


func _on_copy_desktop() -> void:
	var snippet = {"mcpServers": {"budok": {"command": "npx", "args": ["-y", "mcp-remote", runtime.mcp.url(),
		"--header", "Authorization: Bearer %s" % runtime.config.get_value("mcp.auth_token", "")]}}}
	OS.set_clipboard(Util.to_json(snippet, false, "  "))
	_say("Copied a claude_desktop_config.json snippet (uses mcp-remote; needs Node.js).")


func _on_copy_code() -> void:
	OS.set_clipboard("claude mcp add --transport http budok %s --header \"Authorization: Bearer %s\"" % [
		runtime.mcp.url(), runtime.config.get_value("mcp.auth_token", "")])
	_say("Copied a `claude mcp add` command.")


func _on_restart_server() -> void:
	var result = runtime.restart_server()
	_say("Server: %s" % (result.get("url", "") if result.get("ok", false) else result.get("error", "")))


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
	_say("Exported to %s\n%s" % [result.get("absolute_path", ""), result.get("install_hint", "")] if result.get("ok", false) else str(result.get("error", "")))


func _on_fetch_registry() -> void:
	var entry = _selected_entry()
	if entry == null or not entry["loaded"]:
		_say("Load the character first (start a match with it).")
		return
	_say("Fetching...")
	var result = yield(runtime.fetch_registry(entry), "completed")
	_say("Registry: %s" % (str(result.get("coverage", "")) if result.get("ok", false) else str(result.get("error", ""))))
	_on_character_selected(_char_picker.selected)


func _on_refresh_characters() -> void:
	runtime.introspector.clear_cache()
	runtime.schemas.invalidate()
	_refresh_characters()


# --- widgets ---

func _selected_entry():
	if _char_picker.get_item_count() == 0 or _char_picker.selected < 0:
		return null
	return runtime.roster.resolve(str(_char_picker.get_item_metadata(_char_picker.selected)))


func _say(text: String) -> void:
	_message.text = text


func _tab(title: String) -> VBoxContainer:
	var box = VBoxContainer.new()
	box.name = title
	return box


func _row(label_text: String, control: Control) -> HBoxContainer:
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = label_text
	label.rect_min_size = Vector2(170, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _button(text: String, method: String) -> Button:
	var button = Button.new()
	button.text = text
	button.connect("pressed", self, method)
	return button


func _options(items: Array) -> OptionButton:
	var picker = OptionButton.new()
	for item in items:
		picker.add_item(item if item != "" else "(default)")
		picker.set_item_metadata(picker.get_item_count() - 1, item)
	return picker


func _spin(min_value: int, max_value: int) -> SpinBox:
	var spin = SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	return spin


func _set_field(control: Control, value) -> void:
	if control is OptionButton:
		for i in range(control.get_item_count()):
			if str(control.get_item_metadata(i)) == str(value if value != null else ""):
				control.select(i)
	elif control is CheckBox:
		control.pressed = bool(value)
	elif control is SpinBox:
		control.value = float(value if value != null else 0)
	elif control is LineEdit:
		control.text = str(value) if value != null else ""


func _get_field(control: Control, previous):
	if control is OptionButton:
		return control.get_item_metadata(control.selected)
	if control is CheckBox:
		return control.pressed
	if control is SpinBox:
		return int(control.value) if previous is int or previous == null else control.value
	if control is LineEdit:
		return control.text.strip_edges()
	return previous
