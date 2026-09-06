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
# Per API key it reports calls, failures, the override rate, and every
# requested -> served pair, so "which tier is this flow really getting" is one
# command rather than an inference.
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


def asked(r):
    # A combo is a request for a ladder, not for one model, so it is reported as
    # itself rather than compared against whatever tier answered.
    return r.get("comboName") or r.get("requestedModel") or "(unspecified)"


def is_override(r):
    want = r.get("requestedModel")
    if not want or r.get("comboName"):
        return False
    tail = want.split("/", 1)[1] if "/" in want else want
    return (r.get("model") or "") != tail


by_key = collections.defaultdict(lambda: {"n": 0, "fail": 0, "over": 0, "direct": 0,
                                          "pairs": collections.Counter(),
                                          "tin": 0, "tout": 0})
for r in win:
    k = r.get("apiKeyName") or r.get("apiKeyId") or "(no key)"
    b = by_key[k]
    b["n"] += 1
    if failed(r):
        b["fail"] += 1
    if not r.get("comboName") and r.get("requestedModel"):
        b["direct"] += 1
        if is_override(r):
            b["over"] += 1
    b["pairs"][(asked(r), served(r))] += 1
    tok = r.get("tokens") or {}
    b["tin"] += tok.get("in") or 0
    b["tout"] += tok.get("out") or 0

for name, b in sorted(by_key.items(), key=lambda kv: -kv[1]["n"]):
    print("  %s" % name)
    print("    %d call(s), %d failed, tokens in/out %s / %s"
          % (b["n"], b["fail"], format(b["tin"], ","), format(b["tout"], ",")))
    if b["direct"]:
        print("    named a model directly on %d call(s); %d served by something else"
              % (b["direct"], b["over"]))
    else:
        print("    every call named a combo, so there is no override to report")
    for (want, got), n in b["pairs"].most_common(6):
        mark = "  <-- overridden" if (want != got and "/" in want and not want.startswith("auto/")
                                      and want.split("/", 1)[1] != got.split("/", 1)[1]) else ""
        print("      %4d  %-42s -> %s%s" % (n, want[:42], got, mark))
    print()

errs = collections.Counter()
for r in win:
    if failed(r):
        errs[(r.get("status"), str(r.get("error") or "")[:60])] += 1
if errs:
    print("  failure signatures")
    for (st, msg), n in errs.most_common(6):
        print("    %4s x%-4d %s" % (st, n, msg or "(no message)"))
    print()

print("  A requested model and a served one that differ is the content reroute")
print("  in docs/king-system.md 4. It is not fixable from this repo; what this")
print("  report is for is knowing which callers it is happening to.")
PY

printf '%s' "$body" | python3 "$script" "$HOURS" "$LIMIT"
