"""Static checks over the mod sources that need no game: data files, cross-references and syntax."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
MOD = REPO / "mod"
BUDOK = MOD / "budok"
GD_FILES = sorted(MOD.rglob("*.gd"))


def res_to_path(res: str) -> Path:
    assert res.startswith("res://")
    return MOD / res[len("res://"):]


def test_metadata_files_are_valid_json() -> None:
    for folder in ("budok", "budok_test_char"):
        meta = json.loads((MOD / folder / "_metadata").read_text())
        assert meta["id"] == folder and meta["requires"] == [""]
        assert (MOD / folder / "ModMain.gd").is_file()


def test_default_config_has_both_ai_roles() -> None:
    config = json.loads((BUDOK / "config" / "default_config.json").read_text())
    for role in ("play", "annotate"):
        assert {"provider", "model", "effort", "max_tokens", "max_steps"} <= set(config["ai"][role])
        assert config["ai"][role]["provider"] in config["ai"]["providers"]
    assert config["mcp"]["host"] == "127.0.0.1", "server must default to localhost only"
    assert config["mcp"]["require_token"] is True
    assert all(provider["api_key"] == "" for provider in config["ai"]["providers"].values()), "no keys in shipped config"


def test_character_schema_is_valid_json_schema() -> None:
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((BUDOK / "schemas" / "character.v1.json").read_text())
    jsonschema.Draft202012Validator.check_schema(schema)


@pytest.mark.parametrize("path", sorted((BUDOK / "schemas" / "vanilla").glob("*.json")), ids=lambda p: p.stem)
def test_bundled_schemas_validate(path: Path) -> None:
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((BUDOK / "schemas" / "character.v1.json").read_text())
    data = json.loads(path.read_text())
    jsonschema.Draft202012Validator(schema).validate(data)
    assert data["character"] == path.stem
    assert len(data["moves"]) > 20


def test_vanilla_roster_covered() -> None:
    names = {p.stem for p in (BUDOK / "schemas" / "vanilla").glob("*.json")}
    assert {"Ninja", "Cowboy", "Wizard", "Robot", "Mutant"} <= names


@pytest.mark.parametrize("path", GD_FILES, ids=lambda p: str(p.relative_to(MOD)))
def test_res_references_exist(path: Path) -> None:
    """Every res://budok* path a script references must ship with the mod."""
    text = path.read_text()
    for res in re.findall(r'"(res://budok[^"]*\.(?:gd|json|tscn|md))"', text):
        assert res_to_path(res).is_file(), f"{path.name} references missing {res}"


def test_scene_references_exist() -> None:
    for scene in MOD.rglob("*.tscn"):
        for res in re.findall(r'path="(res://budok[^"]*)"', scene.read_text()):
            assert res_to_path(res).is_file(), f"{scene.name} references missing {res}"


def test_every_tool_has_a_handler() -> None:
    text = (BUDOK / "mcp" / "Tools.gd").read_text()
    declared = re.findall(r'_add\("([a-z_]+)"', text)
    handlers = set(re.findall(r"func _t_([a-z_]+)\(", text))
    assert len(declared) == len(set(declared)), "duplicate tool names"
    assert set(declared) == handlers


def test_knowledge_topics_used_by_prompts_exist() -> None:
    prompts = (BUDOK / "ai" / "Prompts.gd").read_text() + (BUDOK / "mcp" / "Resources.gd").read_text()
    for topic in set(re.findall(r'knowledge\("([a-z-]+)"\)', prompts)):
        assert (BUDOK / "knowledge" / f"{topic}.md").is_file(), topic


def test_secrets_never_readable_over_mcp() -> None:
    browser = (BUDOK / "core" / "SourceBrowser.gd").read_text()
    assert 'begins_with("res://")' in browser
    tools = (BUDOK / "mcp" / "Tools.gd").read_text()
    assert '"api_key", "base_url", "auth_token"' in tools


def _gdparse() -> str | None:
    return shutil.which("gdparse")


@pytest.mark.skipif(_gdparse() is None, reason="gdtoolkit (gdparse) not installed")
@pytest.mark.parametrize("path", GD_FILES, ids=lambda p: str(p.relative_to(MOD)))
def test_gdscript_parses(path: Path) -> None:
    result = subprocess.run([_gdparse(), str(path)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr[-2000:]
