#!/usr/bin/env bash
#
# SentinelX Core - macOS installer.
# Companion to install.sh (Linux/systemd). Two modes:
#   user   (default) - LaunchAgent in ~/Library/LaunchAgents; runs as you, NO
#                      root; starts at login, stops at logout.
#   system           - LaunchDaemon in /Library/LaunchDaemons; launchd starts it
#                      at BOOT and it survives logout. Runs AS you and reuses the
#                      same per-user install (uv's Python stays reachable); uses
#                      sudo ONLY for the daemon step, so run it as your normal
#                      user (NOT with sudo).
#
# Env:
#   SENTINELX_MODE=user|system     (default: user)
#   SENTINELX_HUB_URL              (default: https://mcp.sentinelx.app)
#   SENTINELX_HOST_ID              (default: mac-<shortname>)
#   SENTINELX_INSTALL_DIR          (default: ~/sentinelx)
#   SENTINELX_CHECK=1              Dry run: generate + plutil-lint the plist, then exit.
#
set -euo pipefail

MODE="${SENTINELX_MODE:-user}"
CHECK="${SENTINELX_CHECK:-0}"
HUB_URL="${SENTINELX_HUB_URL:-https://mcp.sentinelx.app}"
LABEL="app.sentinelx.core"
REPO_URL="git+https://github.com/pensados/sentinelx-cloud-core.git"
ENROLL_URL="https://raw.githubusercontent.com/pensados/sentinelx-cloud-installer/main/enroll.py"
EXAMPLE_URL="https://raw.githubusercontent.com/pensados/sentinelx-cloud-core/main/config.example.macos.yaml"

c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'; c_cyan=$'\033[36m'; c_bold=$'\033[1m'
info()  { echo "${c_grn}[*]${c_rst} $*"; }
warn()  { echo "${c_ylw}[!]${c_rst} $*"; }
fatal() { echo "${c_red}[x]${c_rst} $*" >&2; exit 1; }

banner() {
  printf '%b' "$c_cyan"
  cat <<'ART'
  ███████╗███████╗███╗   ██╗████████╗██╗███╗   ██╗███████╗██╗     ██╗  ██╗
  ██╔════╝██╔════╝████╗  ██║╚══██╔══╝██║████╗  ██║██╔════╝██║     ╚██╗██╔╝
  ███████╗█████╗  ██╔██╗ ██║   ██║   ██║██╔██╗ ██║█████╗  ██║      ╚███╔╝
  ╚════██║██╔══╝  ██║╚██╗██║   ██║   ██║██║╚██╗██║██╔══╝  ██║      ██╔██╗
  ███████║███████╗██║ ╚████║   ██║   ██║██║ ╚████║███████╗███████╗██╔╝ ██╗
  ╚══════╝╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝╚═╝  ╚═╝
ART
  printf '%b' "$c_rst"
  echo "  ${c_bold}Cloud Installer${c_rst} - connect this Mac to mcp.sentinelx.app"
  echo "  via the Model Context Protocol."
  echo "  ${c_ylw}What you'll get:${c_rst} a SentinelX agent that lets AI assistants"
  echo "  (Claude, ChatGPT, etc.) operate this Mac through MCP."
  echo
}


# Scoped passwordless sudo (macOS "option 1"): the agent runs as your user
# (not an isolated account), so we grant NOPASSWD only for the allowlisted
# commands that need root - launchctl (services) + the file ops - NOT
# "NOPASSWD: ALL". python3 is deliberately excluded (arbitrary code as root).
# Real hardening (a dedicated _sentinelx user) is future work.
setup_sudoers() {
  local f="/etc/sudoers.d/sentinelx" tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# SentinelX agent - scoped passwordless sudo (managed by install-macos.sh).
# Revoke with: sudo rm ${f}
${SVC_USER} ALL=(root) NOPASSWD: /bin/launchctl, /bin/cat, /usr/bin/grep, /usr/bin/touch, /usr/bin/tee, /bin/cp, /bin/mv, /bin/mkdir, /bin/rm, /bin/ln, /bin/unlink, /bin/chmod, /usr/sbin/chown, /usr/bin/sed, ${INSTALL_DIR}/.venv/bin/sentinelx-pensa-safe-edit
EOF
  if sudo visudo -c -f "$tmp" >/dev/null 2>&1; then
    sudo install -m 440 -o root -g wheel "$tmp" "$f"
    info "Installed scoped sudoers at $f (passwordless sudo for allowlisted root cmds)."
  else
    warn "sudoers failed visudo validation; skipped (sudo will prompt for a password)."
  fi
  rm -f "$tmp"
}

# Both modes install per-user: uv places its Python under the user's home, so a
# separate service user could not reach the venv. System mode differs ONLY in
# the service - a LaunchDaemon that launchd starts at boot, running as this user.
INSTALL_DIR="${SENTINELX_INSTALL_DIR:-$HOME/sentinelx}"
SVC_USER="$(id -un)"
if [[ "$MODE" == "system" ]]; then
  PLIST="/Library/LaunchDaemons/${LABEL}.plist"
else
  PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
fi
BIN="$INSTALL_DIR/.venv/bin/sentinelx-cloud-core"

# ---------- plist generators (mirror the Linux systemd unit) ----------------
plist_body() {
  # $1 = extra <dict> lines (e.g. UserName) injected before ProgramArguments
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
$1    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
        <string>--hub</string><string>${HUB_URL}</string>
        <string>--identity</string><string>${INSTALL_DIR}/identity.json</string>
        <string>--config</string><string>${INSTALL_DIR}/config.yaml</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>SENTINELX_AUDIT_PATH</key><string>${INSTALL_DIR}/audit.jsonl</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/agent.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/agent.err</string>
</dict>
</plist>
PL
}
write_plist() {
  if [[ "$MODE" == "system" ]]; then
    plist_body "    <key>UserName</key><string>${SVC_USER}</string>
" > "$1"
  else
    plist_body "" > "$1"
  fi
}

# ---------- CHECK mode: validate the plist, touch nothing --------------------
[[ "$(uname -s)" == "Darwin" ]] || fatal "macOS only. On Linux use install.sh."
if [[ "$CHECK" == "1" ]]; then
  info "check mode ($MODE): generating + linting plist"
  tmp="$(mktemp -d)"; write_plist "$tmp/${LABEL}.plist"
  command -v plutil >/dev/null && { plutil -lint "$tmp/${LABEL}.plist" || fatal "plutil -lint failed"; } || warn "plutil not found - skipping lint"
  info "plist OK"; cat "$tmp/${LABEL}.plist"; exit 0
fi

banner

# System mode must run as your normal user; the install has to be user-owned so
# uv's per-user Python is reachable. We elevate only for the daemon step.
if [[ "$MODE" == "system" && "$(id -u)" == "0" ]]; then
  fatal "Run system mode as your normal user (not with sudo). The script uses sudo only for the LaunchDaemon step."
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
cfg.setdefault("file_ops", {})["paths"] = [
    {"path": os.path.realpath(inst + "/workspace"), "access": "rw"},
    {"path": os.path.realpath(inst + "/config.yaml"), "access": "rw"},  # self-managed policy (file-scoped)
]
cfg["upload_base"] = os.path.realpath(inst + "/uploads")   # macOS: /var -> /private/var
open(inst + "/config.yaml", "w").write(yaml.safe_dump(cfg, sort_keys=False))
print("  config.yaml written")
PYCFG
fi

# ---------- service ----------------------------------------------------------
# We deliberately never `bootout` a running agent: running this installer THROUGH
# the SentinelX agent and tearing it down mid-install would sever the connection
# driving the install. RunAtLoad starts the agent at boot/login, so a fresh
# install loads the service once; a re-run refreshes the plist and leaves the
# running agent alone. Restarting to apply changes is an explicit kickstart.
info "Installing launchd service ($MODE)"
TMP_PLIST="$(mktemp)"
write_plist "$TMP_PLIST"
command -v plutil >/dev/null && plutil -lint "$TMP_PLIST" >/dev/null

if [[ "$MODE" == "system" ]]; then
  sudo cp "$TMP_PLIST" "$PLIST"
  sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
  if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
    info "LaunchDaemon already loaded; plist refreshed (agent left running)."
    info "  Apply changes now (restarts the agent): sudo launchctl kickstart -k system/$LABEL"
  else
    sudo launchctl bootstrap system "$PLIST" && info "LaunchDaemon loaded (starts at boot, survives logout)."
  fi
  setup_sudoers
else
  mkdir -p "$(dirname "$PLIST")"
  cp "$TMP_PLIST" "$PLIST"
  DOM="gui/$(id -u)"
  if launchctl print "$DOM/$LABEL" >/dev/null 2>&1; then
    info "LaunchAgent already loaded; plist refreshed (agent left running)."
    info "  Apply changes now (restarts the agent): launchctl kickstart -k $DOM/$LABEL"
  else
    { launchctl bootstrap "$DOM" "$PLIST" 2>/dev/null || launchctl load "$PLIST"; } && info "LaunchAgent loaded."
  fi
fi
rm -f "$TMP_PLIST"

sleep 3
if [[ "$MODE" == "system" ]]; then
  running=$(sudo launchctl print "system/$LABEL" 2>/dev/null | grep -c "state = running" || true)
else
  running=$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -c "state = running" || true)
fi
if [[ "${running:-0}" -ge 1 ]]; then
  info "Done. Agent running under launchd. Logs: $INSTALL_DIR/agent.log"
else
  warn "Service loaded but not confirmed running yet - check $INSTALL_DIR/agent.log"
fi
