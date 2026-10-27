extends SceneTree

# Boots budok, adds a stand-in for the game's Mod List window and checks that
# the settings tabs get attached, that saving writes config and that the
# overlay toggles. Exit code = failure count.
#   godot --no-window --path mod -s res://tests/ui_smoke.gd

const FAKE_MENU := """extends Control
var info_container
var list_container
func add_mod(_mod):
	pass
"""

var failures := 0
var _mod = null


func _init() -> void:
	_mod = load("res://budok/ModMain.gd").new(null)
	root.call_deferred("add_child", _mod)
	call_deferred("_run")


func check(condition: bool, label: String) -> void:
	if not condition:
		failures += 1
		printerr("FAIL: " + label)
	else:
		print("ok: " + label)


func _run() -> void:
	yield(self, "idle_frame")
	var script = GDScript.new()
	script.source_code = FAKE_MENU
	script.reload()
	var menu = script.new()
	menu.name = "ModLoaderMenu"
	var list = VBoxContainer.new()
	var info = HBoxContainer.new()
	menu.add_child(list)
	menu.add_child(info)
	menu.list_container = list
	menu.info_container = info
	var budok_tabs = TabContainer.new()
	budok_tabs.name = "budok - AI & MCP bridge"
	var mod_info = VBoxContainer.new()
	mod_info.name = "Mod Info"
	budok_tabs.add_child(mod_info)
	info.add_child(budok_tabs)
	menu.rect_size = Vector2(400, 220)
	var main = Control.new()
	main.name = "Main"
	main.add_child(menu)
	root.add_child(main)
	yield(create_timer(2.5), "timeout")
	var runtime = _mod.runtime
	check(runtime.mod_menu.attached(), "settings attached to the Mod List entry")
	var titles = []
	for i in range(budok_tabs.get_tab_count()):
		titles.append(budok_tabs.get_tab_title(i))
	print("tabs: ", titles)
	check(titles.size() == 7 and titles[0] == "Mod Info" and "AI" in titles and "Providers" in titles, "Mod Info kept and budok tabs added")
	var view = runtime.mod_menu.view
	var model_field = view._fields["ai.annotate.model"]["control"]
	model_field.text = "claude-sonnet-5-5"
	view._fields["ai.providers.openai.api_key"]["control"].text = "sk-test"
	view._fields["controllers.p2"]["control"].select(2)
	view._on_save()
	check(runtime.config.get_value("ai.annotate.model") == "claude-sonnet-5-5", "model change saved")
	check(runtime.config.api_key("openai") == "sk-test", "API key saved")
	check(runtime.matches.controllers["p2"] == "ai", "controller applied immediately")
	var saved = load("res://budok/core/Util.gd").read_json("user://budok/config.json")
	check(saved["ai"]["annotate"]["model"] == "claude-sonnet-5-5", "config file written")
	check(view._fields["ai.providers.openai.api_key"]["control"].text == "", "key field cleared after save")
	runtime.panel.toggle()
	check(runtime.panel._root.visible, "overlay opens")
	runtime.panel.toggle()
	view._on_copy_url()
	check(OS.get_clipboard().find("?token=") != -1 or OS.get_name() == "Server", "copy URL")
	# The window fits the screen while budok's tab is open and gets its own
	# size back afterwards.
	budok_tabs.hide()
	yield(self, "idle_frame")
	budok_tabs.show()
	yield(self, "idle_frame")
	var screen = menu.get_viewport_rect().size
	check(menu.rect_size == (screen - Vector2(20, 28)).floor() and menu.rect_position == Vector2(10, 18), "Mod List window fits the screen on the budok tab")
	check(runtime.panel._toggle.visible, "corner button stays visible")
	budok_tabs.hide()
	yield(self, "idle_frame")
	check(menu.rect_size == Vector2(400, 220), "Mod List window size restored")
	quit(failures)
