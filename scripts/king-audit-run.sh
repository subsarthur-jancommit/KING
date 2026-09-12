#!/bin/sh
# What king-audit.timer actually runs. Paired with king-audit.service.
#
# Why this is a file and not an ExecStart= one-liner. The first version was,
# and it could not have worked: systemd expands `$VAR` and `${VAR}` in ExecStart
# itself and performs NO command substitution, so `$(mktemp)`, `$rc` and
# `${NTFY_ALERT_TOPIC:-}` would all have been chewed before /bin/sh ever saw
# them. A unit file is also invisible to `sh -n` and to `shellcheck scripts/*.sh`
# — the two things that have caught nearly every shell mistake in this repo.
# Shell belongs in a script, where the linters can reach it.
#
# It runs the audit, prints the whole run to the journal, and pushes ONLY the
# delta to ntfy. Full run for whoever goes looking; difference for whoever is
# asleep.
set -u

cd "$(dirname "$0")/.." || exit 1

OUT=$(mktemp)
DELTA=$(mktemp)
# Inline, matching king-audit.sh: a cleanup FUNCTION reached only through a
# trap reads as unreachable to shellcheck, and CI runs it with no flags.
trap 'rm -f "$OUT" "$DELTA"' EXIT INT TERM

# `set -e` is deliberately NOT on for this line. The audit exits 1 on a finding
# and 2 on an unknown, and both are it working. Dying here would mean the
# notification never goes out on exactly the nights it is worth sending.
KING_AUDIT_DELTA_OUT="$DELTA" ./scripts/king-audit.sh --all --delta > "$OUT" 2>&1
rc=$?

cat "$OUT"

# The topic is a bare NAME, not a URL, and the first version of this posted to
# it as though it were one — so the very first real run printed "the delta could
# not be pushed" with no further detail. Both halves of that were wrong: the URL
# and the diagnosis. `NTFY_ALERT_TOPIC` is the unguessable half of an
# unauthenticated topic (see king-rotate.sh), and publishing also wants
# `NTFY_TOKEN`, exactly as G-5 and every other alerting path here use them.
#
# Read from .env with sed, like king-audit.sh itself does, and never by sourcing
# it: `. ./.env` is what truncates `LANGFUSE_OTLP_AUTH=Basic <base64>` at the
# space. An environment variable, if the unit sets one, wins over the file.
NTFY_BASE="${NTFY_BASE_URL:-https://gateway.arject.co/king-ntfy}"
topic="${NTFY_ALERT_TOPIC:-}"
[ -n "$topic" ] || topic=$(sed -n 's/^NTFY_ALERT_TOPIC=//p' .env 2>/dev/null | tail -1)
token="${NTFY_TOKEN:-}"
[ -n "$token" ] || token=$(sed -n 's/^NTFY_TOKEN=//p' .env 2>/dev/null | tail -1)

if [ -n "$topic" ] && [ -s "$DELTA" ]; then
    case "$topic" in
        http://*|https://*) url="$topic" ;;
        *)                  url="$NTFY_BASE/$topic" ;;
    esac
    # The HTTP code, not just success or failure. "Refused" and "unreachable"
    # are different faults with different fixes, and a message that says only
    # "could not push" sends the reader to look at the wrong one — which is the
    # distinction _doorverdict and the UNKNOWN verdict exist to keep.
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 30 \
        -H "Authorization: Bearer $token" \
        -H 'Title: KING audit: something moved' \
        -H 'Priority: high' \
        --data-binary @"$DELTA" "$url" 2>/dev/null || echo 000)
    case "$code" in
        200) : ;;
        000) echo "king-audit-run: ntfy at $NTFY_BASE did not answer; the delta was not delivered" >&2 ;;
        *)   echo "king-audit-run: ntfy refused the delta with HTTP $code" >&2 ;;
    esac
    # Deliberately not fatal either way. `systemctl --user --failed` is the
    # signal for "the audit could not run", and overloading it with "the audit
    # ran and the phone did not hear about it" costs more than it saves. The
    # journal above still has the whole run.
fi

# 3 means the audit is incomplete — a planned check never ran, or one ran that
# the manifest does not declare. That is the audit being broken, so the unit
# fails and shows up in `systemctl --user --failed`.
#
# 1 (a finding) and 2 (an unknown) are the audit WORKING, and the notification
# above is how they are reported. Failing the unit for them would mean the one
# signal that says "the instrument is broken" also says "the instrument found
# something", and then it says neither.
if [ "$rc" -ge 3 ]; then
    exit "$rc"
fi
exit 0
