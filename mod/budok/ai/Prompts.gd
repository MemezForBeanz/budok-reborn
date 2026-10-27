extends Reference

# Prompt text shared by the MCP prompts (for chatbots) and the in-mod
# token-mode AI. Rules and conventions come from the knowledge pack so there
# is a single source of truth.

const Util = preload("res://budok/core/Util.gd")
const KNOWLEDGE_DIR := "res://budok/knowledge"


static func knowledge(topic: String) -> String:
	var text = Util.read_text("%s/%s.md" % [KNOWLEDGE_DIR, topic])
	return text if text != null else ""


static func character_primer(info: Dictionary, max_moves: int = 60) -> String:
	if info.empty():
		return ""
	var skeleton = info.get("skeleton", {})
	var schema = info.get("schema", {})
	var lines = ["## %s (%s notes)" % [info.get("character", "?"), info.get("status", "missing")]]
	var summary = schema.get("summary", {})
	for key in ["archetype", "game_plan"]:
		if summary.has(key):
			lines.append("- %s: %s" % [key.replace("_", " "), summary[key]])
	for key in ["strengths", "weaknesses", "tips"]:
		if summary.has(key):
			lines.append("- %s: %s" % [key, PoolStringArray(summary[key]).join("; ")])
	var stats = skeleton.get("stats", {})
	if not stats.empty():
		lines.append("- max HP %s, air options %s" % [stats.get("max_health", "?"), stats.get("air_movements", "?")])
	var resources = schema.get("resources", {})
	for key in resources:
		if not bool(resources[key].get("hidden", false)) and resources[key].has("meaning"):
			lines.append("- resource %s: %s" % [resources[key].get("label", key), resources[key]["meaning"]])
	var moves = skeleton.get("moves", {})
	var notes = schema.get("moves", {})
	var names = moves.keys()
	names.sort()
	var count = 0
	for move_name in names:
		if count >= max_moves:
			lines.append("- ... %d more moves (describe_character lists all)" % (names.size() - count))
			break
		var move = moves[move_name]
		var note = notes.get(move_name, {})
		var parts = ["%s [%s]" % [move_name, note.get("category", move.get("type", "?").to_lower())]]
		if move.get("title", move_name) != move_name:
			parts.append("\"%s\"" % move["title"])
		if move.has("frames"):
			parts.append("%df startup, %d dmg%s" % [move["frames"]["startup"], move["frames"]["total_damage"],
				(", reach %d" % move["frames"]["reach"]) if move["frames"].has("reach") else ""])
		if move.get("meter_bars", 0) > 0:
			parts.append("%d bar(s)" % move["meter_bars"])
		if note.has("summary"):
			parts.append("- " + note["summary"])
		lines.append("- " + PoolStringArray(parts).join(" "))
		count += 1
	if info.get("status", "") == "missing":
		lines.append("(No notes yet: rely on frame data, titles and simulate.)")
	return PoolStringArray(lines).join("\n")


static func play_system(runtime, slot: String) -> String:
	var infos = runtime.matches.infos()
	var other = "p2" if slot == "p1" else "p1"
	var play_cfg = runtime.config.get_value("ai.play", {})
	var parts = [
		"You are playing YOMI Hustle as %s. Win the match." % slot,
		knowledge("gameplay"),
		"# Your character\n" + character_primer(infos.get(slot, {})),
		"# Opponent's character\n" + character_primer(infos.get(other, {}), 30),
	]
	var style = str(play_cfg.get("style", ""))
	if style != "":
		parts.append("# Play style requested by the player\n" + style)
	var risk = str(play_cfg.get("risk", "balanced"))
	if risk != "balanced":
		parts.append("Risk appetite: %s." % risk)
	return PoolStringArray(parts).join("\n\n")


static func annotate_system() -> String:
	return PoolStringArray([
		"You write budok character schemas: concise, accurate gameplay notes for YOMI Hustle characters, based on measured data and the character's code.",
		knowledge("annotating"),
		knowledge("characters"),
		knowledge("action-ui"),
	]).join("\n\n")


static func play_match_prompt(runtime, slot: String) -> String:
	return PoolStringArray([
		play_system(runtime, slot),
		"# How to play through the budok tools",
		"1. Call wait_for_turn (slot %s). When status is your_turn you get turn_token, situation, observation, legal_actions and extras." % slot,
		"2. Optionally describe_character for move notes and simulate 1-3 candidate moves against likely opponent answers.",
		"3. Call submit_action with the turn_token. It waits for the turn to resolve and tells you what the opponent did.",
		"4. Repeat until wait_for_turn returns match_over. Keep each turn's reasoning short. Matches have many turns.",
	]).join("\n")


static func annotate_prompt(character: String) -> String:
	return PoolStringArray([
		annotate_system(),
		"# Task",
		"Write the budok schema for **%s**." % character,
		("Start with introspect_character {\"character\": \"%s\"} (page with offset/limit), read scripts of dynamic moves with read_source, " % character)
			+ "then submit notes in batches with submit_character_schema. Finish with the summary and resources. Report coverage at the end.",
	]).join("\n\n")
