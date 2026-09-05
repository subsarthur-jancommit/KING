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


def uses_tool_calling(tools) -> bool:
    """Tool-bearing runs use ToolCallingAgent; codeexecution runs use CodeAgent.

    Split out as a pure function so the choice is unit-testable without building
    a live agent or reaching smolagents at all.
    """
    return bool(tools)


def build_agent(settings: Settings | None = None, tools=None):
    settings = settings or load_settings()
    model = smolagents_model(settings)
    tools = list(tools or [])

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
    return {"steps": counted, "step_errors": errors}


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
    try:
        agent = build_agent(settings, tools=tools)
        result = agent.run(task)
        return {"result": result, **_diagnostics(agent), "tools": tool_report}
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
