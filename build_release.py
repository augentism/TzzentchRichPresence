"""Package a distributable mod zip into releases/.

The zip contains a top-level TzeentchRichPresence/ folder (so users extract it
straight into their game's mods/ directory) with only the runtime files --
whitelisted, so dev clutter (tz-native, the 1.3 GB SDK, logs) can never leak in.

Rebuilds the native DLL first by default so a release can never ship a stale
bin/tzrp.dll; pass --skip-build to package whatever is already staged.

Output: releases/TzeentchRichPresence-<hash>.zip where <hash> is the first 5
hex digits of the current commit ("-dirty" appended if the working tree has
uncommitted changes).
"""

import argparse
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).parent
RELEASES = ROOT / "releases"
BUILD_SCRIPT = ROOT / "tz-native" / "build.ps1"

# Runtime files/dirs only; everything else stays out of the zip.
INCLUDE = [
    "TzeentchRichPresence.mod",
    "scripts",
    "bin",
]

# Both must be present in bin/ or the mod cannot load: tzrp.dll is the facade,
# discord_partner_sdk.dll is the Discord SDK it imports by name.
REQUIRED_BINARIES = [
    "bin/tzrp.dll",
    "bin/discord_partner_sdk.dll",
]


def git(*args):
    """Run a git command, returning None if it fails (e.g. no commits yet)."""
    try:
        return subprocess.check_output(
            ("git", "-C", str(ROOT)) + args, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def version_tag():
    tag = git("rev-parse", "--short=5", "HEAD")

    if tag is None:
        # Fresh repo with no commits, or git unavailable.
        return "dev"

    if git("status", "--porcelain"):
        tag += "-dirty"

    return tag


def build_native():
    powershell = shutil.which("pwsh") or shutil.which("powershell")

    if powershell is None:
        raise RuntimeError("Neither pwsh nor powershell found; use --skip-build")

    print(f"Building native runtime via {BUILD_SCRIPT.name}...")
    subprocess.check_call(
        [powershell, "-ExecutionPolicy", "Bypass", "-File", str(BUILD_SCRIPT)]
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="package the existing bin/ instead of rebuilding the native DLL",
    )
    args = parser.parse_args()

    if not args.skip_build:
        build_native()

    missing = [name for name in REQUIRED_BINARIES if not (ROOT / name).exists()]

    if missing:
        raise FileNotFoundError(
            "Missing native binaries: "
            + ", ".join(missing)
            + "\nRun tz-native/build.ps1 (needs CMake + MSVC and the Discord SDK "
            "unpacked into discord_social_sdk/)."
        )

    RELEASES.mkdir(exist_ok=True)
    out = RELEASES / f"TzeentchRichPresence-{version_tag()}.zip"

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for name in INCLUDE:
            path = ROOT / name

            if not path.exists():
                raise FileNotFoundError(f"Missing release file: {path}")

            files = [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file())

            for f in files:
                zf.write(f, Path("TzeentchRichPresence") / f.relative_to(ROOT))

    with zipfile.ZipFile(out) as zf:
        count = len(zf.namelist())

    print(f"Wrote {out} ({out.stat().st_size / 1e6:.1f} MB, {count} files)")


if __name__ == "__main__":
    main()
