# Playbook: how to play a turn

Matches last 50-150 turns. Spend effort where the game is decided (neutral guesses, combo starts,
escapes) and move fast on obvious turns.

## Before the first turn

1. Learn your tools: from your character's notes (the primer, or `describe_character`), pick out a fast
   poke, a long-range move or projectile, an anti-air, a combo starter, your grab, your block (`ParryHigh`)
   and your movement (dash, jump). That short list is your game plan; you don't need every move.
2. Do the same for the opponent's 3-4 most dangerous moves (fastest attack, longest reach, their grab).
3. The first turns are for information: play safe (a poke at the edge of your range, a block, a step
   back) and watch what the opponent does. `history` shows their choices once each turn resolves.

## Every turn

1. **What kind of turn is it?** Read `situation`:
   - **You are being hit** (hurt state, combo count against you): you can only hold with DI, or burst.
     DI away from the opponent, and away from the wall when you are near it. Burst when the combo is
     doing a lot of damage or carrying you into a corner, and you have a burst. `look_ahead` here plays
     the opponent's routes against each DI and burst and recommends the one that holds them lowest.
   - **You act first** (the opponent is busy, in hitstun, or slower to recover): this is your advantage.
     Hit them with something fast that reaches; in a combo, keep hitting while it keeps connecting.
     Don't give the turn back with a slow or unsafe move. When they can only DI or burst, `look_ahead`
     runs the combo solver: it searches your routes on the engine and gives the one that keeps the most
     damage whatever they DI. Play its first move, then call it again next turn from where the hit
     really sent them.
   - **Neutral** (both can act, nobody is hit): it is a guess. Pick by spacing:
     - far (beyond both reaches): approach (dash, jump), throw a projectile, or wait for them to come in;
     - mid (inside your poke's reach): fast pokes, and moves that beat their likely approach;
     - close: the triangle. Attacks beat grabs and movement, blocks beat attacks, grabs beat blocks.
   - **They act first** (you are slower to recover): respect it. Block, or get out (back dash, jump,
     a move with invulnerability). Attacking into their advantage usually loses.
2. **Shortlist 2-4 moves** that fit that kind of turn. Use the notes (`use_when`, `beats`, `loses_to`)
   and the frame data: startup (lower is faster) and reach against `spacing.distance_x`.
3. **Check the risky ones** when it matters:
   - `simulate`: one of your moves against one assumed reply, on the real engine. Exact for the next
     exchange: damage, whether it reaches, who acts first after.
   - `look_ahead`: plays each of your candidate moves (plus your blocks and dodges) against every reply
     the opponent has, each move and its aim, strength and direction variants, up to the next decision
     point. With budok's decision core set up it also picks your candidates if you don't name them and
     plays them several turns deeper, with fast decision models choosing both fighters' moves. On combo
     turns it runs the combo solver instead (no model needed). Use it in neutral, on combo turns and at
     turning points; skip it for obvious turns (one sensible move, forced holds).
4. **Mix up.** The opponent reads patterns too. Don't repeat a move they just punished. Use their habits
   from `history`: if they block a lot, grab; if they attack on every turn, block or use a faster move;
   if they jump, anti-air.
5. **Submit** with the turn token. One short note on why is enough.

## Reading look_ahead

- `coverage`: how many exchanges were played. "536 of 536" means every reply was tried against every
  move; fewer means time ran out before the least likely replies.
- Per move: `action`, `data`, `extra` are what to submit. `average` is damage dealt minus taken (a KO
  counts 1000), weighted by how likely each reply is. `worst` is the reply that hurts the move most,
  with `reply_action` to name it back in `opponent_moves`. `likely` and `dangerous` list the
  likeliest replies and the costliest ones.
- A good average can hide one lethal counter: prefer moves whose worst case you can live with, unless
  that reply is very unlikely and the reward is big. "take 0, you act first" against every likely
  reply is a strong sign.
- `lines`: imagined continuations several turns deep, each move against the likeliest reply and then
  its worst. Both sides are played by the decision models, so they show what tends to follow (a combo,
  a punish, a reset), not what will surely happen. Each step is an action you could submit; `stopped`
  says why a line is shorter than `depth` (a KO, out of time, the model gave no move, a long move).
- `followup`: what the lines showed after the next exchange (estimated from similar positions where the
  move had no line of its own). `score` = `average` + `followup`; compare scores between moves, the
  absolute number matters less.
- `recommended`: the engine's pick, the best score among moves whose worst case is not a KO against you.
  `close_calls` are within 25 of it: there, reading the opponent decides (`decision_model_pick` is the
  models' choice among them). `avoid` lists moves whose worst case is a KO against you.
- On a combo turn (`situation` attacking or defending) read `combo`:
  - `best_route` (attacking) or `their_best_route` (being hit): the first move and the steps, and
    `robust_damage`, which the route keeps whatever the defender DIs. `max_damage` is the most it does
    against one DI, and `by_di` gives each DI's damage and how it ends. `escape` is the DI that ends it
    soonest, `if_they_escape` / `if_you_escape` what a burst at each step does, `ends` where everyone
    stands after.
  - `checked` says whether the route was played against every DI (or only no DI, if time ran out).
    "still going ... (the search ended)" means the combo was still on when it stopped searching.
  - `remembered_route`: whether this turn is where last turn's route said it would be, and whether its
    planned move is still the best.
  - `combo_goal` changes what it optimizes: `safe` (don't end where they act first), `corner` (carry
    them to the wall), `save_resources` (keep meter and burst).
- `start` is where every run began, and `preview` says whether the engine's copy matched the live
  match. `engine_data` and `note` show what a move's data became after its limits (a clamped aim).
  If the real turn plays out differently, compare with these to tell a wrong guess from a wrong input.
- It is advice: you know the match history and the opponent's habits, so you decide.
- Steer it: name your candidates in `moves` (on a combo turn they are searched whatever the first screen
  says), the replies you fear in `opponent_moves` (with data, to test an exact aim), set `depth` (more
  turns, slower), and describe your plan in `focus` and the opponent's habits in `opponent_style` so the
  imagined lines play like this match. A second call in the same turn reuses the exchanges already
  played, so it is quick.
