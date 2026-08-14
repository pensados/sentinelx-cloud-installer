# sentinelx-cloud-installer

One-line installer for the [SentinelX](https://sentinelx.app) agent — this is what `https://get.sentinelx.app` serves. It installs [`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core) on a **Linux, macOS, or Windows** host and connects it to Claude.ai or ChatGPT through the SentinelX hub, so your LLM can run allowlisted commands, manage services, and edit files on that host.

## Install

**Linux / macOS** — one command, auto-detects your OS:

```bash
curl -fsSL https://get.sentinelx.app | bash
```

**Windows** — PowerShell installer (needs Python 3.12+ and `git` on `PATH`):

*Service install* — runs as a Windows service at boot; needs an **elevated** PowerShell:

```powershell
iwr -useb https://get.sentinelx.app/install.ps1 -OutFile "$env:TEMP\sx.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\sx.ps1"
```

*Per-user install* — no admin; runs as you at logon (locked-down / corporate machines):

```powershell
iwr -useb https://get.sentinelx.app/install.ps1 -OutFile "$env:TEMP\sx.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\sx.ps1" -User
```

The installer sets up a virtualenv, registers the agent as a service (systemd on Linux, launchd on macOS, a Windows service or per-user task), writes a starter config, and opens a browser sign-in to enroll the host. When it finishes, the host appears in your account and your LLM can reach it. On Linux the agent runs as an unprivileged `sentinelx` user.

## Connect your LLM

- **ChatGPT** — install [SentinelX from the app directory](https://chatgpt.com/apps/sentinelx/asdk_app_69f63e01766881919640f03b5e7912a5), click **Connect**, sign in with the account you enrolled with. No URL to copy.
- **Claude.ai** — Settings → Connectors → Add custom connector → `https://mcp.sentinelx.app/mcp/mcp`, then authorize.

Then try: *"List my SentinelX servers."* · *"Show uptime and disk usage on my-vps."*
Manage your fleet any time at [`mcp.sentinelx.app/dashboard`](https://mcp.sentinelx.app/dashboard).

## What the agent can do

Nothing you haven't allowed. Every action is gated by the config the installer writes (`/etc/sentinelx/config.yaml` on Linux; next to the install on macOS/Windows):

- **`exec.allow`** — shell commands the agent may run
- **`services.allow`** — services it may start, stop, or restart
- **`paths.allow_edit`** — files it may read and edit

A starter config is written at install time; edit it to widen or narrow that reach. Full reference: [`config.example.yaml`](https://github.com/pensados/sentinelx-cloud-core/blob/main/config.example.yaml).

## Windows details

`install.ps1` (also served from `get.sentinelx.app`) runs in one of two modes:

- **Service mode** (default) wraps the agent with [WinSW](https://github.com/winsw/winsw) — runs as LocalSystem, auto-starts at boot; the analogue of the systemd unit / launchd daemon. Needs an elevated PowerShell.
- **Per-user mode** (`-User`) registers a per-user Scheduled Task that runs the agent windowless at logon, as you — no admin, the right fit for locked-down corporate machines.

**Offline / blocked PyPI:** add `-Bundle <zip-or-url>` to install from the prebuilt wheel bundle on the latest release (no PyPI needed). **TLS-inspecting proxy:** the agent verifies the hub cert against the OS trust store, so a corporate CA is accepted without weakening verification. **Other flags:** `-Check` (dry-run), `-HostId`, `-InstallDir`, `-HubUrl`, `-ImportFrom` (reuse an identity/config), `-Source` (editable dev install).

**Uninstall** — service mode:

```powershell
& "C:\ProgramData\SentinelX\sentinelx-service.exe" stop
& "C:\ProgramData\SentinelX\sentinelx-service.exe" uninstall
Remove-Item -Recurse -Force C:\ProgramData\SentinelX
```

Per-user mode:

```powershell
schtasks /End /TN SentinelX; schtasks /Delete /TN SentinelX /F
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\SentinelX"
```

## More

**Multiple hosts** — run the installer on each. Target them from the LLM by `host_id`, `hostname`, or a `label` you set later (`sentinel_set_host_label`); if a name is ambiguous, the LLM asks which one you mean.

**Manual install** (audit before running):

```bash
curl -fsSL https://get.sentinelx.app/install.sh -o install.sh
less install.sh   # read it
bash install.sh   # then run it
```

**Uninstall — Linux:**

```bash
sudo systemctl disable --now sentinelx-cloud-core
sudo rm -rf /opt/sentinelx-cloud-core /etc/sentinelx /etc/sudoers.d/sentinelx
sudo rm -f /etc/systemd/system/sentinelx-cloud-core.service
sudo userdel sentinelx && sudo systemctl daemon-reload
```

**Uninstall — macOS:**

```bash
sudo launchctl bootout system/app.sentinelx.core 2>/dev/null
sudo rm -f /Library/LaunchDaemons/app.sentinelx.core.plist /etc/sudoers.d/sentinelx
rm -rf ~/sentinelx
```

The host stops appearing in your account within seconds of the agent stopping.

## Related

- [`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core) — the agent itself
- [`sentinelx-cloud-protocol`](https://github.com/pensados/sentinelx-cloud-protocol) — wire-format spec
- [Privacy](https://get.sentinelx.app/privacy) · [Terms](https://get.sentinelx.app/terms)

## License

Apache 2.0
