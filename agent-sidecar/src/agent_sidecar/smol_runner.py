"""smolagents CodeAgent entrypoint, backed by OmniRoute."""

from __future__ import annotations

from smolagents import CodeAgent

from .config import Settings, load_settings
from .omniroute_model import smolagents_model


def build_agent(settings: Settings | None = None) -> CodeAgent:
    settings = settings or load_settings()
    model = smolagents_model(settings)
    return CodeAgent(
        tools=[],
        model=model,
        # Empty by default. With executor_type=local this is the ONLY boundary,
        # and it holds: asked to read /etc/passwd and to fetch a URL, an agent
        # tried open(), pathlib, builtins (to recover open) and urllib, and
        # every one was refused. It is still an AST filter, not an OS sandbox —
        # smolagents says so — which is why the real answer is a remote
        # executor.
        #
        # Widening it is a separate, explicit decision (see config.py), because
        # a list that grew automatically when the executor changed would be a
        # permission change nobody made.
        additional_authorized_imports=list(settings.authorized_imports),
        executor_type=settings.executor_type,
        max_steps=settings.max_steps,
    )


def _diagnostics(agent: CodeAgent) -> dict:
    """Structural evidence about the run, taken from the agent's own memory.

    This exists because the answer text cannot be trusted on its own. Blocked
    from fetching a URL, an agent wrote `print("HTTP Status Code: 200")` and
    presented that as a real fetch, complete with a fabricated `Output:` line
    and the code it had NOT been able to run. The prose lied; the step records
    did not. A caller needs something the model does not author.
    """
    steps = list(getattr(getattr(agent, "memory", None), "steps", []) or [])
    errors: list[str] = []
    counted = 0
    for step in steps:
        # TaskStep and PlanningStep carry no `error` attribute; only action
        # steps do, so this both filters and collects in one pass.
        if not hasattr(step, "error"):
            continue
        counted += 1
        err = step.error
        if err:
            errors.append(f"step {getattr(step, 'step_number', counted)}: {err}")
    return {"steps": counted, "step_errors": errors}


def run(task: str, settings: Settings | None = None) -> dict:
    """Run the agent and return its answer alongside what actually happened.

    Returns a dict rather than a bare string so the caller sees `step_errors`.
    An agent that could not do the thing and says it did is worse than one that
    fails, and this is the only signal that distinguishes them.
    """
    agent = build_agent(settings)
    result = agent.run(task)
    return {"result": result, **_diagnostics(agent)}


if __name__ == "__main__":
    import sys

    task = " ".join(sys.argv[1:]) or "Say OK"
    outcome = run(task)
    print(outcome["result"])
    if outcome["step_errors"]:
        print(f"\n[{len(outcome['step_errors'])} step(s) errored]", file=sys.stderr)
        for line in outcome["step_errors"]:
            print(f"  {line}", file=sys.stderr)
