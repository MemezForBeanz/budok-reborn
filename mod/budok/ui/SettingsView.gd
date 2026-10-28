extends Reference

# All budok settings as four tabs (Play, Models, Chatbots, Characters), the
# same view in the game's Mod List window (ui/ModMenuHook.gd), the Options
# window's budok button and the F8 overlay (ui/Panel.gd). Rarely changed
# settings sit in collapsed sections. Models are picked per role: the chat
# model, the notes writer and the decision core, each with its key next to it.

const Util = preload("res://budok/core/Util.gd")
const CONTROLLERS := [["human", "You"], ["mcp", "Chatbot (MCP)"], ["ai", "AI: chat model"], ["decision", "AI: decision models"],
	["tandem", "AI: tandem (chat + decision)"]]
const CHAT_PROVIDERS := [["anthropic", "Anthropic"], ["openai", "OpenAI"], ["openrouter", "OpenRouter"], ["local", "Local server (Ollama...)"]]
const DECISION_PROVIDERS := [["typesafe", "TypeSafe"], ["vercel", "Vercel AI Gateway"]]
const ALL_PROVIDERS := ["anthropic", "openai", "openrouter", "local", "typesafe", "vercel"]
const CHAT_MODELS := {
	"anthropic": [["claude-opus-5-5", "Claude Opus 5.5"], ["claude-sonnet-5-5", "Claude Sonnet 5.5"], ["claude-haiku-5-5", "Claude Haiku 5.5"],
		["claude-fable-5-1", "Claude Fable 5.1"]],
}
const DECISION_MODELS := {
	"typesafe": [["jev-latest", "Jev"], ["jev-preview", "Jev preview"]],
	"vercel": [["typesafe-ai/jev", "Jev (paid credits)"], ["baseten/mammoth-1", "Mammoth-1 27B (free tier)"],
		["perplexity/pplx-decider-v1.2", "Perplexity Decider 27B (free tier)"], ["liquid/d1-ultra", "Liquid d1-ultra (free tier)"],
		["perplexity/pplx-decider-flash-v1.2", "Perplexity Decider Flash (free tier)"], ["microsoft/microsoft-decision-1", "Microsoft Decision-1"],
		["openai/gpt-6-luna-decisions", "GPT-6 Luna Decisions"]],
}
const EFFORTS := [["", "Model default"], ["low", "Low"], ["medium", "Medium"], ["high", "High"], ["xhigh", "Extra high"], ["max", "Max"]]
const AUTO_WHEN := [["matches", "Only before matches"], ["connect", "On boot and when a chatbot connects"]]
const DIM := Color(0.7, 0.7, 0.7)
const ACCENT := Color(1.0, 0.8, 0.35)

var runtime = null
var _fields := {}
var _role_keys := {}
var _endpoint_list: VBoxContainer = null
var _endpoint_cards := []
var _core_status: Label = null
var _play_status: Label = null
var _readiness: Label = null
var _mcp_status: Label = null
var _messages := []
var _token_edit: LineEdit = null
var _char_picker: OptionButton = null
var _char_status: Label = null
var _auto_rows := []


func _init(runtime_ref) -> void:
	runtime = runtime_ref


# Adds the tabs to `tabs` (a TabContainer).
func build_into(tabs: TabContainer) -> void:
	tabs.add_child(_play_tab())
	tabs.add_child(_models_tab())
	tabs.add_child(_chatbots_tab())
	tabs.add_child(_characters_tab())
	refresh()


func refresh() -> void:
	for path in _fields:
		var field = _fields[path]
		if field["type"] != "secret":
			_set_value(field, runtime.config.get_value(path))
	for role in _role_keys:
		_on_role_provider_changed(-1, role)
	_rebuild_endpoints()
	if Util.valid(_token_edit):
		_token_edit.text = str(runtime.config.get_value("mcp.auth_token", ""))
	_on_auto_toggled(bool(runtime.config.get_value("schemas.auto.enabled", true)))
	refresh_characters()
	refresh_status()


func refresh_status() -> void:
	var status = runtime.status()
	if Util.valid(_play_status):
		_play_status.text = PoolStringArray(_play_lines(status)).join("\n")
	if Util.valid(_readiness):
		_readiness.text = PoolStringArray(_readiness_lines(status)).join("\n")
	if Util.valid(_mcp_status):
		_mcp_status.text = "budok %s | game %s\nMCP: %s (%s, %d session(s))" % [status["budok_version"], status["game_version"], status["mcp"]["url"],
			"listening" if status["mcp"]["listening"] else "NOT listening: " + str(runtime.server_state.get("error", "")), status["mcp"]["sessions"]]
	if Util.valid(_core_status):
		_core_status.text = _core_line(status["ai"]["decision_core"])


func _play_lines(status: Dictionary) -> Array:
	var match_status = status["match"]
	var lines = []
	if match_status["blocked_reason"] != "":
		lines.append("Match: not controlled (%s)" % match_status["blocked_reason"])
	elif match_status["in_match"]:
		lines.append("Match: %s vs %s, tick %d" % [match_status["characters"]["p1"], match_status["characters"]["p2"], match_status.get("tick", 0)])
	else:
		lines.append("No match running.")
	var auto = status["ai"]["autopilot"]
	if auto["turns"] > 0 or auto["last_error"] != "":
		lines.append("Chat model: %d turns, %d fallbacks%s" % [auto["turns"], auto["fallbacks"], (", error: " + auto["last_error"]) if auto["last_error"] != "" else ""])
	var decider = status["ai"]["decision_player"]
	if decider["turns"] > 0 or decider["last_error"] != "":
		lines.append("Decision bot: %d turns, %d fallbacks%s" % [decider["turns"], decider["fallbacks"],
			(", last: " + decider["last_decision"]) if decider["last_decision"] != "" else ""])
		if decider["last_error"] != "":
			lines.append("Decision bot error: " + decider["last_error"])
	var agent = status.get("notes_agent", {})
	if agent.get("state", "idle") != "idle":
		lines.append("Notes agent: %s%s" % [agent["state"], (": " + agent["error"]) if agent.has("error") else ""])
	for job in status["schema_jobs"]:
		if job["status"] in ["queued", "assigned", "running"]:
			lines.append("Notes for %s: %s %s" % [job["character"], job["status"], job.get("progress", "")])
	return lines


# What each slot's controller still needs, so a mode that can't play says why.
func _readiness_lines(status: Dictionary) -> Array:
	var lines = []
	var chat = runtime.llm.describe_role("play")
	var core = status["ai"]["decision_core"]
	for slot in ["p1", "p2"]:
		var controller = str(status["match"]["controllers"][slot])
		var needs = []
		if controller in ["ai", "tandem"]:
			needs.append("chat model %s: %s" % [chat["model"], "ready" if chat["has_key"] else "needs an API key (Models tab)"])
		if controller in ["decision", "tandem"] and core["parallel_requests"] > 0:
			needs.append("decision core: %d parallel requests ready" % core["parallel_requests"])
		elif controller in ["decision", "tandem"]:
			needs.append("decision core: no decision model ready (Models tab, Decision core: add one with a model and an API key)")
		if controller == "mcp":
			needs.append("claimed by a chatbot" if status["match"]["claimed_by"][slot] else "waiting for a chatbot to claim it (Chatbots tab)")
		if not needs.empty():
			lines.append("%s %s: %s" % [slot.to_upper(), _label_of(CONTROLLERS, controller), PoolStringArray(needs).join("; ")])
	return lines


static func _core_line(core: Dictionary) -> String:
	var lines = ["Not ready: add a decision model with an API key."]
	if core["parallel_requests"] > 0:
		lines = ["Ready: %d parallel requests, %d calls so far" % [core["parallel_requests"], core["calls"]]]
	for endpoint in core["endpoints"]:
		var notes = []
		if endpoint.has("problem"):
			notes.append(endpoint["problem"])
		if endpoint.has("requests_per_minute"):
			notes.append("%d requests a minute" % endpoint["requests_per_minute"])
		if endpoint.has("last_error"):
			notes.append("last error: " + Util.truncate(str(endpoint["last_error"]), 90))
		lines.append("%s: %d calls%s" % [endpoint["label"], endpoint["calls"], (", " + PoolStringArray(notes).join(", ")) if not notes.empty() else ""])
	return PoolStringArray(lines).join("\n")


# --- tabs ---

func _play_tab() -> Control:
	var box = _tab("Play")
	_play_status = _label("")
	box.add_child(_play_status)
	box.add_child(_header("Who plays"))
	_field(box, "controllers.p1", "P1", "option", CONTROLLERS)
	_field(box, "controllers.p2", "P2", "option", CONTROLLERS)
	_readiness = _label("", DIM)
	box.add_child(_readiness)
	var modes = _section(box, "What the modes do")
	modes.add_child(_note("You: you play it. Chatbot: a connected chatbot (Claude Desktop, Claude Code...) plays it once it claims the slot. "
		+ "AI chat model: the chat model from the Models tab plays it with your API key. AI decision models: the decision core plays it, "
		+ "simulating your best moves many turns ahead. AI tandem: the chat model plays it and asks the decision core to look ahead for it."))
	var turns = _section(box, "Turn rules")
	_field(turns, "turns.forced_turns", "Auto-hold when it is the only move", "option",
		[["never", "Never"], ["skip_unless_hurt", "Unless hurt (keeps DI)"], ["always", "Always"]])
	_field(turns, "turns.timeout_s.ai", "Chat model turn limit (s)", "int", [0, 3600])
	_field(turns, "turns.timeout_s.decision", "Decision bot turn limit (s)", "int", [0, 3600])
	_field(turns, "turns.timeout_s.tandem", "Tandem turn limit (s)", "int", [0, 3600])
	_field(turns, "turns.timeout_s.mcp", "Chatbot turn limit (s)", "int", [0, 3600])
	_field(turns, "turns.fallback_action", "Move when a bot runs out of time", "string")
	_field(turns, "turns.hide_bot_panel", "Hide a bot's move panel", "bool")
	_field(turns, "turns.history_length", "Past turns shown to bots", "int", [1, 60])
	turns.add_child(_note("0 s = no limit."))
	var sims = _section(box, "Simulations")
	_field(sims, "simulation.enabled", "Bots may simulate moves", "bool")
	_field(sims, "simulation.max_ticks", "Ticks per simulated turn", "int", [10, 300])
	var other = _section(box, "Interface and logs")
	_field(other, "ui.show_button", "Corner budok button", "bool")
	_field(other, "ui.toggle_key", "Overlay key", "string")
	_field(other, "ui.show_on_start", "Open the overlay on start", "bool")
	_field(other, "logging.match_logs", "Write match logs", "bool")
	_field(other, "automation.script", "Automation script (path)", "string")
	other.add_child(_note("Automation changes apply after restarting the game."))
	box.add_child(_header("Misc"))
	_field(box, "misc.trash_talk", "Bots trash talk every turn", "bool")
	_field(box, "misc.speech_bubbles", "Bots may say lines above their character", "bool")
	_field(box, "misc.bubble_seconds", "Speech bubble time (s)", "int", [1, 30])
	box.add_child(_note("Lines appear in a bubble above the character. Chatbots and the chat model can talk (trash talk turns that on too); "
		+ "decision models can't write."))
	box.add_child(_buttons([["Save", "_on_save"]]))
	return _end_tab(box)


func _models_tab() -> Control:
	var box = _tab("Models")
	box.add_child(_header("Chat model"))
	box.add_child(_note("Plays the AI chat model controller and leads Tandem."))
	_role_rows(box, "play")
	var play_more = _section(box, "More chat model settings")
	_field(play_more, "ai.play.effort", "Effort (Anthropic)", "option", EFFORTS)
	_field(play_more, "ai.play.max_steps", "Tool steps per turn", "int", [1, 100])
	_field(play_more, "ai.play.max_simulations", "Simulations per turn", "int", [0, 20])
	_field(play_more, "ai.play.allow_simulation", "May simulate", "bool")
	_field(play_more, "ai.play.style", "Play style (free text)", "string")
	_field(play_more, "ai.play.risk", "Risk", "option", [["cautious", "Cautious"], ["balanced", "Balanced"], ["reckless", "Reckless"]])
	_field(play_more, "ai.play.memory_turns", "Own notes kept", "int", [0, 50])
	_field(play_more, "ai.play.reflect_after_match", "Save lessons after a match", "bool")
	_field(play_more, "ai.play.max_tokens", "Max output tokens", "int", [256, 128000])
	_field(play_more, "ai.play.request_timeout_s", "Request timeout (s)", "int", [10, 3600])
	_field(play_more, "ai.play.temperature", "Temperature (empty = default)", "float_or_null")
	_field(play_more, "ai.play.refusal_fallback", "Refusal fallback (Claude API)", "bool")

	box.add_child(_header("Decision core"))
	box.add_child(_note("Decision models play the decision controller and do Tandem's and look_ahead's lookahead. "
		+ "Add several (or the same model with several keys): requests go to whichever has a free slot."))
	_endpoint_list = VBoxContainer.new()
	box.add_child(_endpoint_list)
	box.add_child(_buttons([["+ Add decision model", "_on_add_endpoint"]]))
	_core_status = _label("", DIM)
	box.add_child(_core_status)
	var look = _section(box, "Lookahead")
	_field(look, "ai.core.depth", "Turns each line looks ahead", "int", [0, 30])
	_field(look, "ai.core.candidates", "Own moves compared", "int", [1, 8])
	_field(look, "ai.core.think_s", "Thinking time per turn (s)", "int", [3, 600])
	_field(look, "ai.decide.pick", "Decision bot picks", "option", [["sample", "Drawn from the odds"], ["best", "Always the top move"]])
	_field(look, "ai.core.max_options", "Options per question", "int", [2, 255])
	_field(look, "ai.core.request_timeout_s", "Request timeout (s)", "int", [2, 300])
	_field(look, "ai.core.frame_budget_ms", "Simulation ms per frame", "int", [1, 100])
	look.add_child(_note("Each move (yours, plus your blocks and dodges) is first played against every opponent reply for one exchange; "
		+ "then deep lines run, one per parallel request, each turn of a line one request. Depth 0 turns simulations off. "
		+ "More ms per frame thinks faster but makes the game less smooth. Lower the options per question if a model rejects requests."))

	box.add_child(_header("Notes writer"))
	box.add_child(_note("Writes notes for characters that have none (Characters tab)."))
	_role_rows(box, "annotate")
	var notes_more = _section(box, "More notes writer settings")
	_field(notes_more, "ai.annotate.effort", "Effort (Anthropic)", "option", EFFORTS)
	_field(notes_more, "ai.annotate.batch_size", "Moves per request", "int", [1, 50])
	_field(notes_more, "ai.annotate.include_source", "Send code of code-driven moves", "bool")
	_field(notes_more, "ai.annotate.max_source_chars", "Max code characters per move", "int", [500, 50000])
	_field(notes_more, "ai.annotate.max_steps", "Tool steps per batch", "int", [1, 100])
	_field(notes_more, "ai.annotate.max_tokens", "Max output tokens", "int", [256, 128000])
	_field(notes_more, "ai.annotate.request_timeout_s", "Request timeout (s)", "int", [10, 3600])
	_field(notes_more, "ai.annotate.refusal_fallback", "Refusal fallback (Claude API)", "bool")

	var addresses = _section(box, "Provider addresses (advanced)")
	addresses.add_child(_note("Keys typed above are saved per provider; empty keys fall back to these environment variables."))
	for provider in ALL_PROVIDERS:
		if provider != "local":
			_field(addresses, "ai.providers.%s.api_key_env" % provider, "%s key variable" % provider, "string")
		_field(addresses, "ai.providers.%s.base_url" % provider, "%s address" % provider, "string")
	box.add_child(_buttons([["Save", "_on_save"]]))
	return _end_tab(box)


func _chatbots_tab() -> Control:
	var box = _tab("Chatbots")
	_mcp_status = _label("")
	box.add_child(_mcp_status)
	_token_edit = LineEdit.new()
	_token_edit.secret = true
	_token_edit.editable = false
	box.add_child(_row("Token", _token_edit))
	box.add_child(_buttons([["Show token", "_on_show_token"], ["Copy URL + token", "_on_copy_url"], ["New token", "_on_new_token"]]))
	box.add_child(_header("Connect a chatbot"))
	box.add_child(_buttons([["Claude Desktop config", "_on_copy_desktop"], ["Claude Code command", "_on_copy_code"]]))
	box.add_child(_buttons([["Desktop config (Node.js)", "_on_copy_desktop_node"]]))
	box.add_child(_note("The buttons copy what to paste into the chatbot's settings. Other MCP clients: the URL with the token "
		+ "(Authorization: Bearer <token>, or ?token=). Web chatbots need a public HTTPS tunnel to this port; keep the token secret."))
	box.add_child(_header("Server"))
	_field(box, "mcp.enabled", "Run the MCP server", "bool")
	_field(box, "mcp.port", "Port", "int", [1024, 65535])
	_field(box, "mcp.require_token", "Require the token", "bool")
	_field(box, "mcp.max_wait_s", "Longest wait per call (s)", "int", [1, 50])
	var advanced = _section(box, "Advanced")
	_field(advanced, "mcp.host", "Listen address (keep 127.0.0.1)", "string")
	_field(advanced, "mcp.allowed_origins", "Extra browser origins (comma separated)", "list")
	_field(advanced, "source_access.enabled", "Bots may read game and mod scripts", "bool")
	_field(advanced, "source_access.max_file_bytes", "Largest script they may read", "int", [1000, 5000000])
	box.add_child(_buttons([["Save and restart server", "_on_save_restart"]]))
	return _end_tab(box)


func _characters_tab() -> Control:
	var box = _tab("Characters")
	_char_picker = OptionButton.new()
	_char_picker.clip_text = true
	_char_picker.connect("item_selected", self, "_on_character_selected")
	box.add_child(_row("Character", _char_picker))
	_char_status = _label("")
	box.add_child(_char_status)
	box.add_child(_buttons([["Write notes with AI", "_on_generate"], ["Export", "_on_export"], ["Refresh", "_on_refresh_characters"], ["Clear memories", "_on_clear_memories"]]))
	box.add_child(_header("Automatic notes"))
	_field(box, "schemas.auto.enabled", "Write missing notes automatically", "bool")
	_auto_rows = [
		_field(box, "schemas.auto.when", "When", "option", AUTO_WHEN),
		_field(box, "schemas.auto.match_start", "Before a match, for both characters (bots wait)", "bool"),
		_field(box, "schemas.auto.use_agent", "Notes agent (Claude Code, own context)", "bool"),
		_field(box, "schemas.auto.agent_command", "Claude Code command", "string"),
		_field(box, "schemas.auto.agent_model", "Agent model (empty = default)", "string"),
		_field(box, "schemas.auto.use_api", "Notes writer from the Models tab", "bool"),
		_field(box, "schemas.auto.use_player", "The chatbot that is playing (last resort)", "bool"),
		_note("The notes agent is Claude Code, which budok starts in the background with your Claude login (install it first), or a second chat you open "
			+ "with budok's notes_worker prompt. Either has its own context, so the chat that plays never writes notes."),
	]
	box.add_child(_auto_rows[_auto_rows.size() - 1])
	_fields["schemas.auto.enabled"]["control"].connect("toggled", self, "_on_auto_toggled")
	box.add_child(_header("Memories"))
	_field(box, "memory.enabled", "Bots keep memories between matches", "bool")
	_field(box, "memory.shown_per_match", "Memories shown at match start", "int", [0, 30])
	var registry = _section(box, "Community registry")
	_field(registry, "schemas.registry_enabled", "Use the registry (opt-in)", "bool")
	_field(registry, "schemas.registry_url", "Registry address (https)", "string")
	registry.add_child(_buttons([["Fetch notes for this character", "_on_fetch_registry"]]))
	box.add_child(_buttons([["Save", "_on_save"]]))
	return _end_tab(box)


# Provider, model (with suggestions) and that provider's key for a chat role.
func _role_rows(box: Control, role: String) -> void:
	var provider_row = _field(box, "ai.%s.provider" % role, "Provider", "option", CHAT_PROVIDERS)
	var model_edit = _field_control("ai.%s.model" % role, "string")
	var suggestions = _suggestions(model_edit)
	box.add_child(_row("Model", _pair(model_edit, suggestions)))
	var key = LineEdit.new()
	key.secret = true
	var key_row = _row("API key", key)
	box.add_child(key_row)
	var provider = _fields["ai.%s.provider" % role]["control"]
	_role_keys[role] = {"provider": provider, "key": key, "key_row": key_row, "suggestions": suggestions}
	provider.connect("item_selected", self, "_on_role_provider_changed", [role])
	provider_row.hint_tooltip = "Where the model runs; its key is saved for this provider."


func _on_role_provider_changed(_index: int, role: String) -> void:
	var parts = _role_keys[role]
	var provider = str(parts["provider"].get_item_metadata(parts["provider"].selected))
	parts["key_row"].visible = provider != "local"
	parts["key"].text = ""
	parts["key"].placeholder_text = _key_placeholder(provider, str(runtime.config.get_value("ai.providers.%s.api_key" % provider, "")))
	_fill_suggestions(parts["suggestions"], CHAT_MODELS.get(provider, []))


func _key_placeholder(provider: String, saved: String) -> String:
	if saved != "":
		return "saved (hidden); type to replace"
	var env = str(runtime.config.get_value("ai.providers.%s.api_key_env" % provider, ""))
	if env != "" and OS.get_environment(env) != "":
		return "using %s from the environment" % env
	return "not set"


# --- decision core endpoints ---

func _rebuild_endpoints() -> void:
	if not Util.valid(_endpoint_list):
		return
	for card in _endpoint_cards:
		if Util.valid(card["box"]):
			card["box"].queue_free()
	_endpoint_cards = []
	var list = runtime.config.get_value("ai.core.endpoints", [])
	for endpoint in list if list is Array else []:
		_add_endpoint_card(endpoint if endpoint is Dictionary else {})


func _add_endpoint_card(endpoint: Dictionary) -> void:
	var card = {"saved_key": str(endpoint.get("api_key", ""))}
	var box = VBoxContainer.new()
	card["box"] = box
	var title = HBoxContainer.new()
	card["enabled"] = CheckBox.new()
	card["enabled"].pressed = bool(endpoint.get("enabled", true))
	card["enabled"].text = "Model %d" % (_endpoint_cards.size() + 1)
	card["enabled"].modulate = ACCENT
	title.add_child(card["enabled"])
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(spacer)
	var remove = Button.new()
	remove.text = "Remove"
	remove.connect("pressed", self, "_on_remove_endpoint", [box])
	title.add_child(remove)
	box.add_child(title)
	card["provider"] = OptionButton.new()
	card["provider"].clip_text = true
	for item in DECISION_PROVIDERS:
		card["provider"].add_item(item[1])
		card["provider"].set_item_metadata(card["provider"].get_item_count() - 1, item[0])
	card["model"] = LineEdit.new()
	card["model"].text = str(endpoint.get("model", ""))
	card["suggestions"] = _suggestions(card["model"])
	card["key"] = LineEdit.new()
	card["key"].secret = true
	card["threads"] = _spin(1, 32, Util.as_int(endpoint.get("threads", 4)))
	card["max_rpm"] = _spin(0, 10000, Util.as_int(endpoint.get("max_rpm", 0)))
	box.add_child(_row("Provider", card["provider"]))
	box.add_child(_row("Model", _pair(card["model"], card["suggestions"])))
	box.add_child(_row("API key", card["key"]))
	box.add_child(_row("Parallel requests", card["threads"]))
	box.add_child(_row("Requests a minute (0 = no limit)", card["max_rpm"]))
	box.add_child(HSeparator.new())
	_endpoint_list.add_child(box)
	_endpoint_cards.append(card)
	card["provider"].connect("item_selected", self, "_on_endpoint_provider_changed", [card])
	var provider = str(endpoint.get("provider", "typesafe"))
	for i in range(card["provider"].get_item_count()):
		if str(card["provider"].get_item_metadata(i)) == provider:
			card["provider"].select(i)
	_on_endpoint_provider_changed(card["provider"].selected, card)


func _on_endpoint_provider_changed(_index: int, card: Dictionary) -> void:
	var provider = str(card["provider"].get_item_metadata(card["provider"].selected))
	_fill_suggestions(card["suggestions"], DECISION_MODELS.get(provider, []))
	if card["saved_key"] != "":
		card["key"].placeholder_text = "saved (hidden); type to replace"
	else:
		var shared = _key_placeholder(provider, str(runtime.config.get_value("ai.providers.%s.api_key" % provider, "")))
		card["key"].placeholder_text = "not set" if shared == "not set" else "empty: the shared %s key (%s)" % [provider, shared.split(";")[0]]


func _on_add_endpoint() -> void:
	_add_endpoint_card({"provider": "typesafe", "model": "jev-latest", "threads": 4, "max_rpm": 0, "enabled": true})
	_say("Added a decision model; fill in its key and press Save.")


func _on_remove_endpoint(box: Control) -> void:
	for card in _endpoint_cards:
		if card["box"] == box:
			_endpoint_cards.erase(card)
			box.queue_free()
			_say("Removed; press Save to keep it that way.")
			return


func _endpoints_value() -> Array:
	var out = []
	for card in _endpoint_cards:
		var typed = card["key"].text.strip_edges()
		out.append({
			"label": "",
			"provider": str(card["provider"].get_item_metadata(card["provider"].selected)),
			"model": card["model"].text.strip_edges(),
			"api_key": typed if typed != "" else card["saved_key"],
			"threads": int(card["threads"].value),
			"max_rpm": int(card["max_rpm"].value),
			"enabled": card["enabled"].pressed,
		})
	return out


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
		runtime.config.set_value(path, value)
	for role in _role_keys:
		var parts = _role_keys[role]
		var typed = parts["key"].text.strip_edges()
		if typed != "":
			runtime.config.set_value("ai.providers.%s.api_key" % str(parts["provider"].get_item_metadata(parts["provider"].selected)), typed)
	if Util.valid(_endpoint_list):
		runtime.config.set_value("ai.core.endpoints", _endpoints_value())
	runtime.config.save()
	for slot in ["p1", "p2"]:
		runtime.matches.set_controller(slot, str(runtime.config.get_value("controllers." + slot, "human")))
	for role in _role_keys:
		_on_role_provider_changed(-1, role)
	_rebuild_endpoints()
	runtime.emit_signal("status_changed")
	refresh_status()


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
	var row = _row(label, _field_control(path, type, options))
	box.add_child(row)
	return row


func _field_control(path: String, type: String, options = null) -> Control:
	var control = null
	match type:
		"bool":
			control = CheckBox.new()
		"int":
			control = _spin(options[0], options[1], options[0])
		"option":
			control = OptionButton.new()
			control.clip_text = true
			for item in options:
				control.add_item(item[1] if item is Array else str(item))
				control.set_item_metadata(control.get_item_count() - 1, item[0] if item is Array else item)
		"secret":
			control = LineEdit.new()
			control.secret = true
			control.placeholder_text = "saved (hidden)" if str(runtime.config.get_value(path, "")) != "" else "not set"
		_:
			control = LineEdit.new()
	_fields[path] = {"type": type, "control": control}
	return control


static func _spin(low: int, high: int, value: int) -> SpinBox:
	var spin = SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.value = value
	return spin


# A short list of known models next to a model field; picking one fills it in.
func _suggestions(target: LineEdit) -> OptionButton:
	var list = OptionButton.new()
	list.clip_text = true
	list.rect_min_size.x = 46
	list.size_flags_horizontal = 0
	list.connect("item_selected", self, "_on_suggestion", [list, target])
	return list


func _fill_suggestions(list: OptionButton, models: Array) -> void:
	list.clear()
	list.add_item("List")
	list.set_item_metadata(0, "")
	for model in models:
		list.add_item(model[1])
		list.set_item_metadata(list.get_item_count() - 1, model[0])
	list.visible = not models.empty()
	list.select(0)


func _on_suggestion(index: int, list: OptionButton, target: LineEdit) -> void:
	var model = str(list.get_item_metadata(index))
	if model != "":
		target.text = model
	list.select(0)


static func _pair(main: Control, side: Control) -> HBoxContainer:
	var pair = HBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pair.add_child(main)
	pair.add_child(side)
	return pair


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


static func _label_of(pairs: Array, value: String) -> String:
	for pair in pairs:
		if pair[0] == value:
			return pair[1]
	return value


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
	message.modulate = ACCENT
	tab.add_child(message)
	_messages.append(message)
	return tab


# A titled group that starts folded; the title button opens and closes it.
func _section(box: Control, title: String) -> VBoxContainer:
	var button = Button.new()
	button.toggle_mode = true
	button.flat = true
	button.align = Button.ALIGN_LEFT
	button.text = "+ " + title
	var body = VBoxContainer.new()
	body.visible = false
	button.connect("toggled", self, "_on_section_toggled", [button, body, title])
	box.add_child(button)
	box.add_child(body)
	return body


func _on_section_toggled(open: bool, button: Button, body: Control, title: String) -> void:
	body.visible = open
	button.text = ("- " if open else "+ ") + title


# Label and control share the row, so it fits narrow windows; long labels wrap.
func _row(label_text: String, control: Control) -> HBoxContainer:
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = label_text
	label.autowrap = true
	label.valign = Label.VALIGN_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_stretch_ratio = 1.2
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


func _header(text: String) -> Control:
	var box = VBoxContainer.new()
	box.add_child(HSeparator.new())
	var label = Label.new()
	label.text = text
	label.modulate = ACCENT
	box.add_child(label)
	return box


static func _label(text: String, color: Color = Color.white) -> Label:
	var label = Label.new()
	label.autowrap = true
	label.text = text
	label.modulate = color
	return label


static func _note(text: String) -> Label:
	return _label(text, DIM)


func _say(text: String) -> void:
	for message in _messages:
		if Util.valid(message):
			message.text = text
			message.visible = text != ""
