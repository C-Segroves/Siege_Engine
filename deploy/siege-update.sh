#!/usr/bin/env bash
# Siege Engine browser server: one update run (systemd timer siege-update.timer, or by hand).
#
#   siege-update.sh [--force] [--no-fetch]
#
#   1. git fetch; new commits on BRANCH are checked out (the checkout belongs to this script:
#      local edits in it are discarded).
#   2. The disc images in ISO_DIR (and SOUNDTRACK_DIR) are fingerprinted (names, sizes, times).
#   3. Whatever is out of date is rebuilt: the discs are imported again (changed discs, or new code when
#      REIMPORT_ON_CODE_CHANGE=yes), the game data is packed for the browser, the web build is exported with
#      Godot, and the served links are swapped atomically (data first, then the app).
#      What was last built is recorded in STATE_DIR, so a run that failed half-way is completed by the next.
#   --force rebuilds everything; --no-fetch skips step 1.
#
# Settings: siege.conf (see siege.conf.example). Log: LOG_DIR/update.log and the systemd journal.
# Only one run at a time (lock file); a run that finds the lock taken exits at once.
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "$(dirname "$SELF")/lib/common.sh"

FORCE=0
FETCH=1
IMPORT_FAILED=0
STAMP="$(date '+%Y%m%d-%H%M%S')"

parse_args() {
	local arg
	for arg in "$@"; do
		case "$arg" in
			--force) FORCE=1 ;;
			--no-fetch) FETCH=0 ;;
			-h|--help) sed -n '2,16p' "$SELF"; exit 0 ;;
			*) die "unknown option $arg (see --help)" ;;
		esac
	done
}

start_log() {
	mkdir -p "$LOG_DIR" "$STATE_DIR"
	[[ -z "${SIEGE_LOGGING:-}" ]] || return 0     # a re-run of this script already writes into the log
	export SIEGE_LOGGING=1
	exec > >(tee -a "$LOG_DIR/update.log") 2>&1
}

take_lock() {
	exec 9>"$STATE_DIR/update.lock"
	if ! flock -n 9; then
		log "another update is running - nothing to do"
		exit 0
	fi
}

# ------------------------------------------------------------------ code

sync_code() {
	[[ -d "$REPO_DIR/.git" ]] || die "no checkout at $REPO_DIR - run deploy/install.sh first"
	(( FETCH )) || return 0
	log "fetching $BRANCH"
	siege_git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
	local here there
	here="$(git -C "$REPO_DIR" rev-parse HEAD)"
	there="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"
	[[ "$here" != "$there" ]] || return 0
	log "new commits: ${here:0:10} -> ${there:0:10}"
	git -C "$REPO_DIR" checkout --quiet -B "$BRANCH" "origin/$BRANCH"
	git -C "$REPO_DIR" reset --quiet --hard "origin/$BRANCH"
	if ! git -C "$REPO_DIR" diff --quiet "$here" "$there" -- deploy/; then
		log "the deploy scripts changed - continuing with the new version"
		local rerun=(--no-fetch)
		if (( FORCE )); then
			rerun+=(--force)
		fi
		exec "$SELF" "${rerun[@]}"
	fi
}

# ------------------------------------------------------------------ discs

disc_fingerprint() {
	local dir
	for dir in "$ISO_DIR" "$SOUNDTRACK_DIR"; do
		if [[ -n "$dir" && -d "$dir" ]]; then
			find -L "$dir" -type f -printf '%P\t%s\t%T@\n'
		fi
	done | sort | sha256sum | cut -d' ' -f1
}

# What the imported data depends on: the discs, and the code too when REIMPORT_ON_CODE_CHANGE=yes.
make_import_key() {
	[[ -d "$ISO_DIR" ]] || die "ISO_DIR $ISO_DIR does not exist"
	local key
	key="discs $(disc_fingerprint)"
	if [[ "$REIMPORT_ON_CODE_CHANGE" == yes ]]; then
		key+=" code $(git -C "$REPO_DIR" rev-parse HEAD)"
	fi
	printf '%s\n' "$key"
}

# STATE_DIR/<name>: the key of what was last built (empty when never).
read_state() {
	cat "$STATE_DIR/$1" 2>/dev/null || true
}

write_state() {
	printf '%s\n' "$2" > "$STATE_DIR/$1"
}

import_discs() {
	local key="$1"
	log "importing discs from $ISO_DIR (packs: $IMPORT_PACKS)"
	mkdir -p "$DATA_DIR" "$WORK_DIR"
	local args=(--python "$VENV_DIR/bin/python" --importer "$REPO_DIR/tools/siege_import.py"
		--iso-dir "$ISO_DIR" --out "$DATA_DIR" --packs "$IMPORT_PACKS")
	[[ -n "$SOUNDTRACK_DIR" ]] && args+=(--soundtracks "$SOUNDTRACK_DIR")
	if ! TMPDIR="$WORK_DIR" "$VENV_DIR/bin/python" "$REPO_DIR/deploy/import_discs.py" "${args[@]}"; then
		IMPORT_FAILED=1
		log "some imports failed - the other packs are still published (details above)"
	fi
	write_state imported.key "$key"       # also after a partial failure: retried when discs or code change
}

# ------------------------------------------------------------------ build

godot() {
	HOME="$INSTALL_DIR" "$GODOT_BIN" --headless --audio-driver Dummy --path "$REPO_DIR/game" "$@"
}

build_data() {
	local key="$1" out="$DATA_RELEASES/$STAMP"
	log "packing game data for the browser -> $out"
	godot --script res://tools/web/pack_gamedata.gd -- \
		--data="$DATA_DIR" --out="$out" --packs="$(make_pack_csv "$WEB_PACKS")"
	[[ -f "$out/packs.json" ]] || die "packing the game data failed"
	compress_dir "$out"
	publish "$out" "$DATA_CURRENT"
	write_state packed.key "$key"
}

build_app() {
	local key="$1" out="$APP_RELEASES/$STAMP"
	log "exporting the web build -> $out"
	mkdir -p "$out"
	godot --import || true                        # first run on a fresh checkout: build the import cache
	godot --export-release "Web" "$out/index.html"
	[[ -f "$out/index.wasm" ]] || die "the Godot web export failed (no index.wasm)"
	compress_dir "$out"
	publish "$out" "$APP_CURRENT"
	write_state app.key "$key"
}

# gzip (and brotli, when installed) copies next to the files, served by nginx gzip_static / brotli_static.
compress_dir() {
	[[ "$COMPRESS" == "yes" ]] || return 0
	log "compressing $1"
	local file
	while IFS= read -r -d '' file; do
		gzip -6 -k -f "$file"
		if command -v brotli >/dev/null; then
			brotli -q 5 -k -f "$file"
		fi
	done < <(find "$1" -type f \( -name '*.wasm' -o -name '*.pck' -o -name '*.js' -o -name '*.json' -o -name '*.html' \) -print0)
}

# Points the served link at a finished build in one rename, so a page load never sees half a build.
publish() {
	local target="$1" link="$2"
	ln -sfn "$target" "$link.new"
	mv -Tf "$link.new" "$link"
	log "published $link -> $target"
}

# Keeps the newest KEEP_RELEASES builds in a releases folder (never the published one).
prune() {
	local dir="$1" current
	current="$(readlink -f "$2" 2>/dev/null || true)"
	find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n "+$((KEEP_RELEASES + 1))" |
		while IFS= read -r old; do
			[[ "$dir/$old" == "$current" ]] || rm -rf "${dir:?}/$old"
		done
}

# ------------------------------------------------------------------ main

main() {
	parse_args "$@"
	load_conf
	start_log
	take_lock
	log "update run (config $SIEGE_CONF)"
	sync_code
	local import_key data_key app_key built=0
	import_key="$(make_import_key)"
	app_key="$(git -C "$REPO_DIR" rev-parse HEAD)"
	if (( FORCE )) || [[ "$import_key" != "$(read_state imported.key)" || -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
		import_discs "$import_key"
	fi
	data_key="$(read_state imported.key) packs $WEB_PACKS"
	if (( FORCE )) || [[ "$data_key" != "$(read_state packed.key)" || ! -e "$DATA_CURRENT" ]]; then
		build_data "$data_key"
		built=1
	fi
	if (( FORCE )) || [[ "$app_key" != "$(read_state app.key)" || ! -e "$APP_CURRENT" ]]; then
		build_app "$app_key"
		built=1
	fi
	if (( !built )); then
		log "nothing changed"
	fi
	prune "$DATA_RELEASES" "$DATA_CURRENT"
	prune "$APP_RELEASES" "$APP_CURRENT"
	log "update run finished"
	return "$IMPORT_FAILED"
}

main "$@"
exit $?
