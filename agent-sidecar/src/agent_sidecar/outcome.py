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


def _is_direct_model(model: str) -> bool:
    """A combo name is a request for a ladder, not for one model.

    `paid-first` being answered by Opus is the ladder working, so a mismatch
    there means nothing. `agy/claude-sonnet-4-6` being answered by anything
    else means the request was overridden. The `provider/model` shape is what
    separates them.
    """
    return isinstance(model, str) and "/" in model


def _served_matches(model: str, served: str) -> bool:
    """The gateway drops the provider prefix in its reply.

    `agy/claude-sonnet-4-6` comes back as `claude-sonnet-4-6`, and
    `openrouter/deepseek/deepseek-v4-pro-0813` as `deepseek/deepseek-v4-pro-0813`,
    so the comparison is against everything after the first slash.
    """
    tail = model.split("/", 1)[1]
    return served == tail or served == model


def summarise(outcome: dict, *, runner: str, model: str) -> dict:
    """The canonical shape a caller gets back from an agent run.

    `degraded` folds in tool trouble as well as step errors. A tool that was
    configured and did not load leaves the agent answering from training data,
    sounding exactly like one that searched — invisible in `result`, and the
    reason this is not simply `bool(step_errors)`.
    """
    step_errors = list(outcome.get("step_errors") or [])
    tool_report = outcome.get("tools") or {}

    # Asking for one model and being served another is degradation, and until
    # this it was completely silent. The gateway switches routing strategy on
    # prompt content: a request naming `agy/claude-sonnet-4-6` comes back from
    # `big-pickle` whenever the prompt looks like an agent's, which is every
    # single run this service makes. That happens inside a vendored subtree
    # this repo must not edit, so it cannot be fixed here — but it can stop
    # being invisible.
    served = outcome.get("served_by")
    overridden = bool(
        served and _is_direct_model(model) and not _served_matches(model, served)
    )

    # An override off the local model is not the same kind of event as the
    # others. Naming `ollama/...` is how a caller says the work must not leave
    # this host, and the gateway will forward it to a third-party provider when
    # the prompt trips its content switch — measured, with no error and a
    # perfectly normal-looking answer.
    #
    # This one goes in step_errors, so `degraded` is true. The rest of the
    # overrides are a cost and quality question; this is a confidentiality one,
    # and it should not be filed under the flag someone might learn to ignore.
    #
    # It cannot prevent the egress — by the time a response exists the request
    # has already been served elsewhere. It can refuse to be quiet about it.
    if overridden and model.startswith("ollama/"):
        step_errors.append(
            f"local-only work left the host: asked for {model}, served by {served}"
        )
    tools_wanting = bool(
        tool_report.get("error")
        or tool_report.get("missing")
        or tool_report.get("misdirected")
    )
    return {
        "result": str(outcome.get("result")),
        "runner": runner,
        "model": model,
        # Which model was ASKED for, above; which one ANSWERED, here. They
        # differ whenever the request names a combo, and only the second says
        # whether the ladder fell through to the free tier. `null` when the
        # runner could not determine it.
        "served_by": outcome.get("served_by"),
        "steps": outcome.get("steps"),
        "step_errors": step_errors,
        # What the run cost. `null` means not measured, never "free".
        "tokens": outcome.get("tokens"),
        "tools": tool_report,
        # Its own field, deliberately NOT folded into `degraded`.
        #
        # It was folded in at first, which is defensible — being served a model
        # you did not ask for is something not working as configured. But the
        # gateway does it on essentially every agent run, so `degraded` went
        # true every time and stopped distinguishing anything. A flag that is
        # always on is worse than no flag: it trains the caller to ignore the
        # one signal that means the answer itself may be wrong.
        #
        # So `degraded` keeps its narrow meaning — a step failed, or a
        # configured tool did not load — and this carries the routing fact.
        # `served_by` says what actually answered.
        "model_overridden": overridden,
        "degraded": bool(step_errors) or tools_wanting,
    }


# Above this, the journal is trimmed to its most recent half. An append-only
# file on a 48 GB disk that was already at 73% is a slow leak, and the failure
# it produces is the worst kind — a full disk takes down every container on
# the host, not just the one that filled it. Entries are ~400 bytes, so this
# holds roughly 12,000 runs before anything is dropped.
_JOURNAL_MAX_BYTES = 5 * 1024 * 1024


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
        trim_if_oversized(path)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, separators=(",", ":"), default=str) + "\n")
    except Exception as exc:  # noqa: BLE001 - see docstring
        print(f"[run] journal write failed: {exc}", file=sys.stderr, flush=True)



def trim_if_oversized(path: str, max_bytes: int | None = None) -> None:
    """Keep the newest half when the journal passes its cap.

    Shared by the run journal and the vps_exec audit — both are append-only
    files on a disk that a full container takes the whole host down with, and
    duplicating the logic would mean fixing it twice.

    Halving rather than emptying: truncating at the cap would make the history
    vanish periodically and without warning, which is worse than a bounded
    window. A note is written into the file saying a trim happened, so a reader
    never mistakes a trimmed file for the whole story. The note is JSON, which
    the audit log is not — a line that does not parse is a louder signal there
    than a silently shorter file.

    One stat() per write; the rewrite only happens at the cap, which at ~400
    bytes an entry is roughly every 12,000 runs.
    """
    # Resolved at call time, not bound as a default: a default argument is
    # evaluated once when the function is defined, so the module constant
    # would be frozen at import and could never be overridden — which is
    # exactly how the first version of this passed locally and failed in CI.
    if max_bytes is None:
        max_bytes = _JOURNAL_MAX_BYTES

    try:
        if os.path.getsize(path) < max_bytes:
            return
    except OSError:
        return  # not there yet, or unreadable — the append will report it

    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    kept = lines[len(lines) // 2 :]
    note = json.dumps(
        {
            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "caller": "journal",
            "note": (
                f"trimmed at {max_bytes} bytes; "
                f"{len(lines) - len(kept)} older entries dropped"
            ),
        },
        separators=(",", ":"),
    )
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(note + chr(10))
        fh.writelines(kept)

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
            "served_by": summary.get("served_by"),
            "steps": summary.get("steps"),
            "tokens": summary.get("tokens"),
            "tools": (summary.get("tools") or {}).get("selected"),
            "step_errors": summary.get("step_errors") or [],
            "model_overridden": summary.get("model_overridden"),
            "degraded": summary.get("degraded"),
        }
    )
