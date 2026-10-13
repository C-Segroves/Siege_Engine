# Builds a release folder that contains code only (no game data):
#
#   dist/SiegeEngine/
#     SiegeEngine.exe                 Godot app (game/, preset "Windows Desktop" in game/export_presets.cfg)
#     SiegeEngine.console.exe         console wrapper (logs)
#     siege-importer/siege-importer.exe + _internal/   frozen disc importer (tools/build_importer.ps1)
#
# game/engine/importer.gd looks for <exe dir>/siege-importer/siege-importer.exe, so players import their own
# discs from inside the app; packs go to %APPDATA%\Godot\app_userdata\Siege Engine\packs.
#
#   powershell -ExecutionPolicy Bypass -File tools\package_release.ps1 [-Godot <path to Godot 4.6 console exe>]
#              [-RebuildImporter] [-Zip] [-Python python] [-Version <v>] [-SourceUrl <release page url>]
#              [-FfmpegBuild <dir>] [-Dist <dir>] [-Build <dir>]
#
# -Zip writes the two release assets next to the folder:
#   SiegeEngine-<v>-win64.zip            the folder above
#   third-party-sources-<v>.zip          Corresponding Source of the GPL / LGPL parts (tools/third_party_sources.py):
#                                        FFmpeg + libogg/libvorbis/libtheora archives and build scripts, the PyOPL and
#                                        pycdlib sdists, this repository at HEAD, SOURCES.md
# Both must be attached to the same release: licenses\SOURCE-CODE.txt in the zip points to the second one
# (-SourceUrl: the release page, written into that note). -Version defaults to today's date (yyyyMMdd).
# -FfmpegBuild is the out folder of tools/ffmpeg/build_ffmpeg.sh (default build\ffmpeg; see build_importer.ps1).
#
# Needs the Godot export templates matching the editor version (see the message printed when they are missing).
param(
    [string]$Godot = "",
    [switch]$RebuildImporter,
    [switch]$Zip,
    [string]$Python = "python",
    [string]$Version = "",
    [string]$SourceUrl = "",
    [string]$FfmpegBuild = "",
    [string]$Dist = "",
    [string]$Build = ""
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$LocalSettings = Join-Path $PSScriptRoot "local_settings.ps1"   # git-ignored; may set $env:GODOT
if (Test-Path $LocalSettings) { . $LocalSettings }
if (-not $Dist) { $Dist = Join-Path $Root "dist" }
if (-not $Build) { $Build = Join-Path $Root "build" }
if (-not $FfmpegBuild) { $FfmpegBuild = Join-Path $Root "build\ffmpeg" }
if (-not $Version) { $Version = Get-Date -Format "yyyyMMdd" }
$Out = Join-Path $Dist "SiegeEngine"
$Importer = Join-Path $Dist "siege-importer"

# ---------------------------------------------------------------- find Godot
function Find-Godot {
    if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }
    foreach ($n in @("godot", "godot4", "Godot_v4.6-stable_win64_console", "Godot_v4.6.3-stable_win64_console")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $cands = Get-ChildItem -Path @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:LOCALAPPDATA\Programs",
                                    "$env:ProgramFiles") -Recurse -Depth 2 -Filter "Godot_v4.6*_win64_console.exe" -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending
    if ($cands) { return $cands[0].FullName }
    return $null
}
if (-not $Godot) { $Godot = Find-Godot }
if (-not $Godot -or -not (Test-Path $Godot)) {
    Write-Error "Godot 4.6 not found. Pass -Godot <path to Godot_v4.6.x-stable_win64_console.exe> or set `$env:GODOT."
    exit 1
}

# ---------------------------------------------------------------- export templates present?
$ver = (& $Godot --version 2>$null | Select-Object -Last 1).Trim()          # e.g. 4.6.3.stable.official.abcdef
$parts = $ver.Split(".")
$tplVer = if ($parts.Length -ge 4 -and $parts[3] -match "^(stable|rc|beta|dev)") { ($parts[0..3] -join ".") } else { ($parts[0..2] -join ".") }
if ($parts[2] -notmatch "^\d+$") { $tplVer = ($parts[0..2] -join ".") }        # "4.6.stable" style
$tplDir = Join-Path $env:APPDATA "Godot\export_templates\$tplVer"
if (-not (Test-Path (Join-Path $tplDir "windows_release_x86_64.exe"))) {
    Write-Host ""
    Write-Host "Godot export templates for $tplVer are not installed ($tplDir)." -ForegroundColor Yellow
    Write-Host "Install them once, either:"
    Write-Host "  * in the editor: Editor > Manage Export Templates > Download and Install, or"
    Write-Host "  * download Godot_v$($tplVer.Replace('.stable','-stable'))_export_templates.tpz from https://godotengine.org/download/archive/"
    Write-Host "    (or github.com/godotengine/godot/releases), then Editor > Manage Export Templates > Install From File."
    Write-Host "    (A .tpz is a zip: its templates/ folder can also be extracted to $tplDir)"
    exit 2
}

# ---------------------------------------------------------------- importer
if ($RebuildImporter -or -not (Test-Path (Join-Path $Importer "siege-importer.exe"))) {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "build_importer.ps1") -Python $Python `
        -FfmpegBuild $FfmpegBuild -Dist $Dist -Build $Build
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Importer "siege-importer.exe"))) { Write-Error "importer build failed"; exit 1 }
}

# ---------------------------------------------------------------- export the app
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $Out | Out-Null
$exe = Join-Path $Out "SiegeEngine.exe"
Write-Host "Exporting the Godot app with $Godot ..."
& $Godot --headless --path (Join-Path $Root "game") --export-release "Windows Desktop" $exe
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { Write-Error "Godot export failed"; exit 1 }

# ---------------------------------------------------------------- importer next to the exe
Copy-Item -Recurse -Force $Importer (Join-Path $Out "siege-importer")

# ---------------------------------------------------------------- licenses (THIRD_PARTY_NOTICES.md)
# Godot's own license and its third-party notices come from the Godot build itself (tools/godot_licenses.gd);
# the importer's (Python, packages, ffmpeg) are in siege-importer/licenses (tools/build_importer.ps1).
$Licenses = Join-Path $Out "licenses"
New-Item -ItemType Directory -Force $Licenses | Out-Null
Copy-Item -Force (Join-Path $Root "THIRD_PARTY_NOTICES.md") (Join-Path $Out "THIRD_PARTY_NOTICES.md")
Copy-Item -Force (Join-Path $Root "LICENSE") (Join-Path $Licenses "SiegeEngine-LICENSE.txt")
$EmptyProject = Join-Path $Build "godot-licenses"
New-Item -ItemType Directory -Force $EmptyProject | Out-Null
Set-Content -Path (Join-Path $EmptyProject "project.godot") -Value "" -Encoding ascii
& $Godot --headless --audio-driver Dummy --path $EmptyProject --script (Join-Path $PSScriptRoot "godot_licenses.gd") -- $Licenses
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $Licenses "Godot-THIRD_PARTY.txt"))) {
    Write-Error "writing the Godot license texts failed"; exit 1
}
$ImporterLicenses = Join-Path $Out "siege-importer\licenses"
if (-not (Test-Path (Join-Path $ImporterLicenses "ffmpeg\BUILD.txt"))) {
    Write-Error "the importer has no licenses folder or no LGPL ffmpeg: rebuild it (-RebuildImporter)"; exit 1
}
# the full GPL-3.0 (PyOPL) and LGPL-2.1 (FFmpeg) texts at the top as well, next to the note saying where their source is
$gpl = Get-ChildItem -Path $ImporterLicenses -Recurse -Filter "COPYING" | Where-Object { $_.Directory.Name -like "PyOPL-*" } | Select-Object -First 1
if ($gpl) { Copy-Item -Force $gpl.FullName (Join-Path $Licenses "GPL-3.0.txt") }
Copy-Item -Force (Join-Path $ImporterLicenses "ffmpeg\FFmpeg-COPYING.LGPLv2.1.txt") (Join-Path $Licenses "LGPL-2.1.txt")
$urlArgs = if ($SourceUrl) { @("--url", $SourceUrl) } else { @() }   # PowerShell 5 drops empty arguments
foreach ($note in @((Join-Path $Licenses "SOURCE-CODE.txt"), (Join-Path $ImporterLicenses "SOURCE-CODE.txt"))) {
    & $Python (Join-Path $PSScriptRoot "third_party_sources.py") notice --version $Version @urlArgs --out $note
    if ($LASTEXITCODE -ne 0) { Write-Error "writing $note failed"; exit 1 }
}
@"
Siege Engine
============
Start SiegeEngine.exe and use "Import disc (.iso)..." (or drag .iso files onto the window) to convert your own
original Dynamix discs: Metaltech: Earthsiege, Metaltech: Battledrome, Earthsiege 2, Starsiege: Tribes,
Starsiege, Tribes 2. No game content is included; imported packs are stored in
%APPDATA%\Godot\app_userdata\Siege Engine\packs.

Licenses: the Siege Engine code is MIT licensed (licenses\SiegeEngine-LICENSE.txt). This folder also contains
third-party components under their own licenses: the importer's OPL emulator (PyOPL / DOSBox, GPL-3.0) and
ffmpeg (LGPL-2.1, a separate program in siege-importer\ffmpeg\). See THIRD_PARTY_NOTICES.md, licenses\ and
siege-importer\licenses\. Where to get their source code: licenses\SOURCE-CODE.txt.
"@ | Set-Content -Encoding UTF8 (Join-Path $Out "README.txt")

$size = (Get-ChildItem $Out -Recurse | Measure-Object Length -Sum).Sum
Write-Host ("Release folder: {0} ({1:N0} MB)" -f $Out, ($size / 1MB))
if ($Zip) {
    $z = Join-Path $Dist ("SiegeEngine-{0}-win64.zip" -f $Version)
    if (Test-Path $z) { Remove-Item $z }
    Compress-Archive -Path (Join-Path $Out "*") -DestinationPath $z
    Write-Host "Zip: $z"
    # the Corresponding Source of the GPL / LGPL parts: attach it to the same release as the zip above
    $src = Join-Path $Dist ("third-party-sources-{0}.zip" -f $Version)
    & $Python (Join-Path $PSScriptRoot "third_party_sources.py") bundle --version $Version @urlArgs `
        --ffmpeg-build $FfmpegBuild --out $src
    if ($LASTEXITCODE -ne 0) { Write-Error "building $src failed"; exit 1 }
}
