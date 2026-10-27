# Playing YOMI Hustle through budok

YOMI Hustle ("Your Only Move Is HUSTLE") is a turn-based fighting game with simultaneous moves. The game
pauses whenever at least one player can act. Each player who can act picks a move (plus options), both
lock in, and the engine plays the moves out tick by tick until someone can act again. Then the game
pauses for the next decision point.

## What a turn looks like

- **Who chooses**: a player chooses when they are *actionable*, meaning their current move reached a point
  where it can be cancelled or ended. If you are mid-move or stuck in hitstun, you may not get a turn while
  the opponent does. budok only asks you when the game is waiting on you.
- **Hidden information**: both players choose blind. You learn the opponent's move only after the turn
  resolves (`history` in observations, or `outcome` from `submit_action`).
- **Hold / Continue**: `Continue` (shown as "Hold") keeps doing what you are doing. When it is the only
  legal option, budok skips the turn for you unless you are being hit and DI matters
  (setting `turns.forced_turns`).

## Core interactions (rock-paper-scissors with frame data)

- **Attacks** beat grabs and movement once their hitbox comes out (startup frames). Faster startup wins trades.
- **Blocking / parrying** (`ParryHigh`, other defense moves) beats attacks. A parry needs the right timing
  and height: low hits must be blocked low. Many parry moves take a timing/height payload.
- **Grabs** beat blocking. They lose to attacks and to jumping or moving away.
- **Movement** (dashes, jumps, rolls) sets spacing. Some movement has invulnerability windows.
- **Frame advantage**: after an exchange, whoever becomes actionable first acts first next turn.
  `simulate` reports this as `frame_advantage` (positive means you act first).
- **Range** matters most. A move whose hitbox cannot reach just whiffs and leaves you open.
  Compare `spacing.distance_x` with each move's measured `reach` (how far its hitbox extends in front of
  you; the opponent's body adds roughly 10-20 more). Moves with lunges or projectiles travel further than
  their reach suggests, so simulate when unsure.

## Options on every move (extras)

- **DI** (directional influence) `{x, y}` in -100..100, screen space (+x right, +y down). While you are
  being hit it nudges your knockback direction. Use it to escape combos or avoid walls.
- **reverse**: perform the move facing the other way (only on reversible moves).
- **feint**: cancel the move early into something else on the next turn. It costs a free cancel, or a full
  meter bar when you have none. Only on feintable moves.
- **Character extras**: some characters add toggles (for example Ninja's sticky-bomb detonate or momentum
  release). They are listed under `extras.character` with whether each is available right now.

## Resources

- **HP**: reduce the opponent to 0, or have more HP when the timer runs out.
- **Super meter**: builds from attacking and moving forward. Supers and some specials cost bars.
- **Burst**: escapes combos (defensive) or extends pressure (offensive). Usually one per match, refilling slowly.
- **Free cancels**: limited feints, regained over time.
- **Air options**: jumps and air dashes left before landing.

## How to decide well

1. Read `situation` first. It is a one-paragraph summary.
2. Shortlist 2-4 legal moves that make sense for the range and state.
3. `simulate` the riskiest candidates against the opponent's most likely answers (block, attack, grab,
   or hold). Simulations run on the real engine and are deterministic.
4. Mix up. Repeating the same move is easy for a human (or another bot) to read. `history` shows
   your own patterns too.
5. Submit. On an `invalid_action` error, fix the action and resubmit with the same token.
