# budok-reborn: Refactor Plan

Status: **implemented** (first full pass, see README and docs/). Not yet verified inside a live game.

Decisions taken after the proposal:
1. The MCP server lives in the mod, and so does token mode (LLM calls over HTTPS from GDScript).
2. The headless VM / tournament / video pipeline was removed. Automation is now an in-game GDScript hook
   plus an external MCP connector (`connectors/python`).
3. Tested against a bundled test character (`mod/budok_test_char`); the maintainer tests real mods locally.
4. The community registry is opt-in. Schemas shipped inside a character's mod are used without generation.
5. Added during implementation: per-role AI settings (move making vs schema creation) and an engine-backed
   `simulate` tool.

## 1. Goal

Turn budok-ai into a **native YOMI Hustle mod** that runs inside a player's normal Steam install. Chatbot apps connect to it over **MCP**, and the original **API-key ("token") mode** keeps working. Every character must work: vanilla, characters added in newer builds, and modded characters loaded through char_loader. Each modded character gets a schema built mostly by automatic introspection, and an LLM adds the move semantics that code can't infer. The connected bot also needs enough knowledge of YOMI code and modding conventions to do that annotation well.

## 2. Where the code is today (and what blocks the goal)

| Area | Current state | Problem for the new goal |
|---|---|---|
| Transport | Mod is a WebSocket **client** of a Python daemon (`BridgeClient.gd` → `server.py`), custom v2 envelope protocol (`schemas/*.v2.json`, `protocol.py` 1k lines) | Chatbots can't speak it. Needs a daemon process plus a config file for every match. |
| Runtime | Headless game in an OrbStack VM on Xvfb; `scripts/run_*.sh`, `replay_capture.py` drive it all | It isn't "native". Too much setup just to play against a bot. |
| Version gate | `RuntimeCompatibility.gd` hard-pins `Global.VERSION == "1.9.20-steam"` and engine `3.5.1` | Refuses every newer build, so it can't support new characters. |
| Character identity | `ObservationBuilder.SCENE_PATH_TO_CHARACTER` (5 entries), `prompt.VALID_CHARACTERS`, `AutoMatchStarter.BUILTIN_CHARACTERS` | Any other character shows up as `"P1"`/`"P2"` and can't be selected by LLM choice. |
| Character state | `_build_character_data()` hand-codes each vanilla character's fields | Modded and new characters get no resource state at all. |
| Objects | `OBJECT_CATEGORY_MAP` matches on node name | Every modded projectile comes back as `unknown`. |
| Move knowledge | `prompts/move_catalog.json` (hand-written, 6 keys) plus `_character_guide`/`_tactical_cheat_sheet` hardcoded in `prompt.py` | No mechanism for characters outside the list. |
| Legal actions | `LegalActionBuilder.gd` reads the `P1ActionButtons`/`P2ActionButtons` UI and known data-UI control types | Good seam to keep. Custom data-UI controls in mods aren't handled. |

What stays: the **game-side seams** are proven and reusable. That covers `player_actionable`, `on_action_selected(action, data, extra)`, action-button enumeration, `game_ended`/`game_won`, the replay save, `AutoMatchStarter`'s `match_ready` path, and the stale-turn and legality validation in `DecisionValidator.gd`. The refactor rebuilds the layers *around* those seams. The seams themselves stay.

## 3. Target architecture

```
YOMI Hustle (player's own install, windowed, normal Steam launch)
└─ budok mod (GDScript)
   ├─ core/                      transport-agnostic game adapter
   │   ├─ GameAdapter            observe / enumerate / validate / apply  (today's builders, refactored)
   │   ├─ CharacterIntrospector  walks fighter + states + hitboxes → character skeleton
   │   ├─ SchemaStore            user://budok/schemas/<char>@<fingerprint>.json
   │   └─ TurnController         per-slot controller: human | mcp | fallback
   ├─ mcp/                       MCP server, Streamable HTTP, 127.0.0.1 only
   │   ├─ HttpServer             TCP_Server + minimal HTTP/1.1 (JSON responses, no SSE required)
   │   ├─ JsonRpc                MCP lifecycle: initialize, tools/*, resources/*, prompts/*
   │   └─ tools/ resources/ prompts/
   ├─ knowledge/                 YOMI engine + modding docs served as MCP resources
   └─ ui/                        in-game panel: slot assignment, URL, pairing token, status

budok (Python, optional, `uv tool install budok`)
   ├─ budok stdio                stdio ⇄ HTTP proxy for clients that only launch stdio servers
   ├─ budok play                 TOKEN MODE: provider adapters drive a slot *as an MCP client*
   ├─ budok annotate             TOKEN MODE: runs the modded-character schema pipeline unattended
   └─ budok tournament/analysis  kept, rebuilt on `budok play`
```

### Key decision: the MCP server lives inside the mod

Recommended. The alternative is a Python sidecar.

- "Native" then means it really is native: install the mod, launch the game, paste a URL into the chatbot. No daemon runs.
- Godot 3.5 has `TCP_Server`/`StreamPeerTCP`. MCP Streamable HTTP lets a server answer every POST with a plain `application/json` body and return `405` on GET, so we don't need SSE or a full HTTP stack. The server polls in `_process()` on the main thread, which also removes any threading hazard around game state.
- **Token mode becomes an MCP client of the same server.** One interface serves both modes, the custom WebSocket protocol goes away, and every token-mode run exercises the same code path chatbots use.
- Cost: an HTTP/JSON-RPC layer written in GDScript (roughly 600–900 lines with tests). It's acceptable because the surface is small.

### Connecting chatbot apps

| Client | How |
|---|---|
| Claude Code, Cursor, and other clients that speak Streamable HTTP | Point at `http://127.0.0.1:<port>/mcp` and send the bearer token |
| Claude Desktop and other stdio-only configs | `budok stdio --url … --token …` (or `npx mcp-remote`) |
| Web chatbots (claude.ai connectors, ChatGPT) | These need a public HTTPS URL. Documented opt-in tunnel (e.g. `cloudflared`), and the token is required. The default stays localhost-only. |

Security requirements (these aren't optional): bind `127.0.0.1` by default. Require a random pairing token, generated on first run, shown in the in-game panel, and regenerable. Validate the `Origin` header, since the MCP spec calls this out for DNS-rebinding. Rate-limit bad-token attempts. Never expose file-write tools.

## 4. MCP surface

Keep the tool count small and make results compact. Chatbot context is the scarcest resource: a 150-turn match with today's full observation JSON would overflow most context windows.

### Tools

| Tool | Purpose |
|---|---|
| `get_status` | Game and mod version, menu or in-match, which slots are controlled by whom, schema coverage |
| `list_characters` | Every entry in `Global.name_paths`, with source (vanilla/mod id) and schema status (`curated`/`generated`/`skeleton_only`/`missing`) |
| `start_match` | `{p1, p2, controllers:{p1:"human"\|"mcp", p2:…}, stage?, starting_hp?}`. Reuses `AutoMatchStarter` |
| `claim_slot` / `release_slot` | A session claims `p1`/`p2`. This is what enables bot-vs-bot with two MCP sessions, and token mode vs a chatbot |
| `wait_for_turn` | Long-poll, bounded (≤ ~25 s so it stays under client tool timeouts). Returns `{status:"your_turn", turn_token, situation, legal_actions}` or `{status:"waiting"\|"match_over"}` |
| `get_observation` | `detail: "summary"\|"full"`, for when the bot wants more than the summary in `wait_for_turn` |
| `describe_move` | Annotated schema entry for one move, so the per-turn payload doesn't have to carry it |
| `submit_action` | `{turn_token, action, data?, extra?}` → validated by `DecisionValidator`. Returns a structured error the bot can fix, or `{applied:true, outcome}` after the turn resolves when `wait_outcome:true` |
| `introspect_character` | Automated skeleton for a character (see §5) |
| `read_source` / `search_source` | Read-only access to `res://` scripts (mod and vanilla, where readable) for annotation and modding questions |
| `submit_character_schema` | Validate and store LLM annotations (see §5) |

Turn tokens replace bot-visible `match_id`/`turn_id`. They are opaque, single-use, and rejected once stale. That keeps the existing stale-turn guarantee.

### Resources and prompts

- Resources: `yomi://knowledge/{topic}`, `yomi://characters/{id}/schema`, `yomi://match/history`.
- Prompts: `play_match` (strategy primer generated from the selected characters' schemas, replacing hardcoded `prompt.py` guides) and `annotate_character` (the §5 workflow).

### Pacing and fallback in MCP mode

A chatbot is slow and human-paced. The game already waits for both players, so in MCP mode the decision timeout defaults to **off**. When it's set, `FallbackHandler.gd` applies the configured safe action. Edge cases to handle explicitly:

- The client disconnects in the middle of a match. The slot is held for N seconds, then reverts to fallback or pauses (configurable).
- Two sessions try to claim the same slot. The second claim is rejected.
- `submit_action` arrives for a turn that has already been resolved by fallback. Return `stale_turn`, not an error the bot will retry forever.
- Match ends during `wait_for_turn`. Return `match_over` with the result.
- Online or lobby matches: MCP control is **refused** outside local/singleplayer games. A bot playing for you online is cheating, and the replay sync would break anyway.

## 5. Character support and schema generation

### 5.1 Generic observation (all characters)

- Character identity comes from `Global.name_paths` (reverse lookup of `fighter.filename`), and mod id comes from char_loader metadata. `SCENE_PATH_TO_CHARACTER` and the other hardcoded lists go away.
- `character_data` comes from a **property diff**: the fighter's script property list minus `BaseChar.gd`'s, filtered to serializable primitives (int/float/bool/String/small Vector2/Fixed strings) and capped in size. The schema (§5.3) can rename fields, give them meaning, or hide noisy ones. The hand-written vanilla blocks become curated schema entries rather than code.
- Objects: classify by script inheritance chain (projectile base vs other `BaseObj`), not by node name. Owner, position, and remaining lifetime come from base fields, and the schema can add meaning.

### 5.2 Automated skeleton (`CharacterIntrospector`)

The introspector runs on the **live fighter** at match start (safe), and optionally on an off-tree scene instance from the menu (guarded, since a character's `_ready()` may assume a running game). For every state under `state_machine` it extracts:

- name, `title`, script path, action type (movement/attack/special/super/defense), air/ground availability, `super_level`/meter cost, interrupt categories, `reversible`, `can_feint`
- payload spec from `data_ui_scene`, reusing the `LegalActionBuilder` expansion logic
- **frame data from `Hitbox` children**: damage, hitstun, start tick, active ticks, knockback, throw/guard-break flags, and `iasa_at`/anim length → startup/active/recovery. This is the bulk of what `move_catalog.json` carries by hand today.
- `dynamic: true` when hitboxes or projectiles are created in code (`_frame_N`, `spawn_object`), so the LLM knows to read the source

Every state also gets a **fingerprint**: the hash of the scene path, the script sources, and the mod `_metadata` version. When a mod updates, the hash changes and the schema is flagged stale, but it isn't silently reused.

### 5.3 Character schema format (`schemas/character.v1.json`)

```jsonc
{
  "character": "Kirby", "source": {"mod_id": "...", "version": "..."}, "fingerprint": "sha256:…",
  "provenance": {"skeleton": "auto", "annotations": "llm", "model": "...", "created_at": "..."},
  "archetype": "…", "game_plan": "…",               // LLM
  "resources": {"field_name": {"label": "…", "meaning": "…", "hidden": false}},  // auto + LLM
  "moves": {
    "Inhale": {
      "auto":  {"type": "special", "startup": 6, "active": 4, "damage": 0, "meter_cost": 0, "air": true, "payload": {...}},
      "notes": {"category": "grab", "description": "…", "beats": "…", "loses_to": "…", "use_when": "…"}  // LLM
    }
  }
}
```

The validator rejects these: moves that aren't in the skeleton (no hallucinated moves), `auto` fields that differ from the introspected values (the LLM annotates and never overrides measured data), invalid enums, and missing coverage. Partial submissions are accepted and merged, so a big roster can be annotated in batches that fit a context window.

The vanilla characters get **curated** schemas migrated from `move_catalog.json` and the `prompt.py` guides. These also serve as golden fixtures for the introspector, because the auto fields must agree with the hand data.

### 5.4 Annotation workflow

The same steps run in both modes:

1. `introspect_character` returns the skeleton plus, for `dynamic` or unclear moves, the relevant script excerpts.
2. The model reads `yomi://knowledge/*` (§6) and calls `read_source` as needed.
3. The model calls `submit_character_schema` in batches. The validation errors it gets back are written so the model can act on them.
4. The result is stored in `user://budok/schemas/`, and `export`/`import` lets players share schemas. A community registry keyed by fingerprint can come later.

- **MCP mode:** the `annotate_character` prompt guides the connected chatbot through the steps. `start_match` with a `missing` character offers to run it first, and the match still plays on `skeleton_only` if the user declines.
- **Token mode:** `budok annotate --character X` (or automatically before `budok play`) runs the same loop with a configured provider.

## 6. Knowledge pack: YOMI code and mod conventions

`mod/budok/knowledge/*.md` holds docs in our own words, served as MCP resources. It includes **no redistributed decompiled game source**. The bot reads the user's local install at runtime through `read_source`/`search_source`.

Topics:
- engine basics: Godot 3.5 GDScript, the deterministic tick loop, and FixedMath string arithmetic, which explains why payloads sometimes arrive as strings
- character anatomy: `BaseChar.gd`, the state machine, `CharacterState` lifecycle (`_enter`, `_frame_N`, `_tick`, `_exit`), interrupt types, hitbox fields, and projectiles/`BaseObj`
- action UI: `ActionUIData` and the vanilla controls (`XYPlot`, `8Way`, `Slider`, `CountOption`, `OptionButton`, `CheckButton`), plus how mods add their own
- char_loader conventions: mod folder layout, `_metadata`, `ModMain.gd`, `installScriptExtension`, character registration into `Global.name_paths`, and custom character select
- "how to read a modded character" checklist, which feeds the `annotate_character` prompt

Must verify in Phase 0: whether vanilla `.gd` files can be read as text in the shipped `.pck` or are compiled `.gdc`. Mod scripts are usually plain text. If vanilla is compiled, `search_source` covers mod scripts only, and the knowledge pack carries the vanilla API surface.

## 7. Python side (`daemon/` → `budok/`)

| Keep or rework | Drop |
|---|---|
| `adapters/` (anthropic, openai, openrouter, baselines) behind the token-mode MCP client | `server.py`, `protocol.py`, `schemas/*.v1/v2` envelope schemas, `BridgeClient.gd`, `ProtocolCodec.gd` |
| `response_parser.py`, `fallback.py` (reused for token mode) | OrbStack/VM scripts (`run_*.sh`, `install_mod.sh` VM paths), and `replay_capture.py` moved to an optional `budok record` extra |
| `prompt.py`, rewritten to render from character schemas instead of hardcoded guides | v1 schemas and compat paths |
| `storage/`, `tournament/`, `analysis/`, `tui.py`, re-pointed at MCP-mode match logs | |

Token mode loop: `budok play --slot p2 --policy anthropic/…` connects, calls `claim_slot`, loops `wait_for_turn` → adapter → `submit_action`, and writes the same `runs/` artifacts as today. Unattended tournaments still need a game instance per match. The headless VM flow can keep working as an "advanced" path on top of the same mod, but it stops being the default.

## 8. Phased delivery

Each phase ends in a playable or testable state.

**Phase 0: Ground truth.** Decompile the current Steam build. Confirm the seams in `docs/game_internals.md` still hold, list the characters added since `1.9.20`, check whether vanilla scripts can be read, and survey 3–5 popular char_loader characters for custom data-UI controls and dynamic hitboxes. Output: updated `game_internals.md` plus a fixtures set.

**Phase 1: Mod core split.** Extract `core/GameAdapter` from `TurnHook`, `ObservationBuilder`, `LegalActionBuilder`, `ActionApplier`, and `DecisionValidator`, with no transport inside. Add a `TurnController` with per-slot controllers (human/fallback first). Replace the version pin with **capability probing**: check signals, methods, and nodes, keep a "tested builds" list, and warn on an unknown build rather than refusing. Rename the mod to `budok` and update `_metadata`.

**Phase 2: Native MCP server.** `HttpServer` + `JsonRpc` + the gameplay tools (`get_status`, `list_characters`, `start_match`, `claim_slot`, `wait_for_turn`, `get_observation`, `submit_action`). Add pairing token, Origin check, and the in-game panel. Exit criterion: a human plays P1 and Claude plays P2 from a chatbot app, on vanilla characters.

**Phase 3: Generic characters.** Generic identity, property-diff `character_data`, inheritance-based object classification, and the `CharacterIntrospector` with frame data. Golden test: introspected vanilla frame data matches the curated catalog.

**Phase 4: Schemas.** `character.v1.json`, validator, `SchemaStore` with fingerprints, migration of vanilla curated schemas, `introspect_character`/`submit_character_schema`/`describe_move`, and the `annotate_character` prompt. Exit criterion: a chatbot annotates a real modded character end to end and then plays it.

**Phase 5: Knowledge pack.** `knowledge/*.md`, `read_source`/`search_source` (read-only, `res://` sandboxed, size-capped), plus resources and prompts.

**Phase 6: Python `budok`.** MCP-client token mode, `stdio` proxy, `annotate`, prompt rendering from schemas, then tournament and analysis rebuilt on it. Delete the WebSocket protocol.

**Phase 7: Docs and packaging.** One-page install for each client (Claude Desktop, Claude Code, ChatGPT via tunnel), a mod zip release, and a rewritten README.

## 9. Testing strategy

- **GDScript:** keep the existing smoke-scene approach (`mod/Bridge*Smoke.gd`) and the Python harnesses in `scripts/mod_*_harness.py`, pointed at `core/` with fake fighters and states. Add fake modded characters with custom fields, dynamic hitboxes, and an unknown data-UI control.
- **MCP conformance:** a Python test suite drives the server with the official MCP client SDK against a headless game (CI-optional) and a fake-game mode of the mod (CI-required). Covers lifecycle, auth and Origin rejection, slot contention, stale tokens, long-poll timeouts, and match-over during a wait.
- **Schema:** validator unit tests that check hallucinated moves are rejected, auto fields can't be overridden, partial merges work, and a fingerprint change marks the schema stale. Vanilla golden fixtures cover the introspector.
- **Token mode:** the existing orchestrator, adapter, and fallback tests, re-targeted at the MCP client.

## 10. Risks

| Risk | Mitigation |
|---|---|
| A GDScript HTTP server misbehaves with some clients (keep-alive, chunked bodies) | Implement only `Content-Length` bodies, close-after-response allowed, and a conformance suite against real clients; the `budok stdio` proxy is a fallback path |
| Off-tree instancing of modded characters crashes or has side effects | Default to live-fighter introspection; menu-time instancing is opt-in and guarded |
| Custom data-UI controls can't be enumerated | Generic fallback: read the control's `get_data()` default and report `{"type":"opaque","default":…}`, and let the schema supply hints |
| LLM annotations are wrong | Measured `auto` fields are authoritative and never LLM-written; provenance is recorded; users can re-annotate and edit |
| Chatbot context overflow over long matches | Compact `situation` summaries, `describe_move` on demand, and a rolling recap in `wait_for_turn` instead of the full history |
| Game updates break seams | Capability probing, the tested-builds list, and the Phase 0 checklist rerun per update |
| Legal and distribution issues with decompiled code | The knowledge pack is original prose; source is read only from the user's own install |

## 11. Open decisions

1. **MCP server in-mod (recommended) or Python sidecar?** This drives Phases 2 and 6.
2. **Keep the headless VM / LLM-vs-LLM tournament pipeline** as an advanced path, or drop it entirely?
3. **First mod characters to target** for Phase 4 validation. Pick ones people actually play.
4. **Schema sharing:** local export/import only, or plan a community registry now?
