#!/bin/sh
# Read the traces. 2,183 of them had been collected and nobody had ever looked.
#
# Why this exists. `E-9` proves the tracing pipeline is alive — spans leave the
# collector and arrive at Langfuse — and that is all it proves. Alive is not the
# same as useful: an archive nothing reads is a cost with no return, and this one
# had been accumulating since 2026-09-05.
#
# What the traces know that nothing else here does. The gateway's call log says
# which provider answered. The agent journal says what a run cost. Neither
# carries both halves of the question that actually matters:
#
#   name  = "chat ollama/qwen2.5:1.5b-instruct-q4_K_M"   <- what was ASKED FOR
#   model = "qwen2.5:1.5b-instruct-q4_K_M"               <- what SERVED it
#
# Both sides, on the same row. That is the exact fault that ran unnoticed from
# 2026-09-06 to 2026-09-12: `local-router.sh` asked for the local model and
# `antigravity/gemini-pro-agent` answered, while every check stayed green and
# the score it produced got *better*. This report is the instrument that would
# have said so on day one.
#
# Usage:
#   ./scripts/trace-report.sh             # the last 24 hours
#   ./scripts/trace-report.sh 168         # the last week
#   ./scripts/trace-report.sh --self-test # the predicates, no network
#
# Exit: 0 clean · 1 a threshold was breached · 2 the backend could not be read.
# 2 is never folded into 0. "No local work escaped" and "I could not find out"
# are different answers and this script refuses to print the reassuring one when
# it means the other.

set -eu

cd "$(dirname "$0")/.."

HOURS="${1:-24}"
case "$HOURS" in
  --self-test) HOURS="selftest" ;;
  ''|*[!0-9]*) echo "usage: $0 [hours] | $0 --self-test" >&2; exit 2 ;;
esac

# The share of observations allowed to carry a WARNING or ERROR level before
# this exits 1. Not zero: a single transient upstream error is noise, and a
# threshold that fires on noise gets muted, which is how a report stops being
# read. Local escapes have no such allowance — see the predicate.
MAX_ERROR_PCT="${TRACE_MAX_ERROR_PCT:-10}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ analysis
# One Python program, used by both the live path and --self-test, so the test
# exercises the code that runs rather than a second transcription of it. E-5
# stayed green for a week on a check whose test re-implemented its subject.
ANALYSIS=$(cat <<'PYTR'
import json, os, statistics, sys, collections


def requested(name):
    """The model asked for, out of a span name like 'chat ollama/qwen2.5:1.5b'.

    Returns (provider, model) and never raises: a name that does not match the
    shape yields ('', '') so it is skipped rather than counted as a mismatch.
    An unparsed name must not become a finding — that is a detector reporting
    its own blind spot as the subject's fault.
    """
    if not name:
        return ("", "")
    tail = name.split(" ", 1)[1] if " " in name else name
    if "/" not in tail:
        return ("", tail)
    prov, _, mdl = tail.partition("/")
    return (prov, mdl)


def escaped(name, served):
    """True when work asked of the LOCAL provider was served by something else.

    This is the only mismatch treated as a fault. The gateway is allowed to
    reroute within a model family and does so by design, so a general
    served != requested alarm would fire on correct behaviour and be muted
    within a week. Local is different: the whole value of the local rung is
    that it is free and stays on this host, and BOTH of those die the moment
    anything else answers. That asymmetry is the rule, not a convenience.
    """
    prov, mdl = requested(name)
    if prov not in ("ollama", "ollama-local"):
        return False
    if not served or not mdl:
        return False
    return served != mdl


def verdict(rows_read, total_items, escapes, err_pct, max_err_pct):
    """What the run means, separated from the printing so it can be tested.

    Order encodes the rule this file exists for: ignorance is not a clean bill.
    Nothing read is 'unknown', never 'ok', however reassuring the zero looks.
    """
    if rows_read == 0 and total_items > 0:
        return "unknown"
    if total_items == 0:
        return "empty"
    if escapes > 0:
        return "escape"
    if err_pct > max_err_pct:
        return "errors"
    return "ok"


def analyse(rows):
    lat = collections.defaultdict(list)
    served_by = collections.Counter()
    asked_for = collections.Counter()
    levels = collections.Counter()
    escapes = []
    for r in rows:
        name = r.get("name") or ""
        served = r.get("model") or ""
        lvl = (r.get("level") or "DEFAULT").upper()
        levels[lvl] += 1
        if served:
            served_by[served] += 1
            if r.get("latency") is not None:
                try:
                    lat[served].append(float(r["latency"]))
                except (TypeError, ValueError):
                    pass
        prov, mdl = requested(name)
        if prov:
            asked_for["%s/%s" % (prov, mdl)] += 1
        if escaped(name, served):
            escapes.append((name, served))
    return lat, served_by, asked_for, levels, escapes


def pct(part, whole):
    return (100.0 * part / whole) if whole else 0.0


if __name__ == "__main__":
    if os.environ.get("TRACE_SELFTEST") == "1":
        bad = 0

        def check(label, got, want):
            global bad
            if got != want:
                bad += 1
                print("  FAIL %s: got %r, want %r" % (label, got, want))
            else:
                print("  ok    %s" % label)

        check("a prefixed span name splits into provider and model",
              requested("chat ollama/qwen2.5:1.5b-instruct-q4_K_M"),
              ("ollama", "qwen2.5:1.5b-instruct-q4_K_M"))
        check("a name with no provider prefix yields no provider",
              requested("chat big-pickle"), ("", "big-pickle"))
        check("an empty name is not parsed into anything",
              requested(""), ("", ""))
        # A model name may itself contain a slash; only the provider is split.
        check("only the provider is split off, not every segment",
              requested("chat ollama/hf.co/u/m"), ("ollama", "hf.co/u/m"))

        # THE CANARY. Every other fixture here confirms that nothing is
        # reported, and a predicate hardwired to return False would pass all of
        # them. This is the one that has to fail if the detector is dead, and it
        # is the exact shape of the six-day fault: ollama asked, antigravity
        # served.
        check("local work served by another provider IS an escape",
              escaped("chat ollama/qwen2.5:1.5b-instruct-q4_K_M",
                      "gemini-pro-agent"), True)
        check("local work served by the local model is not an escape",
              escaped("chat ollama/qwen2.5:1.5b-instruct-q4_K_M",
                      "qwen2.5:1.5b-instruct-q4_K_M"), False)
        check("ollama-local counts as local too",
              escaped("chat ollama-local/x", "y"), True)
        # A paid provider answering with a different model name is the family
        # fallback working. Flagging it would make the report fire on correct
        # behaviour, and a report that cries wolf is a report nobody opens.
        check("a non-local provider serving a different name is not an escape",
              escaped("chat antigravity/claude-sonnet-4-6", "claude-sonnet-4-5"),
              False)
        check("an unparseable name is skipped, not counted as an escape",
              escaped("", "anything"), False)

        check("nothing read while the backend reports rows is unknown, not ok",
              verdict(0, 247, 0, 0.0, 10), "unknown")
        check("a genuinely empty window is empty, not ok",
              verdict(0, 0, 0, 0.0, 10), "empty")
        check("one escape outranks a clean error rate",
              verdict(100, 100, 1, 0.0, 10), "escape")
        check("an error rate above the ceiling is a finding",
              verdict(100, 100, 0, 11.0, 10), "errors")
        check("an error rate at the ceiling is not a finding",
              verdict(100, 100, 0, 10.0, 10), "ok")
        check("a clean window is ok", verdict(100, 100, 0, 0.0, 10), "ok")

        if bad:
            print("%d fixture(s) failed." % bad)
            sys.exit(1)
        print("trace-report predicates pass, including the escape canary.")
        sys.exit(0)

    payload = json.load(sys.stdin)
    rows = payload["rows"]
    total_items = payload["totalItems"]
    hours = payload["hours"]
    max_err = float(payload["maxErrorPct"])

    lat, served_by, asked_for, levels, escapes = analyse(rows)
    errs = levels.get("ERROR", 0) + levels.get("WARNING", 0)
    err_pct = pct(errs, len(rows))
    v = verdict(len(rows), total_items, len(escapes), err_pct, max_err)

    print("model routing and latency — last %s hours" % hours)
    print()
    print("  observations: %d read of %d the backend reports" % (len(rows), total_items))
    if len(rows) < total_items:
        print("  NOTE: paging stopped early; every figure below covers the %d read." % len(rows))
    print()

    if not rows:
        if v == "empty":
            print("  No generations recorded in this window.")
            print("  That is a real answer, not a silent report: the backend was")
            print("  reached and asked, and it holds nothing for these hours.")
        sys.exit(0 if v == "empty" else 2)

    print("  latency by the model that ACTUALLY served, seconds")
    print("    %-36s %5s %8s %8s %8s" % ("model", "n", "p50", "p95", "max"))
    for m, vals in sorted(lat.items(), key=lambda kv: -len(kv[1])):
        s = sorted(vals)
        p95 = s[max(0, int(len(s) * 0.95) - 1)]
        print("    %-36s %5d %8.2f %8.2f %8.2f"
              % (m[:36], len(s), statistics.median(s), p95, max(s)))
    print()

    print("  what was asked for")
    for k, n in asked_for.most_common(10):
        print("    %-44s %5d" % (k[:44], n))
    print()

    print("  levels: %s" % (", ".join("%s=%d" % (k, n) for k, n in levels.most_common()) or "none"))
    print("  warning+error share: %.1f%%  (ceiling %.0f%%)" % (err_pct, max_err))
    print()

    # The headline finding, printed whichever way it goes. A detector that only
    # speaks when it finds something is indistinguishable from a dead one.
    if escapes:
        print("  LOCAL WORK LEFT THE HOST — %d observation(s)" % len(escapes))
        for name, served in escapes[:10]:
            print("    asked %-40s served %s" % (name[:40], served))
        print()
        print("  Both premises of the local rung are gone for these calls: they")
        print("  were not free, and the prompt left this machine. See")
        print("  docs/king-system.md 4, 'the local router is not local'.")
    else:
        print("  local work that left the host: 0")
        print("  (the detector is exercised by --self-test against the exact")
        print("   shape of the 2026-09-06 fault, so this zero is a measurement)")
    print()

    sys.exit(0 if v in ("ok", "empty") else 1)
PYTR
)

if [ "$HOURS" = "selftest" ]; then
  if ! python3 -c "" >/dev/null 2>&1; then
    red "python3 is required, and the python3 on PATH here does not run."
    exit 2
  fi
  TRACE_SELFTEST=1 python3 -c "$ANALYSIS"
  exit $?
fi

# ------------------------------------------------------- credential and window
# From the RUNNING container, not from .env, and the reason is written down in
# king-mistakes: `. ./.env` parses `LANGFUSE_OTLP_AUTH=Basic <base64>` and stops
# at the space, yielding the 5-character string "Basic". That produced a 401 that
# read exactly like a dead pipeline, and very nearly got reported as one. The
# container holds the value the collector is actually using.
if ! python3 -c "" >/dev/null 2>&1; then
  red "python3 is required, and the python3 on PATH here does not run."
  exit 2
fi
command -v docker >/dev/null 2>&1 || { red "docker is required to read the collector's environment."; exit 2; }

OTEL=$(docker compose --profile tracing ps -q otel-collector 2>/dev/null || true)
if [ -z "$OTEL" ]; then
  red "No otel-collector is running here, so there is no credential to read"
  red "and no way to ask the backend. Start the tracing profile, or run this"
  red "on the host that collects."
  exit 2
fi

CENV=$(docker inspect "$OTEL" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)
AUTH=$(printf '%s\n' "$CENV" | sed -n 's/^LANGFUSE_OTLP_AUTH=//p' | head -1)
BASE=$(printf '%s\n' "$CENV" | sed -n 's/^LANGFUSE_OTLP_ENDPOINT=//p' | head -1)
BASE=$(printf '%s' "${BASE:-https://cloud.langfuse.com/api/public/otel}" | sed 's#/api/public/otel$##')
if [ -z "$AUTH" ]; then
  red "The collector carries no LANGFUSE_OTLP_AUTH, so the backend cannot be asked."
  exit 2
fi

FROM=$(date -u -d "$HOURS hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
if [ -z "$FROM" ]; then
  red "GNU date is required to build the window."
  exit 2
fi

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Page until the backend's own totalPages is covered, capped so a runaway
# pagination bug cannot turn a report into a denial of service against it.
PAGE=1
MAXPAGE=20
while [ "$PAGE" -le "$MAXPAGE" ]; do
  if ! curl -s -m 90 -H "Authorization: $AUTH" \
       "$BASE/api/public/observations?limit=100&page=$PAGE&fromStartTime=$FROM&type=GENERATION" \
       > "$WORK/p$PAGE.json" 2>/dev/null; then
    red "The backend did not answer for page $PAGE."
    exit 2
  fi
  TOTALPAGES=$(WORKF="$WORK/p$PAGE.json" python3 -c 'import json,os
try:
    d=json.load(open(os.environ["WORKF"]))
    print(int((d.get("meta") or {}).get("totalPages") or 0))
except Exception:
    print(-1)')
  if [ "$TOTALPAGES" = "-1" ]; then
    red "The backend answered with something that is not a page of observations."
    red "A refusal and an empty window look identical once parsed, so this stops."
    exit 2
  fi
  [ "$PAGE" -ge "$TOTALPAGES" ] && break
  PAGE=$((PAGE + 1))
done

WORK="$WORK" HOURS="$HOURS" MAXERR="$MAX_ERROR_PCT" python3 -c 'import json,os,sys
rows=[]; total=0
d=os.environ["WORK"]
for f in sorted(os.listdir(d)):
    if not f.endswith(".json"): continue
    try: p=json.load(open(os.path.join(d,f)))
    except Exception: continue
    rows += p.get("data") or []
    total = max(total, int((p.get("meta") or {}).get("totalItems") or 0))
json.dump({"rows":rows,"totalItems":total,"hours":os.environ["HOURS"],
           "maxErrorPct":os.environ["MAXERR"]}, sys.stdout)' > "$WORK/payload.json"

python3 -c "$ANALYSIS" < "$WORK/payload.json"
