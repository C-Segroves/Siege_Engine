# Menu map

This file says where every app screen's buttons go, and where Back, Esc (`menu_back`) and pad B take you.
Esc and pad B always press the screen's Back button (ScreenFrame).

## How Back works

There is one navigation stack per router: `ScreenRouter.go / back / replace / go_root` in `engine/ui/screen_router.gd`.
- **go:** opening a page remembers the current one.
- **back:** returns to the remembered page.
- **replace:** a page that refreshes itself (Saves after a delete, Options after a data-folder change), or a flow
  step that must not be returned to (Debriefing → End). It is not remembered.
- **Main menu:** the **library**, the app's front door. The one exception is the original Earthsiege shell's
  MULTIPLAYER entry, which opens the launcher's own menu as its main menu.
  - `Launcher.go_main_menu` goes there.
  - Back with nothing remembered also goes there (`Launcher.back_from_root`).

So Back always returns to the screen you came from. From any page the library opened (Arena / versus, Host, Join,
campaign pages, the launcher menu) that is the library.

Tests: `tests/ui_nav_check.gd` covers every path below (`_check_back_paths`, `_check_launcher_routes`,
`_check_library_routes`, the killed prompt). `tests/fix_d_check.gd` covers the shape viewer.

## Library (`library.tscn`): the main menu

| Screen | Buttons | Back / Esc / pad B |
|---|---|---|
| Home | Import disc, Remove pack, Add soundtrack folder, soundtrack → Jukebox, Continue campaign → Briefing, New campaign → New campaign, Load game → Saves, Host LAN game → Host, Join LAN game → Browser, Co-op missions (LAN) → Host (co-op), Skirmish, training, extraction → launcher Menu, Metaltech: Earthsiege → original shell, Shape viewer, Options, Tested game versions → Versions; primary: Arena / versus → Host (versus) | "Quit" asks first |
| Jukebox | Stop / play tracks | Home |
| Options | settings | Home |
| Versions | each installed game's detected release (tested / untested), the tested-versions table; also from Options (Tested game versions) | the page it came from |
| Shape viewer (`tools/shape_viewer.tscn`) | "Back to library" button | Library |

## Launcher (`launcher.tscn`)

| Screen | Buttons (→ target) | Back / Esc / pad B |
|---|---|---|
| Menu | Pilot name, Continue campaign → Briefing, New campaign, Load game → Saves, Tribes training → Training, Extraction raid → Extraction, Host LAN game → Host, Join LAN game → Browser, Play intro, Shape viewer, Library, Options, Quit (asks); primary: Skirmish / armory → Armory | "Back to library" (or "Back to original shell") |
| Armory | Extraction raid instead → Extraction; primary: Start skirmish → battle | the page it came from (Menu) |
| Host | the match settings, team list (Assign all, Shuffle teams); primary: Create lobby → Lobby | the page it came from (Menu, or the library) |
| Browser | a server → Lobby; primary: Join address → Lobby | the page it came from (Menu, or the library) |
| Lobby | name, Herc, soldier, team pickers, Stash, shop and loadout → Extraction; primary: host Start match / Start mission (disabled until everyone is ready and on a team), client Ready / Not ready | "Leave" ends the session and returns to the page it came from (Host / Browser). After a battle the lobby is the first page, so Leave goes to the main menu |
| Extraction (from the lobby) | stash / shop / kit buttons; primary: Done → back to the Lobby | "Back to lobby" |
| Extraction (from the menu) | stash / shop / kit buttons; primary: Start raid → battle | the page it came from |
| Training | mission list; primary: Start training → battle | the page it came from |
| New campaign | pilot name, campaign choice; primary: Start campaign → Briefing | the page it came from |
| Saves (load) | Delete (refreshes in place); primary: New campaign → New campaign; a save → Briefing | the page it came from |
| Saves (save) | Delete; primary: Save | the page it came from (Briefing / Saga choice) |
| Options | settings | the page it came from |
| Briefing | Save game → Saves, Hangar → Hangar, Herc choice; primary: Launch mission → battle | "Save and quit to menu" → main menu |
| Hangar | Repair, Repair all, Build, Scrap | "Back to …" → the page that opened it (Briefing / Lobby) |
| Saga choice | side choice → Briefing, Save game → Saves | "Save and quit to menu" → main menu |
| Debriefing | primary: Continue → Briefing / Lobby / End (replaced, not remembered), or Replay mission | "Main menu" → main menu |
| End | primary: Main menu, or Replay mission (lost campaign) | "Back" / "Main menu" → main menu |
| Killed in action | primary: Replay mission → Briefing | "Quit to main menu" → main menu |

## In battle

| Screen | Buttons | Back / Esc / pad B |
|---|---|---|
| Battle menu (`menu_pause`) | Resume, Options → Options, Abort mission / Leave match, Quit to desktop | Resume |
| Options (over the battle) | settings | Battle menu |
| Results | primary: Continue → the front end page (lobby / debriefing / main menu), Rematch | Continue |
