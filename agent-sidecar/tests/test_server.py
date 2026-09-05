"""Unit tests for the HTTP wrapper.

Unconditional, like test_config.py and unlike test_smoke.py: the runners are
monkeypatched, so nothing here needs a reachable OmniRoute, credentials or a
model call. What is being tested is the wrapper's own contract — request
validation, error shaping, and that it dispatches to the right runner — not
whether an agent can think.
"""

from __future__ import annotations

import pytest
from starlette.testclient import TestClient

from agent_sidecar import server


TOKEN = "test-token-not-a-real-secret"


@pytest.fixture(autouse=True)
def _auth_configured(monkeypatch):
    """/run fails closed without a token, so every test needs one configured.

    Autouse because the alternative — remembering to set it per test — would
    have every /run test quietly asserting against a 503 instead of the
    behaviour it names.
    """
    monkeypatch.setenv("AGENT_SIDECAR_AUTH_TOKEN", TOKEN)


@pytest.fixture
def client():
    # The header is attached to every request so the tests below stay about
    # the wrapper's own contract; the auth tests set their own headers.
    return TestClient(server.app, headers={"Authorization": f"Bearer {TOKEN}"})


@pytest.fixture
def _stub_runners(monkeypatch):
    """Replace both runners with a recorder.

    Deliberately not autouse: test_resolve_maps_every_advertised_runner needs
    the real `_resolve`, and an autouse patch would have silently disabled the
    one test that checks the mapping points at anything real.
    """
    calls = []

    def _fake(name):
        # Mirrors both real runners: `run(task, settings=None)`. The server
        # always passes settings now, because the model can be chosen per call.
        def _run(task, settings=None):
            calls.append((name, task, getattr(settings, "model_id", None)))
            return f"{name} handled: {task}"

        return _run

    monkeypatch.setattr(
        server, "_resolve", lambda runner: _fake(runner), raising=True
    )
    return calls


def test_healthz_reports_config_without_leaking_secrets(client, monkeypatch):
    monkeypatch.setenv("OMNIROUTE_API_KEY", "super-secret-value")
    monkeypatch.setenv("AGENT_SIDECAR_MODEL_ID", "opencode/big-pickle")

    resp = client.get("/healthz")

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["model_id"] == "opencode/big-pickle"
    assert body["omniroute_api_key_set"] is True
    assert sorted(body["runners"]) == ["pydantic-ai", "smolagents"]
    # The point of the booleans: the key must never appear anywhere in the
    # payload, including inside a nested value.
    assert "super-secret-value" not in resp.text


def test_run_refuses_everything_when_no_token_is_configured(
    _stub_runners, monkeypatch
):
    monkeypatch.delenv("AGENT_SIDECAR_AUTH_TOKEN", raising=False)
    bare = TestClient(server.app)

    resp = bare.post("/run", json={"task": "t"})

    # 503, not 401: an unset token is a deployment fault, and the distinction
    # tells an operator to fix the config rather than hunt for a credential.
    assert resp.status_code == 503
    assert "AGENT_SIDECAR_AUTH_TOKEN" in resp.json()["error"]
    assert _stub_runners == []


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": ""},
        {"Authorization": "Bearer"},
        {"Authorization": "Bearer "},
        {"Authorization": TOKEN},  # no scheme
        {"Authorization": f"Basic {TOKEN}"},
        {"Authorization": "Bearer wrong-token"},
    ],
)
def test_run_rejects_a_bad_or_missing_token(_stub_runners, headers):
    bare = TestClient(server.app)

    resp = bare.post("/run", json={"task": "secret task text"}, headers=headers)

    assert resp.status_code == 401
    # The task must not come back in the rejection — a rejected caller learns
    # nothing about what was sent, and the body is never parsed at all.
    assert "secret task text" not in resp.text
    assert _stub_runners == []


def test_run_accepts_a_case_insensitive_bearer_scheme(_stub_runners):
    bare = TestClient(server.app)

    resp = bare.post(
        "/run", json={"task": "t"}, headers={"Authorization": f"bearer {TOKEN}"}
    )

    assert resp.status_code == 200


def test_healthz_reports_whether_auth_is_configured(client):
    body = client.get("/healthz").json()

    assert body["auth_configured"] is True
    assert TOKEN not in client.get("/healthz").text


def test_run_defaults_to_smolagents(client, _stub_runners):
    resp = client.post("/run", json={"task": "do the thing"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["result"] == "smolagents handled: do the thing"
    assert body["runner"] == "smolagents"
    assert [(n, t) for n, t, _ in _stub_runners] == [("smolagents", "do the thing")]


def test_run_dispatches_to_pydantic_ai(client, _stub_runners):
    resp = client.post("/run", json={"task": "t", "runner": "pydantic-ai"})

    assert resp.status_code == 200
    assert resp.json()["runner"] == "pydantic-ai"
    assert [(n, t) for n, t, _ in _stub_runners] == [("pydantic-ai", "t")]


def test_run_uses_the_model_from_the_request(client, _stub_runners, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MODEL_ID", "opencode/big-pickle")

    resp = client.post("/run", json={"task": "t", "model": "agy/claude-sonnet-4-6"})

    assert resp.status_code == 200
    # Echoed back so the caller can tell which model answered. Without this a
    # silent fall to a weaker model is indistinguishable from success — the
    # same failure shape that let a web-search combo quietly answer from
    # training data.
    assert resp.json()["model"] == "agy/claude-sonnet-4-6"
    assert _stub_runners[0][2] == "agy/claude-sonnet-4-6"


def test_run_falls_back_to_the_configured_model(client, _stub_runners, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MODEL_ID", "ollama/qwen2.5:1.5b-instruct-q4_K_M")

    resp = client.post("/run", json={"task": "t"})

    assert resp.status_code == 200
    assert resp.json()["model"] == "ollama/qwen2.5:1.5b-instruct-q4_K_M"


def test_run_caps_max_steps_at_the_configured_ceiling(
    client, _stub_runners, monkeypatch
):
    monkeypatch.setenv("AGENT_SIDECAR_MAX_STEPS", "8")

    # A caller may lower the ceiling but must not be able to raise it: the
    # bound exists to stop a run that will never converge, and a caller that
    # times out does not stop the agent.
    captured = {}

    def _capture(runner):
        def _run(task, settings=None):
            captured["max_steps"] = settings.max_steps
            return "ok"

        return _run

    monkeypatch.setattr(server, "_resolve", _capture, raising=True)

    client.post("/run", json={"task": "t", "max_steps": 99})
    assert captured["max_steps"] == 8

    client.post("/run", json={"task": "t", "max_steps": 3})
    assert captured["max_steps"] == 3


# `True` is included deliberately: it is an int subclass, so a naive
# isinstance check would accept it as "1 step".
@pytest.mark.parametrize("bad", [0, -1, "4", 2.5, True, [], {}])
def test_run_rejects_a_bad_max_steps(client, _stub_runners, bad):
    resp = client.post("/run", json={"task": "t", "max_steps": bad})

    assert resp.status_code == 400
    assert "max_steps" in resp.json()["error"]
    assert _stub_runners == []


@pytest.mark.parametrize("bad", ["", "   ", 7, [], {}])
def test_run_rejects_a_non_string_or_empty_model(client, _stub_runners, bad):
    resp = client.post("/run", json={"task": "t", "model": bad})

    assert resp.status_code == 400
    assert "model" in resp.json()["error"]
    # Nothing should have been dispatched.
    assert _stub_runners == []


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"task": ""},
        {"task": "   "},
        {"task": 42},
        {"task": None},
    ],
)
def test_run_rejects_a_missing_or_empty_task(client, payload):
    resp = client.post("/run", json=payload)

    assert resp.status_code == 400
    assert "task" in resp.json()["error"]


def test_run_rejects_a_non_object_body(client):
    resp = client.post("/run", json=["not", "an", "object"])

    assert resp.status_code == 400


def test_run_rejects_a_non_json_body(client):
    resp = client.post("/run", content=b"not json at all")

    assert resp.status_code == 400


def test_run_rejects_an_unknown_runner(client):
    resp = client.post("/run", json={"task": "t", "runner": "nope"})

    assert resp.status_code == 400
    body = resp.json()
    assert "nope" in body["error"]
    assert body["valid_runners"] == ["pydantic-ai", "smolagents"]


def test_run_surfaces_the_runner_failure_rather_than_a_bare_500(client, monkeypatch):
    def _boom(runner):
        def _run(task, settings=None):
            raise RuntimeError("model refused")

        return _run

    monkeypatch.setattr(server, "_resolve", _boom, raising=True)

    resp = client.post("/run", json={"task": "t"})

    assert resp.status_code == 500
    # A workflow step only sees the response body, so an opaque 500 would make
    # every distinct failure look identical.
    assert resp.json()["error"] == "RuntimeError: model refused"


def test_run_coerces_a_non_string_result(client, monkeypatch):
    # A CodeAgent can legitimately return a number or a list; the response
    # shape must not change depending on what the agent happened to produce.
    monkeypatch.setattr(server, "_resolve", lambda runner: (lambda task, settings=None: 42))

    resp = client.post("/run", json={"task": "t"})

    assert resp.status_code == 200
    assert resp.json()["result"] == "42"


def test_run_surfaces_step_errors_and_flags_the_answer_as_degraded(
    client, monkeypatch
):
    # The case this exists for: the agent answered, but a step failed, so the
    # answer was produced despite something not working. Measured in the wild —
    # blocked from fetching a URL, an agent printed a hardcoded status code and
    # presented it as a real fetch. `result` alone cannot show that.
    monkeypatch.setattr(
        server,
        "_resolve",
        lambda runner: (
            lambda task, settings=None: {
                "result": "The HTTP status code is 200.",
                "steps": 3,
                "step_errors": ["step 2: InterpreterError: Import of urllib not allowed"],
            }
        ),
    )

    body = client.post("/run", json={"task": "t"}).json()

    assert body["result"] == "The HTTP status code is 200."
    assert body["steps"] == 3
    assert body["degraded"] is True
    assert "urllib" in body["step_errors"][0]


def test_run_is_not_degraded_when_every_step_succeeded(client, monkeypatch):
    monkeypatch.setattr(
        server,
        "_resolve",
        lambda runner: (
            lambda task, settings=None: {"result": "391", "steps": 2, "step_errors": []}
        ),
    )

    body = client.post("/run", json={"task": "t"}).json()

    assert body["degraded"] is False
    assert body["step_errors"] == []
    assert body["steps"] == 2


def test_run_still_accepts_a_runner_that_returns_a_bare_value(client, monkeypatch):
    # pydantic-ai and the stubs predate the dict shape; a bare return must not
    # break the wrapper, and must report as not-degraded rather than unknown.
    monkeypatch.setattr(
        server, "_resolve", lambda runner: (lambda task, settings=None: 42)
    )

    body = client.post("/run", json={"task": "t"}).json()

    assert body["result"] == "42"
    assert body["degraded"] is False
    assert body["steps"] is None


def test_resolve_maps_every_advertised_runner_to_a_real_callable():
    """The only test that exercises the real mapping.

    Every other test patches `_resolve`, so without this a typo in a module
    path or function name in RUNNERS would ship unnoticed and only fail at the
    first real request. This imports the runner modules for real, which is
    exactly the point.
    """
    for runner in server.RUNNERS:
        assert callable(server._resolve(runner)), runner


@pytest.mark.parametrize(
    "executor,expected",
    [
        ("local", "restriction"),
        ("e2b", "install-manifest (NOT a restriction)"),
        ("modal", "install-manifest (NOT a restriction)"),
    ],
)
def test_healthz_says_which_meaning_the_import_list_has(
    client, monkeypatch, executor, expected
):
    # The trap this guards: `authorized_imports: []` reads as "nothing can be
    # imported", and under a remote executor that is false — smolagents passes
    # the list to pip and restricts nothing. Verified in the wild: with the
    # list empty under e2b, an agent imported socket, platform and urllib.
    monkeypatch.setenv("AGENT_SIDECAR_EXECUTOR", executor)

    assert client.get("/healthz").json()["imports_are"] == expected


def test_vps_exec_is_off_unless_explicitly_enabled(monkeypatch):
    # The failure this guards: a deployment that grew a shell by accident.
    # Mounting the Docker socket is granting host root, so the tool must be
    # something an operator turned on, never something a default did.
    from agent_sidecar import mcp_server

    monkeypatch.delenv("AGENT_SIDECAR_EXEC_ENABLED", raising=False)
    out = mcp_server.vps_exec("echo should-not-run")

    assert out["enabled"] is False
    assert "AGENT_SIDECAR_EXEC_ENABLED" in out["error"]
    assert "stdout" not in out


@pytest.mark.parametrize("flag", ["true", "TRUE", "1", "yes"])
def test_vps_exec_runs_when_enabled(monkeypatch, tmp_path, flag):
    from agent_sidecar import mcp_server

    monkeypatch.setenv("AGENT_SIDECAR_EXEC_ENABLED", flag)
    monkeypatch.setenv("AGENT_SIDECAR_EXEC_AUDIT", str(tmp_path / "a.log"))
    monkeypatch.setenv("AGENT_SIDECAR_WORKDIR", str(tmp_path))

    out = mcp_server.vps_exec("echo hello-from-exec")

    assert out["exit_code"] == 0
    assert "hello-from-exec" in out["stdout"]


def test_vps_exec_audits_every_command(monkeypatch, tmp_path):
    from agent_sidecar import mcp_server

    log = tmp_path / "audit" / "vps_exec.log"
    monkeypatch.setenv("AGENT_SIDECAR_EXEC_ENABLED", "true")
    monkeypatch.setenv("AGENT_SIDECAR_EXEC_AUDIT", str(log))
    monkeypatch.setenv("AGENT_SIDECAR_WORKDIR", str(tmp_path))

    mcp_server.vps_exec("echo audited")

    assert log.exists()
    assert "echo audited" in log.read_text()


def test_vps_exec_caps_the_timeout(monkeypatch, tmp_path):
    # A caller must not be able to hold the bridge open indefinitely — the
    # same reason max_steps exists for the agent.
    from agent_sidecar import mcp_server

    monkeypatch.setenv("AGENT_SIDECAR_EXEC_ENABLED", "true")
    monkeypatch.setenv("AGENT_SIDECAR_EXEC_AUDIT", str(tmp_path / "a.log"))
    monkeypatch.setenv("AGENT_SIDECAR_WORKDIR", str(tmp_path))

    out = mcp_server.vps_exec("sleep 5", timeout=1)

    assert "timed out after 1s" in out["error"]


@pytest.mark.parametrize("bad", ["", "   "])
def test_vps_exec_rejects_an_empty_command(monkeypatch, tmp_path, bad):
    from agent_sidecar import mcp_server

    monkeypatch.setenv("AGENT_SIDECAR_EXEC_ENABLED", "true")
    monkeypatch.setenv("AGENT_SIDECAR_EXEC_AUDIT", str(tmp_path / "a.log"))

    out = mcp_server.vps_exec(bad)

    assert "command is required" in out["error"]


def test_healthz_says_tools_are_inactive_without_the_mcp_key(client, monkeypatch):
    """The mirror of the imports_are trap.

    Setting the allowlist and seeing it echoed back reads as "the agent has
    tools". It does not: loading them also needs a separately provisioned
    `manage`-scoped key. An agent with no tools answers from training data and
    sounds exactly like one that searched, so the conjunction is what gets
    reported.
    """
    monkeypatch.setenv("AGENT_SIDECAR_AGENT_TOOLS", "omniroute_web_search")
    monkeypatch.delenv("OMNIROUTE_MCP_API_KEY", raising=False)

    body = client.get("/healthz").json()

    assert body["agent_tools"] == ["omniroute_web_search"]
    assert body["agent_tools_active"] is False


def test_healthz_says_tools_are_active_when_both_are_set(client, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_AGENT_TOOLS", "omniroute_web_search")
    monkeypatch.setenv("OMNIROUTE_MCP_API_KEY", "a-manage-scoped-key")

    body = client.get("/healthz").json()

    assert body["agent_tools_active"] is True
    # The key itself must never appear, the same rule as every other secret
    # this endpoint reports on.
    assert "a-manage-scoped-key" not in client.get("/healthz").text


def test_run_reports_degraded_when_a_configured_tool_is_missing(client, monkeypatch):
    """A tool that was asked for and not delivered is degradation.

    It is also invisible in `result`: the agent just answers without it. This
    is the same failure a self-hosted search layer produced for real — not an
    outage, confident wrong answers — so it has to reach the caller as a flag
    they can branch on.
    """

    def _runner(task, settings=None):
        return {
            "result": "answered anyway",
            "steps": 2,
            "step_errors": [],
            "tools": {
                "enabled": True,
                "offered": 40,
                "selected": [],
                "missing": ["omniroute_web_search"],
                "misdirected": [],
            },
        }

    monkeypatch.setattr(server, "_resolve", lambda runner: _runner, raising=True)

    body = client.post("/run", json={"task": "t"}).json()

    assert body["result"] == "answered anyway"
    assert body["step_errors"] == []
    assert body["degraded"] is True
    assert body["tools"]["missing"] == ["omniroute_web_search"]


def test_run_is_not_degraded_when_every_tool_loaded(client, monkeypatch):
    def _runner(task, settings=None):
        return {
            "result": "ok",
            "steps": 3,
            "step_errors": [],
            "tools": {
                "enabled": True,
                "offered": 40,
                "selected": ["omniroute_web_search"],
                "missing": [],
                "misdirected": [],
            },
        }

    monkeypatch.setattr(server, "_resolve", lambda runner: _runner, raising=True)

    body = client.post("/run", json={"task": "t"}).json()

    assert body["degraded"] is False
    assert body["tools"]["selected"] == ["omniroute_web_search"]


def test_a_crashed_run_is_still_marked_degraded(client, monkeypatch):
    """The field the documentation tells callers to branch on must always exist.

    Before this, a runner that raised produced {error, runner, model} and
    nothing else. The status code was 500, but a caller reading the body — which
    is what docs/king-system.md tells them to do, "read degraded before you read
    result" — got None from `degraded`, which is falsy, which is exactly what a
    clean run looks like.
    """

    def _explodes(task, settings=None):
        raise RuntimeError("the model provider hung up")

    monkeypatch.setattr(server, "_resolve", lambda runner: _explodes, raising=True)

    resp = client.post("/run", json={"task": "t"})
    body = resp.json()

    assert resp.status_code == 500
    assert body["degraded"] is True
    assert "RuntimeError" in body["error"]
    assert body["step_errors"] == ["RuntimeError: the model provider hung up"]
    # No fabricated `result`: there is no answer, and an empty string would read
    # as "the agent answered nothing" rather than "the agent never ran".
    assert "result" not in body


def test_run_reports_what_it_cost(client, monkeypatch):
    """Roadmap 4.6 asks for cost per run to be known. It was not.

    smolagents prints token counts to the container log, where they are
    unparseable and scroll away, and the caller — the one deciding whether to
    run the agent again — never saw them.
    """

    def _runner(task, settings=None):
        return {
            "result": "ok",
            "steps": 2,
            "step_errors": [],
            "tokens": {"input": 13993, "output": 603, "total": 14596},
        }

    monkeypatch.setattr(server, "_resolve", lambda runner: _runner, raising=True)

    body = client.post("/run", json={"task": "t"}).json()

    assert body["tokens"] == {"input": 13993, "output": 603, "total": 14596}
    assert body["degraded"] is False


def test_missing_token_counts_are_null_not_zero(client, monkeypatch):
    """`null` means "not measured". Zeroes would read as "the call was free",
    which is a different claim and a wrong one."""

    def _runner(task, settings=None):
        return {"result": "ok", "steps": None, "step_errors": [], "tokens": None}

    monkeypatch.setattr(server, "_resolve", lambda runner: _runner, raising=True)

    body = client.post("/run", json={"task": "t"}).json()

    assert body["tokens"] is None
    assert body["degraded"] is False


def test_every_run_is_journalled(client, monkeypatch, tmp_path):
    """Run data used to die with the response.

    There was no way to answer "what did the agent cost this week" or "are
    degraded runs becoming more common" — the gateway's own call_logs sees model
    calls, not steps, tools, or whether the answer could be trusted.
    """
    journal = tmp_path / "runs.jsonl"
    monkeypatch.setenv("AGENT_SIDECAR_RUN_JOURNAL", str(journal))

    def _runner(task, settings=None):
        return {
            "result": "ok",
            "steps": 3,
            "step_errors": [],
            "tokens": {"input": 23105, "output": 986, "total": 24091},
        }

    monkeypatch.setattr(server, "_resolve", lambda runner: _runner, raising=True)
    client.post("/run", json={"task": "find the release date"})

    import json as _json

    lines = journal.read_text(encoding="utf-8").strip().splitlines()
    assert len(lines) == 1
    entry = _json.loads(lines[0])
    assert entry["steps"] == 3
    assert entry["tokens"]["total"] == 24091
    assert entry["degraded"] is False
    assert entry["task"] == "find the release date"
    assert isinstance(entry["seconds"], float)


def test_a_crashed_run_is_journalled_too(client, monkeypatch, tmp_path):
    journal = tmp_path / "runs.jsonl"
    monkeypatch.setenv("AGENT_SIDECAR_RUN_JOURNAL", str(journal))

    def _explodes(task, settings=None):
        raise RuntimeError("provider hung up")

    monkeypatch.setattr(server, "_resolve", lambda runner: _explodes, raising=True)
    client.post("/run", json={"task": "t"})

    import json as _json

    entry = _json.loads(journal.read_text(encoding="utf-8").strip())
    assert entry["degraded"] is True
    assert "RuntimeError" in entry["error"]


def test_an_unwritable_journal_does_not_fail_the_run(client, monkeypatch, tmp_path):
    """Best-effort, like the vps_exec audit beside it.

    A full disk or a mis-owned volume must not turn working agent runs into
    500s — but it must not be silent either, which is why the helper writes the
    failure to stderr.
    """
    monkeypatch.setenv(
        "AGENT_SIDECAR_RUN_JOURNAL", str(tmp_path / "nope" / "runs.jsonl")
    )
    from agent_sidecar import outcome as outcome_mod

    monkeypatch.setattr(
        outcome_mod.os,
        "makedirs",
        lambda *a, **k: (_ for _ in ()).throw(OSError("read-only")),
    )

    def _runner(task, settings=None):
        return {"result": "ok", "steps": 1, "step_errors": [], "tokens": None}

    monkeypatch.setattr(server, "_resolve", lambda runner: _runner, raising=True)

    resp = client.post("/run", json={"task": "t"})

    assert resp.status_code == 200
    assert resp.json()["result"] == "ok"


def test_a_run_takes_and_returns_a_slot(client, monkeypatch):
    def _runner(task, settings=None):
        return {"result": "ok", "steps": 1, "step_errors": [], "tokens": None}

    monkeypatch.setattr(server, "_resolve", lambda runner: _runner, raising=True)
    before = server.RUN_SLOTS.active

    client.post("/run", json={"task": "t"})

    assert server.RUN_SLOTS.active == before, "the slot was not released"


def test_a_crashed_run_still_returns_its_slot(client, monkeypatch):
    """The leak that would be invisible until the service stopped answering."""

    def _explodes(task, settings=None):
        raise RuntimeError("boom")

    monkeypatch.setattr(server, "_resolve", lambda runner: _explodes, raising=True)
    before = server.RUN_SLOTS.active

    client.post("/run", json={"task": "t"})

    assert server.RUN_SLOTS.active == before


def test_surplus_runs_are_rejected_rather_than_piled_on(client, monkeypatch):
    """The container is capped at 1 GB and 1 CPU, so it cannot take the host
    down. What it CAN do is OOM inside its own cgroup and take the runs already
    in flight with it. Refusing the surplus loses one caller instead of all."""
    monkeypatch.setattr(server, "RUN_SLOTS", server._RunSlots(1), raising=True)
    server.RUN_SLOTS.try_acquire()  # occupy the only slot

    resp = client.post("/run", json={"task": "t"})
    body = resp.json()

    assert resp.status_code == 429
    assert resp.headers["Retry-After"] == "30"
    assert body["degraded"] is True
    assert "concurrency limit" in body["step_errors"][0]


def test_a_rejected_request_does_not_consume_a_slot(client, monkeypatch):
    monkeypatch.setattr(server, "RUN_SLOTS", server._RunSlots(1), raising=True)
    server.RUN_SLOTS.try_acquire()

    client.post("/run", json={"task": "t"})

    assert server.RUN_SLOTS.active == 1, "a rejected run must not take a slot"


def test_a_malformed_request_never_occupies_a_slot(client, monkeypatch):
    monkeypatch.setattr(server, "RUN_SLOTS", server._RunSlots(2), raising=True)

    client.post("/run", json={"task": ""})

    assert server.RUN_SLOTS.active == 0


def test_zero_disables_the_concurrency_bound(monkeypatch):
    slots = server._RunSlots(0)
    for _ in range(50):
        assert slots.try_acquire() is True


def test_a_rejected_run_is_journalled(client, monkeypatch, tmp_path):
    """Found by reading the report the journal feeds.

    Rejections were the one outcome not recorded, which meant the journal
    looked calmest exactly when capacity was being hit hardest — the opposite
    of the trend it exists to surface.
    """
    journal = tmp_path / "runs.jsonl"
    monkeypatch.setenv("AGENT_SIDECAR_RUN_JOURNAL", str(journal))
    monkeypatch.setattr(server, "RUN_SLOTS", server._RunSlots(1), raising=True)
    server.RUN_SLOTS.try_acquire()

    resp = client.post("/run", json={"task": "t"})

    import json as _json

    assert resp.status_code == 429
    entry = _json.loads(journal.read_text(encoding="utf-8").strip())
    assert entry["degraded"] is True
    assert "already in flight" in entry["error"]


def test_http_and_mcp_return_the_same_shape(monkeypatch, tmp_path):
    """They were built separately and drifted apart.

    The MCP path is how Claude reaches the agent, and it was the one missing
    token counts and the tool report, and computing `degraded` without them —
    so the caller that matters most got the least.
    """
    monkeypatch.setenv("AGENT_SIDECAR_RUN_JOURNAL", str(tmp_path / "runs.jsonl"))
    from agent_sidecar.outcome import summarise

    raw = {
        "result": 144,
        "steps": 1,
        "step_errors": [],
        "tokens": {"input": 10, "output": 2, "total": 12},
        "tools": {"enabled": True, "offered": 110, "selected": ["omniroute_web_search"],
                  "missing": [], "misdirected": []},
    }
    summary = summarise(raw, runner="smolagents", model="opencode/big-pickle")

    assert set(summary) == {
        "result", "runner", "model", "served_by", "steps", "step_errors",
        "tokens", "tools", "degraded",
    }
    # Coerced: a CodeAgent can return a number.
    assert summary["result"] == "144"
    assert summary["degraded"] is False


def test_summarise_counts_tool_trouble_as_degraded():
    from agent_sidecar.outcome import summarise

    summary = summarise(
        {"result": "ok", "steps": 1, "step_errors": [],
         "tools": {"enabled": True, "missing": ["omniroute_web_search"]}},
        runner="smolagents",
        model="m",
    )

    # No step failed, yet the agent answered without the tool it was configured
    # to hold — which is invisible in `result` and is the whole reason
    # `degraded` is not simply bool(step_errors).
    assert summary["degraded"] is True


def test_served_by_is_reported_separately_from_the_model_asked_for():
    """A combo name is a request, not an answer.

    Ask for `paid-first` and the reply may come from Opus or, if the ladder
    fell all the way through, from the free tier — and reporting only the
    request makes those two look identical. `ask_model` has always distinguished
    them; run_agent reported the request and labelled it `model`.
    """
    from agent_sidecar.outcome import summarise

    summary = summarise(
        {"result": "ok", "steps": 1, "step_errors": [],
         "served_by": "claude-opus-4-6-thinking-high"},
        runner="smolagents",
        model="paid-first",
    )

    assert summary["model"] == "paid-first"
    assert summary["served_by"] == "claude-opus-4-6-thinking-high"


def test_an_undeterminable_served_model_is_null_not_the_request():
    """Falling back to the requested name would be worse than saying nothing:
    it would assert a fact the runner does not have."""
    from agent_sidecar.outcome import summarise

    summary = summarise({"result": "ok"}, runner="smolagents", model="paid-first")

    assert summary["served_by"] is None


def test_a_model_override_counts_as_degraded():
    """The failure this was written for, and it is not hypothetical.

    The gateway switches routing strategy on prompt content, so a request
    naming agy/claude-sonnet-4-6 comes back from big-pickle whenever the prompt
    looks like an agent's — which is every run this service makes. It happens
    inside a vendored subtree that must not be edited, so it cannot be fixed
    here. It can stop being invisible.
    """
    from agent_sidecar.outcome import summarise

    summary = summarise(
        {"result": "ok", "steps": 1, "step_errors": [], "served_by": "big-pickle"},
        runner="smolagents",
        model="agy/claude-sonnet-4-6",
    )

    assert summary["degraded"] is True
    assert "model override" in summary["step_errors"][0]
    assert "big-pickle" in summary["step_errors"][0]


def test_the_provider_prefix_is_not_treated_as_a_mismatch():
    """The gateway replies without the provider prefix, so a naive comparison
    would call every single correct run degraded."""
    from agent_sidecar.outcome import summarise

    for asked, served in (
        ("agy/claude-sonnet-4-6", "claude-sonnet-4-6"),
        ("opencode/big-pickle", "big-pickle"),
        ("openrouter/deepseek/deepseek-v4-pro-0813", "deepseek/deepseek-v4-pro-0813"),
    ):
        summary = summarise(
            {"result": "ok", "steps": 1, "step_errors": [], "served_by": served},
            runner="smolagents",
            model=asked,
        )
        assert summary["degraded"] is False, f"{asked} -> {served} misread as override"


def test_a_combo_being_answered_by_a_tier_is_not_an_override():
    """A combo name asks for a ladder, not for one model. paid-first answered
    by Opus is the ladder working exactly as designed."""
    from agent_sidecar.outcome import summarise

    summary = summarise(
        {"result": "ok", "steps": 1, "step_errors": [],
         "served_by": "claude-opus-4-6-thinking-high"},
        runner="smolagents",
        model="paid-first",
    )

    assert summary["degraded"] is False


def test_an_unknown_served_model_does_not_invent_an_override():
    from agent_sidecar.outcome import summarise

    summary = summarise(
        {"result": "ok", "steps": 1, "step_errors": [], "served_by": None},
        runner="smolagents",
        model="agy/claude-sonnet-4-6",
    )

    assert summary["degraded"] is False


# --------------------------------------------------------------------------
# vps_status had no test at all. It is the tool Claude reads before deciding
# whether the box has room for more work, so a silent change in any of its four
# shell one-liners would produce confident wrong answers about capacity.
# --------------------------------------------------------------------------


def test_vps_status_reports_the_four_facts_it_promises():
    from agent_sidecar import mcp_server

    body = mcp_server.vps_status.fn() if hasattr(mcp_server.vps_status, "fn") else mcp_server.vps_status()

    assert set(body) == {"memory", "disk", "load", "sidecar_uptime", "note"}
    # Real values, not the "<unavailable: …>" placeholder the helper falls back
    # to — a health tool that reports a placeholder as if it were a reading is
    # worse than one that errors.
    for key in ("memory", "disk", "load", "sidecar_uptime"):
        assert body[key], f"{key} came back empty"
        assert not body[key].startswith("<unavailable"), f"{key} = {body[key]}"


def test_vps_status_memory_avoids_the_free_command_that_is_not_installed():
    """procps is absent from python:slim, so `free` returns an empty string.

    That was the original bug: a memory field reading "" looks like a value.
    The reading comes from /proc/meminfo instead, so it must carry both numbers.
    """
    from agent_sidecar import mcp_server

    body = mcp_server.vps_status.fn() if hasattr(mcp_server.vps_status, "fn") else mcp_server.vps_status()

    assert "MB total" in body["memory"]
    assert "MB available" in body["memory"]


def test_vps_status_says_its_view_is_the_container_not_the_gateway():
    """The note is load-bearing: this container holds no Docker socket by
    design, so anyone reading these numbers as gateway health would be wrong
    about what they are looking at."""
    from agent_sidecar import mcp_server

    body = mcp_server.vps_status.fn() if hasattr(mcp_server.vps_status, "fn") else mcp_server.vps_status()

    assert "omniroute_get_health" in body["note"]
