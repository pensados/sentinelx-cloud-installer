# sentinelx-installer

One-line installer for `sentinelx-core`. Served from `https://get.sentinelx.app`.

## Usage

```bash
curl -fsSL https://get.sentinelx.app | bash
```

What it does:

1. Detects OS (Linux only, x86_64/arm64).
2. Generates a stable `host_id` (UUID stored at `/etc/sentinelx/host_id`).
3. Installs `sentinelx-core` to `/opt/sentinelx-core`.
4. Starts a tiny local HTTP server on a random port to receive the OAuth callback.
5. Opens the user's browser to `https://mcp.sentinelx.app/auth/enroll/start?host_id=...&callback=...`.
6. Captures the enrollment JWT from the redirect, writes `/etc/sentinelx/identity.json`.
7. Installs and starts the systemd unit `sentinelx-core.service`.

## Files

- `install.sh` — the bash entrypoint (what `curl | bash` runs)
- `enroll.py` — Python script that runs the local callback server and orchestrates enrollment
- `sentinelx-core.service` — systemd unit template

## Hosting `get.sentinelx.app`

The script lives on a static host (Cloudflare Pages, GitHub Pages, S3 + CloudFront — any of these). The reverse proxy at `get.sentinelx.app` serves `install.sh` directly.

## Re-enrollment

If the host loses its identity file or the user wants to reconnect with a different account:

```bash
sudo /opt/sentinelx-core/bin/sentinelx-enroll
```
