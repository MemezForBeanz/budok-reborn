extends Node

# Puts budok's settings into the game's own Mod List window (main menu →
# Mod List → budok): the mod loader gives every mod a TabContainer with a
# "Mod Info" tab, and we append our settings tabs to it. The window is rebuilt
# with the main scene, so we keep checking and re-attach when needed.

const Util = preload("res://budok/core/Util.gd")
const SettingsView = preload("res://budok/ui/SettingsView.gd")
const CHECK_INTERVAL := 1.0

var runtime = null
var view = null
var _container = null
var _timer := 0.0


func setup(runtime_ref) -> void:
	runtime = runtime_ref


func attached() -> bool:
	return Util.valid(_container)


func _process(delta: float) -> void:
	_timer += delta
	if _timer < CHECK_INTERVAL:
		return
	_timer = 0.0
	if Util.valid(_container):
		if _container.is_visible_in_tree() and view != null:
			view.refresh_status()
		return
	var container = _find_mod_tab()
	if container == null:
		return
	_container = container
	view = SettingsView.new(runtime)
	view.build_into(container)
	print("budok: settings added to the Mod List window")


func _find_mod_tab():
	var tree = get_tree()
	if tree == null:
		return null
	var menu = _find_menu(tree.root, 0)
	if menu == null:
		return null
	var info = Util.prop(menu, "info_container", null)
	if not Util.valid(info):
		return null
	var friendly = _friendly_name()
	for child in info.get_children():
		if child is TabContainer and (str(child.name) == friendly or str(child.name).begins_with("budok")):
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
