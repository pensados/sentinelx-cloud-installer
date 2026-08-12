#!/usr/bin/env bash
#
# SentinelX Core - macOS installer (launchd).
# Companion to install.sh (Linux/systemd). Run with sudo.
#
# Env:
#   SENTINELX_HUB_URL       Hub websocket URL
#   SENTINELX_INSTALL_DIR   Install dir (default: /usr/local/sentinelx-cloud-core)
#   SENTINELX_CHECK=1        Dry run: generate + validate the launchd plist and
#                           exit, without creating users, cloning, or loading.
#
set -euo pipefail

INSTALL_DIR="${SENTINELX_INSTALL_DIR:-/usr/local/sentinelx-cloud-core}"
ETC_DIR="${SENTINELX_ETC_DIR:-/usr/local/etc/sentinelx}"
LOG_DIR="/usr/local/var/log/sentinelx"
UPLOAD_BASE="/usr/local/var/sentinelx/uploads"
WORKSPACE="/usr/local/var/sentinelx/workspace"
SVC_USER="_sentinelx"
SVC_GROUP="_sentinelx"
LABEL="app.sentinelx.core"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
REPO_URL="https://github.com/pensados/sentinelx-cloud-core.git"
HUB_URL="${SENTINELX_HUB_URL:-wss://mcp.sentinelx.app/agent}"
CHECK="${SENTINELX_CHECK:-0}"

c_grn=$'\033[32m'; c_red=$'\033[31m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
info()  { echo "${c_grn}[*]${c_rst} $*"; }
warn()  { echo "${c_ylw}[!]${c_rst} $*"; }
fatal() { echo "${c_red}[x]${c_rst} $*" >&2; exit 1; }

realpath_py() { /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# --- launchd plist (mirrors the Linux systemd unit) --------------------------
write_plist() {
  local dest="$1"
  cat > "$dest" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/.venv/bin/sentinelx-cloud-core</string>
        <string>--hub</string>
        <string>${HUB_URL}</string>
        <string>--identity</string>
        <string>${ETC_DIR}/identity.json</string>
        <string>--config</string>
        <string>${ETC_DIR}/config.yaml</string>
    </array>
    <key>UserName</key>
    <string>${SVC_USER}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/agent.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/agent.err</string>
</dict>
</plist>
PLIST
}

# --- config: start from the rich example, override macOS paths (realpath'd) ---
write_config() {
  local dest="$1" example="$2"
  /usr/bin/python3 - "$dest" "$example" "$WORKSPACE" "$UPLOAD_BASE" <<'PYCFG'
import sys, os, yaml
dest, example, ws, upload = sys.argv[1:5]
cfg = yaml.safe_load(open(example)) if os.path.exists(example) else {}
cfg.setdefault("file_ops", {})["paths"] = [{"path": os.path.realpath(ws), "access": "rw"}]
cfg["upload_base"] = os.path.realpath(upload)   # macOS: /var -> /private/var
open(dest, "w").write(yaml.safe_dump(cfg, sort_keys=False))
print("config written:", dest)
PYCFG
}

# ============================================================================
[[ "$(uname -s)" == "Darwin" ]] || fatal "macOS only. On Linux use install.sh."

# --- CHECK mode: validate the plist without touching the system -------------
if [[ "$CHECK" == "1" ]]; then
  info "check mode: generating launchd plist"
  tmp="$(mktemp -d)"
  write_plist "$tmp/${LABEL}.plist"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$tmp/${LABEL}.plist" || fatal "plist failed plutil -lint"
  else
    warn "plutil not found (not on macOS?) - skipping lint"
  fi
  info "plist OK"
  cat "$tmp/${LABEL}.plist"
  exit 0
fi

# --- real install (requires root) -------------------------------------------
[[ "$(id -u)" == "0" ]] || fatal "Run with sudo."
command -v git >/dev/null 2>&1 || fatal "git not found (xcode-select --install)."
[[ -x /usr/bin/python3 ]] || fatal "python3 not found."

info "Creating service user ${SVC_USER}"
if ! dscl . -read "/Users/${SVC_USER}" >/dev/null 2>&1; then
  # pick a free UID in the daemon range
  uid=200
  while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$uid"; do uid=$((uid+1)); done
  dscl . -create "/Groups/${SVC_GROUP}"
  dscl . -create "/Groups/${SVC_GROUP}" PrimaryGroupID "$uid"
  dscl . -create "/Users/${SVC_USER}"
  dscl . -create "/Users/${SVC_USER}" UserShell /usr/bin/false
  dscl . -create "/Users/${SVC_USER}" RealName "SentinelX Agent"
  dscl . -create "/Users/${SVC_USER}" UniqueID "$uid"
  dscl . -create "/Users/${SVC_USER}" PrimaryGroupID "$uid"
  dscl . -create "/Users/${SVC_USER}" NFSHomeDirectory /var/empty
  dscl . -create "/Users/${SVC_USER}" IsHidden 1
fi

info "Installing agent code"
mkdir -p "$INSTALL_DIR" "$ETC_DIR" "$LOG_DIR" "$UPLOAD_BASE" "$WORKSPACE"
if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
else
  git -C "$INSTALL_DIR" pull --ff-only
fi
/usr/bin/python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install -e "$INSTALL_DIR"

info "Writing config"
[[ -f "$ETC_DIR/config.yaml" ]] || write_config "$ETC_DIR/config.yaml" "$INSTALL_DIR/config.example.yaml"

chown -R "${SVC_USER}:${SVC_GROUP}" "$INSTALL_DIR" "$ETC_DIR" "$LOG_DIR" "$UPLOAD_BASE" "$WORKSPACE"

info "Installing launchd daemon"
write_plist "$PLIST"
chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
info "Done. Logs: $LOG_DIR/agent.log"
