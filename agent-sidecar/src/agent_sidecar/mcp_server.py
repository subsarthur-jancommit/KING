"""MCP surface for Claude.

Why this exists. Everything this VPS can do was reachable only by curl from
inside the box, or through four thin Activepieces flows. Claude had five tools
while the machine ran 1,019 models, a 59k-node code graph, and an agent runtime
with an off-host sandbox. The gap was not capability, it was the absence of a
door.

This is the door for the parts OmniRoute's own MCP server does not cover.
OmniRoute already exposes 110 tools at /api/mcp/stream (routing, quotas, cost,
skills, memory) and codegraph exposes 10 at :8130/mcp. Neither can run an
agent, so that is what this adds — and nothing that duplicates them.

Stateless on purpose: `stateless_http=True` means no session state to lose
across a reverse proxy, which is the same reason the codegraph server runs
with --stateless.
"""

from __future__ import annotations

import json
import subprocess
import urllib.request
from dataclasses import replace

from mcp.server.fastmcp import FastMCP

from .config import load_settings

mcp = FastMCP("king", stateless_http=True)


@mcp.tool(
    description=(
        "Run a multi-step agent on the KING VPS. The agent writes and executes "
        "Python inside an off-host sandbox, loops until done, and returns its "
        "answer. ALWAYS read `degraded` before trusting `result`: true means at "
        "least one step failed and the answer was produced despite it — the "
        "agent fabricates when the sandbox blocks it."
    )
)
def run_agent(
    task: str, model: str | None = None, max_steps: int | None = None
) -> dict:
    """Returns {result, model, steps, step_errors, degraded}."""
    from . import smol_runner

    settings = load_settings()
    if model and model.strip():
        settings = replace(settings, model_id=model.strip())
    if max_steps is not None:
        # Bounded above by config, never raised by the caller: the ceiling
        # exists because a caller that times out does NOT stop the agent.
        settings = replace(
            settings, max_steps=min(int(max_steps), settings.max_steps)
        )

    outcome = smol_runner.run(task, settings)
    errors = outcome.get("step_errors") or []
    return {
        "result": str(outcome.get("result")),
        "model": settings.model_id,
        "steps": outcome.get("steps"),
        "step_errors": errors,
        "degraded": bool(errors),
    }


@mcp.tool(
    description=(
        "Ask any model in the gateway a single question — no agent loop, no "
        "code execution. Use a combo name (paid-first, free-then-local, "
        "websearch-tiers) or a model id (agy/claude-opus-4-6-thinking-high). "
        "Returns the answer and which model actually served it, so a silent "
        "fall to a weaker tier is visible."
    )
)
def ask_model(prompt: str, model: str = "paid-first", max_tokens: int = 1200) -> dict:
    settings = load_settings()
    body = json.dumps(
        {
            "model": model,
            "max_tokens": int(max_tokens),
            "temperature": 0,
            "messages": [{"role": "user", "content": prompt}],
        }
    ).encode()
    req = urllib.request.Request(
        f"{settings.omniroute_base_url}/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {settings.omniroute_api_key or ''}",
        },
    )
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=180).read().decode())
    except Exception as exc:  # surfaced, not swallowed — see server.py
        return {"error": f"{type(exc).__name__}: {exc}", "requested_model": model}
    msg = (d.get("choices") or [{}])[0].get("message") or {}
    return {
        "answer": (msg.get("content") or msg.get("reasoning") or "").strip(),
        "requested_model": model,
        # The model that actually answered. A combo can fall several tiers
        # without erroring, and the text alone never shows it.
        "served_by": d.get("model"),
        "usage": d.get("usage"),
    }


@mcp.tool(
    description=(
        "Read-only health of the KING VPS: running containers with status, "
        "memory, disk, and load. Use before deciding whether the box has room "
        "for more work."
    )
)
def vps_status() -> dict:
    def sh(cmd: str) -> str:
        try:
            return subprocess.run(
                ["sh", "-c", cmd], capture_output=True, text=True, timeout=25
            ).stdout.strip()
        except Exception as exc:
            return f"<unavailable: {type(exc).__name__}>"

    # No Docker socket in this container by design, so container state comes
    # from the gateway rather than from `docker ps`. Memory and disk are this
    # container's view; on a single-purpose VPS that tracks the host closely
    # enough to answer "is there room", which is what this is for.
    return {
        # /proc/meminfo rather than `free`: this is a python:slim image and
        # procps is not installed, so `free` returned an empty string — a
        # health tool reporting "" for memory is worse than one that errors.
        "memory": sh(
            "awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}"
            "END{printf \"%d MB total, %d MB available\", t/1024, a/1024}' /proc/meminfo"
        ),
        "disk": sh("df -h / | awk 'NR==2{print $3\" used of \"$2\" (\"$5\")\"}'"),
        "load": sh("cat /proc/loadavg | cut -d' ' -f1-3"),
        "sidecar_uptime": sh("cat /proc/uptime | cut -d' ' -f1"),
        "note": (
            "Container-level view. For gateway-side health use OmniRoute's own "
            "omniroute_get_health tool."
        ),
    }


app = mcp.streamable_http_app()
