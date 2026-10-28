extends Node

# Speech bubbles above the fighters (Play tab, Misc): lines bots say with
# submit_action's `say` or the say tool, and their trash talk. A bubble is a
# child of the live fighter just above the game's own "You" label, so it
# follows the character, scales with the camera like the game's labels, and
# never mirrors when the character turns around (only its "flip" child does).

const Util = preload("res://budok/core/Util.gd")
const GAME_THEME := "res://theme.tres"
const MAX_CHARS := 100
const MAX_WIDTH := 110
# World pixels above the fighter's feet; the game's "You" label spans 36-50.
const ABOVE := 54
# How far a bubble reaches past its fighter toward the opponent; the rest of
# it extends away, so two bubbles side by side don't cover each other.
const OVERHANG := 14
const FADE_S := 0.5

var runtime = null
var _theme = null
var _bubbles := {}


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	_theme = load(GAME_THEME) if ResourceLoader.exists(GAME_THEME) else null


func enabled() -> bool:
	return bool(runtime.config.get_value("misc.speech_bubbles", false)) or trash_talk()


func trash_talk() -> bool:
	return bool(runtime.config.get_value("misc.trash_talk", false))


# Shows `text` above `slot`'s fighter, replacing what it said before.
# Returns {"ok", "shown"} or {"ok": false, "error"}.
func say(slot: String, text: String) -> Dictionary:
	if not enabled():
		return {"ok": false, "error": "speech bubbles are off (budok settings: Play tab, Misc)"}
	var fighter = Util.prop(runtime.matches.game, slot, null) if runtime.matches.game != null else null
	if not Util.valid(fighter):
		return {"ok": false, "error": "no match in progress"}
	var line = clean(text)
	if line == "":
		return {"ok": false, "error": "nothing to say"}
	_remove(slot)
	var holder = Node2D.new()
	holder.name = "BudokSpeech"
	# Above both fighters and their effects.
	holder.z_index = 100
	holder.z_as_relative = false
	var panel = PanelContainer.new()
	panel.theme = _theme
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.08, 0.85)
	style.border_color = Color(1, 1, 1, 0.9)
	style.set_border_width_all(1)
	for margin in [MARGIN_LEFT, MARGIN_TOP, MARGIN_RIGHT, MARGIN_BOTTOM]:
		style.set_default_margin(margin, 3)
	panel.add_stylebox_override("panel", style)
	var label = Label.new()
	label.text = line
	label.align = Label.ALIGN_CENTER
	label.autowrap = true
	panel.add_child(label)
	holder.add_child(panel)
	fighter.add_child(holder)
	# Measured in the tree, with the game's font: short lines stay on one line.
	var font = label.get_font("font")
	label.rect_min_size.x = min(MAX_WIDTH, (font.get_string_size(line).x if font != null else MAX_WIDTH) + 2)
	var seconds = clamp(float(runtime.config.get_value("misc.bubble_seconds", 4)), 1.0, 30.0) + line.length() / 30.0
	_bubbles[slot] = {"holder": holder, "panel": panel, "fighter": fighter, "until": OS.get_ticks_msec() + int(seconds * 1000.0)}
	_place(_bubbles[slot])
	return {"ok": true, "shown": line}


# One line of plain text, at most MAX_CHARS.
static func clean(text: String) -> String:
	var out = ""
	for character in text.strip_edges().replace("\n", " ").replace("\t", " "):
		if character.ord_at(0) >= 32:
			out += character
	while out.find("  ") != -1:
		out = out.replace("  ", " ")
	return out if out.length() <= MAX_CHARS else out.substr(0, MAX_CHARS - 3) + "..."


func _process(_delta: float) -> void:
	for slot in _bubbles.keys():
		var bubble = _bubbles[slot]
		var left = (bubble["until"] - OS.get_ticks_msec()) / 1000.0
		if left <= 0.0 or not Util.valid(bubble["holder"]):
			_remove(slot)
			continue
		bubble["holder"].modulate.a = clamp(left / FADE_S, 0.0, 1.0)
		_place(bubble)


# Above the head, extending away from the opponent. A wrapping label is first
# measured at zero width, which makes its container very tall, and containers
# never shrink by themselves; resetting the size makes it fit the text again.
static func _place(bubble: Dictionary) -> void:
	var panel = bubble["panel"]
	panel.rect_size = Vector2.ZERO
	var toward = Util.as_int(Util.call_or(bubble["fighter"], "get_opponent_dir", [], 0))
	var x = -panel.rect_size.x / 2.0
	if toward > 0:
		x = OVERHANG - panel.rect_size.x
	elif toward < 0:
		x = -OVERHANG
	panel.rect_position = Vector2(x, -ABOVE - panel.rect_size.y).round()


func _remove(slot: String) -> void:
	var bubble = _bubbles.get(slot)
	_bubbles.erase(slot)
	if bubble != null and Util.valid(bubble["holder"]):
		bubble["holder"].queue_free()
