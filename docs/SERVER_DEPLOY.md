# Running a Siege Engine game server

A dedicated server lets desktop players (ENet) or browser players (WebSocket) play on one machine that is always on. It runs the whole match itself (it is the
authority; nobody hosts from a pilot's PC), restarts a match when one ends, and lists its match over HTTP.
A player joins by the server's address (typed in, or picked from a list). Matches can also be listed on a **master server**
(section 10), a tiny service you run yourself; it only lists games and never carries game traffic. LAN play needs none.

## Contents
1. [How it works](#1-how-it-works)
2. [Settings](#2-settings)
3. [Run it by hand (no container)](#3-run-it-by-hand)
4. [LAN profile (serves the web build and game data)](#4-lan-profile)
5. [Public cloud profile (dedicated server only)](#5-public-cloud-profile)
6. [Ports](#6-ports)
7. [Cheap test hosts](#7-cheap-test-hosts)
8. [Joining](#8-joining)
9. [Checks and known limits](#9-checks-and-known-limits)
10. [Run a master server](#10-run-a-master-server)
11. [Security and exposed ports](#11-security-and-exposed-ports)

## 1. How it works

* Transport: ENet (UDP) is the default, for desktop players on a bare `godot` run and on any dedicated server. It
  needs no proxy and keeps the gameplay RPCs unreliable-ordered. WebSocket (`ws://`, `wss://` behind TLS) is only
  for web clients and browsers, which have no UDP; the Docker/systemd proxy profiles below set `--transport=ws`.
  One server process uses one transport (Godot allows one peer per session), so a browser and a desktop player
  cannot share a match yet; `transport` in the settings picks `enet` (default) or `ws`.
* Capacity: `max_players` (default and hard cap 64, `Net.MAX_PLAYERS`). A pilot-hosted LAN game keeps its 24
  (`Net.LAN_PLAYERS`). The lobby shows `pilots/max`, the match list reports `max`, and a pilot who joins a full
  server is refused with "Server full".
* Server profile: the server runs a collision-only world (`engine/server_profile.gd`, switched on by
  `DedicatedServer`): terrain and structure collision, hit capsules and cell states are built; meshes, materials,
  textures, skies, weather, soldier bodies and their animation are not. On Varuna's Fall this took the process from
  about 1.7 GB to 0.8 GB resident (see `tests/server_profile_perf.tscn`); `tests/server_profile_check.tscn` proves
  the same rays hit the same heights as the full world.
* `--server` (scene `res://server/dedicated_server.tscn`) is headless with no local pilot. Pilots join, press
  Ready (or the lobby timer runs out), the match starts, and `results_seconds` after it ends the next one begins.
  A match with everybody gone for `idle_abort_seconds` is ended.
* The match list is a small HTTP endpoint inside the same process (`engine/match_list_server.gd`):
  `GET /matches` returns `{"matches":[{name, mode, map, players, max, in_game, password, transport, port}]}`,
  `GET /health` returns `ok`. Nothing else is served: never game data. One process = one match; run more
  processes (other ports, other `name`) for more matches.
* The web build's Join screen lists the matches of the server that served the page (same origin) and joins over
  `wss://<page host>/ws`. The desktop's Join screen accepts an IP (ENet), a `ws://`/`wss://` address, or
  `https://server` (shows that server's match list).
* The server needs the game data to run matches (maps, vehicles): mount your own imported packs on it. It reads
  them and never sends them to anybody. Each player needs his own data (desktop: imported discs; browser: the
  LAN profile downloads it from your server, the public profile does not offer it).

## 2. Settings

Copy `deploy/server.json.example` to `server.json` and edit it. Every key can also be given as `--key=value`
on the command line (it wins over the file). Keys: `name`, `port` (47700), `bind`, `transport` (`enet` default, `ws` for browsers), `max_players` (64), `list_port`
(47702, 0 = no list), `password` (empty = open), `data_dir` (folder with the imported packs; default: the
engine's usual lookup, `../gamedata` next to `game/`), `mode` (`vs` or `coop`), `map` (part of a map's name as
the host screen shows it, e.g. `Katabatic`), `game_mode` (`deathmatch`, `team_deathmatch`, ...), `bots` (infantry
bots), `ai` (AI units), `max_bots` (0 = no cap: the most live AI soldiers plus AI vehicles at once; garrisons and squads far from every player are refused first, mission units never; see `engine/bot_budget.gd`), `frag_limit`, `time_limit_s`, `min_players`, `lobby_seconds` (start this long after the
first pilots, ready or not), `results_seconds`, `idle_abort_seconds`, `tick_hz` (0: the fixed simulation tick and the
engine's physics rate follow the game's net profile, 30 Hz for Earthsiege/Starsiege and 32 Hz for Tribes; a number pins it for every game), `max_catchup_steps` (2: ticks run per frame after a stall; the rest are dropped),
`stats_seconds` (60: print a `SERVER STATS` line with tick p50/p95/p99, bytes per client, entity counts and RAM; 0 = off),
`master` (empty: not listed; `http://host:47710` or `host` lists this server on a master server, section 10), `master_token` (the master's `auth_token`, if it has one).

## 3. Run it by hand

**On your own PC, from the app:** Library > Options & tools > **Run dedicated server...** opens a sheet (name, map,
game mode, players, port, max players, password, max bots, master server). Start server runs a headless server from the
installed app with your imported game data; the sheet shows its status, the addresses others can join with, and the log.
Stop server ends it. Close leaves it running; quitting the app from the library stops it. The sheet starts from the
defaults of `server.json.example` (`ServerConfig`) and remembers what you used last (never the password).

**On another machine** (a PC, a VPS, a container), with the same settings in `server.json`:

```
cp deploy/server_override.cfg game/override.cfg    # Jolt physics for the server (the installer and the image do this)
godot --headless --audio-driver Dummy --path game res://server/dedicated_server.tscn -- --server \
      --config=server.json --data_dir=/srv/siege/gamedata
```
`game/override.cfg` is gitignored and only the server runs with it; without it the server runs on GodotPhysics (the same
behaviour, more cost per soldier, docs/DEDICATED_SERVER_SCALING.md section 8.5.4).
It prints `SERVER READY ...`. Check `curl http://127.0.0.1:47702/matches`.

## 4. LAN profile

Serves the web build and the game data to LAN players, and runs the game server. For a trusted network only.

* Container: build the web build and data with `deploy/install.sh` / `deploy/siege-update.sh`
  ([WEB_DEPLOY.md](WEB_DEPLOY.md)), then in `deploy/`:
  ```
  cp server.json.example server.json ; cp env.example .env     # edit both
  docker compose --profile lan up -d --build
  ```
  Open `http://<machine>:8080/`. nginx (`nginx-server-lan.conf`) serves `/`, `/data/`, and forwards `/ws` and
  `/matches` to the game container.
* Without Docker (the existing CT): set `GAME_SERVER="yes"` in `siege.conf` and run `install.sh` again. It adds the
  `siege-server` systemd service (Godot headless from the update checkout) and the `/ws` + `/matches` locations to
  the nginx site (`nginx-game.conf.template`). The service listens on 127.0.0.1 only; nginx is the front door.
  Edit `/etc/siege-engine/server.json`, then `systemctl restart siege-server`.

## 5. Public cloud profile

DEDICATED SERVER ONLY. No web build, no `/data/`, no game data of any kind is served; players bring their own.

```
cd deploy
cp server.json.example server.json ; cp env.example .env     # set SIEGE_DOMAIN and SIEGE_GAMEDATA
docker compose --profile public up -d --build
```
Caddy (`Caddyfile.public`) gets a Let's Encrypt certificate for `SIEGE_DOMAIN` and forwards only `/ws` and
`/matches`; everything else answers 404. Players join `wss://<domain>/ws`. The game container is not published
on a host port. Set a `password` if the server should not be open.

**Legal note.** Siege Engine ships no game content. The server process has to load game data to simulate matches,
so the data on it is your own legally obtained copy, kept on the machine and used only for running matches. Do not
copy it to the public profile's web root or let any proxy serve it, and do not offer downloads of it. Whether
running a public server from your copy of a game is acceptable under that game's licence is your responsibility;
check the licence before you open a server to the public. See also `LEGAL_AUDIT.md`.

## 6. Ports

| Port | Use | Exposed |
|---|---|---|
| 47700/udp | game, ENet (the default transport) | open it to the players; direct, no proxy |
| 47700/tcp | game, WebSocket (`transport: "ws"`) | only through the proxy (`/ws`) in both profiles |
| 47702/tcp | match list, HTTP | only through the proxy (`/matches`) |
| 8080/tcp (`SIEGE_HTTP_PORT`) | LAN profile web page + `/ws` + `/matches` | LAN |
| 80, 443/tcp | public profile Caddy (certificate + `wss`) | internet |
| 47701/udp | LAN discovery (ENet servers and desktop-hosted LAN games) | LAN |
| 47710/tcp | master server (section 10) | players and game servers, direct (no proxy) |

## 7. Cheap test hosts

The image is Debian slim and builds for amd64 and arm64 (Godot has Linux arm64 builds; the Dockerfile picks the
right one and verifies its SHA-512).

* Oracle Cloud Always Free: Ampere A1 (ARM, up to 4 cores / 24 GB free). Best fit. Open TCP 80/443 in the VCN
  security list and in the instance firewall.
* Google Cloud e2-micro: free tier, 1 GB RAM. Enough for a small match; add swap. Open 80/443 in the VPC firewall.
* Hetzner CX22 (about EUR 4 per month, 4 GB) or CAX11 (ARM). Any small VPS with Docker works the same.

Point a DNS name at the machine before starting the public profile (the certificate needs it). Bandwidth is small
(snapshots for up to 64 pilots).

## 8. Joining

* Browser: open the LAN server's page, Join online game, pick the match.
* Desktop: Join LAN game (the Browser screen) has three ways in:
  * **LAN games**: pilot-hosted games and dedicated servers on your network, found by broadcast.
  * **Online games**: the list of the master server set in Options > Online (Refresh to reload), each with its ping.
  * **Join by address**: type the server's IP (`192.168.1.20`), `IP:port` (`192.168.1.20:47800`) or a host name, then press
    Enter or Check: the server's name, mode, map, players and the ping appear before you join (the info comes from its match
    list, HTTP port 47702, so that port must be reachable; without it you can still press Join address). Joined addresses
    are remembered under Recent. For a WebSocket server type `ws://host:port/ws`, `wss://domain/ws` or `https://domain`
    (lists the matches). Password if the server asks.

## 9. Checks and known limits

* Tested here: headless server plus a desktop client over WebSocket through the UI (join, ready, movement, an AI
  kill, match end, automatic next match): `tests/server_ws_check.tscn` with
  `e2e_driver.tscn -- --flow=lan_join --transport=ws --dedicated --mode=vs --port=<p>` (start the server check with
  `--transport=ws`; without it the same check runs over ENet and the driver joins without `--transport`); 64 ENet
  clients on loopback and the 65th refused (`tests/net_transport_check.tscn`); ENet LAN regression
  (`tests/game_modes_lan.tscn`).
* Not tested: the browser client against the server (the code path is the same WebSocketMultiplayerPeer), the
  Docker image build and the compose files on a real daemon (the files were only validated with
  `docker compose config`), the systemd service, and TLS in front of the WebSocket.
* A pilot cannot join a match in progress (he joins during the lobby or the results pause), the dedicated server
  runs `vs` and `coop` matches only (no campaign or extraction), and hosting from the browser is not possible.

## 10. Run a master server

A master server is the "connecting server" of the old Quake and Tribes days: game servers **register** with it and send a
**heartbeat** every 30 s; players ask it for the **list** and join a listed game directly. It never relays game traffic, holds
no game data and stores nothing personal (name, mode, map, player counts, a password-protected flag, ports).

It is a headless Godot scene of the same app (`res://server/master_server.tscn`), not a separate program: the game binary is
the one thing every host already has (the Windows desktop app, the Docker image, the systemd install), it reuses the engine's HTTP
code, and it needs no Python or other runtime. Run it anywhere, also on the PC where you run a game server.

```
godot --headless --audio-driver Dummy --path game res://server/master_server.tscn -- --port=47710
```
It prints `MASTER READY port=47710`. Options (command line or `--config=master.json`): `port` (47710), `bind` (`*`), `auth_token`
(empty: anyone may register; set it so only your servers can), `ttl` (90: seconds without a heartbeat before an entry expires),
`rate_limit` (60 requests per address per minute).

* **Docker**: `docker compose --profile master up -d --build` in `deploy/` (publishes `SIEGE_MASTER_PORT`, default 47710;
  `SIEGE_MASTER_TOKEN` in `.env` sets the token). It can run next to the `lan` or `public` profile; it needs no game data.
* **systemd**: set `MASTER_SERVER="yes"` in `siege.conf` and run `install.sh` again (service `siege-master`, settings in
  `/etc/siege-engine/master.json`, created on the first run).
* **LAN, no internet**: run it on any machine of the LAN, for example `http://192.168.1.5:47710` (use your own address).

**Using it.** On the machine of a dedicated server set `"master": "192.168.1.5:47710"` in `server.json` (or `--master=...`, or the
sheet's Master server field); the server registers when it is ready and keeps itself listed. On a player's PC set the address
under Options > Online: the Browser then shows an **Online games** section next to the LAN games, and **Host online game**
(Play tab, and in the Browser under the original shell) hosts a lobby like Host LAN game and also lists it on the master until
the lobby closes (it answers the match list on port 47702 for the ping). Leave the address empty and nothing is ever sent anywhere.

**Protocol** (JSON over HTTP; bodies are at most 2 KB):

| Request | Body | Answer |
|---|---|---|
| `POST /register` | `name`, `game`, `mode`, `map`, `players`, `max`, `password` (bool), `version`, `transport` (`enet`/`ws`), `port`, `list_port`, `in_game` | 200 `{ok, id, heartbeat_seconds, ttl_seconds}`; 400 on a bad field |
| `POST /heartbeat` | the same, with fresh numbers | 200, or 404 when the master does not know the entry (register again) |
| `DELETE /unregister` | `{"port": 47700}` | 200, or 404 |
| `GET /servers` | none | `{"servers": [{name, game, mode, map, players, max, password, version, transport, ip, port, list_port, in_game, age}]}` |
| `GET /health` | none | `ok` |

The listed `ip` is the address the master **observes** on the connection, never what the server claims (this handles NAT); `port`
is the game port the server declares. Only that same address can update or remove an entry. A client that sees `127.0.0.1` (a server
on the master's own machine) joins at the master's host instead. Entries expire after `ttl` seconds without a heartbeat. Limits:
512 entries, 8 per address, 60 requests per address per minute (429), bodies over 2 KB (413). With `auth_token` set, the three write
requests need `Authorization: Bearer <token>`; `GET /servers` stays open. The token lives in your settings files only, never in the repo.

Checks: `tests/master_server_check.tscn` (registry, routes, token, validation, rate limit, one real round trip) and
`tests/master_lan_check.tscn` (a master process, a dedicated server started the way the sheet does, a client that lists it, joins by the
listed and by a typed address, and sees the entry expire; ports 47770, 47772, 47711; run it alone).

## 11. Security and exposed ports

A server or master you run is a network service: open only what you need, and only to the people who need it.

| Port | Service | Who needs it | Notes |
|---|---|---|---|
| 47700/udp | game (ENet) | players | the game itself; set a `password` for a private server |
| 47700/tcp | game (WebSocket, `transport: "ws"`) | the proxy only | publish it through the proxy (`/ws`), not directly |
| 47702/tcp | match list (`/matches`, `/health`) | players (info and ping) | read only; shows name, mode, map, counts, whether a password is set |
| 47710/tcp | master server | players and game servers | lists games only; set `auth_token` to restrict who may register |
| 47701/udp | LAN discovery (broadcast) | the LAN | never forward it to the internet |

* Binds default to `*` for the game and the lists (players must reach them); the systemd game server binds `127.0.0.1` behind nginx.
  Set `bind` to one address to listen on a single interface.
* The master never relays game traffic and never serves game data. A game server sends it no password and no pilot name; the only
  things a PC sends it are the listing fields above (a hosted lobby uses the host's chosen server name).
* Pilots connect straight to the game server; the master's `ip` is only a pointer. Do not put real names, addresses or tokens in
  `server.json.example` or any file in the repo; keep your own `server.json`, `master.json` and `.env` out of version control.
* Firewalls: on Windows allow the app (or the ports above) for a local server; on a router forward UDP 47700 and TCP 47702 (and 47710
  for a master) to the machine only if people outside your LAN should join.
