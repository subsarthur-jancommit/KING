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
import os
import subprocess
import sys
import time
import urllib.request
from dataclasses import replace
from datetime import datetime, timezone

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from .config import load_settings
from .outcome import journal_run, summarise, trim_if_oversized

# MCP ships DNS-rebinding protection that validates the Host header against an
# allow-list defaulting to localhost only. Behind a reverse proxy the header is
# the public name, so every request arrives as "Invalid Host header" — a 200
# with that body rather than an error status, which reads like a broken tool
# rather than a rejected host.
#
# The fix is to add the real host, NOT to disable the protection: it is the
# only thing stopping a page in a browser from driving this endpoint through a
# victim's own network.
_LOOPBACK = ["127.0.0.1:*", "localhost:*", "[::1]:*"]
_extra_hosts = [
    h.strip()
    for h in os.environ.get("AGENT_SIDECAR_MCP_ALLOWED_HOSTS", "").split(",")
    if h.strip()
]

mcp = FastMCP(
    "king",
    # No session state to lose across a reverse proxy — the same reason the
    # codegraph server runs with --stateless.
    stateless_http=True,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=_LOOPBACK + _extra_hosts,
        allowed_origins=[f"https://{h}" for h in _extra_hosts]
        + ["http://127.0.0.1:*", "http://localhost:*", "http://[::1]:*"],
    ),
)


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
    """Returns {result, runner, model, steps, step_errors, tokens, tools, degraded}."""
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

    started = time.monotonic()
    outcome = smol_runner.run(task, settings)
    # The same summariser the HTTP path uses. These were built separately and
    # drifted: this one omitted token counts and the tool report, and computed
    # `degraded` from step errors alone — so a run whose tools failed to load
    # reported clean to the caller that matters most, since this is how Claude
    # reaches the agent.
    summary = summarise(outcome, runner="smolagents", model=settings.model_id)
    # And it wrote nothing to the journal, which made the journal worse than
    # incomplete: it recorded operator curl while the busiest caller left no
    # trace, so every question asked of it was answered from a biased sample.
    journal_run(summary, task=task, seconds=time.monotonic() - started, caller="mcp")
    return summary


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


@mcp.tool(
    description=(
        "Run a shell command on the KING VPS and return stdout, stderr and the "
        "exit code. The working directory is the repository. Use for git, "
        "docker compose, reading logs, running scripts in scripts/. Disabled "
        "unless the operator has explicitly enabled it."
    )
)
def vps_exec(command: str, timeout: int = 60) -> dict:
    """Shell on the host, gated and audited.

    Two things about this tool are deliberate and worth stating plainly.

    It is OFF by default. `AGENT_SIDECAR_EXEC_ENABLED` must be set, because a
    deployment that grew a shell by accident is exactly the failure this whole
    service is otherwise built to avoid.

    And **the agent never gets it.** smolagents is constructed with `tools=[]`,
    so a task the agent reads can never reach this — which matters because the
    agent reads web pages, and a page carrying instructions plus a shell is a
    direct path from someone else's text to this machine. Claude holds the
    operator's context; the agent holds only what it read.
    """
    if os.environ.get("AGENT_SIDECAR_EXEC_ENABLED", "").strip().lower() not in (
        "1",
        "true",
        "yes",
    ):
        return {
            "error": "vps_exec is disabled; set AGENT_SIDECAR_EXEC_ENABLED=true",
            "enabled": False,
        }

    if not isinstance(command, str) or not command.strip():
        return {"error": "command is required and must be a non-empty string"}

    # Bounded: a command that never returns would hold the bridge open, the
    # same failure an unbounded agent loop already demonstrated.
    timeout = max(1, min(int(timeout), 600))
    workdir = os.environ.get("AGENT_SIDECAR_WORKDIR", "/workspace")

    _audit(command, timeout)
    try:
        p = subprocess.run(
            ["sh", "-c", command],
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=workdir if os.path.isdir(workdir) else None,
        )
    except subprocess.TimeoutExpired:
        return {"error": f"timed out after {timeout}s", "command": command}
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}", "command": command}

    # Capped so one `docker logs` cannot flood the caller's context.
    cap = 20000
    out, err = p.stdout or "", p.stderr or ""
    return {
        "exit_code": p.returncode,
        "stdout": out[:cap],
        "stderr": err[:cap],
        "truncated": len(out) > cap or len(err) > cap,
        "cwd": workdir,
    }


def _audit(command: str, timeout: int) -> None:
    """Append every command to a file, best-effort.

    Best-effort on purpose: an unwritable audit path must not stop the
    operator working, but it also must not silently look like it logged. The
    failure is written to stderr, which lands in the container log.
    """
    path = os.environ.get("AGENT_SIDECAR_EXEC_AUDIT", "/audit/vps_exec.log")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # Bounded for the same reason the run journal is: an append-only file
        # nothing rotates is a slow leak, and a full disk takes down every
        # container on this host rather than only the one that filled it.
        # 2 MB rather than the journal's 5 — a command line is far shorter than
        # a run record, so this still holds tens of thousands of commands.
        trim_if_oversized(path, 2 * 1024 * 1024)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(
                f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}"
                f"\ttimeout={timeout}\t{command}\n"
            )
    except Exception as exc:  # noqa: BLE001 — see docstring
        print(f"[vps_exec] audit write failed: {exc}", file=sys.stderr, flush=True)


app = mcp.streamable_http_app()
