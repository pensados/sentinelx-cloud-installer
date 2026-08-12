#!/usr/bin/env bash
#
# SentinelX Core - macOS installer.
# Companion to install.sh (Linux/systemd). Two modes:
#   user   (default) - LaunchAgent in ~/Library/LaunchAgents, runs as you, NO root.
#   system           - LaunchDaemon + hidden _sentinelx user, requires sudo.
#
# Env:
#   SENTINELX_MODE=user|system     (default: user)
#   SENTINELX_HUB_URL              (default: https://mcp.sentinelx.app)
#   SENTINELX_HOST_ID              (default: mac-<shortname>)
#   SENTINELX_INSTALL_DIR          (default: ~/sentinelx  or  /usr/local/sentinelx-cloud-core)
#   SENTINELX_CHECK=1              Dry run: generate + plutil-lint the plist, then exit.
#
set -euo pipefail

MODE="${SENTINELX_MODE:-user}"
CHECK="${SENTINELX_CHECK:-0}"
HUB_URL="${SENTINELX_HUB_URL:-https://mcp.sentinelx.app}"
LABEL="app.sentinelx.core"
REPO_URL="git+https://github.com/pensados/sentinelx-cloud-core.git"
ENROLL_URL="https://raw.githubusercontent.com/pensados/sentinelx-cloud-installer/main/enroll.py"
EXAMPLE_URL="https://raw.githubusercontent.com/pensados/sentinelx-cloud-core/main/config.example.yaml"

c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
info()  { echo "${c_grn}[*]${c_rst} $*"; }
warn()  { echo "${c_ylw}[!]${c_rst} $*"; }
fatal() { echo "${c_red}[x]${c_rst} $*" >&2; exit 1; }

if [[ "$MODE" == "system" ]]; then
  INSTALL_DIR="${SENTINELX_INSTALL_DIR:-/usr/local/sentinelx-cloud-core}"
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"
  SVC_USER="_sentinelx"
else
  INSTALL_DIR="${SENTINELX_INSTALL_DIR:-$HOME/sentinelx}"
  PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
fi
BIN="$INSTALL_DIR/.venv/bin/sentinelx-cloud-core"

# ---------- plist generators (mirror the Linux systemd unit) ----------------
write_launchagent() {
  cat > "$1" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
        <string>--hub</string><string>${HUB_URL}</string>
        <string>--identity</string><string>${INSTALL_DIR}/identity.json</string>
        <string>--config</string><string>${INSTALL_DIR}/config.yaml</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/agent.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/agent.err</string>
</dict>
</plist>
PL
}
write_launchdaemon() {
  cat > "$1" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>UserName</key><string>${SVC_USER:-_sentinelx}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
        <string>--hub</string><string>${HUB_URL}</string>
        <string>--identity</string><string>${INSTALL_DIR}/identity.json</string>
        <string>--config</string><string>${INSTALL_DIR}/config.yaml</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/agent.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/agent.err</string>
</dict>
</plist>
PL
}
write_plist() { if [[ "$MODE" == "system" ]]; then write_launchdaemon "$1"; else write_launchagent "$1"; fi; }

# ---------- CHECK mode: validate the plist, touch nothing --------------------
[[ "$(uname -s)" == "Darwin" ]] || fatal "macOS only. On Linux use install.sh."
if [[ "$CHECK" == "1" ]]; then
  info "check mode ($MODE): generating + linting plist"
  tmp="$(mktemp -d)"; write_plist "$tmp/${LABEL}.plist"
  command -v plutil >/dev/null && { plutil -lint "$tmp/${LABEL}.plist" || fatal "plutil -lint failed"; } || warn "plutil not found - skipping lint"
  info "plist OK"; cat "$tmp/${LABEL}.plist"; exit 0
fi

# ---------- prerequisites ----------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
  info "Command Line Tools (git) not found - triggering install"
  xcode-select --install 2>/dev/null || true
  fatal "A macOS dialog should appear. Click 'Install', wait for it to finish, then re-run this script."
fi

export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
  info "Installing uv (brings a modern Python without sudo)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v uv >/dev/null 2>&1 || fatal "uv install failed; ensure ~/.local/bin is on PATH."

# ---------- install the agent ------------------------------------------------
info "Installing agent into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/workspace" "$INSTALL_DIR/uploads"
[[ -d "$INSTALL_DIR/.venv" ]] || uv venv --python 3.12 "$INSTALL_DIR/.venv"
# shellcheck disable=SC1091
source "$INSTALL_DIR/.venv/bin/activate"
uv pip install --refresh "$REPO_URL"

# ---------- enroll (skip if we already have an identity) ---------------------
HOST_ID="${SENTINELX_HOST_ID:-mac-$(hostname -s)}"
if [[ -f "$INSTALL_DIR/identity.json" ]]; then
  info "identity.json present - skipping enrollment"
else
  curl -fsSL "$ENROLL_URL" -o "$INSTALL_DIR/enroll.py"
  echo "${c_ylw}Enroll in your browser:${c_rst} ${HUB_URL}/auth/dashboard/enroll?host_id=${HOST_ID}"
  echo "  (log in, copy the token, paste it below)"
  python "$INSTALL_DIR/enroll.py" --hub "$HUB_URL" --host-id "$HOST_ID" --output "$INSTALL_DIR/identity.json" --mode paste
fi

# ---------- config (macOS paths, realpath'd) --------------------------------
if [[ ! -f "$INSTALL_DIR/config.yaml" ]]; then
  info "Writing config"
  python - "$INSTALL_DIR" "$EXAMPLE_URL" <<'PYCFG'
import os, sys, yaml, urllib.request
inst, url = sys.argv[1], sys.argv[2]
cfg = yaml.safe_load(urllib.request.urlopen(url).read())
cfg.setdefault("file_ops", {})["paths"] = [{"path": os.path.realpath(inst + "/workspace"), "access": "rw"}]
cfg["upload_base"] = os.path.realpath(inst + "/uploads")   # macOS: /var -> /private/var
open(inst + "/config.yaml", "w").write(yaml.safe_dump(cfg, sort_keys=False))
print("  config.yaml written")
PYCFG
fi

# ---------- service (LaunchAgent, or LaunchDaemon for system mode) -----------
info "Installing launchd service ($MODE)"
mkdir -p "$(dirname "$PLIST")"
write_plist "$PLIST"
command -v plutil >/dev/null && plutil -lint "$PLIST" >/dev/null

# NOTE: we deliberately never `bootout` a running agent here. When this
# installer is run *through* the SentinelX agent itself, tearing the agent
# down mid-install severs the very connection driving the install. RunAtLoad
# already starts the agent at login, so a fresh install only needs to load the
# service once; a re-run just refreshes the plist and leaves the agent running.
if [[ "$MODE" == "system" ]]; then
  [[ "$(id -u)" == "0" ]] || fatal "system mode needs sudo."
  chown root:wheel "$PLIST"; chmod 644 "$PLIST"
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    info "LaunchDaemon already loaded; plist refreshed (agent left running)."
    info "  Apply changes now (restarts the agent): sudo launchctl kickstart -k system/$LABEL"
  else
    launchctl bootstrap system "$PLIST" && info "LaunchDaemon loaded."
  fi
else
  DOM="gui/$(id -u)"
  if launchctl print "$DOM/$LABEL" >/dev/null 2>&1; then
    info "LaunchAgent already loaded; plist refreshed (agent left running)."
    info "  Apply changes now (restarts the agent): launchctl kickstart -k $DOM/$LABEL"
  else
    { launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null || launchctl load "$PLIST"; } && info "LaunchAgent loaded."
  fi
fi

sleep 3
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  info "Done. Agent is managed by launchd. Logs: $INSTALL_DIR/agent.log"
else
  warn "Service loaded but not visible in launchctl list yet - check $INSTALL_DIR/agent.log"
fi
