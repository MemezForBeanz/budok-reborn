# budok Test Fighter

A tiny character mod for testing budok's support for modded characters without needing art. It inherits
the vanilla Ninja scene and adds:

- **`charge_level`**: a custom resource (0-3), copied to ghosts via `extra_state_variables`.
- **Charge Blast** (`ChargeBlast` state): a code-driven attack whose damage depends on how many charges it
  spends. It has a `CountOption` payload (`Spend`, 0-3) and its damage is set in `_enter()`, so budok
  flags it as `dynamic`.
- **Charge extra toggle**: a custom `PlayerExtra` panel. The toggle is hidden at max charge and disabled
  with defensive moves. budok must map it and enforce its availability.

It ships **without** a budok schema, so it exercises the generation path. To test the "schema shipped in
the mod" path instead, add `Tester.budok.json` next to `Tester.tscn` (export one from budok first).

Install: zip the `budok_test_char` folder (`scripts/package_mod.sh` builds `dist/budok_test_char.zip`) and
put it in the game's `mods/` folder next to `budok.zip`. "Tester" then appears in character select and in
budok's `list_characters`.
