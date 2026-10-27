# Writing a character schema (notes) with budok

Goal: give a player who has never seen this character enough understanding to pick good moves. budok has
already measured the mechanics. You add meaning.

## Workflow

1. `introspect_character {character}` gives the skeleton: every selectable move with title, type, air
   rules, meter cost, cancel categories, measured `frames` (startup / active / recovery / damage), hitbox
   flags (throw, guard break, knockdown, low/high), payload presence, `dynamic` flags and script paths.
   It also lists the character's custom `resources`. Page through big characters with `offset`/`limit`.
2. For moves marked `dynamic`, or with unclear names, read their script (`read_source {path}`; the path is
   in `script_path`, or use `include_source: true`). Look at `_frame_N` callbacks, `spawn_object` calls
   and velocity changes.
3. Read the fighter script (`script_path` at the top of the skeleton) for resources, `process_extra` and
   passives.
4. Submit notes in batches with `submit_character_schema` (partial submissions merge). Fix any reported
   errors and resubmit.
5. Finish with `summary` (archetype, game plan, strengths, weaknesses, tips) and `resources` meanings.

## Format (`budok.character.v1`)

```json
{
  "summary": {
    "archetype": "rushdown with a command grab",
    "game_plan": "Close the gap with dashes, then mix strikes and the command grab.",
    "strengths": ["fast close-range buttons"], "weaknesses": ["no projectile"], "tips": ["..."]
  },
  "resources": {"charge_level": {"label": "Charge", "meaning": "0-3; each level adds damage to Blast", "hidden": false}},
  "extras": {"detonate": {"meaning": "explodes the active bomb this turn"}},
  "moves": {
    "Blast": {
      "category": "attack", "range": "mid", "risk": "medium",
      "summary": "Forward energy burst; big damage at charge 3.",
      "beats": "grabs, slow startups", "loses_to": "parry, jump over",
      "use_when": "opponent is at mid range and likely to grab",
      "avoid_when": "point blank vs a fast jab",
      "payload_hint": "Aim: keep y near 0 against grounded opponents",
      "combo_hint": "cancels into Dash on hit", "tags": ["launcher"]
    }
  }
}
```

- `moves` keys are state (node) names from the skeleton. Button titles are accepted and remapped.
- `category`: attack, grab, projectile, movement, defense, super, special, utility, install or counter.
- `range`: close, mid, far, fullscreen or any. `risk`: low, medium or high.
- Text fields up to 600 characters each. Lists up to 8 items.
- Do **not** include startup, damage, frames or meter. They are measured and would be ignored.
  Keep numbers out of the text fields too: players already see the measured values, and a wrong number
  in a note misleads them. If a number matters (a lunge distance, a charge count), check it with
  `simulate` first.
- Hitboxes are not hits. Hitboxes that share a `group` hit at most once per move together (a slash can
  use twelve boxes along its path and still hit once); only boxes in different groups, or `looping`
  boxes, hit again. The skeleton's `hits` already counts this.

## Quality checklist

- Every selectable move has at least `category` and `summary`.
- Distinguish moves with the same animation but different rules (air vs ground versions, meter versions).
- Say what each payload control does when it matters (aim angles, charge counts).
- Mention unusual properties: invulnerability, armor, projectiles that persist, moves that spend or build
  resources, stance changes.
