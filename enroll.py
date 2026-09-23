#!/usr/bin/env python3
"""sentinelx-enroll: drive the OAuth enrollment flow on first install.

Two modes:

1. **browser** (default): spin up a one-shot HTTP server on a localhost port,
   print the enrollment URL, and capture the token when the redirect lands.
   Works when the user has a browser that can reach this machine's localhost
   (typical case: installing on the same machine you're sitting in front of,
   or via SSH tunnel: `ssh -L 8765:localhost:8765 server`).

2. **paste**: just print instructions for the user to visit the dashboard URL,
   complete enrollment there, copy the JWT, and paste it on stdin. Works on
   any headless server.

The installer chooses the mode automatically based on `--mode` (default: browser).
The script never opens the browser itself — always prints the URL for the user
to copy. This is more predictable across SSH/headless setups.

Standalone — only depends on the Python stdlib so it works on any boxed Linux
without pip-installing anything.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import signal
import socket
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# How long we wait for the user to finish the OAuth dance (browser mode)
TIMEOUT_SECONDS = 600

# Page returned to the browser at /. Reads the URL fragment (which can't be
# read server-side) and POSTs it back to /finish.
CAPTURE_PAGE = """<!doctype html>
<html><head><title>SentinelX enrollment</title>
<style>body{font-family:system-ui;background:#0e1116;color:#e6edf3;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.box{max-width:420px;text-align:center;padding:32px;border:1px solid #30363d;border-radius:8px}
h1{font-size:18px;margin:0 0 12px}.s{color:#7ee787;font-size:24px}.f{color:#ff7b72}</style>
</head><body><div class="box" id="box">
<h1>Connecting your server to SentinelX</h1><p id="msg">Finalizing enrollment…</p>
</div><script>
(async()=>{
  const frag = window.location.hash.slice(1);
  if(!frag){document.getElementById('msg').innerHTML='<span class="f">No token received.</span>';return}
  try{
    const r=await fetch('/finish',{method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},body:frag});
    if(r.ok){document.getElementById('msg').innerHTML='<span class="s">✓ Done!</span><br>You can close this window.';}
    else{document.getElementById('msg').innerHTML='<span class="f">Server rejected the token.</span>';}
  }catch(e){document.getElementById('msg').innerHTML='<span class="f">Network error.</span>';}
})();
</script></body></html>
"""


class CallbackServer(HTTPServer):
    """Wraps HTTPServer with a place to stash the result."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)  # type: ignore[arg-type]
        self.result: dict[str, str] | None = None
        self.error: str | None = None


class CallbackHandler(BaseHTTPRequestHandler):
    server: CallbackServer  # type: ignore[assignment]

    def log_message(self, format: str, *args: object) -> None:  # silence stderr
        return

    def do_GET(self) -> None:  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(CAPTURE_PAGE.encode("utf-8"))

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        params = dict(urllib.parse.parse_qsl(body))
        if "token" in params:
            self.server.result = params
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.server.error = "no token in fragment"
            self.send_response(400)
            self.end_headers()


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def banner(text: str) -> str:
    """Box the URL so the user can spot it among installer log noise."""
    line = "─" * (len(text) + 2)
    return f"\n┌{line}┐\n│ {text} │\n└{line}┘\n"


def run_browser_mode(hub: str, host_id: str) -> dict[str, str]:
    """Spin up local HTTP server, print URL, wait for callback."""
    port = find_free_port()
    callback_url = f"http://localhost:{port}/"

    server = CallbackServer(("127.0.0.1", port), CallbackHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    enroll_url = (
        f"{hub.rstrip('/')}/auth/enroll/start"
        f"?host_id={urllib.parse.quote(host_id)}"
        f"&callback={urllib.parse.quote(callback_url)}"
    )

    print(file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print("  SentinelX enrollment — open this URL in your browser:", file=sys.stderr)
    print(banner(enroll_url), file=sys.stderr)
    print("  Local listener:", callback_url, file=sys.stderr)
    print("  If running on a remote server, tunnel first:", file=sys.stderr)
    print(f"    ssh -L {port}:localhost:{port} <user>@<remote>", file=sys.stderr)
    print(f"  Or use 'paste' mode: --mode paste", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(file=sys.stderr)
    print(f"Waiting for completion (timeout: {TIMEOUT_SECONDS}s)…", file=sys.stderr)

    try:
        for _ in range(TIMEOUT_SECONDS):
            if server.result or server.error:
                break
            server_thread.join(timeout=1.0)
    finally:
        server.shutdown()

    if server.error:
        raise SystemExit(f"Enrollment failed: {server.error}")
    if not server.result:
        raise SystemExit(f"Enrollment timed out after {TIMEOUT_SECONDS}s")
    return server.result


def run_paste_mode(hub: str, host_id: str) -> dict[str, str]:
    """Print dashboard URL, read JWT from stdin."""
    dashboard_url = (
        f"{hub.rstrip('/')}/auth/dashboard/enroll"
        f"?host_id={urllib.parse.quote(host_id)}"
    )

    print(file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print("  SentinelX enrollment (paste mode)", file=sys.stderr)
    print(file=sys.stderr)
    print("  1. Open this URL in your browser:", file=sys.stderr)
    print(banner(dashboard_url), file=sys.stderr)
    print("  2. Log in with your SentinelX account.", file=sys.stderr)
    print("  3. The page will display an enrollment token.", file=sys.stderr)
    print("  4. Copy it and paste it below.", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(file=sys.stderr)

    print("Paste enrollment token: ", file=sys.stderr, end="", flush=True)

    # Read the token. If we were started via `curl | bash` then sys.stdin is
    # the install script itself (already consumed) and reading it returns "".
    # In that case fall back to reading from the controlling terminal directly,
    # which is the same source the user is typing into.
    token = sys.stdin.readline().strip()
    if not token and sys.stdin.isatty() is False:
        # Root cause of the classic hang: under `sudo` with `Defaults use_pty`
        # (the default on modern Ubuntu) this process is a background job on
        # sudo's pty, so reading the controlling terminal raises SIGTTIN — which
        # by default STOPS the process (State T) and freezes the whole installer
        # forever. Ignoring SIGTTIN makes the read fail fast with EIO instead,
        # which we catch below and turn into a clear, actionable message. (The
        # keyboard genuinely isn't reachable in this setup, so failing cleanly
        # and pointing at the run-as-root workaround is the best we can do.)
        try:
            signal.signal(signal.SIGTTIN, signal.SIG_IGN)
        except (ValueError, OSError):
            pass  # not the main thread / unsupported — best effort
        try:
            with open("/dev/tty", "r") as tty:
                # With SIGTTIN ignored this fails fast with EIO under use_pty
                # (keyboard unreachable), and blocks normally for a real paste.
                token = tty.readline().strip()
        except OSError:
            # EIO (background read under use_pty) or no controlling terminal.
            token = ""

    if not token:
        raise SystemExit(
            "No token entered.\n"
            "\n"
            "If the prompt stalled and nothing happened when you pasted: your\n"
            "`sudo` likely uses `Defaults use_pty` (the default on modern Ubuntu),\n"
            "which breaks the interactive token prompt. The cleanest fix is to run\n"
            "as root so `sudo` isn't in the pipe:\n"
            "\n"
            "  sudo -i\n"
            "  curl -fsSL https://get.sentinelx.app | bash\n"
            "\n"
            "(Pass SENTINELX_HOST_ID=host_xxx to reuse this host's id.)\n"
        )
    if token.count(".") != 2:
        raise SystemExit("Token doesn't look like a JWT (expected 3 segments).")

    return {"token": token, "host_id": host_id}


def _claims_unverified(token: str) -> dict:
    """Read a JWT's payload WITHOUT verifying it.

    There is no key here; the hub verifies. This only decides what to DO with
    the token -- write it as-is, or exchange it -- so a forged payload gains
    nothing: the hub rejects it at the exchange or on connect.
    """
    try:
        seg = token.split(".")[1]
        seg += "=" * (-len(seg) % 4)
        data = json.loads(base64.urlsafe_b64decode(seg))
        return data if isinstance(data, dict) else {}
    except Exception:  # noqa: BLE001
        return {}


_EXCHANGE_ERRORS = {
    "enrollment_token_already_used": (
        "This enrollment token was already used. Enrollment tokens work once;\n"
        "generate a new one from the dashboard and run the installer again."
    ),
    "expired": (
        "This enrollment token has expired. Generate a new one from the\n"
        "dashboard and run the installer again."
    ),
    "host_disabled": (
        "This host id has been disabled on your account, so it cannot be\n"
        "enrolled. Generate a token for a new host from the dashboard."
    ),
}


def exchange_enrollment_token(hub: str, token: str) -> str:
    """Trade a one-time enrollment token for this host's session credential.

    Exits on ANY failure without writing identity.json. That matters: the
    installer skips enrollment whenever identity.json exists, so a file written
    with a token that never worked would leave a host that silently never
    connects, and re-running would not fix it.
    """
    url = f"{hub.rstrip('/')}/agent/enroll"
    req = urllib.request.Request(
        url,
        data=b"",
        method="POST",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        try:
            err = json.loads(exc.read().decode("utf-8") or "{}").get("error")
        except Exception:  # noqa: BLE001
            err = None
        raise SystemExit(
            _EXCHANGE_ERRORS.get(err or "")
            or f"The hub refused the enrollment token (HTTP {exc.code}, {err or 'no detail'})."
        )
    except (urllib.error.URLError, OSError) as exc:
        raise SystemExit(
            f"Could not reach {hub} to exchange the enrollment token: {exc}\n"
            "Nothing was written; check connectivity and run the installer again."
        )
    cred = body.get("credential") if isinstance(body, dict) else None
    if not isinstance(body, dict) or not body.get("ok") or not isinstance(cred, str) \
            or cred.count(".") != 2:
        raise SystemExit("The hub did not return a host credential. Nothing was written.")
    return cred


def run_env_mode(token: str, host_id: str) -> dict[str, str]:
    """Non-interactive enrollment from SENTINELX_ENROLL_TOKEN.

    For hosts provisioned by automation, where nobody is there to paste. The
    token's own host_id is used: it was not minted for the id this installer
    run generated, and the hub treats the claim as authoritative anyway.
    """
    token = token.strip()
    if token.count(".") != 2:
        raise SystemExit("SENTINELX_ENROLL_TOKEN doesn't look like a JWT (expected 3 segments).")
    print("Using SENTINELX_ENROLL_TOKEN (non-interactive enrollment).", file=sys.stderr)
    return {"token": token, "host_id": _claims_unverified(token).get("host_id") or host_id}


def main() -> None:
    parser = argparse.ArgumentParser(description="Enroll this host with SentinelX")
    parser.add_argument("--hub", required=True, help="Hub base URL (e.g. https://mcp.sentinelx.app)")
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--output", required=True, help="Path to write identity.json")
    parser.add_argument(
        "--mode",
        choices=["browser", "paste"],
        default="browser",
        help="browser=local HTTP server captures token; paste=user copies token from web dashboard",
    )
    args = parser.parse_args()

    env_token = os.environ.get("SENTINELX_ENROLL_TOKEN", "").strip()
    if env_token:
        result = run_env_mode(env_token, args.host_id)
    elif args.mode == "paste":
        result = run_paste_mode(args.hub, args.host_id)
    else:
        result = run_browser_mode(args.hub, args.host_id)

    token = result["token"]
    host_id = result.get("host_id", args.host_id)

    # A one-time enrollment token is exchanged for the host's session
    # credential BEFORE anything is written. Legacy tokens (no `typ`) are
    # written exactly as before -- that is every token issued today.
    claims = _claims_unverified(token)
    if claims.get("typ") == "enroll":
        host_id = claims.get("host_id") or host_id
        token = exchange_enrollment_token(args.hub, token)

    identity = {
        "host_id": host_id,
        "token": token,
        "hub": args.hub,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(identity, indent=2))
    print(f"Identity written to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()

