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
