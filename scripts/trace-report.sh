#!/bin/sh
# Read the traces. 2,183 of them had been collected and nobody had ever looked.
#
# Why this exists. `E-9` proves the tracing pipeline is alive — spans leave the
# collector and arrive at Langfuse — and that is all it proves. Alive is not the
# same as useful: an archive nothing reads is a cost with no return, and this one
# had been accumulating since 2026-09-05.
#
# WHAT THIS CANNOT DO, first, because the first version claimed it could.
#
# It was written to detect the 2026-09-06 fault — a caller asking for the local
# model and a paid provider answering — by comparing the span name against the
# served model. Fifteen fixtures passed, including a canary, and a real payload
# with one doctored row went red. Then a genuine reroute happened, F-4 caught it
# out of the agent journal, and this report said `local work that left the
# host: 0`.
#
# The premise was wrong. The span is written AFTER the gateway has decided, so
# both fields describe the destination and neither describes the request.
# Measured over 487 generations in 24 hours:
#
#   direct    ollama         qwen2.5:1.5b                    281
#   auto      antigravity    claude-sonnet-4-6               149
#   auto      opencode       big-pickle                       31
#   auto      antigravity    gemini-3.1-pro-low               12
#   priority  opencode-zen   big-pickle                        5
#   priority  antigravity    claude-opus-4-6-thinking-high     5
#   direct    opencode-zen   big-pickle                        4
#
# Three values, not two. `priority` is a combo ladder — the caller naming a
# ROUTE rather than a model — and it only appeared when the window widened from
# 300 rows to 487. Fixtures written from the first sample would have been
# invented again, one sample later.
#
# `gen_ai.request.model` carries the post-reroute name too. A rerouted call
# arrives here as a perfectly consistent `chat antigravity/claude-sonnet-4-6`
# -> `claude-sonnet-4-6`, so name-vs-model CANNOT disagree for the one case the
# check existed to catch. The fixtures passed because I had invented a row shape
# the gateway never emits. A canary proves a predicate can fire; it proves
# nothing about whether the world can produce the input that fires it.
#
# **The reroute detector is `F-4`**, against `/audit/runs.jsonl`, where the
# sidecar records the model it ASKED for beside the one that served — the two
# facts the trace cannot hold at once. That check already existed and already
# works; this file is not a second opinion on it.
#
# WHAT THE TRACES DO KNOW, which nothing else here reports:
#
#   latency by the model that actually served, p50/p95/max — the call log has
#   no timings and the agent journal covers only agent runs
#
#   `gen_ai.system`, which separates a call the gateway served as addressed
#   (`direct`) from one its auto-router chose (`auto`). Every `auto` row is
#   spend the caller did not name, and the local rung is honoured only by
#   `direct` + `ollama`. That is the trace-visible shadow of rerouting: not
#   which call was diverted, but how much of the traffic the router is deciding
#
# Usage:
#   ./scripts/trace-report.sh             # the last 24 hours
#   ./scripts/trace-report.sh 168         # the last week
#   ./scripts/trace-report.sh --self-test # the predicates, no network
#
# Exit: 0 clean · 1 a threshold was breached · 2 the backend could not be read.
# 2 is never folded into 0. "Nothing was wrong" and "I could not find out" are
# different answers, and this refuses to print the reassuring one when it means
# the other.

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
# read.
MAX_ERROR_PCT="${TRACE_MAX_ERROR_PCT:-10}"

# The share of CLASSIFIED generations the gateway's own router may choose before
# this exits 1. The ceiling is high on purpose: routing is what a gateway is
# for, and combo requests like `paid-first` are SUPPOSED to arrive as `auto`.
# What it catches is the shape of a real regression — a day where nearly nothing
# is served as addressed. Measured 2026-09-12 the figure was 35%.
MAX_AUTO_PCT="${TRACE_MAX_AUTO_PCT:-90}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ analysis
# One Python program, used by both the live path and --self-test, so the test
# exercises the code that runs rather than a second transcription of it. E-5
# stayed green for a week on a check whose test re-implemented its subject.
ANALYSIS=$(cat <<'PYTR'
import json, os, statistics, sys, collections


def routing(row):
    """(system, provider) for one observation, from the OTel attributes.

    `system` is 'direct' when the gateway served the model it was addressed by,
    and 'auto' when its own router chose the destination. That distinction is
    the only trace-visible trace of rerouting — see the header for why the
    span's model fields cannot carry it.

    Never raises. A row whose attributes are missing or oddly shaped yields
    ('', ''), so it is counted as unclassified rather than silently sorted into
    whichever bucket happens to be reassuring.
    """
    md = row.get("metadata") or {}
    at = md.get("attributes") if isinstance(md, dict) else None
    if not isinstance(at, dict):
        return ("", "")
    return (str(at.get("gen_ai.system") or ""),
            str(at.get("gen_ai.provider.name") or ""))


def stayed_local(system, provider):
    """True when this call was served, as addressed, by the on-host model.

    BOTH halves are required and that is the point. `direct` alone says the
    gateway did not re-route, and `ollama` alone would count a router-chosen
    local call as though the caller had asked for it. Only the pair means the
    work was asked of the local rung and stayed there.
    """
    return system == "direct" and provider.split("-")[0] == "ollama"


def verdict(rows_read, total_items, auto_pct, max_auto_pct, err_pct, max_err_pct):
    """What the run means, separated from the printing so it can be tested.

    The order encodes the rule this file exists for: ignorance is not a clean
    bill. Nothing read is 'unknown', never 'ok', however reassuring the zero
    looks.
    """
    if rows_read == 0 and total_items > 0:
        return "unknown"
    if total_items == 0:
        return "empty"
    if err_pct > max_err_pct:
        return "errors"
    if auto_pct > max_auto_pct:
        return "auto"
    return "ok"


def analyse(rows):
    lat = collections.defaultdict(list)
    served_by = collections.Counter()
    routes = collections.Counter()
    levels = collections.Counter()
    local = 0
    auto = 0
    classified = 0
    for r in rows:
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
        system, provider = routing(r)
        if system:
            classified += 1
            routes[(system, provider, served)] += 1
            if system == "auto":
                auto += 1
            if stayed_local(system, provider):
                local += 1
    return lat, served_by, routes, levels, local, auto, classified


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

        def row(system, provider, **kw):
            r = {"metadata": {"attributes": {}}}
            if system is not None:
                r["metadata"]["attributes"]["gen_ai.system"] = system
            if provider is not None:
                r["metadata"]["attributes"]["gen_ai.provider.name"] = provider
            r.update(kw)
            return r

        check("a well-formed row yields its system and provider",
              routing(row("direct", "ollama")), ("direct", "ollama"))
        check("a row with no attributes yields nothing, not a guess",
              routing({}), ("", ""))
        check("attributes of the wrong shape yield nothing",
              routing({"metadata": {"attributes": "not-a-dict"}}), ("", ""))

        # These four are the real distribution, measured over 300 generations
        # on 2026-09-12. Fixtures invented rather than observed are what let the
        # PREVIOUS version of this file pass fifteen tests while being unable to
        # detect the thing it existed for.
        check("direct+ollama is local work that stayed",
              stayed_local("direct", "ollama"), True)
        check("direct+ollama-local is the same provider, prefixed",
              stayed_local("direct", "ollama-local"), True)
        check("auto+antigravity is not local",
              stayed_local("auto", "antigravity"), False)
        check("auto+opencode is not local",
              stayed_local("auto", "opencode"), False)
        check("direct+opencode-zen is direct but not local",
              stayed_local("direct", "opencode-zen"), False)
        # `priority` is the third value the gateway emits, found only when the
        # window widened to 487 rows — a combo ladder like `paid-first`, which
        # IS the caller naming a route. Neither local nor router-chosen.
        check("priority is not local work that stayed",
              stayed_local("priority", "opencode-zen"), False)
        check("priority is not counted as router-chosen either",
              routing(row("priority", "antigravity")), ("priority", "antigravity"))
        # The pair is required in BOTH directions. A router-chosen call that
        # happened to land on ollama was not asked of the local rung, and
        # counting it as local would flatter exactly the number that matters.
        check("auto+ollama is NOT counted as local work that stayed",
              stayed_local("auto", "ollama"), False)
        check("a provider merely starting with the letters is not ollama",
              stayed_local("direct", "ollamafake"), False)

        check("nothing read while the backend reports rows is unknown, not ok",
              verdict(0, 300, 0.0, 90, 0.0, 10), "unknown")
        check("a genuinely empty window is empty, not ok",
              verdict(0, 0, 0.0, 90, 0.0, 10), "empty")
        check("an error rate above the ceiling outranks the routing share",
              verdict(100, 100, 99.0, 90, 11.0, 10), "errors")
        check("an auto share above the ceiling is a finding",
              verdict(100, 100, 95.0, 90, 0.0, 10), "auto")
        check("an auto share at the ceiling is not a finding",
              verdict(100, 100, 90.0, 90, 0.0, 10), "ok")
        check("a clean window is ok", verdict(100, 100, 35.0, 90, 0.0, 10), "ok")

        # analyse() end to end on the measured distribution, so the counting
        # is pinned and not only the predicates it calls.
        rows = ([row("direct", "ollama", model="qwen2.5:1.5b", latency=1.8)] * 192
                + [row("auto", "antigravity", model="claude-sonnet-4-6", latency=3.0)] * 86
                + [row("auto", "opencode", model="big-pickle", latency=2.2)] * 20
                + [row("direct", "opencode-zen", model="big-pickle", latency=2.0)] * 2)
        lat, served, routes, levels, local, auto, classified = analyse(rows)
        check("every row is classified", classified, 300)
        check("local work counted", local, 192)
        check("router-chosen work counted", auto, 106)
        check("latency kept per SERVING model", sorted(lat), 
              ["big-pickle", "claude-sonnet-4-6", "qwen2.5:1.5b"])
        check("an unclassifiable row is counted nowhere rather than somewhere",
              analyse([{}])[6], 0)

        if bad:
            print("%d fixture(s) failed." % bad)
            sys.exit(1)
        print("trace-report predicates pass, on the distribution the gateway "
              "actually emits.")
        sys.exit(0)

    payload = json.load(sys.stdin)
    rows = payload["rows"]
    total_items = payload["totalItems"]
    hours = payload["hours"]
    max_err = float(payload["maxErrorPct"])
    max_auto = float(payload["maxAutoPct"])

    lat, served_by, routes, levels, local, auto, classified = analyse(rows)
    errs = levels.get("ERROR", 0) + levels.get("WARNING", 0)
    err_pct = pct(errs, len(rows))
    auto_pct = pct(auto, classified)
    v = verdict(len(rows), total_items, auto_pct, max_auto, err_pct, max_err)

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

    print("  who decided, and what answered")
    print("    %-8s %-16s %-30s %5s" % ("decided", "provider", "model", "n"))
    for (system, provider, served), n in sorted(routes.items(), key=lambda kv: -kv[1]):
        print("    %-8s %-16s %-30s %5d" % (system[:8], provider[:16], served[:30], n))
    if classified < len(rows):
        print("    (%d row(s) carried no gen_ai.system and are counted nowhere)"
              % (len(rows) - classified))
    print()

    print("  levels: %s" % (", ".join("%s=%d" % (k, n) for k, n in levels.most_common()) or "none"))
    print("  warning+error share: %.1f%%  (ceiling %.0f%%)" % (err_pct, max_err))
    print()

    # Printed whichever way it goes. A number that only appears when it is bad
    # is indistinguishable from a number nobody computes.
    print("  served as addressed by the on-host model: %d of %d classified (%.1f%%)"
          % (local, classified, pct(local, classified)))
    print("  chosen by the gateway's own router:       %d of %d classified (%.1f%%)  (ceiling %.0f%%)"
          % (auto, classified, auto_pct, max_auto))
    print()
    print("  Every `auto` row is spend the caller did not name. It is NOT a list")
    print("  of diverted calls — the span is written after the gateway decides,")
    print("  so it cannot say what was asked for. F-4 answers that, from the")
    print("  agent journal, which records both. See the header.")
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

WORK="$WORK" HOURS="$HOURS" MAXERR="$MAX_ERROR_PCT" MAXAUTO="$MAX_AUTO_PCT" python3 -c 'import json,os,sys
rows=[]; total=0
d=os.environ["WORK"]
for f in sorted(os.listdir(d)):
    if not f.endswith(".json"): continue
    try: p=json.load(open(os.path.join(d,f)))
    except Exception: continue
    rows += p.get("data") or []
    total = max(total, int((p.get("meta") or {}).get("totalItems") or 0))
json.dump({"rows":rows,"totalItems":total,"hours":os.environ["HOURS"],
           "maxErrorPct":os.environ["MAXERR"],
           "maxAutoPct":os.environ["MAXAUTO"]}, sys.stdout)' > "$WORK/payload.json"

python3 -c "$ANALYSIS" < "$WORK/payload.json"
