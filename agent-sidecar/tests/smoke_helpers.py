"""Helpers for the live smoke test, kept out of it so they can be tested.

`test_smoke.py` carries a module-level `skipif` that probes for a reachable
OmniRoute, so every test in it is skipped on a machine without one — including
the `agent-sidecar-unit` CI job, which builds the sidecar alone with no gateway.
A judgement call defined there would therefore be exercised only in the job that
needs a live gateway, which is the job most likely to be red for reasons of its
own.

This module imports nothing and touches no network, so the classifier below can
be tested wherever the suite runs.
"""

from __future__ import annotations

# The one step-error class that cannot indicate a broken path.
#
# smolagents raises this when the text the model emitted is not valid Python.
# It says something about the model's output formatting and nothing about
# whether the sidecar reached the gateway, whether the gateway routed, or
# whether the tools loaded.
_PARSE_FAILURE = "Code parsing failed"


def path_errors(step_errors: list[str]) -> list[str]:
    """The step errors that could mean the path under test is broken.

    `step_errors` mixes two populations and only one belongs in a smoke test's
    verdict.

    A **code parsing** failure is the model emitting malformed text. Observed
    2026-09-06: `opencode/big-pickle` wrote a valid
    `final_answer("SMOKE-TEST-OK")` and then a stray `</` on the next line. The
    agent recovered and returned the right answer on step 4. Nothing about the
    sidecar, the gateway or the tools was wrong — a free model produced a bad
    first draft, and CI went red for it.

    Everything else stays fatal, and that distinction is the whole point. A
    `NameError` is what a **missing tool** looks like from inside the sandbox:
    the agent calls `omniroute_web_search`, it was never registered, and Python
    reports it is not defined. That is exactly the silent degradation the
    assertion exists to catch. So syntax-level parse failures are forgiven and
    name or execution errors never are.

    This deliberately does not soften the production `degraded` flag, which
    should still go true when the agent stumbles. It only decides whether a
    third party's output formatting is allowed to fail this repo's build.
    """
    return [e for e in step_errors if _PARSE_FAILURE not in e]
