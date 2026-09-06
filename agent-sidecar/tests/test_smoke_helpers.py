"""The smoke test's step-error classifier, tested where it always runs.

`test_smoke.py` is skipped without a reachable OmniRoute, so nothing there is
exercised by the `agent-sidecar-unit` job. The classifier encodes a judgement
that is easy to "simplify" into a bug later — forgive parse errors, never
forgive name errors — so it is pinned here instead.
"""

from __future__ import annotations

from smoke_helpers import path_errors


def test_a_clean_run_has_nothing_to_report():
    assert path_errors([]) == []


def test_a_code_parsing_failure_is_forgiven():
    """Verbatim from CI run 34004521273.

    `opencode/big-pickle` emitted a valid `final_answer(...)` and then a stray
    `</`. The agent recovered and answered correctly on step 4. Nothing about
    the path under test was wrong.
    """
    errors = [
        "step 1: Code parsing failed on line 2 due to: SyntaxError: "
        "invalid syntax (<unknown>, line 2)\n</\n ^"
    ]
    assert path_errors(errors) == []


def test_a_name_error_is_never_forgiven():
    """This is what a missing tool looks like from inside the sandbox.

    The agent calls a tool that was never registered and Python reports it is
    not defined. Forgiving this would blind the smoke test to exactly the
    silent degradation it exists to catch — an agent answering from training
    data because its search tool never loaded.
    """
    errors = ["step 1: NameError: name 'omniroute_web_search' is not defined"]
    assert path_errors(errors) == errors


def test_a_gateway_error_is_never_forgiven():
    errors = ["step 2: APIStatusError: 502 Provider returned empty content"]
    assert path_errors(errors) == errors


def test_the_egress_error_is_never_forgiven():
    """The one step error that is a confidentiality event, not a quality one."""
    errors = [
        "local-only work left the host: asked for "
        "ollama/qwen2.5:1.5b-instruct-q4_K_M, served by gemini-3.7-flash-high"
    ]
    assert path_errors(errors) == errors


def test_a_mixed_run_keeps_only_the_fatal_ones():
    """The case that matters: a recovered parse error must not hide a real one."""
    parse = "step 1: Code parsing failed on line 2 due to: SyntaxError: invalid syntax"
    fatal = "step 2: NameError: name 'get_neighbors' is not defined"

    assert path_errors([parse, fatal]) == [fatal]
    # Order must not matter — a parse error arriving second is just as harmless.
    assert path_errors([fatal, parse]) == [fatal]


def test_the_match_is_on_the_message_not_the_step_number():
    """Step numbers vary run to run; the classification must not depend on them."""
    assert path_errors(["step 7: Code parsing failed on line 1"]) == []
    assert path_errors(["step 11: Code parsing failed on line 1"]) == []
