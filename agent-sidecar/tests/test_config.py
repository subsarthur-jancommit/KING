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
    ):
        monkeypatch.delenv(var, raising=False)


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
