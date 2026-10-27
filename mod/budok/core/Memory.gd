extends Reference

# Long-term memory that bots keep in this game install: short notes about a
# character, a matchup ("Ninja vs Tester": playing Ninja against Tester) or the
# game in general. Bots write them with the remember tool at any time, and the
# in-game AI after its matches; later matches show them again. One JSON file per
# subject in user://budok/memory, so players can read, share or delete them.
# Each note records who wrote it, so a bot can recall only its own.

const Util = preload("res://budok/core/Util.gd")
const DIR := "user://budok/memory"
const GENERAL := "general"
const MAX_TEXT := 600
const MAX_TAGS := 8

var max_per_subject := 100


static func subject_for(character: String, opponent: String) -> String:
	if character != "" and opponent != "":
		return "matchup:%s vs %s" % [character, opponent]
	if character != "":
		return "character:" + character
	if opponent != "":
		return "character:" + opponent
	return GENERAL


func remember(character: String, opponent: String, text: String, tags, author: String, context: Dictionary = {}) -> Dictionary:
	text = text.strip_edges()
	if text == "":
		return {"ok": false, "error": "text is empty"}
	if text.length() > MAX_TEXT:
		return {"ok": false, "error": "keep a memory under %d characters (this one has %d); split it up" % [MAX_TEXT, text.length()]}
	var subject = subject_for(character, opponent)
	var data = _load(subject)
	var entry = {"id": "%s#%s" % [_file_stem(subject), Util.random_hex(3)], "text": text, "by": author,
		"at": Time.get_datetime_string_from_system()}
	var clean_tags = []
	for tag in tags if tags is Array else []:
		if clean_tags.size() < MAX_TAGS and str(tag).strip_edges() != "":
			clean_tags.append(Util.truncate(str(tag).strip_edges(), 40))
	if not clean_tags.empty():
		entry["tags"] = clean_tags
	if not context.empty():
		entry["match"] = context
	data["entries"].append(entry)
	while data["entries"].size() > max_per_subject:
		data["entries"].pop_front()
	_save(subject, data)
	return {"ok": true, "id": entry["id"], "subject": subject, "count": data["entries"].size()}


# Memories about these characters (their own notes, the matchups between them,
# and general ones), newest first. No characters means every subject.
func recall(characters: Array, query: String = "", limit: int = 20, author: String = "") -> Array:
	var subjects = []
	if characters.empty():
		subjects = _all_subjects()
	else:
		subjects.append(GENERAL)
		for character in characters:
			subjects.append(subject_for(character, ""))
		for a in characters:
			for b in characters:
				if a != b:
					subjects.append(subject_for(a, b))
		if characters.size() == 1:
			for subject in _all_subjects():
				if subject.begins_with("matchup:%s vs " % characters[0]) or subject.ends_with(" vs " + characters[0]):
					subjects.append(subject)
	var found = []
	var needle = query.strip_edges().to_lower()
	for subject in subjects:
		for entry in _load(subject)["entries"]:
			if author != "" and str(entry.get("by", "")) != author:
				continue
			if needle != "" and (str(entry["text"]) + " " + PoolStringArray(entry.get("tags", [])).join(" ")).to_lower().find(needle) == -1:
				continue
			var shown = entry.duplicate()
			shown["subject"] = subject
			found.append(shown)
	found.sort_custom(NewestFirst.new(), "before")
	return found.slice(0, limit - 1) if found.size() > limit else found


func forget(id: String) -> Dictionary:
	var stem = id.split("#")[0]
	for subject in _all_subjects():
		if _file_stem(subject) != stem:
			continue
		var data = _load(subject)
		for i in range(data["entries"].size()):
			if data["entries"][i]["id"] == id:
				data["entries"].remove(i)
				_save(subject, data)
				return {"ok": true, "forgot": id}
	return {"ok": false, "error": "no memory with id %s" % id}


# How many memories mention a character (own subject plus its matchups).
func count_for(character: String) -> int:
	return recall([character], "", 100000).size() - _load(GENERAL)["entries"].size()


func clear_for(character: String) -> int:
	var removed = 0
	var dir = Directory.new()
	for subject in _all_subjects():
		if subject == subject_for(character, "") or subject.begins_with("matchup:%s vs " % character) or subject.ends_with(" vs " + character):
			removed += _load(subject)["entries"].size()
			dir.remove(_path(subject))
	return removed


# Short lines for prompts and turn views: "[Tester] text".
static func lines(entries: Array, max_chars: int = 200) -> Array:
	var out = []
	for entry in entries:
		var label = str(entry.get("subject", "")).replace("character:", "").replace("matchup:", "")
		out.append("[%s] %s" % [label, Util.truncate(str(entry["text"]), max_chars)])
	return out


func _all_subjects() -> Array:
	var subjects = []
	var dir = Directory.new()
	if dir.open(DIR) != OK:
		return subjects
	dir.list_dir_begin(true, true)
	var name = dir.get_next()
	while name != "":
		if name.ends_with(".json"):
			var data = Util.read_json("%s/%s" % [DIR, name])
			if data is Dictionary and data.has("subject"):
				subjects.append(str(data["subject"]))
		name = dir.get_next()
	return subjects


func _load(subject: String) -> Dictionary:
	var data = Util.read_json(_path(subject))
	if not (data is Dictionary) or not (data.get("entries") is Array):
		data = {"subject": subject, "entries": []}
	return data


func _save(subject: String, data: Dictionary) -> void:
	Util.ensure_dir(DIR)
	Util.write_json(_path(subject), data)


static func _file_stem(subject: String) -> String:
	return Util.safe_file_name(subject)


static func _path(subject: String) -> String:
	return "%s/%s.json" % [DIR, _file_stem(subject)]


class NewestFirst:
	func before(a, b) -> bool:
		return str(a.get("at", "")) > str(b.get("at", ""))
