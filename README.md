# sentinelx-cloud-installer

The one-line installer for SentinelX. This is what `https://get.sentinelx.app` serves.

```bash
curl -fsSL https://get.sentinelx.app | sudo bash
```

Run that on any Linux host you want to operate from your LLM. The script clones
[`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core), sets
it up as a systemd service, and walks you through enrollment.

## Who this is for

Anyone who wants to install the SentinelX agent on a Linux server and connect
it to Claude.ai or ChatGPT via the SentinelX hub.

## What it does, step by step

1. **Prereq check** — confirms you're on Linux, running as root, with `git`,
   `python3`, and `systemd` available.
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

## Connecting to your LLM

In Claude.ai or ChatGPT:

1. Settings → Connectors → Add custom MCP
2. URL: `https://mcp.sentinelx.app/mcp/mcp`
3. Authorize with the same Google account you used during enrollment.

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
sudo bash install.sh                # then run it
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
