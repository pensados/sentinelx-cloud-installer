# sentinelx-cloud-installer

The one-line installer for SentinelX. This is what `https://get.sentinelx.app` serves.

**Linux / macOS** — the one-liner auto-detects your OS:

```bash
curl -fsSL https://get.sentinelx.app | bash
```

**Windows** — a PowerShell installer (needs Python 3.12+ and `git` on `PATH`):

```powershell
iwr -useb https://get.sentinelx.app/install.ps1 -OutFile "$env:TEMP\sx.ps1"
# service install (admin) -- runs as a Windows service at boot:
powershell -ExecutionPolicy Bypass -File "$env:TEMP\sx.ps1"
# ...or a no-admin per-user install:
powershell -ExecutionPolicy Bypass -File "$env:TEMP\sx.ps1" -User
```

Run the relevant command on any host you want to operate from your LLM. The script installs
[`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core) and registers it
as a service -- a systemd unit on Linux, a launchd daemon on macOS, a Windows service (or a
per-user task with `-User`) on Windows -- then walks you through enrollment. See
[Windows](#windows) below for offline installs and corporate-network notes.

## Who this is for

Anyone who wants to install the SentinelX agent on a Linux or macOS host and connect
it to Claude.ai or ChatGPT via the SentinelX hub.

## What it does, step by step

1. **OS detection & prereqs** — the one-line command auto-detects Linux or
   macOS and runs the right installer. On Linux it confirms you're root with
   `git`, `python3`, and `systemd`; on macOS it installs Python via `uv` and
   uses `launchd`. (Steps 2–3 below describe the Linux flow; macOS is analogous
   with a per-user install and launchd.)
2. **System user** — creates an unprivileged `sentinelx` user that the agent
   will run as.
3. **Sudo setup** — by default, installs `/etc/sudoers.d/sentinelx` so the
   agent can run privileged commands without a password. The real security
   boundary is the allowlist in `/etc/sentinelx/config.yaml` — without that
   sudo rule, the LLM can't restart services or edit `/etc/`. To skip this
   step, set `SENTINELX_SKIP_SUDO=1`.
4. **Clone & venv** — fetches `sentinelx-cloud-core` to `/opt/sentinelx-cloud-core`
   and builds a virtualenv there.
5. **Config skeleton** — drops a starter `/etc/sentinelx/config.yaml` that you
   can edit later to control which commands the agent will allow.
6. **Enrollment** — opens an interactive enrollment flow:
   - Prints a URL like `https://mcp.sentinelx.app/auth/dashboard/enroll?host_id=...`
   - You open it in your browser, sign in with Google, copy the displayed
     enrollment token, paste it back into the installer.
7. **systemd unit** — installs and starts `sentinelx-cloud-core.service`. The
   agent connects out to `mcp.sentinelx.app` and stays connected.

After this completes, the host appears in your account on the SentinelX hub
and you can target it from Claude.ai or ChatGPT.

## Windows

Windows uses a PowerShell installer (`install.ps1`, also served from
`get.sentinelx.app`) instead of the bash script. Two modes:

```powershell
iwr -useb https://get.sentinelx.app/install.ps1 -OutFile "$env:TEMP\sx.ps1"
# service install -- runs as LocalSystem at boot; needs an ELEVATED PowerShell:
powershell -ExecutionPolicy Bypass -File "$env:TEMP\sx.ps1"
# per-user install -- no admin; runs as you at logon (for locked-down machines):
powershell -ExecutionPolicy Bypass -File "$env:TEMP\sx.ps1" -User
```

- **Service mode** wraps the agent with [WinSW](https://github.com/winsw/winsw)
  so it runs as a Windows service (LocalSystem, auto-start at boot) — the
  analogue of the systemd unit / launchd daemon.
- **User mode** (`-User`) registers a per-user Scheduled Task that runs the
  agent windowless at logon, as your own account. No admin required — the
  right fit for locked-down corporate machines.

**Prerequisites:** Python 3.12+ and `git` on `PATH`. **Offline / blocked
PyPI:** add `-Bundle <zip-or-url>` to install from the prebuilt wheel bundle
attached to the latest release (`--no-index --no-deps`, no PyPI needed).
**TLS-inspecting proxy:** the agent verifies the hub certificate against the
OS trust store (`truststore`), so a corporate CA is accepted without
weakening verification.

Other flags: `-Check` (no-admin dry-run), `-HostId`, `-InstallDir`,
`-HubUrl`, `-ImportFrom` (reuse an existing identity/config), `-Source`
(editable dev install).

**Uninstall (Windows).** Service mode:

```powershell
& "C:\ProgramData\SentinelX\sentinelx-service.exe" stop
& "C:\ProgramData\SentinelX\sentinelx-service.exe" uninstall
Remove-Item -Recurse -Force C:\ProgramData\SentinelX
```

User mode:

```powershell
schtasks /End /TN SentinelX; schtasks /Delete /TN SentinelX /F
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\SentinelX"
```

## Connecting to your LLM

**ChatGPT** — install [SentinelX from the app directory](https://chatgpt.com/apps/sentinelx/asdk_app_69f63e01766881919640f03b5e7912a5),
click **Connect**, and authorize with the same Google account you used during
enrollment. No URL to copy.

**Claude.ai** — Settings → Connectors → Add custom MCP:

1. URL: `https://mcp.sentinelx.app/mcp/mcp`
2. Authorize with the same Google account you used during enrollment.

You're done. Try asking your LLM:

> *"List my SentinelX servers."*
> *"Show uptime and disk usage on my-vps."*

## Multiple servers

Run the installer on each one. Hosts are bound to your account, and the LLM
can target them by:

- **host_id** — the unique ID generated at install time
- **hostname** — whatever the server reports (e.g. `web-prod-01`)
- **label** — a custom alias you set later via `sentinel_set_host_label`

If a name resolves to multiple hosts, the LLM is told which it is and asks
you to disambiguate.

## What you control

The agent only runs what's allowed in `/etc/sentinelx/config.yaml`:

- **`exec.allow`** — exact shell commands the LLM can run
- **`services.allow`** — systemd units the LLM can manage
- **`paths.allow_edit`** — files the LLM can read/write via `sentinel_edit`

A starter config is written at install time. Edit it to expand or restrict
what your LLM can touch.

## Manual install

If you'd rather not pipe a remote script into sudo:

```bash
curl -fsSL https://get.sentinelx.app/install.sh -o install.sh
less install.sh                     # read it
bash install.sh                # then run it
```

The script is tiny (~7 KB) and stdlib-only.

## Uninstall

```bash
sudo systemctl disable --now sentinelx-cloud-core
sudo rm -rf /opt/sentinelx-cloud-core
sudo rm -rf /etc/sentinelx
sudo rm -f /etc/sudoers.d/sentinelx
sudo userdel sentinelx
sudo rm /etc/systemd/system/sentinelx-cloud-core.service
sudo systemctl daemon-reload
```

The host stops appearing in your hub account within seconds (the WebSocket
disconnects). Operational logs about that host roll off after 30 days.

## Related

- [`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core) — the agent itself
- [`sentinelx-cloud-protocol`](https://github.com/pensados/sentinelx-cloud-protocol) — wire format spec
- [Privacy Policy](https://get.sentinelx.app/privacy) · [Terms](https://get.sentinelx.app/terms)

## License

Apache 2.0
