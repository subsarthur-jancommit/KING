"""pydantic-ai typed Agent entrypoint, backed by OmniRoute."""

from __future__ import annotations

from .config import Settings, load_settings
from .omniroute_model import pydantic_ai_model


def build_agent(settings: Settings | None = None):
    from pydantic_ai import Agent

    settings = settings or load_settings()
    model = pydantic_ai_model(settings)
    return Agent(model)


def run_sync(task: str, settings: Settings | None = None) -> dict:
    """Same return shape as smol_runner.run, so the HTTP wrapper needs no
    special-casing.

    `steps` is None rather than 0: this runner is a single typed call with no
    iteration to count, and reporting 0 would read as "ran nothing" instead of
    "does not apply". `step_errors` is empty because a failure here raises
    rather than being recorded and continued past.
    """
    agent = build_agent(settings)
    result = agent.run_sync(task)
    # `tokens` is None rather than zeroes, for the same reason `steps` is: this
    # runner does not expose a usage monitor, and reporting 0/0 would read as
    # "the call was free" instead of "not measured here".
    return {
        "result": result.output,
        "steps": None,
        "step_errors": [],
        "tokens": None,
        "served_by": None,
    }


if __name__ == "__main__":
    import sys

    task = " ".join(sys.argv[1:]) or "Say OK"
    print(run_sync(task)["result"])
