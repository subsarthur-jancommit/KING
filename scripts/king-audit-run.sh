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

if [ -n "${NTFY_ALERT_TOPIC:-}" ] && [ -s "$DELTA" ]; then
    # Best-effort. A push that fails must not turn a completed audit into a
    # failed unit, because `systemctl --user --failed` is the signal for "the
    # audit could not run" and overloading it costs more than it saves.
    curl -s -m 30 \
        -H 'Title: KING audit: something moved' \
        -H 'Priority: high' \
        --data-binary @"$DELTA" "$NTFY_ALERT_TOPIC" >/dev/null 2>&1 \
        || echo "king-audit-run: the delta could not be pushed to ntfy" >&2
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
