#!/bin/sh
# Prove every registered provider still answers, on a schedule, and say so
# somewhere a person will find.
#
# Why this exists. OmniRoute's built-in health autopilot reported all providers
# "healthy, 0 issues" while three of them failed 100% of real requests. A
# provider that is registered, enabled, and silent is the exact failure this
# deployment has been bitten by three times — a saved connection that answers
# nothing looks identical to a working one from every dashboard.
#
# `pool-register.sh --prove` already sends a real completion to each provider
# and counts only the ones that answer. It has never been run on a schedule, so
# it catches a dead provider only when somebody happens to think of it. This is
# the wrapper that makes it periodic and makes its failure reach somewhere.
#
# Two signals, deliberately:
#
#   1. The systemd unit FAILS. That is the signal of last resort and it works
#      when everything else is down — `systemctl --user --failed`.
#   2. An alert is POSTed to the gateway_alerts webhook, so the failure lands in
#      the same table as every other alert instead of a second place nobody
#      watches. This reuses the path the monitor already proved rather than
#      opening a new one, which is the argument gateway_monitor's own code
#      makes for doing it this way.
#
# The post is best-effort and never decides the exit code. A provider outage
# that coincides with Activepieces being down must still fail the unit.
#
# Usage:
#   ./scripts/pool-prove.sh              # from the repo root on the VPS
# Env:
#   POOL_ALERT_URL, POOL_ALERT_SECRET    # both required to post; without them
#                                        # the failing unit is the only signal
set -eu

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

cd "$(dirname "$0")/.."

# Not `out=$(...)` on its own: under `set -e` a non-zero exit inside command
# substitution ends the script, and a non-zero exit is the case this entire
# script exists to handle.
rc=0
out=$(./scripts/pool-register.sh --prove 2>&1) || rc=$?
printf '%s\n' "$out"

# Kept separate from `rc`, which the dead-model check below also sets.
# Two different faults must not be reported as each other.
prove_rc=$rc

# Second question, and the one the first cannot answer.
#
# `--prove` sends one completion per PROVIDER. A provider is healthy the moment
# any one of its models replies, so a provider can pass here while several of
# the model names the router is free to pick have never worked at all. Measured
# 2026-09-08: openrouter answered 4 of 4 on its free model and was reported
# healthy, while every paid OpenRouter model the router selected failed on an
# account with no credit. Same shape as most entries in docs/king-mistakes.md —
# an instrument green against a different question than the one that matters.
#
# This asks the call log rather than sending more traffic: which (provider,
# model) pairs were selected at least three times and never once answered. It
# costs nothing, and it reflects what the router actually did instead of what a
# probe would have done.
#
# Acknowledged pairs live in scripts/pool-dead-models.txt with a reason each,
# so the guard stays green for what is already known and goes red for anything
# new.
dead=""
key=$(sed -n 's/^OMNIROUTE_MCP_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -n 1)
[ -n "$key" ] || key=$(sed -n 's/^OMNIROUTE_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -n 1)
if [ -n "$key" ]; then
  # A temp file, not a heredoc on python's stdin: a heredoc IS stdin, so
  # piping the log into `python3 - <<PY` feeds python the script and discards
  # the log. That is exactly how gateway-report.sh first failed.
  chk=$(mktemp)
  trap 'rm -f "$chk"' EXIT INT TERM
  cat > "$chk" <<'PYCHK'
import collections, json, sys

try:
    rows = json.load(sys.stdin)
except Exception as exc:
    # Unreadable log is not a pool fault, and must not be reported as one.
    print("could not read the call log: %s" % exc, file=sys.stderr)
    raise SystemExit(0)
if not isinstance(rows, list):
    rows = rows.get("data") or rows.get("logs") or []

known = set()
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if line:
                known.add(line)
except FileNotFoundError:
    pass

def failed(r):
    return (isinstance(r.get("status"), int) and r["status"] >= 400) or bool(r.get("error"))

agg = collections.defaultdict(lambda: [0, 0, ""])
for r in rows:
    k = "%s/%s" % (r.get("provider") or "?", r.get("model") or "?")
    agg[k][0] += 1
    if failed(r):
        agg[k][1] += 1
        agg[k][2] = " ".join(str(r.get("error") or "").split())[:70]

for name, (n, f, err) in sorted(agg.items()):
    if n >= 3 and f == n and name not in known:
        print("%s\t%d/%d\t%s" % (name, f, n, err))
PYCHK
  dead=$(curl -s -m 60 "${OMNIROUTE_BASE_URL:-http://localhost:20128}/api/usage/call-logs?limit=500&excludeTests=1" \
      -H "Authorization: Bearer $key" \
      | python3 "$chk" scripts/pool-dead-models.txt 2>/dev/null || true)
fi

if [ -n "$dead" ]; then
  red "Model(s) the router selects that have never once answered:"
  printf '%s\n' "$dead" | while IFS="$(printf '\t')" read -r name ratio err; do
    printf '  %-42s %-7s %s\n' "$name" "$ratio" "$err"
  done
  echo
  echo "Each is selectable by the router and cannot answer, so every selection"
  echo "is an attempt the family fallback then has to cover. Fix it, or"
  echo "acknowledge it with a reason in scripts/pool-dead-models.txt."
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  green "Every registered provider answered, and no selectable model is dead."
  exit 0
fi

# Name the silent providers rather than counting them. "3 of 7 answered" tells
# you to go and look; "chutes, targon are silent" is the thing you were going
# to look for.
#
# Anchored on the table's own separator line and the blank line that closes it,
# rather than on field counts — the BUKTI column contains spaces, so counting
# fields misreads a row like "MENJAWAB (glm-4.7)".
silent=""
if [ "$prove_rc" -ne 0 ]; then
  silent=$(printf '%s\n' "$out" | awk '
    /^-{5,}/            { inrows = 1; next }
    inrows && NF == 0   { inrows = 0 }
    inrows && !/MENJAWAB/ && NF > 0 { print $1 }
  ' | paste -sd, - 2>/dev/null | sed 's/,/, /g' || true)
  [ -n "$silent" ] || silent="(could not parse which; see the table above)"
fi

# One alert, two possible causes, named separately. A dead selectable model is
# not a silent provider, and reporting it as one would send somebody to check a
# provider that is working perfectly.
dead_names=$(printf '%s' "$dead" | awk -F'\t' 'NF { print $1 }' \
  | paste -sd, - 2>/dev/null | sed 's/,/, /g' || true)
if [ -n "$silent" ] && [ -n "$dead_names" ]; then
  subject="$silent; $dead_names"
  reason="pool proof failed: $silent did not answer; and $dead_names never answer when selected"
elif [ -n "$silent" ]; then
  subject="$silent"
  reason="pool proof failed: $silent did not answer"
else
  subject="$dead_names"
  reason="selectable model(s) that never answer: $dead_names"
fi
red "$reason"

if [ -n "${POOL_ALERT_URL:-}" ] && [ -n "${POOL_ALERT_SECRET:-}" ]; then
  # Same envelope and HMAC scheme gateway_alerts already verifies, and the
  # field names its shaping step reads directly: `provider` and `reason` land
  # in the table's own columns without the shaping needing a third branch.
  body=$(printf '{"event":"pool.prove_failed","timestamp":"%s","data":{"severity":"CRITICAL","provider":%s,"reason":%s}}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$subject" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')" \
    "$(printf '%s' "$reason" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')")
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$POOL_ALERT_SECRET" -r | cut -d' ' -f1)
  # if/then/else rather than `A && B || C`: in that form C also runs when A
  # succeeded and B failed, reporting a successful post as failed (SC2015).
  if curl -sf -m 15 -X POST "$POOL_ALERT_URL" \
       -H 'Content-Type: application/json' \
       -H 'x-webhook-event: pool.prove_failed' \
       -H "x-webhook-signature: sha256=$sig" \
       -d "$body" >/dev/null 2>&1; then
    yellow "  alert posted to gateway_alerts"
  else
    yellow "  could not post the alert; the failing unit below is the signal"
  fi
else
  yellow "  POOL_ALERT_URL / POOL_ALERT_SECRET unset — the failing unit is the only signal"
fi

# The unit must fail whatever the post did.
exit "$rc"
