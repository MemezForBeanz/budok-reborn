# Architecture

Everything runs inside the game process. The mod is loaded by the game's mod loader (`ModMain.gd`, a
child of the `ModLoader` autoload, so it survives scene changes) and creates `core/Runtime.gd`, which
wires the services below. Game objects are only ever touched by duck typing and runtime autoload lookups.
A renamed class or singleton in a future build therefore breaks one feature, not the whole mod.

```
YOMI Hustle process
└─ budok (ModMain → Runtime)
   ├─ core/MatchController  watches Global.current_game; opens a turn per player the game waits on
   │    ├─ ActionCatalog     legal moves + payload/extras from the player's native ActionButtons panel;
   │    │                    applies via ActionButtons.on_action_submitted (the Lock In path)
   │    ├─ Observation       per-player snapshot + plain-language situation
   │    ├─ Simulator         what-if previews: fresh Game (ghost) + copy_to + tick, in a hidden viewport;
   │    │                    a pool of previews reset between runs at one decision point
   │    ├─ Lookahead         the sweep (every pair of moves for the next exchange) and lines played
   │    │                    several turns ahead in previews (SimTurns: the panel's legality rules,
   │    │                    the game's turn logic and each move's input variants, ported for previews)
   │    └─ ComboSolver       combo turns: beam search over the attacker's routes, checked against
   │                         every DI; deep positions are forked (Simulator.fork) instead of replayed
   ├─ core/Roster           Global.name_paths + character loader registry (lazy loading of mods)
   ├─ core/Introspector     measured skeleton from the character scene (states, hitboxes, resources)
   ├─ core/SchemaStore      notes lookup (override → mod-shipped → bundled → generated → registry),
   │                        validation and merging
   ├─ core/SourceBrowser    read-only res:// access
   ├─ core/Memory           lessons bots saved between matches (user://budok/memory)
   ├─ core/SchemaJobs       automatic notes: queue of characters without notes, handed to the
   │    │                   in-game AI and to notes agents; holds a match's first turn for them
   │    └─ NotesAgent        starts Claude Code headless (claude -p) as the notes agent
   ├─ mcp/HttpServer        TCP_Server-based HTTP/1.1, polled on the main thread, deferred responses
   ├─ mcp/McpServer         JSON-RPC, sessions, auth, origin checks; mcp/Tools + mcp/Resources
   ├─ ai/LlmClient          Anthropic Messages API / OpenAI-compatible chat, and decision models
   │                        (Vercel AI Gateway /decision-model, TypeSafe /v1/systemone) via HTTPRequest
   ├─ ai/AutoPilot          token mode player (controllers "ai" and "tandem"; tandem adds look_ahead)
   ├─ ai/DecisionCore       decision models behind one dispatcher (ai.core.endpoints: keys, parallel
   │                        requests, rate limits, failover) and the lookahead analysis (the engine
   │                        picks; models choose among close calls; combo turns go to ComboSolver,
   │                        whose route is remembered and checked next turn); look_ahead
   ├─ ai/DecisionPilot      decision-model player (controller "decision"): analyze, then pick
   ├─ ai/Annotator          token mode schema writer
   ├─ ui/SettingsView       all settings as four tabs (Play, Models, Chatbots, Characters)
   ├─ ui/SpeechBubbles      lines bots say, in a bubble above their fighter (Play tab, Misc)
   ├─ ui/ModMenuHook        adds those tabs to the game's Mod List → budok entry
   ├─ ui/Panel              same tabs on the F8 overlay
   └─ automation/Automation optional user GDScript
```

## Turn lifecycle

1. The game pauses and activates both move panels. When a panel is active and its fighter is
   `state_interruptable`, budok waits about 3 frames for the panel to settle. It then snapshots the legal
   catalog and opens a turn with a random token.
2. The slot's controller decides:
   - `human` does nothing.
   - `mcp` answers `wait_for_turn` / `submit_action`.
   - `ai` triggers the autopilot.
   - `decision` triggers the decision player; `tandem` triggers the autopilot with the decision core.
3. `submit` re-validates against the snapshot: the action must be legal and `is_usable()` (an unusable
   action would turn into a forfeit), and the payload and extras must be valid. It then calls
   `on_action_submitted` with exactly the values the UI would produce.
4. When the panel deactivates, the turn closes. The next decision point records the history entry from
   `ReplayManager.frames`, so the opponent's move is revealed only after it resolved. Undo truncates history.

## Previews

A preview is a fresh `Game` (a ghost) the live match is copied into with the game's own `copy_to`,
ticked by hand and never drawn. Copying all of a fighter's ~120 states is the slow part, so a preview is
copied once per decision point and then reset: the variables it had after the copy are put back, and only
the states a run entered are copied again. The combo solver also copies a preview mid-route
(`Simulator.fork`) to play many moves from one position. Two things budok adds to the game's copy:

- **Object names.** Objects are found by name (`objs_map`: `"P1"`, `"P2"`, then `"3"`, `"4"`, ... by
  spawn count), and `copy_to` names the objects it makes by the copy's own count. Once the live match
  has freed an object the names disagree, and a fighter that tracks its projectile by name (Ninja's
  grappling hook) finds another object. Each copy's map is rebuilt with the source's names and size (new
  objects' RNG seeds come from its size).
- **Fighter variables.** Entering the current state again during the copy can spend an air option or
  meter twice, so each fighter's `state_variables` are put back from the source afterwards.

While a preview ticks, `ReplayManager.resimulating` is set, as in the game's own resimulation: particles,
afterimages and sounds are skipped, and nothing that plays out changes. Previews were checked against
fresh copies (sweep exchanges, solver routes from forks, finer-DI and switching-DI branches: identical)
and against the live match (one exchange in 120 differed, with three projectiles and a summon in
flight; with reversed moves in two of three exchanges, hp, state, position and facing matched in 119
of 120, one a fighter 2 pixels off).

A move played reversed sets the game's `reverse` extra: entering a reversible state that is not a hurt
state, the fighter turns to face away (`CharState`), and the aim pads turn with it. The game itself
flips any reversible state; the panel's Reverse button also needs the state's `flip_allowed()`, so
budok offers (and the solver replays) a reversed move only where both hold.

## Fairness and safety

- No control in online or lobby matches. Replays are never controlled.
- Simulations queue an *assumed* opponent action. They never read the opponent's real queued input, and
  the opponent side is resolved without touching the human's UI. The decision player's lookahead lines
  predict the opponent's moves with its model; the move specs it uses are read once, at the start of the
  match, before anyone could touch the panels.
- Locking in through `on_action_submitted` doesn't drive the ghost preview, so a human can't see the
  bot's pick.
- The MCP server binds localhost and requires a token. `user://` (keys) is unreadable through tools, and
  settings changes over MCP can't touch keys or URLs.
