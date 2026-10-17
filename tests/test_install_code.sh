#!/usr/bin/env bash
# install.sh never leaves the host without the agent (sxrep_AWPBMJKC9DG8).
# Runs the real code-install functions, extracted from install.sh, against a fake
# live install: a failed download must change nothing; a good one swaps the code
# in and keeps the user's files; a failed Python setup puts the old install back.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
warn() { :; }
source <(sed -n '/^# --- BEGIN agent-home preservation/,/^# --- END agent-home preservation/p' "$HERE/install.sh")
source <(sed -n '/^# --- BEGIN code install/,/^# --- END code install/p' "$HERE/install.sh")
fail() { echo "FAIL: $*"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

mkdir -p "$W/release/src"; echo new > "$W/release/src/agent.py"
git -C "$W/release" init -q; git -C "$W/release" add -A; git -C "$W/release" commit -qm r

live() {   # a live install: old code (git) + the agent user's own files + a venv
    local d="$1"; mkdir -p "$(dirname "$d")"
    git clone -q "$W/release" "$d"; echo old > "$d/src/agent.py"; git -C "$d" commit -qam old
    mkdir -p "$d/.ssh" "$d/.venv/bin"; echo KEY > "$d/.ssh/id_ed25519"; echo py > "$d/.venv/bin/python"
}
leftovers() { ls -A "$(dirname "$1")" | grep -E '^\.sentinelx-(new|preserve)' || true; }

# --- case 1: the download fails (GitHub blocked) -> nothing changes -----------------------------
D="$W/opt1/sentinelx-cloud-core"; live "$D"
if STAGE="$(stage_core_code "$D" "$W/no-such-repo.git" main 2>/dev/null)"; then fail "a broken repo staged"; fi
[[ "$(cat "$D/src/agent.py")" == old ]] || fail "code touched by a failed download"
[[ -f "$D/.ssh/id_ed25519" && -f "$D/.venv/bin/python" ]] || fail "files touched by a failed download"
[[ -z "$(leftovers "$D")" ]] || fail "left $(leftovers "$D")"
echo "ok: case 1 (download fails): live install untouched, nothing left behind"

# --- case 2: a good download is swapped in, the user's files follow ----------------------------
D="$W/opt2/sentinelx-cloud-core"; live "$D"
STAGE="$(stage_core_code "$D" "$W/release" main 2>/dev/null)"
PREV="$(swap_in_core_code "$D" "$STAGE")"
[[ "$(cat "$D/src/agent.py")" == new ]] || fail "code not replaced"
[[ "$(cat "$D/.ssh/id_ed25519")" == KEY ]] || fail ".ssh did not follow"
[[ -n "$PREV" && "$(cat "$PREV/src/agent.py")" == old ]] || fail "previous install not kept aside"
[[ -z "$(leftovers "$D")" ]] || fail "left $(leftovers "$D")"
echo "ok: case 2 (swap): new code in place, user files kept, old install kept aside"

# --- case 3: the Python setup fails -> the old install comes back, user files included ----------
rollback_core_code "$D" "$PREV"
[[ "$(cat "$D/src/agent.py")" == old ]] || fail "old code not restored"
[[ "$(cat "$D/.ssh/id_ed25519")" == KEY && -f "$D/.venv/bin/python" ]] || fail "old install incomplete after rollback"
[[ ! -e "$PREV" ]] || fail "previous-install dir left behind"
echo "ok: case 3 (rollback): old code and venv back, user files back"

# --- case 4: first install (nothing there yet) ----------------------------------------------------
D="$W/opt4/sentinelx-cloud-core"
STAGE="$(stage_core_code "$D" "$W/release" main 2>/dev/null)"
PREV="$(swap_in_core_code "$D" "$STAGE")"
[[ -z "$PREV" && "$(cat "$D/src/agent.py")" == new ]] || fail "first install"
echo "ok: case 4 (first install)"
echo "ALL OK"
