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
# The schedule is every 15 minutes, but observed spacing has reached 22.5 minutes
# under load. 35 leaves room for that without letting a real stall hide.
MAX_AGE_MIN="${MONITOR_MAX_AGE_MIN:-35}"
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
    curl -sf -m 15 -X POST "$MONITOR_ALERT_URL" \
      -H 'Content-Type: application/json' \
      -H 'x-webhook-event: monitor.deadman' \
      -H "x-webhook-signature: sha256=$sig" \
      -d "$body" >/dev/null 2>&1 \
      && yellow "  alert posted to gateway_alerts" \
      || yellow "  could not post the alert either — Activepieces may be down, which is the point"
  fi
  exit 1
}

url=$(sed -n 's/^AP_POSTGRES_URL=//p' activepieces/.env 2>/dev/null | tail -1)
[ -n "$url" ] || fail_out "AP_POSTGRES_URL not found in activepieces/.env; cannot check whether the monitor is alive."

# `created` is quoted because Activepieces uses camelCase column names.
if ! age=$(docker run --rm "$PSQL_IMAGE" psql "$url" -At -c \
      "select coalesce(round(extract(epoch from (now() - max(\"created\")))/60), -1)
       from flow_run where \"flowId\" = '$FLOW_ID' and environment = 'PRODUCTION';" 2>&1); then
  fail_out "Could not query Postgres for the monitor's last run: $(printf '%s' "$age" | tr '\n' ' ' | cut -c1-160)"
fi

age=$(printf '%s' "$age" | tr -dc '0-9-')
case "$age" in
  '' | -* ) fail_out "No PRODUCTION run of $FLOW_ID has ever been recorded, or the age was unreadable ('$age')." ;;
esac

if [ "$age" -gt "$MAX_AGE_MIN" ]; then
  fail_out "gateway_monitor last ran ${age} minutes ago; the limit is ${MAX_AGE_MIN}. It is not running."
fi

green "gateway_monitor ran ${age} minute(s) ago (limit ${MAX_AGE_MIN})."
