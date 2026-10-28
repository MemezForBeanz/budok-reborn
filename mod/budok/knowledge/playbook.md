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
     doing a lot of damage or carrying you into a corner, and you have a burst.
   - **You act first** (the opponent is busy, in hitstun, or slower to recover): this is your advantage.
     Hit them with something fast that reaches; in a combo, keep hitting while it keeps connecting
     (simulate to check it connects). Don't give the turn back with a slow or unsafe move.
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
   - `look_ahead` (when budok's decision core is set up): compares several of your moves against the
     opponent's likeliest replies and plays each several turns deep, with fast decision models choosing
     both fighters' moves. You get a few lines per move. Use it in neutral and at turning points; skip it
     for obvious turns (one sensible move, a combo you already confirmed, forced holds).
4. **Mix up.** The opponent reads patterns too. Don't repeat a move they just punished. Use their habits
   from `history`: if they block a lot, grab; if they attack on every turn, block or use a faster move;
   if they jump, anti-air.
5. **Submit** with the turn token. One short note on why is enough.

## Reading look_ahead

- `next_turn`: what happens in this exchange against each tested reply, with how likely that reply is.
  "deal 90, take 0, you act first" against a likely reply is a strong sign.
- `lines`: imagined continuations several turns deep. Both sides are played by the decision models, so
  they show what tends to follow (a combo, a punish, a reset), not what will surely happen.
- `score`: damage dealt minus taken (a KO counts 1000), weighted by how likely each reply is, plus the
  deep lines. Compare scores between moves; the absolute number matters less.
- `decision_model_pick`: the decision models' choice after seeing all of the above.
- Prefer moves that do well against the likely replies and are not disastrous against any of them.
  It is advice: you know the match history and the opponent's habits, so you decide.
- Steer it: name your candidates in `moves`, the replies you fear in `opponent_moves`, set `depth`
  (more turns, slower), and describe your plan in `focus` and the opponent's habits in
  `opponent_style` so the imagined lines play like this match.
