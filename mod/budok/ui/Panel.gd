extends CanvasLayer

# F8 overlay with the same settings tabs as the game's Mod List entry
# (ui/SettingsView.gd), plus a small corner button to open it.

const Util = preload("res://budok/core/Util.gd")
const SettingsView = preload("res://budok/ui/SettingsView.gd")
# The game's own UI theme (small pixel font). The game draws at 640x360 and
# scales up, so Godot's default theme would be several times too big.
const GAME_THEME := "res://theme.tres"
const WIDTH := 420

var runtime = null
var view = null
var _root: PanelContainer = null
var _toggle: Button = null
var _show_button := true
var _refresh_timer := 0.0


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	layer = 120
	var game_theme = load(GAME_THEME) if ResourceLoader.exists(GAME_THEME) else null
	# Anchored top-right; the button grows leftwards to fit its text.
	_toggle = Button.new()
	_toggle.text = "budok"
	_toggle.theme = game_theme
	_toggle.anchor_left = 1.0
	_toggle.anchor_right = 1.0
	_toggle.margin_left = -4
	_toggle.margin_right = -4
	_toggle.margin_top = 2
	_toggle.margin_bottom = 2
	_toggle.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_toggle.connect("pressed", self, "toggle")
	add_child(_toggle)
	# Right side of the screen, full height below the button.
	_root = PanelContainer.new()
	_root.theme = game_theme
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.anchor_bottom = 1.0
	_root.margin_left = -WIDTH - 4
	_root.margin_right = -4
	_root.margin_top = 18
	_root.margin_bottom = -4
	add_child(_root)
	var tabs = TabContainer.new()
	_root.add_child(tabs)
	view = SettingsView.new(runtime)
	view.build_into(tabs)
	_root.visible = bool(runtime.config.get_value("ui.show_on_start", false))
	runtime.connect("status_changed", self, "_on_status_changed")
	_on_status_changed()


func toggle() -> void:
	_root.visible = not _root.visible
	if _root.visible:
		view.refresh()


func _on_status_changed() -> void:
	_show_button = bool(runtime.config.get_value("ui.show_button", true))
	if _root.visible:
		view.refresh_status()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key = OS.find_scancode_from_string(str(runtime.config.get_value("ui.toggle_key", "F8")))
		if key != 0 and event.scancode == key:
			toggle()
			get_tree().set_input_as_handled()


func _process(delta: float) -> void:
	# The Mod List already shows these settings, and the button would cover
	# its title bar.
	_toggle.visible = _show_button and not (runtime.mod_menu != null and runtime.mod_menu.showing())
	if not _root.visible:
		return
	_refresh_timer += delta
	if _refresh_timer >= 1.0:
		_refresh_timer = 0.0
		view.refresh_status()
