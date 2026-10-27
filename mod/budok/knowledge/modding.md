# YOMI Hustle modding conventions

## Mod packaging

- A mod is a **zip** in the game's `mods/` folder or a Steam Workshop item. The mod loader mounts it as a
  resource pack, so its files appear under `res://<ModFolder>/...`.
- Each mod folder contains a `_metadata` JSON file: `name`, `friendly_name`, `description`, `author`,
  `version`, `id`, `requires` (`[""]` for none), `overwrites` (replaces vanilla characters) and
  `priority` (load order).
- Entry point: `ModMain.gd`, a Node whose `_init(modLoader)` runs at load time. It usually calls
  `modLoader.installScriptExtension("res://<ModFolder>/Something.gd")`. That script `extends` a vanilla
  script by path and takes over its path, so every later `load()` of the vanilla path gets the extended
  version. Extensions chain: call the parent with `.method()`.
- The mod loader adds a hash of the active mods to `Global.VERSION`, so online peers must run the same mods.

## Custom characters

- Characters are registered with the built-in character loader: from an extension of
  `res://ui/CSS/CharacterSelect.gd`, call `addCustomChar(name, scene_path, button_name)` in `_ready()`.
- Internally a custom character is keyed as `F-<hash of mod folder>__<Name>`. That key is what
  `match_data.selected_characters[n].name` and `Global.name_paths` use, once the character is loaded.
- Characters load **lazily**: the loader imports their assets and adds them to `Global.name_paths` the
  first time they are picked (`CharacterSelect.loadListChar(index)`). budok's `start_match` does this for you.
- A character scene's root script extends `res://characters/BaseChar.gd`. Its states usually live under
  `res://<ModFolder>/<char>/states/`. Common vanilla state bases (`CharState.gd`, `Grab.gd`, `Dash.gd`...)
  live in `res://characters/states/`.
- Custom variables that must survive ghosts and replays are added to the fighter's `state_variables` or
  copied in `copy_to()`.

## Shipping a budok schema with a character (no generation needed)

Put the notes file in one of these places inside your mod and budok picks it up automatically:

1. `<scene path without extension>.budok.json` next to the character scene, for example
   `res://MyMod/kirby/Kirby.budok.json` for `res://MyMod/kirby/Kirby.tscn`.
2. `res://<ModFolder>/budok/<CharacterName>.json`
3. `res://<ModFolder>/budok_schema.json`: either one schema, or `{"characters": {"Name": {...}, ...}}` for
   mods with several characters.

The format is described in `yomi://schema/format`. Only write notes. Frame data, meter costs and payload
shapes are measured from your scene at runtime, so they can never be out of date. Players can still
override shipped notes locally.

## Useful patterns when reading mod code

- Search the mod folder for `addCustomChar` to find every character it adds.
- `extends "res://characters/states/..."` tells you which vanilla behaviour a move reuses.
- `_frame_N` functions hold timed effects. `spawn_object(...)` creates projectiles or summons.
- `host` inside a state is the fighter. `host.opponent` is the other fighter.
- `fixed.*` calls operate on number strings.
