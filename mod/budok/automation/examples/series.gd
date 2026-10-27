extends Reference

# Example automation script: plays a short AI-vs-AI series with the token-mode
# AI on both sides and prints the results. Copy it to user://budok/automation.gd
# (or anywhere), set "automation": {"script": "<path>"} in
# user://budok/config.json, and start the game.

const MatchStarter = preload("res://budok/core/MatchStarter.gd")
const GAMES := 3
const P1 := "Ninja"
const P2 := "Cowboy"


func run(runtime) -> void:
	var wins = {"p1": 0, "p2": 0, "draw": 0}
	for game_index in range(GAMES):
		var started = yield(MatchStarter.start(runtime, {
			"p1": P1, "p2": P2,
			"controllers": {"p1": "ai", "p2": "ai"},
			"starting_hp": 600,
		}), "completed")
		if not started.get("ok", false):
			print("series: could not start game %d: %s" % [game_index + 1, started.get("error", "")])
			return
		var result = yield(runtime.matches, "match_ended")
		wins[result["winner"]] += 1
		print("series: game %d -> %s (hp %s)" % [game_index + 1, result["winner"], result["hp"]])
		# Give the game a moment before the next start (it begins replaying the match).
		yield(runtime.get_tree().create_timer(3.0), "timeout")
	print("series finished: %s" % wins)
