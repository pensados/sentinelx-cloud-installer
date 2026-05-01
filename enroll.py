#!/usr/bin/env python3
"""sentinelx-enroll: drive the OAuth enrollment flow on first install.

Spins up a one-shot HTTP server on a random localhost port, opens the user's
browser to the hub, and captures the enrollment JWT from the redirect fragment.

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
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

# How long we wait for the user to finish the OAuth dance
TIMEOUT_SECONDS = 300

# The fragment can't be read server-side, so the page returned to the browser
# is a small HTML that captures the fragment via JS and POSTs it back to us.
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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hub", required=True, help="Hub base URL (e.g. https://mcp.sentinelx.app)")
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--output", required=True, help="Path to write identity.json")
    args = parser.parse_args()

    port = find_free_port()
    callback_url = f"http://localhost:{port}/"

    server = CallbackServer(("127.0.0.1", port), CallbackHandler)

    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    enroll_url = (
        f"{args.hub.rstrip('/')}/auth/enroll/start"
        f"?host_id={urllib.parse.quote(args.host_id)}"
        f"&callback={urllib.parse.quote(callback_url)}"
    )

    print(f"Opening browser: {enroll_url}", file=sys.stderr)
    if not webbrowser.open(enroll_url):
        print("Could not open browser automatically.", file=sys.stderr)
        print(f"Please open this URL manually:\n  {enroll_url}", file=sys.stderr)

    # Wait for the result
    try:
        for _ in range(TIMEOUT_SECONDS):
            if server.result or server.error:
                break
            server_thread.join(timeout=1.0)
    finally:
        server.shutdown()

    if server.error:
        print(f"Enrollment failed: {server.error}", file=sys.stderr)
        sys.exit(1)
    if not server.result:
        print(f"Enrollment timed out after {TIMEOUT_SECONDS}s", file=sys.stderr)
        sys.exit(1)

    identity = {
        "host_id": server.result.get("host_id", args.host_id),
        "token": server.result["token"],
        "hub": args.hub,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(identity, indent=2))
    print(f"Identity written to {out_path}")


if __name__ == "__main__":
    main()
