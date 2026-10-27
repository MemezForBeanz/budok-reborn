# budok

LLMs can fight! Here's Sonnet vs. Opus from the original project:

https://github.com/user-attachments/assets/5e855a46-f6a0-48f7-b811-9c26b8d8a907

**budok** is a native mod for [YOMI Hustle](https://store.steampowered.com/app/2212330/Your_Only_Move_Is_HUSTLE/),
a turn-based, simultaneous-move fighting game. It lets AI play the game inside your normal Steam install:

- **Chatbot apps over MCP.** The mod runs an MCP server inside the game, so Claude Desktop, Claude Code
  and other MCP clients can start matches, see the situation, **simulate moves on the real engine** and
  lock in decisions. Play against your chatbot, or let two bots fight.
- **API-key mode ("token mode").** Paste an Anthropic, OpenAI, OpenRouter or local-model key and the mod
  plays a slot by itself. Move making and schema writing each have their own model and behaviour settings.
- **Every character.** That includes vanilla characters, characters added in newer builds, and **modded
  characters** loaded through the character loader. budok measures each character's moves straight from
  its scene (frame data, reach, meter costs, payloads, custom resources and extras). An LLM, or the mod
  author, only adds the meaning of each move.

You must own the game. Everything runs locally. Online and lobby matches are never controlled.

## Install

1. Build `budok.zip` with `python scripts/package_mod.py` (it lands in `dist/`).
2. Put the zip in the game's `mods/` folder (next to the game executable; create it if needed). Leave it
   zipped.
3. Start the game. All settings live in the game's own mod settings: **main menu → Mod List → budok**
   (tabs Connect, Players, AI, Providers, Characters, Advanced). The same tabs open from **Options →
   budok settings** (also in the pause menu during a match), the F8 key and the small **budok** button in
   the top-right corner, which you can turn off under Advanced.
4. Optional check: `python connectors/python/selftest.py --token <token>` plays a short match through
   MCP (both sides random moves, a few simulations) and reports problems.

## Connect a chatbot (MCP)

The **Connect** tab shows the server URL (default `http://127.0.0.1:8765/mcp`) and a secret token,
with copy buttons for ready-made configs:

- **Claude Code**: `claude mcp add --transport http budok http://127.0.0.1:8765/mcp --header "Authorization: Bearer <token>"`
- **Claude Desktop** (and other clients that only start local commands): click **Copy Claude Desktop
  config** and merge its `mcpServers` entry into `claude_desktop_config.json`. It runs budok's bundled
  stdio bridge with Python 3 (no Node.js needed), which reads the token and port from the game's settings
  (so the config has no token in it) and reconnects by itself when the game restarts.
  `connectors/python/budok_stdio.py` is the same file, if you'd rather keep it somewhere else.
- **Any other MCP client**: Streamable HTTP at the URL. Send `Authorization: Bearer <token>`, or add
  `?token=<token>` for clients that can't set headers.
- **Web chatbots** (claude.ai connectors, ChatGPT) need a public HTTPS URL. Run a tunnel such as
  `cloudflared tunnel --url http://127.0.0.1:8765` and use `https://<tunnel>/mcp?token=<token>`. Anyone
  with that URL and token can control your game, so close the tunnel when done.

Then ask your chatbot something like *"Start a match, I'm Ninja on P1, you play Cowboy on P2."* It will
call `start_match`, loop `wait_for_turn` → `simulate` → `submit_action`, and you play P1 with the normal
game UI. The `play_match` MCP prompt gives it the rules and both characters' notes. See
[docs/mcp.md](docs/mcp.md) for every tool.

## Let the mod play by itself (token mode)

In the **AI** tab (keys go in **Providers**):

- **Move making**: provider, model, effort, tool steps, simulations per turn, play style and risk.
- **Schema creation**: a separate provider and model for writing notes on modded characters (a strong
  model is worth it, since this runs once per character).
- **Providers** tab: API keys for Anthropic, OpenAI and OpenRouter (stored in `user://budok/config.json`,
  or read from the usual environment variables), plus the URL of a local OpenAI-compatible server
  (Ollama, LM Studio).

Then set a slot to `ai` in the **Players** tab, or start a match with `controllers: {"p2": "ai"}`. Each
turn the model gets the situation, can simulate candidate moves and must submit one. Turn timeouts fall
back to a safe move. All settings: [docs/settings.md](docs/settings.md).

## Modded characters

Modded characters work out of the box: budok lists them, loads them on demand and reads their moves from
the scene. To give bots real understanding, each character also gets **notes** (what each move is for,
what it beats, when to use it):

1. **Shipped by the mod**: if the character's mod contains a budok schema, it is used directly, with no
   generation. Mod authors can put `<Character>.budok.json` next to the character scene. See
   [docs/modded-characters.md](docs/modded-characters.md).
2. **Generated by your chatbot**: ask it to run the `annotate_character` prompt. It reads the measured
   skeleton and the character's code (`introspect_character`, `read_source`) and saves notes with
   `submit_character_schema`.
3. **Generated in token mode**: the **Characters** tab → *Generate with AI*.
4. **Automatically** (on by default): when a match starts with a character that has no notes, a separate
   **notes agent** writes them before the bots play, in its own context, so the chat that plays never has
   to. If [Claude Code](https://docs.anthropic.com/en/docs/claude-code) is installed, budok starts it in
   the background with your Claude login (only budok's notes tools allowed) and it exits when it is done.
   Without Claude Code, open a second chat with the `notes_worker` prompt and leave it waiting. The
   in-game AI (with an API key) can work alongside. Characters tab → *Automatic notes* picks who does it
   and when (before matches, or for every character on boot and when a chatbot connects).
5. **Community registry** (opt-in): fetch notes other players published for the exact same character build.

Vanilla characters ship with curated notes. Bots also get a knowledge pack about the engine and modding
conventions (MCP resources `yomi://knowledge/...`) and read-only access to game and mod scripts.

## Memory

Bots can keep lessons between matches: `remember` saves a note about a character, a matchup or the game in
general, at any time; `recall` and `forget` read and delete them. Memories live in this game install
(`user://budok/memory`, one JSON file per subject), are shared by every bot that plays here (each note
records who wrote it) and come back at the start of later matches. The in-game AI saves 1-3 lessons
after each of its matches (`ai.play.reflect_after_match`), and schema generation reads them as evidence.
To change a move's notes for good, bots can also update the schema directly with
`submit_character_schema`. **Characters → Clear memories** deletes a character's memories.

`mod/budok_test_char` is a small test character mod (Ninja-based, with a custom resource, a code-driven
move with a charge payload, and a custom extra toggle). Use it to try the modded-character flow without
art: `python scripts/package_mod.py --test-char`.

## Automation

- **GDScript**: point `automation.script` at a script with `func run(runtime)`. It gets the same API the
  MCP tools use. Example: `mod/budok/automation/examples/series.gd` (AI vs AI series).
- **Python / anything else**: drive the MCP server. `connectors/python/budok_connector.py` is a
  dependency-free client with `status`, `characters`, `tool ...` and `series` commands.

See [docs/automation.md](docs/automation.md).

## Development

```bash
uv sync                      # dev tools: pytest, jsonschema, ruff
uv run pytest                # data, consistency, GDScript syntax (gdtoolkit 3.x), connector, packaging
GODOT_BIN=/path/to/godot-3.5.1 uv run pytest   # adds real-compiler, unit and settings-UI checks
python scripts/package_mod.py --test-char --install "<game>/mods"
```

Always run the Godot checks before shipping. Godot 3 has built-in functions (`to_json`, `parse_json`),
keywords (`tool`) and virtuals (`_notification`) that a syntax-only parser accepts but the real compiler
rejects. A single compile error stops the whole mod from loading.

Layout: `mod/budok/` (the mod: `core/` game adapter, `mcp/` server, `ai/` token mode, `ui/`,
`knowledge/`, `schemas/`), `mod/budok_test_char/`, `connectors/python/`, `docs/`, `tests/`.
Architecture notes: [docs/architecture.md](docs/architecture.md).
