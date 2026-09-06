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

if [ "$rc" -eq 0 ]; then
  green "Every registered provider answered."
  exit 0
fi

# Name the silent providers rather than counting them. "3 of 7 answered" tells
# you to go and look; "chutes, targon are silent" is the thing you were going
# to look for.
#
# Anchored on the table's own separator line and the blank line that closes it,
# rather than on field counts — the BUKTI column contains spaces, so counting
# fields misreads a row like "MENJAWAB (glm-4.7)".
silent=$(printf '%s\n' "$out" | awk '
  /^-{5,}/            { inrows = 1; next }
  inrows && NF == 0   { inrows = 0 }
  inrows && !/MENJAWAB/ && NF > 0 { print $1 }
' | paste -sd, - 2>/dev/null | sed 's/,/, /g' || true)

[ -n "$silent" ] || silent="(could not parse which; see the table above)"

reason="pool proof failed: $silent did not answer"
red "$reason"

if [ -n "${POOL_ALERT_URL:-}" ] && [ -n "${POOL_ALERT_SECRET:-}" ]; then
  # Same envelope and HMAC scheme gateway_alerts already verifies, and the
  # field names its shaping step reads directly: `provider` and `reason` land
  # in the table's own columns without the shaping needing a third branch.
  body=$(printf '{"event":"pool.prove_failed","timestamp":"%s","data":{"severity":"CRITICAL","provider":%s,"reason":%s}}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$silent" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().strip()))')" \
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
