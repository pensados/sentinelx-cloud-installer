"""enroll.py: what gets written to identity.json.

sxrep_BJNC0WGMBMGN / sxrep_VV880Z9JHFXV (2026-10-08/09): a one-time token lost
20 characters when the assistant copied it. Its payload could no longer be read,
so it was treated as a legacy token and written as-is; the agent then retried an
invalid token 220+ times, and install.sh skipped enrollment on every re-run
because identity.json existed.
"""

import base64
import io
import json
import sys
import urllib.error
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


def test_the_exchange_names_itself_and_shows_what_refused_it(monkeypatch):
    """2026-10-19: Cloudflare's Browser Integrity Check blocked the default
    'Python-urllib' user agent with 403 'error code: 1010', and the installer said
    only 'no detail', which read as a bad token."""
    seen = {}

    def edge_refuses(req, timeout):
        seen["ua"] = req.get_header("User-agent")
        raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {},
                                     io.BytesIO(b"error code: 1010\n"))

    monkeypatch.setattr(enroll.urllib.request, "urlopen", edge_refuses)
    with pytest.raises(SystemExit) as exc:
        enroll.exchange_enrollment_token("https://hub.test", ENROLL)
    assert (seen["ua"] or "").startswith("sentinelx-enroll/")
    assert "HTTP 403, error code: 1010" in str(exc.value)


def test_the_hubs_own_errors_keep_their_messages(monkeypatch):
    def hub_refuses(req, timeout):
        raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {},
                                     io.BytesIO(b'{"ok": false, "error": "host_disabled"}'))

    monkeypatch.setattr(enroll.urllib.request, "urlopen", hub_refuses)
    with pytest.raises(SystemExit) as exc:
        enroll.exchange_enrollment_token("https://hub.test", ENROLL)
    assert str(exc.value) == enroll._EXCHANGE_ERRORS["host_disabled"]


# --- short enrollment codes (sxc_FBFST45N) -------------------------------------
# The dashboard and assistants hand out XXXX-XXXX-XXXX instead of the ~640-char
# token (sxrep_1P2B8GE9JCWY: an assistant rewrote the token and broke it). The
# installer sends the code as typed; the hub normalises it and answers with the
# host credential AND the host id the code was made for.

class _Resp:
    def __init__(self, body):
        self._b = json.dumps(body).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


@pytest.fixture(autouse=True)
def _isolated_home(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("SENTINELX_ENROLL_TOKEN", raising=False)
    monkeypatch.delenv("SENTINELX_ENROLL_CODE", raising=False)


def _hub(monkeypatch, *, status=200, body=None, seen=None):
    body = body if body is not None else {"ok": True, "credential": "a.b.c", "host_id": "host_from_hub"}

    def urlopen(req, timeout):
        if seen is not None:
            seen.append(req)
        if status != 200:
            raise urllib.error.HTTPError(req.full_url, status, "x", {},
                                         io.BytesIO(json.dumps(body).encode()))
        return _Resp(body)
    monkeypatch.setattr(enroll.urllib.request, "urlopen", urlopen)


def _main(monkeypatch, tmp_path, mode="paste"):
    out = tmp_path / "identity.json"
    monkeypatch.setattr(sys, "argv", ["enroll.py", "--hub", "https://hub.test", "--host-id",
                                      "host_generated", "--output", str(out), "--mode", mode])
    enroll.main()
    return json.loads(out.read_text())


def test_a_code_from_the_environment_is_exchanged_as_json(monkeypatch, tmp_path):
    seen = []
    _hub(monkeypatch, seen=seen)
    monkeypatch.setenv("SENTINELX_ENROLL_CODE", " abcd-1234-wxyz ")
    ident = _main(monkeypatch, tmp_path)
    assert ident == {"host_id": "host_from_hub", "token": "a.b.c", "hub": "https://hub.test"}
    [req] = seen
    assert req.full_url == "https://hub.test/agent/enroll"
    assert json.loads(req.data) == {"code": "abcd-1234-wxyz"}
    assert req.get_header("Authorization") is None
    assert req.get_header("Content-type") == "application/json"
    assert (req.get_header("User-agent") or "").startswith("sentinelx-enroll/")


def test_a_typed_code_at_the_prompt_is_exchanged(monkeypatch, tmp_path):
    seen = []
    _hub(monkeypatch, seen=seen)
    monkeypatch.setattr(sys, "stdin", io.StringIO("abcd 1234 wxyz\n"))
    ident = _main(monkeypatch, tmp_path)
    assert ident["host_id"] == "host_from_hub" and ident["token"] == "a.b.c"
    assert json.loads(seen[0].data) == {"code": "abcd 1234 wxyz"}


def test_a_pasted_token_still_takes_the_token_path(monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "stdin", io.StringIO(ENROLL + "\n"))
    monkeypatch.setattr(enroll, "exchange_enrollment_token", lambda h, t: "host-credential")
    monkeypatch.setattr(enroll, "exchange_enrollment_code", lambda h, c: pytest.fail("not a code"))
    ident = _main(monkeypatch, tmp_path)
    assert ident == {"host_id": "host_abc", "token": "host-credential", "hub": "https://hub.test"}


def test_a_code_typed_with_dots_is_still_a_code():
    assert not enroll.looks_like_token("ABCD.1234.WXYZ")
    assert enroll.looks_like_token(ENROLL)


def test_the_token_variable_wins_over_the_code(monkeypatch, tmp_path):
    monkeypatch.setenv("SENTINELX_ENROLL_TOKEN", ENROLL)
    monkeypatch.setenv("SENTINELX_ENROLL_CODE", "ABCD-1234-WXYZ")
    monkeypatch.setattr(enroll, "exchange_enrollment_token", lambda h, t: "host-credential")
    monkeypatch.setattr(enroll, "exchange_enrollment_code", lambda h, c: pytest.fail("token wins"))
    assert _main(monkeypatch, tmp_path)["token"] == "host-credential"


def test_a_wrong_or_expired_code_says_so_and_writes_nothing(monkeypatch, tmp_path):
    _hub(monkeypatch, status=401, body={"ok": False, "error": "invalid_or_expired_code"})
    monkeypatch.setenv("SENTINELX_ENROLL_CODE", "ABCD-1234-WXYZ")
    with pytest.raises(SystemExit) as exc:
        _main(monkeypatch, tmp_path)
    assert "wrong or has expired" in str(exc.value) and "Nothing was written" in str(exc.value)
    assert not (tmp_path / "identity.json").exists()


def test_too_many_attempts_says_how_long_to_wait(monkeypatch, tmp_path):
    _hub(monkeypatch, status=429, body={"ok": False, "error": "too_many_attempts", "retry_after": 421})
    monkeypatch.setenv("SENTINELX_ENROLL_CODE", "ABCD-1234-WXYZ")
    with pytest.raises(SystemExit) as exc:
        _main(monkeypatch, tmp_path)
    assert "Wait 8 minutes" in str(exc.value)
    assert not (tmp_path / "identity.json").exists()


def test_a_used_code_is_told_in_code_words(monkeypatch, tmp_path):
    _hub(monkeypatch, status=409, body={"ok": False, "error": "enrollment_token_already_used"})
    monkeypatch.setenv("SENTINELX_ENROLL_CODE", "ABCD-1234-WXYZ")
    with pytest.raises(SystemExit) as exc:
        _main(monkeypatch, tmp_path)
    assert "code was already used" in str(exc.value)


def test_a_code_answer_without_a_credential_writes_nothing(monkeypatch, tmp_path):
    _hub(monkeypatch, body={"ok": True, "host_id": "h"})
    monkeypatch.setenv("SENTINELX_ENROLL_CODE", "ABCD-1234-WXYZ")
    with pytest.raises(SystemExit):
        _main(monkeypatch, tmp_path)
    assert not (tmp_path / "identity.json").exists()


def test_the_prompt_asks_for_a_code(monkeypatch, tmp_path, capsys):
    _hub(monkeypatch)
    monkeypatch.setattr(sys, "stdin", io.StringIO("ABCD-1234-WXYZ\n"))
    _main(monkeypatch, tmp_path)
    assert "Paste the enrollment code (or token): " in capsys.readouterr().err
