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
import json
import socket
import sys
import threading
import urllib.parse
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
    token = sys.stdin.readline().strip()

    if not token:
        raise SystemExit("No token entered.")
    if token.count(".") != 2:
        raise SystemExit("Token doesn't look like a JWT (expected 3 segments).")

    return {"token": token, "host_id": host_id}


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

    if args.mode == "paste":
        result = run_paste_mode(args.hub, args.host_id)
    else:
        result = run_browser_mode(args.hub, args.host_id)

    identity = {
        "host_id": result.get("host_id", args.host_id),
        "token": result["token"],
        "hub": args.hub,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(identity, indent=2))
    print(f"Identity written to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()

