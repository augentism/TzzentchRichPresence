"""Deploy the current working state into the game's mods/ folder for testing.

Copies only the whitelisted runtime files (see build_release.INCLUDE), so the
1.3 GB discord_social_sdk/ tree and the tz-native/ build directory can never be
dragged into the game folder.

Also ensures the mod is listed in mod_load_order.txt -- without an entry there
DMF silently never loads the mod, which looks identical to the mod being broken.

Usage:
    python deploy.py              # deploy whatever is currently in bin/
    python deploy.py --build      # rebuild the native DLL first
"""

import argparse
import shutil
import subprocess
from pathlib import Path

from build_release import INCLUDE, REQUIRED_BINARIES, ROOT, build_native

MOD_NAME = "TzeentchRichPresence"
GAME_MODS = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods"
)
DST = GAME_MODS / MOD_NAME
LOAD_ORDER = GAME_MODS / "mod_load_order.txt"


def ensure_load_order():
    """Append the mod to mod_load_order.txt if it isn't already listed."""
    if not LOAD_ORDER.exists():
        print(f"! {LOAD_ORDER.name} not found; add '{MOD_NAME}' to it manually")
        return

    lines = LOAD_ORDER.read_text(encoding="utf-8").splitlines()

    if any(line.strip() == MOD_NAME for line in lines):
        return

    # Note: this file is managed by Vortex, which may rewrite it and drop this
    # entry. If the mod stops loading after a Vortex deploy, re-run this script.
    with LOAD_ORDER.open("a", encoding="utf-8") as f:
        f.write(f"\n{MOD_NAME}\n" if lines and lines[-1].strip() else f"{MOD_NAME}\n")

    print(f"Registered '{MOD_NAME}' in {LOAD_ORDER.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--build", action="store_true", help="rebuild the native DLL before deploying"
    )
    args = parser.parse_args()

    if args.build:
        build_native()

    if not GAME_MODS.exists():
        raise FileNotFoundError(f"Game mods folder not found: {GAME_MODS}")

    missing = [name for name in REQUIRED_BINARIES if not (ROOT / name).exists()]

    if missing:
        # Not fatal: the Lua side pcall-wraps ffi.load and degrades gracefully,
        # so Lua-only iteration still works. But presence won't actually fire.
        print("! Missing native binaries (run with --build): " + ", ".join(missing))

    copied = 0

    locked = []

    for name in INCLUDE:
        path = ROOT / name

        if not path.exists():
            continue

        # Copy file-by-file rather than via copytree so one locked DLL cannot
        # abort the whole deploy -- Lua-only changes must still get through.
        sources = [path] if path.is_file() else [p for p in path.rglob("*") if p.is_file()]

        for source in sorted(sources):
            # Overlay rather than wipe, so an existing .git repo or other local
            # files in the destination are left intact.
            target = DST / source.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)

            try:
                shutil.copy2(source, target)
                copied += 1
            except PermissionError:
                # Darktide holds bin/*.dll open for the whole session; Lua can
                # be reloaded in-game but native code cannot be hot-swapped.
                locked.append(source.relative_to(ROOT).as_posix())

    ensure_load_order()
    print(f"Deployed {copied} files to {DST}")

    if locked:
        print(
            "\n! Could not replace (file in use -- Darktide is running): "
            + ", ".join(locked)
            + "\n  Lua changes are live after a mod reload, but the native DLL"
            "\n  only updates once you fully close the game and re-run this."
        )


if __name__ == "__main__":
    main()
