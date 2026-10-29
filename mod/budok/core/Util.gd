extends Reference

# Stateless helpers shared by every budok script. Everything here is static so
# scripts can `const Util = preload(...)` without creating instances.
# Game objects are accessed by duck typing only: the mod must keep loading even
# if a game update renames a class, so we never reference game class_names.


# The first node named `name` under `root` (depth first), without looking
# inside `skip`: Node.find_node walks every node, and a match (each of
# budok's previews too) holds thousands, none of them UI.
static func find_named(root: Node, name: String, skip: Array = []):
	var stack = [root]
	while not stack.empty():
		var node = stack.pop_back()
		if str(node.name) == name:
			return node
		if node in skip:
			continue
		var children = node.get_children()
		for i in range(children.size() - 1, -1, -1):
			stack.append(children[i])
	return null


# The game worlds a UI search can skip: the live match and the previews.
static func game_worlds(runtime) -> Array:
	var out = []
	var current = prop(autoload("Global"), "current_game", null)
	if valid(current):
		out.append(current)
	var sandbox = prop(prop(runtime, "simulator", null), "_sandbox", null)
	if valid(sandbox):
		out.append(sandbox)
	return out


static func has_prop(obj, name: String) -> bool:
	if obj == null:
		return false
	if obj is Dictionary:
		return obj.has(name)
	if not (obj is Object) or not is_instance_valid(obj):
		return false
	return name in obj


static func prop(obj, name: String, default_value = null):
	if not has_prop(obj, name):
		return default_value
	if obj is Dictionary:
		return obj[name]
	var value = obj.get(name)
	return default_value if value == null else value


static func call_or(obj, method: String, args: Array = [], default_value = null):
	if obj == null or not (obj is Object) or not is_instance_valid(obj):
		return default_value
	if not obj.has_method(method):
		return default_value
	return obj.callv(method, args)


# Script constants (MAX_SUPER_METER, ...) are not properties, so `in` misses them.
static func constant(obj, name: String, default_value = null):
	if not valid(obj):
		return default_value
	var script = obj.get_script()
	while script != null:
		var constants = script.get_script_constant_map()
		if constants.has(name):
			return constants[name]
		script = script.get_base_script()
	return default_value


static func valid(obj) -> bool:
	return obj != null and obj is Object and is_instance_valid(obj)


# Autoloads (Global, Network, ReplayManager, ...) are looked up at runtime so a
# renamed singleton in a future build degrades one feature instead of failing
# to compile the whole mod.
static func autoload(name: String):
	var tree = Engine.get_main_loop()
	if tree == null or not (tree is SceneTree):
		return null
	return tree.root.get_node_or_null(name)


# Visible relative to `root`: ignores whether root's ancestors are shown, so a
# deliberately hidden bot panel still reports its options. include_root also
# requires root itself to be visible.
static func visible_within(node, root, include_root: bool = true) -> bool:
	var current = node
	while valid(current):
		if current == root and not include_root:
			return true
		if current is CanvasItem and not current.visible:
			return false
		if current == root:
			return true
		current = current.get_parent()
	return false


static func now_ms() -> int:
	return OS.get_ticks_msec()


static func random_hex(byte_count: int = 16) -> String:
	var crypto = Crypto.new()
	return crypto.generate_random_bytes(byte_count).hex_encode()


# Godot prints NaN and infinity as bare nan / inf, which is not JSON (clients
# then drop the whole reply), so non-finite numbers become null.
static func json_str(value, sorted: bool = false, indent: String = "") -> String:
	var text = JSON.print(value, indent, sorted)
	if _has_non_finite(text):
		text = JSON.print(finite(value), indent, sorted)
	return text


static func _has_non_finite(text: String) -> bool:
	for token in ["nan", "inf"]:
		var at = text.find(token)
		while at != -1:
			var start = at - 1 if at > 0 and text[at - 1] != "-" else at - 2
			var before = text[start] if start >= 0 else ""
			var after = text[at + token.length()] if at + token.length() < text.length() else ""
			if before in [":", ",", "[", " ", "\t", "\n"] and after in ["", ",", "}", "]", " ", "\t", "\n", "\r"]:
				return true
			at = text.find(token, at + 1)
	return false


static func finite(value):
	match typeof(value):
		TYPE_REAL:
			return null if is_nan(value) or is_inf(value) else value
		TYPE_DICTIONARY:
			var out = {}
			for key in value:
				out[key] = finite(value[key])
			return out
		TYPE_ARRAY:
			var out_array = []
			for item in value:
				out_array.append(finite(item))
			return out_array
	return value


static func json_parse(text: String) -> Dictionary:
	var result = JSON.parse(text)
	if result.error != OK:
		return {"ok": false, "error": "%s at line %d" % [result.error_string, result.error_line]}
	return {"ok": true, "value": result.result}


static func ensure_dir(path: String) -> void:
	var dir = Directory.new()
	if not dir.dir_exists(path):
		dir.make_dir_recursive(path)


static func file_exists(path: String) -> bool:
	var file = File.new()
	return file.file_exists(path)


static func read_text(path: String, max_bytes: int = -1):
	var file = File.new()
	if not file.file_exists(path):
		return null
	if file.open(path, File.READ) != OK:
		return null
	var text = ""
	if max_bytes > 0 and file.get_len() > max_bytes:
		text = file.get_buffer(max_bytes).get_string_from_utf8()
	else:
		text = file.get_as_text()
	file.close()
	return text


static func write_text(path: String, text: String) -> bool:
	ensure_dir(path.get_base_dir())
	var file = File.new()
	if file.open(path, File.WRITE) != OK:
		return false
	file.store_string(text)
	file.close()
	return true


static func read_json(path: String):
	var text = read_text(path)
	if text == null:
		return null
	var parsed = json_parse(text)
	return parsed.get("value") if parsed["ok"] else null


static func write_json(path: String, value) -> bool:
	return write_text(path, json_str(value, true, "  "))


static func deep_merge(base: Dictionary, override: Dictionary) -> Dictionary:
	var result = base.duplicate(true)
	for key in override:
		if result.has(key) and result[key] is Dictionary and override[key] is Dictionary:
			result[key] = deep_merge(result[key], override[key])
		elif override[key] is Dictionary or override[key] is Array:
			result[key] = override[key].duplicate(true)
		else:
			result[key] = override[key]
	return result


static func dig(data: Dictionary, path: String, default_value = null):
	var node = data
	for part in path.split("."):
		if not (node is Dictionary) or not node.has(part):
			return default_value
		node = node[part]
	return node


static func plant(data: Dictionary, path: String, value) -> void:
	var parts = path.split(".")
	var node = data
	for i in range(parts.size() - 1):
		if not node.has(parts[i]) or not (node[parts[i]] is Dictionary):
			node[parts[i]] = {}
		node = node[parts[i]]
	node[parts[parts.size() - 1]] = value


static func strip_trailing_digits(text: String) -> String:
	var result = text
	while result.length() > 0 and result[-1] >= "0" and result[-1] <= "9":
		result = result.substr(0, result.length() - 1)
	return result if result != "" else text


static func safe_file_name(text: String) -> String:
	var result = ""
	for i in range(text.length()):
		var c = text[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c in ["-", "_", "."]:
			result += c
		else:
			result += "_"
	return result


static func truncate(text: String, max_chars: int) -> String:
	if max_chars <= 0 or text.length() <= max_chars:
		return text
	return text.substr(0, max_chars) + "... [truncated %d chars]" % (text.length() - max_chars)


# Game state mixes ints, floats, fixed-point strings ("1.25"), Vector2 and
# node references. Convert to plain JSON-friendly values, dropping objects.
static func json_safe(value, depth: int = 0):
	if depth > 6:
		return null
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_REAL:
			return stepify(value, 0.001)
		TYPE_STRING:
			return truncate(value, 200)
		TYPE_VECTOR2:
			return {"x": stepify(value.x, 0.001), "y": stepify(value.y, 0.001)}
		TYPE_DICTIONARY:
			var out = {}
			var count = 0
			for key in value:
				if count >= 40:
					break
				var converted = json_safe(value[key], depth + 1)
				if converted != null or value[key] == null:
					out[str(key)] = converted
				count += 1
			return out
		TYPE_ARRAY, TYPE_INT_ARRAY, TYPE_REAL_ARRAY, TYPE_STRING_ARRAY:
			var out_array = []
			for item in value:
				if out_array.size() >= 24:
					break
				var converted_item = json_safe(item, depth + 1)
				if converted_item != null:
					out_array.append(converted_item)
			return out_array
	return null


# Fixed-point game values arrive as strings like "-3.5". Return a float when
# the value is numeric, otherwise the value untouched.
static func numeric(value):
	if value is String and value.is_valid_float():
		return float(value)
	return value


static func as_int(value, default_value: int = 0) -> int:
	if value is int:
		return value
	if value is float:
		return int(round(value))
	if value is String and value.is_valid_float():
		return int(round(float(value)))
	if value is bool:
		return 1 if value else 0
	return default_value


static func xy(value) -> Dictionary:
	# get_pos()/get_vel() return Vector2 or {"x", "y"} dictionaries depending on build.
	if value is Vector2:
		return {"x": int(round(value.x)), "y": int(round(value.y))}
	if value is Dictionary:
		return {"x": as_int(numeric(value.get("x", 0))), "y": as_int(numeric(value.get("y", 0)))}
	return {"x": 0, "y": 0}


static func script_chain(obj) -> Array:
	var paths = []
	if not valid(obj):
		return paths
	var script = obj.get_script()
	while script != null:
		if script.resource_path != "":
			paths.append(script.resource_path)
		script = script.get_base_script()
	return paths


static func enum_name(keys: Array, index) -> String:
	var i = as_int(index, -1)
	if i >= 0 and i < keys.size():
		return str(keys[i])
	return str(index)
