#!/bin/sh
# Summarise the agent run journal written by agent-sidecar (/audit/runs.jsonl).
#
# Why this exists. The journal answers questions nothing else here can — what
# the agent cost, whether degraded runs are becoming more common, which of its
# seven tools actually get used — but it is JSON lines inside a Docker volume,
# which is data nobody reads. Collected-and-unreadable is half a feature.
#
# Usage:
#   ./scripts/agent-report.sh              # summarise everything
#   ./scripts/agent-report.sh 7            # only the last 7 days
#   JOURNAL=/path/to/runs.jsonl ./scripts/agent-report.sh   # a local file
#
# By default it reads the journal out of the running container, because that is
# where it lives. Set JOURNAL to read a copy instead.
set -eu

DAYS="${1:-0}"
CONTAINER="${AGENT_CONTAINER:-king-agent-sidecar-http-1}"
JOURNAL="${JOURNAL:-}"

# Validated BEFORE the pipeline, not inside it. An `exit 1` in the left-hand
# side of a pipe exits only that subshell; the pipeline still reports python3's
# status, so the script would print "no such journal" and then succeed. Caught
# by testing the missing-file case rather than assuming it.
if [ -n "$JOURNAL" ]; then
  [ -f "$JOURNAL" ] || { echo "no such journal: $JOURNAL" >&2; exit 1; }
elif ! docker exec "$CONTAINER" sh -c 'test -f /audit/runs.jsonl' 2>/dev/null; then
  echo "no journal yet in $CONTAINER (/audit/runs.jsonl)." >&2
  echo "It is written on the first POST /run after the journal shipped." >&2
  exit 1
fi

{
  if [ -n "$JOURNAL" ]; then
    cat "$JOURNAL"
  else
    # `docker exec cat` rather than a bind mount: the volume is named, and the
    # file is owned by uid 10001 inside the container.
    docker exec "$CONTAINER" cat /audit/runs.jsonl
  fi
} | python3 -c '
import collections, datetime, json, sys

days = int(sys.argv[1])
cutoff = None
if days > 0:
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)

runs, skipped = [], 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        # A truncated final line is normal if the file was read mid-write.
        # Counted rather than ignored, so a corrupt journal is visible.
        skipped += 1
        continue
    if cutoff is not None:
        try:
            when = datetime.datetime.fromisoformat(entry.get("at", ""))
        except ValueError:
            skipped += 1
            continue
        if when < cutoff:
            continue
    runs.append(entry)

if not runs:
    print("no runs in range.")
    if skipped:
        print(f"({skipped} unparseable line(s))")
    raise SystemExit(0)

total_in = sum((r.get("tokens") or {}).get("input") or 0 for r in runs)
total_out = sum((r.get("tokens") or {}).get("output") or 0 for r in runs)
unmeasured = sum(1 for r in runs if not r.get("tokens"))
degraded = [r for r in runs if r.get("degraded")]
seconds = [r.get("seconds") or 0 for r in runs]

span = "all time" if not days else f"last {days} day(s)"
print(f"agent runs — {span}")
print(f"  runs            {len(runs)}")
print(f"  degraded        {len(degraded)}  ({100.0 * len(degraded) / len(runs):.0f}%)")
print(f"  tokens in/out   {total_in:,} / {total_out:,}")
if unmeasured:
    # Not folded into the totals: null means "not measured", never "free".
    print(f"  unmeasured      {unmeasured} run(s) reported no token counts")
print(f"  seconds med/max {sorted(seconds)[len(seconds) // 2]:.1f} / {max(seconds):.1f}")

overridden = [r for r in runs if r.get("model_overridden")]
if overridden:
    # The gateway reroutes on prompt content and can land anywhere, so the
    # model a run asked for and the model that answered are different
    # questions. This counts how often they disagreed.
    # Built by concatenation, not an f-string: this whole program lives inside
    # a single-quoted shell string, so a single quote anywhere in it ends the
    # string and the next word becomes a bare name. That exact bug shipped
    # once.
    pairs = collections.Counter(
        str(r.get("model")) + " -> " + str(r.get("served_by")) for r in overridden
    )
    print(f"  model overridden {len(overridden)} of {len(runs)} run(s)")
    for pair, n in pairs.most_common(5):
        print(f"    {n:>4}  {pair}")

by_caller = collections.Counter(r.get("caller") or "?" for r in runs)
print("  by caller")
for name, n in by_caller.most_common():
    # "?" is a run journalled before the field existed, not an unknown client.
    print(f"    {n:>4}  {name}")

by_model = collections.Counter(r.get("model") or "?" for r in runs)
print("  by model")
for name, n in by_model.most_common():
    print(f"    {n:>4}  {name}")

tools = collections.Counter()
for r in runs:
    for t in r.get("tools") or []:
        tools[t] += 1
if tools:
    print("  tools offered to the agent (per run)")
    for name, n in tools.most_common():
        print(f"    {n:>4}  {name}")

if degraded:
    print("  most recent degraded runs")
    for r in degraded[-5:]:
        why = r.get("error") or "; ".join(r.get("step_errors") or []) or "tools missing"
        when = r.get("at", "?")
        print(f"    {when}  {why[:90]}")

if skipped:
    print(f"  ({skipped} unparseable line(s) skipped)")
' "$DAYS"
