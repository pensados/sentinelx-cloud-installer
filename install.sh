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
on_error() {
    local rc="$1" line="$2" cmd="$3"
    echo ""
    echo "[X] Install FAILED (exit=$rc) at line $line"
    echo "    Last command: $cmd"
    echo "    State: $(ls -la /etc/sentinelx/ 2>&1 | head -5)"
    echo ""
    # If enrollment is what failed, the overwhelmingly likely cause on modern
    # Ubuntu is the sudo+use_pty token-prompt issue. Make the fix that works
    # the LAST thing the user reads, not a generic "see the README".
    if printf '%s' "$cmd" | grep -qi "enroll"; then
        echo "    Enrollment couldn't read your token. On modern Ubuntu (sudo with"
        echo "    'Defaults use_pty') the interactive prompt can't receive input when"
        echo "    sudo is in the pipe. Re-run as root instead — this works:"
        echo ""
        echo "        sudo -i"
        echo "        curl -fsSL https://get.sentinelx.app | bash"
    else
        echo "    To finish manually, see the README or run with bash -x for verbose tracing."
    fi
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

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

# --- optional: passwordless sudo for sentinelx -------------------------------
#
# OFF BY DEFAULT. You have to ask for it.
#
# Why you might want it: the agent runs as the unprivileged 'sentinelx' user,
# so operations like `systemctl restart nginx`, editing files under /etc or
# `apt update` need root. Without sudo those simply fail, and everything else
# (reading logs, inspecting the system, editing files the sentinelx user owns)
# keeps working.
#
# What it actually means, stated plainly: granting NOPASSWD:ALL makes the
# agent ROOT-EQUIVALENT on this host. The command allowlist in
# /etc/sentinelx/config.yaml is a usability guardrail that keeps the model on
# rails; it is NOT a security boundary, because an agent with sudo can run a
# script that steps around it. Treat enabling this as handing the machine's
# root account to whoever can drive the agent -- including anything that can
# influence the model, such as the contents of a file it reads. That is the
# same trust you extend to any remote administration tool, and it should be a
# decision, not a default.
#
# To enable, either answer the prompt below, or pass:
#   SENTINELX_ENABLE_SUDO=1
#
# To remove later: rm /etc/sudoers.d/sentinelx
#
SUDOERS_FILE="/etc/sudoers.d/sentinelx"

# Whether this host ends up with the agent able to become root. Drives the
# systemd hardening below: a host without sudo can be locked down further,
# and a host with sudo must not be, or sudo itself would stop working.
SUDO_ENABLED=0

if [[ "${SENTINELX_SKIP_SUDO:-0}" == "1" ]]; then
    # Kept for compatibility with existing automation. Now redundant: not
    # granting sudo is the default.
    info "Skipping sudo setup (SENTINELX_SKIP_SUDO=1)"
elif [[ -f "$SUDOERS_FILE" ]]; then
    info "Sudoers file already exists at $SUDOERS_FILE — leaving it alone"
    SUDO_ENABLED=1
else
    # Default NO, including the non-interactive curl|bash case: installing the
    # agent is not the same decision as handing it root, so the privileged
    # option is never taken on the user's behalf. Only an explicit env var or
    # an explicit "yes" at the prompt turns it on.
    if [[ "${SENTINELX_ENABLE_SUDO:-0}" == "1" ]]; then
        REPLY="y"
        info "Enabling passwordless sudo (SENTINELX_ENABLE_SUDO=1)"
    else
        REPLY="n"
    fi
    if [[ "$REPLY" != "y" && -t 0 ]]; then
        echo
        echo "${c_yel}[?]${c_rst} Configure passwordless sudo for the 'sentinelx' user?"
        echo "    This lets the agent run systemctl, edit /etc/, install"
        echo "    packages and so on."
        echo
        echo "    It also makes the agent ROOT-EQUIVALENT on this host. The"
        echo "    command allowlist keeps the model on rails, but it does not"
        echo "    contain an agent that has sudo. Say yes only if you want the"
        echo "    agent to administer this machine."
        echo
        echo "    You can enable it later with: SENTINELX_ENABLE_SUDO=1"
        echo
        read -r -p "    Allow passwordless sudo for sentinelx? [y/N] " REPLY
        REPLY="${REPLY:-n}"
    fi

    if [[ "${REPLY,,}" =~ ^(y|yes)$ ]]; then
        info "Installing sudoers rule at $SUDOERS_FILE"
        # Atomic install: write to temp, validate with visudo, then rename.
        # If validation fails, sudoers stays untouched.
        SUDOERS_TMP="$(mktemp /tmp/sentinelx-sudoers.XXXXXX)"
        cat > "$SUDOERS_TMP" <<'EOF'
# Generated by sentinelx-cloud-installer, at the operator's explicit request.
# Allows the unprivileged 'sentinelx' user (which the agent runs as) to
# execute commands as root without a password.
#
# This makes the agent root-equivalent on this host. The command allowlist in
# /etc/sentinelx/config.yaml keeps the model on rails but does not bound an
# agent that has sudo, so do not rely on it as a security boundary here.
#
# To revoke: rm /etc/sudoers.d/sentinelx  (then restart the agent)
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
        SUDO_ENABLED=1
        info "Sudoers rule installed and validated"
        warn "This agent is now root-equivalent on this host."
    else
        info "No sudo configured (the default). The agent can read the system"
        info "    and work with files the 'sentinelx' user owns; anything"
        info "    needing root will fail with a permission error."
        info "    To grant it later: SENTINELX_ENABLE_SUDO=1 bash install.sh"
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
    # Preflight: the interactive token prompt hangs when `sudo` uses
    # `Defaults use_pty` (default on modern Ubuntu). Warn up front with the
    # clean workaround so a stall is never a silent mystery.
    if [ -n "${SUDO_USER:-}" ] \
        && grep -REqs '^[[:space:]]*Defaults[^!]*use_pty' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        warn "Your sudo uses 'Defaults use_pty'. If the token prompt below stalls"
        warn "after you paste, press Ctrl-C and re-run as root (no sudo in the pipe):"
        warn "    sudo -i"
        warn "    curl -fsSL https://get.sentinelx.app | bash"
    fi
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
        # No fallback config. config.example.yaml ships with the core repo, so a
        # missing example means an incomplete or corrupted checkout. Fail loudly
        # rather than writing a config that would silently drift from the
        # canonical example (which is exactly how the two drifted before).
        err "$EXAMPLE_CONFIG not found in the sentinelx-cloud-core checkout."
        err "config.example.yaml ships with the agent, so this means the download"
        err "or clone is incomplete/corrupted. Re-fetch the agent and retry."
        exit 1
    fi
    chmod 644 "$ETC_DIR/config.yaml"
fi

mkdir -p /var/lib/sentinelx/uploads
chown -R sentinelx:sentinelx /var/lib/sentinelx

# --- install systemd unit ----------------------------------------------------
#
# NoNewPrivileges is the difference between the two profiles, and it is
# enforced by the kernel rather than by anything the agent checks. Without
# sudo we set it: nothing the agent runs -- an allowlisted command, a script,
# an edit -- can then acquire privileges by any route, so "this agent cannot
# become root on this host" is a fact rather than a promise. With sudo we
# cannot set it, because it would block sudo itself; on those hosts the agent
# is root-equivalent by the operator's explicit choice.
if [[ "$SUDO_ENABLED" == "1" ]]; then
    HARDENING="# This host granted the agent passwordless sudo, so NoNewPrivileges
# is deliberately NOT set: it would block sudo and every root operation
# would fail with a permission error. The agent is root-equivalent here.
# To lock it down, remove /etc/sudoers.d/sentinelx and re-run the installer."
else
    HARDENING="# No sudo was granted, so privilege escalation is blocked outright.
# Kernel-enforced: no command, script or edit run by the agent can gain
# privileges, regardless of what the agent is asked to do.
NoNewPrivileges=yes"
fi

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

$HARDENING

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
systemctl enable sentinelx-cloud-core.service

# restart, not `enable --now`: on a host that already had the agent running,
# `--now` is a no-op, so the freshly installed code sat on disk while the old
# process kept serving from memory -- an upgrade that silently did nothing and
# still printed "SentinelX is running". That is how someone re-running this
# installer to pick up a security fix would have stayed on the vulnerable
# version. restart covers both cases: it starts a stopped service and replaces
# a running one.
systemctl restart sentinelx-cloud-core.service

# --- final status ------------------------------------------------------------
sleep 2
if systemctl is-active --quiet sentinelx-cloud-core.service; then
    # Report the version the RUNNING process will serve, read from the venv
    # the unit actually executes. Printing "running" without it is what let a
    # no-op upgrade look like a successful one.
    RUNNING_VERSION="$("$INSTALL_DIR/.venv/bin/python" -c \
        'import importlib.metadata as m; print(m.version("sentinelx-cloud-core"))' \
        2>/dev/null || echo "unknown")"
    info "SentinelX is running (agent $RUNNING_VERSION)."
    echo
    echo "  Status:   systemctl status sentinelx-cloud-core"
    echo "  Logs:     journalctl -u sentinelx-cloud-core -f"
    echo "  Hub URL:  $HUB_URL"
    echo "  Host ID:  $HOST_ID"
    echo "  Config:   $ETC_DIR/config.yaml"
    echo
    info "One step left — connect SentinelX to your AI assistant:"
    echo
    echo "  Connector URL:  $HUB_URL/mcp/mcp"
    echo "  Dashboard:      $HUB_URL/dashboard   (view and manage your hosts)"
    echo
    echo "  Claude:   Settings → Connectors → Add custom connector → paste the URL"
    echo "  ChatGPT:  https://chatgpt.com/apps/sentinelx/asdk_app_69f63e01766881919640f03b5e7912a5"
    echo
    echo "  Full guide:  https://sentinelx.app/#setup"
else
    warn "Service did not start cleanly."
    warn "Check 'journalctl -u sentinelx-cloud-core -n 50'"
    journalctl -u sentinelx-cloud-core -n 20 --no-pager
    exit 1
fi

