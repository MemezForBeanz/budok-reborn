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
| `controllers.*` values | | `human` (you), `mcp` (a connected chatbot), `ai` (chat model with your API key, `ai.play`) or `decision` (decision model such as Jev, `ai.decide`). |
| `turns.timeout_s.mcp` / `.ai` / `.decision` | `0` / `120` / `120` | Seconds before a bot-controlled turn falls back (0 = wait forever). |
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

Play only: `allow_simulation`, `max_simulations` (per turn), `memory_turns`, `reflect_after_match` (after
each match, let the model save 1-3 lessons as memories; one short request), `style` (free text such as
"aggressive rushdown"), `risk` (`cautious`, `balanced` or `reckless`).
Annotate only: `batch_size` (moves per request), `include_source` and `max_source_chars` (attach code of
code-driven moves).

Keys: `ai.providers.<name>.api_key`, or the environment variable in `api_key_env`
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`). `ai.providers.local.base_url` points at any
OpenAI-compatible server (default Ollama, `http://127.0.0.1:11434/v1`).

## ai.decide: decision models (controller `decision`)

Decision models such as TypeSafe's Jev don't chat: they pick one of a fixed list of options and give a
probability for each. budok builds the options and the facts, and looks ahead on the real engine. Each turn:

1. One request ranks your moves and predicts the opponent's (two questions, one request).
2. Your `candidates` likeliest moves are played on the engine against the opponent's `replies` likeliest
   replies, up to the next decision point.
3. `threads` lines play on from there for `depth` turns in all. At every decision point inside a line the
   model picks both fighters' moves, and the picks are drawn from its probabilities so lines differ.
4. A last request picks among the candidates, each now described with what the engine showed. The move
   is drawn from its probabilities (`pick: sample`, so the bot is hard to read) or is the likeliest
   (`pick: best`).

| Key | Default | Meaning |
|---|---|---|
| `provider` | `vercel` | `vercel` (AI Gateway, `ai.providers.vercel`) or `typesafe` (TypeSafe's own API, `ai.providers.typesafe`). |
| `model` | `typesafe-ai/jev` | Decision model ID. With `typesafe`, a TypeSafe model such as `jev-latest` (empty uses TypeSafe's default). |
| `depth` | `10` | Turns each line plays, counting the move being chosen (up to 30). `1` only plays the next turn for each candidate and reply; `0` turns simulations off, so the first request decides. |
| `threads` | `4` | Lines that go deep, run at the same time (up to 16). They are spread over the candidates. |
| `candidates` / `replies` | `4` / `3` | Your moves compared, and opponent replies each one is tested against. Every pair gets at least a one-turn line. |
| `max_options` | `48` | Options per question (the API allows 255). Each move's default input comes first, then other aims, directions or slider values. |
| `pick` | `sample` | `sample` draws from the last request's probabilities (never options under 10% of the likeliest); `best` takes the likeliest. |
| `think_s` | `30` | Thinking time per turn. Lines stop in time for the last request; it is kept 5 s under `turns.timeout_s.decision`. |
| `request_timeout_s` | `20` | Per request. |
| `frame_budget_ms` | `8` | Engine time all lines may use per frame. Higher thinks faster but makes the game less smooth. |
| `extra_body` | `{}` | Merged into every request body. |

Cost and speed: one request per turn of each deep line, plus two. Depth 10 with 4 lines is about 40
requests a turn for each decision bot; depth 30 with 8 lines is about 240. Each line also needs its own
copy of the match (about 80 ms of engine work each), and engine time per frame is capped, so a turn takes
several seconds even with an instant model. Character notes and post-match lessons still come from chat
models (`ai.annotate`, the notes agent); the decision bot only reads them.

Keys: `ai.providers.vercel.api_key` (or `AI_GATEWAY_API_KEY`), `ai.providers.typesafe.api_key` (or
`TYPESAFE_API_KEY`).

## other

| Key | Default | Meaning |
|---|---|---|
| `schemas.registry_enabled` / `registry_url` | `false` / `""` | Opt-in community registry (HTTPS). Files are looked up as `<url>/<fingerprint>.json`. |
| `schemas.auto.enabled` | `true` | Write missing character notes automatically (Characters tab → Automatic notes). |
| `schemas.auto.use_agent` | `true` | A separate notes agent writes them, in its own context: budok starts Claude Code in the background (`claude -p`, with your Claude login, only budok's notes tools allowed, output in `user://budok/agent/agent.log`) and it exits when the queue is empty. A second chat running the `notes_worker` prompt counts as a notes agent too, and budok then starts none. |
| `schemas.auto.agent_command` | `claude` | The Claude Code command or its full path. budok also looks in the usual install folders (`~/.local/bin`, npm's global folder, Homebrew), since a game started by Steam may not see your shell's `PATH`. Not changeable over MCP. |
| `schemas.auto.agent_model` | `""` | Model for the notes agent (`--model`); empty uses Claude Code's default. |
| `schemas.auto.use_api` | `true` | The in-game AI writes them with your API key (settings `ai.annotate`), side by side with the notes agent. |
| `schemas.auto.use_player` | `false` | Hand jobs to the chatbot that is playing, before its first move, but only when no notes agent is available. |
| `schemas.auto.when` | `matches` | `matches`: only for the characters of a match. `connect`: every character without notes, when the game boots and when a chatbot first claims a slot. |
| `schemas.auto.match_start` | `true` | When a match starts and its character or opponent has no notes, write them first; bots wait for them before their first move (their turn timer waits too). |
| `source_access.enabled` / `max_file_bytes` | `true` / `200000` | Read-only `res://` access for bots. |
| `automation.script` | `""` | GDScript with `func run(runtime)` started after boot. |
| `ui.show_button` / `toggle_key` / `show_on_start` | `true` / `F8` / `false` | Corner button, overlay key, open on start. |
| `logging.match_logs` | `true` | Write `user://budok/matches/<time>_<p1>_vs_<p2>.json` after each match. |
| `memory.enabled` | `true` | Bots may save and recall memories (`user://budok/memory/<subject>.json`, one file per character, matchup or `general`). |
| `memory.shown_per_match` | `6` | Memories shown at match start (in `start_match`, the first turn and the token-mode prompt). |
| `memory.max_per_subject` | `100` | Oldest memories of a subject are dropped past this. |
