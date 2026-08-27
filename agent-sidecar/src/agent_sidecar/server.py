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

import anyio
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from .config import load_settings

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
            # Booleans only — never the keys themselves. This endpoint is
            # unauthenticated (see the module docstring in docs) and its whole
            # job is to be safe to curl.
            "omniroute_api_key_set": settings.omniroute_api_key is not None,
            "mcp_tools_enabled": settings.omniroute_mcp_api_key is not None,
            "runners": sorted(RUNNERS),
        }
    )


async def run(request: Request) -> JSONResponse:
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

    func = _resolve(runner)
    try:
        result = await anyio.to_thread.run_sync(func, task)
    except Exception as exc:
        # The message is returned rather than swallowed because the caller is a
        # workflow step whose only view of this service is the response body;
        # a bare 500 would make every failure look identical. The type name is
        # included for the same reason.
        return JSONResponse(
            {"error": f"{type(exc).__name__}: {exc}", "runner": runner},
            status_code=500,
        )

    # smolagents returns whatever the agent produced, which is not always a
    # string (a CodeAgent can return a number or a list). Coerce so the
    # response shape is stable for the caller.
    return JSONResponse({"result": str(result), "runner": runner})


app = Starlette(
    routes=[
        Route("/healthz", health, methods=["GET"]),
        Route("/run", run, methods=["POST"]),
    ]
)
