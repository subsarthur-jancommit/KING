"""smolagents runner, backed by OmniRoute.

Two agent kinds, chosen by whether the run has tools:

* No tools -> CodeAgent. It writes Python and needs somewhere safe to run it,
  which is the e2b/modal sandbox. This is the "run arbitrary code" path.

* Tools loaded -> ToolCallingAgent. It emits JSON tool calls and executes no
  arbitrary Python at all, so there is nothing to sandbox. That is the correct
  shape for an agent that reads web pages: the only actions it can take are the
  allowlisted MCP tools, and untrusted page content can never become code
  running on this host. It is also the only shape that works — a remote
  CodeAgent serializes each tool's source into the sandbox, and the
  dynamically-wrapped MCPAdaptTool fails that validation (measured: "Tool
  validation failed for MCPAdaptTool ... 'func' is undefined").
"""

from __future__ import annotations

from smolagents import CodeAgent, ToolCallingAgent
from smolagents.utils import AgentError

from .config import Settings, load_settings
from .mcp_tools import (
    mcp_tools_enabled,
    select_agent_tools,
    smolagents_mcp_server_parameters,
)
from .omniroute_model import smolagents_model


# Two measured failures shaped this, and they pull in opposite directions.
#
# First: the model filled the tool's `provider` field with `duckduckgo-free`,
# which the gateway lists but holds no credential for, so the search returned
# nothing and the run burned its step budget retrying other dead providers.
#
# The obvious fix — "do not set provider" — was tried and was WRONG. The run
# records came back with `Argument provider is required` three times: the MCP
# tool's schema marks the field required, and smolagents validates arguments
# client-side before the request is ever sent. (A direct MCP call without it
# succeeds, because the server itself is lenient. Only the client is strict.)
#
# So the field must be set, and set to one that exists. Of the twenty search
# and fetch providers the gateway advertises, exactly one reports
# `cred=configured`: tavily-search, which serves both search and fetch.
TOOL_AGENT_INSTRUCTIONS = (
    "For omniroute_web_search and omniroute_web_fetch you MUST set "
    '`provider` to "tavily-search". It is the only provider with credentials '
    "configured on this gateway; any other value returns no results. "
    "If a tool returns nothing, say you could not find it — never invent an "
    "answer or fall back to your own memory of the world."
)


class _TokenCeiling:
    """Stops a run that has cost more than it is allowed to.

    smolagents bounds iterations with max_steps but nothing bounds what one
    iteration costs, and a tool returning a large page moves the context a long
    way in a single step. This is the second half of the rule that came out of
    an agent running past the caller that had already given up: the loop is the
    one thing here that can spend without bound, so the ceiling lives in the
    service.

    Registered as a step callback, which smolagents invokes as
    `callback(memory_step, agent=...)` after each ActionStep — and after the
    monitor's own metrics callback, so the totals it reads are current.
    """

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.used = 0
        self.tripped = False

    def __call__(self, memory_step, agent=None) -> None:
        if agent is None or self.tripped:
            return
        counts = getattr(getattr(agent, "monitor", None), "get_total_token_counts", None)
        if not callable(counts):
            return
        try:
            self.used = getattr(counts(), "total_tokens", 0) or 0
        except Exception:  # noqa: BLE001 - a ceiling must not itself break a run
            return
        if self.used > self.limit:
            self.tripped = True
            # Cooperative: smolagents raises AgentError at the next step
            # boundary rather than tearing down mid-tool-call.
            agent.interrupt()


def uses_tool_calling(tools) -> bool:
    """Tool-bearing runs use ToolCallingAgent; codeexecution runs use CodeAgent.

    Split out as a pure function so the choice is unit-testable without building
    a live agent or reaching smolagents at all.
    """
    return bool(tools)


def build_agent(settings: Settings | None = None, tools=None, ceiling=None):
    settings = settings or load_settings()
    model = smolagents_model(settings)
    tools = list(tools or [])
    callbacks = [ceiling] if ceiling is not None else None

    if uses_tool_calling(tools):
        # No executor_type and no additional_authorized_imports: this agent
        # runs no arbitrary Python, so neither the sandbox nor the import
        # allowlist applies. The tool allowlist (config.py + mcp_tools.py) is
        # the whole boundary, and it is enforced before we ever get here.
        return ToolCallingAgent(
            tools=tools,
            model=model,
            max_steps=settings.max_steps,
            instructions=TOOL_AGENT_INSTRUCTIONS,
            step_callbacks=callbacks,
        )

    return CodeAgent(
        tools=tools,
        model=model,
        # With executor_type=local this list is the ONLY boundary, and it holds:
        # asked to read /etc/passwd and to fetch a URL, an agent tried open(),
        # pathlib, builtins (to recover open) and urllib, and every one was
        # refused. It is still an AST filter, not an OS sandbox — smolagents
        # says so — which is why the real answer is a remote executor.
        #
        # Widening it is a separate, explicit decision (see config.py), because
        # a list that grew automatically when the executor changed would be a
        # permission change nobody made.
        additional_authorized_imports=list(settings.authorized_imports),
        executor_type=settings.executor_type,
        max_steps=settings.max_steps,
        step_callbacks=callbacks,
    )


def _diagnostics(agent) -> dict:
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
    return {"steps": counted, "step_errors": errors, "tokens": _token_usage(agent)}


def _token_usage(agent) -> dict | None:
    """What the run cost, from the agent's own monitor.

    smolagents already computes this and prints it to the container log —
    "Input tokens: 13,993 | Output tokens: 603" — where it is unparseable and
    scrolls away. The caller, who is the one deciding whether to run the agent
    again, never saw it at all.

    Defensive on every access: pydantic_runner builds a different agent object,
    and a missing monitor must degrade to `null` rather than turn a successful
    run into a 500 over a metric.
    """
    monitor = getattr(agent, "monitor", None)
    counts = getattr(monitor, "get_total_token_counts", None)
    if not callable(counts):
        return None
    try:
        usage = counts()
    except Exception:  # noqa: BLE001 - a metric must never fail a run
        return None
    return {
        "input": getattr(usage, "input_tokens", None),
        "output": getattr(usage, "output_tokens", None),
        "total": getattr(usage, "total_tokens", None),
    }


def _load_tools(settings: Settings):
    """(tools, client, report) — never raises.

    A gateway that is briefly unreachable must not turn every agent run into a
    500; the agent without tools is exactly the agent this service shipped with
    for weeks. But it must not degrade *quietly* either. Self-hosting a search
    layer that silently returned junk once cost two hours and produced
    confident, sourced, wrong answers, so the reason travels back with the run.
    """
    blank = {
        "enabled": False,
        "offered": 0,
        "selected": [],
        "missing": [],
        "misdirected": [],
    }
    if not mcp_tools_enabled(settings) or not settings.agent_tools:
        return [], None, blank

    from smolagents import MCPClient

    # MCPClient connects inside __init__, so a failure here leaves no client to
    # close and `client` correctly stays None.
    try:
        client = MCPClient(
            smolagents_mcp_server_parameters(settings), structured_output=True
        )
    except Exception as exc:  # noqa: BLE001 - reported, not swallowed
        return [], None, {**blank, "enabled": True, "error": f"{type(exc).__name__}: {exc}"}

    try:
        tools, report = select_agent_tools(client.get_tools(), settings)
    except Exception as exc:  # noqa: BLE001 - reported, not swallowed
        client.disconnect()
        return [], None, {**blank, "enabled": True, "error": f"{type(exc).__name__}: {exc}"}

    return tools, client, {**report, "enabled": True}


def run(task: str, settings: Settings | None = None) -> dict:
    """Run the agent and return its answer alongside what actually happened.

    Returns a dict rather than a bare string so the caller sees `step_errors`.
    An agent that could not do the thing and says it did is worse than one that
    fails, and this is the only signal that distinguishes them.
    """
    settings = settings or load_settings()
    tools, client, tool_report = _load_tools(settings)
    ceiling = _TokenCeiling(settings.max_tokens) if settings.max_tokens > 0 else None
    try:
        agent = build_agent(settings, tools=tools, ceiling=ceiling)
        try:
            result = agent.run(task)
        except AgentError:
            # Hitting the ceiling is a bounded stop, not a crash, so it must not
            # become a 500 — the caller gets whatever the run established, plus
            # a step error saying why it ended. Any OTHER AgentError is a real
            # failure and still propagates.
            if ceiling is None or not ceiling.tripped:
                raise
            result = (
                f"Stopped: this run reached its token ceiling "
                f"({ceiling.used:,} of {ceiling.limit:,} allowed) and was "
                f"interrupted before it could finish."
            )

        outcome = {"result": result, **_diagnostics(agent), "tools": tool_report}
        if ceiling is not None and ceiling.tripped:
            # Goes in step_errors so `degraded` becomes true without the caller
            # needing to know this feature exists.
            outcome["step_errors"] = list(outcome["step_errors"]) + [
                f"token ceiling: used {ceiling.used} of {ceiling.limit} allowed"
            ]
        return outcome
    finally:
        # The tool list stays usable outside a `with` block, but the transport
        # does not close itself — smolagents documents the try/finally pairing.
        if client is not None:
            client.disconnect()


if __name__ == "__main__":
    import sys

    task = " ".join(sys.argv[1:]) or "Say OK"
    outcome = run(task)
    print(outcome["result"])
    if outcome["step_errors"]:
        print(f"\n[{len(outcome['step_errors'])} step(s) errored]", file=sys.stderr)
        for line in outcome["step_errors"]:
            print(f"  {line}", file=sys.stderr)
