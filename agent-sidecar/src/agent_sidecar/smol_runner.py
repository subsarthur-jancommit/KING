"""smolagents CodeAgent entrypoint, backed by OmniRoute."""

from __future__ import annotations

from smolagents import CodeAgent

from .config import Settings, load_settings
from .omniroute_model import smolagents_model


def build_agent(settings: Settings | None = None) -> CodeAgent:
    settings = settings or load_settings()
    model = smolagents_model(settings)
    return CodeAgent(tools=[], model=model, additional_authorized_imports=[])


def run(task: str, settings: Settings | None = None) -> str:
    agent = build_agent(settings)
    return agent.run(task)


if __name__ == "__main__":
    import sys

    task = " ".join(sys.argv[1:]) or "Say OK"
    print(run(task))
