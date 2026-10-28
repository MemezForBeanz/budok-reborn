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
	# Stand-in for the game's Options window: a column of toggles ending in Back.
	var options = PanelContainer.new()
	options.name = "OptionsContainer"
	var column = VBoxContainer.new()
	for toggle_name in ["FullscreenButton", "MusicButton", "OptionsBackButton"]:
		var toggle = Button.new() if toggle_name == "OptionsBackButton" else CheckButton.new()
		toggle.name = toggle_name
		column.add_child(toggle)
	options.add_child(column)
	main.add_child(options)
	root.add_child(main)
	yield(create_timer(2.5), "timeout")
	var runtime = _mod.runtime
	check(runtime.mod_menu.attached(), "settings attached to the Mod List entry")
	var options_button = column.get_node_or_null("BudokSettingsButton")
	check(options_button != null and options_button.get_index() == column.get_node("OptionsBackButton").get_index() - 1, "budok button sits above Back in the Options window")
	options_button.emit_signal("pressed")
	check(runtime.panel._root.visible and not options.visible, "Options button opens the budok overlay")
	runtime.panel.toggle()
	var titles = []
	for i in range(budok_tabs.get_tab_count()):
		titles.append(budok_tabs.get_tab_title(i))
	print("tabs: ", titles)
	check(titles == ["Mod Info", "Play", "Models", "Chatbots", "Characters"], "Mod Info kept and budok's four tabs added")
	var view = runtime.mod_menu.view
	var model_field = view._fields["ai.annotate.model"]["control"]
	model_field.text = "claude-sonnet-5-5"
	# The key field follows the provider picked for the role.
	var provider = view._fields["ai.annotate.provider"]["control"]
	for i in range(provider.get_item_count()):
		if provider.get_item_metadata(i) == "openai":
			provider.select(i)
	view._on_role_provider_changed(-1, "annotate")
	view._role_keys["annotate"]["key"].text = "sk-test"
	view._fields["controllers.p2"]["control"].select(2)
	view._on_add_endpoint()
	var card = view._endpoint_cards[view._endpoint_cards.size() - 1]
	card["model"].text = "jev-preview"
	card["key"].text = "ts-test"
	view._on_save()
	check(runtime.config.get_value("ai.annotate.model") == "claude-sonnet-5-5", "model change saved")
	check(runtime.config.api_key("openai") == "sk-test", "API key saved for the role's provider")
	check(runtime.matches.controllers["p2"] == "ai", "controller applied immediately")
	var endpoints = runtime.config.get_value("ai.core.endpoints")
	check(endpoints.size() == 2 and endpoints[1]["model"] == "jev-preview" and endpoints[1]["api_key"] == "ts-test", "decision model added with its own key")
	check(runtime.core.capacity() == 4, "only decision models with a key count")
	var saved = load("res://budok/core/Util.gd").read_json("user://budok/config.json")
	check(saved["ai"]["annotate"]["model"] == "claude-sonnet-5-5", "config file written")
	check(view._role_keys["annotate"]["key"].text == "", "key field cleared after save")
	check(view._endpoint_cards[1]["key"].text == "" and view._endpoint_cards[1]["key"].placeholder_text.begins_with("saved"), "decision key kept hidden after save")
	view._on_save()
	check(runtime.config.get_value("ai.core.endpoints")[1]["api_key"] == "ts-test", "saving again keeps the hidden key")
	view._on_remove_endpoint(view._endpoint_cards[0]["box"])
	view._on_save()
	check(runtime.config.get_value("ai.core.endpoints").size() == 1 and runtime.config.get_value("ai.core.endpoints")[0]["model"] == "jev-preview", "decision model removed")
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
