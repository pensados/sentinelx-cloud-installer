#!/usr/bin/env bash
# SentinelX core installer. Designed to be `curl -fsSL get.sentinelx.app | bash`-friendly.
set -euo pipefail

HUB_URL="${SENTINELX_HUB_URL:-https://mcp.sentinelx.app}"
INSTALL_DIR="${SENTINELX_INSTALL_DIR:-/opt/sentinelx-core}"
ETC_DIR="/etc/sentinelx"
RELEASE_TAG="${SENTINELX_VERSION:-latest}"

# --- pretty output -----------------------------------------------------------
c_red=$(tput setaf 1 2>/dev/null || true)
c_grn=$(tput setaf 2 2>/dev/null || true)
c_yel=$(tput setaf 3 2>/dev/null || true)
c_rst=$(tput sgr0 2>/dev/null || true)

info()  { echo "${c_grn}[+]${c_rst} $*"; }
warn()  { echo "${c_yel}[!]${c_rst} $*"; }
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
for cmd in curl python3 systemctl; do
    command -v "$cmd" >/dev/null || fatal "Missing required tool: $cmd"
done

# --- generate or reuse host_id -----------------------------------------------
mkdir -p "$ETC_DIR"
if [[ ! -f "$ETC_DIR/host_id" ]]; then
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

# --- install core code -------------------------------------------------------
info "Installing sentinelx-core to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# In real life this fetches a release tarball from GitHub Releases.
# For now we assume it's downloaded somehow:
TARBALL_URL="https://github.com/pensados/sentinelx-core/releases/${RELEASE_TAG}/download/sentinelx-core-${ARCH}.tar.gz"

if [[ "$RELEASE_TAG" == "latest" ]]; then
    TARBALL_URL="https://github.com/pensados/sentinelx-core/releases/latest/download/sentinelx-core-${ARCH}.tar.gz"
fi

curl -fsSL "$TARBALL_URL" | tar -xz -C "$INSTALL_DIR" --strip-components=1
chown -R sentinelx:sentinelx "$INSTALL_DIR"

# --- enroll with the hub -----------------------------------------------------
info "Starting enrollment flow..."
ENROLL_PY="$INSTALL_DIR/bin/sentinelx-enroll"
if [[ ! -x "$ENROLL_PY" ]]; then
    fatal "Missing enrollment script at $ENROLL_PY"
fi

if [[ -f "$ETC_DIR/identity.json" ]]; then
    warn "Existing identity.json found; skipping enrollment. Run sentinelx-enroll to re-enroll."
else
    "$ENROLL_PY" --hub "$HUB_URL" --host-id "$HOST_ID" --output "$ETC_DIR/identity.json"
    chmod 600 "$ETC_DIR/identity.json"
    chown sentinelx:sentinelx "$ETC_DIR/identity.json"
fi

# --- install systemd unit ----------------------------------------------------
info "Installing systemd unit"
cat > /etc/systemd/system/sentinelx-core.service <<EOF
[Unit]
Description=SentinelX Core agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sentinelx
Group=sentinelx
ExecStart=$INSTALL_DIR/bin/sentinelx-core --hub $HUB_URL --identity $ETC_DIR/identity.json
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$INSTALL_DIR /var/log/sentinelx

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/log/sentinelx
chown sentinelx:sentinelx /var/log/sentinelx

systemctl daemon-reload
systemctl enable --now sentinelx-core.service

# --- final status ------------------------------------------------------------
sleep 1
if systemctl is-active --quiet sentinelx-core.service; then
    info "SentinelX is running."
    echo
    echo "  Status:   systemctl status sentinelx-core"
    echo "  Logs:     journalctl -u sentinelx-core -f"
    echo "  Hub URL:  $HUB_URL"
    echo
    info "Done. Add SentinelX in Claude → Settings → Connectors."
else
    warn "Service did not start cleanly. Check 'journalctl -u sentinelx-core'."
    exit 1
fi
