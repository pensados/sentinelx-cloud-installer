"""enroll.py: what gets written to identity.json.

sxrep_BJNC0WGMBMGN / sxrep_VV880Z9JHFXV (2026-10-08/09): a one-time token lost
20 characters when the assistant copied it. Its payload could no longer be read,
so it was treated as a legacy token and written as-is; the agent then retried an
invalid token 220+ times, and install.sh skipped enrollment on every re-run
because identity.json existed.
"""

import base64
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import enroll  # noqa: E402


def _b64(obj) -> str:
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


def _jwt(payload) -> str:
    return f"{_b64({'alg': 'EdDSA', 'typ': 'JWT'})}.{_b64(payload)}.{'s' * 86}"


ENROLL = _jwt({"typ": "enroll", "host_id": "host_abc", "sub": "u1", "jti": "j1",
               "iat": 1791000000, "exp": 1791003600, "scope": "agent", "pad": "x" * 300})


def _run(monkeypatch, tmp_path, token, exchange=None):
    out = tmp_path / "identity.json"
    monkeypatch.setenv("SENTINELX_ENROLL_TOKEN", token)
    monkeypatch.setattr(sys, "argv", ["enroll.py", "--hub", "https://hub.test",
                                      "--host-id", "host_fallback", "--output", str(out)])
    if exchange:
        monkeypatch.setattr(enroll, "exchange_enrollment_token", exchange)
    enroll.main()
    return json.loads(out.read_text())


def test_a_token_cut_while_copying_is_refused_and_nothing_is_written(monkeypatch, tmp_path):
    head, payload, sig = ENROLL.split(".")
    cut = f"{head}.{payload[:60] + payload[80:]}.{sig}"          # 20 characters lost
    assert enroll._claims_unverified(cut) == {}                 # the case: unreadable
    with pytest.raises(SystemExit) as exc:
        _run(monkeypatch, tmp_path, cut, exchange=lambda h, t: pytest.fail("must not exchange"))
    assert "damaged" in str(exc.value) and "Nothing was written" in str(exc.value)
    assert not (tmp_path / "identity.json").exists()


def test_a_one_time_token_is_exchanged_before_anything_is_written(monkeypatch, tmp_path):
    ident = _run(monkeypatch, tmp_path, ENROLL, exchange=lambda h, t: "host-credential")
    assert ident == {"host_id": "host_abc", "token": "host-credential", "hub": "https://hub.test"}


def test_a_failed_exchange_writes_nothing(monkeypatch, tmp_path):
    def refuse(hub, token):
        raise SystemExit("bad")
    with pytest.raises(SystemExit):
        _run(monkeypatch, tmp_path, ENROLL, exchange=refuse)
    assert not (tmp_path / "identity.json").exists()


def test_a_readable_legacy_token_is_still_written_as_is(monkeypatch, tmp_path):
    legacy = _jwt({"host_id": "host_old", "sub": "u1", "exp": 1822000000})
    ident = _run(monkeypatch, tmp_path, legacy, exchange=lambda h, t: pytest.fail("legacy is not exchanged"))
    assert ident["token"] == legacy and ident["host_id"] == "host_old"
