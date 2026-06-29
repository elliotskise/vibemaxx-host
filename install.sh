#!/usr/bin/env bash
#
# VibeMaxx host — one-line VPS installer.
#
# Installs the always-on `vibemaxx-host` daemon (agent/terminal sessions over WebSocket) on a
# Debian/Ubuntu box, as a hardened non-root systemd service bound to loopback. Your VibeMaxx
# desktop app then connects to it so sessions survive your local machine sleeping/shutting off.
#
# Quick start (loopback only — reach it over an SSH tunnel):
#   curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh | sudo bash
#
# With automatic-TLS wss:// (point the domain's DNS at this box FIRST):
#   curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh \
#     | sudo bash -s -- --domain host.example.com
#
# It is idempotent: re-run it to update to the latest daemon (the token is preserved).
# Uninstall with:  sudo bash install.sh --uninstall
#
# Options (pass after `bash -s --`):
#   --domain <host>        Domain pointed at this VPS; installs Caddy for automatic-TLS wss://.
#   --github-token <tok>   GitHub token for authenticated git push/pull from the host (optional).
#   --token <tok>          Use this bearer token instead of generating one.
#   --port <n>             Loopback port (default 8765).
#   --user <name>          Service user (default vibemaxx).
#   --version <spec>       npm version/tag to install (default latest).
#   --uninstall            Stop + remove the service, user-data is kept.
#   --purge                With --uninstall, also delete the data dir and env file.
#   -h, --help             Show this help.

set -euo pipefail

# --- defaults -------------------------------------------------------------------------------
DOMAIN=""
PORT="8765"
BIND="127.0.0.1"
TOKEN=""
GITHUB_TOKEN=""
APP_USER="vibemaxx"
NPM_SPEC="latest"
DO_UNINSTALL=0
DO_PURGE=0

SERVICE="vibemaxx-host"
ENV_DIR="/etc/vibemaxx"
ENV_FILE="${ENV_DIR}/host.env"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mx  %s\033[0m\n' "$*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0; }

# --- parse flags ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)        DOMAIN="${2:-}"; shift 2 ;;
    --github-token)  GITHUB_TOKEN="${2:-}"; shift 2 ;;
    --token)         TOKEN="${2:-}"; shift 2 ;;
    --port)          PORT="${2:-}"; shift 2 ;;
    --user)          APP_USER="${2:-}"; shift 2 ;;
    --version)       NPM_SPEC="${2:-}"; shift 2 ;;
    --uninstall)     DO_UNINSTALL=1; shift ;;
    --purge)         DO_PURGE=1; shift ;;
    -h|--help)       usage ;;
    *)               die "Unknown option: $1 (try --help)" ;;
  esac
done

APP_HOME="/home/${APP_USER}"
DATA_DIR="${APP_HOME}/.vibemaxx-host"
PROJECTS_DIR="${APP_HOME}/projects"

[ "$(id -u)" -eq 0 ] || die "Run as root:  curl -fsSL <url> | sudo bash"
command -v apt-get >/dev/null || die "This installer targets Debian/Ubuntu (apt-get not found)."

# --- uninstall path -------------------------------------------------------------------------
if [ "${DO_UNINSTALL}" -eq 1 ]; then
  say "Removing the ${SERVICE} service"
  systemctl disable --now "${SERVICE}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload 2>/dev/null || true
  npm uninstall -g vibemaxx-host 2>/dev/null || true
  if [ "${DO_PURGE}" -eq 1 ]; then
    warn "Purging data dir ${DATA_DIR} and ${ENV_FILE}"
    rm -rf "${DATA_DIR}" "${ENV_FILE}"
  else
    printf '   Kept user-data: %s  (and %s). Re-run with --purge to delete.\n' "${DATA_DIR}" "${ENV_FILE}"
  fi
  ok "Uninstalled."
  exit 0
fi

# --- 1. system packages ---------------------------------------------------------------------
say "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
# build-essential + python3: fallback compile for node-pty/better-sqlite3 if no prebuild exists.
apt-get install -y ca-certificates curl gnupg git build-essential python3 openssl

NODE_MAJOR="$(command -v node >/dev/null && node -p 'process.versions.node.split(".")[0]' || echo 0)"
if [ "${NODE_MAJOR}" -lt 18 ]; then
  say "Installing Node.js 20 LTS"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
else
  say "Node.js $(node -v) already present"
fi
NODE_BIN="$(command -v node)"

# --- 2. service user + dirs -----------------------------------------------------------------
if id -u "${APP_USER}" >/dev/null 2>&1; then
  say "User ${APP_USER} already exists"
else
  say "Creating non-root user ${APP_USER}"
  useradd --system --create-home --home-dir "${APP_HOME}" --shell /usr/sbin/nologin "${APP_USER}"
fi
install -d -o "${APP_USER}" -g "${APP_USER}" "${DATA_DIR}" "${PROJECTS_DIR}"

# --- 3. install the daemon from npm ---------------------------------------------------------
say "Installing the vibemaxx-host daemon from npm (vibemaxx-host@${NPM_SPEC})"
# Global install builds node-pty/better-sqlite3 for THIS Node's ABI (prebuilds used when available).
npm install -g "vibemaxx-host@${NPM_SPEC}" --no-audit --no-fund
# node-pty's spawn-helper can lose its exec bit through copies; restore it (best-effort).
find "$(npm root -g)" -name spawn-helper -exec chmod +x {} \; 2>/dev/null || true

DAEMON_MAIN="$(npm root -g)/vibemaxx-host/host-dist/host/index.js"
[ -f "${DAEMON_MAIN}" ] || die "Daemon entry not found at ${DAEMON_MAIN} after install."

# --- 4. token + env file --------------------------------------------------------------------
install -d -m 750 "${ENV_DIR}"
if [ -z "${TOKEN}" ] && [ -f "${ENV_FILE}" ]; then
  TOKEN="$(grep -E '^VIBEMAXX_HOST_TOKEN=' "${ENV_FILE}" | head -n1 | cut -d= -f2- || true)"
  [ -n "${TOKEN}" ] && say "Reusing existing token from ${ENV_FILE}"
fi
if [ -z "${TOKEN}" ]; then
  say "Generating a bearer token"
  TOKEN="$("${NODE_BIN}" -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"
fi

say "Writing ${ENV_FILE}"
{
  echo "VIBEMAXX_HOST_TOKEN=${TOKEN}"
  echo "VIBEMAXX_HOST_BIND=${BIND}"
  echo "VIBEMAXX_HOST_PORT=${PORT}"
  echo "VIBEMAXX_HOST_DATA_DIR=${DATA_DIR}"
  [ -n "${GITHUB_TOKEN}" ] && echo "VIBEMAXX_HOST_GITHUB_TOKEN=${GITHUB_TOKEN}"
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

# --- 5. systemd unit ------------------------------------------------------------------------
say "Installing systemd service ${SERVICE}"
cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=VibeMaxx host daemon (agent sessions over WebSocket)
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${PROJECTS_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${DAEMON_MAIN}
Restart=always
RestartSec=2

# Hardening — the daemon can spawn arbitrary processes, so contain it.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${DATA_DIR} ${PROJECTS_DIR}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE}" >/dev/null
systemctl restart "${SERVICE}"

# --- 6. Caddy (optional TLS) ----------------------------------------------------------------
PUBLIC_URL="ws://${BIND}:${PORT}"
if [ -n "${DOMAIN}" ]; then
  if ! command -v caddy >/dev/null; then
    say "Installing Caddy"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy
  fi
  say "Configuring Caddy for ${DOMAIN}"
  cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
	reverse_proxy ${BIND}:${PORT}
}
CADDY
  systemctl reload caddy || systemctl restart caddy
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80,443/tcp >/dev/null || true
  fi
  PUBLIC_URL="wss://${DOMAIN}"
fi

# --- summary --------------------------------------------------------------------------------
sleep 1
STATUS="$(systemctl is-active "${SERVICE}" || true)"
HEALTH="$(curl -fsS "http://${BIND}:${PORT}/healthz" 2>/dev/null || echo 'unreachable')"

cat <<SUMMARY

$(ok "VibeMaxx host is set up.")

  Service     : ${SERVICE} (${STATUS})
  Health      : http://${BIND}:${PORT}/healthz -> ${HEALTH}
  Projects    : ${PROJECTS_DIR}   (clone repos here; agents can read/write here)

  Connect from the desktop app  (Settings → Connections → Host connection):
    URL   : ${PUBLIC_URL}
    Token : ${TOKEN}

SUMMARY

if [ -z "${DOMAIN}" ]; then
  cat <<NOTE
$(warn "No --domain set — the daemon is loopback-only (no TLS, not reachable from the internet).")
   Reach it by either:
     - re-running with --domain your.domain  for automatic-TLS wss://, or
     - an SSH tunnel from your laptop:
         ssh -N -L ${PORT}:127.0.0.1:${PORT} <user>@<this-vps>
       then connect the app to  ws://127.0.0.1:${PORT}
     - or a Tailscale/WireGuard private address.

NOTE
fi

cat <<TIPS
  Logs    : journalctl -u ${SERVICE} -f
  Status  : systemctl status ${SERVICE}
  Update  : re-run this installer (token is preserved)
  Remove  : sudo bash install.sh --uninstall

TIPS
