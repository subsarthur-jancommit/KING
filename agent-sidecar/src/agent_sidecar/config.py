"""Environment configuration, reusing OmniRoute's own documented convention
(omniroute/.env.example, "Internal Agent & MCP Integrations") rather than
inventing a new one.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    omniroute_base_url: str
    omniroute_api_key: str | None
    model_id: str
    # MCP tool loading is opt-in and requires a SEPARATE, more-privileged key
    # (see docs/integrations/scalability-system.md — /api/mcp/stream requires
    # 'manage'/'admin' scope, validated the hard way; the sidecar's default
    # key intentionally does NOT carry that scope).
    omniroute_mcp_api_key: str | None
    omniroute_mcp_url: str
    # Where smolagents' CodeAgent executes the Python it generates. "local"
    # means in-process, guarded only by an AST-level import allowlist that
    # smolagents explicitly documents as not a security boundary. That is
    # appropriate while tasks come from an operator on the command line, and
    # not appropriate the moment untrusted input can reach this service.
    # See docs/integrations/vps-hardening.md.
    executor_type: str


# Mirrors smolagents.CodeAgent's own Literal for executor_type (verified
# against smolagents 1.26.0). Kept here so a typo fails immediately with a
# clear message instead of surfacing deep inside smolagents at agent build.
VALID_EXECUTORS = ("local", "blaxel", "e2b", "modal", "docker")


def load_settings() -> Settings:
    base_url = os.environ.get("OMNIROUTE_BASE_URL", "http://localhost:20128").rstrip("/")
    executor_type = os.environ.get("AGENT_SIDECAR_EXECUTOR", "local").strip() or "local"
    if executor_type not in VALID_EXECUTORS:
        raise ValueError(
            f"AGENT_SIDECAR_EXECUTOR={executor_type!r} is not supported; "
            f"expected one of {', '.join(VALID_EXECUTORS)}"
        )
    return Settings(
        omniroute_base_url=base_url,
        omniroute_api_key=os.environ.get("OMNIROUTE_API_KEY") or None,
        model_id=os.environ.get("AGENT_SIDECAR_MODEL_ID", "opencode/big-pickle"),
        omniroute_mcp_api_key=os.environ.get("OMNIROUTE_MCP_API_KEY") or None,
        omniroute_mcp_url=os.environ.get(
            "OMNIROUTE_MCP_URL", f"{base_url}/api/mcp/stream"
        ),
        executor_type=executor_type,
    )
