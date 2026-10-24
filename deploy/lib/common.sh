# Shared helpers for deploy/install.sh and deploy/siege-update.sh (sourced, not run).
# shellcheck shell=bash disable=SC2034 # the settings and paths are used by the scripts that source this

# Where siege.conf is looked for, first match wins: $SIEGE_CONF, /etc/siege-engine/siege.conf,
# deploy/siege.conf next to these scripts (git-ignored).
SIEGE_CONF_DEFAULT="/etc/siege-engine/siege.conf"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
	printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
	log "ERROR: $*" >&2
	exit 1
}

find_conf() {
	local candidate
	for candidate in "${SIEGE_CONF:-}" "$SIEGE_CONF_DEFAULT" "$DEPLOY_DIR/siege.conf"; do
		if [[ -n "$candidate" && -f "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

# Loads siege.conf and fills in the defaults of siege.conf.example for anything left out.
load_conf() {
	local conf
	conf="$(find_conf)" || die "no siege.conf found (looked at \$SIEGE_CONF, $SIEGE_CONF_DEFAULT, $DEPLOY_DIR/siege.conf)"
	# shellcheck source=/dev/null # siege.conf: see siege.conf.example
	source "$conf"
	SIEGE_CONF="$conf"
	: "${REPO_URL:?REPO_URL is not set in $conf}"
	BRANCH="${BRANCH:-main}"
	INSTALL_DIR="${INSTALL_DIR:-/opt/siege-engine}"
	ISO_DIR="${ISO_DIR:-/srv/siege/iso}"
	SOUNDTRACK_DIR="${SOUNDTRACK_DIR:-}"
	DATA_DIR="${DATA_DIR:-/srv/siege/gamedata}"
	WORK_DIR="${WORK_DIR:-/srv/siege/work}"
	SITE_DIR="${SITE_DIR:-/srv/siege/site}"
	LOG_DIR="${LOG_DIR:-/var/log/siege-engine}"
	SERVICE_USER="${SERVICE_USER:-siege}"
	IMPORT_PACKS="${IMPORT_PACKS:-all}"
	WEB_PACKS="${WEB_PACKS:-all}"
	REIMPORT_ON_CODE_CHANGE="${REIMPORT_ON_CODE_CHANGE:-yes}"
	KEEP_RELEASES="${KEEP_RELEASES:-2}"
	COMPRESS="${COMPRESS:-yes}"
	UPDATE_INTERVAL="${UPDATE_INTERVAL:-15min}"
	HTTP_PORT="${HTTP_PORT:-8080}"
	BASIC_AUTH_USER="${BASIC_AUTH_USER:-}"
	BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"
	TLS_MODE="${TLS_MODE:-off}"
	TLS_PORT="${TLS_PORT:-8443}"
	TLS_CERT="${TLS_CERT:-}"
	TLS_KEY="${TLS_KEY:-}"
	GAME_SERVER="${GAME_SERVER:-no}"
	GAME_SERVER_CONFIG="${GAME_SERVER_CONFIG:-/etc/siege-engine/server.json}"
	GAME_SERVER_PORT="${GAME_SERVER_PORT:-47700}"
	GAME_SERVER_LIST_PORT="${GAME_SERVER_LIST_PORT:-47702}"
	SERVERS_ONLY="${SERVERS_ONLY:-no}"
	SERVER_INSTANCES="${SERVER_INSTANCES:-}"
	SERVERS_DIR="${SERVERS_DIR:-/etc/siege}"
	SERVER_BASE_PORT="${SERVER_BASE_PORT:-47700}"
	SERVER_PORT_STEP="${SERVER_PORT_STEP:-20}"
	MASTER_SERVER="${MASTER_SERVER:-no}"
	MASTER_CONFIG="${MASTER_CONFIG:-/etc/siege-engine/master.json}"
	MASTER_PORT="${MASTER_PORT:-47710}"
	GODOT_VERSION="${GODOT_VERSION:-4.6.3}"
	GODOT_RELEASE_URL="${GODOT_RELEASE_URL:-https://github.com/godotengine/godot/releases/download}"
	GODOT_SHA512="${GODOT_SHA512:-}"
	TEMPLATES_SHA512="${TEMPLATES_SHA512:-}"
	derive_paths
}

# Paths that follow from the settings (one place, used by both scripts).
derive_paths() {
	REPO_DIR="$INSTALL_DIR/repo"
	VENV_DIR="$INSTALL_DIR/venv"
	GODOT_DIR="$INSTALL_DIR/godot"
	GODOT_BIN="$GODOT_DIR/godot"
	STATE_DIR="$INSTALL_DIR/state"
	# Godot looks for export templates under $HOME; the service user's home is INSTALL_DIR.
	TEMPLATES_DIR="$INSTALL_DIR/.local/share/godot/export_templates/${GODOT_VERSION}.stable"
	APP_RELEASES="$SITE_DIR/app"
	DATA_RELEASES="$SITE_DIR/data"
	APP_CURRENT="$SITE_DIR/app-current"
	DATA_CURRENT="$SITE_DIR/data-current"
}

# "es1 bd" or "es1,bd" -> "es1,bd"; "all" stays "all".
make_pack_csv() {
	local list="${1//,/ }"
	# shellcheck disable=SC2086 # word splitting is the point
	set -- $list
	local IFS=,
	printf '%s\n' "$*"
}

# git with the deploy key (if install.sh made one) and new host keys accepted on first contact.
siege_git() {
	GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes" git "$@"
}
