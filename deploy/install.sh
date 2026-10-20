#!/usr/bin/env bash
# Siege Engine browser server: installs everything on a fresh Debian 12+ / Ubuntu 22.04+ machine or LXC container.
#
#   sudo ./install.sh            (from the repository's deploy/ folder; safe to run again at any time)
#   sudo ./install.sh --build    ... and run the first update (import the discs, build, publish) right away
#
# First run: copies siege.conf.example to /etc/siege-engine/siege.conf and stops so you can edit it.
# Then it installs the packages (git, Python, ffmpeg, nginx), a service user, the repository checkout, the
# importer's Python environment, Godot (headless) with its web export templates (checksums verified), the
# nginx site and the systemd timer that runs deploy/siege-update.sh. Guide: docs/WEB_DEPLOY.md.
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"

BUILD_NOW=0
NGINX_SNIPPETS="/etc/nginx/siege-engine"
NGINX_SITE="/etc/nginx/sites-available/siege-engine"
TLS_DIR="/etc/siege-engine/tls"
WRAPPER="/usr/local/bin/siege-update"
PACKAGES=(git openssh-client ca-certificates curl unzip python3 python3-venv python3-pip python3-dev build-essential
	ffmpeg nginx openssl gzip fontconfig util-linux)
OPTIONAL_PACKAGES=(brotli libnginx-mod-http-brotli-static)

parse_args() {
	local arg
	for arg in "$@"; do
		case "$arg" in
			--build) BUILD_NOW=1 ;;
			-h|--help) sed -n '2,11p' "$0"; exit 0 ;;
			*) die "unknown option $arg (see --help)" ;;
		esac
	done
}

require_root() {
	[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
	command -v apt-get >/dev/null || die "this installer needs a Debian or Ubuntu system (apt-get)"
}

# ------------------------------------------------------------------ settings

ensure_conf() {
	if find_conf >/dev/null; then
		return 0
	fi
	install -d -m 755 "$(dirname "$SIEGE_CONF_DEFAULT")"
	install -m 600 "$DEPLOY_DIR/siege.conf.example" "$SIEGE_CONF_DEFAULT"
	log "created $SIEGE_CONF_DEFAULT from the example."
	log "edit it (at least REPO_URL and ISO_DIR), then run this script again."
	exit 0
}

# ------------------------------------------------------------------ system

install_packages() {
	log "installing packages"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q
	apt-get install -y -q "${PACKAGES[@]}"
	local pkg
	for pkg in "${OPTIONAL_PACKAGES[@]}"; do
		apt-get install -y -q "$pkg" >/dev/null 2>&1 || log "optional package $pkg is not available - skipped"
	done
}

create_user() {
	if ! id "$SERVICE_USER" >/dev/null 2>&1; then
		log "creating system user $SERVICE_USER"
		useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
	fi
	chgrp "$SERVICE_USER" "$SIEGE_CONF"
	chmod 640 "$SIEGE_CONF"
}

make_dirs() {
	install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 755 "$INSTALL_DIR" "$STATE_DIR" "$SITE_DIR" \
		"$APP_RELEASES" "$DATA_RELEASES"
	install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 750 "$DATA_DIR" "$WORK_DIR" "$LOG_DIR"
	[[ -d "$ISO_DIR" ]] || install -d -m 755 "$ISO_DIR"       # may be a (read-only) bind mount
	if ! runuser -u "$SERVICE_USER" -- test -r "$ISO_DIR" -a -x "$ISO_DIR"; then
		log "WARNING: $SERVICE_USER cannot read $ISO_DIR - see 'Permissions' in docs/WEB_DEPLOY.md"
	fi
}

as_service() {
	runuser -u "$SERVICE_USER" -- env HOME="$INSTALL_DIR" "$@"
}

# ------------------------------------------------------------------ code

is_ssh_url() {
	[[ "$REPO_URL" == ssh://* || "$REPO_URL" =~ ^[^/:]+@[^/:]+: ]]
}

# An ssh repository address needs a key: one is made for the service user and shown for the git host.
setup_git_access() {
	is_ssh_url || return 0
	local key="$INSTALL_DIR/.ssh/id_ed25519"
	if [[ ! -f "$key" ]]; then
		install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 700 "$INSTALL_DIR/.ssh"
		as_service ssh-keygen -q -t ed25519 -N "" -C "siege-engine-deploy" -f "$key"
	fi
	if ! as_service bash -c "$(declare -f siege_git); siege_git ls-remote --heads '$REPO_URL'" >/dev/null 2>&1; then
		log "the repository is not reachable with the deploy key yet. Add this public key to the repository"
		log "as a read-only deploy key (Gitea/GitHub: repository Settings > Deploy keys), then run this again:"
		cat "$key.pub"
		exit 1
	fi
}

clone_repo() {
	if [[ -d "$REPO_DIR/.git" ]]; then
		log "repository already cloned at $REPO_DIR (siege-update.sh keeps it current)"
		return 0
	fi
	log "cloning $BRANCH into $REPO_DIR"
	as_service bash -c "$(declare -f siege_git); siege_git clone --branch '$BRANCH' '$REPO_URL' '$REPO_DIR'"
}

setup_venv() {
	log "setting up the importer's Python environment"
	[[ -x "$VENV_DIR/bin/python" ]] || as_service python3 -m venv "$VENV_DIR"
	local reqs="$STATE_DIR/requirements.txt"
	# the build-only line (PyInstaller) is for the Windows release; pyopl is optional (FM music)
	grep -viE '^(pyinstaller|pyopl)\b' "$REPO_DIR/tools/requirements.txt" > "$reqs"
	chown "$SERVICE_USER:" "$reqs"
	as_service "$VENV_DIR/bin/pip" install -q --upgrade pip
	as_service "$VENV_DIR/bin/pip" install -q -r "$reqs"
	as_service "$VENV_DIR/bin/pip" install -q pyopl ||
		log "pyopl did not install - Earthsiege's FM music will be skipped by the importer"
}

# ------------------------------------------------------------------ Godot

godot_platform() {
	case "$(uname -m)" in
		x86_64) echo "linux.x86_64" ;;
		aarch64|arm64) echo "linux.arm64" ;;
		*) die "no Godot build for $(uname -m)" ;;
	esac
}

# Downloads $1 into the downloads folder and checks it against the pin $2 or the release's SHA512-SUMS.txt.
fetch_verified() {
	local name="$1" pin="$2" dl="$INSTALL_DIR/downloads"
	local base="$GODOT_RELEASE_URL/${GODOT_VERSION}-stable"
	install -d -m 755 "$dl"
	[[ -f "$dl/$name" ]] || curl -fL --retry 3 -o "$dl/$name" "$base/$name"
	[[ -f "$dl/SHA512-SUMS.txt" ]] || curl -fsSL --retry 3 -o "$dl/SHA512-SUMS.txt" "$base/SHA512-SUMS.txt"
	local want got
	want="${pin:-$(awk -v f="$name" '$2 == f {print $1}' "$dl/SHA512-SUMS.txt")}"
	[[ -n "$want" ]] || die "no checksum for $name in SHA512-SUMS.txt"
	got="$(sha512sum "$dl/$name" | cut -d' ' -f1)"
	if [[ "$got" != "$want" ]]; then
		rm -f "$dl/$name"
		die "checksum mismatch for $name (download removed; run again)"
	fi
	log "verified $name (SHA-512)"
}

install_godot() {
	local platform binary_zip templates
	platform="$(godot_platform)"
	binary_zip="Godot_v${GODOT_VERSION}-stable_${platform}.zip"
	templates="Godot_v${GODOT_VERSION}-stable_export_templates.tpz"
	if [[ ! -x "$GODOT_BIN" || "$("$GODOT_BIN" --version 2>/dev/null)" != "${GODOT_VERSION}.stable"* ]]; then
		log "installing Godot $GODOT_VERSION ($platform)"
		fetch_verified "$binary_zip" "$GODOT_SHA512"
		install -d -m 755 "$GODOT_DIR"
		unzip -o -q "$INSTALL_DIR/downloads/$binary_zip" -d "$GODOT_DIR"
		chmod 755 "$GODOT_DIR/Godot_v${GODOT_VERSION}-stable_${platform}"
		ln -sfn "$GODOT_DIR/Godot_v${GODOT_VERSION}-stable_${platform}" "$GODOT_BIN"
	fi
	if [[ ! -f "$TEMPLATES_DIR/web_nothreads_release.zip" ]]; then
		log "installing the Godot web export templates"
		fetch_verified "$templates" "$TEMPLATES_SHA512"
		install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 755 "$TEMPLATES_DIR"
		unzip -o -q -j "$INSTALL_DIR/downloads/$templates" 'templates/web_*' 'templates/version.txt' -d "$TEMPLATES_DIR"
	fi
	chown -R "$SERVICE_USER:" "$INSTALL_DIR/.local"     # Godot writes its editor data under the service user's home
}

# ------------------------------------------------------------------ web server

write_auth_snippet() {
	local file="$NGINX_SNIPPETS/server-auth.conf"
	if [[ -z "$BASIC_AUTH_USER" || -z "$BASIC_AUTH_PASSWORD" ]]; then
		rm -f "$file" "$NGINX_SNIPPETS/htpasswd"
		return 0
	fi
	printf '%s:%s\n' "$BASIC_AUTH_USER" "$(openssl passwd -apr1 -stdin <<< "$BASIC_AUTH_PASSWORD")" \
		> "$NGINX_SNIPPETS/htpasswd"
	chown root:www-data "$NGINX_SNIPPETS/htpasswd"
	chmod 640 "$NGINX_SNIPPETS/htpasswd"
	printf 'auth_basic "Siege Engine";\nauth_basic_user_file %s/htpasswd;\n' "$NGINX_SNIPPETS" > "$file"
}

write_tls_snippet() {
	local file="$NGINX_SNIPPETS/server-tls.conf" cert="$TLS_CERT" key="$TLS_KEY"
	case "$TLS_MODE" in
		off) rm -f "$file"; return 0 ;;
		self-signed)
			cert="$TLS_DIR/siege.crt"
			key="$TLS_DIR/siege.key"
			if [[ ! -f "$cert" ]]; then
				install -d -m 700 "$TLS_DIR"
				openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname -f)" \
					-keyout "$key" -out "$cert" 2>/dev/null
			fi ;;
		files) [[ -f "$cert" && -f "$key" ]] || die "TLS_MODE=files needs TLS_CERT and TLS_KEY" ;;
		*) die "TLS_MODE must be off, self-signed or files" ;;
	esac
	printf 'listen %s ssl;\nlisten [::]:%s ssl;\nssl_certificate %s;\nssl_certificate_key %s;\n' \
		"$TLS_PORT" "$TLS_PORT" "$cert" "$key" > "$file"
}

write_brotli_snippet() {
	local file="$NGINX_SNIPPETS/server-brotli.conf"
	if ls /etc/nginx/modules-enabled/*brotli* >/dev/null 2>&1; then
		echo "brotli_static on;" > "$file"
	else
		rm -f "$file"
	fi
}

render() {
	sed -e "s|@HTTP_PORT@|$HTTP_PORT|g" -e "s|@SITE_DIR@|$SITE_DIR|g" -e "s|@SNIPPET_DIR@|$NGINX_SNIPPETS|g" \
		-e "s|@SERVICE_USER@|$SERVICE_USER|g" -e "s|@SIEGE_CONF@|$SIEGE_CONF|g" -e "s|@REPO_DIR@|$REPO_DIR|g" \
		-e "s|@UPDATE_INTERVAL@|$UPDATE_INTERVAL|g" -e "s|@GODOT_BIN@|$GODOT_BIN|g" -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" 		-e "s|@DATA_DIR@|$DATA_DIR|g" -e "s|@GAME_SERVER_CONFIG@|$GAME_SERVER_CONFIG|g" 		-e "s|@GAME_SERVER_PORT@|$GAME_SERVER_PORT|g" -e "s|@GAME_SERVER_LIST_PORT@|$GAME_SERVER_LIST_PORT|g" "$1" > "$2"
}

setup_nginx() {
	log "configuring nginx on port $HTTP_PORT"
	install -d -m 755 "$NGINX_SNIPPETS"
	write_auth_snippet
	write_tls_snippet
	write_brotli_snippet
	render "$REPO_DIR/deploy/nginx-site.conf.template" "$NGINX_SITE"
	ln -sfn "$NGINX_SITE" /etc/nginx/sites-enabled/siege-engine
	if [[ "$HTTP_PORT" == 80 ]]; then
		rm -f /etc/nginx/sites-enabled/default        # the stock page would take port 80
	fi
	nginx -t
	systemctl enable nginx >/dev/null
	systemctl reload-or-restart nginx
}

# ------------------------------------------------------------------ game server (optional)

# GAME_SERVER=yes: the dedicated server as a systemd service, and /ws + /matches in the nginx site.
setup_game_server() {
	local snippet="$NGINX_SNIPPETS/server-game.conf"
	if [[ "$GAME_SERVER" != yes ]]; then
		rm -f "$snippet"
		systemctl disable --now siege-server.service >/dev/null 2>&1 || true
		return 0
	fi
	log "configuring the game server (ports $GAME_SERVER_PORT / $GAME_SERVER_LIST_PORT)"
	if [[ ! -f "$GAME_SERVER_CONFIG" ]]; then
		install -d -m 755 "$(dirname "$GAME_SERVER_CONFIG")"
		install -m 640 -g "$SERVICE_USER" "$REPO_DIR/deploy/server.json.example" "$GAME_SERVER_CONFIG"
		log "created $GAME_SERVER_CONFIG from the example - edit it (name, map, mode, password)"
	fi
	render "$REPO_DIR/deploy/nginx-game.conf.template" "$snippet"
	render "$REPO_DIR/deploy/systemd/siege-server.service.template" /etc/systemd/system/siege-server.service
	systemctl daemon-reload
	systemctl enable siege-server.service >/dev/null
	systemctl restart siege-server.service
	nginx -t
	systemctl reload nginx
}

# ------------------------------------------------------------------ updates

setup_systemd() {
	log "installing the update timer (every $UPDATE_INTERVAL)"
	render "$REPO_DIR/deploy/systemd/siege-update.service.template" /etc/systemd/system/siege-update.service
	render "$REPO_DIR/deploy/systemd/siege-update.timer.template" /etc/systemd/system/siege-update.timer
	systemctl daemon-reload
	systemctl enable --now siege-update.timer >/dev/null
	cat > "$WRAPPER" <<-EOF
		#!/bin/sh
		# Runs one Siege Engine update as $SERVICE_USER (options: --force, --no-fetch). Installed by deploy/install.sh.
		exec runuser -u $SERVICE_USER -- env HOME=$INSTALL_DIR SIEGE_CONF=$SIEGE_CONF $REPO_DIR/deploy/siege-update.sh "\$@"
	EOF
	chmod 755 "$WRAPPER"
}

print_summary() {
	local ip
	ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
	log "done."
	log "  disc images:  $ISO_DIR"
	log "  build now:    sudo siege-update --force      (log: $LOG_DIR/update.log)"
	log "  then open:    http://${ip:-<this machine>}:$HTTP_PORT/"
	[[ "$GAME_SERVER" == yes ]] && log "  game server:  ws://${ip:-<this machine>}:$HTTP_PORT/ws   (list: /matches; settings: $GAME_SERVER_CONFIG)"
	return 0
}

main() {
	parse_args "$@"
	require_root
	ensure_conf
	load_conf
	install_packages
	create_user
	make_dirs
	setup_git_access
	clone_repo
	setup_venv
	install_godot
	setup_nginx
	setup_game_server
	setup_systemd
	print_summary
	if (( BUILD_NOW )); then
		"$WRAPPER" --force
	fi
}

main "$@"
