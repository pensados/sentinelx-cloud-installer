#!/usr/bin/env bash
# install.sh does not offer passwordless sudo where sudo isn't installed
# (2026-10-19: in PRoot on Android, answering "y" aborted the install with a
# misleading "failed visudo validation"). Runs the real block from install.sh,
# in a terminal (script(1)) so the question would be asked, with no visudo on PATH.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
command -v script >/dev/null || { echo "SKIP: needs script(1)"; exit 0; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
for t in bash cat mktemp chmod chown mv rm; do ln -s "$(command -v "$t")" "$W/bin/$t"; done
sed -n '/^# --- BEGIN sudo choice/,/^# --- END sudo choice/p' "$HERE/install.sh" \
    | sed "s|/etc/sudoers.d/sentinelx|$W/sudoers-sentinelx|" > "$W/block.sh"
grep -q 'END sudo choice' "$W/block.sh" || fail "markers missing in install.sh"
cat > "$W/run.sh" <<EOF
info() { echo "INFO: \$*"; }; warn() { echo "WARN: \$*"; }; fatal() { echo "FATAL: \$*"; exit 1; }
c_yel=; c_rst=
PATH="$W/bin"
source "$W/block.sh"
echo "SUDO_ENABLED=\$SUDO_ENABLED"
EOF

# 1. Someone at a terminal who would answer "y", and no sudo: no question, no failure.
out="$(printf 'y\n' | script -qec "bash $W/run.sh" /dev/null 2>&1 || true)"
echo "$out" | grep -q 'Allow passwordless sudo' && fail "asked anyway: $out"
echo "$out" | grep -q "isn't installed on this system" || fail "no notice: $out"
echo "$out" | grep -q 'SUDO_ENABLED=0' || fail "did not finish: $out"

# 2. SENTINELX_ENABLE_SUDO=1 without sudo: a clear stop, not the visudo message.
out="$(SENTINELX_ENABLE_SUDO=1 bash "$W/run.sh" </dev/null 2>&1 || true)"
echo "$out" | grep -q 'visudo validation' && fail "old message: $out"
echo "$out" | grep -q "SENTINELX_ENABLE_SUDO=1, but sudo isn't installed" || fail "unclear failure: $out"
echo OK
