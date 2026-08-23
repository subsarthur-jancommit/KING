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


def smolagents_mcp_server_parameters(settings: Settings) -> dict:
    if not settings.omniroute_mcp_api_key:
        raise RuntimeError(
            "OMNIROUTE_MCP_API_KEY is not set — MCP tool loading is opt-in, "
            "see agent_sidecar.mcp_tools module docstring."
        )
    return {
        "url": settings.omniroute_mcp_url,
        "transport": "streamable-http",
        "headers": {"Authorization": f"Bearer {settings.omniroute_mcp_api_key}"},
    }


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
