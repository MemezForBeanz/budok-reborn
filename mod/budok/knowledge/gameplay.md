# Playing YOMI Hustle through budok

YOMI Hustle ("Your Only Move Is HUSTLE") is a turn-based fighting game with simultaneous moves. The game
pauses whenever at least one player can act. Each player who can act picks a move (plus options), both
lock in, and the engine plays the moves out tick by tick until someone can act again. Then the game
pauses for the next decision point.

## What a turn looks like

- **Who chooses**: a decision point happens when either player becomes *actionable* (their move reached a
  point where it can be cancelled or ended). The other player then gets a turn too. If they are mid-move
  (`busy` in the observation) their only option is `Continue`, which lets the move keep running, plus DI when
  they are being hit. budok only asks you when the game is waiting on you.
- **Hidden information**: both players choose blind. You learn the opponent's move only after the turn
  resolves (`history` in observations, or `outcome` from `submit_action`). A history entry with
  `"busy": true` and a `state` means that player was mid-move, so their `Continue` was not a choice.
- **Hold / Continue**: `Continue` (shown as "Hold") keeps doing what you are doing. When it is the only
  legal option, budok skips the turn for you unless you are being hit and DI matters
  (setting `turns.forced_turns`).
- **Hitlag**: on a hit or block, both the attacker and the defender freeze for a few ticks
  (`hitlag` in the observation; `in_hitlag` in simulations). A move you pick during hitlag starts when it
  ends, so the first ticks of a simulation can show nothing happening.

## Core interactions (rock-paper-scissors with frame data)

- **Attacks** beat grabs and movement once their hitbox comes out (startup frames). Faster startup wins trades.
- **Blocking / parrying** (`ParryHigh`, shown as Block) beats attacks. Its payload has a Block Height
  (`High` stops mid and high hits, `Low` stops lows; the wrong height still takes about half the damage)
  and a Melee Parry Timing: the tick, counted from now, when the hit arrives. Exact timing parries the hit
  for no damage; otherwise it is a block with chip damage (about a third). Against an attack started now,
  the timing is its `startup`; simulate to check.
- **Grabs** beat blocking. They lose to attacks and to jumping or moving away.
- **Movement** (dashes, jumps, rolls) sets spacing. Some movement has invulnerability windows.
- **Frame advantage**: after an exchange, whoever becomes actionable first acts first next turn.
  `simulate` reports this as `frame_advantage` (positive means you act first).
- **Range** matters most. A move whose hitbox cannot reach just whiffs and leaves you open.
  Compare `spacing.distance_x` (center to center) with each move's measured `reach` (how far its hitbox
  extends in front of your center; the opponent's body adds roughly 10-20 more). Moves with lunges or
  projectiles travel further than their reach suggests, and grabs need to be very close, so simulate when
  unsure.
- **Damage** listed per move is one hit's base damage (`damage`; multi-hit moves also give `hits` and
  `max_damage`). Real damage is lower in combos (scaling) and can differ with payloads, so simulate for
  exact numbers.
- **Stage**: the floor runs from `stage.left_wall` to `stage.right_wall` (minus and plus the stage's
  half-width). A fighter stops when the edge of its body reaches a wall, so its center stays a little inside.
  `wall_distance` on each fighter is the gap between its body and each wall. Being cornered limits
  retreat and makes knockback into the wall dangerous.

## Options on every move (extras)

- **DI** (directional influence) `{x, y}` in -100..100, screen space (+x right, +y down). While you are
  being hit it nudges your knockback direction. Use it to escape combos or avoid walls.
- **Aim payloads** (`xy`) are screen space too: the arrow as it would appear on screen, +x right, -y up.
  They do not flip when you face left or reverse. `{"x": 100, "y": 0}` always points right on screen.
- **reverse**: perform the move facing *away* from the opponent (only on reversible moves). Fighters
  always face their opponent at a decision point, so a reversed lunge, dash or kick travels away from them
  (toward the wall behind you). Use it to retreat with a move's movement or to bait. It is not a cross-up.
- **feint**: cancel the move early into something else on the next turn. It costs a free cancel, or a full
  meter bar when you have none. Only on feintable moves.
- **Character extras**: some characters add toggles (for example Ninja's sticky-bomb detonate or momentum
  release). They are listed under `extras.character` with whether each is available right now.

## Resources

- **HP**: reduce the opponent to 0, or have more HP when the timer runs out.
- **Super meter**: builds from attacking and moving forward. Supers and some specials cost bars.
- **Burst**: escapes combos (defensive) or extends pressure (offensive). Using one spends your burst stock
  (`burst`, at most one at a time). It is not one per match: the burst meter refills over time and faster
  when you take damage, and grants a new stock when full (`burst_progress`, in %, while you have none).
- **Free cancels**: limited feints, regained over time.
- **Air options**: jumps and air dashes left before landing.

## How to decide well

1. Read `situation` first. It is a one-paragraph summary.
2. Shortlist 2-4 legal moves that make sense for the range and state.
3. `simulate` the riskiest candidates against the opponent's most likely answers (block, attack, grab,
   or hold). Simulations run on the real engine and are deterministic.
4. Mix up. Repeating the same move is easy for a human (or another bot) to read. `history` shows
   your own patterns too.
5. Submit. On an `invalid_action` error, fix the action and resubmit with the same token. Read `notes` in
   the result: they say when the game changed your input (an aim outside the move's cone, a number out of
   range).
6. Remember. When you learn how a character really behaves or what works in a matchup, save it with
   `remember` (one concrete lesson each). Memories come back in later matches, for you and other bots.

## Moves with more than one step

Some moves stop after a few ticks and give you another decision (a follow-up, such as a dash that then
asks where to go). In `simulate`, `you_act_again_at` lists those decisions. Without `then` the preview
assumes you Continue there; pass `then: [{action, data}]` to preview the follow-up you plan.
