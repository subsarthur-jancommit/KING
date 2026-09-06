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
# smolagents emits it in two forms, and matching only the one you happen to
# have seen is how this was got wrong the first time. From its source, both
# occurrences and no others:
#
#   agents.py:1712                "Error in code parsing: ... Make sure to
#                                  provide correct code blobs."
#                                 — the model never produced a <code> block
#   local_python_executor.py:1618 "Code parsing failed on line {n} due to:
#                                  {SyntaxError}: ..."
#                                 — the model produced one, and it was not
#                                   valid Python
#
# Both say something about the model's output formatting and nothing about
# whether the sidecar reached the gateway, whether the gateway routed, or
# whether the tools loaded. The shared substring is matched case-insensitively
# rather than either literal, so a wording change upstream degrades to a red
# build rather than a silently wrong classification.
_PARSE_FAILURE = "code parsing"


def path_errors(step_errors: list[str]) -> list[str]:
    """The step errors that could mean the path under test is broken.

    `step_errors` mixes two populations and only one belongs in a smoke test's
    verdict.

    A **code parsing** failure is the model emitting malformed text. Both
    observed on 2026-09-06 within half an hour, from `opencode/big-pickle`:
    once a valid `final_answer("SMOKE-TEST-OK")` followed by a stray `</`, and
    once the bare text `SMOKE-TEST-OK</code>` with no code block at all. The
    agent recovered both times and returned the right answer. Nothing about the
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
    return [e for e in step_errors if _PARSE_FAILURE not in e.lower()]
