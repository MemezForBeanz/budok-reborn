"""Runs the GDScript checks on a real Godot 3.5 binary when GODOT_BIN points at one (skipped otherwise).

    GODOT_BIN=/path/to/Godot_v3.5.1-stable_linux_headless.64 uv run pytest tests/test_godot.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
GODOT = os.environ.get("GODOT_BIN", "")

pytestmark = pytest.mark.skipif(not GODOT, reason="set GODOT_BIN to a Godot 3.5 binary")


def run(script: str) -> subprocess.CompletedProcess:
    return subprocess.run([GODOT, "--no-window", "--path", str(REPO / "mod"), "-s", script],
                          capture_output=True, text=True, timeout=180, check=False)


def test_every_script_compiles() -> None:
    result = run("res://tests/compile_check.gd")
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]
    assert "SCRIPT ERROR" not in result.stdout + result.stderr


def test_unit_tests() -> None:
    result = run("res://tests/run_tests.gd")
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-4000:]


def test_settings_ui_and_mod_list_integration(tmp_path: Path) -> None:
    user_dir = Path.home() / ".local/share/godot/app_userdata/budok tests/budok"
    shutil.rmtree(user_dir, ignore_errors=True)
    result = run("res://tests/ui_smoke.gd")
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "FAIL" not in output, output[-4000:]
    assert "SCRIPT ERROR" not in output, output[-4000:]
