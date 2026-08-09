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
services:
  # Pre-registered so common web-server and agent ops work on a fresh install
  # (e.g. the "restart nginx" example in the docs). Safe actions only, no
  # stop/start. Add more services, or more actions, below as you need them.
  nginx:
    actions: [status, restart, reload]
  # Apache is httpd on RHEL/Fedora, apache2 on Debian/Ubuntu. Both listed so
  # "restart my web server" works either way; a missing unit just errors.
  httpd:
    actions: [status, restart, reload]
  apache2:
    actions: [status, restart, reload]
  # The agent itself, so the LLM can reload policy after you edit this file.
  # Restart re-reads /etc/sentinelx/config.yaml (brief reconnect). No start/stop
  # on purpose: the agent can't bring itself back up once stopped.
  sentinelx-cloud-core:
    actions: [status, restart, is-active, is-enabled]

playbooks:

  add_allowed_command:
    description: |
      How to add a new command to this host's allowlist persistently.
    when: |
      The user asks to allow a new command on this host (e.g. "let me run
      htop", "add ncdu to the allowlist", "I need ripgrep here"). Use this
      playbook to extend the policy permanently. For one-off needs,
      sentinel_script_run is usually a better fit.
    steps:
      - "Read the current config to confirm the file path and locate the
         allowed_commands section: call sentinel_exec with command 'sudo
         cat /etc/sentinelx/config.yaml'."
      - "Use sentinel_edit in 'replace' mode to insert the new command
         under the allowed_commands list. Anchor the edit on an existing
         '  - <something>' line that's adjacent to where the new entry
         logically belongs (alphabetical or by category). Pass sudo=true
         since /etc/sentinelx is root-owned. Use validator_preset='yaml' so
         the edit is rejected if it produces invalid YAML."
      - "Reload the agent so the new policy takes effect. Two paths,
         depending on whether 'sentinelx-cloud-core' is declared in
         this same config under services:
         (a) if declared: sentinel_service action='restart'
             service='sentinelx-cloud-core'. The WS session will drop
             when the agent restarts itself; this is expected and the
             agent reconnects automatically.
         (b) if NOT declared: ask the operator to run on a terminal
             'sudo systemctl restart sentinelx-cloud-core' once. After
             that one-time bootstrap, declaring sentinelx-cloud-core in
             services lets future restarts use path (a) without manual
             intervention. The default config.example.yaml ships with
             this service declared, so path (a) is the typical case."
      - "Verify the change took effect by calling sentinel_capabilities and
         confirming the new command appears in allowed_commands. If it
         doesn't, the agent didn't reload — check the journal with
         sentinel_exec 'sudo journalctl -u sentinelx-cloud-core -n 30'."
    requires:
      - "sudo access on /etc/sentinelx/config.yaml (set up by the installer)."
      - "Either: 'sentinelx-cloud-core' declared as a managed service in this
         same config (the default config.example.yaml ships it), OR a way to
         run 'sudo systemctl restart sentinelx-cloud-core' on a real terminal
         for the one-time bootstrap. Once the service is declared and the
         agent has loaded the new policy, future restarts can be done via
         sentinel_service without operator intervention."
    notes:
      - "If the user only needs the command for a single invocation, prefer
         sentinel_script_run over modifying the policy. Scripts run inside
         a subshell where every command is still allowlist-checked, so this
         is not a way to bypass policy — it's a way to compose allowed
         commands without persisting the new entry."
      - "Avoid adding commands that grant broad privilege escalation (su,
         chsh, visudo, unrestricted sudo, etc.) without warning the user.
         The whole point of the allowlist is to be conservative."
      - "Allowed commands are matched as PREFIXES, not exact strings. So
         'sudo cat' allows 'sudo cat /etc/passwd' but NOT 'sudo cattool'.
         When adding a new entry, think about what completions of that
         prefix should be reachable."

  add_allowed_read_path:
    description: |
      How to add a new directory to this host's file_ops read allowlist
      persistently, so sentinel_read / sentinel_list / sentinel_search can
      operate under it.
    when: |
      The user asks to let the assistant read, list, or search a directory
      that is currently rejected with 'path_not_allowed' (e.g. "let me read
      files under /data", "I want you to be able to search /srv/app", "add
      /home/me/projects to what you can see"). Use this playbook to extend
      file_ops.allowed_read_paths permanently. This is the read-only
      counterpart to add_allowed_command.
    steps:
      - "Confirm what the user actually wants exposed. allowed_read_paths
         entries are PREFIXES: adding '/data' makes everything under
         /data readable by sentinel_read/list/search. If the user names a
         single file, add its parent directory and tell them the whole
         directory becomes readable, not just that file. If they name a
         broad path (/home, /, /etc on a shared box), pause and confirm —
         see the notes below."
      - "Read the current config to confirm the file path and locate the
         file_ops section: call sentinel_exec with command 'sudo cat
         /etc/sentinelx/config.yaml'. If there is no file_ops block yet,
         this playbook still applies — you will be creating it."
      - "Use sentinel_edit in 'replace' mode to add the new entry under
         file_ops.allowed_read_paths. Anchor the edit on an existing
         '    - <path>' line in that list. If the file_ops block does not
         exist at all, add the whole block (file_ops: / allowed_read_paths:
         / the entry) anchored on a stable nearby line such as the end of
         the security block. Pass sudo=true since /etc/sentinelx is
         root-owned. Use validator_preset='yaml' so the edit is rejected
         if it produces invalid YAML."
      - "Reload the agent so the new policy takes effect. Two paths,
         depending on whether 'sentinelx-cloud-core' is declared in this
         same config under services:
         (a) if declared: sentinel_service action='restart'
             service='sentinelx-cloud-core'. The WS session will drop
             when the agent restarts itself; this is expected and the
             agent reconnects automatically.
         (b) if NOT declared: ask the operator to run on a terminal
             'sudo systemctl restart sentinelx-cloud-core' once. The
             default config.example.yaml ships with this service
             declared, so path (a) is the typical case."
      - "Verify the change took effect by calling sentinel_capabilities and
         confirming the new path appears under file_ops.allowed_read_paths.
         Then do a positive check: call sentinel_list on the new path and
         confirm it no longer returns 'path_not_allowed'. If it still does,
         the agent didn't reload — check the journal with sentinel_exec
         'sudo journalctl -u sentinelx-cloud-core -n 30'."
    requires:
      - "sudo access on /etc/sentinelx/config.yaml (set up by the installer)."
      - "Either: 'sentinelx-cloud-core' declared as a managed service in this
         same config (the default config.example.yaml ships it), OR a way to
         run 'sudo systemctl restart sentinelx-cloud-core' on a real terminal
         for the one-time bootstrap."
    notes:
      - "allowed_read_paths is matched as PREFIXES, after canonicalizing the
         requested path (symlinks resolved, '..' collapsed). Adding '/data'
         reaches everything under /data; it does NOT reach '/data-private'
         (no shared prefix boundary). Think about what the prefix opens up."
      - "This only affects the read-only primitives (sentinel_read,
         sentinel_list, sentinel_search). It does NOT grant exec, edit, or
         any write capability. It is strictly additive read visibility."
      - "Be cautious with broad paths. Adding '/home' on a multi-user or
         personal machine exposes everyone's personal files to recursive
         search; adding '/' exposes the whole filesystem (still bounded by
         the agent user's unix permissions, but that is a weak second line,
         not a real boundary). When the user asks for a broad path, confirm
         they understand the scope before applying the edit. The whole point
         of the allowlist is to be a deliberate, narrow boundary."
      - "If the user only needs to read something once, it may not be worth
         a permanent policy change — but unlike commands, there is no
         one-off read primitive, so a config change is the only path. Keep
         the entry as narrow as the use case allows."

  update_sentinelx_code:
    description: |
      Update the SentinelX agent on this host to the latest commit on main.
    when: |
      The user asks to update, upgrade, or pull the latest version of
      SentinelX on this host (e.g. "update sentinelx", "is there a new
      version of the agent?", "pull the latest"). This playbook handles
      the AGENT CODE only — config changes are handled separately by
      sync_sentinelx_config.
    steps:
      - "Check the current commit with sentinel_exec: 'cd
         /opt/sentinelx-cloud-core && sudo -u sentinelx git log --oneline -1'.
         Note the SHA. This is what we'll be moving away from."
      - "Fetch and compare with sentinel_exec: 'cd /opt/sentinelx-cloud-core
         && sudo -u sentinelx git fetch origin main && sudo -u sentinelx
         git log HEAD..origin/main --oneline'. If the output is EMPTY, the
         agent is already up to date — STOP HERE and tell the user. If
         non-empty, summarize the incoming commits before pulling."
      - "Check pip install mode with sentinel_exec: 'sudo
         /opt/sentinelx-cloud-core/.venv/bin/pip show sentinelx-cloud-core
         | grep -E \"Editable|Location\"'. If 'Editable project location:'
         is present, the install is editable and a git pull is sufficient.
         If absent, pip reinstall will be required after the pull (older
         installs predate commit 030190c which switched the installer to
         editable mode)."
      - "Check whether new dependencies are needed with sentinel_exec: 'cd
         /opt/sentinelx-cloud-core && sudo -u sentinelx git diff
         HEAD..origin/main --name-only | grep -E
         \"pyproject|setup\\.py|setup\\.cfg|requirements\"'. If output is
         non-empty, pip reinstall will be needed even on editable installs
         (new deps to fetch). If empty, code-only update."
      - "Pull with sentinel_exec: 'cd /opt/sentinelx-cloud-core && sudo -u
         sentinelx git pull --ff-only origin main'. If --ff-only fails, the
         working tree has local changes — STOP and tell the user; this is
         not a routine update path and probably needs human review."
      - "(Conditional) If step 3 said NOT editable OR step 4 found
         pyproject changes, reinstall with sentinel_exec: 'sudo
         /opt/sentinelx-cloud-core/.venv/bin/pip install -e
         /opt/sentinelx-cloud-core'. Otherwise, skip this step."
      - "Restart the agent. Two paths (same as add_allowed_command):
         (a) if sentinelx-cloud-core is declared in services:
             sentinel_service action='restart' service='sentinelx-cloud-core'.
             The WS session will drop while the agent restarts itself; this
             is expected. The agent reconnects to the hub automatically.
         (b) if NOT declared: ask the user to run on a real terminal: 'sudo
             systemctl restart sentinelx-cloud-core'."
      - "Verify with sentinel_capabilities. The agent should respond and
         the response should reflect any new capabilities. If capabilities
         errors out, the new version may have a startup bug — check the
         journal with sentinel_exec: 'sudo journalctl -u sentinelx-cloud-core
         -n 30 --no-pager'."
      - "(Optional follow-up) Mention to the user that config.example.yaml
         may have new playbooks, services, or commands not yet in their
         /etc/sentinelx/config.yaml. Offer to walk through them via the
         sync_sentinelx_config playbook. Don't run that automatically — the
         user decides whether to adopt new config defaults."
    requires:
      - "sudo access on /opt/sentinelx-cloud-core (set up by the installer)."
      - "git, pip, journalctl in the allowlist (all in the default config)."
      - "Either sentinelx-cloud-core declared in services for self-restart,
         or operator availability for a one-time bootstrap restart on a
         terminal."
    notes:
      - "This playbook handles the HAPPY PATH for a recent install. It does
         NOT handle: custom branches or forks, working trees with local
         modifications, agent versions older than the editable-mode
         migration with non-trivial schema changes. Those need human
         review."
      - "Updates to /etc/sentinelx/config.yaml are NOT handled here. The
         user's config is independent of the repo's config.example.yaml —
         git pull does NOT modify /etc/sentinelx/config.yaml. To pick up
         new playbooks, services, or commands shipped in the example, use
         sync_sentinelx_config."
      - "Bootstrap problem: the FIRST time this playbook runs on a host
         that didn't previously have sentinelx-cloud-core declared in
         services, step 7(b) requires manual intervention. After that
         one-time bootstrap, every future run goes through 7(a) without
         operator help."
      - "Rollback: this playbook does not handle rolling back an update.
         If something breaks after an update, the operator can manually
         'git reset --hard <previous-commit>' in /opt/sentinelx-cloud-core
         and restart. That diagnostic step is intentionally human-driven."

  sync_sentinelx_config:
    description: |
      Help the user adopt new options from /opt/sentinelx-cloud-core/config.example.yaml
      into their /etc/sentinelx/config.yaml without overwriting their
      customizations. Interactive by design.
    when: |
      The user asks about new playbooks, new services, or new options
      after an update (e.g. "are there new playbooks I'm missing?", "sync
      my config with the latest example", "show me what's new in the
      config"). The user's local /etc/sentinelx/config.yaml is NEVER
      touched by git pull, so improvements to config.example.yaml don't
      propagate automatically. This playbook helps adopt them selectively.
    steps:
      - "Verify the repo is up to date by checking that
         /opt/sentinelx-cloud-core/config.example.yaml is newer than the
         user's last sync. The simplest signal: check 'cd
         /opt/sentinelx-cloud-core && sudo -u sentinelx git log -1
         --format=%ci config.example.yaml' against the mtime of
         /etc/sentinelx/config.yaml. If the example is older or equal,
         suggest running update_sentinelx_code first."
      - "Compute the diff with sentinel_exec: 'sudo diff
         /etc/sentinelx/config.yaml
         /opt/sentinelx-cloud-core/config.example.yaml'. Show the user the
         output. The diff will fall into categories: new playbook entries,
         new service declarations, new commands in the allowlist, updated
         comments, and (rarely) removed options. The user's customizations
         that aren't in the example are PRESERVED — they only show up as
         lines marked '<' in the diff."
      - "Walk the user through each diff hunk and categorize it. Suggested
         framing: 'New feature you might want' (playbooks, services), 'New
         documentation' (comments), 'Your customization (preserve)'
         (anything in user but not in example), 'Possibly obsolete'
         (anything removed in the example). Ask which categories to merge."
      - "For each section the user wants to adopt, use sentinel_edit in
         'replace' mode with sudo=true and validator_preset='yaml'. Anchor
         each insert on a stable line (e.g., a section comment header
         like '# ============================================================================').
         Make ONE edit at a time, NOT a wholesale file replace — that
         would lose user customizations. After each edit, the agent
         creates a .bak file automatically; mention this to the user."
      - "After all edits, sanity-check the result with sentinel_exec:
         'sudo cat /etc/sentinelx/config.yaml | python3 -c \"import sys,
         yaml; yaml.safe_load(sys.stdin); print(\\\"YAML OK\\\")\"'.
         If this fails, an edit produced invalid YAML — restore from one
         of the .bak files (sentinel_edit creates one per edit) and try
         again with smaller hunks."
      - "Reload the agent (same as update_sentinelx_code step 7): either
         (a) sentinel_service action='restart' service='sentinelx-cloud-core',
         or (b) ask the user for a manual restart if the service isn't
         declared yet."
      - "Verify with sentinel_capabilities — new playbooks and services
         should appear in the response. If a new playbook is now present
         but references a service the user hasn't declared, warn the user
         that the playbook will fail at runtime until that service is
         added."
    requires:
      - "sudo access on /etc/sentinelx/config.yaml."
      - "git repo at /opt/sentinelx-cloud-core/ with recent fetch (run
         update_sentinelx_code first if unsure)."
      - "Either sentinelx-cloud-core in services for self-restart, or
         operator for a manual restart."
    notes:
      - "This playbook is fundamentally INTERACTIVE. The LLM should NEVER
         blindly merge config.example.yaml into the user's config. The
         user may have intentional customizations (custom allowlist, custom
         services, deliberately removed defaults). Always show the diff
         and confirm with the user before each edit."
      - "The diff might be large after a long gap between updates. There
         is no urgency to merge everything in one session — the user's
         existing config keeps working. Break the merge into multiple
         passes if the diff is overwhelming."
      - "Why isn't this automatic? Because /etc/sentinelx/config.yaml is
         the user's source of truth. Auto-merging would risk overwriting
         intentional customizations. A future version of SentinelX may
         move built-in playbooks into the agent code itself, eliminating
         this drift entirely; until then, this playbook closes the gap."
      - "Pro tip: to see only NEW additions in the example (lines present
         in example but not in user), use 'sudo diff
         /etc/sentinelx/config.yaml
         /opt/sentinelx-cloud-core/config.example.yaml | grep \"^>\"'.
         To see only the user's customizations (present in user but not
         in example), use the same diff with grep \"^<\"."

  create_binary_playbook:
    description: |
      Compose a new playbook that documents how the LLM should use a
      specific binary that's already in the allowlist. Output is a YAML
      block ready to insert under playbooks:.
    when: |
      User asks to "add a playbook for X", "document how to use Y",
      "create a recipe for Z", or "explain to the LLM how to use BIN"
      where BIN is a CLI tool already permitted by the allowlist but
      doesn't have a dedicated playbook yet. Common with custom infra
      tooling (e.g., site-specific helpers, internal CLIs).
    steps:
      - "Confirm the target binary is allowlisted by calling
         sentinel_capabilities and looking for it under allowed_commands.
         If NOT allowlisted, tell the user to add it first via the
         add_allowed_command playbook. Do NOT proceed without this check
         — a playbook for a non-allowlisted binary is dead documentation."
      - "Discover the binary's interface (Camino D — the project's
         convention). Try in order:
         (a) sentinel_exec '<binary>' (no args). Many binaries print help
             on bare invocation. SAFE only if you trust the binary not to
             do something on no-args (most help-printers do nothing else).
         (b) If (a) executes something instead of printing help, try
             sentinel_exec '<binary> --help'.
         (c) If neither works, ask the user for a sample command-line."
      - "Read the help output and DETERMINE: the binary's primary purpose,
         the available subcommands or modes, the required vs optional
         flags, any explicit safety notes the help itself mentions."
      - "Ask the user (or infer from the conversation if the user has
         been clear) the following before composing:
         - PRIMARY use case in one phrase (becomes 'description:').
         - Trigger phrases the user might say (becomes 'when:').
         - Any 'gotchas' from past use (becomes 'notes:').
         - Whether the binary needs sudo: ALWAYS, sometimes, or never?
         - What other commands it depends on (e.g., DNS records before
           hosting setup) — becomes 'requires:'.
         - Whether any subcommands are destructive (delete, drop, reset)
           — these get explicit 'confirm with user' notes."
      - "DRY-RUN: compose a draft playbook following the standard shape
         (description, when, steps, requires, notes). Show it to the user
         in a fenced YAML block. INCLUDE in the steps a 'if unsure, run
         <binary> (without args)' line — Camino D should always be
         present. Do NOT write to /etc/sentinelx/config.yaml yet."
      - "Wait for the user's response. Possible outcomes:
         (a) approves as-is → proceed to apply.
         (b) requests changes → revise the draft, show again, loop until
             user is satisfied.
         (c) rejects → stop. The draft costs nothing to discard."
      - "APPLY (only after explicit user approval): use sentinel_edit
         in 'replace' mode with sudo=true and validator_preset='yaml'.
         Anchor on a stable line — typically a section header like
         '# CATEGORY B' if the playbook is for custom tooling, or just
         before the next existing playbook. Insert ONE playbook at a
         time."
      - "Reload the agent so the new playbook is exposed in capabilities:
         sentinel_service action='restart' service='sentinelx-cloud-core'."
      - "Verify by calling sentinel_capabilities — the new playbook
         should appear in the playbooks: map with all five expected
         fields (description, when, steps, requires, notes). If a field
         is missing or malformed, the YAML edit went wrong; check the
         .bak that sentinel_edit created."
    requires:
      - "The target binary must already be in allowed_commands (run
         add_allowed_command first if needed)."
      - "sentinel_edit + sudo for /etc/sentinelx/config.yaml."
      - "sentinelx-cloud-core declared in services for self-restart, OR
         operator availability for a manual restart."
    notes:
      - "Do NOT auto-generate playbook content from imagination. ALWAYS
         base it on (a) what the binary's --help/no-args output actually
         says, and (b) what the user tells you in the conversation. If
         neither is informative enough, ask clarifying questions instead
         of guessing — guesses become wrong notes that mislead future
         operators."
      - "ALWAYS include 'if unsure about exact args, run <binary>
         (without args) to see help' as one of the steps. This is the
         project convention (Camino D) — it lets future operators verify
         the syntax dynamically without relying on the playbook being
         fresh. Static documentation rots; the binary's own help does not."
      - "DON'T duplicate the binary's --help in the playbook. The
         playbook's job is to add CONTEXT (when to invoke, what comes
         before, what comes after, what to watch out for) — NOT to
         repeat what the binary already documents itself."
      - "For destructive subcommands (delete, drop, remove, reset, kill,
         purge, wipe), include both: (1) a step that says 'confirm with
         user before invoking' and (2) a note explaining why the action
         is destructive and whether it's reversible."
      - "If the binary needs sudo only sometimes (e.g., 'pensa-X' for
         user paths and 'sudo pensa-X' for /etc paths), the steps should
         show both forms and the requires: should mention both
         allowlist entries."
      - "Naming convention: prefer verb_noun snake_case for the playbook
         key (e.g., create_cloudflare_subdomain, send_email,
         provision_hosting_site). Avoid generic names like 'use_X' or
         'X_helper'. The name itself is part of the LLM's matching
         signal for 'when:'."
      - "There's a similar meta-playbook for systemd services
         (add_service) and for allowlist entries (add_allowed_command).
         Together they let the LLM extend the agent's policy in all
         three dimensions: commands, services, and the playbooks that
         document them."

  add_service:
    description: |
      Add a new systemd service to the policy so the LLM can manage it
      via sentinel_service (status, restart, etc).
    when: |
      User asks to "add service X to the allowlist", "let me restart Y
      via the agent", "manage Z with sentinelx", or any equivalent
      phrasing where Z is a systemd unit not currently exposed in the
      services: map.
    steps:
      - "Verify the systemd unit actually exists on this host. Run:
         sentinel_exec 'systemctl list-unit-files <unit-name>*' (with
         trailing wildcard to allow @-instance variants). If the unit
         is NOT installed, STOP — tell the user to install the package
         first. Adding a non-existent unit to the policy is dead config."
      - "Confirm the unit is NOT already in services. Call
         sentinel_capabilities and check the services: map. If already
         present, ask the user whether they want to UPDATE the actions
         (different concern) or if they thought it was missing (mistake)."
      - "Determine the SERVICE KEY (the name in the map) and the UNIT
         (the .service file). Default rule: if the unit name is
         'foo.service', use 'foo' as both key and unit. If the unit has
         a suffix that matters (e.g., 'foo-agent.service'), use the full
         name in unit and a short key like 'foo'. Ask the user if unsure."
      - "Determine the ACTIONS the user wants to expose. Ask the user
         (or infer from context) which TIER fits:
         (a) Read-only: [status, is-active, is-enabled]
             — for critical services where you only want inspection.
             Examples: ssh, networking, the agent itself.
         (b) Conservative: [status, restart, is-active, is-enabled]
             — for typical services that may need reloading.
             Examples: nginx, the agent itself, most daemons.
         (c) Operational: [status, start, stop, restart, reload,
             is-active, is-enabled]
             — for services the user controls fully via the LLM.
             Examples: docker, application servers.
         Prefer (b) by default unless the user explicitly needs (c)."
      - "Determine sudo requirements. Most system services need sudo
         to manage. Set requires_sudo=true UNLESS the user is running a
         systemd --user service (rare in production). Confirm by trying
         'sudo systemctl is-active <unit>' — if it works without password
         prompt, the agent's sudoers covers it (which is the default
         installer config)."
      - "(Optional) Determine a description. One short sentence is
         enough — appears in capabilities to help the LLM understand
         context. Skip if no useful summary comes to mind."
      - "DRY-RUN: compose the YAML block following the standard shape:

         <key>:
           unit: <unit-name>
           actions: [<list>]
           requires_sudo: <bool>
           description: \"<optional>\"

         Show it to the user in a fenced YAML block. Do NOT write to
         /etc/sentinelx/config.yaml yet."
      - "Wait for user response. Possible outcomes:
         (a) approves → proceed to apply.
         (b) requests changes → revise (e.g., different action tier),
             show again.
         (c) rejects → stop."
      - "APPLY (only after explicit user approval): use sentinel_edit
         in 'replace' mode with sudo=true and validator_preset='yaml'.
         Anchor the edit on a stable line within the services: section
         (e.g., on the existing nginx or docker block). Insert ONE
         service at a time."
      - "Reload the agent so the new service is exposed. Two paths
         (same as add_allowed_command):
         (a) if 'sentinelx-cloud-core' is declared in services:
             sentinel_service action='restart'
             service='sentinelx-cloud-core'.
         (b) if NOT declared yet: ask the user to run on a terminal
             'sudo systemctl restart sentinelx-cloud-core' once."
      - "Verify by calling sentinel_capabilities — the new service
         should appear in services: with the correct unit, actions,
         and requires_sudo flag. Test one of the actions (preferably
         status, the safest): sentinel_service action='status'
         service='<key>'."
    requires:
      - "sentinel_edit + sudo for /etc/sentinelx/config.yaml."
      - "The systemd unit being added must already exist on the host
         (install the package first if needed)."
      - "The agent's sudoers config must cover sudo systemctl for this
         service. The default installer's /etc/sudoers.d/sentinelx is
         broad enough for most cases."
      - "sentinelx-cloud-core in services for self-restart, OR operator
         for manual restart."
    notes:
      - "Tier choice matters for SAFETY. Operational tier (with start/
         stop) lets the LLM bring services UP and DOWN. For services
         whose downtime impacts users (web servers, databases), prefer
         Conservative tier and reserve Operational for explicit user
         control."
      - "Critical services (ssh, networking, the agent itself, docker
         in some setups) should NEVER have stop/start exposed. If the
         agent stops ssh, you lose remote access. If it stops networking,
         you lose everything. Read-only tier protects against this."
      - "Naming convention: service KEY should be lowercase, hyphenated,
         short (e.g., 'nginx', 'postgres', 'sentinelx-cloud-core').
         UNIT field uses the actual systemd unit name (with or without
         .service suffix — both work)."
      - "For services with @-instance variants (e.g., '[email protected]',
         'systemd-resolved.service'), declare the BASE name. The agent
         will dispatch to the right instance based on what the LLM
         passes. If you need to manage specific instances, use distinct
         keys (e.g., postgresql_main, postgresql_replica)."
      - "If the user has a service that they want the LLM to EVER stop
         (e.g., for maintenance windows), Operational tier is the right
         call — but document in the description WHY stop is exposed,
         so future operators understand the risk."
      - "There's a related meta-playbook for binaries
         (create_binary_playbook) and for allowlist entries
         (add_allowed_command). Together they let the LLM extend the
         agent's policy in three dimensions: commands, services, and
         the playbooks that document them."

  sentinelx_meta:
    description: |
      Surface metadata about this SentinelX cloud agent: source repo,
      installed version, available updates, support resources. Use this
      whenever the user asks about the agent itself.
    when: |
      User asks meta-questions about the agent: "what version is this",
      "where's the source code", "is there an update available", "where
      do I report bugs", "show me the changelog", "what's running here",
      "what's behind SentinelX". Also useful as a starting point when
      onboarding a new operator who needs to learn the project layout.
    steps:
      - "For STATIC info (repo URL, install paths, support links), the
         answer is already in the notes section of this playbook — no
         tool call needed. Just read the notes and respond."
      - "For the INSTALLED VERSION (current commit), run:
           cd /opt/sentinelx-cloud-core && git log -1 --format='%h %s (%ci)'
         Output is one line: short SHA + commit message + ISO date.
         Example: '5991315 Remove pensa-safe-edit from default allowlist
         (2026-05-05 01:36:03 +0000)'."
      - "For an UPDATE CHECK (is there anything newer on origin/main?),
         run:
           cd /opt/sentinelx-cloud-core && git fetch origin main 2>&1 \\
              | tail -5 && git log HEAD..origin/main --oneline
         If the second command's output is empty → up-to-date.
         If it shows commits → those are pending updates, list them to
         the user with their messages."
      - "For a quick UPDATE-AVAILABLE summary (just the count behind),
         run:
           cd /opt/sentinelx-cloud-core && git rev-list --count HEAD..origin/main
         Output is a single integer. 0 means up-to-date."
      - "For the REMOTE URL (canonical source), run:
           cd /opt/sentinelx-cloud-core && git remote get-url origin
         Useful if the install was customized to point at a fork."
      - "If the user wants to APPLY pending updates, hand off to the
         update_sentinelx_code playbook. Do NOT run git pull or restart
         from THIS playbook — separation of concerns: this playbook
         informs, update_sentinelx_code applies."
      - "If the user wants to MERGE new defaults from the example into
         their /etc/sentinelx/config.yaml after updating, use the
         sync_sentinelx_config playbook."
    requires:
      - "git in allowlist (default)."
      - "/opt/sentinelx-cloud-core readable by the agent (default install
         location, owned by sentinelx user)."
      - "Network access to github.com for git fetch (otherwise update
         checks fail; static info still works offline)."
    notes:
      - "Source repo: https://github.com/pensados/sentinelx-cloud-core"
      - "Public installer: https://get.sentinelx.app (one-line curl|bash
         install — wraps the install.sh from the sentinelx-cloud-installer
         repo)."
      - "Issues / bug reports:
         https://github.com/pensados/sentinelx-cloud-core/issues"
      - "Discussions / questions:
         https://github.com/pensados/sentinelx-cloud-core/discussions"
      - "Hub URL: https://mcp.sentinelx.app — the central server every
         agent connects to via outbound websocket. The connector URL for
         Claude.ai / ChatGPT is https://mcp.sentinelx.app/mcp/mcp."
      - "Install dir: /opt/sentinelx-cloud-core (managed by the
         installer; safe to inspect, don't edit by hand — use
         update_sentinelx_code to update or sentinel_edit for runtime
         changes)."
      - "Config file: /etc/sentinelx/config.yaml — the policy. Allowlist,
         services, locations, playbooks all live here. Edit via
         sentinel_edit or hand-edit and restart."
      - "Identity file: /etc/sentinelx/identity.json — sensitive (host
         credentials for the hub). Mode 600, owned by the sentinelx user.
         Never share, never include in support tickets, never display
         contents to the user."
      - "Logs: 'journalctl -u sentinelx-cloud-core -f' — live tail.
         '-n 100' for last 100 lines. Look for WARN/ERROR levels first."
      - "If you're checking whether this host can self-update: it can,
         iff (a) update_sentinelx_code is in playbooks, AND (b)
         sentinelx-cloud-core is declared in services with the 'restart'
         action. Both should be true on any default install."
      - "The PROJECT considers updates user-driven, not automatic. There
         is intentionally NO auto-update mechanism — the operator
         decides when to pull new code, and the agent should INFORM
         (via this playbook) but not ACT autonomously on updates."
      - "Related meta-playbooks: add_allowed_command (extend allowlist),
         add_service (declare systemd services), create_binary_playbook
         (document custom CLIs). Together with update_sentinelx_code +
         sync_sentinelx_config they form the agent's self-extension
         surface."

  drop_share:
    description: |
      Use drop.pensa.ar as a temporary buffer for files when transferring
      between hosts, sharing host-side files with the operator/LLM, or
      replicating one file to many hosts. drop.pensa.ar is a self-hosted
      file-drop service (https://github.com/pensados/drop-pensa) that
      accepts uploads up to 50 MB and returns a public URL with
      configurable expiry. Files NEVER pass through the LLM's context.

    when: |
      Use this playbook in any of these scenarios:

        (1) HOST-TO-HOST TRANSFER: copy a file from one enrolled host to
            another (e.g., move /var/log/nginx/error.log from orion to
            atlas for offline analysis). Bytes never touch the LLM
            context.

        (2) SHARE WITH OPERATOR / LLM FOR REVIEW: the user asks Claude
            to look at a file that lives on a host (logs, configs,
            dumps). Uploading via drop and pasting the URL into the
            chat lets Claude web_fetch it without paying the cost of
            base64-inlining a multi-MB file.

        (3) REPLICATE ONE FILE TO MANY HOSTS: if the same artifact must
            land on 3+ hosts (a config snippet, a binary, a cert), drop
            it once and use sentinel_upload_file with file_url N times.
            One POST instead of N base64 encodes.

        (4) USER WANTS TO PUSH A FILE TO A HOST: the operator uploads
            via the drop web UI (https://drop.pensa.ar), pastes the URL
            in chat, then sentinel_upload_file with file_url lands it
            on the target host without any base64 routing through the
            LLM.

      DO NOT use this playbook when:

        - The LLM is creating a NEW file (text, config, code) and
          uploading it to ONE host. In that case, sentinel_upload_file
          with content_base64 (or sentinel_edit with mode='write' for
          text) is one call versus three, with the same actual cost
          on the LLM side. Drop adds steps without saving anything.

        - The file is already at its destination. Don't round-trip
          through drop just because.

    steps:
      - "(SCENARIO 1 — HOST-TO-HOST TRANSFER): on the SOURCE host, run:
         sentinel_exec command='curl -s -F file=@/PATH/TO/FILE
         https://drop.pensa.ar/upload?expires_in=600'.
         The response is JSON; parse out the .url field. Tip: pipe to
         python3 to extract cleanly:
         sentinel_exec command='curl -s -F file=@/PATH https://drop.pensa.ar/upload
         | python3 -c \"import sys,json; print(json.load(sys.stdin)[\\\"url\\\"])\"'.
         Then on the DESTINATION host, call sentinel_upload_file with
         file_url=<that URL> and target_path=<where you want it>.
         The destination agent fetches drop.pensa.ar directly. Verify
         with the sha256 returned in both responses — they MUST match."

      - "(SCENARIO 2 — SHARE WITH OPERATOR/LLM): on the host that has
         the file, run: sentinel_exec command='curl -s -F file=@/PATH
         https://drop.pensa.ar/upload?expires_in=3600 | python3 -c
         \"import sys,json; print(json.load(sys.stdin)[\\\"url\\\"])\"'.
         Show the resulting URL to the operator. The operator pastes
         it in the chat as a separate message — that is the cue for
         Claude to use web_fetch on it. Claude's web_fetch will NOT
         work on URLs the agent generated dynamically; the operator's
         paste is what authorizes the fetch."

      - "(SCENARIO 3 — ONE-TO-MANY REPLICATION): identical to Scenario 1,
         but instead of a single sentinel_upload_file call, repeat that
         call N times with the same file_url against each destination.
         drop.pensa.ar's default 1-hour expiry covers most multi-host
         pushes; bump expires_in if the operation will span longer."

      - "(SCENARIO 4 — OPERATOR PUSHES A FILE TO A HOST): the operator
         uploads via https://drop.pensa.ar (web UI, drag-and-drop) and
         pastes the resulting URL in chat. Claude then calls
         sentinel_upload_file with file_url=<that URL> on the target
         host. Same flow as Scenario 1, just with a human as the
         original uploader instead of a host."

      - "(VERIFICATION, ALL SCENARIOS): the upload response from drop
         includes 'sha256'. The sentinel_upload_file response after
         file_url fetch includes 'sha256' too. Compare them — they
         must be identical. If they differ, the file was modified
         in transit; abort and investigate."

      - "(CLEANUP, OPTIONAL): drop responses include a 'delete_url'
         with a one-time token. To remove the file before its TTL
         expires (e.g., for sensitive content), run sentinel_exec
         command='curl -s -X DELETE \"<delete_url>\"'. Even if you
         skip this, the file auto-expires per its TTL (1h default,
         7d max)."

    requires:
      - "'curl' in the host's allowlist (default config has it)."
      - "'python3' in the host's allowlist if you want to parse the
         JSON response on-host (default config has it; alternatively
         the operator/LLM can parse the JSON in the chat)."
      - "Network access from each participating host to drop.pensa.ar.
         For this to work behind restrictive firewalls, allow outbound
         HTTPS to drop.pensa.ar (port 443) — same constraint as any
         other outbound HTTPS call."
      - "drop.pensa.ar must be reachable. It's a self-hosted service;
         if it's down, this playbook doesn't work. Status check:
         curl -s https://drop.pensa.ar/healthz."

    notes:
      - "Drop's hard limits: 50 MB per file, 7-day max retention,
         255-char max filename (POSIX NAME_MAX). Rate limits: 30
         uploads/hour per IP, 200 fetches/min per IP plus 100/hour
         per (file, IP) pair, 60 deletes/hour. For files >50 MB,
         fall back to sentinel_upload_init / chunk / complete with
         content_base64 chunks (the chunked upload path supports
         arbitrarily large files but pays the base64 cost per
         chunk)."

      - "HTTP semantics worth knowing when a fetch fails:
         (a) 404 = the file ID was never registered or has fully
             expired (TTL elapsed). Treat as 'try again with a
             fresh upload'.
         (b) 410 Gone = a one-shot upload that has already been
             consumed. Re-fetching is impossible; the file is
             permanently gone. Treat as 'someone else got there
             first, ask the operator to re-upload'.
         (c) 416 = a Range request asked for bytes outside the
             file. Adjust the Range header.
         (d) 429 = rate limited. Wait and retry, or split work
             across hosts.
         The drop service supports HTTP Range requests (RFC 9110)
         for resumable downloads — useful for very large fetches
         over flaky links, though sentinel_upload_file does not
         currently use range-resume."

      - "Since agent v0.2.0 the file_url path of
         sentinel_upload_file enforces a strict allowlist:
         only hostnames in security.trusted_fetch_hosts are
         accepted, the resolved IP must be public-routable
         (loopback / RFC1918 / link-local rejected), https
         only, and redirects are disabled. The current
         allowlist is exposed by sentinel_capabilities under
         the fetch_policy key — check it before passing a
         file_url, and prefer drop.pensa.ar (which is in
         the default allowlist). Any URL outside the
         allowlist will fail with fetch_blocked."

      - "Why drop is faster than the base64-inline path WHEN the
         file does NOT originate in the LLM: the LLM generates ~50
         tokens (the URL) instead of ~12,000 tokens for a 30 KB
         base64 payload. Cost difference scales linearly with
         file size. For LLM-originated files, the LLM still has
         to emit the bytes once somewhere — drop adds steps without
         saving the emission cost in that case (see when: above)."

      - "The sha256 returned by drop is computed at upload time. The
         sha256 returned by sentinel_upload_file (file_url path) is
         computed at fetch time. Matching them confirms end-to-end
         integrity across both networks (LLM → drop → host)."

      - "Drop URLs are unguessable (~78 bits of entropy in the file
         id) but PUBLIC during their TTL. Do NOT upload secrets
         (private keys, passwords, tokens) without setting
         one_shot=true (file deleted on first download) AND keeping
         expires_in short. Even then, treat drop as 'better than
         pasting in chat, worse than a real secret store'."

      - "Reference URLs:
         - service:    https://drop.pensa.ar
         - source:     https://github.com/pensados/drop-pensa
         - api docs:   https://drop.pensa.ar/api"

# ============================================================================
# Logging
# ============================================================================

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
    info "One step left — connect SentinelX to your AI assistant:"
    echo
    echo "  Connector URL:  $HUB_URL/mcp/mcp"
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

