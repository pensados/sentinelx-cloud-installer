#!/usr/bin/env bash
#
# SentinelX bootstrap — detects the OS and runs the right installer.
#
#   curl -fsSL https://get.sentinelx.app | bash
#
# Pass any SENTINELX_* env vars through as usual, e.g. on a headless Mac server:
#   curl -fsSL https://get.sentinelx.app | SENTINELX_MODE=system bash
#
set -euo pipefail
BASE="${SENTINELX_BASE_URL:-https://get.sentinelx.app}"

case "$(uname -s)" in
  Darwin)
    # macOS installs per-user (uv's Python lives under your home; the installer
    # elevates only for a system-mode LaunchDaemon). It must NOT run as root.
    # If someone ran the old `| sudo bash`, drop back to the invoking user.
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
      echo "SentinelX: on macOS the install must be user-owned; re-running as ${SUDO_USER}." >&2
      exec sudo -u "$SUDO_USER" -E bash -c "curl -fsSL '$BASE/install-macos.sh' | bash"
    fi
    curl -fsSL "$BASE/install-macos.sh" | bash
    ;;
  Linux)
    # Linux needs root; self-elevate if we're not already there.
    if [ "$(id -u)" -eq 0 ]; then
      curl -fsSL "$BASE/install.sh" | bash
    else
      curl -fsSL "$BASE/install.sh" | sudo -E bash
    fi
    ;;
  *)
    echo "SentinelX: unsupported OS '$(uname -s)'. See ${BASE}" >&2
    exit 1
    ;;
esac
