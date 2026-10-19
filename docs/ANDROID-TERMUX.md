# Installing SentinelX on Android

SentinelX runs on Android inside **[Termux](https://termux.dev)**, a Linux environment
app. The agent is pure Python over an **outbound** WebSocket, so your phone or tablet
becomes a host you can operate from your LLM, with **no inbound ports and no root**.

**The recommended way** is to run a small Debian inside Termux (with PRoot) and use the
same one-line installer as on any Linux server. It takes a few minutes, and everything
installs from ready-made packages. [Part 1](#part-1-install-debian-in-proot) covers it.

[Part 2](#part-2-keep-it-running) keeps the agent running in the background and starts
it when the device boots. [Part 3](#part-3-alternative-termux-without-debian) is an
alternative without Debian, for reference.

> **Status:** tested on aarch64 with Debian 13 in PRoot on Android 13 (tablet) and
> Android 16 (phone), October 2026: install, background, screen off, network changes
> and reboot. Not yet a first-class install target. If you hit a snag, open an issue
> on the installer repo.

---

## Requirements

- An **aarch64** device (any modern phone or tablet).
- A **SentinelX account** to enroll the host.
- **Termux**, from **[F-Droid](https://f-droid.org)** or Google Play. The current Play
  build works (`termux-info` shows `TERMUX_VERSION=googleplay.…`). But to have the
  agent start by itself when the device boots you need the **Termux:Boot** add-on,
  which exists **only on F-Droid** and must come from the same store as Termux.
  F-Droid is an alternative app store: download its APK from f-droid.org, allow your
  browser to install unknown apps, then install Termux and Termux:Boot from it.
  Termux is **not** Termius, and it is not the raw Android shell.

---

## Part 1: Install (Debian in PRoot)

PRoot runs a full Debian inside Termux without root: `apt`, normal paths, and the
standard installer. Its limits: no `systemd` (Part 2 replaces it), a simulated root,
no ports below 1024, and the same Android background rules as Termux itself.

### 1. Termux packages and Debian

In Termux:

```bash
pkg update && pkg upgrade -y
```

Then, **as a separate command** (on a fresh F-Droid install the first `pkg update` may
ask you to pick a mirror and stop there; if packages are not found later, run
`termux-change-repo`):

```bash
pkg install -y proot-distro termux-services
proot-distro install debian
proot-distro login debian
```

The prompt changes to `root@localhost`: you are inside Debian.

### 2. Run the installer inside Debian

```bash
apt update && apt install -y python3 python3-venv python3-pip git curl ca-certificates
```

Then run the install command from your dashboard (**Add host**), the same one you
would use on a Linux server:

```bash
curl -fsSL https://get.sentinelx.app | SENTINELX_ENROLL_TOKEN=<token> bash
```

It installs the agent, enrolls the host and writes the config. Finding no systemd, it
ends by printing how to run the agent:

```bash
runuser -u sentinelx -- /opt/sentinelx-cloud-core/.venv/bin/sentinelx-cloud-core \
    --hub https://mcp.sentinelx.app \
    --identity /etc/sentinelx/identity.json \
    --config /etc/sentinelx/config.yaml
```

Run it once to see it connect (the host shows as online in your dashboard), then stop
it with Ctrl+C and set it up to run in the background (Part 2).

> **The `sentinelx` user isolates nothing under PRoot.** PRoot reports every file as
> owned by whoever asks, so the agent can read and write anywhere in the Debian
> install (including `/root` and `/etc`) and everything the Termux app can reach. It
> still cannot reach other apps' data or the rest of Android. The installer says so
> too. Keep `allowed_commands` in `/etc/sentinelx/config.yaml` to what you need.

---

## Part 2: Keep it running

The command above stops with its Termux session. To keep the agent running, supervise
it with **runit** (`termux-services`) and start runit at boot with **Termux:Boot**.
Tested this way, the agent stayed connected through 25+ minutes with the screen off,
reconnected within a second of a Wi-Fi/mobile data switch, and came back by itself
after a reboot.

### Android settings

- Settings → Apps → **Termux** → Battery → **Unrestricted**. Same for **Termux:Boot**.
- Android 12 and 13 limit background child processes (the "phantom process killer").
  An idle agent was not affected in testing, but if you see it cut off under load,
  lift the limit once from a computer with `adb`:
  ```bash
  adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent"
  adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
  ```
  On Android 14+ it is a switch: Developer options → **Disable child process
  restrictions**.

### The service

In **Termux** (not inside Debian; type `exit` to leave it):

```bash
termux-wake-lock
```

If you just installed `termux-services`, **close Termux completely and open it
again** first: until then, `sv-enable` fails with `unable to change to service
directory`.

```bash
S=$PREFIX/var/service/sentinelx
mkdir -p $S/log $S/control
cat > $S/run <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec proot-distro login debian -- runuser -u sentinelx -- /opt/sentinelx-cloud-core/.venv/bin/sentinelx-cloud-core --hub https://mcp.sentinelx.app --identity /etc/sentinelx/identity.json --config /etc/sentinelx/config.yaml 2>&1
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

`sv status` should show `run: sentinelx: (pid …)`. A `warning: unable to open
supervise/ok` from the first `sv-enable` is harmless. Logs are in
`$PREFIX/var/log/sv/sentinelx/current`.

`control/t` is **required**: `proot-distro` does not pass the stop signal on to the
agent inside, so without it `sv restart` and `sv down` leave the old agent running.

If you installed without Debian (Part 3), the `exec` line is instead:
`exec python -m sentinelx_core --identity $HOME/sentinelx/identity.json --config $HOME/sentinelx/config.yaml 2>&1`

### Start at boot (Termux:Boot, F-Droid only)

Open the Termux:Boot app once so Android registers it, then in Termux:

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

### Day to day

- **Don't close Termux.** Typing `exit` in the last Termux session, or tapping *Exit*
  in its notification, stops runit and the agent with it. Leave Termux in the
  background.
- **After editing the config**: `sv restart sentinelx` (in Termux).
- **Updating the agent**: run the install command again inside Debian (it keeps the
  existing enrollment), then `sv restart sentinelx`.
- **Removing the service**: stop it first, then remove it. Deleting the folder of a
  running service leaves the agent running with nothing to stop it, and
  `proot-distro` then refuses to remove or reset Debian (`container is busy`).
  ```bash
  sv down sentinelx
  sv-disable sentinelx
  rm -rf $PREFIX/var/service/sentinelx
  ```

---

## Part 3: Alternative: Termux without Debian

The agent can also run directly in Termux. It is slower to install (one dependency
compiles on-device, ~15 minutes) and entirely manual: Termux isn't a standard distro
(no `apt`, no `systemd`, non-standard paths), so the installer does not run there.
Last tested on Android 14; not tested with the Part 2 service.

**1. Dependencies**

```bash
pkg update && pkg install python git rust bash curl
```

`rust` is required: `pydantic-core` is written in Rust and compiles on-device.

**2. The agent**

```bash
cd ~
git clone https://github.com/pensados/sentinelx-cloud-core.git
cd sentinelx-cloud-core
pip install -e .
```

⏳ **This takes ~10–15 minutes.** The `Building wheel for pydantic-core ...` spinner
sits there for a long time; this is normal, do not cancel.

**3. The config**

```bash
mkdir -p ~/sentinelx/uploads
cat > ~/sentinelx/config.yaml <<'EOF'
# Commands the LLM may run via `exec`. Keep this tight: a phone holds personal
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
> `file_ops_paths:` is silently ignored: you'll see `policy_unknown_keys` in the logs
> and the agent will have **no allowed paths**.

**4. Enrollment**

```bash
HOST_ID="host_$(python -c 'import uuid; print(uuid.uuid4().hex[:16])')"
curl -fsSL https://raw.githubusercontent.com/pensados/sentinelx-cloud-installer/main/enroll.py \
  -o ~/sentinelx/enroll.py
python ~/sentinelx/enroll.py \
  --hub https://mcp.sentinelx.app \
  --host-id "$HOST_ID" \
  --output ~/sentinelx/identity.json \
  --mode paste
```

It prints a URL: open it, sign in, and paste the enrollment token it shows. It writes
`~/sentinelx/identity.json`.

> **Don't write `identity.json` by hand.** Dashboard tokens are one-time enrollment
> tokens: `enroll.py` exchanges yours once for this host's own credential and writes
> *that*. A token saved straight into the file is never exchanged, and the agent is
> refused on connect.

**5. Run it**

```bash
python -m sentinelx_core \
  --identity ~/sentinelx/identity.json \
  --config ~/sentinelx/config.yaml
```

The logs end in `connected; session=...`. Then keep it running as in Part 2.

---

## Accessing photos and shared files (opt-in)

By default, Android's **scoped storage** blocks the agent from your photos and files.
This is deliberate and safe. To grant access (a conscious security decision), in
Termux:

```bash
termux-setup-storage      # Android prompts: tap "Allow"
```

Then add the specific directory to `file_ops.paths` and restart the agent
(`sv restart sentinelx`). For read-only camera access:

```yaml
file_ops:
  paths:
    - path: /storage/emulated/0/DCIM          # camera + screenshots (read-only)
      access: r
```

`/sdcard` is a symlink to `/storage/emulated/0`; the agent checks the **real** path,
so use the `/storage/emulated/0/...` form. This was tested without Debian (Part 3);
inside Debian, check first that `ls /storage/emulated/0` works there.

---

## Security notes for Android

Android's app sandbox makes the agent's reach **narrower on a phone than on a server**:

- **The agent runs inside the Termux app sandbox.** The root inside Debian is
  simulated: underneath it is still the Termux app. It cannot become a real root,
  cannot read other apps' data, and **cannot even list your installed apps** (`pm`,
  `/data/app` and `/data/data` are blocked by Android).
- **Inside that sandbox, nothing separates the agent from the rest of Termux and
  Debian** (see the note in Part 1).
- **Photos and shared files are blocked by default** (scoped storage). Access is an
  explicit opt-in.
- **`file_ops.paths` scopes only the file tools** (read / list / search / edit /
  transfer). It does **not** constrain `exec` / `script_run`: those are governed by
  `allowed_commands`. On a phone, keep that allowlist tight.

---

## Gotchas

- **`file_ops.paths`, not `file_ops_paths`.**
- **`transfer_file`'s `destination_path` is relative to the destination agent's
  `upload_base`**, not an absolute filesystem path. To land a file at a specific
  location, transfer it, then move it into place.
- **Battery/Doze**: Android kills background processes aggressively. Use
  `termux-wake-lock` and set Termux's battery use to Unrestricted (Part 2).
