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
| **Play** | Who plays P1 and P2, and what each chosen mode still needs; folded: turn rules, simulations, interface and logs; Misc: speech bubbles and trash talk. |
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
| `turns.timeout_s.mcp` / `.ai` / `.decision` / `.tandem` | `0` / `120` / `120` / `180` | Seconds a bot-controlled turn may take (0 = wait forever). The turn waits for the bot: for chat-model bots (`ai`, `tandem`), 12 s before the limit the decision core takes over and plays its engine pick (the best move of the bot's last `look_ahead` this turn, else a quick one of its own), as a CPU opponent would. |
| `turns.fallback_action` | `Continue` | Move played when no bot or engine pick could be had (an MCP chatbot's timeout, or the engine found nothing). It must be legal; otherwise Continue is used. |
| `turns.hide_bot_panel` | `true` | Hide a bot's move panel (from the frame the game shows it, all turn long), so only the bot locks in its move. |
| `turns.history_length` | `12` | Turns of history shown to bots. |
| `simulation.enabled` / `.max_ticks` | `true` / `120` | Allow `simulate`, and how far it may look ahead. |
| `simulation.reuse_previews` | `true` | Reset and reuse preview games instead of copying the match afresh each time (much faster). Only for the game's own characters: previews of characters from mods are always fresh copies. |

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
| `max_steps` | `6` | `30` | Tool-use steps per turn or per batch. A playing model that used them all gets one more request that can only lock in its move; a request that failed for a reason that may pass (no connection, a timeout, the provider busy or rate limiting) is sent again, up to five times. Only then does the engine pick. |
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

1. Unless the caller named them, one request ranks your moves and guesses the opponent's move (two
   questions, one request). Your `candidates` best moves are compared, plus up to four of your defensive
   moves (block, low block, dodges, burst) that aren't among them.
2. The sweep: every candidate is played on the engine against **every** opponent reply, up to the next
   decision point. Replies are each legal move and its variants: every aim its pad allows (and half
   strength on pads with few aims), each direction, choice and switch, a slider's ends and middle. A
   move's guessed probability is shared by its variants. Likeliest replies go first, so if time runs out
   every candidate has met the same replies. This needs no model calls.
3. Deep lines (one per parallel request the core has) start from the candidates against the likeliest
   reply (each candidate once, best first), then against each one's worst reply, and play on for
   `depth` turns. Only turns where someone has a real choice count, and a line that reaches its depth in
   the middle of a combo gets up to four more turns to finish it. At every decision point inside a line
   the models pick both fighters' moves, drawn from their probabilities so lines differ.
4. Each move's score is its next-exchange average plus its follow-up: what its lines gained or lost
   after their first exchange. A reply without a line of its own borrows the follow-up of lines that
   started from the same kind of position (you act first, even, they act first), so every move is scored
   the same way. Lines cut short (out of time, no model answer) or still mid-combo are shown but not counted.
5. The engine picks: the best score among moves whose worst case is not a KO against you. When other
   moves score within 25 of it, a last request lets the models choose among those close calls, and
   only those.

**Combo turns** (one fighter can act and the other can only DI, burst or wait out a move) skip all of
that: the combo solver searches the attacker's routes on the engine, without model requests.

1. Every move the attacker has (each aim and variant, and reversed: every move the game lets you
   Reverse right now, turnarounds, reversed dashes and hits included) is played against no DI; the
   best six (plus any moves you named, and the next move of the route chosen last turn) start a route
   each.
2. A beam search grows the routes, three at a time, a step per round, until the combo ends (the
   defender can act again), a KO, or 24 steps. Each step plays one variant of every move (a move and
   the same move reversed count as two), then every variant of the best two and finer aims around the
   best aimed one (22.5 degrees either side, half and three-quarter strength).
3. The best three routes are played again, the same moves, against every DI: none, and each of the
   eight directions held for the whole combo. Where two neighbouring directions do differently (the
   combo ends at another step, a move stops connecting, or 10 damage apart), the direction halfway
   between is played, then halfway again on each side that still differs (22.5, then 11.25 degrees;
   up to 10 more per route), so a narrow window that drops the combo is found. They are named from the
   nearest main direction: `DI toward 23° up`, `DI up 11° away`. This step gets 80% of the thinking
   time. A route's **robust damage** is what it keeps whatever the defender DIs.
4. Attacking, the leading route also meets a defender who switches DI at every hit: at each step it
   takes, of the eight directions that held the route lowest, the one that leaves the attacker worst
   off over that hit and the next (DI steers the hit's knockback, so whether the combo holds shows at
   the next move). If that costs the route the lead, the new leader meets it too.
5. A burst (and any other escape) is played at the first step of every checked route and along the
   best one.
6. Attacking, the bot plays the first move of the most robust route. On the next turn it checks the
   position against what the route predicted (and against which DI), searches again from the real
   position, and keeps the planned move when nothing beats it. Being hit, it compares every DI it has,
   the finer directions included (each played against every checked route), and its escapes, and
   picks the one that holds the attacker's best routes lowest; a burst counts as costing 120 damage.
   It picks again at every hit, so it is itself a defender who switches DI.

`combo_goal` on `look_ahead` changes what the solver optimizes: `damage` (default; spending a burst to
extend a combo costs 120), `safe` (avoid ending where the opponent acts first), `corner` (carry them
toward the wall behind them), `save_resources` (meter costs 60 a bar, a burst 300).

Who uses it:

- **`decision` controller**: plays the engine's pick, or among close calls the move drawn from the
  models' ranking (`ai.decide.pick: sample`, so the bot is hard to read) or their top one (`best`). Combo
  turns are the solver's alone.
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
| `candidates` | `4` | Your moves compared (plus your defensive moves). Each is played against every opponent reply. |
| `max_options` | `48` | Options per question (the API allows 255). Each move's default input comes first, then other aims, directions or slider values. Lower it for models that reject long lists. |
| `think_s` | `30` | Thinking time per turn, counted from the first answer (waiting for a free request doesn't count). Everything ends 5 s before the turn timeout. |
| `request_timeout_s` | `20` | Per request. |
| `frame_budget_ms` | `12` | Engine time all preview work (the sweep, lines and combo solver, and making and freeing previews) may use per frame, on average. Higher thinks faster but makes the game less smooth; with characters from mods, whose previews are fresh copies, lower it if the game stutters while a bot thinks. |

`ai.decide.pick` (`sample` or `best`) only affects the decision controller.

Cost and speed: one request per turn of each deep line, plus two. Depth 10 with 4 parallel requests is
about 40 requests a turn. The sweep is engine work only: 8 moves against 60-70 replies is about 500
exchanges, roughly 15 ms of engine work each, so 8-12 s at the default frame budget. It gets up to two
thirds of `think_s` (the deep lines the rest). A preview is copied from the match once and then reset
between exchanges, restoring only what an exchange changed (checked against fresh copies, exchange for
exchange). A second `look_ahead` in the same turn reuses the exchanges already played.

A combo turn is engine work only, and engine-heavy: an exchange in a combo costs about 30 ms (hits and
knockback make ticks slower), so the solver plays about 15-20 exchanges a second at the default frame
budget. With the default `think_s` that is a few hundred exchanges: every first move, three to five
steps deeper on the best routes, and the DI check. Deep positions are copied once and every move is
played from the copy, instead of replaying the route for each. Lower `think_s` makes combo turns
shallower (the output says when routes were still going); a higher `frame_budget_ms` makes them faster.

Which models:

- **Jev with a TypeSafe key**: TypeSafe's default limit is 80 requests a second, so the full lookahead runs.
- **Jev through Vercel** (`typesafe-ai/jev`) needs paid AI Gateway credits.
- **Vercel's free tier** allows 5 requests a minute per model: set `max_rpm` to 5. Free-tier models that
  handled budok's requests well: `baseten/mammoth-1` and `perplexity/pplx-decider-v1.2` (27B),
  `liquid/d1-ultra`. A free model also works as an overflow entry behind Jev. Some models limit the number
  of options per question and reject longer lists with "check it against the model's supported inputs
  and limits" (`convaiinnovations/laya` takes 10 but not 40).

budok 1.3.0 kept one decision model under `ai.decide`; it moves to `ai.core` by itself.

## agents (Play tab, CLI agents)

budok can start a command-line agent itself, with your own login of that program (a Claude, ChatGPT or
Google subscription instead of an API key), to play a slot. It runs headless, without a window, gets the
prompt for its slot's mode and plays through budok's tools only. Its MCP address carries a ticket that
ties its session to that slot: it plays it without claiming it (a Tandem slot stays Tandem), and it may
not claim slots, change controllers, start matches or change settings. If it exits while its match goes
on, it is started again (three times at most). Its output is in `user://budok/agents/<slot>/agent.log`
(the previous run's in `agent.prev.log`).

| Key | Default | Meaning |
|---|---|---|
| `agents.for_mcp` | `true` | Start an agent for a slot set to Chatbot (MCP) that no chatbot of yours claims (it waits 3 s after the match starts). If one of your chatbots claims the slot later, the agent steps aside. Turn it off to keep Chatbot slots for your own apps. |
| `agents.for_bots` | `false` | The agent thinks for slots set to AI: chat model or AI: tandem, instead of the API chat model (Models tab). In Tandem it calls `look_ahead` every turn and decides; at the turn limit (`turns.timeout_s`) the engine plays its pick, as for any chat-model bot. |
| `agents.cli` | `claude` | `claude` (Claude Code, `claude -p`), `codex` (Codex CLI, `codex exec`), `gemini` (Gemini CLI) or `custom`. Claude Code is the tested one; Codex and Gemini follow their documented headless use (Codex gets budok's address as `-c mcp_servers.budok_agent.url=...` with a read-only sandbox, and MCP servers in your own `config.toml` that lead to budok, such as a `budok` entry for the stdio bridge, are switched off for that run only; Gemini a settings file with budok as a trusted server). |
| `agents.model` | `""` | Model for the agent (`--model` / `-m`); empty uses the program's default. |
| `agents.command` | `""` | The program or its full path; empty finds it in `PATH` and the usual install folders. |
| `agents.custom_command` | `""` | For `custom`: the command line, using `{mcp_url}` (budok's address with the ticket and token), `{mcp_config}` (a Claude-style MCP config file), `{model}`, `{prompt_file}` and `{dir}`. The prompt also comes in on stdin. |

None of these can be changed over MCP. The prompts per mode:

- **Chatbot** (`mcp`): play the slot with `wait_for_turn`, `simulate` / `look_ahead` as it sees fit, and `submit_action`.
- **AI chat model** (`ai`): decide alone, `simulate` up to three moves; `look_ahead` is not available.
- **Tandem**: call `look_ahead` first on every turn with a real choice, read the recommendation, close calls
  and worst cases, then decide and submit the move as listed. The agent is the final decision maker.

### The agent window (F9, or the corner "agent" button)

A window you can drag and resize, one view per slot: your messages, the agent's replies, its own words (from
its log) and every tool call it makes with how it went. Type a message to the agent (or chatbot) playing that
slot: it gets it with its next tool call as `operator_messages` (a `wait_for_turn` in progress returns early),
and answers with `operator_reply`. Start and Stop buttons start or stop that slot's agent; "Other calls" shows
calls from sessions that play no slot.

## misc (Play tab, Misc)

| Key | Default | Meaning |
|---|---|---|
| `misc.speech_bubbles` | `false` | Bots may say lines in a speech bubble above their character: chatbots with `say` (or `say` on `submit_action`), the chat model with `say` on its move. Decision models can't write. |
| `misc.trash_talk` | `false` | Bots that can write are asked to trash talk their opponent with every move (playful and about the match). Turns speech bubbles on too. |
| `misc.bubble_seconds` | `4` | How long a bubble stays up, plus a little per character. |

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
| `ui.show_button` / `toggle_key` / `agent_window_key` / `show_on_start` | `true` / `F8` / `F9` / `false` | Corner buttons (budok and agent), overlay key, agent window key, open on start. |
| `logging.match_logs` | `true` | Write `user://budok/matches/<time>_<p1>_vs_<p2>.json` after each match. |
| `memory.enabled` | `true` | Bots may save and recall memories (`user://budok/memory/<subject>.json`, one file per character, matchup or `general`). |
| `memory.shown_per_match` | `6` | Memories shown at match start (in `start_match`, the first turn and the token-mode prompt). |
| `memory.max_per_subject` | `100` | Oldest memories of a subject are dropped past this. |

On Windows the notes agent and the CLI agents that play start hidden (through `wscript`, so no terminal window opens). If it stops or never connects, the notes status (Play tab, and `get_status`) shows the end of its log, `user://budok/agent/agent.log`: on Windows that is `%APPDATA%\YourOnlyMoveIsHUSTLE\budok\agent\agent.log`. Claude Code on Windows needs Git for Windows; if its log says it cannot find git-bash, set `CLAUDE_CODE_GIT_BASH_PATH`.
