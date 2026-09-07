#!/bin/sh
# What has the gateway been complaining about? Read the alerts that
# `gateway_alerts` records, from the command line.
#
# Alerts started landing in a table on 2026-09-06. Before that they were shaped
# and dropped — fourteen deliveries, zero rows. Collected and unread is half a
# feature, and a table nobody opens is only a slower way of dropping them, so
# this is the other half.
#
# Reads Postgres directly, the same way monitor-deadman.sh does, rather than
# through the Activepieces API. Two reasons: no API token is needed, and it
# still answers when the Activepieces engine is wedged — which is one of the
# states you would most want to ask about.
#
# Usage:
#   ./scripts/alerts-report.sh          # the last 7 days
#   ./scripts/alerts-report.sh 30       # the last 30 days
set -eu

DAYS="${1:-7}"
case "$DAYS" in
  ''|*[!0-9]*) echo "usage: $0 [days]   (a whole number, default 7)" >&2; exit 2 ;;
esac

PSQL_IMAGE="${MONITOR_PSQL_IMAGE:-postgres:16-alpine}"
TABLE_NAME="${ALERTS_TABLE_NAME:-gateway_alerts}"

cd "$(dirname "$0")/.."

url=$(sed -n 's/^AP_POSTGRES_URL=//p' activepieces/.env 2>/dev/null | tail -1)
[ -n "$url" ] || { echo "AP_POSTGRES_URL not found in activepieces/.env" >&2; exit 1; }

# The cells are one row per field, so everything is pivoted back by name here.
# Selecting by field NAME rather than position: positions shift when a column is
# added, and a report that silently prints the wrong column is worse than one
# that prints nothing.
#
# The time shown is the alert's own `received_at` — when the condition was
# observed — falling back to the row's insert time when that cell is empty or
# unparseable. The shape is checked with a regex before the cast rather than
# cast-and-hope: `::timestamptz` raises on bad input, so one malformed cell
# written by some future producer would fail the whole report instead of
# degrading one line of it. Ordering stays on `r.created`, which is always
# present and always a real timestamp, so a bad `received_at` cannot scramble
# the sequence either.
# The two are sub-second apart for a live alert; they diverged by 18 minutes the
# first time this was tested with a hand-written row, which is how the
# distinction was noticed.
q() {
  docker run --rm "$PSQL_IMAGE" psql "$url" -At -F'|' -c "$1"
}

rows=$(q "
  select coalesce(
           to_char(
             max(case
                   when f.name = 'received_at'
                    and c.value ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}'
                   then c.value::timestamptz
                 end) at time zone 'UTC',
             'MM-DD HH24:MI'),
           to_char(r.created at time zone 'UTC', 'MM-DD HH24:MI')),
         coalesce(max(case when f.name = 'event'    then c.value end), '-'),
         coalesce(max(case when f.name = 'provider' then c.value end), '-'),
         coalesce(max(case when f.name = 'detail'   then c.value end), '-')
  from record r
  join \"table\" t on t.id = r.\"tableId\"
  left join cell c on c.\"recordId\" = r.id
  left join field f on f.id = c.\"fieldId\"
  where t.name = '$TABLE_NAME'
    and r.created > now() - interval '$DAYS days'
  group by r.id, r.created
  order by r.created desc;
" 2>&1) || { echo "Could not read the alerts table: $(printf '%s' "$rows" | tr '\n' ' ' | cut -c1-200)" >&2; exit 1; }

printf 'gateway alerts — last %s day(s)\n\n' "$DAYS"

if [ -z "$rows" ]; then
  echo "  No alerts recorded in this window."
  echo
  # Silence here has two very different causes and the difference matters.
  echo "  That is the good outcome, but confirm it is not the quiet one: alerts"
  echo "  only began being written on 2026-09-06. A window that starts earlier"
  echo "  will look calm because nothing was recording, not because nothing"
  echo "  happened. Activepieces run history for the gateway_alerts flow is"
  echo "  where the older deliveries are."
  exit 0
fi

printf '%s\n' "$rows" | awk -F'|' '
  {
    printf "  %s  %-22s %s\n", $1, $2, ($3 == "-" ? "" : $3)
    if ($4 != "-" && $4 != "") printf "      %s\n", $4
    by_event[$2]++
    if ($3 != "-" && $3 != "") by_provider[$3]++
    n++
  }
  END {
    printf "\n  %d alert(s)\n", n
    printf "\n  by event\n"
    for (k in by_event) printf "    %4d  %s\n", by_event[k], k
    if (length(by_provider) > 0) {
      printf "\n  by provider\n"
      for (k in by_provider) printf "    %4d  %s\n", by_provider[k], k
    }
  }
'

cat <<'NOTE'

  Ratios here are ATTEMPTS, not outcomes. gateway_monitor counts rows in
  call_logs, which are per-provider attempts — including every one the gateway
  recovered a moment later via its model-family fallback, and every one the
  OpenAI SDK retried. That is not a small correction: measured over 168h, a
  15.8% attempt failure rate was a 2.5% caller-visible one.

  Rows written from 2026-09-07 say so themselves — look for
  "N/M request(s) reached a caller" in the detail. A row without that phrase
  predates the change and carries only the attempt ratio, so the two real
  alerts before it both read far worse than they were: the 04:56 CRITICAL
  reported 56% and reached zero callers.

  Confirm real impact from served_by and degraded:  ./scripts/agent-report.sh
  Or read it per provider and per caller:           ./scripts/gateway-report.sh
NOTE
