"""Extract mission preview images from a limn asset dump into map_images/.

The limn extraction in ../DTAssets was made without a dictionary, so every file
is named <murmur64a-of-resource-path>.<ext> rather than by path. The game's
mission templates declare the resource paths (texture_big/medium/small), so we
hash those forward and match, then decode the BC-compressed DDS to PNG.

Output (both are gitignored -- they are game assets, not mod content):
    map_images/<mission>.png          native resolution, full aspect
    map_images/square/<mission>.png   1024x1024 centre-crop, ready to upload

Discord art assets want square-ish images between 512x512 and 1024x1024, and
the large-image slot renders square, so upload the square/ versions. Key them
by the mission id (the filename stem) -- that is what presence/assets.lua maps.

Usage:  python extract_map_images.py [--size big|medium|small]
"""

import argparse
import glob
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).parent
ASSETS = ROOT.parent / "DTAssets" / "out"
TEMPLATES = ROOT.parent / "Darktide-Source-Code" / "scripts" / "settings" / "mission" / "templates"
OUT = ROOT / "map_images"
SQUARE = OUT / "square"
SQUARE_SIZE = 1024


def murmur64a(key: bytes, seed: int = 0) -> int:
    """Bitsquid resource-name hash: MurmurHash64A, seed 0."""
    m = 0xC6A4A7935BD1E995
    r = 47
    mask = 0xFFFFFFFFFFFFFFFF
    h = (seed ^ ((len(key) * m) & mask)) & mask

    body = len(key) - len(key) % 8
    for i in range(0, body, 8):
        k = int.from_bytes(key[i:i + 8], "little")
        k = (k * m) & mask
        k ^= k >> r
        k = (k * m) & mask
        h ^= k
        h = (h * m) & mask

    left = len(key) & 7
    if left:
        for j in range(left - 1, -1, -1):
            h ^= key[body + j] << (8 * j)
        h = (h * m) & mask

    h ^= h >> r
    h = (h * m) & mask
    h ^= h >> r
    return h


def _block(text, start):
    """Slice from an opening brace to its match, so a table never bleeds into
    the next one. A fixed-size window silently attributes a neighbour's texture
    to the wrong mission."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i]
    return text[start:]


def mission_textures():
    """mission id -> {texture_big/medium/small: resource path}.

    Only real missions: the template files also contain settings tables
    (ammo, pickup_settings, vo_events...) that are not missions at all, so we
    require a mission_name loc id to be declared in the same table.
    """
    out = {}
    for path in sorted(glob.glob(str(TEMPLATES / "*.lua"))):
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"^[\t ]*([a-z][a-z0-9_]*) = \{", text, re.M):
            block = _block(text, m.end() - 1)

            if not re.search(r'mission_name = "loc_mission_name_', block):
                continue

            found = {
                size: tm.group(1)
                for size in ("texture_big", "texture_medium", "texture_small")
                for tm in [re.search(rf'{size} = "([^"]+)"', block)]
                if tm
            }
            if found:
                out.setdefault(m.group(1), found)
    return out


def to_square(image, size):
    """Centre-crop to square, then resize. Map previews are ~2:1, and the
    Discord large-image slot is square, so cropping beats squashing."""
    from PIL import Image

    w, h = image.size
    side = min(w, h)
    image = image.crop(((w - side) // 2, (h - side) // 2,
                        (w + side) // 2, (h + side) // 2))
    return image.resize((size, size), Image.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", default="big", choices=["big", "medium", "small"],
                        help="which declared texture to extract (default: big)")
    args = parser.parse_args()

    try:
        from PIL import Image
    except ImportError:
        sys.exit("Pillow is required:  pip install Pillow")

    if not ASSETS.is_dir():
        sys.exit(f"Asset dump not found: {ASSETS}")

    available = set(os.listdir(ASSETS))
    OUT.mkdir(exist_ok=True)
    SQUARE.mkdir(exist_ok=True)

    key = f"texture_{args.size}"
    found, missing, failed = [], [], []

    for mission, sizes in sorted(mission_textures().items()):
        resource = sizes.get(key)
        if not resource:
            continue

        name = f"{murmur64a(resource.encode()):016x}"
        source = next((ASSETS / f"{name}.{ext}"
                       for ext in ("dds", "texture", "png")
                       if f"{name}.{ext}" in available), None)
        if source is None:
            missing.append(mission)
            continue

        try:
            with Image.open(source) as image:
                rgb = image.convert("RGB")
                rgb.save(OUT / f"{mission}.png")
                to_square(rgb, SQUARE_SIZE).save(SQUARE / f"{mission}.png")
                found.append((mission, rgb.size))
        except Exception as exc:                      # noqa: BLE001
            failed.append((mission, str(exc)))

    for mission, size in found:
        print(f"  {mission:24s} {size[0]}x{size[1]}")
    print(f"\n{len(found)} extracted -> {OUT}")
    if missing:
        print(f"{len(missing)} not in the dump: {', '.join(missing)}")
    if failed:
        print(f"{len(failed)} failed to decode:")
        for mission, exc in failed:
            print(f"  {mission}: {exc}")


if __name__ == "__main__":
    main()
