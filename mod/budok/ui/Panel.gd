extends CanvasLayer

# F8 overlay with the same settings tabs as the game's Mod List entry
# (ui/SettingsView.gd), plus a small corner button to open it.

const Util = preload("res://budok/core/Util.gd")
const SettingsView = preload("res://budok/ui/SettingsView.gd")

var runtime = null
var view = null
var _root: PanelContainer = null
var _toggle: Button = null
var _refresh_timer := 0.0


func setup(runtime_ref) -> void:
	runtime = runtime_ref
	layer = 120
	_toggle = Button.new()
	_toggle.text = "budok"
	_toggle.anchor_left = 1.0
	_toggle.anchor_right = 1.0
	_toggle.margin_left = -70
	_toggle.margin_right = -4
	_toggle.margin_top = 4
	_toggle.margin_bottom = 26
	_toggle.connect("pressed", self, "toggle")
	add_child(_toggle)
	_root = PanelContainer.new()
	_root.anchor_left = 1.0
	_root.anchor_right = 1.0
	_root.margin_left = -560
	_root.margin_right = -4
	_root.margin_top = 30
	_root.margin_bottom = 620
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
	_toggle.visible = bool(runtime.config.get_value("ui.show_button", true))
	if _root.visible:
		view.refresh_status()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key = OS.find_scancode_from_string(str(runtime.config.get_value("ui.toggle_key", "F8")))
		if key != 0 and event.scancode == key:
			toggle()
			get_tree().set_input_as_handled()


func _process(delta: float) -> void:
	if not _root.visible:
		return
	_refresh_timer += delta
	if _refresh_timer >= 1.0:
		_refresh_timer = 0.0
		view.refresh_status()
