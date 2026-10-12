#!/usr/bin/env bash
# install.sh keeps the agent user's own files across a reinstall (sxrep_PQG3QSK9V8M0).
# Runs the real preserve/restore functions, extracted from install.sh, against a
# fake old install: git-tracked code + the user's ~/.ssh, ~/.gitconfig, a folder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
warn() { echo "[!] $*"; }
source <(sed -n '/^# --- BEGIN agent-home preservation/,/^# --- END agent-home preservation/p' "$HERE/install.sh")
fail() { echo "FAIL: $*"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch main

# the "new release" repo
mkdir -p "$W/release/src"; echo new > "$W/release/src/agent.py"; echo readme > "$W/release/README.md"
echo "[ship]" > "$W/release/.editorconfig"
git -C "$W/release" init -q; git -C "$W/release" add -A; git -C "$W/release" commit -qm r

# --- case 1: old install with git metadata ---------------------------------------------------
D="$W/opt/sentinelx-cloud-core"; mkdir -p "$W/opt"
git clone -q "$W/release" "$D"; echo old > "$D/src/agent.py"
mkdir -p "$D/.ssh" "$D/repos/myproj" "$D/.venv/bin" "$D/__pycache__"
echo KEY > "$D/.ssh/id_ed25519"; chmod 700 "$D/.ssh"; chmod 600 "$D/.ssh/id_ed25519"
echo "[core]" > "$D/.gitconfig"; echo notes > "$D/repos/myproj/n.txt"; echo x > "$D/.venv/bin/python"
echo mine > "$D/.editorconfig.local"; echo "user-version" > "$D/.editorconfig.mine"
HOLD="$(preserve_agent_home "$D")"
rm -rf "$D"; mkdir -p "$D"; git clone -q "$W/release" "$D"
restore_agent_home "$D" "$HOLD"
[[ "$(cat "$D/src/agent.py")" == new ]] || fail "code not replaced"
[[ "$(cat "$D/.ssh/id_ed25519")" == KEY ]] || fail ".ssh lost"
[[ "$(stat -c %a "$D/.ssh/id_ed25519")" == 600 && "$(stat -c %a "$D/.ssh")" == 700 ]] || fail ".ssh perms changed"
[[ -f "$D/.gitconfig" && -f "$D/repos/myproj/n.txt" && -f "$D/.editorconfig.local" ]] || fail "user files lost"
[[ ! -e "$D/.venv" && ! -e "$D/__pycache__" ]] || fail "old venv/cache carried over"
[[ ! -d "$HOLD" ]] || fail "holding dir left behind"
echo "ok: case 1 (git metadata): code replaced, .ssh/.gitconfig/folders kept with perms, venv dropped"

# --- case 2: a user file collides with one the release ships ---------------------------------
D2="$W/opt2/core"; mkdir -p "$W/opt2"; git clone -q "$W/release" "$D2"
git -C "$D2" rm -q --cached .editorconfig; git -C "$D2" commit -qm untrack   # now user-owned in the old install
echo "user's own" > "$D2/.editorconfig"
HOLD="$(preserve_agent_home "$D2")"; rm -rf "$D2"; mkdir -p "$D2"; git clone -q "$W/release" "$D2"
restore_agent_home "$D2" "$HOLD" >/dev/null
[[ "$(cat "$D2/.editorconfig")" == "[ship]" ]] || fail "release file overwritten"
ls "$D2"/.editorconfig.preserved-* >/dev/null 2>&1 || fail "colliding user file not kept aside"
echo "ok: case 2 (collision): release file wins, the user's copy is kept as .preserved-<stamp>"

# --- case 3: no git metadata: keep only dotfiles ---------------------------------------------
D3="$W/opt3/core"; mkdir -p "$D3/.ssh" "$D3/src"; echo KEY > "$D3/.ssh/k"; echo old > "$D3/src/agent.py"
HOLD="$(preserve_agent_home "$D3")"; rm -rf "$D3"; mkdir -p "$D3"; git clone -q "$W/release" "$D3"
restore_agent_home "$D3" "$HOLD"
[[ -f "$D3/.ssh/k" && "$(cat "$D3/src/agent.py")" == new ]] || fail "no-git case"
echo "ok: case 3 (no git metadata): dotfiles kept, code replaced"

# --- case 4: fresh install (dir doesn't exist) -----------------------------------------------
[[ -z "$(preserve_agent_home "$W/nope")" ]] || fail "fresh install"
restore_agent_home "$W/nope" ""
echo "ok: case 4 (fresh install): nothing to keep"
echo "ALL OK"
