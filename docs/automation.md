# Automation

budok replaced the old headless VM, daemon and tournament pipeline with two lighter options. Both use
the same API as the MCP tools.

## In-game GDScript

Set `automation.script` in `user://budok/config.json` to a script path (`user://...` or `res://...`):

```gdscript
extends Reference

const MatchStarter = preload("res://budok/core/MatchStarter.gd")

func run(runtime) -> void:
    var started = yield(MatchStarter.start(runtime, {"p1": "Ninja", "p2": "Tester",
        "controllers": {"p1": "ai", "p2": "ai"}}), "completed")
    var result = yield(runtime.matches, "match_ended")
    print(result)
```

Useful entry points: `runtime.matches` (controllers, turn views, `submit`, `simulate`, signals
`turn_opened`, `match_started` and `match_ended`), `runtime.schemas` (describe and submit notes),
`runtime.annotator.start(entry)`, `runtime.roster` and `runtime.config`. A complete example is
`mod/budok/automation/examples/series.gd`.

## External (Python or anything that speaks MCP)

`connectors/python/budok_connector.py` uses only the standard library:

```bash
export BUDOK_TOKEN=...   # from the panel
python connectors/python/budok_connector.py status
python connectors/python/budok_connector.py series --p1 Ninja --p2 Cowboy --games 5 --controllers ai ai
```

Use `BudokClient` in your own scripts to play `mcp` slots with any policy: `wait_for_turn` →
your logic → `submit_action`. Match logs are written to `user://budok/matches/` for analysis.
