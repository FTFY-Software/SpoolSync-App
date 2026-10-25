#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# SpoolSync installation wizard
#
# Prompts for configuration, writes .env, builds/starts the Docker Compose
# stack and creates the initial admin account.
#
# Requirements: bash 4+, Docker Engine with the Compose v2 plugin (or
# docker-compose), and a user allowed to talk to the Docker daemon.
#
# Usage: ./install.sh [--yes] [--no-start] [--help]
#
# Any setting can be preset through the environment, e.g.
#   FRONTEND_PORT=8080 ./install.sh --yes
# See docs/INSTALL.md and docs/CONFIGURATION.md.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
ASSUME_YES=0
NO_START=0

# ── Output helpers ───────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

info()    { printf '%s\n' "${CYAN}==>${RESET} $*"; }
ok()      { printf '%s\n' "${GREEN}✔${RESET} $*"; }
warn()    { printf '%s\n' "${YELLOW}!${RESET} $*" >&2; }
die()     { printf '%s\n' "${RED}✖ $*${RESET}" >&2; exit 1; }
section() { printf '\n%s\n' "${BOLD}── $* ──${RESET}"; }
hint()    { [[ $ASSUME_YES -eq 1 ]] || printf '%s\n' "${DIM}$*${RESET}"; }

usage() {
  cat <<'EOF'
SpoolSync installation wizard

Usage: ./install.sh [options]

Options:
  -y, --yes       Non-interactive: accept defaults (or values preset in the
                  environment / existing .env) without prompting.
      --no-start  Only write .env; do not build, start or seed.
  -h, --help      Show this help.

Presettable variables:
  SPOOLSYNC_HOSTNAME FRONTEND_BIND FRONTEND_PORT BACKEND_BIND BACKEND_PORT
  ESP32_SERVER_HOST PUBLIC_URL
  SPOOLSYNC_DB_MODE (bundled|external) POSTGRES_HOST POSTGRES_PORT POSTGRES_DB
  POSTGRES_USER POSTGRES_PASSWORD POSTGRES_PUBLISH (y|n) POSTGRES_PUBLISH_BIND
  POSTGRES_PUBLISH_PORT
  JWT_SECRET JWT_EXPIRES_IN PRINTER_POLL_INTERVAL_MS SYSLOG_HOST
  BROWSERLESS_URL SPOOLSYNC_IMAGE_SOURCE (build|pull) SPOOLSYNC_TAG
  ADMIN_USERNAME ADMIN_EMAIL ADMIN_PASSWORD CREATE_ADMIN (y|n)

Secrets left empty are generated randomly (except an external database's
password). At an optional prompt, enter "-" to clear the current value.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)   ASSUME_YES=1 ;;
    --no-start) NO_START=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

# ── Random generation ────────────────────────────────────────────────────────
random_hex() { # bytes
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    od -An -tx1 -N "$1" /dev/urandom | tr -d ' \n'
  fi
}

random_password() { # length; alphanumeric so it is easy to type
  local out=''
  while [[ ${#out} -lt $1 ]]; do
    out+="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:$1}"
}

# ── Validators (return 0 when valid, print the reason otherwise) ─────────────
# shellcheck disable=SC2015  # A && B || C is intended: either test failing is invalid
v_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )) || { echo "must be a number between 1 and 65535"; return 1; }
}
v_bind() {
  local octet
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "must be an IPv4 address such as 0.0.0.0 or 127.0.0.1"; return 1; }
  for octet in ${1//./ }; do
    (( 10#$octet <= 255 )) || { echo "each part of an IPv4 address must be 0-255"; return 1; }
  done
}
v_host() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo "must be a hostname or IPv4 address"; return 1; }
}
v_optional_url() {
  local re="^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]']*)?$"
  [[ -z "$1" || "$1" =~ $re ]] || { echo "must be a URL such as https://spoolsync.example.com"; return 1; }
}
v_ident() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || { echo "letters, digits and _ only, starting with a letter"; return 1; }
}
v_ext_db_password() {
  [[ -n "$1" ]] || { echo "the external database's password is required"; return 1; }
  [[ "$1" =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "may only contain A-Z a-z 0-9 . _ ~ - (it is embedded in a URL)"; return 1; }
}
v_db_password() {
  [[ "$1" =~ ^[A-Za-z0-9._~-]+$ ]] || { echo "may only contain A-Z a-z 0-9 . _ ~ - (it is embedded in a URL)"; return 1; }
  (( ${#1} >= 12 )) || { echo "must be at least 12 characters"; return 1; }
}
v_jwt_secret() {
  [[ "$1" != *"'"* && ! "$1" =~ [[:space:]] ]] || { echo "may not contain quotes or whitespace"; return 1; }
  (( ${#1} >= 32 )) || { echo "must be at least 32 characters"; return 1; }
}
v_duration() {
  [[ "$1" =~ ^[0-9]+(s|m|h|d|w|y)$ ]] || { echo "use a number followed by s, m, h, d, w or y (e.g. 7d)"; return 1; }
}
# shellcheck disable=SC2015
v_seconds() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 5 )) || { echo "must be a whole number of seconds, 5 or more"; return 1; }
}
v_username() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || { echo "3-32 characters: letters, digits, . _ -"; return 1; }
}
v_email() {
  local re="^[^@[:space:]']+@[^@[:space:]']+$"
  [[ "$1" =~ $re ]] || { echo "must look like name@domain"; return 1; }
}
v_admin_password() {
  [[ "$1" != *$'\n'* ]] || { echo "may not contain newlines"; return 1; }
  (( ${#1} >= 8 )) || { echo "must be at least 8 characters"; return 1; }
}
v_optional_host() {
  [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "must be a hostname, host:port or URL"; return 1; }
}
v_image_source() {
  [[ "$1" == build || "$1" == pull ]] || { echo "must be 'build' or 'pull'"; return 1; }
}
v_tag() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "must be a valid image tag"; return 1; }
}

# ── Prompt helpers ───────────────────────────────────────────────────────────
# Defaults come from: environment > existing .env > built-in default.
declare -A EXISTING=()

default_for() { # name builtin
  local name="$1" builtin="$2"
  if [[ -n "${!name:-}" ]]; then printf '%s' "${!name}"
  elif [[ -n "${EXISTING[$name]:-}" ]]; then printf '%s' "${EXISTING[$name]}"
  else printf '%s' "$builtin"; fi
}

# ask NAME "Question" default validator
ask() {
  local name="$1" question="$2" def="$3" validator="$4" answer reason
  while true; do
    if [[ $ASSUME_YES -eq 1 ]]; then
      answer="$def"
    else
      read -r -p "$question ${DIM}[${def:-none}]${RESET}: " answer || die "Input closed"
      answer="${answer:-$def}"
    fi
    [[ $answer == - ]] && answer='' # "-" clears an optional value
    if reason="$($validator "$answer")"; then
      printf -v "$name" '%s' "$answer"
      return
    fi
    [[ $ASSUME_YES -eq 1 ]] && die "$name: $reason"
    warn "$reason"
  done
}

# ask_secret NAME "Question" current validator generator
# Blank keeps the current value if there is one, otherwise generates one.
GENERATED=()
ask_secret() {
  local name="$1" question="$2" current="$3" validator="$4" generator="$5"
  local answer confirm reason label
  label="$([[ -n "$current" ]] && echo "keep current" || echo "generate random")"
  while true; do
    if [[ $ASSUME_YES -eq 1 ]]; then
      answer=''
    else
      read -r -s -p "$question ${DIM}[blank = $label]${RESET}: " answer || die "Input closed"
      echo
    fi
    if [[ -z "$answer" ]]; then
      if [[ -n "$current" ]]; then
        answer="$current"
      else
        answer="$($generator)"
        [[ -n "$answer" ]] && GENERATED+=("$name")
      fi
    elif [[ $ASSUME_YES -eq 0 ]]; then
      read -r -s -p "Repeat to confirm: " confirm || die "Input closed"
      echo
      [[ "$answer" == "$confirm" ]] || { warn "Values did not match, try again"; continue; }
    fi
    if reason="$($validator "$answer")"; then
      printf -v "$name" '%s' "$answer"
      return
    fi
    [[ $ASSUME_YES -eq 1 ]] && die "$name: $reason"
    warn "$reason"
  done
}

# ask_yn NAME "Question" y|n
ask_yn() {
  local name="$1" question="$2" def="$3" answer
  while true; do
    if [[ $ASSUME_YES -eq 1 ]]; then
      answer="$def"
    else
      read -r -p "$question ${DIM}[$([[ $def == y ]] && echo Y/n || echo y/N)]${RESET}: " answer || die "Input closed"
      answer="${answer:-$def}"
    fi
    case "${answer,,}" in
      y|yes) printf -v "$name" y; return ;;
      n|no)  printf -v "$name" n; return ;;
      *)     warn "Please answer y or n" ;;
    esac
  done
}

gen_db_password() { random_hex 24; }
gen_jwt_secret()  { random_hex 48; }
gen_admin_pass()  { random_password 20; }
gen_none()        { :; }

# ── Port checks ──────────────────────────────────────────────────────────────
port_in_use_by_others() { # port
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnH "sport = :$1" 2>/dev/null | grep -q . || return 1
  # Ports held by this stack's own containers are fine on re-runs.
  docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Ports}}' \
    | grep -qE "(^|[ ,])[^ ,]*:$1->" && return 1
  return 0
}

ask_port() { # NAME "Question" default
  local name="$1"
  while true; do
    ask "$name" "$2" "$3" v_port
    if port_in_use_by_others "${!name}"; then
      [[ $ASSUME_YES -eq 1 ]] && die "Port ${!name} is already in use on this host"
      warn "Port ${!name} is already in use on this host; pick another"
      set -- "$1" "$2" "$(( ${!name} == 80 ? 8080 : ${!name} + 1 ))"
      continue
    fi
    return
  done
}

# ── Host addresses ───────────────────────────────────────────────────────────
# "address interface" lines for this host's IPv4 addresses, skipping Docker's
# own bridge interfaces.
host_addresses() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show scope global | awk '$2 !~ /^(docker|br-|veth)/ { sub(/\/.*/, "", $4); print $4, $2 }'
  else
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | sed 's/$/ -/' || true
  fi
}

guess_hostname() {
  local fqdn
  fqdn="$(hostname -f 2>/dev/null || hostname)"
  if [[ $fqdn == *.* || ${#HOST_IPS[@]} -eq 0 ]]; then
    printf '%s' "$fqdn"
  else
    printf '%s' "${HOST_IPS[0]}"
  fi
}

# Bind addresses must exist on this host or Docker fails to publish the port.
ask_bind() { # NAME "Question" default
  local name="$1" ip
  while true; do
    ask "$name" "$2" "$3" v_bind
    ip="${!name}"
    if [[ $ip == 0.0.0.0 || $ip == 127.* || " ${HOST_IPS[*]} " == *" $ip "* ]]; then
      return
    fi
    [[ $ASSUME_YES -eq 1 ]] && die "$name: $ip is not an address of this host"
    warn "$ip is not an address of this host; Docker would fail to publish the port"
    set -- "$1" "$2" 0.0.0.0
  done
}

version_ge() { # a b → a >= b
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ── .env handling ────────────────────────────────────────────────────────────
load_existing_env() {
  local line key value
  [[ -f "$ENV_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\'(.*)\'$ || "$value" =~ ^\"(.*)\"$ ]]; then value="${BASH_REMATCH[1]}"; fi
    EXISTING[$key]="$value"
  done < "$ENV_FILE"
}

q() { printf "'%s'" "$1"; } # single-quote for .env (values are validated quote-free)

write_env() {
  if [[ -f "$ENV_FILE" ]]; then
    local backup
    backup="$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$ENV_FILE" "$backup"
    ok "Previous configuration saved to $backup"
  fi
  # Optional overlays are enabled through COMPOSE_FILE. Setting it stops
  # Compose from auto-loading docker-compose.override.yml, so keep that last.
  local compose_files="docker-compose.yml" compose_block=''
  [[ $SPOOLSYNC_DB_MODE == external ]] && compose_files+=":compose/external-db.yml"
  [[ $POSTGRES_PUBLISH == y ]] && compose_files+=":compose/publish-db.yml"
  if [[ $compose_files != docker-compose.yml ]]; then
    [[ -f docker-compose.override.yml ]] && compose_files+=":docker-compose.override.yml"
    compose_block="
# ── Compose files ──
COMPOSE_FILE=$(q "$compose_files")
COMPOSE_PATH_SEPARATOR=':'
"
  fi

  ( umask 077
    cat > "$ENV_FILE" <<EOF
# Generated by install.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC').
# Re-run ./install.sh to change, or edit and run: docker compose up -d
# Reference: docs/CONFIGURATION.md

# ── Secrets ──
POSTGRES_PASSWORD=$(q "$POSTGRES_PASSWORD")
JWT_SECRET=$(q "$JWT_SECRET")

# ── Hostnames & addresses ──
SPOOLSYNC_HOSTNAME=$(q "$SPOOLSYNC_HOSTNAME")
PUBLIC_URL=$(q "$PUBLIC_URL")
ESP32_SERVER_HOST=$(q "$ESP32_SERVER_HOST")

# ── Network ──
FRONTEND_BIND=$(q "$FRONTEND_BIND")
FRONTEND_PORT=$(q "$FRONTEND_PORT")
BACKEND_BIND=$(q "$BACKEND_BIND")
BACKEND_PORT=$(q "$BACKEND_PORT")

# ── Database ──
SPOOLSYNC_DB_MODE=$(q "$SPOOLSYNC_DB_MODE")
POSTGRES_HOST=$(q "$POSTGRES_HOST")
POSTGRES_PORT=$(q "$POSTGRES_PORT")
POSTGRES_DB=$(q "$POSTGRES_DB")
POSTGRES_USER=$(q "$POSTGRES_USER")
POSTGRES_PUBLISH=$(q "$POSTGRES_PUBLISH")
POSTGRES_PUBLISH_BIND=$(q "$POSTGRES_PUBLISH_BIND")
POSTGRES_PUBLISH_PORT=$(q "$POSTGRES_PUBLISH_PORT")
${compose_block}
# ── Sessions ──
JWT_EXPIRES_IN=$(q "$JWT_EXPIRES_IN")

# ── Printers ──
PRINTER_POLL_INTERVAL_MS=$(q "$PRINTER_POLL_INTERVAL_MS")
SYSLOG_HOST=$(q "$SYSLOG_HOST")
BROWSERLESS_URL=$(q "$BROWSERLESS_URL")

# ── Images ──
SPOOLSYNC_IMAGE_SOURCE=$(q "$SPOOLSYNC_IMAGE_SOURCE")
SPOOLSYNC_TAG=$(q "$SPOOLSYNC_TAG")
EOF
  )
  ok "Wrote $SCRIPT_DIR/$ENV_FILE (mode 600)"
}

# ── Preflight ────────────────────────────────────────────────────────────────
printf '%s\n' "${BOLD}SpoolSync installation wizard${RESET}"

[[ -f docker-compose.yml ]] || die "docker-compose.yml not found next to install.sh"
command -v docker >/dev/null 2>&1 || die "Docker is not installed (https://docs.docker.com/engine/install/)"
docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Is it running, and is $(id -un) in the 'docker' group? (sudo usermod -aG docker $(id -un), then log in again)"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "Docker Compose is not installed (https://docs.docker.com/compose/install/)"
fi
COMPOSE_VERSION="$("${COMPOSE[@]}" version --short 2>/dev/null | sed 's/^v//' || echo 0)"
ok "Using Compose $COMPOSE_VERSION"

load_existing_env
mapfile -t HOST_IPS < <(host_addresses | awk '{print $1}')

# Compose names volumes <project>_postgres_data; the project defaults to the
# directory name.
PROJECT="${COMPOSE_PROJECT_NAME:-${EXISTING[COMPOSE_PROJECT_NAME]:-$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}}"
DB_VOLUME_EXISTS=0
if [[ -n "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.volume=postgres_data")" ]]; then
  DB_VOLUME_EXISTS=1
fi

if [[ -f "$ENV_FILE" ]]; then
  info "Existing $ENV_FILE found; its values are used as defaults."
fi
# ── Questions ────────────────────────────────────────────────────────────────
section "Hostname & network"
if [[ ${#HOST_IPS[@]} -gt 0 ]]; then
  hint "This host's addresses: $(host_addresses | awk '{ printf "%s%s (%s)", sep, $1, $2; sep = ", " }')"
fi
hint "The name or address people type in their browser to reach SpoolSync."
ask SPOOLSYNC_HOSTNAME "Hostname or IP for SpoolSync" "$(default_for SPOOLSYNC_HOSTNAME "$(guess_hostname)")" v_host

hint "The web UI is served by nginx, which also proxies the API."
hint "Bind address: 0.0.0.0 = all interfaces, 127.0.0.1 = only a reverse proxy on"
hint "this host, or one specific address from the list above."
ask_bind FRONTEND_BIND "Web UI bind address" "$(default_for FRONTEND_BIND 0.0.0.0)"
ask_port FRONTEND_PORT "Web UI port" "$(default_for FRONTEND_PORT 80)"

hint "ESP32 spool holders report weights straight to the backend API, so it"
hint "must be reachable on the LAN if you use them. Their firmware expects 3000."
def_backend_bind="$(default_for BACKEND_BIND 0.0.0.0)"
ask_yn EXPOSE_BACKEND "Expose the backend API on the network (needed for ESP32 devices)?" \
  "$([[ $def_backend_bind == 127.0.0.1 ]] && echo n || echo y)"
if [[ $EXPOSE_BACKEND == y ]]; then
  [[ $def_backend_bind == 127.0.0.1 ]] && def_backend_bind=0.0.0.0
  ask_bind BACKEND_BIND "Backend API bind address" "$def_backend_bind"
else
  BACKEND_BIND=127.0.0.1
fi
ask_port BACKEND_PORT "Backend API port" "$(default_for BACKEND_PORT 3000)"

ESP32_SERVER_HOST=''
if [[ $EXPOSE_BACKEND == y ]]; then
  [[ $BACKEND_PORT != 3000 ]] && warn "ESP32 devices may not find the API on a port other than 3000."
  hint "ESP32 devices are given this host when provisioned. They often cannot resolve"
  hint "local hostnames, so an IP address is the safest choice."
  def_esp32="$(default_for ESP32_SERVER_HOST '')"
  if [[ -z $def_esp32 ]]; then
    if [[ $BACKEND_BIND != 0.0.0.0 ]]; then def_esp32="$BACKEND_BIND"
    elif [[ ${#HOST_IPS[@]} -gt 0 ]]; then def_esp32="${HOST_IPS[0]}"
    else def_esp32="$SPOOLSYNC_HOSTNAME"; fi
  fi
  ask ESP32_SERVER_HOST "Host or IP ESP32 devices connect to" "$def_esp32" v_host
  if [[ $BACKEND_BIND != 0.0.0.0 && $ESP32_SERVER_HOST =~ ^[0-9.]+$ && $ESP32_SERVER_HOST != "$BACKEND_BIND" ]]; then
    warn "The API only listens on $BACKEND_BIND, so devices connecting to $ESP32_SERVER_HOST will fail."
  fi
fi

section "Database"
POSTGRES_PUBLISH_BIND="$(default_for POSTGRES_PUBLISH_BIND 127.0.0.1)"
POSTGRES_PUBLISH_PORT="$(default_for POSTGRES_PUBLISH_PORT 5432)"
ask_yn USE_EXTERNAL_DB "Use an external PostgreSQL server instead of the bundled one?" \
  "$([[ "$(default_for SPOOLSYNC_DB_MODE bundled)" == external ]] && echo y || echo n)"
if [[ $USE_EXTERNAL_DB == y ]]; then
  version_ge "$COMPOSE_VERSION" 2.24.0 \
    || die "An external database needs Docker Compose 2.24 or newer (found $COMPOSE_VERSION)"
  SPOOLSYNC_DB_MODE=external
  POSTGRES_PUBLISH=n
  hint "The server must be reachable from inside the backend container; 'localhost' won't work."
  def_db_host="$(default_for POSTGRES_HOST '')"
  [[ $def_db_host == postgres ]] && def_db_host=''
  ask POSTGRES_HOST "Database host or IP" "$def_db_host" v_host
  if [[ $POSTGRES_HOST == localhost || $POSTGRES_HOST == 127.* ]]; then
    warn "$POSTGRES_HOST refers to the backend container itself; use the host's LAN IP instead."
  fi
  ask POSTGRES_PORT "Database port" "$(default_for POSTGRES_PORT 5432)" v_port
  ask POSTGRES_DB "Database name" "$(default_for POSTGRES_DB spoolsync)" v_ident
  ask POSTGRES_USER "Database user" "$(default_for POSTGRES_USER spoolsync)" v_ident
  ask_secret POSTGRES_PASSWORD "Database password" "$(default_for POSTGRES_PASSWORD '')" v_ext_db_password gen_none
else
  SPOOLSYNC_DB_MODE=bundled
  POSTGRES_HOST=postgres
  POSTGRES_PORT=5432
  POSTGRES_DB="$(default_for POSTGRES_DB spoolsync)"
  POSTGRES_USER="$(default_for POSTGRES_USER spoolsync)"
  if [[ $DB_VOLUME_EXISTS -eq 1 ]]; then
    warn "An existing SpoolSync database volume was found for project '$PROJECT'."
    warn "Its password was fixed when it was created; keep the same POSTGRES_PASSWORD."
    if [[ -z "$(default_for POSTGRES_PASSWORD '')" ]]; then
      warn "No saved database password. Enter its original password,"
      warn "or remove the old data first: ${COMPOSE[*]} down -v"
    fi
  fi
  hint "Leave blank to generate a strong random password (recommended)."
  ask_secret POSTGRES_PASSWORD "Database password" "$(default_for POSTGRES_PASSWORD '')" v_db_password gen_db_password
  if [[ $DB_VOLUME_EXISTS -eq 1 && -n "${EXISTING[POSTGRES_PASSWORD]:-}" && "$POSTGRES_PASSWORD" != "${EXISTING[POSTGRES_PASSWORD]}" ]]; then
    warn "The existing database still uses the old password; the backend will fail to connect"
    warn "unless you also change it inside Postgres (see docs/CONFIGURATION.md)."
    ask_yn CONTINUE "Continue anyway?" n
    [[ $CONTINUE == y ]] || die "Aborted"
  fi

  hint "Publishing the database port lets backup or admin tools connect to it."
  ask_yn POSTGRES_PUBLISH "Publish the database port on this host?" "$(default_for POSTGRES_PUBLISH n)"
  if [[ $POSTGRES_PUBLISH == y ]]; then
    hint "127.0.0.1 = this host only (recommended), 0.0.0.0 = the whole network."
    ask_bind POSTGRES_PUBLISH_BIND "Database bind address" "$POSTGRES_PUBLISH_BIND"
    ask_port POSTGRES_PUBLISH_PORT "Database host port" "$POSTGRES_PUBLISH_PORT"
  fi
fi

section "Login sessions"
hint "Leave blank to generate a strong random secret (recommended)."
ask_secret JWT_SECRET "Login session secret (JWT_SECRET)" "$(default_for JWT_SECRET '')" v_jwt_secret gen_jwt_secret

ask JWT_EXPIRES_IN "How long a login stays valid (e.g. 12h, 7d, 30d)" "$(default_for JWT_EXPIRES_IN 7d)" v_duration

section "Admin account"
hint "The first administrator account. Additional users are managed in the UI."
ask_yn CREATE_ADMIN "Create the initial admin account?" "$(default_for CREATE_ADMIN "$([[ $DB_VOLUME_EXISTS -eq 1 ]] && echo n || echo y)")"
if [[ $CREATE_ADMIN == y ]]; then
  ask ADMIN_USERNAME "Admin username" "$(default_for ADMIN_USERNAME admin)" v_username
  ask ADMIN_EMAIL "Admin email (used to log in)" "$(default_for ADMIN_EMAIL admin@spoolsync.local)" v_email
  ask_secret ADMIN_PASSWORD "Admin password" "${ADMIN_PASSWORD:-}" v_admin_password gen_admin_pass
fi

# Advanced options keep their defaults unless the user opts in.
PRINTER_POLL_INTERVAL_MS="$(default_for PRINTER_POLL_INTERVAL_MS 30000)"
SYSLOG_HOST="$(default_for SYSLOG_HOST '')"
BROWSERLESS_URL="$(default_for BROWSERLESS_URL '')"
PUBLIC_URL="$(default_for PUBLIC_URL '')"
SPOOLSYNC_IMAGE_SOURCE="$(default_for SPOOLSYNC_IMAGE_SOURCE build)"
SPOOLSYNC_TAG="$(default_for SPOOLSYNC_TAG latest)"

section "Advanced"
ask_yn ADVANCED "Configure advanced options (public URL, printer polling, syslog, images)?" n
if [[ $ADVANCED == y ]]; then
  hint "Public base URL when SpoolSync is served through a reverse proxy, e.g."
  hint "https://spoolsync.example.com. Used for the OIDC callback; blank = detect per request."
  ask PUBLIC_URL "Public URL (blank = auto, - to clear)" "$PUBLIC_URL" v_optional_url


  ask POLL_SECONDS "Printer polling interval in seconds" "$(( PRINTER_POLL_INTERVAL_MS / 1000 ))" v_seconds
  PRINTER_POLL_INTERVAL_MS=$(( POLL_SECONDS * 1000 ))

  hint "Syslog target pushed to PrusaLink 'buddy' firmware printers (host or host:port)."
  ask SYSLOG_HOST "Syslog host (blank to skip, - to clear)" "$SYSLOG_HOST" v_optional_host

  hint "Browserless WebSocket URL for the work-in-progress PrusaConnect login."
  ask BROWSERLESS_URL "Browserless URL (blank to skip, - to clear)" "$BROWSERLESS_URL" v_optional_host

  hint "'build' compiles images from this checkout. 'pull' downloads ghcr.io images,"
  hint "which may require 'docker login ghcr.io' if they are not public."
  ask SPOOLSYNC_IMAGE_SOURCE "Image source (build/pull)" "$SPOOLSYNC_IMAGE_SOURCE" v_image_source
  if [[ $SPOOLSYNC_IMAGE_SOURCE == pull ]]; then
    ask SPOOLSYNC_TAG "Image tag" "$SPOOLSYNC_TAG" v_tag
  fi
fi

# ── Review ───────────────────────────────────────────────────────────────────
mask() { [[ " ${GENERATED[*]} " == *" $1 "* ]] && echo "(generated)" || echo "(set)"; }

section "Summary"
cat <<EOF
  Hostname            ${SPOOLSYNC_HOSTNAME}
  Public URL          ${PUBLIC_URL:-auto}
  Web UI              ${FRONTEND_BIND}:${FRONTEND_PORT}
  Backend API         ${BACKEND_BIND}:${BACKEND_PORT}
  ESP32 server host   ${ESP32_SERVER_HOST:-n/a (API not exposed)}
  Database            $([[ $SPOOLSYNC_DB_MODE == external ]] && echo "external ${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}" || echo "bundled (${POSTGRES_USER}/${POSTGRES_DB})")
  Database published  $([[ $POSTGRES_PUBLISH == y ]] && echo "${POSTGRES_PUBLISH_BIND}:${POSTGRES_PUBLISH_PORT}" || echo no)
  Database password   $(mask POSTGRES_PASSWORD)
  Session secret      $(mask JWT_SECRET)
  Session lifetime    ${JWT_EXPIRES_IN}
  Admin account       $([[ $CREATE_ADMIN == y ]] && echo "${ADMIN_USERNAME} <${ADMIN_EMAIL}>, password $(mask ADMIN_PASSWORD)" || echo "not created")
  Printer polling     $(( PRINTER_POLL_INTERVAL_MS / 1000 ))s
  Syslog host         ${SYSLOG_HOST:-none}
  Browserless URL     ${BROWSERLESS_URL:-none}
  Images              ${SPOOLSYNC_IMAGE_SOURCE}$([[ $SPOOLSYNC_IMAGE_SOURCE == pull ]] && echo " (tag ${SPOOLSYNC_TAG})")
EOF
echo
ask_yn PROCEED "Write configuration$([[ $NO_START -eq 0 ]] && echo " and start SpoolSync")?" y
[[ $PROCEED == y ]] || die "Aborted; nothing was changed"

write_env

if [[ $NO_START -eq 1 ]]; then
  info "Configuration written. Start later with: ${COMPOSE[*]} up -d --build"
  exit 0
fi

# ── Start ────────────────────────────────────────────────────────────────────
section "Starting SpoolSync"
if [[ $SPOOLSYNC_IMAGE_SOURCE == pull ]]; then
  info "Pulling images…"
  if ! "${COMPOSE[@]}" pull; then
    die "Pulling images failed. Run 'docker login ghcr.io' or re-run the wizard and choose 'build'."
  fi
  "${COMPOSE[@]}" up -d --no-build
else
  info "Building images from source (this takes a few minutes the first time)…"
  "${COMPOSE[@]}" up -d --build
fi

info "Waiting for the backend to become healthy…"
deadline=$(( SECONDS + 180 ))
until "${COMPOSE[@]}" exec -T backend wget -qO- http://127.0.0.1:3000/health 2>/dev/null | grep -q '"ok"'; do
  if (( SECONDS > deadline )); then
    "${COMPOSE[@]}" logs --tail 40 backend >&2 || true
    die "Backend did not become healthy within 3 minutes (logs above)"
  fi
  sleep 3
done
ok "Backend is up"

if [[ $CREATE_ADMIN == y ]]; then
  info "Creating roles and the admin account…"
  # Credentials go over stdin so they never appear in the process list.
  # shellcheck disable=SC2016  # expanded inside the container
  printf '%s\n%s\n%s\n' "$ADMIN_USERNAME" "$ADMIN_EMAIL" "$ADMIN_PASSWORD" \
    | "${COMPOSE[@]}" exec -T backend sh -c \
      'IFS= read -r u; IFS= read -r e; IFS= read -r p; SEED_ADMIN_USERNAME="$u" SEED_ADMIN_EMAIL="$e" SEED_ADMIN_PASSWORD="$p" node prisma/seed.js' \
    || die "Seeding failed. Is the username already taken by another account?"
  ok "Admin account ready"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
port_suffix="$([[ $FRONTEND_PORT == 80 ]] || echo ":$FRONTEND_PORT")"
section "SpoolSync is running"
[[ -n $PUBLIC_URL ]] && echo "  ${PUBLIC_URL}"
if [[ $FRONTEND_BIND == 127.* ]]; then
  echo "  http://${FRONTEND_BIND}${port_suffix}  (local only; point your reverse proxy here)"
elif [[ $FRONTEND_BIND != 0.0.0.0 ]]; then
  echo "  http://${SPOOLSYNC_HOSTNAME}${port_suffix}"
  [[ $SPOOLSYNC_HOSTNAME != "$FRONTEND_BIND" ]] && echo "  http://${FRONTEND_BIND}${port_suffix}"
else
  echo "  http://${SPOOLSYNC_HOSTNAME}${port_suffix}"
  for ip in "${HOST_IPS[@]}"; do
    [[ $ip != "$SPOOLSYNC_HOSTNAME" ]] && echo "  http://${ip}${port_suffix}"
  done
fi
[[ -n $ESP32_SERVER_HOST ]] && echo "  ESP32 provisioning will default to host ${ESP32_SERVER_HOST} (API port ${BACKEND_PORT})"
[[ $POSTGRES_PUBLISH == y ]] && echo "  Database: ${POSTGRES_PUBLISH_BIND}:${POSTGRES_PUBLISH_PORT} (user ${POSTGRES_USER}, db ${POSTGRES_DB})"
if [[ $CREATE_ADMIN == y ]]; then
  echo
  echo "  Log in as:  ${BOLD}${ADMIN_EMAIL}${RESET}"
  if [[ " ${GENERATED[*]} " == *" ADMIN_PASSWORD "* ]]; then
    echo "  Password:   ${BOLD}${ADMIN_PASSWORD}${RESET}   ← shown once; store it now"
  fi
  echo "  ${DIM}If an account with this email already existed, its password was left unchanged.${RESET}"
fi
cat <<EOF

Next steps:
  • Change the admin password after first login if it was shared.
  • NFC scanning, ESP32 USB provisioning and OIDC login need HTTPS
    (see docs/INSTALL.md → Reverse proxy & HTTPS).
  • Configure OIDC single sign-on under Settings in the web UI.

Useful commands (run in $SCRIPT_DIR):
  ${COMPOSE[*]} ps                status
  ${COMPOSE[*]} logs -f backend   follow backend logs
  ./install.sh                     change configuration
  ${COMPOSE[*]} down              stop (data is kept)
EOF
