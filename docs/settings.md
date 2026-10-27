# Settings

Defaults ship in `mod/budok/config/default_config.json`. Your changes are saved to
`user://budok/config.json`:

| OS | Path |
|---|---|
| Windows | `%APPDATA%\YourOnlyMoveIsHUSTLE\budok\config.json` |
| macOS | `~/Library/Application Support/YourOnlyMoveIsHUSTLE/budok/config.json` |
| Linux | `~/.local/share/YourOnlyMoveIsHUSTLE/budok/config.json` |

Every setting below can be edited in game, under **main menu → Mod List → budok** (or the F8 overlay).

## mcp

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Run the MCP server. |
| `host` / `port` | `127.0.0.1` / `8765` | Listen address. Keep localhost unless you know why. Tunnels connect to localhost anyway. |
| `auth_token` | generated | Bearer token. Regenerate it from the panel. |
| `require_token` | `true` | Turn off only on a fully trusted machine. |
| `allowed_origins` | `[]` | Extra browser origins allowed to call the server. |
| `max_wait_s` | `25` | Upper bound for long-poll waits. |

## controllers, turns, simulation

| Key | Default | Meaning |
|---|---|---|
| `controllers.p1` / `.p2` | `human` / `mcp` | Default controller for matches you start from the game menu. |
| `turns.forced_turns` | `skip_unless_hurt` | Auto-submit Hold when it is the only option: `never`, `skip_unless_hurt` (keeps DI decisions) or `always`. |
| `turns.timeout_s.mcp` / `.ai` | `0` / `120` | Seconds before a bot-controlled turn falls back (0 = wait forever). |
| `turns.fallback_action` | `Continue` | Move played on timeout or AI failure. It must be legal; otherwise Continue is used. |
| `turns.hide_bot_panel` | `true` | Hide a bot's move panel so it can't be clicked by accident. |
| `turns.history_length` | `12` | Turns of history shown to bots. |
| `simulation.enabled` / `.max_ticks` | `true` / `120` | Allow `simulate`, and how far it may look ahead. |

## ai: separate settings for move making and schema creation

`ai.play` (token-mode player) and `ai.annotate` (schema writer) have the same keys:

| Key | Play default | Annotate default | Meaning |
|---|---|---|---|
| `provider` | `anthropic` | `anthropic` | `anthropic`, `openai`, `openrouter` or `local`. |
| `model` | `claude-opus-5-5` | `claude-opus-5-5` | Any model ID the provider accepts. |
| `effort` | `low` | `high` | Anthropic `output_config.effort` (`low` ... `max`). Empty uses the model default. Lower effort makes faster turns. |
| `max_tokens` | `16000` | `16000` | Output cap per request. |
| `temperature` | `null` | `null` | OpenAI-compatible providers only. Anthropic's current API rejects sampling parameters. |
| `request_timeout_s` | `180` | `300` | HTTP timeout. |
| `max_steps` | `6` | `30` | Tool-use steps per turn or per batch. |
| `refusal_fallback` | `true` | `true` | On the Claude API, retry a declined request on a fallback model (`fallbacks: "default"`). |
| `extra_body` | `{}` | `{}` | Merged into every request body (for example `reasoning_effort` for OpenAI reasoning models). |

Play only: `allow_simulation`, `max_simulations` (per turn), `memory_turns`, `style` (free text such as
"aggressive rushdown"), `risk` (`cautious`, `balanced` or `reckless`).
Annotate only: `batch_size` (moves per request), `include_source` and `max_source_chars` (attach code of
code-driven moves), `auto_generate_missing` (annotate characters without notes when a match starts).

Keys: `ai.providers.<name>.api_key`, or the environment variable in `api_key_env`
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`). `ai.providers.local.base_url` points at any
OpenAI-compatible server (default Ollama, `http://127.0.0.1:11434/v1`).

## other

| Key | Default | Meaning |
|---|---|---|
| `schemas.registry_enabled` / `registry_url` | `false` / `""` | Opt-in community registry (HTTPS). Files are looked up as `<url>/<fingerprint>.json`. |
| `source_access.enabled` / `max_file_bytes` | `true` / `200000` | Read-only `res://` access for bots. |
| `automation.script` | `""` | GDScript with `func run(runtime)` started after boot. |
| `ui.show_button` / `toggle_key` / `show_on_start` | `true` / `F8` / `false` | Corner button, overlay key, open on start. |
| `logging.match_logs` | `true` | Write `user://budok/matches/<time>_<p1>_vs_<p2>.json` after each match. |
