# Builds tzrp.dll and stages it (with the Discord SDK runtime) into ../bin.
# Requires MSVC (Visual Studio Build Tools) and CMake on PATH.

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $root "build"
$sdk = Join-Path $root "..\discord_social_sdk"
$bin = Join-Path $root "..\bin"

cmake -S $root -B $build -A x64
cmake --build $build --config Release

if (-not (Test-Path $bin)) { New-Item -ItemType Directory $bin | Out-Null }

Copy-Item (Join-Path $build "Release\tzrp.dll") $bin -Force
# tzrp.dll imports these by name; they must sit next to it and be loaded
# explicitly by path first (Windows will not search the mod folder for them).
Copy-Item (Join-Path $sdk "bin\release\discord_partner_sdk.dll") $bin -Force

Write-Host "staged to $bin"

# dumpbin only exists on PATH inside a developer prompt; find it via vswhere so
# the export check works from a plain shell too.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
	$vs = & $vswhere -latest -products * -property installationPath
	$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC" -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
		Where-Object { $_.FullName -like "*Hostx64\x64*" } | Select-Object -First 1
	if ($dumpbin) {
		& $dumpbin.FullName /exports (Join-Path $bin "tzrp.dll") | Select-String "TZRP_"
	}
}
