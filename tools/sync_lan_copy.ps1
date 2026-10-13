# Copies a runnable Siege Engine (Godot runtime + project + the user's imported game data) to a
# folder another PC can run for LAN testing. Re-run it to refresh the copy after changes.
# Usage: pwsh tools/sync_lan_copy.ps1 -Target <shared folder> [-GodotDir <folder with the Godot exes>]
# Both can also come from the environment (SIEGE_LAN_TARGET, SIEGE_GODOT_DIR), which the git-ignored
# tools/local_settings.ps1 may set (copy tools/local_settings.example.ps1).
param(
    [string]$Target = "",     # folder the other PCs can reach, e.g. a network share
    [string]$GodotDir = ""    # folder holding the Godot 4.6.3 exes
)
$ErrorActionPreference = "Stop"
$LocalSettings = Join-Path $PSScriptRoot "local_settings.ps1"
if (Test-Path $LocalSettings) { . $LocalSettings }
if (-not $Target) { $Target = $env:SIEGE_LAN_TARGET }
if (-not $GodotDir) { $GodotDir = $env:SIEGE_GODOT_DIR }
if (-not $Target) { throw "Set -Target or the SIEGE_LAN_TARGET environment variable (or tools/local_settings.ps1) to the folder to copy to." }
if (-not $GodotDir) { throw "Set -GodotDir or the SIEGE_GODOT_DIR environment variable (or tools/local_settings.ps1) to the Godot 4.6.3 folder." }
$Root = Split-Path -Parent $PSScriptRoot
$GodotExe = "Godot_v4.6.3-stable_win64.exe"
$RobocopyOk = 8   # robocopy exit codes below 8 mean success

function Copy-Tree([string]$From, [string]$To, [string[]]$ExcludeDirs = @()) {
    $robocopyArgs = @($From, $To, "/MIR", "/NFL", "/NDL", "/NJH", "/NP", "/R:1", "/W:1")
    if ($ExcludeDirs.Count -gt 0) { $robocopyArgs += "/XD"; $robocopyArgs += $ExcludeDirs }
    robocopy @robocopyArgs | Out-Null
    if ($LASTEXITCODE -ge $RobocopyOk) { throw "robocopy failed ($LASTEXITCODE): $From -> $To" }
}

# New class_name scripts only resolve after Godot rebuilds its class cache; the copy runs the
# project directly (no editor), so the cache must be fresh before copying.
function Update-ClassCache {
    $console = Join-Path $GodotDir "Godot_v4.6.3-stable_win64_console.exe"
    & $console --headless --audio-driver Dummy --path (Join-Path $Root "game") --import 2>&1 | Out-Null
}

function Write-Launchers([string]$Dir) {
    $play = "@echo off`r`nstart `"`" `"%~dp0godot\$GodotExe`" --path `"%~dp0game`"`r`n"
    Set-Content -Path (Join-Path $Dir "Play Siege Engine.bat") -Value $play -Encoding ascii -NoNewline
    $readme = @"
Siege Engine - LAN test copy
============================
1. Copy this whole folder to the other PC's local disk (running from the network share works but loads slower).
2. Double-click "Play Siege Engine.bat".
3. When Windows Firewall asks, allow Godot on Private networks (LAN games use UDP ports 47700-47701).
4. Host on one PC (Arena / Co-op -> Host), join from the other (Join -> it should appear in the list,
   or type the host PC's IP address).
Both PCs must run the same copy: refresh this folder (tools/sync_lan_copy.ps1 on the dev PC) after updates.
The game data in gamedata\ came from your own discs - keep it on your own machines.
"@
    Set-Content -Path (Join-Path $Dir "README_LAN.txt") -Value $readme -Encoding utf8
}

Update-ClassCache
New-Item -ItemType Directory -Force -Path $Target | Out-Null
Copy-Tree $GodotDir (Join-Path $Target "godot")
Copy-Tree (Join-Path $Root "game") (Join-Path $Target "game")
Copy-Tree (Join-Path $Root "gamedata") (Join-Path $Target "gamedata")
Write-Launchers $Target
Write-Output "LAN copy ready: $Target"
