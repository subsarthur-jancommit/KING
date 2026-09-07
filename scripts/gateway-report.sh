#!/bin/sh
# Who called the gateway, what they asked for, and what actually answered.
#
# This closes the visibility half of a gap the roadmap has carried for a while:
# the agent reports `served_by` and `model_overridden` on every run, and the
# Activepieces flows report nothing — the AI piece hands back text, not a model
# name, so a flow served by the free tier looks exactly like one served by Opus.
#
# The fix does NOT require changing the flows. The gateway already records the
# answer: every row in `call_logs` carries `apiKeyName`, `requestedModel`, and
# the `provider`/`model` that actually served it. Rewriting working flows to use
# HTTP steps so they could observe themselves would risk the thing being
# measured in order to measure it; reading what the gateway already writes does
# not.
#
# Per API key it reports calls, failures, tokens, and how each call was routed:
# rerouted by the gateway, through a ladder the caller chose, or left alone.
# So "which tier is this flow really getting" is one command rather than an
# inference — with one honest limit, documented at `routing_class` below: this
# log cannot say which model the caller originally named.
#
# Usage:
#   ./scripts/gateway-report.sh          # the last 24 hours
#   ./scripts/gateway-report.sh 168      # the last week
set -eu

HOURS="${1:-24}"
case "$HOURS" in
  ''|*[!0-9]*) echo "usage: $0 [hours]   (a whole number, default 24)" >&2; exit 2 ;;
esac

BASE="${OMNIROUTE_BASE_URL:-http://localhost:20128}"
LIMIT="${CALL_LOG_LIMIT:-500}"

cd "$(dirname "$0")/.."

# The manage-scoped key, read-only use. Never printed and never placed on a
# command line, matching every other script here.
key=$(sed -n 's/^OMNIROUTE_MCP_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -1)
[ -n "$key" ] || key=$(sed -n 's/^OMNIROUTE_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -1)
[ -n "$key" ] || { echo "No OmniRoute key in agent-sidecar/.env" >&2; exit 1; }

body=$(curl -s -m 120 "$BASE/api/usage/call-logs?limit=$LIMIT&excludeTests=1" \
  -H "Authorization: Bearer $key") || {
    echo "Could not read call logs from $BASE" >&2; exit 1; }

# The analysis goes to a temp file rather than a heredoc on python3's stdin:
# a heredoc IS stdin, so `printf ... | python3 - <<PY` silently feeds python the
# script and throws the call logs away. That is exactly how the first run of
# this script failed, with a JSON parse error on an empty document.
script=$(mktemp)
trap 'rm -f "$script"' EXIT INT TERM
cat > "$script" <<'PY'
import collections, datetime, json, sys

hours = int(sys.argv[1])
limit = int(sys.argv[2])

try:
    payload = json.load(sys.stdin)
except Exception as exc:
    print("Could not parse the call-log response: %s" % exc)
    raise SystemExit(1)

rows = payload if isinstance(payload, list) else (
    payload.get("logs") or payload.get("data") or payload.get("items") or [])

# Rows still in flight are spliced in from memory and carry status 0; counting
# them scores every in-progress request as a failure. The monitor makes the
# same exclusion, for the same reason.
rows = [r for r in rows if r and r.get("active") is not True]


def parsed(ts):
    try:
        return datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
    except Exception:
        return None


cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)
win = [r for r in rows if (parsed(r.get("timestamp")) or cutoff) >= cutoff]

print("gateway calls — last %d hour(s)" % hours)
if not win:
    print()
    print("  Nothing in this window.")
    if len(rows) >= limit:
        print("  The API returned its full page of %d rows, so older calls were" % limit)
        print("  truncated before the window was applied — raise CALL_LOG_LIMIT.")
    raise SystemExit(0)

oldest = min(p for p in (parsed(r.get("timestamp")) for r in win) if p)
print("  %d call(s), oldest %s" % (len(win), oldest.strftime("%m-%d %H:%M")))
if len(rows) >= limit:
    print("  NOTE: the API returned its full page of %d rows. Older calls in this" % limit)
    print("  window may be missing; raise CALL_LOG_LIMIT to widen it.")
print()


def failed(r):
    return (isinstance(r.get("status"), int) and r["status"] >= 400) or bool(r.get("error"))


def served(r):
    prov, model = r.get("provider"), r.get("model")
    return "%s/%s" % (prov or "?", model or "?")


# `requestedModel` is NOT what the caller asked for.
#
# Measured 2026-09-06: on every row in this log it equals the served model
# exactly, including the ones the sidecar independently reports as overridden.
# The gateway writes it after routing has already chosen, so comparing it to
# `model` can only ever produce "no overrides" — an instrument reading zero
# because it is wired to the wrong side of the thing it measures. The first
# version of this script did exactly that and disagreed with the sidecar, which
# is how it was noticed.
#
# What DOES survive is `comboName`, the ladder a call went through:
#
#   auto/*        assigned by the gateway's own content router. No caller here
#                 selects auto/* any more — that was retired — so its presence
#                 is the reroute in section 4, recorded by the gateway itself.
#   a named combo the caller asked for a ladder: paid-first, websearch-tiers.
#                 Whichever tier answered is that ladder working.
#   none          a direct model request that routing left alone.
def routing_class(r):
    combo = r.get("comboName") or ""
    if combo.startswith("auto/"):
        return "rerouted"
    if combo:
        return "ladder"
    return "direct"


by_key = collections.defaultdict(lambda: {"n": 0, "fail": 0,
                                          "cls": collections.Counter(),
                                          "pairs": collections.Counter(),
                                          "tin": 0, "tout": 0})
for r in win:
    k = r.get("apiKeyName") or r.get("apiKeyId") or "(no key)"
    b = by_key[k]
    b["n"] += 1
    if failed(r):
        b["fail"] += 1
    b["cls"][routing_class(r)] += 1
    b["pairs"][(r.get("comboName") or "(direct)", served(r))] += 1
    tok = r.get("tokens") or {}
    b["tin"] += tok.get("in") or 0
    b["tout"] += tok.get("out") or 0

for name, b in sorted(by_key.items(), key=lambda kv: -kv[1]["n"]):
    c = b["cls"]
    print("  %s" % name)
    print("    %d call(s), %d failed, tokens in/out %s / %s"
          % (b["n"], b["fail"], format(b["tin"], ","), format(b["tout"], ",")))
    print("    routing: %d rerouted by the gateway, %d through a ladder the caller "
          "chose, %d direct" % (c["rerouted"], c["ladder"], c["direct"]))
    if c["rerouted"]:
        print("             the rerouted ones did not get the model they asked for;")
        print("             this log cannot say which model that was (see above).")
    for (combo, got), n in b["pairs"].most_common(6):
        print("      %4d  %-30s -> %s" % (n, combo[:30], got))
    print()

# Per-provider reliability.
#
# The section above groups by API key, which answers "what is this caller
# getting". It cannot answer "which provider is unreliable", because one key
# spreads its calls across every provider the router picks. That question is
# the one the alerts raise: `gateway_monitor` reports a single blended error
# ratio, and the first thing anyone asks on reading one is which provider it
# came from. Working that out used to mean pulling the raw call log and
# grouping it by hand.
#
# The same attempts-not-outcomes caveat applies here as in the alerts: a row is
# one provider attempt, so a provider the gateway recovered from via its family
# fallback still counts a failure here while the caller saw a normal answer.
# High is worth investigating, not worth panicking about — and the section
# immediately below turns that caveat into an actual number instead of leaving
# it as a warning.
prov = collections.defaultdict(lambda: {"n": 0, "fail": 0, "sig": collections.Counter()})
for r in win:
    b = prov[r.get("provider") or "(none)"]
    b["n"] += 1
    if failed(r):
        b["fail"] += 1
        b["sig"][(r.get("status"), str(r.get("error") or "").strip()[:44])] += 1

hurt = [(k, b) for k, b in prov.items() if b["fail"]]
if hurt:
    print("  provider reliability (attempts, not outcomes)")
    print("    %-14s %6s %7s %6s   %s" % ("provider", "calls", "failed", "rate", "commonest failure"))
    for k, b in sorted(hurt, key=lambda kv: (-kv[1]["fail"], -kv[1]["n"])):
        (st, msg), _ = b["sig"].most_common(1)[0]
        print("    %-14s %6d %7d %5.0f%%   %s %s"
              % (k[:14], b["n"], b["fail"], 100.0 * b["fail"] / b["n"],
                 st if st is not None else "---", msg or "(no message)"))
    clean = sorted(k for k, b in prov.items() if not b["fail"])
    if clean:
        print("    no failures: %s" % ", ".join(clean))
    print()

# What actually reached the caller.
#
# Every number above this line counts provider ATTEMPTS, and the gap between an
# attempt and an outcome is enormous here: on an empty or failed response the
# gateway falls back to the next model in the family and serves that instead
# (`chatCore.ts`, EMPTY_CONTENT_FALLBACK), so a caller can see a perfectly
# normal answer while three FAILED rows land in this log.
#
# That is why every report and alert in this repo carries an
# "attempts, not outcomes" caveat. A caveat tells you not to trust a number;
# it does not give you the right one. `correlationId` does: the attempts for a
# single client request share one, so the LAST attempt in each correlation is
# what the caller actually got.
#
# Measured 2026-09-07 over 500 rows: 81 failed attempts (16.2%) were 12
# caller-visible failures (3.0%), and all twelve were the local model. Every
# antigravity, opencode and openrouter failure in that window was recovered.
corr = collections.defaultdict(list)
nocorr = []
for r in win:
    cid = r.get("correlationId")
    corr[cid].append(r) if cid else nocorr.append(r)

if corr:
    clean = recovered = reached = 0
    seen = collections.Counter()
    for attempts in corr.values():
        attempts.sort(key=lambda r: r.get("timestamp") or "")
        last = attempts[-1]
        if failed(last):
            reached += 1
            seen[(last.get("provider"), str(last.get("error") or "").strip()[:52])] += 1
        elif any(failed(a) for a in attempts):
            recovered += 1
        else:
            clean += 1

    n_att = sum(1 for r in win if failed(r))
    print("  what reached the caller")
    print("    %d client request(s) behind %d attempt(s); %d attempt(s) failed"
          % (len(corr), len(win) - len(nocorr), n_att))
    print("      %4d clean" % clean)
    print("      %4d recovered by the gateway's family fallback (caller saw an answer)"
          % recovered)
    print("      %4d reached the caller as an error" % reached)
    if len(win):
        print("    caller-visible failure rate %.1f%% (attempt failure rate %.1f%%)"
              % (100.0 * reached / len(corr), 100.0 * n_att / len(win)))
    for (pv, msg), n in seen.most_common(6):
        print("      %4dx %-12s %s" % (n, pv or "?", msg or "(no message)"))
    if nocorr:
        # Never fold these into the counts above: without a correlationId there
        # is no way to tell a lone failure from one that was retried elsewhere.
        print("    %d row(s) carry no correlationId and are not judged here (%d failed)"
              % (len(nocorr), sum(1 for r in nocorr if failed(r))))
    print()

errs = collections.Counter()
for r in win:
    if failed(r):
        errs[(r.get("status"), str(r.get("error") or "").strip()[:96])] += 1
if errs:
    print("  failure signatures")
    for (st, msg), n in errs.most_common(8):
        print("    %4s x%-4d %s" % (st, n, msg or "(no message)"))
    print()

print("  A call routed through auto/* is the content reroute in")
print("  docs/king-system.md 4 — the caller named a model and the gateway chose")
print("  otherwise. It is not fixable from this repo; this report is for knowing")
print("  which callers it happens to. For what a specific run asked for versus")
print("  what answered it, read served_by in ./scripts/agent-report.sh, which")
print("  records the caller's side.")
PY

printf '%s' "$body" | python3 "$script" "$HOURS" "$LIMIT"
