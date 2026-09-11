#!/usr/bin/env bash
# Dead-man's switch for gateway_monitor.
#
# gateway_monitor watches the gateway. Until now nothing watched gateway_monitor,
# and on 2026-08-29 it stopped for 14 hours 19 minutes without anyone noticing —
# the Activepieces container reported `healthy` throughout, because its
# healthcheck answers from the API and the API does not need the job queue.
#
# The check reads Postgres directly rather than asking Activepieces whether it is
# alive. That is the point: a monitor that shares fate with the thing it watches
# is not a monitor. Reading the durable record catches both failure modes —
# "the flow stopped but the engine is up" and "the engine is gone" — with one
# query, and it needs no new credential, because AP_POSTGRES_URL is already on
# this host and Neon is external to everything here.
#
#   ./scripts/monitor-deadman.sh          # check, alert if stale
#   ./scripts/monitor-deadman.sh --quiet  # same, but silent when healthy (cron)
#
# Exit codes: 0 = the monitor ran recently, 1 = stale or unmeasurable.

set -euo pipefail

cd "$(dirname "$0")/.."

FLOW_ID="${MONITOR_FLOW_ID:-6Ko1wC7xxFxE7GjruoB5u}"
# The schedule is every 15 minutes. Two things stretch the real gap, and 35
# accounted for only one of them:
#
#   observed spacing under load          22.5 min
#   + one slot skipped by a republish    15.0 min   (publishing a flow
#                                                    re-registers its schedule)
#   ------------------------------------------------
#   worst LEGITIMATE gap                 37.5 min
#
# At 35 this fires on an entirely normal day — publish a flow while the host is
# busy and the deadman calls it a stall. An alarm that goes off when nothing is
# wrong is one people learn to dismiss, which is the failure it exists to
# prevent, arriving by a different road.
#
# 50 tolerates one skipped slot with 12.5 minutes of margin and still catches
# two (52.5 min), which is a genuine outage rather than a busy afternoon.
# king-audit.sh G-4 fails below 40 and carries the same arithmetic, so this
# number and its justification cannot drift apart silently.
MAX_AGE_MIN="${MONITOR_MAX_AGE_MIN:-50}"
STATE_FILE="${MONITOR_STATE_FILE:-$HOME/.king-monitor-deadman}"
PSQL_IMAGE="${MONITOR_PSQL_IMAGE:-postgres:16-alpine}"

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
green()  { [ "$quiet" -eq 1 ] || printf '\033[32m%s\033[0m\n' "$*"; }

# Everything below distinguishes "the monitor is late" from "I could not find
# out". The second is not a pass. Three instruments in this repo used to answer
# zero when they could not read, and one of them stood in front of this exact
# class of outage — see docs/integrations/reliability-plan.md.
fail_out() {
  red "$*"
  printf '%s\tSTALE\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE_FILE"
  # Best effort, and deliberately not the only signal: this reaches the operator
  # when the flow has stopped but Activepieces is still serving, which is one of
  # the two failure modes. When the engine itself is gone it will not, and the
  # non-zero exit below is what systemd surfaces then.
  if [ -n "${MONITOR_ALERT_URL:-}" ] && [ -n "${MONITOR_ALERT_SECRET:-}" ]; then
    body=$(printf '{"event":"monitor.deadman","timestamp":"%s","data":{"reason":%s}}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$*" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")
    sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$MONITOR_ALERT_SECRET" -r | cut -d' ' -f1)
    # if/then/else rather than `A && B || C`: in that form C also runs when A
    # succeeded but B failed, so a failing printf would report the post as
    # failed. Benign here and still wrong, and shellcheck says so (SC2015).
    if curl -sf -m 15 -X POST "$MONITOR_ALERT_URL" \
         -H 'Content-Type: application/json' \
         -H 'x-webhook-event: monitor.deadman' \
         -H "x-webhook-signature: sha256=$sig" \
         -d "$body" >/dev/null 2>&1; then
      yellow "  alert posted to gateway_alerts"
    else
      yellow "  could not post the alert either — Activepieces may be down, which is the point"
    fi
  fi
  exit 1
}

# _dm_verdict <flow_status> <age_minutes> <max_age>
#
# Three states used to print one sentence. "gateway_monitor last ran N minutes
# ago; it is not running" is true whether the flow was deliberately switched
# off, never existed in this database, or genuinely stalled — and in two of
# those three it sends the reader looking for a broken engine.
#
# On 2026-09-11 that mattered in practice. The six flows were restored as ROWS
# into a fresh Neon project and set DISABLED, because Activepieces registers
# triggers in the Redis queue and restored rows do not re-register. The deadman
# reported a stall. Nothing had stalled; nothing had been armed.
#
# Every non-ENABLED outcome is still a failure — coverage is missing either way
# — but each names its own cause, and therefore its own fix.
_dm_verdict() {
  case "${1:-}" in
    MISSING)  printf 'missing';    return ;;
    ENABLED)  ;;
    '')       printf 'unreadable'; return ;;
    *)        printf 'disabled';   return ;;
  esac
  case "${2:-}" in ''|*[!0-9-]*) printf 'unreadable'; return ;; esac
  [ "$2" -ge 0 ] || { printf 'never'; return; }
  [ "$2" -le "${3:-50}" ] || { printf 'stale'; return; }
  printf 'ok'
}

if [ "${1:-}" = "--self-test" ]; then
  f=0
  check() {
    if [ "$(_dm_verdict "$2" "$3" "$4")" = "$1" ]
    then printf '  ok    %s\n' "$5"
    else printf '  FAIL  %s\n' "$5"; f=$((f+1)); fi
  }
  echo "monitor-deadman self-test (fixtures only; no database, no network)"
  check ok         ENABLED  12   50 "an enabled flow that ran 12 minutes ago is healthy"
  check stale      ENABLED  90   50 "an enabled flow 90 minutes late is a stall"
  check never      ENABLED  -1   50 "an enabled flow with no run ever recorded is not called a stall"
  check disabled   DISABLED -1   50 "a DISABLED flow names itself rather than reading as a stall"
  check disabled   DISABLED 12   50 "a DISABLED flow is still a failure even with a recent run"
  check missing    MISSING  -1   50 "a flow absent from the database names itself"
  check unreadable ''       12   50 "an unreadable status is unknown, never a pass"
  check unreadable ENABLED  ''   50 "an unreadable age is unknown, never a pass"
  check unreadable ENABLED  abc  50 "a non-numeric age is unknown, never a pass"
  # The old predicate, pinned: age alone, so every cause printed one sentence.
  _dm_old() { if [ "${1:-0}" -gt "${2:-50}" ]; then printf 'stale'; else printf 'ok'; fi; }
  if [ "$(_dm_old 99999 50)" = "stale" ]
  then printf '  ok    the OLD age-only test called a disabled flow a stall, which is why it was replaced\n'
  else printf '  FAIL  the OLD age-only test called a disabled flow a stall, which is why it was replaced\n'; f=$((f+1)); fi
  echo
  if [ "$f" -eq 0 ]; then green "self-test passed"; exit 0; fi
  red "$f self-test check(s) failed"; exit 1
fi

url=$(sed -n 's/^AP_POSTGRES_URL=//p' activepieces/.env 2>/dev/null | tail -1)
[ -n "$url" ] || fail_out "AP_POSTGRES_URL not found in activepieces/.env; cannot check whether the monitor is alive."

# One query, two facts. `created` and `flowId` are quoted because Activepieces
# uses camelCase column names. Scalar subqueries rather than a join, so a flow
# row that does not exist still returns exactly one row to read.
q="select coalesce((select status from flow where id='$FLOW_ID'), 'MISSING')
          || '|' ||
          coalesce((select round(extract(epoch from (now()-max(\"created\")))/60)
                    from flow_run
                    where \"flowId\"='$FLOW_ID' and environment='PRODUCTION')::text, '-1');"
if ! row=$(docker run --rm "$PSQL_IMAGE" psql "$url" -At -c "$q" 2>&1); then
  fail_out "Could not query Postgres for the monitor's state: $(printf '%s' "$row" | tr '\n' ' ' | cut -c1-160)"
fi

row=$(printf '%s' "$row" | tr -d ' \r\n')
status=${row%%|*}
age=${row#*|}

case "$(_dm_verdict "$status" "$age" "$MAX_AGE_MIN")" in
  ok)
    green "gateway_monitor ran ${age} minute(s) ago (limit ${MAX_AGE_MIN})." ;;
  stale)
    fail_out "gateway_monitor is ENABLED but last ran ${age} minutes ago; the limit is ${MAX_AGE_MIN}. It has stalled." ;;
  never)
    fail_out "gateway_monitor is ENABLED but no PRODUCTION run has ever been recorded in this database. The trigger is not armed — publishing the flow in the UI re-registers it." ;;
  disabled)
    fail_out "gateway_monitor exists but its status is ${status}, so nothing is scheduled. This is a switch, not a stall: enable the flow in Activepieces to restore coverage." ;;
  missing)
    fail_out "gateway_monitor (${FLOW_ID}) does not exist in this database at all. Nothing is watching the gateway." ;;
  *)
    fail_out "Could not read the monitor's state (status='${status}' age='${age}')." ;;
esac
