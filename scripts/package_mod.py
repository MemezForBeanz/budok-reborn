#!/usr/bin/env python3
"""Build installable mod zips into dist/ (and optionally copy them into the game's mods folder).

    python scripts/package_mod.py                      # dist/budok.zip
    python scripts/package_mod.py --test-char          # also dist/budok_test_char.zip
    python scripts/package_mod.py --install "<game dir>/mods"

Each zip contains a single top-level folder (budok/, budok_test_char/), which is what the
YOMI Hustle mod loader expects.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MOD_ROOT = REPO / "mod"
DIST = REPO / "dist"
SKIP_PARTS = {".import", ".godot", "__pycache__"}
SKIP_SUFFIXES = {".uid", ".pyc"}
# Files from outside the mod folder that ship inside a zip: {folder: {zip path: repo path}}.
EXTRA_FILES = {"budok": {"budok/tools/budok_stdio.py": REPO / "connectors" / "python" / "budok_stdio.py"}}


def build(folder: str) -> Path:
    source = MOD_ROOT / folder
    metadata = source / "_metadata"
    if not metadata.is_file():
        raise SystemExit(f"{metadata} is missing")
    json.loads(metadata.read_text())  # must be valid JSON or the loader skips the mod
    if not (source / "ModMain.gd").is_file():
        raise SystemExit(f"{source}/ModMain.gd is missing")
    DIST.mkdir(exist_ok=True)
    target = DIST / f"{folder}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_dir() or SKIP_PARTS & set(path.parts) or path.suffix in SKIP_SUFFIXES:
                continue
            archive.write(path, Path(folder) / path.relative_to(source))
        for zip_path, repo_path in EXTRA_FILES.get(folder, {}).items():
            archive.write(repo_path, zip_path)
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--test-char", action="store_true", help="also package the budok test fighter")
    parser.add_argument("--install", type=Path, help="copy the zips into this mods folder")
    args = parser.parse_args(argv)
    built = [build("budok")]
    if args.test_char:
        built.append(build("budok_test_char"))
    for path in built:
        print(f"built {path.relative_to(REPO)}")
        if args.install:
            args.install.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, args.install / path.name)
            print(f"installed {args.install / path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
