"""HTTP wrapper so a workflow step can invoke the runners.

Until now the two runners were reachable only as `docker compose run
agent-sidecar uv run python -m agent_sidecar.smol_runner "..."` — one task per
container start, from an operator's shell. That is fine for a human, but a
workflow engine cannot call it: Activepieces composes steps out of HTTP
requests, not `docker compose run`.

This exposes the same two functions over HTTP without changing either of them.
`smol_runner.run` and `pydantic_runner.run_sync` are imported and called as-is;
nothing about how an agent is built, what it may import, or where it executes
moves here.

Deliberately Starlette rather than FastAPI: `mcp` already pulls Starlette and
Uvicorn into this image, so this endpoint costs no new dependency, and one
JSON route needs nothing FastAPI adds on top.

Run it with the `agent-sidecar-http` profile; see
docs/integrations/activepieces-workflow.md.
"""

from __future__ import annotations

import json
import os
import secrets
import sys
import time
from contextlib import asynccontextmanager
from dataclasses import replace
from datetime import datetime, timezone

import anyio
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route

from .config import load_settings
from .mcp_server import app as mcp_app
from .outcome import journal, journal_run, summarise

# Both runners are fully synchronous and can take minutes: smolagents' CodeAgent
# loops until it reaches an answer. Calling them directly in an async handler
# would block the event loop and stall every other request, so each one is
# handed to a worker thread instead.
RUNNERS = {
    "smolagents": ("agent_sidecar.smol_runner", "run"),
    "pydantic-ai": ("agent_sidecar.pydantic_runner", "run_sync"),
}


def _resolve(runner: str):
    from importlib import import_module

    module_name, func_name = RUNNERS[runner]
    return getattr(import_module(module_name), func_name)


async def health(_request: Request) -> JSONResponse:
    """Liveness plus the effective config, minus anything secret.

    Reports which runners are available and what model they will use, so a
    misconfigured deployment is visible here rather than only in a failed run.
    """
    settings = load_settings()
    return JSONResponse(
        {
            "status": "ok",
            "model_id": settings.model_id,
            "omniroute_base_url": settings.omniroute_base_url,
            "executor_type": settings.executor_type,
            "max_steps": settings.max_steps,
            # The second ceiling. Steps bound how many times the loop turns;
            # this bounds what the turns cost. 0 means disabled.
            "max_tokens": settings.max_tokens,
            # How many runs this container will do at once, and how many are
            # in flight right now. Rejecting the surplus beats an OOM inside
            # the cgroup that kills the runs already working.
            "max_concurrent": RUN_SLOTS.limit,
            "runs_in_flight": RUN_SLOTS.active,
            "authorized_imports": list(settings.authorized_imports),
            # The list above means opposite things per executor, so say which.
            # Under `local` it restricts and is the entire boundary; under a
            # remote sandbox smolagents pip-installs it and restricts nothing,
            # so an operator reading `authorized_imports: []` must not conclude
            # "nothing can be imported".
            "imports_are": (
                "restriction"
                if settings.executor_type == "local"
                else "install-manifest (NOT a restriction)"
            ),
            "agent_tools": list(settings.agent_tools),
            # The trap this guards is the mirror of imports_are: an operator
            # sets AGENT_SIDECAR_AGENT_TOOLS, sees it echoed back, and assumes
            # the agent has tools. It does not, unless a separately provisioned
            # `manage`-scoped OMNIROUTE_MCP_API_KEY is also set — and an agent
            # with no tools answers from training data and sounds identical to
            # one that searched. So report the conjunction, not the setting.
            "agent_tools_active": bool(
                settings.agent_tools and settings.omniroute_mcp_api_key
            ),
            # Booleans only — never the keys themselves. This endpoint is
            # unauthenticated (see the module docstring in docs) and its whole
            # job is to be safe to curl.
            "omniroute_api_key_set": settings.omniroute_api_key is not None,
            # False here means /run is refusing everything, which is a
            # deployment fault worth seeing from the outside.
            "auth_configured": settings.auth_token is not None,
            "mcp_tools_enabled": settings.omniroute_mcp_api_key is not None,
            "runners": sorted(RUNNERS),
        }
    )


def _authorise(request: Request, settings) -> JSONResponse | None:
    """Return a rejection response, or None when the caller may proceed.

    Checked before the body is read, so a rejected request never has its task
    parsed, logged, or echoed back.
    """
    if settings.auth_token is None:
        # Fail closed. An unset token is a misconfiguration, and the safe
        # reading of "no token configured" for an endpoint that executes
        # model-written Python is "nobody may call this" — not "anybody may".
        return JSONResponse(
            {
                "error": "AGENT_SIDECAR_AUTH_TOKEN is not configured; "
                "/run is refusing all requests"
            },
            status_code=503,
        )

    header = request.headers.get("authorization", "")
    scheme, _, presented = header.partition(" ")
    if scheme.lower() != "bearer" or not presented:
        return JSONResponse({"error": "missing bearer token"}, status_code=401)

    # Constant-time: a plain `==` leaks the shared secret one byte at a time to
    # anyone who can measure the response.
    if not secrets.compare_digest(presented, settings.auth_token):
        return JSONResponse({"error": "invalid bearer token"}, status_code=401)

    return None


async def run(request: Request) -> JSONResponse:
    settings = load_settings()
    rejection = _authorise(request, settings)
    if rejection is not None:
        return rejection

    try:
        payload = await request.json()
    except Exception:
        return JSONResponse({"error": "body must be JSON"}, status_code=400)

    if not isinstance(payload, dict):
        return JSONResponse({"error": "body must be a JSON object"}, status_code=400)

    task = payload.get("task")
    if not isinstance(task, str) or not task.strip():
        return JSONResponse(
            {"error": "'task' is required and must be a non-empty string"},
            status_code=400,
        )

    runner = payload.get("runner", "smolagents")
    if runner not in RUNNERS:
        return JSONResponse(
            {
                "error": f"unknown runner {runner!r}",
                "valid_runners": sorted(RUNNERS),
            },
            status_code=400,
        )

    # Per-call model. Without it every caller shares one baked-in default, and
    # the choice that actually matters here — a subscription-quota model that
    # costs nothing per call, a cheap per-token one for volume, or the local
    # one for work that must not leave the host — could only be made by
    # restarting the container. Absent, `load_settings()` keeps its own default.
    model = payload.get("model")
    if model is not None:
        if not isinstance(model, str) or not model.strip():
            return JSONResponse(
                {"error": "'model' must be a non-empty string when given"},
                status_code=400,
            )
        settings = replace(settings, model_id=model.strip())

    # Per-call iteration ceiling, bounded above by the configured one so a
    # caller cannot raise it. A caller that times out does NOT stop the agent —
    # measured: curl gave up at 300 s and the loop was still on step 5 — so
    # this is the only thing that ends a run that will never converge.
    max_steps = payload.get("max_steps")
    if max_steps is not None:
        if not isinstance(max_steps, int) or isinstance(max_steps, bool) or max_steps < 1:
            return JSONResponse(
                {"error": "'max_steps' must be a positive integer when given"},
                status_code=400,
            )
        settings = replace(settings, max_steps=min(max_steps, settings.max_steps))

    # Taken here, after validation, so a malformed request never occupies a
    # slot — and released in `finally` so a crashing run does not leak one.
    if not RUN_SLOTS.try_acquire():
        # Journalled like any other outcome. A rejection is the signal that the
        # service is saturated, which is exactly the trend the journal exists to
        # make answerable — leaving it out would mean the record looks calmest
        # at the moment capacity is being hit hardest.
        journal(
            {
                "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "runner": runner,
                "model": settings.model_id,
                "task": task[:200],
                "seconds": 0.0,
                "error": f"rejected: {RUN_SLOTS.limit} run(s) already in flight",
                "degraded": True,
            }
        )
        return JSONResponse(
            {
                "error": (
                    f"busy: {RUN_SLOTS.limit} agent run(s) already in flight on "
                    f"this container. Retry shortly."
                ),
                "runner": runner,
                "model": settings.model_id,
                "steps": None,
                "step_errors": ["rejected: concurrency limit reached"],
                "degraded": True,
            },
            status_code=429,
            headers={"Retry-After": "30"},
        )

    func = _resolve(runner)
    started = time.monotonic()
    try:
        result = await anyio.to_thread.run_sync(func, task, settings)
    except Exception as exc:
        # The message is returned rather than swallowed because the caller is a
        # workflow step whose only view of this service is the response body;
        # a bare 500 would make every failure look identical. The type name is
        # included for the same reason.
        #
        # `degraded` and `step_errors` are present here too, and that is the
        # point: the documented contract is "read degraded before you read
        # result", and a body that omits the field on the one path where
        # everything failed makes `body.get("degraded")` return None — falsy,
        # i.e. indistinguishable from a clean run to any caller that branches
        # on it rather than on the status code.
        #
        # No `result` key is invented to match the success shape. There is no
        # result, and an empty string here would read as "the agent answered
        # nothing" rather than "the agent never ran".
        journal(
            {
                "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "runner": runner,
                "model": settings.model_id,
                "task": task[:200],
                "seconds": round(time.monotonic() - started, 2),
                "error": f"{type(exc).__name__}: {exc}",
                "degraded": True,
            }
        )
        return JSONResponse(
            {
                "error": f"{type(exc).__name__}: {exc}",
                "runner": runner,
                "model": settings.model_id,
                "steps": None,
                "step_errors": [f"{type(exc).__name__}: {exc}"],
                "degraded": True,
            },
            status_code=500,
        )
    finally:
        RUN_SLOTS.release()

    # smolagents returns whatever the agent produced, which is not always a
    # string (a CodeAgent can return a number or a list), so `summarise`
    # coerces it and builds the one response shape every caller gets — the
    # HTTP one here and the MCP `run_agent` tool alike. They used to be built
    # separately and had drifted apart; see outcome.py.
    outcome = result if isinstance(result, dict) else {"result": result}
    summary = summarise(outcome, runner=runner, model=settings.model_id)
    journal_run(
        summary, task=task, seconds=time.monotonic() - started, caller="http"
    )
    return JSONResponse(summary)


class _RunSlots:
    """Bounded concurrency for agent runs.

    The container is capped at 1 GB and 1 CPU, so it cannot take the host down
    — that lesson is already paid for. But anyio will happily run dozens of
    agent loops in threads, and the failure that produces is an OOM inside the
    cgroup, which kills the runs already in flight along with the ones that
    caused it. Rejecting the surplus is strictly better than losing everybody.

    A plain counter rather than a lock: check and increment happen with no
    `await` between them, and the event loop is single-threaded, so no other
    request can interleave. `limit <= 0` disables the bound.
    """

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.active = 0

    def try_acquire(self) -> bool:
        if self.limit <= 0:
            return True
        if self.active >= self.limit:
            return False
        self.active += 1
        return True

    def release(self) -> None:
        if self.limit > 0 and self.active > 0:
            self.active -= 1


def _slot_limit() -> int:
    raw = os.environ.get("AGENT_SIDECAR_MAX_CONCURRENT", "2").strip() or "2"
    try:
        return int(raw)
    except ValueError:
        # A typo here must not disable the bound silently, and must not stop
        # the service either. Fall back to the default and say so.
        print(
            f"[run] AGENT_SIDECAR_MAX_CONCURRENT={raw!r} is not an integer; using 2",
            file=sys.stderr,
            flush=True,
        )
        return 2


# Process-wide on purpose: the point is to bound what this container runs at
# once, so it cannot be per-request.
RUN_SLOTS = _RunSlots(_slot_limit())


class _McpAuthMiddleware:
    """Bearer auth for the mounted MCP app.

    The MCP surface exposes the same agent as POST /run, so it inherits the
    same rule: fail closed, and check before any body is read. Written as raw
    ASGI rather than BaseHTTPMiddleware because the MCP transport streams, and
    BaseHTTPMiddleware buffers the response body.
    """

    def __init__(self, app, prefix: str = "/mcp"):
        self.app = app
        self.prefix = prefix

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not scope["path"].startswith(self.prefix):
            await self.app(scope, receive, send)
            return

        settings = load_settings()
        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
        presented = ""
        scheme, _, rest = headers.get("authorization", "").partition(" ")
        if scheme.lower() == "bearer":
            presented = rest

        if settings.auth_token is None:
            body, status = b'{"error":"AGENT_SIDECAR_AUTH_TOKEN is not configured"}', 503
        elif not presented or not secrets.compare_digest(presented, settings.auth_token):
            body, status = b'{"error":"invalid or missing bearer token"}', 401
        else:
            await self.app(scope, receive, send)
            return

        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": [(b"content-type", b"application/json")],
            }
        )
        await send({"type": "http.response.body", "body": body})


@asynccontextmanager
async def _lifespan(_app):
    # Starlette does NOT run a mounted app's lifespan, and FastMCP sets up its
    # session manager there. Without this the MCP route 500s on first use with
    # nothing obviously wrong in the config — so it is run explicitly.
    async with mcp_app.router.lifespan_context(mcp_app):
        yield


app = Starlette(
    lifespan=_lifespan,
    middleware=[Middleware(_McpAuthMiddleware)],
    routes=[
        Route("/healthz", health, methods=["GET"]),
        Route("/run", run, methods=["POST"]),
        # Mounted last: the two Routes above match first, so this only ever
        # receives /mcp. FastMCP serves that path itself.
        Mount("/", app=mcp_app),
    ],
)
