# Settings

Defaults ship in `mod/budok/config/default_config.json`. Your changes are saved to
`user://budok/config.json`:

| OS | Path |
|---|---|
| Windows | `%APPDATA%\YourOnlyMoveIsHUSTLE\budok\config.json` |
| macOS | `~/Library/Application Support/YourOnlyMoveIsHUSTLE/budok/config.json` |
| Linux | `~/.local/share/YourOnlyMoveIsHUSTLE/budok/config.json` |

Every setting below can be edited in game. The same four tabs appear under **main menu → Mod List → budok**,
behind the **budok settings** button in the game's Options window, and in the F8 overlay:

| Tab | What is there |
|---|---|
| **Play** | Who plays P1 and P2, and what each chosen mode still needs; folded: turn rules, simulations, interface and logs. |
| **Models** | The chat model, the decision core (its models and keys, and the lookahead) and the notes writer, each with its provider, model and key together; folded: the more detailed settings and provider addresses. |
| **Chatbots** | The MCP server: address, token, copy-paste configs for Claude Desktop and Claude Code. |
| **Characters** | Character notes, automatic notes, memories and the community registry. |

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
| `controllers.*` values | | `human` (you), `mcp` (a connected chatbot), `ai` (chat model with your API key, `ai.play`), `decision` (the decision core) or `tandem` (the chat model leading the decision core). |
| `turns.timeout_s.mcp` / `.ai` / `.decision` / `.tandem` | `0` / `120` / `120` / `180` | Seconds before a bot-controlled turn falls back (0 = wait forever). |
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

## ai.core: the decision core (controllers `decision` and `tandem`, MCP `look_ahead`)

Decision models such as TypeSafe's Jev don't chat: they pick one of a fixed list of options and give a
probability for each. The decision core puts one or more of them behind one dispatcher and uses them to
look ahead on the real engine. For one turn:

1. Unless the caller named them, one request ranks your moves and predicts the opponent's (two questions,
   one request).
2. Your `candidates` moves are played on the engine against `replies` opponent replies, up to the next
   decision point.
3. Deep lines (one per parallel request the core has) play on from there for `depth` turns in all. At
   every decision point inside a line the models pick both fighters' moves, drawn from their
   probabilities so lines differ.
4. A last request ranks the candidates, each now described with what the engine showed.

Who uses it:

- **`decision` controller**: plays the move drawn from that ranking (`ai.decide.pick: sample`, so the
  bot is hard to read) or the top one (`best`).
- **`tandem` controller**: the chat model (`ai.play`) plays and calls the `look_ahead` tool, naming the
  moves and replies to test, how deep to look and a `focus` / `opponent_style` that steer the imagined
  lines. It gets a few lines per move back and decides itself, so the lookahead never fills its context.
- **MCP chatbots**: the same `look_ahead` tool (see [mcp.md](mcp.md)).

`ai.core.endpoints` is a list; each entry is one model with its own key:

| Key | Default | Meaning |
|---|---|---|
| `provider` | `typesafe` | `typesafe` (TypeSafe's own API) or `vercel` (AI Gateway). |
| `model` | `jev-latest` | `jev-latest` or `jev-preview` on TypeSafe; any decision model ID on Vercel (`typesafe-ai/jev`, `baseten/mammoth-1`...). |
| `api_key` | `""` | This entry's key. Empty uses the provider's shared key (`ai.providers.<provider>.api_key`, or `TYPESAFE_API_KEY` / `AI_GATEWAY_API_KEY`). |
| `threads` | `4` | Requests this entry may have running at once. The core's parallel requests are the sum over all entries, and that many deep lines run at a time. |
| `max_rpm` | `0` | Requests per minute to stay under (0 = no limit). budok also learns a limit from the provider's rate-limit errors. |
| `enabled` | `true` | Off keeps the entry but sends it nothing. |

A request goes to the first entry (in list order) with a free slot, so put the best model first; more
entries, or the same model with more keys, add capacity. An entry that fails passes the request to the
next one; a rejected key (401/403) sits out for five minutes, other errors for ten seconds. Under a rate
limit the deep lines get shorter so the requests a turn needs still fit, and requests inside lines never
use an entry's last free request.

Lookahead settings (also `ai.core`):

| Key | Default | Meaning |
|---|---|---|
| `depth` | `10` | Turns each deep line plays, counting the move being chosen (up to 30). `1` only plays the next turn for each candidate and reply; `0` turns simulations off, so the first request decides. |
| `candidates` / `replies` | `4` / `3` | Your moves compared, and opponent replies each one is tested against. Every pair gets at least a one-turn line. |
| `max_options` | `48` | Options per question (the API allows 255). Each move's default input comes first, then other aims, directions or slider values. Lower it for models that reject long lists. |
| `think_s` | `30` | Thinking time per turn, counted from the first answer (waiting for a free request doesn't count). Everything ends 5 s before the turn timeout. |
| `request_timeout_s` | `20` | Per request. |
| `frame_budget_ms` | `8` | Engine time all lines may use per frame. Higher thinks faster but makes the game less smooth. |

`ai.decide.pick` (`sample` or `best`) only affects the decision controller.

Cost and speed: one request per turn of each deep line, plus two. Depth 10 with 4 parallel requests is
about 40 requests a turn. With Jev that took 7-9 s a turn in testing. Each line also needs its own copy of
the match (about 80 ms of engine work), so a turn takes a few seconds even with an instant model.

Which models:

- **Jev with a TypeSafe key**: TypeSafe's default limit is 80 requests a second, so the full lookahead runs.
- **Jev through Vercel** (`typesafe-ai/jev`) needs paid AI Gateway credits.
- **Vercel's free tier** allows 5 requests a minute per model: set `max_rpm` to 5. Free-tier models that
  handled budok's requests well: `baseten/mammoth-1` and `perplexity/pplx-decider-v1.2` (27B),
  `liquid/d1-ultra`. A free model also works as an overflow entry behind Jev. Some models limit the number
  of options per question and reject longer lists with "check it against the model's supported inputs
  and limits" (`convaiinnovations/laya` takes 10 but not 40).

budok 1.3.0 kept one decision model under `ai.decide`; it moves to `ai.core` by itself.

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
