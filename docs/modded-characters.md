# Modded characters

## What budok does automatically

For any character the game can load, vanilla or modded, budok instances the character scene off-tree
(its `_ready` never runs) and measures:

- every selectable state: title, type, air rules, air option use, meter required and spent, cancel
  categories, combo-only and neutral-only rules, reversible and feintable;
- hitboxes: startup, active frames, recovery (from `iasa_at`), damage, hitstun, reach and vertical span,
  hit height, throw, guard break, knockdown, wall slam and follow-ups;
- payload presence and, at turn time, the exact payload spec from the live UI controls;
- custom script variables (anything the character adds on top of `BaseChar`), exposed as resources;
- character extras (from the character's extras panel), with their live availability;
- `dynamic` moves whose behaviour is set in code, with their script path.

The skeleton gets a **fingerprint**. When the mod changes the character, stored notes are flagged
`stale`. They are still used, but bots and players can see they may be outdated.

## Notes ("schema") lookup order

1. `user://budok/schemas/<name>.json` with `"override": true` (a player's own override)
2. **Shipped in the character's mod**:
   - `<scene path without .tscn>.budok.json`, for example `res://MyMod/Kirby.budok.json` next to
     `res://MyMod/Kirby.tscn`
   - `res://<ModFolder>/budok/<Character>.json`
   - `res://<ModFolder>/budok_schema.json`: one schema, or `{"characters": {"Name": {...}}}`
3. Bundled with budok (vanilla characters)
4. `user://budok/schemas/<name>.json` (generated or hand-written)
5. Registry cache (opt-in)

## For mod authors

Write notes only. budok measures everything else. Easiest path:

1. Start a match with your character in game, open budok's panel → Characters → **Generate with AI**
   (or ask a connected chatbot to run the `annotate_character` prompt). Fix anything you disagree with.
2. **Export** writes the file to `user://budok/export/<Character>.budok.json`.
3. Ship it next to your character scene as `<Scene>.budok.json`.

Format: [`mod/budok/schemas/character.v1.json`](../mod/budok/schemas/character.v1.json); a guided
description is in [`knowledge/annotating.md`](../mod/budok/knowledge/annotating.md).

## Limits

- Hitboxes created or moved purely in code (no hitbox nodes) can't be measured statically. Such moves
  are flagged `dynamic`, and `simulate` still shows their real behaviour.
- Custom data-UI controls that budok doesn't recognise are offered as `opaque`, with the game's default
  value. Bots can send values of the same shape.
- Exported game builds may ship vanilla scripts compiled. Then `read_source` works for mod scripts (mods
  usually ship text) but not for those vanilla files. The knowledge pack covers the vanilla API.
