# Siege Engine coding standards

The project follows Robert C. Martin's *Clean Code*. The rules below make it concrete for this
codebase (GDScript game code first, the Python tools second). Every change should leave the code it
touches cleaner than it found it.

## 1. Clean Code rules

### Names
- Intention-revealing names: `shield_front`, `charge_spent`, not `s`, `tmp` or `v2`.
- Classes are nouns (`HangarBay`, `MapBuilder`); functions are verbs (`build_terrain`, `apply_hit`).
- One word per concept across the whole project:
  - `build_*` creates nodes.
  - `load_*` reads data files.
  - `make_*` returns a value with no side effects.
  - `apply_*` mutates state.
- No encodings or abbreviations beyond the ones the original formats use (DTS, DBA, VOL …).

### Functions
- Small: aim for at most about 30 lines; a function longer than about 50 lines must be split.
- Each function does one thing at one level of abstraction. If a function needs section comments,
  split it at those comments.
- Few arguments: 0–3. More than 3 means passing a Dictionary/Resource (a parameter object) or a
  missing class.
- No flag arguments that switch behaviour; write two functions instead.
- Command/query separation: a function either changes state or returns a value, not both
  (builders returning the node they built are fine).
- No hidden side effects; anything a function mutates should be obvious from its name.

### Classes and files
- Single Responsibility: one reason to change per script.
- A script over about 400 lines is a candidate to split (e.g. Battle → camera, spawning, net sync,
  mission hookup).
- Game-specific code lives under `games/<pack>/`; anything two games share moves to `engine/`.
- Depend on abstractions (provider contracts, the vehicle/weapon/map schemas), not on another
  game's internals.

### Comments
- The code says *what*; comments only say *why*: the original-game evidence (address, file,
  RE note) or a non-obvious constraint.
- No commented-out code and no change logs in comments.
- Doc comments (`##`) go on public classes and functions.

### Errors and data
- Fail loudly at the boundary (`push_error` plus a safe default) and never silently continue
  with corrupt state.
- No magic numbers: name them as `const`, citing the source of original-game values.
- Don't return or accept `null` where an empty Array or Dictionary works.

### Duplication
- DRY: copy-pasted logic between games or screens is a bug waiting to happen; extract it.

### Tests
- Headless tests in `game/tests/` (`compile_all`, `hangar_check`, `garage_check`, `saga_check`, `ttk_check` …)
  must pass before reporting work as done.
- Add a test with every fix.

## 2. Input: one input map, named actions only

- **Named actions only:** gameplay and UI code never tests raw keys or mouse buttons. It asks
  `Input.is_action_*` / `event.is_action_*` about the actions below, all defined in one place:
  `engine/input/siege_input.gd` (autoload `SiegeInput`). That script:
  - registers default keyboard, mouse and gamepad bindings at startup;
  - loads the player's rebinding from `user://input.json`;
  - offers `rebind(action, event)` / `reset_defaults()` for an options screen.
- **The one exception: the original Earthsiege shell.** Its dialog hotkeys are DOS scan codes from
  the original data, so `ShellMenu` translates key events through one documented adapter table.
  Navigation and confirm/cancel in the shell still use the `ui_*` actions.

| action | default keyboard / mouse | gamepad | meaning |
|---|---|---|---|
| `ui_accept` / `ui_cancel` / `ui_up` … | Godot defaults (Enter, Esc, arrows) | A / B / d-pad, left stick | menus everywhere |
| `ui_click` | mouse left | — | click the control under the cursor (position-based widgets: original shell, cockpit buttons) |
| `menu_back` | Esc | B | leave the current screen |
| `menu_pause` | Esc (in battle) | Start | pause / in-game menu (frees the mouse) |
| `menu_secondary` | mouse right | X | menus: remove / alternate action on the focused item (rename a slot tab). Handlers ask with `exact_match` (`UiActions.is_pressed`) |
| `menu_info` | F1 | Y | menus: pin / unpin the detail tooltip (`ItemTooltip`) of the focused item |
| `menu_tab_prev` / `menu_tab_next` | Ctrl+PgUp / Ctrl+PgDn | LB / RB | menus: slot tabs, pane tabs, carousel cards, store categories |
| `menu_zone_prev` / `menu_zone_next` | Shift+Tab / Tab | LT / RT | menus: jump between the zones of a screen (Tab and Shift+Tab are two controls: bindings keep their modifiers) |
| `menu_switch_kind` | V | View/Back | menus: infantry <-> vehicle |
| `menu_primary` | Ctrl+Enter | Start | menus: press the footer / sheet primary action |
| `callin_menu` | L | LB + RB together (`ChordAction`) | extraction raid, on foot: open the call-in menu (`CallinMenu`) |
| `menu_scroll_up` / `menu_scroll_down` | wheel up / down | — | scroll a list (original shell) |
| `throttle_up` / `throttle_down` | W / S | right trigger / left trigger | Herc throttle (analog on the triggers); on foot run forward / back |
| `throttle_stop` | X | left stick click | all stop |
| `turn_left` / `turn_right` | A / D | left stick X | turn the chassis; on foot strafe |
| `aim_left` / `aim_right` / `aim_up` / `aim_down` (+ mouse motion) | mouse | right stick | torso twist / pitch |
| `torso_center` | Z | right stick click | centre the torso |
| `ascend` / `descend` | Space / left Ctrl | A / X | flyers: climb / dive (Earthsiege 2 jets: nose up / down; Tribes-style hover craft: lift); on foot `ascend` jumps; in a Tribes vehicle `ascend` gets out |
| `jet` | mouse right | LB | on foot: jetpack (Tribes IDACTION_JET) |
| `weapon_next` | Q | Y | on foot: next carried weapon (Tribes nextWeapon; Y is weapon swap in Call of Duty) |
| `interact` | E | X | on foot: the nearest thing in reach (`InfantryInteraction`): pick up an item (also by walking over it, as in Tribes), loot a cache / bag (extraction), touch a switch, board the vehicle whose hatch is in reach |
| `vehicle_enter_exit` | E | B | get out of any vehicle; on foot E boards through `interact` and pad B boards a non-Tribes vehicle within hatch reach (light armour only). Without a Tribes pack installed pilots cannot get out (no soldier) |
| `seat_next` | F | d-pad left | in a Tribes vehicle: move to the next free seat the armour may take (remake addition) |
| `grenade_throw` | G (Tribes 1 and 2) | d-pad up | on foot: hold and release to throw a grenade (longer = farther) |
| `mine_drop` | B (Tribes 2; Tribes 1 M) | d-pad down | on foot: hold and release to throw a mine |
| `pack_use` | R (Tribes 2; Tribes 1 P) | d-pad right | switch the worn backpack on / off (repair, shield, sensor jammer) |
| `repair_kit_use` | H (Tribes 1; Tribes 2 Q) | left stick click | use a repair kit |
| `structure_repair` | R | back paddle 1 | a Herc without a repair pack: hold next to a structure to repair it (`RepairDirector`; capturing it when hostile) |
| `inventory_toggle` | I | hold X (0.5 s) | extraction raid: open / close the inventory panel (`InventoryPanel`) |
| `exfil_call` | O | hold right stick click (1 s) | extraction raid: call an exfil transport to the nearest extraction zone |
| `fire_group_1` / `fire_group_2` | mouse left / mouse right | RB / LB | weapon groups (on foot: `fire_group_1` fires the weapon in hand) |
| `target_next` / `target_nearest` | T / C (original) | Y / — | targeting (vehicles; on foot pad Y is `weapon_next`, T still cycles) |
| `view_toggle` | V | Back | cockpit / chase view |
| `scoreboard` | Tab | — | multiplayer scores |
| `objectives_toggle` | J | — | battle and on foot: show / hide the mission objectives panel (`ObjectivesPanel`) |
| `command_map` | N | hold Back (0.5 s) | battle and on foot: open / close the command map (`CommandMap`): orders to wingmen, squadmates and teammates (Tribes originals: C, taken here by `target_nearest`) |
| `missile_cam_toggle` | M | — | battle: show / hide the missile-cam window (Earthsiege 1/2 player missiles) |
| `cockpit_mode_1`…`cockpit_mode_6` | F1–F6 (original) | — | cockpit display modes; in Starsiege F1–F3 call up squadmate 1–3 and F4 the squad, then 1–7 order (`SquadKeys`, the original keys) |
| `cockpit_mode_next` | — | d-pad right | next cockpit display mode |
| `cloak_toggle` | Ctrl+X (Starsiege IDACTION_CAMOUFLAGE; plain X stays `throttle_stop`) | — | battle: switch a vehicle's cloak on / off (`CloakState`; a soldier's cloaking pack is `pack_use`) |
| `hdd_page_1` / `hdd_page_2` | F7 / F8 (original) | — | damage display pages |
| `look_up` / `look_down` | PgUp / PgDn, keypad 8 / 2 | d-pad up / down | cockpit view tilt |
| `look_left` / `look_right` | keypad 4 / 6 (original F9 / F10; F10 is `debug_toggle`) | — | Earthsiege 2 cockpit side views (toggle; again the other one, `look_up` / `look_down` or an MFD page key: front view) |
| `orbit` (held + drag) | mouse left / right | — | hangar and shape viewer |
| `orbit_left` / `orbit_right` / `orbit_up` / `orbit_down` | Q / E / R / F | right stick | hangar, shape viewer and the menus (the lobby carousel stage) |
| `zoom_in` / `zoom_out` | wheel up / down | right / left trigger | hangar and shape viewer |
| `viewer_next_lod` / `viewer_cell_state` / `viewer_interpolation` | L / C / I | — | shape viewer tools |
| `chat_all` / `chat_team` | Enter (keypad Enter) / Y | — | battle and on foot: type a chat line to everybody / to the team (`BattleChat`) |
| `chat_quick` | K | Share (misc 1) | battle and on foot: the quick-chat menu of canned lines (`QuickChatMenu`; ui_up / ui_down / ui_accept pick) |
| `chat_history` | U | — | battle and on foot: the full chat history, filter tabs, move / resize the panel (edit mode) |
| `chat_send` / `chat_cancel` | Enter / Esc | — / B | chat open: send the line / close the chat (in the quick-chat menu: back one level) |
| `chat_scroll_up` / `chat_scroll_down` | wheel up / down, PgUp / PgDn | right stick up / down | chat open: scroll the history |
| `chat_channel_next` | Tab | Y | chat open, typing: switch between all and team |
| `screenshot` | F12 | — | save a screenshot (user://screenshots, handled by `SiegeInput`) |
| `debug_toggle` | F10 | — | developer overlay / launcher |

**Gamepad on foot (Xbox names; Call of Duty / Hunt: Showdown convention).** A jump, B board (pad) / get out,
X interact (tap) - inventory (hold, raid), Y next weapon, LB jet, RB fire, LT / RT run back / forward, left stick
strafe and run, right stick look, left stick click repair kit, right stick click level the view (tap) - call exfil
(hold, raid), d-pad up grenade, down mine, right pack, left next seat, View/Back view toggle, Start pause, Share
quick chat. "Two buttons together = one action" is `ChordAction` (`engine/input/chord_action.gd`, `SiegeInput.CHORD_ACTIONS`): no single pad
button is free on foot, so `callin_menu` is the LB + RB chord (LB and RB still act on their own: jet, fire).
"Tap = the button's own action, hold = another" is `HeldAction` (`engine/input/held_action.gd`): the
tap still acts on press, so a hold only goes on a button whose tap is harmless when held (interact with nothing in
reach, level the view). Saved bindings of version 1 are migrated (`SiegeInput.make_migrated_v1`: `loot_pickup` ->
`interact`, the moved pad defaults replace the saved pad events of those actions).

Actions are added to this table first, then to `SiegeInput`, and to the context they are live in
(`engine/input/binding_contexts.gd`: menus, battle, infantry (on foot), viewer, chat, or global). The infantry
context shares controls with the battle context where a soldier never needs both (`jet` / `fire_group_2` on
mouse right and LB, `interact` / `descend` on pad X, `weapon_next` / `target_next` on pad Y, `interact` /
`vehicle_enter_exit` on E (on foot boarding is one of interact's offers), the gear actions / the cockpit views on the d-pad,
`repair_kit_use` / `throttle_stop` on the left stick click). In a Tribes vehicle `ascend` (the jump key) also
gets out, as the originals' jump trigger does. The chat context is live only while the chat is open (typing, the
quick-chat menu, the history): `BattleChat` then holds the player's controls (`PlayerHold`) and the chat panel takes
every key and button, so the chat actions may reuse battle controls (Enter, Esc, Tab, pad B / Y, PgUp / PgDn, the
right stick); gameplay `_input` handlers that run before the GUI check `ChatFocus.open`. Rebinding never silently
binds one control twice inside a context: the options screen offers Swap / Clear / Cancel.

## 3. UI: one theme, shared widgets

- **Theme:** one theme for the app's own screens (library, launcher, lobby, briefings, options,
  hangar overlay), `engine/ui/siege_theme.gd`, which builds `siege_theme.tres`. It is set as the
  project's default theme. Screens never call `add_theme_*_override` for colours, fonts or sizes;
  they use the theme's named variations: `HeaderLabel`, `SectionLabel`, `DimLabel`,
  `StatusLabel`, `PrimaryButton`, `DangerButton`, `TitleBar`, `FooterBar`, `ModalPanel`, and the lobby / loadout kit
  `CreditsLabel`, `CardPanel`, `CardPanelSelected`, `BadgeNotAllowed`, `BadgeAtRisk`, `BadgeLost`, `TabButton`,
  `ReadyDot` / `ReadyDotOff`, `Tooltip` …
  (built-in types such as `Panel`/`PanelContainer` can't be variations; the theme styles them
  directly as cards). Constants live under the theme type `Siege` (including `narrow_width` = 900, the content width below which screens use their narrow layout).
- **Shared widgets** live in `engine/ui/`:
  - `ScreenFrame`: title bar, content area and footer with Back / primary action;
  - `OptionRow`: label plus control;
  - `VehiclePicker`;
  - `LoadoutEditor`;
  - `HangarView`;
  - `GaragePicker` (a campaign's "Your Herc"; the Hangar screen edits the garage);
  - `MapPicker`;
  - `ConfirmDialog` (two answers, or three with `add_choice`);
  - `BattleMenu`: the in-battle menu (`menu_pause`) of every game and mode: Resume, Options,
    Abort mission / Leave match, Quit to desktop; the battle supplies what each choice does
    (`games/es1/battle/battle_exit.gd`);
  - `ChatPanel` (`engine/chat/`): the battle chat panel, with `ChatOptions` (`engine/ui/chat_options.gd`) as
    the options screen's chat section;
  - `MatchResults`: the results screen after every match (winner, pilots' kills / deaths / score,
    time, salvage; Continue, Rematch);
  - `ItemRow`: one item in a list (name, dim detail line, action buttons): the raid inventory, the stash, the shop.
  - `CreditsBadge`: the wallet readout "CR 1,240" (plain number or a Callable; never focusable);
  - `ItemTooltip`: one detail plate per screen, `watch(control, provider)`: shows on hover, on focus after 0.4 s, pinned by `menu_info`;
  - `ModalSheet`: a full-screen modal (title row, body, Back left / primary bottom-right); `menu_back` closes, `menu_primary` presses
    the primary action, focus is trapped inside and returns on close; used by Operator Setup and the lobby's dialogs;
  - `OptionRow.make_readonly(label, text)`: a setting only the host may change, shown as text (a Label, not a control);
  - `NameRow`: the player's name (saved by `PlayerProfile`, used in the lobby, chat and nameplates);
  - `OperatorSetup` (`engine/ui/operator/`): the one loadout screen (soldier, Herc, store, look) of the lobby and Options;
  - `TeamList`: the teams of a team match (colour, name, pilots and bots; pilots pick, the host assigns);
  - `HudLayout` (`engine/ui/hud_layout.gd`): the zones of the overlay HUD (top-left status, target, top-centre compass,
    centre banners, top-right radar and objectives, bottom-left / right / centre instruments, screen-wide effects). A
    HUD element never places itself at fixed coordinates: it `declare`s its size every frame and draws into
    `rect_of(id)`; a zone stacks its elements, so none overlap. A new element is a row of `HudLayout.ELEMENTS`;
    `hud_layout_check` shows everything at once at 1280x720, 1920x1080 and a narrow window. Floating panels (chat,
    missile cam) search for a spot clear of `make_occupied_rects`. The crosshair, world markers, modal panels and each
    game's cockpit painters are not placed by it;
  - `ObjectivesPanel`: the translucent in-battle objectives side panel (`MissionObjectives` gathers the lines);
  - `CatalogBridge`: the front end's one door to other catalogs (infantry choices, game modes, map teams,
    extraction relation presets).

  A screen composes these instead of building rows by hand.
- **Navigation:**
  - Every screen supports mouse, keyboard and gamepad (focus neighbours set, first control
    focused on open).
  - `menu_back` always leaves the screen.
  - The primary action is always bottom-right.
- **The original Earthsiege shell** keeps its original look; only its input goes through actions.
- **Text sizes and spacing** come from the theme constants (`margin`, `gap`, `font_size_*`).

## 4. Game mechanics: one engine, original feel per game

Every game runs on the same mechanics code. Rendering was unified first (`docs/RENDER_UNIFICATION.md`);
missions and the other mechanics follow the same rule (`docs/MECHANICS_UNIFICATION.md`).

- **One set of building blocks:** timers, waypoint and area checks, objectives (destroy, protect, reach,
  datalink/recon, survive, escort), spawn waves, fail rules, messages and voice prompts, mission end, damage,
  sensors, targeting and AI orders live once, in `engine/`.
- **Games are data adapters:** a game's importer or `games/<pack>/` code translates the original data
  (ELF scripts, UnrealScript actors, ES1 mission files, Torque scripts …) into those shared blocks. It never
  adds a separate runtime with its own timers, triggers or objective logic.
- **Original feel stays in data:** timings, messages, voice lines, ranges and rules come from the original
  game (cited as in section 1), so each game plays like the original while the code is shared.
- **Extend, don't fork:** when a game needs behaviour the shared blocks lack, add it to the shared block
  (configurable through data) so every game can use it.
- **Clean Code applies throughout** (section 1, Robert C. Martin): small single-purpose classes, the
  `build_`/`load_`/`make_`/`apply_` naming, no duplication across games, and a test with every block.
