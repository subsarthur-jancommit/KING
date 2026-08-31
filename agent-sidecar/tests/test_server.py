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


@pytest.fixture
def client():
    return TestClient(server.app)


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


def test_resolve_maps_every_advertised_runner_to_a_real_callable():
    """The only test that exercises the real mapping.

    Every other test patches `_resolve`, so without this a typo in a module
    path or function name in RUNNERS would ship unnoticed and only fail at the
    first real request. This imports the runner modules for real, which is
    exactly the point.
    """
    for runner in server.RUNNERS:
        assert callable(server._resolve(runner)), runner
