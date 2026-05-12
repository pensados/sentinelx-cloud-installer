#!/usr/bin/env bash
# SentinelX core installer.
# Designed to be `curl -fsSL https://get.sentinelx.app | bash`-friendly.
#
# Environment overrides:
#   SENTINELX_HUB_URL       Hub URL (default: https://mcp.sentinelx.app)
#   SENTINELX_INSTALL_DIR   Install dir (default: /opt/sentinelx-cloud-core)
#   SENTINELX_HOST_ID       Force a specific host_id (default: auto-generated)
#   SENTINELX_CORE_REPO     Override the git repo URL
#   SENTINELX_CORE_REF      Override the git ref (branch/tag/commit, default: main)
#   SENTINELX_ENROLL_MODE   browser | paste (default: paste — works on headless)
#   SENTINELX_SKIP_SUDO     Set to 1 to skip the sudoers helper
set -euo pipefail

# Anchor cwd to a stable, always-readable directory before doing anything
# else. Reason: operators often run uninstall + reinstall back-to-back from
# inside /opt/sentinelx-cloud-core. The uninstall `rm -rf` removes that
# directory while the shell is still parked in it. Linux keeps the
# "phantom" cwd entry (the shell's stored inode is gone but $PWD still
# points there), and the very next subprocess that calls getcwd() — git,
# python, anything — fails with "Unable to read current working directory".
# That broke a real install during May 2026 review prep with a wall of
# `job-working-directory: error retrieving current directory` messages.
# Switching to / first guarantees getcwd() works regardless of what the
# operator did before piping us into bash.
cd / 2>/dev/null || true

# When `curl | bash` is used, the script's $0 is "bash" (not a file path)
# and stdin is the pipe carrying the script bytes. That stdin gets
# inherited by every subprocess we spawn — most notably enroll.py, which
# needs to read the user's enrollment token. Even with the /dev/tty
# fallback in enroll.py, having a half-consumed pipe as stdin can cause
# bash itself to read EOF earlier than expected, killing the install
# silently after enroll.py succeeds.
#
# Solution: detect that we were started via stdin pipe, write ourselves
# to a tempfile, and re-exec from that file with a clean stdin. After
# this, stdin is /dev/null (closed) and the script reads its lines from
# disk, immune to whatever enroll.py or any other subprocess does to
# stdin.
if [ ! -t 0 ] && [ -z "${SENTINELX_INSTALLER_RELAUNCHED:-}" ]; then
    # Heuristic: $0 is something like "bash" or "/bin/bash" rather than a
    # real file path → we're being piped from curl.
    if [ "$0" = "bash" ] || [ "$0" = "/bin/bash" ] || [ "$0" = "/usr/bin/bash" ] || [ ! -f "$0" ]; then
        TMPSCRIPT=$(mktemp /tmp/sentinelx-installer.XXXXXX.sh)
        cat > "$TMPSCRIPT"
        chmod +x "$TMPSCRIPT"
        export SENTINELX_INSTALLER_RELAUNCHED=1
        # Re-exec with stdin closed. Any subprocess that needs user input
        # has to use /dev/tty (which enroll.py already does as a fallback).
        exec bash "$TMPSCRIPT" "$@" </dev/null
    fi
fi

# When `set -e` triggers an exit, this trap fires before the script dies and
# prints what line crashed and what command. Without this, install failures
# look like "the script just stopped" — exactly the bug we hit during
# initial deployment.
trap 'rc=$?; echo ""; echo "[X] Install FAILED (exit=$rc) at line $LINENO"; echo "    Last command: $BASH_COMMAND"; echo "    State: $(ls -la /etc/sentinelx/ 2>&1 | head -5)"; echo ""; echo "    To finish manually, see the README or run with bash -x for verbose tracing."; exit $rc' ERR

HUB_URL="${SENTINELX_HUB_URL:-https://mcp.sentinelx.app}"
INSTALL_DIR="${SENTINELX_INSTALL_DIR:-/opt/sentinelx-cloud-core}"
ETC_DIR="/etc/sentinelx"
CORE_REPO="${SENTINELX_CORE_REPO:-https://github.com/pensados/sentinelx-cloud-core.git}"
CORE_REF="${SENTINELX_CORE_REF:-main}"
ENROLL_MODE="${SENTINELX_ENROLL_MODE:-paste}"

# --- pretty output -----------------------------------------------------------
c_red=$(tput setaf 1 2>/dev/null || true)
c_grn=$(tput setaf 2 2>/dev/null || true)
c_yel=$(tput setaf 3 2>/dev/null || true)
c_cyan=$(tput setaf 6 2>/dev/null || true)
c_bold=$(tput bold 2>/dev/null || true)
c_rst=$(tput sgr0 2>/dev/null || true)

# --- banner ------------------------------------------------------------------
# Printed once at startup, AFTER the stdin-pipe re-exec dance above (so it
# only appears in the relaunched run, not twice). tput-based colors degrade
# gracefully on dumb terminals: if tput fails, the vars are empty strings
# and the banner just prints in plain text.
echo "${c_cyan}"
cat << 'EOF'
  ███████╗███████╗███╗   ██╗████████╗██╗███╗   ██╗███████╗██╗     ██╗  ██╗
  ██╔════╝██╔════╝████╗  ██║╚══██╔══╝██║████╗  ██║██╔════╝██║     ╚██╗██╔╝
  ███████╗█████╗  ██╔██╗ ██║   ██║   ██║██╔██╗ ██║█████╗  ██║      ╚███╔╝
  ╚════██║██╔══╝  ██║╚██╗██║   ██║   ██║██║╚██╗██║██╔══╝  ██║      ██╔██╗
  ███████║███████╗██║ ╚████║   ██║   ██║██║ ╚████║███████╗███████╗██╔╝ ██╗
  ╚══════╝╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝╚═╝  ╚═╝
EOF
echo "${c_rst}"
echo "  ${c_bold}Cloud Installer${c_rst} — connect this server to mcp.sentinelx.app"
echo "  via the Model Context Protocol."
echo ""
echo "  ${c_yel}What you'll get:${c_rst} a SentinelX agent that lets AI assistants"
echo "  (Claude, ChatGPT, etc.) operate this server through MCP."
echo ""

info()  { echo "${c_grn}[+]${c_rst} $*"; }
warn()  { echo "${c_yel}[!]${c_rst} $*"; }
err()   { echo "${c_red}[!]${c_rst} $*" >&2; }
fatal() { echo "${c_red}[x]${c_rst} $*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || fatal "Only Linux is supported."
[[ "$EUID" -eq 0 ]] || fatal "Please run as root (use sudo)."

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64|arm64) ;;
    *) fatal "Unsupported architecture: $ARCH" ;;
esac

# Required tools
for cmd in curl git systemctl; do
    command -v "$cmd" >/dev/null || fatal "Missing required tool: $cmd"
done

# Find a Python that meets the >=3.11 requirement AND has pip + venv.
# Some systems (e.g. Debian Trixie's python3.13) ship the interpreter in
# /usr/bin but split pip and venv into separate apt packages, so a Python
# can satisfy the version check while still being unusable for our purposes.
# We test all three together: version, pip module, venv module. Only a
# Python that passes all three is selected.
PYTHON_BIN=""
PYTHON_REJECTED=""  # accumulator for diagnostic message if nothing works

check_python() {
    local candidate="$1"
    command -v "$candidate" >/dev/null 2>&1 || return 1
    local ver
    ver=$("$candidate" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")
    [ -n "$ver" ] || return 1
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [ "$major" -ge 3 ] && [ "$minor" -ge 11 ] || return 1
    "$candidate" -c "import pip" >/dev/null 2>&1 || {
        PYTHON_REJECTED="$PYTHON_REJECTED $candidate (no pip)"
        return 1
    }
    "$candidate" -c "import venv" >/dev/null 2>&1 || {
        PYTHON_REJECTED="$PYTHON_REJECTED $candidate (no venv)"
        return 1
    }
    return 0
}

for candidate in python3.13 python3.12 python3.11 python3; do
    if check_python "$candidate"; then
        PYTHON_BIN=$(command -v "$candidate")
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    err "No usable Python >=3.11 found on this system."
    if [ -n "$PYTHON_REJECTED" ]; then
        err "  Tried but rejected:$PYTHON_REJECTED"
        err ""
    fi
    err "  Install Python 3.11 with pip and venv:"
    err ""
    err "  On Ubuntu 22.04 / Debian 11 (which ship Python 3.10):"
    err "    sudo add-apt-repository -y ppa:deadsnakes/ppa"
    err "    sudo apt update"
    err "    sudo apt install -y python3.11 python3.11-venv"
    err ""
    err "  On Ubuntu 24.04 / Debian 12+ (Python 3.11+ in default repos):"
    err "    sudo apt install -y python3.11 python3.11-venv python3-pip"
    err ""
    err "  On RHEL/Fedora:"
    err "    sudo dnf install -y python3.11"
    err ""
    err "  Then re-run this installer. It will auto-detect the new Python."
    exit 1
fi

info "  Python:      $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

# Note: pip and venv availability are already verified by check_python() above,
# so we don't repeat those checks here.

info "SentinelX installer starting"
info "  Hub:         $HUB_URL"
info "  Install dir: $INSTALL_DIR"
info "  Repo:        $CORE_REPO @ $CORE_REF"
info "  Enroll mode: $ENROLL_MODE"

# --- generate or reuse host_id -----------------------------------------------
mkdir -p "$ETC_DIR"
if [[ -n "${SENTINELX_HOST_ID:-}" ]]; then
    HOST_ID="$SENTINELX_HOST_ID"
    echo "$HOST_ID" > "$ETC_DIR/host_id"
    info "Using provided host_id: $HOST_ID"
elif [[ ! -f "$ETC_DIR/host_id" ]]; then
    HOST_ID="host_$(cat /proc/sys/kernel/random/uuid | tr -d - | head -c 16)"
    echo "$HOST_ID" > "$ETC_DIR/host_id"
    chmod 644 "$ETC_DIR/host_id"
    info "Generated host_id: $HOST_ID"
else
    HOST_ID="$(cat "$ETC_DIR/host_id")"
    info "Using existing host_id: $HOST_ID"
fi

# --- create system user ------------------------------------------------------
if ! id sentinelx >/dev/null 2>&1; then
    info "Creating system user 'sentinelx'"
    useradd --system --home-dir "$INSTALL_DIR" --shell /bin/false sentinelx
fi

# --- configure passwordless sudo for sentinelx -------------------------------
#
# Why: the agent runs as the unprivileged 'sentinelx' user, but most useful
# operations (systemctl restart nginx, editing files in /etc, apt update, etc.)
# require root. Without sudo NOPASSWD, the LLM can't actually do its job.
#
# Security model: the *real* security boundary is the allowlist in
# /etc/sentinelx/config.yaml. The LLM can only invoke commands you've explicitly
# put there. So granting NOPASSWD to the agent doesn't expand the LLM's
# attack surface — it just lets the allowlist work as intended.
#
# To skip this step (for example in automation where you'll set up sudo
# yourself, or when you want zero sudo at all), pass:
#   SENTINELX_SKIP_SUDO=1
#
# To remove later: rm /etc/sudoers.d/sentinelx
#
SUDOERS_FILE="/etc/sudoers.d/sentinelx"

if [[ "${SENTINELX_SKIP_SUDO:-0}" == "1" ]]; then
    info "Skipping sudo setup (SENTINELX_SKIP_SUDO=1)"
elif [[ -f "$SUDOERS_FILE" ]]; then
    info "Sudoers file already exists at $SUDOERS_FILE — leaving it alone"
else
    # Detect if we're running interactively. If stdin is not a tty (curl|bash
    # case), we default to YES because the user just opted into the install.
    REPLY="y"
    if [[ -t 0 ]]; then
        echo
        echo "${c_yel}[?]${c_rst} Configure passwordless sudo for the 'sentinelx' user?"
        echo "    This lets the agent run systemctl, edit /etc/, etc. without"
        echo "    needing a password. Real security comes from the command"
        echo "    allowlist in /etc/sentinelx/config.yaml, which you control."
        echo
        read -r -p "    Allow passwordless sudo for sentinelx? [Y/n] " REPLY
        REPLY="${REPLY:-y}"
    fi

    if [[ "${REPLY,,}" =~ ^(y|yes)$ ]]; then
        info "Installing sudoers rule at $SUDOERS_FILE"
        # Atomic install: write to temp, validate with visudo, then rename.
        # If validation fails, sudoers stays untouched.
        SUDOERS_TMP="$(mktemp /tmp/sentinelx-sudoers.XXXXXX)"
        cat > "$SUDOERS_TMP" <<'EOF'
# Generated by sentinelx-cloud-installer.
# Allows the unprivileged 'sentinelx' user (which the agent runs as) to
# execute commands as root without a password.
#
# The LLM can only invoke commands listed in /etc/sentinelx/config.yaml,
# so the security boundary is the allowlist, not sudo itself.
#
# To revoke: rm /etc/sudoers.d/sentinelx
sentinelx ALL=(ALL) NOPASSWD: ALL
EOF

        if ! visudo -c -f "$SUDOERS_TMP" >/dev/null 2>&1; then
            rm -f "$SUDOERS_TMP"
            fatal "Generated sudoers file failed visudo validation. Aborting."
        fi

        # visudo passed → install
        chmod 0440 "$SUDOERS_TMP"
        chown root:root "$SUDOERS_TMP"
        mv "$SUDOERS_TMP" "$SUDOERS_FILE"
        info "Sudoers rule installed and validated"
    else
        warn "Skipped sudo setup. The agent will only be able to run commands"
        warn "    that don't require root. To enable later, re-run the installer"
        warn "    or write /etc/sudoers.d/sentinelx yourself."
    fi
fi

# --- install core code via git clone -----------------------------------------
info "Installing sentinelx-cloud-core to $INSTALL_DIR"

# Clean install: remove anything that was there before
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"

# Shallow clone for speed and disk
git clone --depth 1 --branch "$CORE_REF" "$CORE_REPO" "$INSTALL_DIR"

# Install in a venv to avoid polluting the system Python.
#
# We use `pip install -e` (editable mode) so the venv's site-packages
# imports the code DIRECTLY from $INSTALL_DIR/src rather than a separate
# copy. The practical benefit: operators can update the agent with a
#   cd $INSTALL_DIR && sudo -u sentinelx git pull && \
#       sudo systemctl restart sentinelx-cloud-core
# and the new code takes effect immediately. With a non-editable install
# the new code lands in $INSTALL_DIR/src but the agent keeps loading the
# stale copy from .venv/lib/.../site-packages until the package is
# reinstalled — a footgun that bit us during the May 2026 reviews.
info "Setting up Python virtualenv"
"$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install --quiet -e "$INSTALL_DIR"

chown -R sentinelx:sentinelx "$INSTALL_DIR"

# --- enroll ------------------------------------------------------------------
ENROLL_PY="$INSTALL_DIR/../sentinelx-cloud-installer/enroll.py"
# Above path won't exist — we need to also fetch the installer script.
# Simpler: ship enroll.py inside core repo, or download it separately.
# For now we download it on the fly from the installer repo.
INSTALLER_ENROLL_URL="https://raw.githubusercontent.com/pensados/sentinelx-cloud-installer/main/enroll.py"
ENROLL_PY="$ETC_DIR/sentinelx-enroll.py"

info "Downloading enrollment helper"
curl -fsSL "$INSTALLER_ENROLL_URL" -o "$ENROLL_PY"
chmod 755 "$ENROLL_PY"

if [[ -f "$ETC_DIR/identity.json" ]]; then
    warn "Existing identity.json found at $ETC_DIR/identity.json"
    warn "Skipping enrollment. Delete it and re-run to re-enroll."
else
    info "Starting enrollment ($ENROLL_MODE mode)"
    "$PYTHON_BIN" "$ENROLL_PY" \
        --hub "$HUB_URL" \
        --host-id "$HOST_ID" \
        --output "$ETC_DIR/identity.json" \
        --mode "$ENROLL_MODE"
    chmod 600 "$ETC_DIR/identity.json"
    chown sentinelx:sentinelx "$ETC_DIR/identity.json"
fi

# --- minimal config ----------------------------------------------------------
if [[ ! -f "$ETC_DIR/config.yaml" ]]; then
    # Use the rich example config shipped in the core repo as the starting
    # point. It comes with ~85 commonly-needed commands organized by category,
    # and a curated set of optional ones that the user can uncomment.
    EXAMPLE_CONFIG="$INSTALL_DIR/config.example.yaml"
    if [[ -f "$EXAMPLE_CONFIG" ]]; then
        info "Installing rich starter config to $ETC_DIR/config.yaml"
        info "  (~85 allowed commands by default. Edit to add/remove.)"
        cp "$EXAMPLE_CONFIG" "$ETC_DIR/config.yaml"
        # Inject the upload_base which the example doesn't include
        echo "" >> "$ETC_DIR/config.yaml"
        echo "# Where uploaded files are temporarily staged" >> "$ETC_DIR/config.yaml"
        echo "upload_base: /var/lib/sentinelx/uploads" >> "$ETC_DIR/config.yaml"
    else
        # Fallback: minimal config in case core repo doesn't ship the example.
        warn "$EXAMPLE_CONFIG not found, writing minimal fallback config"
        cat > "$ETC_DIR/config.yaml" <<EOF
# SentinelX agent configuration. Edit to expand allowed commands.
allowed_commands:
  - echo
  - whoami
  - uname
  - hostname
  - date
  - ls
  - id
  - pwd
  - df -h
  - free -h
  - uptime
  - cat /etc/os-release
upload_base: /var/lib/sentinelx/uploads
services: {}

# SSRF defense for upload_file's file_url. Empty allowlist below means
# file_url is effectively disabled. Add hosts you trust the agent to
# fetch from (your own services only — see config.example.yaml for
# the full explanation).
security:
  trusted_fetch_hosts:
    - drop.pensa.ar
    - get.sentinelx.app
  file_url_timeout_seconds: 15
EOF
    fi
    chmod 644 "$ETC_DIR/config.yaml"
fi

mkdir -p /var/lib/sentinelx/uploads
chown -R sentinelx:sentinelx /var/lib/sentinelx

# --- install systemd unit ----------------------------------------------------
info "Installing systemd unit"
cat > /etc/systemd/system/sentinelx-cloud-core.service <<EOF
[Unit]
Description=SentinelX Core agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sentinelx
Group=sentinelx
ExecStart=$INSTALL_DIR/.venv/bin/sentinelx-cloud-core \\
    --hub $HUB_URL \\
    --identity $ETC_DIR/identity.json \\
    --config $ETC_DIR/config.yaml
Restart=always
RestartSec=5

# NOTE: We deliberately DO NOT set NoNewPrivileges=true here.
# The agent's allowlist intentionally permits commands like \`sudo cat\`,
# \`sudo systemctl status\`, etc., for read-only inspection of root-owned
# files and services. NoNewPrivileges blocks all setuid escalation and
# would silently break those — the operator would see "permission denied"
# from sudo despite the sudoers helper being installed correctly.
#
# Defense-in-depth is provided by:
#   1. Running as a system user 'sentinelx' (no shell, no home, no login)
#   2. The allowlist in /etc/sentinelx/config.yaml — only listed commands
#      can run, and only with their listed prefixes
#   3. The sudoers helper at /etc/sudoers.d/sentinelx — only allowed
#      commands can be run via sudo
# Removing NoNewPrivileges does not weaken any of these.

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/log/sentinelx
chown sentinelx:sentinelx /var/log/sentinelx

# Detect whether we have a working systemd. Rare environments (Docker
# containers without an init, WSL1, ChromeOS Crostini, some minimal LXC
# templates) ship `systemctl` but can't actually talk to PID 1.
# We probe by trying a harmless query — if systemd-as-PID-1 isn't there,
# this returns non-zero and prints "System has not been booted with systemd".
if ! systemctl list-units --type=service --no-pager >/dev/null 2>&1; then
    warn "systemd doesn't appear to be running on this system."
    warn "Skipping systemctl steps. The agent is installed but won't auto-start."
    warn ""
    warn "To run it once manually:"
    warn "  sudo -u sentinelx $INSTALL_DIR/.venv/bin/sentinelx-cloud-core \\"
    warn "      --hub $HUB_URL \\"
    warn "      --identity $ETC_DIR/identity.json \\"
    warn "      --config $ETC_DIR/config.yaml"
    warn ""
    warn "If you DO have systemd, check the unit at:"
    warn "  /etc/systemd/system/sentinelx-cloud-core.service"
    exit 0
fi

systemctl daemon-reload
systemctl enable --now sentinelx-cloud-core.service

# --- final status ------------------------------------------------------------
sleep 2
if systemctl is-active --quiet sentinelx-cloud-core.service; then
    info "SentinelX is running."
    echo
    echo "  Status:   systemctl status sentinelx-cloud-core"
    echo "  Logs:     journalctl -u sentinelx-cloud-core -f"
    echo "  Hub URL:  $HUB_URL"
    echo "  Host ID:  $HOST_ID"
    echo "  Config:   $ETC_DIR/config.yaml"
    echo
    info "Done. Connect SentinelX in Claude.ai or ChatGPT settings → Connectors."
    info "  Connector URL:  $HUB_URL/mcp/mcp"
else
    warn "Service did not start cleanly."
    warn "Check 'journalctl -u sentinelx-cloud-core -n 50'"
    journalctl -u sentinelx-cloud-core -n 20 --no-pager
    exit 1
fi

