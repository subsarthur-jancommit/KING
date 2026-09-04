"""End-to-end smoke test: both runners against a live OmniRoute instance.

Mirrors the technique omniroute-smoke.yml already uses in CI — the keyless,
no-"enable"-step free provider `opencode/big-pickle` — so this needs no real
upstream provider credentials, only a running OmniRoute and an
OMNIROUTE_API_KEY (any scope that includes at least `models` + `routing`).

Skipped automatically if OmniRoute isn't reachable or no key is configured,
so it never fails a run that simply hasn't set up the prerequisites (see
docs/integrations/scalability-system.md, "Fase 3").
"""

from __future__ import annotations

import os

import httpx
import pytest

from agent_sidecar.config import load_settings
from agent_sidecar.pydantic_runner import run_sync as pydantic_run_sync
from agent_sidecar.smol_runner import run as smol_run


def _omniroute_reachable(base_url: str) -> bool:
    try:
        resp = httpx.get(f"{base_url}/healthz", timeout=5.0)
        return resp.status_code == 200
    except httpx.HTTPError:
        return False


settings = load_settings()
pytestmark = pytest.mark.skipif(
    not settings.omniroute_api_key or not _omniroute_reachable(settings.omniroute_base_url),
    reason=(
        "OMNIROUTE_API_KEY not set or OmniRoute not reachable at "
        f"{settings.omniroute_base_url} — see docs/integrations/"
        "scalability-system.md 'Fase 3' for setup."
    ),
)


def _skip_if_upstream_is_down(exc: Exception) -> None:
    """Distinguish "our wiring is broken" from "the free provider is down".

    These tests exist to prove the sidecar reaches OmniRoute and OmniRoute
    routes onward. `opencode/big-pickle` is a free, keyless, best-effort
    provider, and when it is unavailable OmniRoute answers 503 with
    code `service_unavailable` — which is itself proof the request travelled
    the whole path and was routed. Failing on that turns a third party's
    uptime into this repo's build status.

    Observed for real: CI run 33047603557 went red purely because
    opencode-zen returned "Upstream request failed: Endpoint is unavailable."

    Anything else — a connection error, a 4xx, a malformed reply — still
    fails, because those do indicate something here is wrong.
    """
    message = str(exc)
    if "service_unavailable" in message or "Upstream request failed" in message:
        pytest.skip(
            "Upstream free provider is unavailable (OmniRoute returned 503). "
            "The request reached OmniRoute and was routed, so the path under "
            f"test is intact. Provider message: {message[:200]}"
        )


def test_smolagents_reaches_omniroute():
    try:
        outcome = smol_run("Say exactly: SMOKE-TEST-OK, nothing else.", settings)
    except Exception as exc:
        _skip_if_upstream_is_down(exc)
        raise
    assert "SMOKE-TEST-OK" in outcome["result"]
    # The answer alone is not evidence. An agent blocked from doing the work
    # once wrote `print("HTTP Status Code: 200")` and presented it as a real
    # fetch, so the runner returns step records the model does not author —
    # and a smoke test that ignores them is checking the half that can lie.
    assert not outcome["step_errors"], outcome["step_errors"]


def test_pydantic_ai_reaches_omniroute():
    try:
        outcome = pydantic_run_sync("Say exactly: SMOKE-TEST-OK, nothing else.", settings)
    except Exception as exc:
        _skip_if_upstream_is_down(exc)
        raise
    assert "SMOKE-TEST-OK" in outcome["result"]


@pytest.mark.skipif(
    not os.environ.get("OMNIROUTE_MCP_API_KEY"),
    reason="OMNIROUTE_MCP_API_KEY not set — MCP tool loading is opt-in, see mcp_tools module docstring.",
)
def test_mcp_tools_load_via_smolagents():
    from smolagents import MCPClient

    from agent_sidecar.mcp_tools import smolagents_mcp_server_parameters

    params = smolagents_mcp_server_parameters(settings)
    with MCPClient(params, structured_output=True) as tools:
        assert len(tools) > 0
