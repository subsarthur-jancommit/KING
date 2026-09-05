"""One response shape for an agent run, and one journal, whatever called it.

This exists because there were two of each. `POST /run` built its answer in
server.py and `run_agent` built a different one in mcp_server.py, and they had
drifted: the MCP path — which is how Claude reaches the agent, so the primary
consumer — omitted token counts and the tool report, computed `degraded` from
step errors alone so a run whose tools failed to load could report clean, and
wrote nothing to the journal at all.

That last one made the journal quietly misleading rather than merely
incomplete: it recorded operator curl and Activepieces calls while the busiest
caller left no trace, so any question asked of it about cost or degradation was
answered from a biased sample.

Neither module imports the other's response logic now; both import this.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone


def summarise(outcome: dict, *, runner: str, model: str) -> dict:
    """The canonical shape a caller gets back from an agent run.

    `degraded` folds in tool trouble as well as step errors. A tool that was
    configured and did not load leaves the agent answering from training data,
    sounding exactly like one that searched — invisible in `result`, and the
    reason this is not simply `bool(step_errors)`.
    """
    step_errors = outcome.get("step_errors") or []
    tool_report = outcome.get("tools") or {}
    tools_wanting = bool(
        tool_report.get("error")
        or tool_report.get("missing")
        or tool_report.get("misdirected")
    )
    return {
        "result": str(outcome.get("result")),
        "runner": runner,
        "model": model,
        "steps": outcome.get("steps"),
        "step_errors": step_errors,
        # What the run cost. `null` means not measured, never "free".
        "tokens": outcome.get("tokens"),
        "tools": tool_report,
        "degraded": bool(step_errors) or tools_wanting,
    }


def journal(entry: dict) -> None:
    """Append one line per agent run, best-effort.

    Same contract as the vps_exec audit beside it: an unwritable path must not
    fail the run, and must not silently look like it logged either — the
    failure goes to stderr, which lands in the container log.
    """
    path = os.environ.get("AGENT_SIDECAR_RUN_JOURNAL", "/audit/runs.jsonl")
    try:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, separators=(",", ":"), default=str) + "\n")
    except Exception as exc:  # noqa: BLE001 - see docstring
        print(f"[run] journal write failed: {exc}", file=sys.stderr, flush=True)


def journal_run(summary: dict, *, task: str, seconds: float, caller: str) -> None:
    """Record a completed run, from the same summary the caller was given.

    Derived from the summary rather than assembled separately, so the journal
    cannot disagree with what the caller was told — which is exactly how the
    two response shapes drifted apart in the first place.
    """
    journal(
        {
            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "caller": caller,
            "runner": summary.get("runner"),
            "model": summary.get("model"),
            # Truncated, matching what the vps_exec audit does with commands:
            # enough to recognise a run, not a transcript.
            "task": task[:200],
            "seconds": round(seconds, 2),
            "steps": summary.get("steps"),
            "tokens": summary.get("tokens"),
            "tools": (summary.get("tools") or {}).get("selected"),
            "step_errors": summary.get("step_errors") or [],
            "degraded": summary.get("degraded"),
        }
    )
