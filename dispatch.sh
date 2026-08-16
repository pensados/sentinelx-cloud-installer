#!/usr/bin/env bash
#
# SentinelX bootstrap - detects the OS and runs the right installer.
#
#   curl -fsSL https://get.sentinelx.app | bash
#
# Pass any SENTINELX_* env vars through, e.g. on a headless Mac server:
#   curl -fsSL https://get.sentinelx.app | SENTINELX_MODE=system bash
#
set -euo pipefail
BASE="${SENTINELX_BASE_URL:-https://get.sentinelx.app}"

# Download-then-run: bash must read the installer from a FILE (not the curl
# pipe), otherwise the interactive enrollment prompt reads the pipe and
# truncates the rest of the script. stdin comes from the terminal so the token
# paste works even under `curl | bash`.
run() {
  local url="$1"; shift
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
  local rc=0
  if (exec </dev/tty) 2>/dev/null; then "$@" bash "$tmp" </dev/tty || rc=$?; else "$@" bash "$tmp" || rc=$?; fi
  rm -f "$tmp"
  return "$rc"
}

case "$(uname -s)" in
  Darwin)
    # macOS installs per-user (uv's Python lives under your home; the installer
    # elevates only for a system-mode LaunchDaemon). Must NOT run as root - if
    # someone used the old `| sudo bash`, drop back to the invoking user.
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
      echo "SentinelX: on macOS the install must be user-owned; re-running as ${SUDO_USER}." >&2
      exec sudo -u "$SUDO_USER" -E bash -c "curl -fsSL '$BASE/dispatch.sh' -o /tmp/sxd.\$\$; bash /tmp/sxd.\$\$; rm -f /tmp/sxd.\$\$"
    fi
    run "$BASE/install-macos.sh"
    ;;
  Linux)
    # Linux needs root; self-elevate if we're not already there.
    if [ "$(id -u)" -eq 0 ]; then run "$BASE/install.sh"; else run "$BASE/install.sh" sudo -E; fi
    ;;
  *)
    echo "SentinelX: unsupported OS '$(uname -s)'. See ${BASE}" >&2
    exit 1
    ;;
esac
