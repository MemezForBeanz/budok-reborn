extends Node

# Adds a "budok settings" button to the game's own Options window (main menu
# → Options, and Pause → Options during a match), just above its Back button.
# It opens the budok overlay (ui/Panel.gd). The window is rebuilt with the main
# scene, so we keep checking and re-attach when needed.

const Util = preload("res://budok/core/Util.gd")
const CHECK_INTERVAL := 1.0
const BUTTON_NAME := "BudokSettingsButton"

var runtime = null
var _button = null
var _options = null
var _timer := 0.0


func setup(runtime_ref) -> void:
	runtime = runtime_ref


func attached() -> bool:
	return Util.valid(_button)


func _process(delta: float) -> void:
	_timer += delta
	if _timer < CHECK_INTERVAL or Util.valid(_button):
		return
	_timer = 0.0
	var tree = get_tree()
	var options = Util.find_named(tree.root, "OptionsContainer", Util.game_worlds(runtime)) if tree != null else null
	if options == null:
		return
	var back = options.find_node("OptionsBackButton", true, false)
	var list = back.get_parent() if back != null else _settings_list(options)
	if list == null:
		return
	_options = options
	_button = Button.new()
	_button.name = BUTTON_NAME
	_button.text = "budok settings (AI & MCP)"
	_button.connect("pressed", self, "_on_pressed")
	list.add_child(_button)
	if back != null:
		list.move_child(_button, back.get_index())
	print("budok: settings button added to the Options window")


func _on_pressed() -> void:
	if Util.valid(_options) and _options.has_method("hide"):
		_options.hide()
	runtime.panel.open()


# The column of toggles in the Options window, for builds without a Back button.
func _settings_list(options: Node):
	var best = null
	var best_count = 2
	var stack = [options]
	while not stack.empty():
		var node = stack.pop_back()
		var toggles = 0
		for child in node.get_children():
			stack.append(child)
			if child is BaseButton:
				toggles += 1
		if node is VBoxContainer and toggles > best_count:
			best = node
			best_count = toggles
	return best
