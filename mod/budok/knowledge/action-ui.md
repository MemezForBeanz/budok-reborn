# Move parameters (data) and the action panel

Each move button may own a **data UI scene** (an `ActionUIData` node). When locking in, the game calls
`get_data()` on it:

- no child controls → `null`
- exactly one child → that child's value directly (not wrapped in an object)
- several children → `{child_name: child_value, ...}`
- a custom `ActionUIData` script can override `get_data()` and return anything (for example a plain string).
  budok then reports the payload as `opaque` with the game's own default.

## Vanilla controls and their values

| Control | Value | budok payload type |
|---|---|---|
| XYPlot (aim pad, also the DI pad) | `{"x": int, "y": int}`, each -100..100, screen space (+y down). May be angle-limited. | `xy` |
| 8Way direction picker | `{"x": -1..1, "y": -1..1}`, or `"Neutral"` when nothing is chosen | `direction8` (pass a name such as `"NE"`) |
| CountOption | `{"count": int}` | `int` (wraps as `count`) |
| HorizSlider | `{"x": int}` | `int` (wraps as `x`) |
| CheckButton | `true` / `false` | `bool` |
| OptionButton | `{"id": int, "name": String}` | `option` (pass the name) |

Every payload has a `default`, the value the game would send if a player clicked the move without
touching its controls. Omit `data` to use it.

## Extras sent with every move

`{"DI": {x, y}, "reverse": bool, "feint": bool, "prediction": int}` plus the character's own extras.
`prediction` is unused by current builds and budok always sends the neutral value.

## Legality

The panel shows a button only if the move's categories allow cancelling from the current state, the move
`is_usable()` (meter, air options, combo-only/neutral-only, stance, custom requirements) and the stance
allows it. budok lists exactly the visible, enabled buttons as `legal_actions`. Anything else is rejected
before it reaches the game.
