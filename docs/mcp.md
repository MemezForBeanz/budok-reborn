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
| `start_match` | `{p1, p2, controllers?, claim?, starting_hp?, settings?}`. Works from the menu or mid-match. By default you play P2 and the human plays P1. Says which characters have no move notes yet (`notes_missing`), with how to write them. |
| `set_controller` | Switch a slot between `human`, `mcp` and `ai` at any time. |
| `claim_slot` / `release_slot` | Take or return a slot for this session. Unclaimed `mcp` slots stay playable by the human. |
| `wait_for_turn` | Long-poll. Returns `your_turn` with `turn_token`, `situation` (plain text), `observation`, `legal_actions` (with payload specs, measured frames and notes), `extras` and `payload_help` (how to fill each payload type). Can also return `waiting` (call again) or `match_over`. `detail`: `compact` (move names with payload types and a slim observation, about a fifth of the size), `summary` (default: short notes and frame data) or `full` (all notes, raw resources and the opponent's legal options). A turn where `Continue` is the only move is always minimal (`only_option`). |
| `get_turn` | The open turn, without waiting. |
| `simulate` | `{action, data?, extra?, opponent_action?, opponent_data?, opponent_extra?, ticks?}` runs a deterministic preview on the real engine from the current turn. It returns damage dealt and taken, end states, events (damage, state changes, spawned projectiles), objects still on screen with their speed per tick, frame advantage, when each side can act next, and `in_hitlag` when a fighter starts frozen in hitlag. The opponent's real choice is never used or revealed. |
| `submit_action` | `{turn_token, action, data?, extra?}` validates (legal, usable, payload, extras) and locks in. With `wait_for_outcome` (default on) it waits, at most `mcp.max_wait_s`, for the turn to resolve and returns what happened, including the opponent's revealed move. If the outcome is still `pending` (a slow human opponent), call `wait_for_turn`. On an error nothing is applied and you can retry with the same token. Retrying a move that was already locked in (say, after a lost reply) returns `ok` with `already_applied` and the outcome; a different move returns `already_submitted`. |
| `get_match_log` | Resolved turn history, decisions and result. |
| `describe_character` | Measured data merged with notes for a character, a slot, or selected moves. |
| `introspect_character` | Raw skeleton for writing notes (paged), optionally with the source of code-driven moves. |
| `submit_character_schema` | Save notes (partial submissions merge). Returns actionable validation errors. |
| `generate_character_schema` | Let the in-game token-mode model write the notes in the background. |
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
| `object` | An object with the listed `fields`, each following its own spec. |
| `opaque` | A value shaped like `default`. |

Clients that send `data` as JSON text (`"{\"x\": 10, \"y\": 0}"`) are understood too.

`extra` accepts `di` (`{x, y}`, while being hit), `reverse`, `feint` and the character extras listed in
the turn's `extras.character`. Unavailable extras are rejected. `reverse` performs the move facing away
from the opponent, so a reversed lunge travels away from them.

## Resources and prompts

- `yomi://knowledge/{gameplay,engine,characters,action-ui,modding,annotating}`: the knowledge pack.
- `yomi://schema/format`: JSON Schema of the notes format.
- `yomi://characters/{name}/schema` and `.../skeleton`: per-character data.
- `yomi://match/log`: the current match.
- Prompts: `play_match {slot}`, `annotate_character {character}` and `modding_help {question}`.

## Turn rules worth knowing

- A decision point gives both players a turn. A player who is mid-move or being hit (`busy`) can only
  `Continue` (plus DI or burst when hit). History entries mark such players with `busy` and the state
  that kept running.
- When `Continue` (Hold) is the only option and you are not being hit, budok submits it for you
  (`turns.forced_turns`).
- Timeouts (`turns.timeout_s.mcp`, default off) play `turns.fallback_action`.
- If the human plays a bot's unclaimed slot from the UI, the turn closes as `resolved_elsewhere`.
