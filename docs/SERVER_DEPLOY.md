# Running a Siege Engine game server

A dedicated server lets desktop players (ENet) or browser players (WebSocket) play on one machine that is always on. It runs the whole match itself (it is the
authority; nobody hosts from a pilot's PC), restarts a match when one ends, and lists its match over HTTP.
There is no central matchmaking: every server lists its own match, and a player joins by the server's address.

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
`stats_seconds` (60: print a `SERVER STATS` line with tick p50/p95/p99, bytes per client, entity counts and RAM; 0 = off).

## 3. Run it by hand

```
godot --headless --audio-driver Dummy --path game res://server/dedicated_server.tscn -- --server \
      --config=server.json --data_dir=/srv/siege/gamedata
```
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
* Desktop: Join LAN game, type the server's IP (ENet, the default), or `ws://host:port/ws`, `wss://domain/ws`,
  `https://domain` (lists the matches) for a WebSocket server; password if asked.

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
