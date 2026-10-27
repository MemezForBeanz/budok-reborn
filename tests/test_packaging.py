"""Mod zips must contain one top-level folder with _metadata and ModMain.gd, and no test files."""

from __future__ import annotations

import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def test_package_layout() -> None:
    subprocess.run([sys.executable, str(REPO / "scripts" / "package_mod.py"), "--test-char"], check=True, cwd=REPO)
    for name in ("budok", "budok_test_char"):
        with zipfile.ZipFile(REPO / "dist" / f"{name}.zip") as archive:
            names = archive.namelist()
        assert f"{name}/_metadata" in names and f"{name}/ModMain.gd" in names
        assert all(entry.startswith(f"{name}/") for entry in names)
        assert not any("/tests/" in entry for entry in names)
    with zipfile.ZipFile(REPO / "dist" / "budok.zip") as archive:
        names = archive.namelist()
    assert "budok/knowledge/gameplay.md" in names
    assert "budok/schemas/vanilla/Ninja.json" in names
