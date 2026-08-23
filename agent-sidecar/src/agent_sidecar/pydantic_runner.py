"""pydantic-ai typed Agent entrypoint, backed by OmniRoute."""

from __future__ import annotations

from .config import Settings, load_settings
from .omniroute_model import pydantic_ai_model


def build_agent(settings: Settings | None = None):
    from pydantic_ai import Agent

    settings = settings or load_settings()
    model = pydantic_ai_model(settings)
    return Agent(model)


def run_sync(task: str, settings: Settings | None = None) -> str:
    agent = build_agent(settings)
    result = agent.run_sync(task)
    return result.output


if __name__ == "__main__":
    import sys

    task = " ".join(sys.argv[1:]) or "Say OK"
    print(run_sync(task))
