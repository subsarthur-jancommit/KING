"""The default toolset must not carry the word that flips the gateway.

Measured 2026-09-07 against the gateway's own `x-omniroute-decision` header,
3 repeats per case. `graph_stats` was the sole trigger among the eleven tools
the agent used to be offered, and the carrier was one word in the server's own
description — "Return summary statistics: ...".

These tests exist because the finding is invisible in the code. Nothing about
the string "graph_stats" explains why it costs the caller their model, so the
next person tidying this list will re-add it, and the failure is silent: the
agent still works, it just answers from a model nobody asked for.
"""

from agent_sidecar.config import DEFAULT_AGENT_TOOLS, REROUTE_TRIGGER_TOOLS


def test_reroute_trigger_tools_are_not_offered_by_default():
    overlap = set(DEFAULT_AGENT_TOOLS) & set(REROUTE_TRIGGER_TOOLS)
    assert not overlap, (
        f"{sorted(overlap)} is in DEFAULT_AGENT_TOOLS. Measured 2026-09-07: "
        "offering it flips the gateway to strategy=auto, so the caller stops "
        "getting the model they asked for (19 of 21 runs overridden with it, "
        "0 of 2 without). Re-add it per-call with AGENT_SIDECAR_AGENT_TOOLS "
        "if a task genuinely needs it."
    )


def test_the_three_useful_graph_tools_survive():
    # The point was never to strip the code graph — only the one description
    # that carries the trigger word. If this fails, the cure removed the cause
    # AND the benefit.
    for name in ("get_node", "get_neighbors", "query_graph"):
        assert name in DEFAULT_AGENT_TOOLS, f"{name} should still be offered"


def test_no_default_tool_name_hints_at_the_trigger_word():
    # A weak guard on purpose: it cannot see the server's descriptions, only
    # the names we choose. It catches the obvious case of a future
    # `*_summary`/`summarize_*` tool being added to the default without anyone
    # re-running the probe in docs/king-system.md 4.
    offenders = [t for t in DEFAULT_AGENT_TOOLS
                 if "summar" in t.lower()]
    assert not offenders, (
        f"{offenders} may trip the gateway's intent classifier; re-run the "
        "reroute probe before adding it to the default."
    )


# --- the per-call escape hatch -------------------------------------------
#
# Excluding graph_stats is only defensible if a caller who needs it can still
# ask. These pin the request contract, including the one case that must NOT be
# reachable through it.

import pytest
from starlette.testclient import TestClient

from agent_sidecar import server

TOKEN = "test-token-not-a-real-secret"


@pytest.fixture(autouse=True)
def _auth_configured(monkeypatch):
    # /run fails closed without a token; same reason test_server.py does this.
    monkeypatch.setenv("AGENT_SIDECAR_AUTH_TOKEN", TOKEN)


@pytest.fixture
def client():
    return TestClient(server.app, headers={"Authorization": f"Bearer {TOKEN}"})


@pytest.mark.parametrize("bad", ["graph_stats", [1, 2], [""], [None], {"a": 1}])
def test_tools_must_be_a_list_of_strings(client, bad):
    r = client.post("/run", json={"task": "x", "tools": bad})
    assert r.status_code == 400, f"{bad!r} should be rejected"
    assert "tools" in r.json()["error"]


def test_empty_tools_list_is_not_a_malformed_request(client):
    # [] is a real choice, not a mistake: it is how a caller says "answer this
    # without tools". It must not be rejected the way a bad type is.
    r = client.post("/run", json={"task": "x", "tools": []})
    assert r.status_code != 400


def test_a_caller_cannot_reach_a_never_register_tool_through_the_override():
    # The boundary lives in select_agent_tools, not in request validation, so
    # this asserts the invariant where it is actually enforced — a caller
    # supplying the name directly must still not get the tool.
    from agent_sidecar.mcp_tools import NEVER_REGISTER, select_agent_tools

    class _Tool:
        def __init__(self, name):
            self.name = name

    offered = [_Tool(n) for n in sorted(NEVER_REGISTER)] + [_Tool("get_node")]

    class _S:
        agent_tools = tuple(sorted(NEVER_REGISTER)) + ("get_node",)

    selected, report = select_agent_tools(offered, _S())
    names = {getattr(t, "name", None) for t in selected}
    assert names == {"get_node"}, f"leaked: {sorted(names - {'get_node'})}"
    # And it must say so rather than quietly dropping them. `blocked`, not
    # `misdirected`: being refused is the correct outcome, while `misdirected`
    # means OMNIROUTE_MCP_URL is pointed at this service instead of the
    # gateway. They were one field, and folding them together is what made
    # `degraded` fire on every single run.
    assert report["blocked"] == sorted(NEVER_REGISTER)


# --- the category, not the example ---------------------------------------
#
# The test above proves a caller cannot reach `vps_exec` through the per-call
# override. It passed while `omniroute_memory_clear` — a gateway tool that
# wipes the memory store — was reachable by exactly that route, because
# NEVER_REGISTER held only this service's own three tools while config.py
# claimed otherwise.
#
# A test written against one example proves one example. These assert the
# category: every destructive tool the gateway offers is blocked, and the
# comment in config.py is true rather than aspirational.

DESTRUCTIVE_GATEWAY_TOOLS = (
    "omniroute_memory_clear",
    "omniroute_ccr_delete",
    "omniroute_pool_reset",
    "obsidian_delete_note",
)


@pytest.mark.parametrize("name", DESTRUCTIVE_GATEWAY_TOOLS)
def test_destructive_gateway_tools_can_never_be_registered(name):
    from agent_sidecar.mcp_tools import NEVER_REGISTER

    assert name in NEVER_REGISTER, (
        f"{name} is destructive and is not in NEVER_REGISTER, so an allowlist "
        "naming it — including the per-call `tools` override — would be honoured."
    )


@pytest.mark.parametrize("name", DESTRUCTIVE_GATEWAY_TOOLS)
def test_a_caller_asking_for_a_destructive_tool_does_not_get_it(name):
    from agent_sidecar.mcp_tools import select_agent_tools

    class _Tool:
        def __init__(self, n):
            self.name = n

    class _S:
        agent_tools = (name, "get_node")

    selected, report = select_agent_tools([_Tool(name), _Tool("get_node")], _S())
    assert {getattr(t, "name", None) for t in selected} == {"get_node"}
    assert name in report["blocked"], "the report must say it was blocked, not drop it silently"


def test_the_config_comment_is_not_aspirational():
    # config.py states a guarantee about omniroute_memory_clear. If that
    # sentence survives while the guarantee does not, the comment becomes the
    # reason nobody checks.
    import pathlib

    from agent_sidecar.mcp_tools import NEVER_REGISTER

    cfg = pathlib.Path(__file__).resolve().parents[1] / "src" / "agent_sidecar" / "config.py"
    text = cfg.read_text(encoding="utf-8")
    if "omniroute_memory_clear" in text and "cannot be reached" in text:
        assert "omniroute_memory_clear" in NEVER_REGISTER


# --- `degraded` must not be permanently on -------------------------------
#
# It was, for two independent reasons, both of them correct behaviour being
# misread as failure: the code graph is skipped by design on the local path, so
# its three tools were "missing" on every local run; and NEVER_REGISTER grew to
# include four destructive GATEWAY tools, so `misdirected` — which means
# "OMNIROUTE_MCP_URL points at us" — fired on every run too.
#
# outcome.py already warns about exactly this shape for `model_overridden`:
# a flag that is always on trains the caller to ignore the one signal that
# means the answer may be wrong. These tests exist so it cannot recur a third
# time.

def _summary(**tool_report):
    from agent_sidecar.outcome import summarise

    base = {"offered": 110, "selected": [], "missing": [], "misdirected": []}
    base.update(tool_report)
    return summarise(
        {"result": "x", "step_errors": [], "tools": base, "tools_used": []},
        runner="smolagents",
        model="ollama/qwen2.5:1.5b-instruct-q4_K_M",
    )


def test_deliberate_skip_does_not_degrade():
    out = _summary(
        missing=["get_neighbors", "get_node", "query_graph"],
        withheld=["http://codegraph-serve:8130/mcp: skipped for a local model"],
    )
    assert out["degraded"] is False


def test_missing_without_a_reason_still_degrades():
    out = _summary(missing=["get_neighbors"], withheld=[])
    assert out["degraded"] is True


def test_a_server_that_failed_always_degrades():
    # Even alongside a deliberate skip: `error` means something broke.
    out = _summary(
        error="http://codegraph-serve:8130/mcp: TimeoutError",
        missing=["get_node"],
        withheld=["http://codegraph-serve:8130/mcp: skipped for a local model"],
    )
    assert out["degraded"] is True


def test_blocked_gateway_tools_are_not_misdirection():
    from agent_sidecar.mcp_tools import NEVER_REGISTER, SELF_TOOLS, select_agent_tools
    from agent_sidecar.config import load_settings

    class _T:
        def __init__(self, n):
            self.name = n

    gateway_destructive = sorted(NEVER_REGISTER - SELF_TOOLS)
    assert gateway_destructive, "the wider blocklist must hold more than the self tools"

    settings = load_settings()
    offered = [_T(n) for n in gateway_destructive] + [_T("omniroute_web_search")]
    _, report = select_agent_tools(offered, settings)
    # Blocked, yes — but the gateway offering them is normal, not a sign that
    # OMNIROUTE_MCP_URL is pointed at this service.
    assert report["misdirected"] == []
    for name in gateway_destructive:
        assert name not in report["selected"]


def test_the_self_tools_still_signal_misdirection():
    from agent_sidecar.mcp_tools import SELF_TOOLS, select_agent_tools
    from agent_sidecar.config import load_settings

    class _T:
        def __init__(self, n):
            self.name = n

    offered = [_T(n) for n in sorted(SELF_TOOLS)]
    _, report = select_agent_tools(offered, load_settings())
    assert report["misdirected"] == sorted(SELF_TOOLS)
