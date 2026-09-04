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
    # Bearer token required by POST /run. Fails CLOSED: when this is unset the
    # endpoint refuses every request rather than accepting them. It has to,
    # because /run executes the Python a model writes, and the loopback port
    # binding protects nothing from the Docker bridge — every container on it,
    # including the one that runs model-authored code, reaches
    # http://agent-sidecar-http:8100 directly.
    auth_token: str | None
    # THE SAME LIST MEANS TWO OPPOSITE THINGS depending on executor_type, and
    # this is the single most misleading thing in this service.
    #
    #   local            -> a RESTRICTION. Generated code may import only what
    #                       is listed here, enforced by an AST filter. Empty
    #                       means "nothing", and that is the entire boundary.
    #
    #   e2b / modal      -> an INSTALL MANIFEST. smolagents' remote executors
    #                       pass it to `install_packages()`, i.e. pip. Nothing
    #                       is restricted: generated code can import anything
    #                       already in the sandbox image regardless of this
    #                       list. Verified — with this empty, an agent running
    #                       under e2b imported socket, platform and urllib.
    #
    # So moving to a remote executor does not merely widen the allowlist, it
    # removes the allowlist. That is the intended design — the sandbox is the
    # boundary — but it must be a decision someone makes knowing it, which is
    # why /healthz reports which meaning is in force.
    authorized_imports: tuple[str, ...]
    # Hard ceiling on agent iterations. A loop is the one thing in this stack
    # that can spend without bound, and it does: a 1.5B model driving a
    # CodeAgent produced malformed code blobs, smolagents rejected each one and
    # retried, and the loop was still running at step 5 after the caller had
    # already given up and disconnected at 300 s. A caller timing out does not
    # stop the agent, so the bound has to live here.
    max_steps: int
    # Which MCP tools the agent may hold, by exact name. An ALLOWLIST, never a
    # denylist: OmniRoute serves 110 tools and tags 12 of them "phase 1", but
    # that tag marks usefulness to an MCP client, not safety in the hands of an
    # agent that reads web pages. Two of the twelve — omniroute_switch_combo
    # and omniroute_create_combo — rewrite the live gateway's routing, and a
    # page carrying injected instructions plus a tool that reroutes production
    # is the same shape of hazard as a page plus a shell.
    #
    # Allowlist-only also survives upstream growth: a `git subtree pull` that
    # adds twenty tools adds none of them here. A denylist would have to be
    # updated to stay correct, and would be wrong until someone noticed.
    agent_tools: tuple[str, ...]


# Read-mostly by construction. Search and fetch are what the agent could not
# do at all before; memory is what lets one run leave something for the next.
# Nothing here reconfigures the gateway.
#
# omniroute_memory_add writes, and is included deliberately: the write is
# confined to the memory store, which exists to be written to. Its destructive
# sibling omniroute_memory_clear is not here, and would not be reachable even
# if it were added by hand — see NEVER_REGISTER in mcp_tools.py.
DEFAULT_AGENT_TOOLS: tuple[str, ...] = (
    "omniroute_web_search",
    "omniroute_web_fetch",
    "omniroute_x_search",
    "omniroute_list_models_catalog",
    "omniroute_get_health",
    "omniroute_memory_search",
    "omniroute_memory_add",
)


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
    raw_max_steps = os.environ.get("AGENT_SIDECAR_MAX_STEPS", "8").strip() or "8"
    try:
        max_steps = int(raw_max_steps)
    except ValueError as exc:
        raise ValueError(
            f"AGENT_SIDECAR_MAX_STEPS={raw_max_steps!r} is not an integer"
        ) from exc
    if max_steps < 1:
        raise ValueError(
            f"AGENT_SIDECAR_MAX_STEPS={max_steps} must be at least 1"
        )

    # "none" is spelled out rather than implied by an empty string, because
    # empty means "unset, use the default" everywhere else in this file and a
    # silent tools=[] is indistinguishable from a misconfiguration.
    raw_tools = os.environ.get("AGENT_SIDECAR_AGENT_TOOLS", "").strip()
    if raw_tools.lower() == "none":
        agent_tools: tuple[str, ...] = ()
    elif raw_tools:
        agent_tools = tuple(t.strip() for t in raw_tools.split(",") if t.strip())
    else:
        agent_tools = DEFAULT_AGENT_TOOLS

    return Settings(
        omniroute_base_url=base_url,
        omniroute_api_key=os.environ.get("OMNIROUTE_API_KEY") or None,
        model_id=os.environ.get("AGENT_SIDECAR_MODEL_ID", "opencode/big-pickle"),
        omniroute_mcp_api_key=os.environ.get("OMNIROUTE_MCP_API_KEY") or None,
        omniroute_mcp_url=os.environ.get(
            "OMNIROUTE_MCP_URL", f"{base_url}/api/mcp/stream"
        ),
        executor_type=executor_type,
        auth_token=os.environ.get("AGENT_SIDECAR_AUTH_TOKEN") or None,
        authorized_imports=tuple(
            p.strip()
            for p in os.environ.get("AGENT_SIDECAR_AUTHORIZED_IMPORTS", "").split(",")
            if p.strip()
        ),
        max_steps=max_steps,
        agent_tools=agent_tools,
    )
