# budok MCP server

Transport: MCP Streamable HTTP at `http://127.0.0.1:<port>/mcp`. Every response is plain JSON (no SSE).
Long waits such as waiting for your turn are long-poll tool calls of up to about 25 s, so they stay under
client tool timeouts. Supported protocol versions: `2025-06-18`, `2025-03-26` and `2024-11-05`.

- **Auth**: `Authorization: Bearer <token>`, or `?token=<token>`. The token is generated on first run and
  shown in the panel. Regenerate it there.
- **Origin**: requests with a browser `Origin` header are accepted only from localhost or from
  `mcp.allowed_origins` (protects against DNS-rebinding pages).
- **Sessions**: `initialize` returns `Mcp-Session-Id`. `DELETE /mcp` ends the session and releases its
  slots. Clients that send no session header share one default session.
- `GET /health` answers without auth, for scripts that wait for the game to boot.

## Tools

| Tool | What it does |
|---|---|
| `get_status` | Versions, server, match (characters, controllers, open turns, last result), AI settings, schema jobs. |
| `list_characters` | Every playable character (vanilla, newer builds, mods), with schema status and notes coverage. |
| `start_match` | `{p1, p2, controllers?, claim?, starting_hp?, settings?}`. Works from the menu or mid-match. By default you play P2 and the human plays P1. Says which characters have no move notes yet (`notes_missing`), with how to write them, and gives a short `how_to_play` (the start of the playbook). |
| `set_controller` | Switch a slot between `human`, `mcp`, `ai` (chat model with an API key), `decision` (the decision core) and `tandem` (chat model leading the decision core) at any time. |
| `look_ahead` | `{slot?, moves?, opponent_moves?, defenses?, depth?, lines?, focus?, opponent_style?, detail?, combo_goal?, combo_search?}`. Plays each of your candidate moves, plus your defensive moves (`defenses`, default true), against **every** legal opponent reply and its aim, strength and direction variants on the real engine, up to the next decision point. Per move: `action` / `data` / `extra` to submit as they are, `average` (damage dealt minus taken, weighted by how likely each reply is), `worst` (the reply that hurts it most, with `reply_action` to name it back), `likely` and `dangerous` replies, and `engine_data` / `note` when its data was clamped. With budok's decision core set up (Models tab) it picks your candidates when you don't and plays every move deeper against the likeliest reply, then against its worst (`lines`, each step executable, `stopped` saying why a line is short); `followup` is what those lines showed after the next exchange, and `score` = `average` + `followup`. `recommended` is the engine's pick (the best score whose worst case is not a KO against you), `close_calls` the moves within 25 of it, `decision_model_pick` the models' choice among those. **Combo turns** (one fighter can only DI, burst or wait; `situation` is `attacking` or `defending`) go to the combo solver instead, no model needed: `combo.best_route` (or `their_best_route` when you are being hit) gives the route's first move and steps, `robust_damage` (kept whatever the defender DIs), `expected_damage`, `max_damage`, `by_di` (each DI's damage and how it ends: no DI, the eight directions, the finer directions found between two that did differently (`finer`, named like `DI toward 23° up`) and, attacking, a defender switching to the worst DI at every hit (`di_each_step`)), `weakest_di`, `escape`, bursts and the end position; routes include reversed moves (`extra.reverse`) wherever the game allows a Reverse; being hit, your moves include those finer directions; `combo.remembered_route` says how last turn's route went. `combo_goal`: `damage` (default), `safe`, `corner` or `save_resources`; `combo_search: false` treats a combo turn like any other. `start` is the position the runs began from and whether the engine's copy matched the live match; `coverage` says how many exchanges were played; `notes` explain anything cut short. Moves are names, option names from an earlier answer (`"Jump up-fwd"`) or `{action, data?, extra?}`. `detail: "full"` lists every reply and step. Seconds to tens of seconds (capped by `ai.core.think_s`); a second call in the same turn reuses the exchanges already played. |
| `claim_slot` / `release_slot` | Take or return a slot for this session. Unclaimed `mcp` slots stay playable by the human. |
| `wait_for_turn` | Long-poll. Returns `your_turn` with `turn_token`, `situation` (plain text), `observation`, `legal_actions` (with payload specs, measured frames and notes), `extras` and `payload_help` (how to fill each payload type). Can also return `waiting` (call again) or `match_over`. `detail`: `compact` (move names with payload types and a slim observation, about a fifth of the size), `summary` (default: short notes and frame data) or `full` (all notes, raw resources and the opponent's legal options). A turn where `Continue` is the only move is always minimal (`only_option`). The slot's first turn also carries `how_to_play`; with speech bubbles or trash talk on (Play tab, Misc), `talk` says what to do (trash talk asks for a taunt every turn). |
| `get_turn` | The open turn, without waiting. |
| `simulate` | `{action, data?, extra?, then?, opponent_action?, opponent_data?, opponent_extra?, ticks?}` runs a deterministic preview on the real engine from the current turn. It returns damage dealt and taken, end states, events (damage, state changes, spawned projectiles), objects still on screen with their speed per tick, frame advantage, when each side can act next, `in_hitlag` when a fighter starts frozen in hitlag, `you_act_again_at` when you get another decision inside the preview (a two-step move's follow-up, or a free turn while the opponent is busy), and `your_hitboxes` (active ticks and the closest gap to the opponent's body) so a miss can be explained. `then: [{action, data?, extra?}]` plays your follow-ups at those decisions. `opponent_action` works whenever the opponent has a turn at this decision point, even after they locked in. The opponent's real choice is never used or revealed. |
| `submit_action` | `{turn_token, action, data?, extra?, say?}` validates (legal, usable, payload, extras) and locks in. With `wait_for_outcome` (default on) it waits, at most `mcp.max_wait_s`, for the turn to resolve and returns what happened, including the opponent's revealed move. If the outcome is still `pending` (a slow human opponent), call `wait_for_turn`. On an error nothing is applied and you can retry with the same token. Retrying a move that was already locked in (say, after a lost reply) returns `ok` with `already_applied` and the outcome; a different move returns `already_submitted`. `say` shows a line in a speech bubble above your character when speech is on (otherwise `say_note` says why not). |
| `say` | `{text, slot?}`: a line (under 80 characters, one line) in a speech bubble above your character, when the player turned speech bubbles or trash talk on. |
| `operator_reply` | `{text}`: answer a message the player sent you from budok's agent window. Messages arrive in any tool result as `operator_messages` (a `wait_for_turn` in progress returns early with status `operator_message`); the window shows your answer. |
| `get_match_log` | Resolved turn history, decisions and result. History entries mark players who were mid-move (`busy`, with the `state` that kept running) and turns budok played for a slot because Continue was the only option (`auto`). |
| `remember` | `{text, character?, opponent?, tags?}` saves a lesson for future matches: about one character, a matchup (`character` playing against `opponent`) or general. `p1`/`p2` name the characters in the current match. Memories stay in this game install, are shared by every bot that plays here and record who wrote them. |
| `recall` | `{character?, opponent?, query?, limit?, only_mine?}` lists memories, newest first; defaults to the characters in the current match. |
| `forget` | `{id}` deletes one memory. |
| `describe_character` | Measured data merged with notes for a character, a slot, or selected moves. |
| `introspect_character` | Raw skeleton for writing notes (paged), optionally with the source of code-driven moves. |
| `submit_character_schema` | Save notes (partial submissions merge). Returns actionable validation errors. |
| `generate_character_schema` | Let the in-game token-mode model write the notes in the background. |
| `get_schema_task` / `finish_schema_task` | Automatic notes (`schemas.auto`): the character to write notes for next, with instructions and progress; finish early or hand it back (`skipped: true`). Tasks go to notes agents, which ask with `worker: true` (and can wait for the next character with `wait_s`), not to the chatbot that plays, unless `schemas.auto.use_player` is on and no notes agent is available. Tasks finish by themselves once every move and the summary have notes. While a match's characters get their notes, its bots' `wait_for_turn` returns `status: waiting, reason: notes`. |
| `export_character_schema` / `fetch_registry_schema` | Share notes, or fetch them from the opt-in registry. |
| `read_source` / `search_source` / `list_source_files` | Read-only access to `res://` game and mod files. `user://` (where keys live) is never readable. |
| `get_settings` / `update_setting` | Redacted settings. Changes are limited to controllers, turns, simulation and AI role settings, never keys or URLs. |

### Data and extras

`data` follows the action's `payload` spec. Omit it to use the game's default.

| Payload type | Value to send |
|---|---|
| `xy` | `{"x": -100..100, "y": -100..100}` in screen space, like the aim arrow on screen (+x right, +y down). It does not flip with facing or reverse. Clamped like the UI clamps (some aims are limited to the forward side). `[x, y]` also works. |
| `direction8` | A direction name: `"N"`, `"NE"` ... `"Neutral"` (screen directions). `"up-left"`-style names and `{"direction": "NW"}` also work. The allowed list mirrors with reverse. |
| `int` | A number. budok wraps it the way the game expects. |
| `bool` | `true` or `false`. |
| `option` | The option's name. |
| `choice` | One of `choices` by name, for controls made of buttons, such as a parry's Block Height (`"High"` or `"Low"`). |
| `fixed` | Nothing to choose this turn (for example Super Jump outside a combo, which always homes in); omit `data`. |
| `object` | An object with the listed `fields`, each following its own spec. |
| `opaque` | A value shaped like `default`. `script` names the control's script, which `read_source` can show. |

When the game's control changes a value (an aim outside the move's allowed cone, a number out of range), the
result of `submit_action` or `simulate` says so in `notes`.

Clients that send `data` as JSON text (`"{\"x\": 10, \"y\": 0}"`) are understood too.

`extra` accepts `di` (`{x, y}`, while being hit), `reverse`, `feint` and the character extras listed in
the turn's `extras.character`. Unavailable extras are rejected. `reverse` performs the move facing away
from the opponent, so a reversed lunge travels away from them.

## Resources and prompts

- `yomi://knowledge/{gameplay,engine,characters,action-ui,modding,annotating}`: the knowledge pack.
- `yomi://schema/format`: JSON Schema of the notes format.
- `yomi://characters/{name}/schema` and `.../skeleton`: per-character data.
- `yomi://match/log`: the current match.
- Prompts: `play_match {slot}`, `annotate_character {character}`, `notes_worker` (run it in a second chat to make that chat a notes agent; it waits for characters without notes and writes them) and `modding_help {question}`.

## Turn rules worth knowing

- A decision point gives both players a turn. A player who is mid-move or being hit (`busy`) can only
  `Continue` (plus DI or burst when hit). History entries mark such players with `busy` and the state
  that kept running.
- When `Continue` (Hold) is the only option and you are not being hit, budok submits it for you
  (`turns.forced_turns`). Your next turn then says how many turns were played this way and in which of
  your states (`auto_continued`), for example while frozen by a time stop.
- `start_match` and the first turn of a match include `memories`: lessons bots saved about these
  characters before.
- With automatic notes on (the default), a match whose characters have no notes holds the bots' first
  move: `wait_for_turn` returns `status: "schema_task"` when the job is yours (write the notes, then call it
  again), or `status: "waiting", reason: "notes"` while the in-game AI writes them.
- Timeouts (`turns.timeout_s.mcp`, default off) play `turns.fallback_action`.
- Agents budok starts itself (Play tab, CLI agents) connect with a ticket in the address (`?agent=...`): their session plays its slot as set, without claiming it, and `claim_slot`, `release_slot`, `set_controller`, `start_match` and `update_setting` are refused for it (in AI chat model mode `look_ahead` too). A chatbot of yours that claims a slot an agent plays takes it over, and the agent stops. In-game chat-model bots (`ai`, `tandem`) that run out of time play the decision core's engine pick instead (`engine_pick` in the match log).
- If the human plays a bot's unclaimed slot from the UI, the turn closes as `resolved_elsewhere`.
