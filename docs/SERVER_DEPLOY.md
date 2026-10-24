# Running a Siege Engine game server

A dedicated server lets desktop players (ENet) or browser players (WebSocket) play on one machine that is always on. It runs the whole match itself (it is the
authority; nobody hosts from a pilot's PC), restarts a match when one ends, and lists its match over HTTP.
A player joins by the server's address (typed in, or picked from a list). Matches can also be listed on a **master server**
(section 10), a tiny service you run yourself; it lists games, keeps the short-lived **parties** (friends who go to a server together,
`docs/design/party.md`) and never carries game traffic. LAN play needs none. A server can also run a persistent **extraction raid**
(section 12); section 13 sets up a master and two raid servers in an Ubuntu container on a Proxmox box for the LAN.

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
12. [Extraction servers (a persistent raid)](#12-extraction-servers)
13. [An Ubuntu container on Proxmox: a master and two raid servers, LAN only](#13-ubuntu-container-on-proxmox)

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
  A match with everybody gone for `idle_abort_seconds` is ended. That is the lifecycle of the modes `vs` and `coop`;
  mode `extraction` is one persistent raid that pilots drop into and leave at any time (section 12).
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
engine's usual lookup, `../gamedata` next to `game/`), `mode` (`vs`, `coop` or `extraction`), `map` (part of a map's name as
the host screen shows it, e.g. `Katabatic`), `game_mode` (`deathmatch`, `team_deathmatch`, ...), `bots` (infantry
bots), `ai` (AI units), `max_bots` (0 = no cap: the most live AI soldiers plus AI vehicles at once; garrisons and squads far from every player are refused first, mission units never; see `engine/bot_budget.gd`), `frag_limit`, `time_limit_s`, `min_players`, `lobby_seconds` (start this long after the
first pilots, ready or not), `results_seconds`, `idle_abort_seconds`, `tick_hz` (0: the fixed simulation tick and the
engine's physics rate follow the game's net profile, 30 Hz for Earthsiege/Starsiege and 32 Hz for Tribes; a number pins it for every game), `max_catchup_steps` (2: ticks run per frame after a stall; the rest are dropped),
`stats_seconds` (60: print a `SERVER STATS` line with tick p50/p95/p99, bytes per client, entity counts and RAM; 0 = off),
`master` (empty: not listed; `http://host:47710` or `host` lists this server on a master server, section 10), `master_token` (the master's `auth_token`, if it has one).
Mode `extraction` adds `relations` (`story`, `all_hostile`, `humans_allied`), `raid_fast`, `raid_seed`, `raid_reset_minutes`, `raid_reset_grace_seconds`,
`raid_empty_seconds`, `party_wait_seconds` and `results_hold_seconds` (section 12); for it `bots` are the faction soldiers and `ai` the faction vehicles.
`deploy/server-extraction.json.example` is a complete raid example.

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
| 47701/udp | LAN discovery (ENet servers, desktop-hosted LAN games and LAN parties) | LAN |
| 47710/tcp | master server (section 10): game list and party service | players and game servers, direct (no proxy) |
| 47703/tcp | a LAN party hosted by a player's PC (`docs/design/party.md`) | that LAN |
| 47720/udp, 47722/tcp ... | a second game server on the same host: its own `port` / `list_port` (section 12) | players |

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
* Desktop, with friends: **Party** (Play tab). One pilot creates a party, the others join it by its code (online, through the master) or from the
  LAN list; they ready up, the leader picks a server (LAN game, online game or a typed address) and presses Go, and every member is sent there
  together: the same team in versus and co-op, the same squad on one transport in a raid. After the raid everybody is back on the party screen.
* Desktop: Join LAN game (the Browser screen) has three ways in:
  * **LAN games**: pilot-hosted games and dedicated servers on your network, found by broadcast.
  * **Online games**: the list of the master server set in Options > Online (Refresh to reload), each with its ping.
  * **Join by address**: type the server's IP (`192.0.2.20`), `IP:port` (`192.0.2.20:47800`) or a host name, then press
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
* In `vs` and `coop` a pilot cannot join a match in progress (he joins during the lobby or the results pause); an extraction server is the
  exception by design (section 12). The dedicated server plays no campaign, and hosting from the browser is not possible.
* Extraction servers and parties are checked by `tests/dedicated_extraction_check.tscn` (a headless raid on Katabatic: the world opens on the first
  Ready, a pilot joins the running raid, one extracts, one dies, results, the empty world resets, the next pilot gets a new world),
  `tests/party_check.tscn` (an online and a LAN party: create, join by code, chat, ready, Go moves the members onto one server in one squad on one
  transport, results, back on the party screen) and `tests/party_registry_check.tscn` (the party service's rules, no sockets). Not tested: the
  systemd instances and `install.sh` SERVERS_ONLY on a real Ubuntu machine, the Docker `extraction` profile.

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
* **LAN, no internet**: run it on any machine of the LAN, for example `http://192.0.2.5:47710` (use your own address). Section 13 sets one up in a container.

**Using it.** On the machine of a dedicated server set `"master": "192.0.2.5:47710"` in `server.json` (or `--master=...`, or the
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

**Parties.** The master also keeps the short-lived parties of players who go to a server together (`docs/design/party.md`): POST `/party/create`,
`/party/join`, `/party/state` (the poll), `/party/ready`, `/party/summary`, `/party/destination`, `/party/go`, `/party/say`, `/party/back`, `/party/kick`,
`/party/leave` (JSON bodies of at most 2 KB, every answer is the party as the member sees it). A party has a 5-character code, a leader and up to 8
members; it lives in the master's memory only (no accounts, nothing on disk) and is forgotten when its members stop asking (3 minutes) or nobody touched it
for 30 min. The routes need no `auth_token` and have a rate limit of their own (`party_rate_limit`, default 900 requests per address per minute: a
household of kids polls once a second each; `max_parties`, default 256). A password the leader types for a password-protected destination is passed on to
the members through the master, so use a password you use nowhere else.

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

## 12. Extraction servers

`"mode": "extraction"` makes the server one **persistent raid** on one map (`map`, for example `Katabatic` or `Varuna's Fall`): the loot caches, the faction
squads and their vehicles (`bots` soldiers, `ai` vehicles, capped together by `max_bots`), the relations preset (`relations`) and the transports of
`docs/design/extraction.md`. Every server runs one map; for more maps run more servers on other ports.

**Lifecycle (the choice made, and why).** A raid that ends when its players are gone suits a LAN lobby, not a server where friends come and go. So:

1. **Idle**: with nobody there, no world is simulated and the server costs next to nothing.
2. **Open**: the first pilot who is Ready (pressed Ready in the server's lobby, or came with a party Go) opens the world. From then on pilots and parties join
   **at any time**: the client builds the map, the server sends it the world as it is (every living unit, who sits where, the caches, zones, relations and
   exfil calls), and drops the pilot in by transport. A party is dropped in **together on one transport** (the server waits for the members that are
   connected, and `party_wait_seconds` for those that are not yet) and plays on **one team**, so teammates can revive each other; a pilot who came alone has a team of his own.
3. **Extract or die**: each pilot's raid ends on its own, as in a LAN raid (the haul goes to the stash on his machine, a death leaves a bag). He sees
   his banner for `results_hold_seconds`, then leaves the server and gets his results screen; **the world goes on without him**.
4. **Reset**: the world closes when nobody has been in it and nobody has waited to drop in for `raid_empty_seconds` (default 120; 0 = it stays up), so the next
   pilot finds fresh caches and squads. With `raid_reset_minutes` > 0 it also resets on a schedule: that long after it opened new drop-ins pause ("The world
   resets, extract now"), the world closes when the last raider is out, or `raid_reset_grace_seconds` later (those still inside are sent away and lose
   their kit, as if they had quit). Pilots waiting in the lobby keep their place and drop into the next world.

**Clients bring their operator kits** (client-held profiles, as in a LAN raid): the kit travels in the roster entry, the profile on the player's PC is
charged when the raid starts and credited when he extracts. The server stores nothing about players, so a server restart loses nothing but the current world.
This trusts the clients with their own stash: run an extraction server for friends and family, not for strangers.

| key | default | meaning |
|---|---|---|
| `mode` | `vs` | `extraction` |
| `map` | | part of the map's name as the host screen shows it |
| `bots`, `ai`, `max_bots` | 0, 0, 0 | faction soldiers, faction vehicles, the cap on live AI units (0 = none) |
| `relations` | `story` | `story`, `all_hostile` or `humans_allied` (docs/design/extraction.md section 3) |
| `max_players` | 64 | pilots at once |
| `raid_empty_seconds` | 120 | close the empty world after this long (0 = never) |
| `raid_reset_minutes` | 0 | scheduled reset, minutes after the world opened (0 = never) |
| `raid_reset_grace_seconds` | 300 | how long raiders still inside may extract once the reset time is reached |
| `party_wait_seconds` | 60 | a party drops in together: once its first member has built the battle, the server waits this long for the other members to connect (members that are connected and still loading are always waited for, up to 5 minutes) |
| `results_hold_seconds` | 5 | how long an extracted or killed pilot sees his banner before the results screen |
| `raid_seed` | 0 | the loot and squad seed of every world (0 = a new one each time) |
| `raid_fast` | 0 | 1: the short timers of the tests |

**Several servers on one host.** Each server is one process with its own `port` (UDP, the game), `list_port` (TCP, the match list) and `name`; for example
47700 / 47702 and 47720 / 47722. With systemd use the instance template `deploy/systemd/siege-server@.service.template`: `siege-server@katabatic` reads
`/etc/siege/katabatic.json` (`install.sh` renders it and creates the instances listed in `SERVER_INSTANCES`, section 13). With Docker, the `extraction`
profile of `deploy/docker-compose.yml` runs two raids on the host network with `servers/katabatic.json` and `servers/varuna.json`
(`docker compose --profile extraction --profile master up -d --build`). LAN discovery lists each server with its real game port and match list port, so
two raids on one host show up as two rows.

**Known limits.** A pilot who joins late sees the map as it was built: base structures destroyed before he came are whole for him. The world is
simulated by one process on one core; with the `bots` / `ai` counts of the example a 16-player raid is comfortable on a modern core (the `SERVER STATS`
line shows the tick time; lower `bots` or `max_bots` if p99 gets near the tick budget). Roster claims (the party code) are trusted.

## 13. Ubuntu container on Proxmox

A master server (game list and parties) and two raid servers, Katabatic and Varuna's Fall, in one Ubuntu 24.04 container (LXC) on a Proxmox box, for the
home LAN only. Addresses below are documentation addresses (`192.0.2.x`): use your own.

**What you need.** The repository reachable from the container (Gitea, over ssh with a deploy key or https), your own imported game data (at least Tribes 2:
the maps, the soldiers and the transports come from it; the factions' vehicles come from the other games you have imported, a faction without anything is
skipped), and about 8 GB of RAM, 4 cores and 20 GB of disk for the two raids and the data.

1. **Create the container** (Proxmox: Create CT). Template `ubuntu-24.04-standard`, hostname `siege`, unprivileged is fine, 4 cores, 8192 MB RAM (+512 MB swap),
   20 GB disk, network `vmbr0` (the bridge your LAN is on) with a **static address**, for example `192.0.2.50/24`, gateway your router. Tick *Start at boot*.
   Nothing else (no nesting, no Docker). The container must sit on the same LAN as the PCs: the servers announce themselves by UDP broadcast, which does
   not cross a NAT.
2. **Get the code.** In the container's console, as root:
   ```
   apt-get update && apt-get install -y git
   git clone <your repository address> /root/siege && cd /root/siege
   ```
   (For a private ssh repository: `ssh-keygen -t ed25519`, add the public key to the repository as a read-only deploy key, then clone.)
3. **First installer run** creates the settings file and stops: `sudo ./deploy/install.sh` makes `/etc/siege-engine/siege.conf`. Edit it:
   ```
   REPO_URL="<your repository address>"       # the same address
   SERVERS_ONLY="yes"                          # servers only: no web build, no nginx, no importer, no update timer
   MASTER_SERVER="yes"                         # the game list and the parties, port 47710
   SERVER_INSTANCES="katabatic varuna:Varuna"  # two raids: name[:map]; the map defaults to the name with a capital letter
   DATA_DIR="/srv/siege/gamedata"
   ```
4. **Bring the game data.** The server needs the imported packs (it reads them, it never sends them to anybody). Import on your PC as usual, then copy the
   folders you need (at least `tribes2`) to the container:
   ```
   ssh root@192.0.2.50 mkdir -p /srv/siege/gamedata
   scp -r gamedata/tribes2 gamedata/tribes root@192.0.2.50:/srv/siege/gamedata/      # from the PC's repository folder
   ```
   and in the container, once the installer of step 5 has made the `siege` user, `chown -R siege:siege /srv/siege/gamedata && systemctl restart siege-server@katabatic siege-server@varuna`. (To import the disc images in the container instead, leave `SERVERS_ONLY` out and follow
   `docs/WEB_DEPLOY.md`; the same `SERVER_INSTANCES` still work.)
5. **Second installer run**: `sudo ./deploy/install.sh`. It installs the packages (git and the libraries the headless Godot needs), the service user,
   Godot 4.6.3 (checksum verified), the master service `siege-master`, and one `siege-server@<name>` service per instance. For each instance it creates
   `/etc/siege/<name>.json` from `deploy/server-extraction.json.example`: `katabatic` gets game UDP 47700 and match list TCP 47702, `varuna` gets 47720 and
   47722 (`SERVER_BASE_PORT` / `SERVER_PORT_STEP` change that), both registered with the master at `127.0.0.1:47710`. Edit the json files (`name`, `password`,
   `bots`, `ai`, `max_players`, the reset times), then `systemctl restart siege-server@katabatic siege-server@varuna`.
6. **Check**:
   ```
   systemctl status siege-master siege-server@katabatic siege-server@varuna
   journalctl -u siege-server@katabatic -f            # SERVER READY ... mode=extraction
   curl http://127.0.0.1:47702/matches                 # the Katabatic raid
   curl http://127.0.0.1:47710/servers                 # both raids listed on the master
   ```
7. **Ports** (LAN only: do not forward anything on the router; with the Proxmox firewall on for the container, allow these inbound from the LAN):

   | port | what |
   |---|---|
   | 47710/tcp | master: game list and parties |
   | 47700/udp, 47720/udp | the games (one per raid) |
   | 47702/tcp, 47722/tcp | the match lists (info and ping in the browser) |
   | 47701/udp | the servers' LAN broadcast (outbound from the container to the LAN; players listen on it) |

8. **Play.** On every PC: Options > Online > master server `192.0.2.50` (the port 47710 is assumed). Play tab > **Party** > Create online party: the code
   (five characters) is on the screen. The kids Join online party with that code. Everybody opens Operator Setup if they like (kit, armour), presses Ready; the
   leader picks the raid under Online games (or LAN games, which also lists them) and presses Go: the clients connect together and drop in on one
   transport. Alone, Play > Join LAN game lists the same two raids.
9. **Maintenance.** `sudo siege-servers-update` pulls the code and restarts the master and the raids (a raid in progress is cut: do it when nobody plays).
   Logs: `journalctl -u 'siege-server@*' -f`; each raid prints a `SERVER STATS` line every minute (tick time, RAM). Nothing on the container needs a backup
   except the json settings: pilots' stashes live on their own PCs.
