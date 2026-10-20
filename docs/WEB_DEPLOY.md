# Playing Siege Engine in a browser (self-hosted)

This guide sets up a small Linux server that:

- turns **your** disc images into game data;
- builds the browser version of Siege Engine with headless Godot;
- serves it on your network.

The guide uses a Proxmox LXC container (CT) as the example, but any Debian 12+ / Ubuntu 22.04+ machine works.
Once it is running, the server checks the git repository on a timer. When new commits land, or when you add or
replace disc images, it pulls the code, re-imports the discs, rebuilds and swaps the site over without downtime.

> **Legal note.** The served site contains game data extracted from *your own* discs. Keep it private: your LAN,
> a VPN, or at least the password option (`BASIC_AUTH_*`). Never expose it to the public internet. The
> repository itself holds only code; the server's settings (`siege.conf`), the imported data and the built
> site stay on the server and are never committed.

## Contents
1. [How it works](#1-how-it-works)
2. [Create the container](#2-create-the-container)
3. [Put the disc images on it](#3-put-the-disc-images-on-it)
4. [Install, configure, first build](#4-install-configure-first-build)
5. [Play](#5-play)
6. [How updates work](#6-how-updates-work)
7. [Running things by hand](#7-running-things-by-hand)
8. [Troubleshooting](#8-troubleshooting)
9. [Testing a web build on a development PC](#9-testing-a-web-build-on-a-development-pc)

## 1. How it works

```
ISO_DIR (*.iso, *.cue/*.bin)
  │  deploy/import_discs.py → tools/siege_import.py        (Python venv, same importer as the desktop app)
  ▼
DATA_DIR/<pack>/...                                         (imported game data, private)
  │  game/tools/web/pack_gamedata.gd  (headless Godot, PCKPacker)
  ▼
SITE_DIR/data/<build>/<pack>.pck + packs.json  ──►  SITE_DIR/data-current  ──►  http://server:PORT/data/
git checkout (INSTALL_DIR/repo)
  │  godot --export-release "Web"   (game/export_presets.cfg)
  ▼
SITE_DIR/app/<build>/index.html, index.wasm, index.pck ... ──►  SITE_DIR/app-current ──►  http://server:PORT/
```

**Design choices**

- **Game data in the browser.** The engine reads game data the same way as on desktop: `FileAccess`,
  `DirAccess` listings, JSON indexes, PNG/OGG files, all under `Assets.data_root`. In the browser:
  - Each imported pack becomes one `.pck` file whose files sit at `res://gamedata/<pack>/...`.
  - The page shell (`game/web/siege_shell.html`) lets the player pick which games to load.
  - The shell downloads the chosen packs, with a progress bar, and keeps them in the browser's IndexedDB,
    keyed by their SHA-256. A pack is downloaded again only after the server re-imported it.
  - Before the engine starts, the shell copies the packs into the engine's in-memory file system.
  - At startup `WebPlatform.mount_packs()` (`game/engine/web_platform.gd`) mounts them, and `Assets.data_root`
    becomes `res://gamedata`.
  - The desktop path is unchanged.
- **No threads.** The Web preset uses Godot's single-threaded build (`variant/thread_support=false`). It works
  over plain `http://` on a LAN and needs no cross-origin isolation. A threaded build would need
  `SharedArrayBuffer`, which browsers allow only on https or localhost pages with COOP/COEP headers. nginx
  sends those headers anyway, so a threaded build could be switched on later (with `TLS_MODE`).
- **Sound start gate.** Browsers allow sound only after a click on the page. The **Start** button on the pack
  picker is that click.
- **No LAN play in the browser.** Browsers cannot open ENet (UDP) sockets or listen for connections. The browser
  version therefore plays solo:
  - campaigns, the original Earthsiege shell, skirmish/training/extraction and the shape viewer all work;
  - **Arena / versus** runs as a local session against AI (`Net.host()` uses a local peer on the web);
  - *Host LAN game* and *Co-op missions* are disabled, with a note;
  - *Join online game* joins a game server over WebSocket and lists the matches of the server that served the
    page. The server is optional (`GAME_SERVER="yes"` in `siege.conf`, or the container profiles): see
    [SERVER_DEPLOY.md](SERVER_DEPLOY.md).
- **Disabled in the browser.** Importing discs, adding soundtrack folders, removing packs and choosing a data
  folder all happen on the server. The buttons are disabled and say why.

## 2. Create the container

In the Proxmox web UI: **Create CT**.

| Setting | Recommendation |
|---|---|
| Template | Debian 12 (bookworm) or Ubuntu 24.04 standard |
| Unprivileged container | yes (works fine) |
| Disk | 40 GB plus the size of your disc images if you copy them in (not needed with a bind mount, see below) |
| CPU | 2–4 cores (imports and the Godot export are single-threaded per step; more cores mostly help ffmpeg) |
| Memory | 4 GB minimum; 8 GB if you import Tribes 2 or Starsiege |
| Network | a fixed IP (DHCP reservation or static) so the address stays the same |

The disk holds imported data (all six games together about 1.5 GB), the packed copy for the browser (about the
same) and one previous build, plus the import scratch space while an import runs.

Start the CT and open its console (or `ssh root@<ct-ip>`).

## 3. Put the disc images on it

The importer reads `.iso` files, or `.cue` + `.bin` images (which can carry CD audio). For CD audio with a plain
`.iso`, put the ripped tracks in a folder named like the `.iso`, next to it (see "Discs with CD audio" in the
README). Optional ripped soundtracks go in `SOUNDTRACK_DIR`, one sub-folder per game. Discs of games the
importer does not know are skipped.

**Option A: copy them in.** Create the folder from `ISO_DIR` in your `siege.conf` (default `/srv/siege/iso`),
then copy from your PC:

```sh
# on the CT
mkdir -p /srv/siege/iso
# on your PC (Linux/macOS/Windows with OpenSSH)
scp /path/to/your/isos/*.iso root@<ct-ip>:/srv/siege/iso/
```

**Option B: bind-mount a folder of the Proxmox host** (no copy; read-only is enough). On the Proxmox host:

```sh
pct set <ctid> -mp0 /path/on/host/isos,mp=/srv/siege/iso,ro=1
pct reboot <ctid>
```

**Permissions.** In an unprivileged CT, host files show up as owned by `nobody`. The service user can still
read them if they are world-readable on the host:

```sh
chmod -R o+rX /path/on/host/isos
```

`install.sh` warns when the service user cannot read `ISO_DIR`.

After adding or replacing disc images there is nothing else to do. The next timer run notices the change (file
names, sizes, times) and re-imports.

## 4. Install, configure, first build

1. **Get the `deploy/` folder onto the CT.** Either clone the repository once by hand, or copy the folder from
   your PC:

   ```sh
   apt-get update && apt-get install -y git
   git clone <your repository URL> /root/siege-src     # asks for your git credentials once
   cd /root/siege-src/deploy
   ```

   or `scp -r deploy root@<ct-ip>:/root/siege-deploy` and then `cd /root/siege-deploy`.
2. **First run.** This creates the settings file and stops:

   ```sh
   ./install.sh
   ```
3. **Edit `/etc/siege-engine/siege.conf`** (`nano /etc/siege-engine/siege.conf`). Every setting is explained in
   the file. At least set:
   - `REPO_URL`: the repository the server pulls from. Use an ssh address such as
     `git@your-git-host:owner/Siege_Engine.git` for a private repository.
   - `ISO_DIR`: where the disc images are.
   - Optionally:
     - `IMPORT_PACKS` / `WEB_PACKS`: which games to import and offer;
     - `HTTP_PORT`;
     - `UPDATE_INTERVAL`;
     - `BASIC_AUTH_USER` + `BASIC_AUTH_PASSWORD`;
     - `TLS_MODE`.

   The file is readable only by root and the service user, and it is never committed. The repository only
   carries `deploy/siege.conf.example`.
4. **Run the installer again:**

   ```sh
   ./install.sh
   ```

   It installs:
   - git, Python 3 + venv, ffmpeg and nginx;
   - the service user (`siege`);
   - the checkout in `INSTALL_DIR/repo`;
   - the importer's Python packages;
   - Godot `GODOT_VERSION` (headless) and its web export templates. Both downloads are checked against the
     release's `SHA512-SUMS.txt`, or against your `GODOT_SHA512` / `TEMPLATES_SHA512` pins;
   - the nginx site;
   - the `siege-update.timer`.

   With an ssh `REPO_URL` the installer first creates a key and stops if the repository refuses it. It prints
   the public key: add it to the repository as a **read-only deploy key** (Gitea: repository → Settings → Deploy
   keys), then run `./install.sh` once more.
5. **First build.** It imports every disc, so this takes a while; Tribes 2 and Starsiege are the slow ones.

   ```sh
   siege-update --force
   ```

   You can also run `./install.sh --build` in step 4. Progress goes to the terminal and to
   `/var/log/siege-engine/update.log`.

`install.sh` can be run again at any time, for example after changing `siege.conf`: it re-renders the nginx
site and the timer and keeps everything else.

## 5. Play

Open `http://<ct-ip>:<HTTP_PORT>/` (default port 8080) in a desktop browser: Chrome, Edge or Firefox, with
WebGL 2.

1. Tick the games to load and press **Start**. The first time, the chosen packs download: Earthsiege is about
   90 MB, Battledrome 40 MB, Starsiege 300 MB, Tribes 2 600 MB. After that they load from the browser's
   storage and download again only when the server rebuilt them.
2. All chosen packs are held in the browser's memory while you play. Pick only the games you want, especially
   on machines with little RAM.
3. Click into the game to capture the mouse (Esc releases it).

**Sound over plain http.** Pages served over http from another machine are not a "secure context". Some
browsers then disable the audio worklet Godot prefers. If you hear nothing, set `TLS_MODE="self-signed"`,
re-run `install.sh` and use `https://<ct-ip>:<TLS_PORT>/`. Accept the certificate warning once.

## 6. How updates work

`siege-update.timer` runs `deploy/siege-update.sh` as the service user every `UPDATE_INTERVAL` (and two
minutes after boot). Each run:

1. **Takes a lock.** If a run is already going, the new one exits at once.
2. **Fetches the code.** `git fetch` on `BRANCH`. New commits are checked out with a hard reset: the checkout
   belongs to the server, so edits made in it are discarded. If the commits changed `deploy/` itself, the run
   restarts with the new script.
3. **Fingerprints the discs** in `ISO_DIR` and `SOUNDTRACK_DIR` (names, sizes, modification times).
4. **Rebuilds what is needed:**
   - **Re-import** when the discs changed, on new commits (if `REIMPORT_ON_CODE_CHANGE="yes"`, the default:
     importer fixes reach your data automatically), or when `DATA_DIR` is empty. A failed game keeps its
     previous data; the run reports the failure and carries on with the rest.
   - **Pack** the imported games for the browser into `SITE_DIR/data/<time>/`.
   - **Export** the web build into `SITE_DIR/app/<time>/` on new commits.
   - **Compress**: gzip copies (and brotli, if installed) for nginx to serve.
5. **Publishes atomically.** `data-current` and `app-current` are symlinks, each replaced with a single rename.
   The data goes first, then the app, so a page load never sees half a build. Older builds beyond
   `KEEP_RELEASES` are deleted.
6. **Logs everything** to `LOG_DIR/update.log` and the systemd journal.

Players get the new version on their next page load. The page re-downloads only the packs whose content
changed.

## 7. Running things by hand

| What | Command |
|---|---|
| Update now (only what changed) | `siege-update` |
| Rebuild everything (re-import too) | `siege-update --force` |
| Rebuild without pulling | `siege-update --no-fetch --force` |
| Timer state / next run | `systemctl list-timers siege-update.timer` |
| Last runs | `journalctl -u siege-update -n 200` or `less /var/log/siege-engine/update.log` |
| Pause automatic updates | `systemctl disable --now siege-update.timer` (enable again with `enable --now`) |
| Apply changed settings | edit `/etc/siege-engine/siege.conf`, then `./install.sh` from `INSTALL_DIR/repo/deploy` |
| Roll back to the previous build | `ln -sfn /srv/siege/site/app/<older> /srv/siege/site/app-current` (same for `data`) |
| Import one disc by hand | `sudo -u siege /opt/siege-engine/venv/bin/python /opt/siege-engine/repo/tools/siege_import.py import --out /srv/siege/gamedata /srv/siege/iso/<disc>.iso` |

The paths above are the defaults from `siege.conf.example`.

## 8. Troubleshooting

- **The page says "No game data has been published".** No import has succeeded yet. Check the log for
  `skip <disc>: ...` lines: the disc was not recognised, or is not in `IMPORT_PACKS`. Also check that the
  service user can read `ISO_DIR` (section 3).
- **An import fails.** The log names the importer's own log file: `WORK_DIR/siege-import-<pack>.log`, which
  holds the converter output. Run the import by hand (section 7) to see it live.
- **`the Godot web export failed`.**
  - The project must match `GODOT_VERSION` (see `game/project.godot` / the README).
  - The templates must be in `INSTALL_DIR/.local/share/godot/export_templates/<version>.stable/`; re-run
    `install.sh` to fetch them.
  - Script errors in the log mean the pulled commit does not compile; the previous build stays online.
- **Blank page / "missing features".** The browser needs WebGL 2 and WebAssembly. Make sure hardware
  acceleration is on.
- **No sound.** Click **Start** (the browser gate), then see "Sound over plain http" in section 5.
- **"could not mount game data" in the browser console.** A pack download was cut short. Clear the site's
  storage (browser settings → site data) and reload.
- **The browser runs out of memory.** Load fewer games at once (Tribes 2 alone is about 600 MB).
- **`git fetch` fails.** The deploy key was removed, or the repository address changed. Re-run `install.sh`; it
  shows the key and tests access.
- **Port in use.** Change `HTTP_PORT` and re-run `install.sh`.

## 9. Testing a web build on a development PC

Use any OS, with the Godot 4.6 editor (console build on Windows):

```sh
# pack imported data (here the checkout's gamedata/) for the browser
godot --headless --audio-driver Dummy --path game --script res://tools/web/pack_gamedata.gd -- \
      --data=<repo>/gamedata --out=build/web/data --packs=es1,bd
# export the web build (the preset writes to build/web/ by default; both folders are git-ignored)
godot --headless --audio-driver Dummy --path game --export-release "Web" <repo>/build/web/index.html
# serve it on http://127.0.0.1:8060/ with the same headers as the server
python deploy/serve_local.py --root build/web
```

The Web export templates must be installed in the editor (Editor → Manage Export Templates).
