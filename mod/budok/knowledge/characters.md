# Anatomy of a character (vanilla or modded)

A character is a scene (`.tscn`) whose root script extends `res://characters/BaseChar.gd`. The game only
needs a few things from it. budok reads all of them automatically (`introspect_character`).

## Root node (the fighter)

- Exported tuning: `MAX_HEALTH`, `num_air_movements`, `num_feints`, `damage_taken_modifier`, portrait,
  `player_info_scene` (HUD widget), `player_extra_params_scene` (the character's extra options panel).
- **Custom variables** declared in the character's own script: ammo, install timers, stances, charge
  levels and so on. budok exposes them as `resources` (anything the script adds on top of `BaseChar`).
  The schema gives them labels and meaning.
- `extra_state_variables`: an exported newline-separated list of the character's custom variables that
  must be copied to ghost previews and simulations. A good index of the character's real resources.
- Common overrides: `process_extra(extra)` reads character extras, `tick()` does per-frame resource
  logic, `on_got_hit()`, `on_state_changed(stack)`, `init()` and `copy_to()`.

## The state machine

A child node holds one node per state. A **state** (`CharacterState`) is a move, a movement option or a
reaction (hurt, knockdown). Key exported fields:

| Field | Meaning |
|---|---|
| `title` | Button label (falls back to the node name). budok keys moves by **node name**. |
| `type` | Movement, Attack, Special, Super, Defense or Hurt (panel category). |
| `show_in_menu`, `selectable` | Whether it can appear as a button. |
| `air_type` | Grounded, Aerial or Both. `uses_air_movement` spends an air option. |
| `data_ui_scene` | Scene with the move's parameters (aim, charge, direction...). Its `get_data()` becomes `data`. |
| `anim_length`, `iasa_at`, `interrupt_frames` | Length and cancel points. |
| `interrupt_from_string` / `interrupt_into_string` / `hit_cancel_into_string` | Category names (one per line or comma separated) that decide which states can cancel into which. The panel's legal moves come from these plus `fighter.action_cancels`. |
| `super_level_`, `supers_used_` | Meter bars required and spent. |
| `combo_only`, `neutral_only`, `reversible`, `can_feint_if_possible`, `force_feintable`, `beats_backdash` | Usage rules. |
| `projectile_scene`, `projectile_tick` | Built-in projectile spawn. |
| `UsableRequirement` child nodes | Extra conditions for `is_usable()`. |

Behaviour lives in callbacks on the state script. `_enter()`, `_exit()`, `_tick()` and `_frame_N()` run on
tick N of the move (spawning objects, changing velocity, applying effects). When a move's damage or reach
comes from code (`spawn_object`, manual hitbox activation) and not from hitbox child nodes, budok marks
it `dynamic` and suggests reading its script.

## Hitboxes

Hitbox nodes under a state carry `damage`, `start_tick`, `active_ticks`, `hitstun_ticks`, `hit_height`
(High/Mid/Low), `hitbox_type` (Normal, Flip, ThrowHit, Burst, NoHitstun, Detect...), knockback
(`dir_x`, `dir_y`, `knockback` as fixed strings), `plus_frames`, `guard_break`, `knockdown`, `wall_slam`,
`hits_otg`, `beats_grab` and `followup_state`. `ThrowBox` adds `throw_state` (a grab). `Detect` boxes
deal no damage; they are used to trigger follow-ups. At runtime a state reaches its hitboxes through
`all_hitbox_nodes` (and the fighter through `host.hitboxes`); don't rely on `$Hitbox` paths.

## Extras panel

`player_extra_params_scene` is a `PlayerExtra` (HBoxContainer) whose `get_extra()` returns
character-specific options merged into every action's `extra`. `show_options()` decides which toggles are
visible this turn, and `update_selected_move(state)` enables or disables them per move. **The character's
`process_extra` usually trusts these values without re-checking**, so only toggles the panel shows as
enabled are legal. budok enforces this.
