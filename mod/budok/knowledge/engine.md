# YOMI Hustle engine primer (for reading game and mod code)

## Platform

- Godot **3.5** (GDScript 1.0 syntax: `yield`, `export var`, `onready`, `setget`, `PoolStringArray`,
  `funcref`; no `await`, no typed arrays, no `@export`).
- Simulation is **deterministic and tick based**. One tick = one frame of game logic. Rendering speed does
  not matter.
- Gameplay math uses a **fixed-point library**. Numbers that affect simulation are usually *strings*
  (`"1.5"`, `"-3.0"`) passed through helpers such as `fixed.add`, `fixed.mul`, `fixed.vec_mul` and
  `xy_to_dir(x, y, mul)`. Passing raw floats into these paths breaks determinism or crashes. Integers for
  ticks, damage and counters are plain ints.

## Main pieces

- `res://game.gd`: the match. Holds `p1` and `p2` (fighters), `objects` (projectiles and spawned
  things), `current_tick`, stage size and timer. `tick()` advances one frame. It emits
  `player_actionable` when someone must choose, and `game_won(winner)` at the end. `copy_to(other_game)`
  clones the full state, which is how the ghost preview (and budok's `simulate`) works.
- `res://main.gd`: the scene that creates matches (`_on_match_ready(match_data)` → `setup_game`) and runs
  the ghost preview of both players' highlighted moves.
- `res://characters/BaseChar.gd`: base class of every fighter (`hp`, `MAX_HEALTH`, `super_meter`,
  `supers_available`, `bursts_available`, `feints`, `air_movements_left`, `combo_count`, `queued_action`,
  `queued_data`, `queued_extra`). Inherits `res://obj/BaseObj.gd` (position, velocity, facing, the state
  machine, hitbox handling).
- `res://ObjectState.gd` → `res://characters/states/CharState.gd` (class `CharacterState`): one move or
  behaviour of a character.
- `res://mechanics/Hitbox.gd`: hit detection volumes attached to states. `ThrowBox` extends it for grabs.
- `res://projectile/BaseProjectile.gd`: base of projectiles (they are `BaseObj`s with their own states).
- `res://ui/ActionSelector/ActionButtons.gd`: the per-player move panel. It decides which moves are legal
  this turn and builds `data` and `extra` from the UI.
- Autoload singletons: `Global` (`current_game`, `name_paths`, version), `ReplayManager` (recorded inputs
  per tick, playback), `Network` (online play and the character-select instance `css_instance`),
  `SteamLobby`, `ModLoader`.

## How a decision is applied

`ActionButtons.on_action_submitted(action, data, extra)` → `fighter.on_action_selected(action, data, extra)`
sets `queued_*`. On the next tick `BaseChar.tick_before()` records the input in `ReplayManager`, applies
the extras (`process_extra`) and changes state to the queued move (`Continue` keeps or advances the current
state). If the chosen state is not usable at that moment, the game turns the input into a **forfeit**. This
is why budok validates every action against the live legal set first.

## Frames

`anim_length` is the move's length in ticks. Hitboxes become active at `start_tick` for `active_ticks`.
`iasa_at` ("interruptible as soon as") is when the move can be cancelled or ended. Negative values count
from the end. Startup = first non-detect hitbox `start_tick`. Recovery = `iasa_at` minus the last active tick.
