#!/usr/bin/env bash
#
# Close the three gateway ports at the host firewall.
#
# `king-audit.sh` K-2: ufw reports active and does not cover Docker at all. The
# DOCKER-USER chain — the one hook Docker leaves for the operator — was empty,
# so Docker's own ACCEPT rules pass every published port straight through. Only
# the GCP VPC firewall stood between 20128, 20129 and 20132 and the internet,
# and one control with nothing behind it is not defence in depth.
#
# WHY NOT JUST BIND THEM TO LOOPBACK. They are published by omniroute's
# vendored compose as `"${DASHBOARD_PORT:-20128}:${DASHBOARD_PORT:-20128}"` —
# no bind-host variable, unlike the redis service in the same file which does
# have one. Editing that file is forbidden by CLAUDE.md and a compose override
# of a vendored service once turned every Docker CI job red. So the fix goes
# where the rule says fixes go: outside.
#
# WHY THIS CANNOT LOCK YOU OUT. DOCKER-USER is a hook in the FORWARD chain,
# which only sees traffic being forwarded to containers. SSH reaches sshd
# through INPUT and is never evaluated here. That is structural, not a matter
# of writing the rules carefully.
#
# WHAT IT COULD BREAK, and what these rules do about it. A blanket
# `-i <iface> ! -s <trusted> -j DROP` — the pattern most guides suggest — would
# also drop Caddy's 80 and 443, taking the entire public surface down. So the
# rules are per-port and name only the three. Everything else Docker forwards,
# including Caddy, is untouched.
#
# `-i "$IFACE"` restricts each rule to the public interface, so container-to-
# container traffic on the bridge networks never matches. The mappings are 1:1
# (20128:20128), so the post-DNAT destination port DOCKER-USER sees is the same
# number written here.
#
# IPv6 too: `docker ps` shows `[::]:20128->20128/tcp` alongside the IPv4
# binding. A v4-only rule set would close the front door and leave the back one
# open, which is worse than leaving both open — it looks finished.
#
# Idempotent: existing rules carrying our comment are removed before new ones
# are inserted, so running it twice leaves three rules, not six.
#
# Persistence is `king-firewall.service`, which is `PartOf=docker.service`.
# Docker rebuilds DOCKER-USER on every start, so the rules must be re-applied
# then — and that same mechanism carries them across a reboot. One mechanism
# rather than two that can disagree, which is why `iptables-persistent` is
# deliberately not installed.

set -euo pipefail

IFACE="${KING_PUBLIC_IFACE:-}"
PORTS="${KING_CLOSED_PORTS:-20128 20129 20132}"
# No space in the tag, deliberately.
#
# It was "king-audit K-2" for one run. The removal loop below rebuilds a rule
# from `iptables -S` output and passes it back unquoted — word splitting is the
# point, since the rule is an argument list — so a comment containing a space
# splits mid-token and iptables refuses with `Bad argument 'K-2"'`.
#
# The first run succeeded because there was nothing to remove. The SECOND
# failed, which is every run after the first, which is every Docker restart:
# the exact mechanism `PartOf=docker.service` exists to provide. A guard whose
# persistence path fails on its second invocation is worse than no guard, and
# it took `systemctl restart` to surface it rather than the install.
TAG="king-audit-K-2"

# Derived, not assumed. A hardcoded interface name is the shape of fault K-3
# carried for weeks: a list written once that stopped describing the host.
if [ -z "$IFACE" ]; then
    IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
fi
if [ -z "$IFACE" ]; then
    echo "cannot determine the public interface; set KING_PUBLIC_IFACE" >&2
    exit 2
fi

apply() {
    _ipt="$1"
    # DOCKER-USER may not exist yet if Docker is mid-start.
    if ! "$_ipt" -n -L DOCKER-USER >/dev/null 2>&1; then
        echo "  $_ipt: DOCKER-USER does not exist yet; skipping" >&2
        return 0
    fi
    # Remove ours first, by comment, so re-running does not stack duplicates.
    #
    # Matched WITHOUT quotes around the tag. `iptables -S` quotes a comment
    # only when it contains a space — so the first version of this, written
    # against a tag that had one, matched `--comment "king-audit K-2"`. Taking
    # the space out to fix the word-splitting bug also took the quotes out of
    # the output, and the removal silently stopped matching: three runs left
    # NINE rules instead of three, adding and never subtracting.
    #
    # Two faults from one edit, in opposite directions, and only the rule count
    # showed the second. Assert the count after running this.
    while "$_ipt" -S DOCKER-USER 2>/dev/null | grep -q -- "--comment $TAG"; do
        _rule=$("$_ipt" -S DOCKER-USER | grep -m1 -- "--comment $TAG" | sed 's/^-A /-D /')
        # shellcheck disable=SC2086  # the rule is a pre-split argument list
        "$_ipt" $_rule
    done
    for _p in $PORTS; do
        "$_ipt" -I DOCKER-USER -i "$IFACE" -p tcp --dport "$_p" \
            -m comment --comment "$TAG" -j DROP
    done
    echo "  $_ipt: $(printf '%s' "$PORTS" | wc -w) port(s) closed on $IFACE"
}

apply iptables
apply ip6tables
