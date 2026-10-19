# Installing SentinelX on Android (Termux)

SentinelX runs on Android through **[Termux](https://termux.dev)** — a Linux
environment app. The agent is pure Python over an **outbound** WebSocket, so your
phone (or any ARM device) becomes a host you can operate from your LLM — with **no
inbound ports and no root**.

There are two ways to do it:

- **Option A — Termux directly** (steps 1–5 below). A manual install; Termux isn't a
  standard distro (no `apt`, no `systemd`, non-standard paths). Budget **~15 minutes**:
  one dependency compiles on-device.
- **Option B — Debian inside Termux, with PRoot** ([below](#option-b-debian-in-proot)).
  A regular Debian userland, so everything installs from ready-made wheels in under a
  minute, and the standard installer works there.

Both are kept running the same way: [Keep it running](#6-keep-it-running).

> **Status:** tested on aarch64 — Android 14 (Option A), and Android 13 and 16 with
> Debian 13 in PRoot (Option B, October 2026). Not yet a first-class install target.
> If you hit a snag, open an issue on the installer repo.

---

## Requirements

- **Termux**, from **[F-Droid](https://f-droid.org)** or Google Play. The current Play
  build (`termux-info` shows `TERMUX_VERSION=googleplay.…`) works. But if you want the
  agent to start by itself when the device boots, you need the **Termux:Boot** add-on,
  which exists **only on F-Droid** and must come from the same store as Termux. F-Droid
  is an alternative app store: install it by downloading its APK from f-droid.org and
  allowing the browser to install unknown apps, then install Termux and Termux:Boot
  from it. Termux is **not** Termius, and it is not the raw Android shell.
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

> **Don't write `identity.json` by hand.** Dashboard tokens are one-time
> enrollment tokens: `enroll.py` exchanges yours once for this host's own
> credential and writes *that*. A pasted token saved straight into the file is
> never exchanged, and the agent is refused on connect. `enroll.py` handles
> both one-time and older tokens, so it is the one supported way.

## 5. Run the agent

```bash
python -m sentinelx_core \
  --identity ~/sentinelx/identity.json \
  --config ~/sentinelx/config.yaml
```

You should see logs ending in `connected; session=...`. Your phone is now a live host
in your dashboard. 🎉

## 6. Keep it running

The command in step 5 runs in the **foreground** and stops with its Termux session.
To keep the agent running, supervise it with **runit** (`termux-services`), and start
runit at boot with **Termux:Boot**. This is what was tested; with it the agent stayed
connected through 25+ minutes of screen-off and reconnected within a second of a
Wi-Fi/mobile data switch.

**Android settings first:**

- Settings → Apps → **Termux** → Battery → **Unrestricted**. Same for **Termux:Boot**.
- Android 12 and 13 limit background child processes (the "phantom process killer").
  An idle agent was not affected in testing, but if you see it cut off under load,
  lift the limit once from a computer with `adb`:
  ```bash
  adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent"
  adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
  ```
  On Android 14+ the same thing is a switch: Developer options → **Disable child
  process restrictions**.

**In Termux** (not inside Debian):

```bash
pkg install -y termux-services
termux-wake-lock
```

Then **close Termux completely and open it again**: until you do, `sv-enable` fails
with `unable to change to service directory`.

Create the service. The `run` line depends on how you installed:

```bash
S=$PREFIX/var/service/sentinelx
mkdir -p $S/log $S/control
cat > $S/run <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec RUN_LINE 2>&1
EOF
cat > $S/control/t <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
pkill -TERM -f "sentinelx_core --identity|sentinelx-cloud-core --hub"
EOF
chmod +x $S/run $S/control/t
ln -sf $PREFIX/share/termux-services/svlogger $S/log/run
sv-enable sentinelx
sv status sentinelx
```

Replace `RUN_LINE` with:

| Installed with | `RUN_LINE` |
|---|---|
| Option A (Termux) | `python -m sentinelx_core --identity $HOME/sentinelx/identity.json --config $HOME/sentinelx/config.yaml` |
| Option B, by hand | `proot-distro login debian -- /root/sentinelx/venv/bin/python -m sentinelx_core --identity /root/sentinelx/identity.json --config /root/sentinelx/config.yaml` |
| Option B, with the installer | `proot-distro login debian -- runuser -u sentinelx -- /opt/sentinelx-cloud-core/.venv/bin/sentinelx-cloud-core --hub HUB_URL --identity /etc/sentinelx/identity.json --config /etc/sentinelx/config.yaml` |

`control/t` is **required with PRoot**: `proot-distro` does not pass the stop signal
on to the agent inside, so without it `sv restart` / `sv down` leave the old agent
running. A `warning: unable to open supervise/ok` from the first `sv-enable` is
harmless. Logs are in `$PREFIX/var/log/sv/sentinelx/current`.

**Start at boot (Termux:Boot, F-Droid only).** Open the Termux:Boot app once so
Android registers it, then:

```bash
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-services <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
. $PREFIX/etc/profile
EOF
chmod +x ~/.termux/boot/start-services
```

After a reboot, unlock the device once: Termux's files stay encrypted until then. A
Termux notification reading `0 sessions (wake lock held)` means it worked. With the
Play build (no Termux:Boot), open Termux once after each reboot instead.

**Don't close Termux.** Typing `exit` in the last session, or tapping *Exit* in its
notification, stops runit and the agent with it. Leave Termux in the background.

**Updating the agent**: pull and reinstall where you installed it (re-running the
installer does this for Option B with the installer), then `sv restart sentinelx`.

---

## Option B: Debian in PRoot

PRoot runs a full Debian userland inside Termux without root: `apt`, glibc and normal
paths, so the agent installs from ready-made wheels. Its limits: no `systemd` (use the
runit service from [step 6](#6-keep-it-running)), a simulated root, no ports below
1024, and the same Android background rules as Termux itself.

```bash
# In Termux. Run the second line on its own: on a fresh F-Droid install, the first
# `pkg update` may ask you to pick a mirror and stop the chain.
pkg update && pkg upgrade -y
pkg install -y proot-distro termux-services
proot-distro install debian
proot-distro login debian
```

Inside Debian, the standard installer works:

```bash
apt update && apt install -y python3 python3-venv python3-pip git curl ca-certificates
curl -fsSL https://get.sentinelx.app/install.sh -o install.sh
bash install.sh
```

It installs and enrolls the agent, then, finding no systemd, prints how to run it
(`runuser -u sentinelx -- ...`). Run that once in the foreground to see it connect,
then set up the service from [step 6](#6-keep-it-running) with the "with the
installer" line.

> **The `sentinelx` user isolates nothing under PRoot.** PRoot reports every file as
> owned by whoever asks, so the agent can read and write anywhere in the Debian
> install (including `/root` and `/etc`), and everything the Termux app can reach.
> It still cannot reach other apps' data or the rest of Android.

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

- **The agent runs inside the Termux app sandbox (non-root).** With PRoot (Option B)
  the root inside Debian is simulated: it is still the Termux app underneath. It cannot become root,
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
  `termux-wake-lock` and set Termux's battery use to Unrestricted (see step 6).
