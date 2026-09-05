"""Unit tests for settings loading.

Deliberately unconditional, unlike test_smoke.py: those all skip without a
reachable OmniRoute, which meant a `pytest tests/` run outside CI proved
nothing at all. These need no network, no credentials and no Docker, so the
suite has real coverage everywhere it runs.
"""

from __future__ import annotations

import pytest

from agent_sidecar.config import VALID_EXECUTORS, load_settings


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    """Settings read straight from os.environ, so a stray value in the ambient
    environment (CI exports several of these) would otherwise leak into every
    assertion below."""
    for var in (
        "OMNIROUTE_BASE_URL",
        "OMNIROUTE_API_KEY",
        "OMNIROUTE_MCP_API_KEY",
        "OMNIROUTE_MCP_URL",
        "AGENT_SIDECAR_MODEL_ID",
        "AGENT_SIDECAR_EXECUTOR",
        "AGENT_SIDECAR_MAX_STEPS",
        "AGENT_SIDECAR_AUTHORIZED_IMPORTS",
        "AGENT_SIDECAR_AGENT_TOOLS",
        "AGENT_SIDECAR_MAX_TOKENS",
        "GRAPHIFY_API_KEY",
        "CODEGRAPH_MCP_URL",
    ):
        monkeypatch.delenv(var, raising=False)


def test_authorized_imports_default_to_nothing():
    # With executor_type=local this list is the entire boundary, so the default
    # must be closed. Widening it is a separate decision from changing the
    # executor.
    assert load_settings().authorized_imports == ()


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("json", ("json",)),
        ("json,re,datetime", ("json", "re", "datetime")),
        (" json , re ", ("json", "re")),
        ("json,,re", ("json", "re")),
        ("", ()),
        ("   ", ()),
    ],
)
def test_authorized_imports_are_parsed_from_a_comma_list(raw, expected, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_AUTHORIZED_IMPORTS", raw)
    assert load_settings().authorized_imports == expected


def test_changing_the_executor_does_not_widen_imports(monkeypatch):
    # The failure this guards: bundling "use a sandbox" with "allow more
    # imports" would make the second happen without anyone choosing it.
    monkeypatch.setenv("AGENT_SIDECAR_EXECUTOR", "e2b")
    assert load_settings().authorized_imports == ()


def test_max_steps_defaults_to_a_finite_number():
    # An agent loop is the only thing here that can spend without bound, so the
    # default must be a real ceiling rather than smolagents' own.
    assert load_settings().max_steps == 8


@pytest.mark.parametrize("raw,expected", [("1", 1), ("20", 20), (" 5 ", 5)])
def test_max_steps_is_read_from_the_environment(raw, expected, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MAX_STEPS", raw)
    assert load_settings().max_steps == expected


@pytest.mark.parametrize("bad", ["nope", "3.5", ""])
def test_non_integer_max_steps_fails_fast(bad, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MAX_STEPS", bad)
    if bad == "":
        # Empty falls back to the default rather than erroring, matching how
        # every other variable here treats an unset-but-present value.
        assert load_settings().max_steps == 8
        return
    with pytest.raises(ValueError, match="AGENT_SIDECAR_MAX_STEPS"):
        load_settings()


@pytest.mark.parametrize("bad", ["0", "-1"])
def test_max_steps_below_one_fails_fast(bad, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MAX_STEPS", bad)
    with pytest.raises(ValueError, match="at least 1"):
        load_settings()


def test_executor_defaults_to_local():
    assert load_settings().executor_type == "local"


@pytest.mark.parametrize("executor", VALID_EXECUTORS)
def test_every_documented_executor_is_accepted(executor, monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_EXECUTOR", executor)
    assert load_settings().executor_type == executor


def test_unknown_executor_fails_fast(monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_EXECUTOR", "not-a-sandbox")
    with pytest.raises(ValueError, match="not-a-sandbox"):
        load_settings()


def test_blank_executor_falls_back_to_local(monkeypatch):
    """An empty or whitespace-only value is what an unset shell variable or an
    `AGENT_SIDECAR_EXECUTOR=` line in a .env file produces; treat it as unset
    rather than rejecting it."""
    monkeypatch.setenv("AGENT_SIDECAR_EXECUTOR", "   ")
    assert load_settings().executor_type == "local"


def test_valid_executors_matches_smolagents():
    """Guards against smolagents widening or narrowing its own Literal on an
    upgrade without this list being updated to match."""
    import typing

    from smolagents import CodeAgent

    hints = typing.get_type_hints(CodeAgent.__init__)
    assert set(typing.get_args(hints["executor_type"])) == set(VALID_EXECUTORS)


def test_base_url_trailing_slash_is_stripped(monkeypatch):
    """The MCP URL is derived by string concatenation, so a trailing slash
    would produce a double slash in the resulting endpoint."""
    monkeypatch.setenv("OMNIROUTE_BASE_URL", "http://omniroute-base:20128/")
    settings = load_settings()
    assert settings.omniroute_base_url == "http://omniroute-base:20128"
    assert settings.omniroute_mcp_url == "http://omniroute-base:20128/api/mcp/stream"


def test_agent_tools_default_to_the_read_mostly_set():
    tools = load_settings().agent_tools
    assert "omniroute_web_search" in tools
    assert "omniroute_web_fetch" in tools
    # OmniRoute tags twelve tools "phase 1", and two of them rewrite the live
    # gateway's routing. Usefulness to an MCP client is not the same question
    # as safety in the hands of an agent that reads web pages.
    assert "omniroute_switch_combo" not in tools
    assert "omniroute_create_combo" not in tools
    # Writes to the memory store are the point of the memory store; wiping it
    # is not something an agent should reach.
    assert "omniroute_memory_add" in tools
    assert "omniroute_memory_clear" not in tools


def test_agent_tools_can_be_narrowed(monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_AGENT_TOOLS", " omniroute_web_search , omniroute_get_health ")
    assert load_settings().agent_tools == ("omniroute_web_search", "omniroute_get_health")


def test_agent_tools_none_means_none(monkeypatch):
    # Spelled out rather than implied by an empty string: empty means "unset,
    # use the default" everywhere else here, so a silent no-tools run would be
    # indistinguishable from a misconfiguration.
    monkeypatch.setenv("AGENT_SIDECAR_AGENT_TOOLS", "none")
    assert load_settings().agent_tools == ()


def test_max_tokens_defaults_to_a_generous_backstop():
    # A backstop, not a budget: a measured 3-step search run cost ~24k, so the
    # default sits far above normal operation and exists to stop something
    # pathological rather than to shape ordinary runs.
    assert load_settings().max_tokens == 250000


def test_max_tokens_zero_disables_the_ceiling(monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MAX_TOKENS", "0")
    assert load_settings().max_tokens == 0


def test_a_negative_max_tokens_is_rejected(monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MAX_TOKENS", "-1")
    with pytest.raises(ValueError, match="must be 0"):
        load_settings()


def test_a_non_integer_max_tokens_is_rejected(monkeypatch):
    monkeypatch.setenv("AGENT_SIDECAR_MAX_TOKENS", "lots")
    with pytest.raises(ValueError, match="not an integer"):
        load_settings()


def test_the_default_allowlist_reaches_both_mcp_servers():
    """Two services, one allowlist. The code graph answers "what calls this"
    without that work landing in Claude's context, which is what this whole
    service is for."""
    tools = load_settings().agent_tools

    assert "omniroute_web_search" in tools          # OmniRoute
    assert "get_neighbors" in tools                 # codegraph
    # Read-only only: the graph's PR-triage tools are left out, since an agent
    # that reads web pages has no business acting on pull requests.
    for acting in ("list_prs", "get_pr_impact", "triage_prs"):
        assert acting not in tools


def test_codegraph_is_optional_and_absent_without_its_key(monkeypatch):
    monkeypatch.delenv("GRAPHIFY_API_KEY", raising=False)
    monkeypatch.setenv("OMNIROUTE_MCP_API_KEY", "a-manage-scoped-key")
    from agent_sidecar.mcp_tools import smolagents_mcp_server_parameters

    servers = smolagents_mcp_server_parameters(load_settings())

    # One server, not a crash and not a silent second entry with no key: a
    # codegraph outage or an unset key must not cost the agent its web search.
    assert len(servers) == 1
    assert "api/mcp/stream" in servers[0]["url"]


def test_codegraph_is_added_when_its_key_is_present(monkeypatch):
    monkeypatch.setenv("OMNIROUTE_MCP_API_KEY", "a-manage-scoped-key")
    monkeypatch.setenv("GRAPHIFY_API_KEY", "a-graph-key")
    from agent_sidecar.mcp_tools import smolagents_mcp_server_parameters

    servers = smolagents_mcp_server_parameters(load_settings())

    assert len(servers) == 2
    assert servers[1]["headers"]["Authorization"] == "Bearer a-graph-key"
