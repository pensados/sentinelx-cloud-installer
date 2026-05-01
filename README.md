# sentinelx-cloud-installer

One-line installer for [`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core), the SentinelX agent.

```bash
curl -fsSL https://get.sentinelx.app | sudo bash
```

That's it. The script clones the agent, sets up a Python virtualenv, walks you through enrollment, and registers a systemd service that connects to the SentinelX hub at [`mcp.sentinelx.app`](https://mcp.sentinelx.app/healthz).

Once installed, you can talk to your server through Claude.ai or ChatGPT — the SentinelX hub is exposed as an MCP connector.

---

## What is SentinelX?

SentinelX lets you operate Linux servers from inside an LLM chat. You install a small agent on each server, the agent connects out to a hosted hub via WebSocket, and the hub appears as an MCP connector in Claude.ai and ChatGPT.

You can then ask things like:

- "Show me `df -h` and `uptime` on my prod-web server"
- "Restart nginx on my-vps and tell me when it's back"
- "Check if there are any pending kernel updates across all my servers"

The agent only runs commands that you've explicitly allowed in `/etc/sentinelx/config.yaml`. Nothing else is reachable.

---

## What this installer does

1. Generates a stable `host_id` for this machine and persists it to `/etc/sentinelx/host_id`.
2. Creates a system user `sentinelx` to run the agent under (no shell, no home dir privileges).
3. Clones [`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core) to `/opt/sentinelx-cloud-core`.
4. Sets up a Python virtualenv at `/opt/sentinelx-cloud-core/.venv` and pip-installs the agent.
5. Walks you through OAuth enrollment so the hub knows this host belongs to your account.
6. Writes a minimal allowlist config to `/etc/sentinelx/config.yaml` (echo, whoami, uname, hostname, date, ls, id, pwd, df -h, free -h, uptime, cat /etc/os-release).
7. Installs `sentinelx-cloud-core.service` and starts it.

---

## Enrollment modes

The installer supports two flavors of OAuth enrollment.

### Paste mode (default — works on any server)

```bash
curl -fsSL https://get.sentinelx.app | sudo bash
```

The installer prints a URL. You open it in your browser (any browser, anywhere — your laptop, your phone), log in, copy the displayed token, and paste it into the installer prompt. Recommended for headless servers, VPSs, and anything you reach via SSH.

### Browser mode

```bash
curl -fsSL https://get.sentinelx.app | sudo SENTINELX_ENROLL_MODE=browser bash
```

The installer starts a one-shot HTTP listener on `localhost:<random-port>` and prints a URL. The OAuth flow redirects there with the token in the URL fragment, the page captures it via JavaScript, and POSTs it back to the listener. Works when:

- You're installing on the same machine you're sitting at, or
- You've SSH-tunneled the port: `ssh -L 8765:localhost:8765 user@server`

---

## Configuration

All settings can be overridden by environment variables before running the installer:

| Variable | Default | What it does |
|---|---|---|
| `SENTINELX_HUB_URL` | `https://mcp.sentinelx.app` | Hub URL the agent connects to |
| `SENTINELX_INSTALL_DIR` | `/opt/sentinelx-cloud-core` | Where the agent gets installed |
| `SENTINELX_HOST_ID` | auto-generated | Force a specific host_id |
| `SENTINELX_CORE_REPO` | `https://github.com/pensados/sentinelx-cloud-core.git` | Git repo to clone |
| `SENTINELX_CORE_REF` | `main` | Git ref (branch/tag/commit) |
| `SENTINELX_ENROLL_MODE` | `paste` | `paste` or `browser` |

### Example: pin a specific version

```bash
curl -fsSL https://get.sentinelx.app | sudo SENTINELX_CORE_REF=v0.2.0 bash
```

### Example: install in a custom location

```bash
curl -fsSL https://get.sentinelx.app | sudo SENTINELX_INSTALL_DIR=/srv/sentinelx bash
```

---

## After install

```bash
# Service status
systemctl status sentinelx-cloud-core

# Live logs
journalctl -u sentinelx-cloud-core -f

# Hub-side health
curl https://mcp.sentinelx.app/healthz
```

To **expand the agent's allowed commands**, edit `/etc/sentinelx/config.yaml` and restart:

```bash
sudo systemctl restart sentinelx-cloud-core
```

To **rename your server** in the LLM chat (e.g. give it a friendly alias like `prod-web` instead of `host_0f56813c3e894ded`), just ask Claude or ChatGPT:

> Set the label "prod-web" on my server with hostname my-vps

The LLM will call `sentinel_set_host_label` for you.

---

## Re-enrollment

If you delete `/etc/sentinelx/identity.json` and re-run the installer, you'll get a fresh enrollment flow:

```bash
sudo rm /etc/sentinelx/identity.json
curl -fsSL https://get.sentinelx.app | sudo bash
```

The host keeps its `host_id` (so any labels and history are preserved), but gets a new identity JWT.

---

## Uninstall

```bash
sudo systemctl disable --now sentinelx-cloud-core
sudo rm /etc/systemd/system/sentinelx-cloud-core.service
sudo systemctl daemon-reload
sudo rm -rf /opt/sentinelx-cloud-core /etc/sentinelx /var/log/sentinelx /var/lib/sentinelx
sudo userdel sentinelx
```

---

## Files in this repo

- **`install.sh`** — the bash entrypoint that `curl | bash` runs
- **`enroll.py`** — standalone Python script that drives the OAuth flow (stdlib-only, no pip)
- **`scripts/`** — internal helpers (release, deploy)

The installer is intentionally one bash file plus one Python file. No build step, no compiled artifacts.

---

## Security notes

- The installer runs as root because it creates a system user, installs a systemd service, and writes to `/etc/`. Audit `install.sh` before running, especially if you're cautious about `curl | bash`. The full source is in this repo and the served `install.sh` is byte-identical to what's pushed.
- The OAuth flow uses PKCE (S256). The enrollment JWT is short-lived and bound to a specific `(user_id, host_id)` pair on the hub side.
- The agent runs as the unprivileged `sentinelx` user. To run commands that need root, you'll need to give that user explicit sudoers entries — see [`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core) docs.

---

## Related repos

- [`sentinelx-cloud-core`](https://github.com/pensados/sentinelx-cloud-core) — the agent that runs on your server
- [`sentinelx-cloud-protocol`](https://github.com/pensados/sentinelx-cloud-protocol) — message types shared between agent and hub

---

## License

Apache 2.0. See [`LICENSE`](./LICENSE).
