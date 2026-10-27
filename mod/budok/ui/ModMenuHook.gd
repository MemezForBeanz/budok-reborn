extends Node

# Puts budok's settings into the game's own Mod List window (main menu →
# Mod List → budok): the mod loader gives every mod a TabContainer with a
# "Mod Info" tab, and we append our settings tabs to it. The window is rebuilt
# with the main scene, so we keep checking and re-attach when needed.
#
# The window is only 400x220 of the game's 640x360 screen, and it also grows
# (and never shrinks) when wrapped labels are first measured at zero width, so
# it can end up taller than the screen. While budok's tab is open we size it to
# the screen; when another mod is picked or the window closes, it gets its own
# size and position back. The title bar's "Open Mods Folder" button sits at a
# fixed x, so it moves with the right edge. The window starts below the corner
# budok button (ui/Panel.gd) so the two never overlap.

const Util = preload("res://budok/core/Util.gd")
const SettingsView = preload("res://budok/ui/SettingsView.gd")
const CHECK_INTERVAL := 1.0
const SCREEN_MARGIN := Vector2(10, 10)
const TOP_MARGIN := 18

var runtime = null
var view = null
var _container = null
var _menu = null
var _home := Rect2()
var _folder_button = null
var _folder_button_x := 0.0
var _timer := 0.0


func setup(runtime_ref) -> void:
	runtime = runtime_ref


func attached() -> bool:
	return Util.valid(_container)


func showing() -> bool:
	return Util.valid(_container) and Util.valid(_menu) and _menu.is_visible_in_tree() and _container.is_visible_in_tree()


func _process(delta: float) -> void:
	var showing = showing()
	if showing and _menu.rect_size != _fit_size():
		_fit()
	_timer += delta
	if _timer < CHECK_INTERVAL:
		return
	_timer = 0.0
	if Util.valid(_container):
		if showing and view != null:
			view.refresh_status()
		return
	var menu = _find_menu(get_tree().root, 0) if get_tree() != null else null
	var container = _find_mod_tab(menu)
	if container == null:
		return
	_menu = menu
	_container = container
	_home = Rect2(menu.rect_position, menu.rect_size)
	_folder_button = menu.get_node_or_null("VBoxContainer/TitleBar/ModsLocation")
	if _folder_button != null:
		_folder_button_x = _folder_button.rect_position.x
	container.connect("visibility_changed", self, "_on_visibility_changed")
	view = SettingsView.new(runtime)
	view.build_into(container)
	print("budok: settings added to the Mod List window")


func _on_visibility_changed() -> void:
	if not (Util.valid(_menu) and Util.valid(_container)):
		return
	if _container.is_visible_in_tree():
		_fit()
	else:
		_menu.rect_size = _home.size
		_menu.rect_position = _home.position
		_place_folder_button()


func _fit_size() -> Vector2:
	return (_menu.get_viewport_rect().size - Vector2(SCREEN_MARGIN.x * 2, SCREEN_MARGIN.y + TOP_MARGIN)).floor()


func _fit() -> void:
	_menu.rect_size = _fit_size()
	_menu.rect_position = Vector2(SCREEN_MARGIN.x, TOP_MARGIN)
	_place_folder_button()


func _place_folder_button() -> void:
	if Util.valid(_folder_button):
		_folder_button.rect_position.x = _folder_button_x + _menu.rect_size.x - _home.size.x


func _find_mod_tab(menu):
	if menu == null:
		return null
	var info = Util.prop(menu, "info_container", null)
	if not Util.valid(info):
		return null
	# Exact name first: other mods (budok's test fighter) can start with "budok" too.
	var friendly = _friendly_name()
	for prefix in [friendly, "budok -"]:
		for child in info.get_children():
			var child_name = str(child.name)
			if child is TabContainer and (child_name == friendly or child_name.begins_with(prefix)):
				return child
	return null


# The Mod List window is the node holding both the mod buttons and the per-mod
# info tabs (ModLoaderMenu.gd); matched by shape so a moved script still works.
func _find_menu(node: Node, depth: int):
	if Util.has_prop(node, "info_container") and Util.has_prop(node, "list_container") and node.has_method("add_mod"):
		return node
	if depth > 6:
		return null
	for child in node.get_children():
		var found = _find_menu(child, depth + 1)
		if found != null:
			return found
	return null


func _friendly_name() -> String:
	var meta = Util.read_json("res://budok/_metadata")
	return str(meta.get("friendly_name", "budok")) if meta is Dictionary else "budok"
