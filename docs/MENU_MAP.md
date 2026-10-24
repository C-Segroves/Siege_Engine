# Menu map

This file says where every app screen's buttons go, and where Back, Esc (`menu_back`) and pad B take you.
Esc and pad B always press the screen's Back button (ScreenFrame).

## How Back works

There is one navigation stack per router: `ScreenRouter.go / back / replace / go_root` in `engine/ui/screen_router.gd`.
- **go:** opening a page remembers the current one.
- **back:** returns to the remembered page.
- **replace:** a page that refreshes itself (Saves after a delete, Options after a data-folder change), or a flow
  step that must not be returned to (Debriefing → End). It is not remembered.
- **Main menu:** the **library home**, the app's front door (there is no other menu page). The one exception is the
  original Earthsiege shell's MULTIPLAYER entry, whose "main menu" is the LAN browser (with a Host LAN game button).
  - `Launcher.go_main_menu` goes there.
  - Back with nothing remembered also goes there (`Launcher.back_from_root`).
- **Leaving a match** (any mode, solo or LAN, host or client; results Continue; the battle menu's Leave / Quit to main
  menu) returns to the library home on its **Play** tab (`Session.show_play_tab`). A launcher opened after a match
  with no session left goes there at once; an open LAN or offline session returns to its lobby instead.

So Back always returns to the screen you came from. From any page the library opened (Host, Join,
campaign pages) that is the library home.

Tests: `tests/ui_nav_check.gd` covers every path below (`_check_back_paths`, `_check_launcher_routes`,
`_check_library_routes`, the killed prompt). `tests/fix_d_check.gd` covers the shape viewer.

## Library (`library.tscn`): the main menu

| Screen | Buttons | Back / Esc / pad B |
|---|---|---|
Home has three tabs (`TabPages`, pad LB / RB): **Play**, **Your library**, **Options & tools**. Every mode (skirmish, co-op,
co-op campaign, extraction, Tribes training) is picked in the host lobby's Game Options.

| Screen | Buttons | Back / Esc / pad B |
|---|---|---|
| Home, Play tab | Continue campaign → Lobby (campaign), New campaign → New campaign, Load game → Saves, Host LAN game → Lobby, Host online game → Lobby (also listed on the master server; disabled until a master address is set), Join LAN game → Browser; primary: Host LAN game | "Quit" asks first |
| Home, Your library | Import disc, Remove pack, content toggles, Add soundtrack folder, soundtrack → Jukebox | same |
| Home, Options & tools | Play intro, Shape viewer, **Run dedicated server...** → the Run dedicated server sheet (start / stop a headless server on this PC; Close keeps it running), Options (pilot name, Operator Setup, **Online**: master server address), Tested game versions → Versions | same |
| Jukebox | Stop / play tracks | Home |
| Options | settings, Operator Setup (the active character slot) | Home |
| Versions | each installed game's detected release (tested / untested), the tested-versions table; also from Options (Tested game versions) | the page it came from |
| Shape viewer (`tools/shape_viewer.tscn`) | "Back to library" button | Library |

## Launcher (`launcher.tscn`)

The launcher has no menu page of its own: it opens on the page the library asked for (`start_mode`: lobby, Browser, a
campaign page), or, after a match with no open session, goes straight back to the library home.
Every game is set up in the one standard **Lobby** (`LobbyScreen`, docs/design/lobby_loadout_economy.md section 5), hosted over
LAN or, for skirmish, the single player campaign and the solo raid, as an offline session (`Launcher.open_lobby(kind, solo)`).

| Screen | Buttons (→ target) | Back / Esc / pad B |
|---|---|---|
| Browser | sections LAN games (broadcast, auto-discovered), Online games (the master server's list, with Refresh and ping), Server matches (a server's page address), Join by address (IP, IP:port, host name, ws:// or https://; Check shows the server's name, players and ping; recent addresses); a server → Lobby; primary: Join address → Lobby; under the original shell's MULTIPLAYER entry also Host LAN game and Host online game → Lobby | the page it came from (the library home, or the original shell) |
| Lobby | Game Options (the host edits: one **Game mode** picker lists every versus mode, co-op, co-op campaign, extraction raid and the training pages, with unavailable modes disabled and the reason shown; the Map list shows only the maps that mode can be played on; Save game and Hangar in a campaign), Operator Setup, the squad cards, chat, goals or the campaign briefing; primary: host Start match / Start mission (disabled until everyone is ready and on a team), client Ready / Not ready | "Leave" ends the session and returns to the page it came from (Browser / library home). A single player campaign lobby saves and goes to the main menu. After a battle the lobby is the first page, so Leave goes to the main menu |
| Training | mission list; primary: Start training → battle | the page it came from |
| New campaign | pilot name, campaign choice; primary: Start campaign → Lobby (campaign) | the page it came from |
| Saves (load) | Delete (refreshes in place); primary: New campaign → New campaign; a save → Lobby (campaign) | the page it came from |
| Saves (save) | Delete; primary: Save | the page it came from (Lobby / Saga choice) |
| Options | settings | the page it came from |
| Hangar | Repair, Repair all, Build, Scrap | "Back to …" → the page that opened it (Lobby) |
| Saga choice | side choice → Lobby (campaign), Save game → Saves | "Save and quit to menu" → main menu |
| Debriefing | primary: Continue → Lobby / End (replaced, not remembered), or Replay mission | "Main menu" → main menu |
| End | primary: Main menu, or Replay mission (lost campaign) | "Back" / "Main menu" → main menu |
| Killed in action | primary: Replay mission → battle (the lobby when the launch was not recorded) | "Quit to main menu" → main menu |

## In battle

| Screen | Buttons | Back / Esc / pad B |
|---|---|---|
| Battle menu (`menu_pause`) | Resume, Options → Options, Abort mission / Leave match, Quit to desktop | Resume |
| Options (over the battle) | settings | Battle menu |
| Results | primary: Continue → the front end page (lobby / debriefing / main menu), Rematch | Continue |
