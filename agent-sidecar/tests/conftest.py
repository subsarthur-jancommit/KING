"""Keep the suite from writing into a real deployment's audit files.

Running `pytest tests/` inside the deployed container on 2026-09-06 wrote **105
test entries** into the production run journal — 87 of the 137 lines it then
held. Tasks named `t` and `do the thing`, `RuntimeError: boom` in the degraded
list, and every figure `agent-report.sh` produced computed over them. The
journal is meant to answer what the agent costs and how often it degrades; two
thirds of it was fixtures.

Most journal tests already point `AGENT_SIDECAR_RUN_JOURNAL` at a `tmp_path`.
That is the problem in miniature: it protects the tests that remember to, and
every other test in the suite goes to the default `/audit/...` — which is a
real, mounted, shared volume in the container where the code actually runs.
Opt-in isolation only isolates the cases someone thought of.

So both paths are redirected for the whole session, before any test runs. A
test that wants to assert on the file still overrides the variable itself with
`monkeypatch.setenv`, which wins because function-scoped monkeypatch is applied
after this.

This is defence for running the suite *in the wrong place*, which is exactly
when it matters: in CI these paths do not exist and nothing is lost either way.
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True, scope="session")
def _never_write_to_a_real_audit_volume(tmp_path_factory):
    """Point every audit path at a throwaway directory for the whole session.

    `autouse` and session-scoped on purpose: a fixture that has to be requested
    is one that will be forgotten, and forgetting it is silent — the writes
    succeed, land in the deployment's volume, and are indistinguishable from
    real runs until somebody reads a report and sees `boom`.
    """
    import os

    scratch = tmp_path_factory.mktemp("audit")
    previous = {}
    for var, name in (
        ("AGENT_SIDECAR_RUN_JOURNAL", "runs.jsonl"),
        ("AGENT_SIDECAR_EXEC_AUDIT", "vps_exec.log"),
    ):
        previous[var] = os.environ.get(var)
        os.environ[var] = str(scratch / name)

    yield

    # Restored rather than left set: the process may go on to do something else,
    # and a test suite that permanently rewrites its parent's environment is its
    # own kind of surprise.
    for var, was in previous.items():
        if was is None:
            os.environ.pop(var, None)
        else:
            os.environ[var] = was
