extends WindowDialog

# The agent window: what the agent (or chatbot) playing a slot is doing, as a
# chat log: your messages and its replies, its own words, and every tool call
# it makes with how it went. Type to talk to it; it gets the message with its
# next tool call (ai/AgentDispatch.gd). Drag it by its title, resize it from
# its edges. Opened from the corner "agent" button or its key (F9).

const Util = preload("res://budok/core/Util.gd")
const FEEDS := [["p1", "P1"], ["p2", "P2"], ["other", "Other calls"]]
const SHOWN := 150
const COLORS := {"you": "#ffd060", "reply": "#9be29b", "text": "#ffffff", "call": "#8fb4ff", "status": "#a0a0a0", "log": "#ff9a8a"}

var runtime = null
var _feed: OptionButton = null
var _status: Label = null
var _log: RichTextLabel = null
var _input: LineEdit = null
var _start: Button = null
var _stop: Button = null
var _shown := -1
var _timer := 0.0


func setup(runtime_ref, game_theme) -> void:
	runtime = runtime_ref
	theme = game_theme
	window_title = "budok agents"
	resizable = true
	popup_exclusive = true
	rect_min_size = Vector2(220, 120)
	rect_size = Vector2(290, 175)
	rect_position = Vector2(6, 176)
	var box = VBoxContainer.new()
	box.anchor_right = 1.0
	box.anchor_bottom = 1.0
	box.margin_left = 4
	box.margin_top = 4
	box.margin_right = -4
	box.margin_bottom = -4
	add_child(box)
	var top = HBoxContainer.new()
	box.add_child(top)
	_feed = OptionButton.new()
	for feed in FEEDS:
		_feed.add_item(feed[1])
	_feed.select(1)
	_feed.connect("item_selected", self, "_on_feed_selected")
	top.add_child(_feed)
	_status = Label.new()
	_status.size_flags_horizontal = SIZE_EXPAND_FILL
	_status.clip_text = true
	top.add_child(_status)
	_start = _button("Start", "_on_start")
	top.add_child(_start)
	_stop = _button("Stop", "_on_stop")
	top.add_child(_stop)
	_log = RichTextLabel.new()
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = SIZE_EXPAND_FILL
	box.add_child(_log)
	var bottom = HBoxContainer.new()
	box.add_child(bottom)
	_input = LineEdit.new()
	_input.placeholder_text = "Message the agent (Enter)"
	_input.size_flags_horizontal = SIZE_EXPAND_FILL
	_input.connect("text_entered", self, "_on_send")
	bottom.add_child(_input)
	bottom.add_child(_button("Send", "_on_send_pressed"))


func _button(text: String, method: String) -> Button:
	var button = Button.new()
	button.text = text
	button.connect("pressed", self, method)
	return button


func toggle() -> void:
	if visible:
		hide()
	else:
		popup()
		_shown = -1
		_refresh()


func _slot() -> String:
	return FEEDS[_feed.selected][0]


func _on_feed_selected(_index: int) -> void:
	_shown = -1
	_refresh()


func _on_send(text: String) -> void:
	if _slot() == "other" or text.strip_edges() == "":
		return
	runtime.agents.send(_slot(), text)
	_input.clear()
	_refresh()


func _on_send_pressed() -> void:
	_on_send(_input.text)


func _on_start() -> void:
	if _slot() != "other":
		var started = runtime.agents.start_now(_slot())
		if not started["ok"]:
			runtime.agents.feeds[_slot()].append({"t": Util.now_ms(), "kind": "status", "text": str(started.get("error", "could not start"))})
			runtime.agents.version += 1
	_refresh()


func _on_stop() -> void:
	if _slot() != "other":
		runtime.agents.stop_now(_slot())
	_refresh()


func _process(delta: float) -> void:
	if not visible:
		return
	_timer += delta
	if _timer >= 0.3:
		_timer = 0.0
		_refresh()


func _refresh() -> void:
	var slot = _slot()
	var agents = runtime.agents
	var agent = agents.agents.get(slot, {})
	var who = ""
	if slot == "other":
		who = "calls from sessions that play no slot"
	elif not agent.empty() and agent["state"] in ["starting", "running"]:
		who = "%s, %s mode, %s" % [agent["cli"], agent["mode"], "playing" if agent["sid"] != "" else "starting"]
	elif str(runtime.matches.owners.get(slot, "")) != "":
		who = "a chatbot plays it"
	else:
		who = "%s: %s" % [str(runtime.matches.controllers.get(slot, "human")), agent.get("error", "") if not agent.empty() and agent.get("error", "") != "" else "no agent"]
	_status.text = who
	_status.hint_tooltip = who
	_start.visible = slot != "other"
	_stop.visible = slot != "other" and agents.ready(slot)
	_input.editable = slot != "other"
	if agents.version == _shown:
		return
	_shown = agents.version
	# Text goes in as text (never markup), so nothing an agent prints is read as BBCode.
	_log.clear()
	var feed = agents.feeds.get(slot, [])
	for entry in feed.slice(max(0, feed.size() - SHOWN), feed.size() - 1) if not feed.empty() else []:
		_add_entry(entry)


func _add_entry(entry: Dictionary) -> void:
	var kind = str(entry.get("kind", "status"))
	var prefix = {"you": "you: ", "reply": "agent: ", "call": "> "}.get(kind, "")
	_log.push_color(Color(COLORS.get(kind, "#ffffff")))
	_log.add_text(prefix + str(entry.get("text", "")))
	_log.pop()
	if kind == "call" and entry.has("result"):
		var bad = str(entry["result"]).begins_with("error")
		_log.push_color(Color("#ff9a8a" if bad else "#a0a0a0"))
		_log.add_text("  %s %s (%.1f s)" % ["x" if bad else "->", str(entry["result"]), float(entry.get("ms", 0)) / 1000.0])
		_log.pop()
	_log.newline()
