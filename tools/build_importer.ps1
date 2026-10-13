# Freezes the disc importer (tools/siege_import.py + every converter it runs) into
#   dist/siege-importer/siege-importer.exe   (PyInstaller one-folder console build)
# so the Siege Engine app can import discs on machines without Python.
#
#   powershell -ExecutionPolicy Bypass -File tools\build_importer.ps1 [-Python python] [-InstallDeps] [-Test <iso>]
#              [-FfmpegBuild <dir>] [-Dist <dir>] [-Build <dir>]
#
# -InstallDeps  pip-installs tools/requirements.txt first.
# -Test <iso>   runs the frozen exe's `identify` on that disc image afterwards.
# -FfmpegBuild  the out folder of tools/ffmpeg/build_ffmpeg.sh (default build/ffmpeg), made by
#                   wsl bash tools/ffmpeg/build_ffmpeg.sh build/ffmpeg     (needs mingw-w64, nasm, pkg-config, make)
#               or  docker run --rm -v "${PWD}:/src" -w /src ubuntu:24.04 bash tools/ffmpeg/build_ffmpeg.sh --install-deps build/ffmpeg
#               Its LGPL ffmpeg.exe is copied to siege-importer/ffmpeg/ffmpeg.exe; imageio-ffmpeg's GPL binary is
#               never bundled.
# -Dist, -Build output folder (default dist/) and PyInstaller work folder (default build/).
param(
    [string]$Python = "python",
    [switch]$InstallDeps,
    [string]$Test = "",
    [string]$FfmpegBuild = "",
    [string]$Dist = "",
    [string]$Build = ""
)
$ErrorActionPreference = "Continue"   # native tools log to stderr; exit codes are checked instead
$Root = Split-Path -Parent $PSScriptRoot
$Tools = Join-Path $Root "tools"
if (-not $Dist) { $Dist = Join-Path $Root "dist" }
if (-not $Build) { $Build = Join-Path $Root "build" }
if (-not $FfmpegBuild) { $FfmpegBuild = Join-Path $Root "build\ffmpeg" }
$Ffmpeg = Join-Path $FfmpegBuild "ffmpeg"
foreach ($f in @("ffmpeg.exe", "BUILD.txt", "licenses")) {
    if (-not (Test-Path (Join-Path $Ffmpeg $f))) {
        throw "No LGPL ffmpeg build at $Ffmpeg (missing $f). Build it with tools/ffmpeg/build_ffmpeg.sh (see this script's header) or pass -FfmpegBuild <dir>."
    }
}

if ($InstallDeps) {
    & $Python -m pip install -r (Join-Path $Tools "requirements.txt")
    if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
}
& $Python -c "import PyInstaller, pycdlib, numpy, PIL" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Missing build dependencies. Run: $Python -m pip install -r tools\requirements.txt  (or pass -InstallDeps)"
}
& $Python -c "import pyopl" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Warning "pyopl not installed: the frozen importer will skip Earthsiege's FM music." }

# Every converter is run by name (runpy), so PyInstaller cannot see them: list them as hidden imports.
# Research-only scripts (previews, disassembly helpers needing capstone, the old dev pipeline) are left out.
$skip = @("siege_import", "import_disc", "preview", "preview_gamedata", "scale_lineup", "scale_lineup2",
          "exe", "re_util", "re_fields", "collect_licenses", "third_party_sources")
$hidden = @()
foreach ($f in Get-ChildItem (Join-Path $Tools "*.py")) {
    if ($skip -notcontains $f.BaseName) { $hidden += @("--hidden-import", $f.BaseName) }
}

$sep = [IO.Path]::PathSeparator
$piArgs = @(
    "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--console",
    "--name", "siege-importer",
    "--distpath", $Dist, "--workpath", (Join-Path $Build "pyinstaller"), "--specpath", $Build,
    "--paths", $Tools,
    "--collect-submodules", "siege_games",
    "--hidden-import", "pyopl",
    "--add-data", ((Join-Path $Tools "pack_meta") + $sep + "pack_meta"),
    # imageio-ffmpeg carries a GPL ffmpeg build: the importer runs the bundled LGPL one (video.ffmpeg_exe)
    "--exclude-module", "imageio_ffmpeg",
    "--exclude-module", "matplotlib", "--exclude-module", "tkinter", "--exclude-module", "capstone",
    "--exclude-module", "scipy", "--exclude-module", "pandas", "--exclude-module", "IPython",
    # pulled in only through setuptools/pkg_resources and pywin32 hooks; the converters need none of them
    "--exclude-module", "setuptools", "--exclude-module", "pkg_resources", "--exclude-module", "win32com",
    "--exclude-module", "pythoncom", "--exclude-module", "pywin", "--exclude-module", "win32ui",
    "--exclude-module", "numpy.distutils"
) + $hidden + @((Join-Path $Tools "siege_import.py"))

Write-Host "Building dist\siege-importer ..."
& $Python @piArgs
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }

$exe = Join-Path $Dist "siege-importer\siege-importer.exe"
if (-not (Test-Path $exe)) { throw "build produced no $exe" }
# the LGPL ffmpeg next to the exe (video.ffmpeg_exe finds it there); its BUILD.txt and license texts in licenses\ffmpeg
$ImporterDir = Join-Path $Dist "siege-importer"
New-Item -ItemType Directory -Force (Join-Path $ImporterDir "ffmpeg") | Out-Null
Copy-Item -Force (Join-Path $Ffmpeg "ffmpeg.exe") (Join-Path $ImporterDir "ffmpeg\ffmpeg.exe")
$FfmpegLicenses = Join-Path $ImporterDir "licenses\ffmpeg"
New-Item -ItemType Directory -Force $FfmpegLicenses | Out-Null
Copy-Item -Force (Join-Path $Ffmpeg "BUILD.txt") $FfmpegLicenses
Copy-Item -Force (Join-Path $Ffmpeg "licenses\*") $FfmpegLicenses
# GPL / LGPL / BSD notices: the license texts of Python and every bundled package go into
# dist/siege-importer/licenses, THIRD_PARTY_NOTICES.md next to the exe (tools/collect_licenses.py, which also fails
# unless the bundled ffmpeg is the LGPL build and the only ffmpeg in the folder).
& $Python (Join-Path $Tools "collect_licenses.py") (Join-Path $Dist "siege-importer")
if ($LASTEXITCODE -ne 0) { throw "collecting the third-party license texts failed" }

$size = (Get-ChildItem (Join-Path $Dist "siege-importer") -Recurse | Measure-Object Length -Sum).Sum
Write-Host ("Built {0} ({1:N0} MB folder)" -f $exe, ($size / 1MB))
& $exe games
if ($Test) { & $exe identify $Test }
