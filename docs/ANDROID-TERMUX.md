# Installing SentinelX on Android (Termux)

SentinelX runs on Android through **[Termux](https://termux.dev)** — a Linux
environment app. The agent is pure Python over an **outbound** WebSocket, so your
phone (or any ARM device) becomes a host you can operate from your LLM — with **no
inbound ports and no root**.

This is a **manual install**. The `curl | bash` one-liner targets Linux, macOS, and
Windows; Termux isn't a standard distro (no `apt`, no `systemd`, non-standard paths),
so the steps below adapt the install by hand. Budget **~15 minutes** — one dependency
compiles on-device.

> **Status:** community-tested on aarch64 (Android 14), not yet a first-class install
> target. If you hit a snag, open an issue on the installer repo.

---

## Requirements

- **Termux**, installed from **[F-Droid](https://f-droid.org)** — *not* the Play Store
  (that build is outdated and breaks). Termux is a separate app; it is **not** Termius,
  and it is not the raw Android shell.
- An **aarch64** device (any modern phone/tablet).
- A **SentinelX account** to enroll the host.

---

## 1. Install dependencies

```bash
pkg update && pkg install python git rust bash curl
```

`rust` is required: one Python dependency (`pydantic-core`) is written in Rust and
compiles on-device. `bash` and `curl` are used by the agent and by enrollment.

## 2. Install the agent

```bash
cd ~
git clone https://github.com/pensados/sentinelx-cloud-core.git
cd sentinelx-cloud-core
pip install -e .
```

⏳ **This takes ~10–15 minutes.** `pydantic-core` compiles its Rust extension, and
phones are slow at it. The `Building wheel for pydantic-core ...` spinner will sit
there for a long time — **this is normal, do not cancel.** (In a second Termux session,
`top` will show `rustc`/`cargo` at work.)

## 3. Create the config

```bash
mkdir -p ~/sentinelx/uploads
cat > ~/sentinelx/config.yaml <<'EOF'
# Commands the LLM may run via `exec`. Keep this tight — a phone holds personal
# data. Start minimal and add more only as you actually need them.
allowed_commands:
  - ls
  - cat
  - echo
  - pwd
  - whoami
  - id
  - uname
  - uptime
  - df
  - free
  - stat

upload_base: /data/data/com.termux/files/home/sentinelx/uploads

# Directories the file_ops tools (read / list / search / edit / transfer) may touch.
# The key is `file_ops.paths` (nested), NOT `file_ops_paths`.
file_ops:
  paths:
    - path: /data/data/com.termux/files/home   # your Termux home
      access: rw
EOF
```

> ⚠️ **The key is `file_ops.paths`, nested under `file_ops:`.** A top-level
> `file_ops_paths:` is silently ignored — you'll see `policy_unknown_keys` in the logs
> and the agent will have **no allowed paths** (file reads and transfers will fail with
> `path_not_allowed`).

## 4. Enroll the host

First, generate a host id:

```bash
HOST_ID="host_$(python -c 'import uuid; print(uuid.uuid4().hex[:16])')"
```

Then get an **enrollment token** from the dashboard. Open this URL — built with *your*
host id — in your phone's browser (in Termux the printed link is tappable):

```bash
echo "https://mcp.sentinelx.app/auth/dashboard/enroll?host_id=$HOST_ID"
```

Sign in to your SentinelX account there, and the dashboard gives you a one-line
**enrollment token** (a JWT). Copy it.

**Recommended — let `enroll.py` handle the file** (it prints the same URL and waits for
you to paste the token):

```bash
curl -fsSL https://raw.githubusercontent.com/pensados/sentinelx-cloud-installer/main/enroll.py \
  -o ~/sentinelx/enroll.py

python ~/sentinelx/enroll.py \
  --hub https://mcp.sentinelx.app \
  --host-id "$HOST_ID" \
  --output ~/sentinelx/identity.json \
  --mode paste
```

Follow its prompt (open the URL, sign in, paste the token). It writes
`~/sentinelx/identity.json` — `{host_id, token, hub}`.

**Or fully manual** — write the file yourself after copying the token from that URL:

```bash
cat > ~/sentinelx/identity.json <<EOF
{"host_id": "$HOST_ID", "token": "PASTE_TOKEN_HERE", "hub": "https://mcp.sentinelx.app"}
EOF
```

## 5. Run the agent

```bash
python -m sentinelx_core \
  --identity ~/sentinelx/identity.json \
  --config ~/sentinelx/config.yaml
```

You should see logs ending in `connected; session=...`. Your phone is now a live host
in your dashboard. 🎉

## 6. Keep it running (persistence)

The command above runs in the **foreground** and stops when you close Termux. For a
setup that survives:

```bash
# Stop Android from killing the process when the screen sleeps:
termux-wake-lock

# Autostart at device boot (install once):
pkg install termux-services
#   then register a service for the run command in step 5,
#   OR install the Termux:Boot app (F-Droid) and add the run command there.
```

Also **disable battery optimization for Termux** in Android settings, or Doze may still
kill it. Expect the host to show **offline while the phone sleeps** and reconnect when
you wake it.

---

## Accessing photos and shared files (opt-in)

By default, Android's **scoped storage** blocks the agent from your photos and files —
it only sees the Termux home. This is deliberate and safe.

To grant access (a conscious security decision):

```bash
termux-setup-storage      # Android prompts — tap "Allow"
```

Then add the specific directory to `file_ops.paths` and **restart the agent** (step 5).
For read-only camera access:

```yaml
file_ops:
  paths:
    - path: /data/data/com.termux/files/home
      access: rw
    - path: /storage/emulated/0/DCIM          # camera + screenshots (read-only)
      access: r
```

`/sdcard` is a symlink to `/storage/emulated/0`; the agent resolves symlinks and checks
the **real** path against this list, so use the `/storage/emulated/0/...` form.

---

## Security notes for Android

Android's app sandbox makes the agent's reach **narrower on a phone than on a server** —
which is a good thing:

- **The agent runs inside the Termux app sandbox (non-root).** It cannot become root,
  cannot read other apps' data, and **cannot even list your installed apps** — `pm`,
  `/data/app`, and `/data/data` are all blocked by Android.
- **Photos and shared files are blocked by default** (scoped storage). Access is an
  explicit opt-in (`termux-setup-storage` + a `file_ops.paths` entry).
- **`file_ops.paths` scopes only the file_ops tools** (read / list / search / edit /
  transfer). It does **not** constrain `exec` / `script_run` — those are governed by
  `allowed_commands`. On a phone, keep that allowlist tight.

---

## Gotchas

- **`file_ops.paths`, not `file_ops_paths`** (see step 3).
- **`transfer_file`'s `destination_path` is relative to the destination agent's
  `upload_base`**, not an absolute filesystem path. To land a file at a specific
  location, transfer it, then move it into place on the destination host.
- **OS filesystem permissions still apply** beyond the config scope: the agent runs as
  your Termux user and can only write where that user can. (On other hosts, granting a
  path in `file_ops.paths` may still require an ACL or group permission so the `sentinelx`
  user can write.)
- **Battery/Doze**: Android kills background processes aggressively — use
  `termux-wake-lock` and disable battery optimization for a stable host.
