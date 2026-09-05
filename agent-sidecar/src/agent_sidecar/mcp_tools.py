"""Optional MCP tool loading against OmniRoute's own MCP server.

Deliberately separate from omniroute_model.py's default (chat-completion-only)
path. Validated against a live instance that OmniRoute's Streamable HTTP MCP
endpoint (/api/mcp/stream) requires a 'manage' or 'admin' scoped API key —
the narrower 'mcp:connect' scope only bypasses the loopback-only network
restriction, it does not by itself satisfy requireManagementAuth()'s scope
check. That is a materially more privileged key than the sidecar's default
(models,routing,health) key, so this module — and the
OMNIROUTE_MCP_API_KEY env var it reads — is opt-in and separate on purpose.
Provision that key yourself, understanding the elevated trust, only if you
actually want the sidecar to call OmniRoute's MCP tools.
"""

from __future__ import annotations

from .config import Settings


def mcp_tools_enabled(settings: Settings) -> bool:
    return bool(settings.omniroute_mcp_api_key)


def smolagents_mcp_server_parameters(settings: Settings) -> list[dict]:
    """Every MCP server the agent should load tools from.

    A list, because smolagents' MCPClient accepts one — OmniRoute's 110 tools
    and codegraph's ten are different services with different keys, and a
    codegraph outage must not cost the agent its web search.

    Only servers with a key configured are included. codegraph is optional and
    silently absent when `GRAPHIFY_API_KEY` is unset; OmniRoute is not, because
    without it there is nothing to load and the caller asked for tools.
    """
    if not settings.omniroute_mcp_api_key:
        raise RuntimeError(
            "OMNIROUTE_MCP_API_KEY is not set — MCP tool loading is opt-in, "
            "see agent_sidecar.mcp_tools module docstring."
        )
    servers = [
        {
            "url": settings.omniroute_mcp_url,
            "transport": "streamable-http",
            "headers": {"Authorization": f"Bearer {settings.omniroute_mcp_api_key}"},
        }
    ]
    if settings.codegraph_mcp_api_key:
        servers.append(
            {
                "url": settings.codegraph_mcp_url,
                "transport": "streamable-http",
                "headers": {
                    "Authorization": f"Bearer {settings.codegraph_mcp_api_key}"
                },
            }
        )
    return servers


def pydantic_ai_mcp_toolset(settings: Settings):
    if not settings.omniroute_mcp_api_key:
        raise RuntimeError(
            "OMNIROUTE_MCP_API_KEY is not set — MCP tool loading is opt-in, "
            "see agent_sidecar.mcp_tools module docstring."
        )
    from pydantic_ai.mcp import MCPToolset

    return MCPToolset(
        settings.omniroute_mcp_url,
        headers={"Authorization": f"Bearer {settings.omniroute_mcp_api_key}"},
    )

# Never handed to an agent. Not a policy default — an invariant.
#
# These three are the sidecar's OWN MCP tools (see mcp_server.py), not
# OmniRoute's, so under correct configuration they are not in the offered set
# at all. They are listed because the failure that would put them there is
# quiet: point OMNIROUTE_MCP_URL at this service instead of the gateway and the
# agent is suddenly holding a shell on the VPS, plus run_agent to recurse into
# itself. An agent that reads web pages must never hold either, and "the URL is
# probably right" is not a boundary.
NEVER_REGISTER = frozenset({"vps_exec", "run_agent", "ask_model"})


def select_agent_tools(offered, settings: Settings):
    """Choose which of the server's tools the agent may hold.

    Returns (tools, report). The report exists because every way this can go
    wrong is otherwise silent: a renamed tool upstream, a typo in the env var,
    or the whole allowlist matching nothing all produce an agent with no tools
    and no complaint — which looks exactly like the agent we already had.
    """
    by_name = {}
    for tool in offered:
        name = getattr(tool, "name", None)
        if name:
            by_name[name] = tool

    # Checked against everything OFFERED, not merely everything requested.
    # A hit here means OMNIROUTE_MCP_URL is pointed at this service rather than
    # the gateway, and the caller needs to know that, not just be protected
    # from it.
    misdirected = sorted(n for n in by_name if n in NEVER_REGISTER)

    selected, missing = [], []
    for name in settings.agent_tools:
        if name in NEVER_REGISTER:
            continue
        tool = by_name.get(name)
        if tool is None:
            missing.append(name)
        else:
            selected.append(tool)

    return selected, {
        "offered": len(by_name),
        "selected": [getattr(t, "name", "?") for t in selected],
        "missing": missing,
        "misdirected": misdirected,
    }
