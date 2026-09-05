"""Which tools an agent is allowed to hold.

No network and no MCP server: `select_agent_tools` takes whatever the server
offered and the settings, and is pure. That matters, because the one assertion
here that must never regress — that a shell can never reach the agent — would
otherwise only be checked when a live gateway happened to be reachable.
"""

from __future__ import annotations

import pytest

from agent_sidecar.config import load_settings
from agent_sidecar.mcp_tools import NEVER_REGISTER, select_agent_tools
from agent_sidecar import smol_runner
from agent_sidecar.smol_runner import _TokenCeiling, uses_tool_calling


class _Tool:
    """Stands in for a smolagents Tool; selection only ever reads `.name`."""

    def __init__(self, name: str) -> None:
        self.name = name

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"_Tool({self.name!r})"


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    monkeypatch.delenv("AGENT_SIDECAR_AGENT_TOOLS", raising=False)


def _settings(monkeypatch, allowlist: str | None = None):
    if allowlist is not None:
        monkeypatch.setenv("AGENT_SIDECAR_AGENT_TOOLS", allowlist)
    return load_settings()


def test_only_allowlisted_tools_are_selected(monkeypatch):
    offered = [
        _Tool("omniroute_web_search"),
        _Tool("omniroute_switch_combo"),
        _Tool("omniroute_cache_flush"),
    ]
    tools, report = select_agent_tools(offered, _settings(monkeypatch, "omniroute_web_search"))

    assert [t.name for t in tools] == ["omniroute_web_search"]
    # The other two were offered and simply not asked for. An allowlist means a
    # `git subtree pull` that adds twenty tools adds none of them here — a
    # denylist would be wrong from the moment upstream grew until someone
    # noticed.
    assert report["offered"] == 3
    assert report["selected"] == ["omniroute_web_search"]


def test_a_shell_is_never_registered_even_if_asked_for(monkeypatch):
    """The invariant. `vps_exec` runs commands on the VPS as the sidecar user.

    An agent reads web pages, and a page carrying injected instructions plus a
    shell is a direct path from someone else's text to this machine. So this is
    not a default to be overridden by configuration: naming it in the allowlist
    must still not produce it.
    """
    offered = [_Tool("vps_exec"), _Tool("omniroute_web_search")]
    tools, report = select_agent_tools(
        offered, _settings(monkeypatch, "vps_exec,omniroute_web_search")
    )

    names = [t.name for t in tools]
    assert "vps_exec" not in names
    assert names == ["omniroute_web_search"]
    # And it is not quietly dropped: being offered a shell at all means the URL
    # points at this service instead of the gateway, which the operator has to
    # be told about rather than merely protected from.
    assert report["misdirected"] == ["vps_exec"]


def test_recursion_and_shell_tools_are_all_blocked(monkeypatch):
    # run_agent would let the agent re-enter itself; ask_model is this
    # service's own model call. Neither belongs in an agent's hands.
    offered = [_Tool(name) for name in sorted(NEVER_REGISTER)]
    tools, report = select_agent_tools(
        offered, _settings(monkeypatch, ",".join(sorted(NEVER_REGISTER)))
    )

    assert tools == []
    assert report["misdirected"] == sorted(NEVER_REGISTER)


def test_a_tool_that_was_asked_for_but_not_offered_is_reported(monkeypatch):
    """An upstream rename must not read as success.

    With no report, an allowlist that matches nothing produces an agent with no
    tools that answers from training data and sounds exactly like one that
    searched. That is the failure mode a self-hosted search layer produced for
    real: not an outage, confident wrong answers.
    """
    offered = [_Tool("omniroute_web_search")]
    tools, report = select_agent_tools(
        offered, _settings(monkeypatch, "omniroute_web_search,omniroute_web_fetch")
    )

    assert [t.name for t in tools] == ["omniroute_web_search"]
    assert report["missing"] == ["omniroute_web_fetch"]


def test_no_allowlist_selects_nothing(monkeypatch):
    offered = [_Tool("omniroute_web_search")]
    tools, report = select_agent_tools(offered, _settings(monkeypatch, "none"))

    assert tools == []
    assert report["missing"] == []
    assert report["offered"] == 1


def test_tools_without_a_name_are_ignored(monkeypatch):
    class _Nameless:
        name = None

    offered = [_Nameless(), _Tool("omniroute_web_search")]
    tools, report = select_agent_tools(offered, _settings(monkeypatch, "omniroute_web_search"))

    assert [t.name for t in tools] == ["omniroute_web_search"]
    assert report["offered"] == 1


def test_tool_runs_use_tool_calling_not_code_execution():
    # An agent holding web tools must not also be a CodeAgent: CodeAgent runs
    # model-authored Python, and turning untrusted page content into code on
    # this host is the whole hazard. A run WITH tools uses ToolCallingAgent
    # (no code execution, nothing to sandbox); a run WITHOUT tools stays a
    # CodeAgent in the sandbox.
    assert uses_tool_calling([object()]) is True
    assert uses_tool_calling([]) is False


# --------------------------------------------------------------------------
# _load_tools: the failure paths. None of these had a test, and every one of
# them exists so that a gateway problem does not become a 500 — which means a
# bug in them would be invisible in exactly the situation they were written for.
# --------------------------------------------------------------------------


def test_no_mcp_key_means_no_tools_and_says_so(monkeypatch):
    monkeypatch.delenv("OMNIROUTE_MCP_API_KEY", raising=False)
    tools, client, report = smol_runner._load_tools(_settings(monkeypatch))

    assert tools == []
    assert client is None
    # enabled=False is the honest signal: not "the gateway had no tools", but
    # "tool loading was never attempted".
    assert report["enabled"] is False


def test_allowlist_of_none_skips_loading_even_with_a_key(monkeypatch):
    monkeypatch.setenv("OMNIROUTE_MCP_API_KEY", "a-manage-scoped-key")
    tools, client, report = smol_runner._load_tools(_settings(monkeypatch, "none"))

    assert (tools, client) == ([], None)
    assert report["enabled"] is False


def test_an_unreachable_gateway_is_reported_not_raised(monkeypatch):
    """A gateway blip must not turn every agent run into a 500.

    The agent without tools is the agent this service shipped with for weeks.
    But it must not degrade *quietly* either, so the reason travels back in the
    report and /run folds it into `degraded`.
    """
    monkeypatch.setenv("OMNIROUTE_MCP_API_KEY", "a-manage-scoped-key")

    class _Boom:
        def __init__(self, *a, **k):
            raise ConnectionError("gateway refused the connection")

    monkeypatch.setattr("smolagents.MCPClient", _Boom, raising=True)

    tools, client, report = smol_runner._load_tools(_settings(monkeypatch, "omniroute_web_search"))

    assert (tools, client) == ([], None)
    assert report["enabled"] is True
    assert "ConnectionError" in report["error"]
    assert "gateway refused" in report["error"]


def test_a_failure_after_connecting_still_closes_the_connection(monkeypatch):
    """The one that leaks if nobody checks.

    MCPClient connects inside __init__, so a failure in get_tools() leaves a
    live transport behind. Without the disconnect in that branch the sidecar
    would accumulate open sessions against the gateway, one per failed run.
    """
    monkeypatch.setenv("OMNIROUTE_MCP_API_KEY", "a-manage-scoped-key")
    closed = []

    class _HalfBroken:
        def __init__(self, *a, **k):
            pass

        def get_tools(self):
            raise RuntimeError("tool listing blew up")

        def disconnect(self):
            closed.append(True)

    monkeypatch.setattr("smolagents.MCPClient", _HalfBroken, raising=True)

    tools, client, report = smol_runner._load_tools(_settings(monkeypatch, "omniroute_web_search"))

    assert (tools, client) == ([], None)
    assert closed == [True], "the transport was left open after a failed get_tools()"
    assert "RuntimeError" in report["error"]


def test_a_working_gateway_returns_tools_and_the_client_to_close(monkeypatch):
    monkeypatch.setenv("OMNIROUTE_MCP_API_KEY", "a-manage-scoped-key")

    class _Working:
        def __init__(self, *a, **k):
            pass

        def get_tools(self):
            return [_Tool("omniroute_web_search"), _Tool("omniroute_switch_combo")]

        def disconnect(self):
            pass

    monkeypatch.setattr("smolagents.MCPClient", _Working, raising=True)

    tools, client, report = smol_runner._load_tools(_settings(monkeypatch, "omniroute_web_search"))

    assert [t.name for t in tools] == ["omniroute_web_search"]
    # The caller gets the client back precisely so run() can close it in a
    # finally block — the tool list stays usable outside a `with`, the
    # transport does not close itself.
    assert client is not None
    assert report["enabled"] is True
    assert report["offered"] == 2


# --------------------------------------------------------------------------
# The token ceiling. max_steps bounds how many times the loop turns; nothing
# bounded what one turn costs, and a tool returning a large page moves the
# context a long way in a single step.
# --------------------------------------------------------------------------


class _FakeAgent:
    """Minimal stand-in: the ceiling only reads monitor totals and interrupts."""

    def __init__(self, total):
        self.interrupted = False
        outer = self

        class _Monitor:
            def get_total_token_counts(self):
                class _Usage:
                    total_tokens = outer._total

                return _Usage()

        self._total = total
        self.monitor = _Monitor()

    def interrupt(self):
        self.interrupted = True


def test_ceiling_lets_a_run_under_budget_continue():
    ceiling = _TokenCeiling(1000)
    agent = _FakeAgent(999)

    ceiling(object(), agent=agent)

    assert ceiling.tripped is False
    assert agent.interrupted is False
    assert ceiling.used == 999


def test_ceiling_interrupts_once_the_budget_is_passed():
    ceiling = _TokenCeiling(1000)
    agent = _FakeAgent(1001)

    ceiling(object(), agent=agent)

    assert ceiling.tripped is True
    assert agent.interrupted is True


def test_ceiling_interrupts_only_once():
    """A second trip must not re-interrupt an already-stopping agent."""
    ceiling = _TokenCeiling(10)
    agent = _FakeAgent(50)

    ceiling(object(), agent=agent)
    agent.interrupted = False
    ceiling(object(), agent=agent)

    assert agent.interrupted is False


def test_a_broken_monitor_never_breaks_the_run():
    """A ceiling that throws would turn a cost guard into an outage."""

    class _Exploding:
        class monitor:
            @staticmethod
            def get_total_token_counts():
                raise RuntimeError("monitor is confused")

        interrupted = False

        def interrupt(self):
            self.interrupted = True

    ceiling = _TokenCeiling(10)
    agent = _Exploding()

    ceiling(object(), agent=agent)

    assert ceiling.tripped is False
    assert agent.interrupted is False


def test_an_agent_without_a_monitor_is_ignored():
    class _Bare:
        pass

    ceiling = _TokenCeiling(10)
    ceiling(object(), agent=_Bare())

    assert ceiling.tripped is False
