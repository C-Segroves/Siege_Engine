# Personal settings for the PowerShell tools (tools/sync_lan_copy.ps1, tools/package_release.ps1).
# Copy this file to tools/local_settings.ps1, which is git-ignored, and fill in your own paths.
# Never commit the copy: it holds machine-specific paths.
$env:SIEGE_LAN_TARGET = ""   # sync_lan_copy.ps1: folder the other LAN PCs can reach, e.g. \server\share\Siege_Engine
$env:SIEGE_GODOT_DIR = ""    # sync_lan_copy.ps1: folder holding the Godot 4.6.3 exes
$env:GODOT = ""              # package_release.ps1 and the Python test runners: path to the Godot 4.6 console exe
$env:SIEGE_ISO_DIR = ""      # Python test runners: folder holding your own disc images (.iso)
