"""Extract class icons from a limn asset dump into class_icons/.

Companion to extract_map_images.py; see that file for how the hash-named limn
extraction works. Two things are specific to class icons:

  * The icons are declared as *materials*, not textures. A .material references
    its texture by murmur64 hash, so we read the material and follow the ref.
    The plain "icons/classes/<c>" art is only 348x348 -- below Discord's 512
    minimum -- but "icons/classes/large/<c>" is 1920x1920, so we use that and
    downscale rather than upscaling anything.

  * The source art is white-on-transparent. Discord renders the small image as
    a circle over the card background, which is white in light theme, so a bare
    transparent icon disappears for anyone not on dark theme. We composite onto
    a dark disc by default; pass --transparent to skip that.

Output:  class_icons/<archetype>.png   1024x1024, ready to upload

Upload these keyed by archetype name (veteran, zealot, psyker, ogryn, adamant,
broker, cryptic) -- that is what presence/assets.lua looks up.

Usage:  python extract_class_icons.py [--transparent] [--size 1024]
"""

import argparse
import os
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).parent
ASSETS = ROOT.parent / "DTAssets" / "out"
OUT = ROOT / "class_icons"

ARCHETYPES = ["veteran", "zealot", "psyker", "ogryn", "adamant", "broker", "cryptic"]
SOURCE = "content/ui/materials/icons/classes/large/{archetype}"

BACKGROUND = (30, 32, 36)
# A centred square of side s fits inside the inscribed circle when s <= 0.707*d.
# 0.62 leaves a little breathing room inside Discord's circular crop.
ICON_FRACTION = 0.62


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


def texture_for(path, present):
    """Direct .dds at that path, else the texture the .material points at."""
    name = f"{murmur64a(path.encode()):016x}"

    if f"{name}.dds" in present:
        return ASSETS / f"{name}.dds"

    material = ASSETS / f"{name}.material"
    if not material.is_file():
        return None

    blob = material.read_bytes()
    for i in range(max(0, len(blob) - 8)):
        candidate = f"{struct.unpack_from('<Q', blob, i)[0]:016x}.dds"
        if candidate in present:
            return ASSETS / candidate
    return None


def render(image, size, transparent):
    """Normalise by the icon's alpha bounds so every class ends up the same
    visual weight, then centre it on the canvas."""
    from PIL import Image

    bbox = image.getbbox()
    if bbox:
        image = image.crop(bbox)

    target = int(size * ICON_FRACTION)
    scale = min(target / image.width, target / image.height)
    icon = image.resize((max(1, round(image.width * scale)),
                         max(1, round(image.height * scale))), Image.LANCZOS)

    if transparent:
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    else:
        canvas = Image.new("RGBA", (size, size), BACKGROUND + (255,))

    canvas.paste(icon, ((size - icon.width) // 2, (size - icon.height) // 2), icon)
    return canvas


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transparent", action="store_true",
                        help="no dark disc behind the icon (invisible on light theme)")
    parser.add_argument("--size", type=int, default=1024)
    args = parser.parse_args()

    try:
        from PIL import Image
    except ImportError:
        sys.exit("Pillow is required:  pip install Pillow")

    if not ASSETS.is_dir():
        sys.exit(f"Asset dump not found: {ASSETS}")

    present = set(os.listdir(ASSETS))
    OUT.mkdir(exist_ok=True)

    missing = []
    for archetype in ARCHETYPES:
        source = texture_for(SOURCE.format(archetype=archetype), present)
        if source is None:
            missing.append(archetype)
            continue

        with Image.open(source) as image:
            native = image.size
            rendered = render(image.convert("RGBA"), args.size, args.transparent)
            rendered.save(OUT / f"{archetype}.png")

        print(f"  {archetype:10s} {native[0]}x{native[1]} -> {args.size}x{args.size}")

    print(f"\n{len(ARCHETYPES) - len(missing)} icons -> {OUT}")
    if missing:
        print(f"not found in the dump: {', '.join(missing)}")


if __name__ == "__main__":
    main()
