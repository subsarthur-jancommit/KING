#!/usr/bin/env bash
#
# king-rotate.sh — rotate one credential at a time, without the value ever
# reaching a terminal, a log, a shell history or `ps`.
#
# Bash, not sh, for `read -rs`. Reading a secret with the terminal echoing it
# is how a credential ends up in a scrollback buffer that gets pasted into a
# bug report.
#
# WHAT THIS DOES NOT DO, DELIBERATELY.
#
# It does not generate values, contact providers, or decide anything. You get
# the new credential from wherever it comes from and paste it once. The script
# handles the part that is tedious and therefore gets done wrong: finding the
# right file among six, writing it without clobbering the mode, restarting
# exactly the services that read it, and proving afterwards that the thing
# still works.
#
# THE RULE IT ENFORCES, from docs/king-mistakes.md 24:
#
#   A rotation is not done when the new credential is accepted. It is done
#   when everything that read the old one has been checked.
#
# So every rotation ends by running verify-credentials.sh, which makes seven
# real calls and asserts that a wrong token is refused. A revoked key does not
# announce itself: measured 2026-09-05, an invalid OMNIROUTE_MCP_API_KEY
# produces a 30-second TimeoutError, not "403 invalid key", and the sidecar
# stays healthy throughout. "Nothing looks broken" is not evidence.
#
# Usage:
#   ./scripts/king-rotate.sh --list           what is left, and in what order
#   ./scripts/king-rotate.sh --plan VAR       what would happen; changes nothing
#   ./scripts/king-rotate.sh VAR              rotate it
#   ./scripts/king-rotate.sh --done VAR       record one you rotated by hand
#
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1
STATE=".rotation-state"          # gitignored; names and dates only, no values

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yell()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

# Some targets are owned by the container (uid 1000) while this runs as 1001.
priv() { if sudo -n true 2>/dev/null; then sudo -n "$@"; else "$@"; fi; }

# Every profile both compose files declare, as a COMPOSE_PROFILES value.
#
# Derived, not hardcoded. CLAUDE.md requires every added service to be opt-in
# via `profiles:`, so the list grows, and a stale hardcoded copy would fail the
# exact way this exists to prevent: `docker compose up -d activepieces` returns
# "no such service: omniroute-base" when the profile gating that dependency is
# not active, and the recreate silently does nothing.
#
# Activating a profile only makes a service RESOLVABLE; with `up -d <name>`
# nothing else is started, and `--no-deps` keeps --force-recreate from reaching
# through depends_on into the gateway.
all_profiles() {
    { grep -A1 'profiles:' docker-compose.yml 2>/dev/null
      grep -A1 'profiles:' omniroute/docker-compose.yml 2>/dev/null
    } | grep -oE '^[[:space:]]*-[[:space:]]*[a-z][a-z0-9-]*' \
      | sed 's/^[[:space:]]*-[[:space:]]*//' | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ---------------------------------------------------------------- registry
#
# var | file | services to recreate | risk | what a holder gets / what breaks
#
# risk:
#   safe        rotate freely
#   logout      invalidates sessions; harmless, people log in again
#   destructive orphans stored data; requires a typed confirmation
#   manual      cannot be done from a file alone; the script explains and stops
#
# Order matters: this is the queue --list prints, disclosed credentials first.
REG=$(cat <<'REGEOF'
GRAPHIFY_API_KEY|.env|codegraph-serve|safe|DISCLOSED — printed to a session transcript. Guards the code graph, which is served through Caddy.
openrouter|providers.env||manual|DISCLOSED — passed through chat. Lowercase, and read by scripts/pool-register.sh as KEYFILE. Rotate at openrouter.ai, update the gateway UI, AND this file.
LANGFUSE_OTLP_AUTH|.env|otel-collector|safe|The Langfuse key pair, base64 in an Authorization: Basic header. Rotate at Langfuse, re-encode the pair.
NTFY_TOKEN|.env|ntfy|safe|Publishes to the alert topic. Rotate with NTFY_ALERT_TOPIC.
NTFY_ALERT_TOPIC|.env|ntfy|safe|ntfy topics are unauthenticated by name, so the random topic IS the access control. Update the Activepieces gateway_alerts step too.
AGENT_SIDECAR_AUTH_TOKEN|agent-sidecar/.env|agent-sidecar-http|safe|TIER 1 — ROOT ON THIS HOST. The sidecar mounts docker.sock read-write with EXEC_ENABLED=true.
OMNIROUTE_API_KEY|agent-sidecar/.env|agent-sidecar-http|safe|The sidecar's /v1 calls. Issue the new key in the gateway UI first.
OMNIROUTE_MCP_API_KEY|agent-sidecar/.env|agent-sidecar-http|safe|manage-scoped; reaches /api/mcp/stream and the usage API. Issue in the UI first.
E2B_API_KEY|agent-sidecar/.env|agent-sidecar-http|safe|The code-execution sandbox. A holder runs arbitrary code in E2B on this account.
MODAL_TOKEN_ID|agent-sidecar/.env|agent-sidecar-http|safe|Alternative sandbox backend. Rotate with MODAL_TOKEN_SECRET.
MODAL_TOKEN_SECRET|agent-sidecar/.env|agent-sidecar-http|safe|Alternative sandbox backend. Rotate with MODAL_TOKEN_ID.
SEARXNG_SECRET|.env|searxng|safe|Instance secret for the search service.
POOL_ALERT_SECRET|.pool-prove.env||safe|HMAC secret for the pool-prove timer. No container reads it; the systemd timer picks it up on its next run.
AP_JWT_SECRET|activepieces/.env|activepieces|logout|Signs Activepieces sessions. Everyone is logged out, which is harmless.
JWT_SECRET|omniroute/.env|omniroute|logout|Session tokens for the gateway UI. You will log in again.
AP_REDIS_PASSWORD|.env|ap-redis activepieces|safe|MUST recreate both together, or the workflow engine loses its queue. This script does that.
MACHINE_ID_SALT|omniroute/.env|omniroute|safe|Upstream files it under "Security hashing" beside API_KEY_SECRET. Changes derived machine ids; nothing here pins one.
API_KEY_SECRET|omniroute/.env|omniroute|destructive|Signs issued keys. Rotating INVALIDATES EVERY ISSUED KEY AT ONCE, including the two the sidecar holds. Re-issue them in the same sitting.
AP_ENCRYPTION_KEY|activepieces/.env|activepieces|destructive|Encrypts stored connections. Rotating ORPHANS EVERY SAVED CONNECTION; they must be re-entered.
AP_POSTGRES_URL|activepieces/.env|activepieces|destructive|Carries the Neon password inline. Change the password at Neon first, then this whole URL. king-backup.sh reads it too.
STORAGE_ENCRYPTION_KEY|omniroute/data/server.env|omniroute|destructive|Decrypts EVERY provider credential in storage.sqlite. LOSING IT IS NOT RECOVERABLE BY ROTATION — the only path is reset-encrypted-columns --force, which wipes them all. Back up this file first.
OMNIROUTE_ADMIN_PASSWORD|omniroute/.env|omniroute|manual|The gateway admin login. The file alone does not change it; you must also change it in the gateway UI.
REGEOF
)

reg_field() { printf '%s\n' "$REG" | awk -F'|' -v v="$1" -v n="$2" '$1==v{print $n; exit}'; }
reg_vars()  { printf '%s\n' "$REG" | awk -F'|' '{print $1}'; }
is_done()   { [ -f "$STATE" ] && grep -qxF "$1" <(awk '{print $1}' "$STATE" 2>/dev/null); }

usage() {
    cat <<'USAGE'
king-rotate.sh — rotate one credential at a time

  --list            the queue, with what is already done
  --plan VAR        what would happen. Changes nothing.
  VAR               rotate it
  --done VAR        record a credential you rotated by hand
  --help

Rotate one at a time. After each, this runs verify-credentials.sh, because a
revoked key does not announce itself.
USAGE
}

do_list() {
    printf '\n  %-26s %-26s %-12s %s\n' "CREDENTIAL" "FILE" "RISK" "STATUS"
    printf '  %s\n' "--------------------------------------------------------------------------------"
    _n=0; _d=0
    for v in $(reg_vars); do
        _n=$((_n + 1))
        f=$(reg_field "$v" 2); r=$(reg_field "$v" 4)
        # Pad FIRST, colour SECOND. An escape sequence counts toward printf's
        # field width but not toward anything the eye sees, so colouring before
        # padding walks every coloured column left by nine characters.
        _rp=$(printf '%-12s' "$r")
        case "$r" in
            destructive) _rp=$(printf '\033[31m%s\033[0m' "$_rp") ;;
            manual)      _rp=$(printf '\033[33m%s\033[0m' "$_rp") ;;
        esac
        if is_done "$v"; then
            _sp=$(printf '\033[32m%s\033[0m' "done"); _d=$((_d + 1))
        else
            _sp=$(printf '\033[2m%s\033[0m' "pending")
        fi
        printf '  %-26s %-26s %s %s\n' "$v" "$f" "$_rp" "$_sp"
    done
    printf '\n  %s of %s recorded as rotated.\n' "$_d" "$_n"
    printf '  Order is deliberate: disclosed credentials first, destructive ones last.\n'
    printf '  Start with:  ./scripts/king-rotate.sh --plan %s\n\n' "$(reg_vars | head -1)"
}

show_plan() {
    v="$1"
    f=$(reg_field "$v" 2); s=$(reg_field "$v" 3); r=$(reg_field "$v" 4); d=$(reg_field "$v" 5)
    [ -n "$f" ] || { c_red "  unknown credential: $v"; printf '  see --list\n'; return 1; }
    printf '\n  %s\n' "$v"
    printf '    file      %s\n' "$f"
    printf '    services  %s\n' "${s:-none — nothing to recreate}"
    printf '    risk      %s\n' "$r"
    printf '    note      %s\n' "$d"
    if [ ! -e "$f" ] && ! priv test -e "$f"; then
        c_red "    MISSING   $f does not exist here"
        return 1
    fi
    if { grep -q "^$v=" "$f" 2>/dev/null || priv grep -q "^$v=" "$f" 2>/dev/null; }; then
        printf '    present   yes — the line will be replaced in place\n'
    else
        c_red "    present   NO — $v is not in $f; refusing to guess"
        return 1
    fi
    printf '    after     ./scripts/verify-credentials.sh runs automatically\n\n'
    return 0
}

rotate() {
    v="$1"
    show_plan "$v" || return 1
    f=$(reg_field "$v" 2); s=$(reg_field "$v" 3); r=$(reg_field "$v" 4)

    if [ "$r" = "manual" ]; then
        c_yell "  This one cannot be completed from a file alone."
        case "$v" in
            openrouter)
                cat <<'EOM'
    1. Rotate the key at openrouter.ai and revoke the old one.
    2. Update it in the gateway UI (Providers -> OpenRouter).
    3. Re-run this with the new value to update providers.env, which
       scripts/pool-register.sh reads. Skipping step 3 means the next pool
       registration pushes the OLD key back.
EOM
                printf '\n  Continue and update the file now? [y/N] '
                read -r ans; [ "$ans" = "y" ] || { printf '  stopped.\n'; return 0; }
                ;;
            OMNIROUTE_ADMIN_PASSWORD)
                cat <<'EOM'
    The file does not change the login on its own. Change it in the gateway UI
    first, then run this to bring the file in line.
EOM
                printf '\n  Changed it in the UI already? [y/N] '
                read -r ans; [ "$ans" = "y" ] || { printf '  stopped.\n'; return 0; }
                ;;
        esac
    fi

    if [ "$r" = "destructive" ]; then
        printf '\n'
        c_red "  THIS ROTATION DESTROYS DATA."
        printf '  %s\n\n' "$(reg_field "$v" 5)"
        printf '  Take a restore point first if you have not:  ./scripts/king-backup.sh\n'
        printf '  Type the credential name to confirm: '
        read -r confirm
        [ "$confirm" = "$v" ] || { c_yell "  did not match; nothing changed."; return 1; }
    fi

    # ---- read the value without echoing it ----
    printf '\n  Paste the NEW value for %s (input hidden), then Enter:\n  > ' "$v"
    read -rs newval; printf '\n'
    [ -n "$newval" ] || { c_red "  empty; nothing changed."; return 1; }

    # Compose parses these files itself. A value with whitespace or a '#' is a
    # real hazard there and silently truncates rather than failing, so say so
    # rather than writing something that will look fine and behave oddly.
    case "$newval" in
        *[[:space:]]*|*'#'*)
            c_yell "  NOTE: the value contains whitespace or '#'."
            printf '  Compose truncates at an unquoted # and may keep quotes literally.\n'
            printf '  Continue anyway? [y/N] '
            read -r ans; [ "$ans" = "y" ] || { printf '  stopped; nothing changed.\n'; return 1; }
            ;;
    esac

    # ---- back up, then rewrite in place, preserving mode ----
    bk="${f}.rotate-backup-$(date +%Y%m%d-%H%M%S)"
    umask 077
    priv cp -p "$f" "$bk" || { c_red "  could not back up $f"; return 1; }
    priv chmod 600 "$bk" 2>/dev/null

    tmp="${f}.rotate-tmp.$$"
    # The value goes through a shell variable only. Never an argv (ps reads
    # those), never a sed script, never an echo.
    if [ -w "$f" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$v="*) printf '%s=%s\n' "$v" "$newval" ;;
                *)      printf '%s\n' "$line" ;;
            esac
        done < "$f" > "$tmp"
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 600 "$tmp"
        mv "$tmp" "$f"
    else
        { while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$v="*) printf '%s=%s\n' "$v" "$newval" ;;
                *)      printf '%s\n' "$line" ;;
            esac
          done < <(priv cat "$f"); } > "$tmp"
        priv chmod --reference="$f" "$tmp" 2>/dev/null || priv chmod 600 "$tmp"
        priv chown --reference="$f" "$tmp" 2>/dev/null
        priv mv "$tmp" "$f"
    fi
    unset newval
    c_green "  written to $f (backup: $bk)"

    # ---- recreate exactly the services that read it ----
    if [ -n "$s" ]; then
        printf '  recreating: %s\n' "$s"
        # Two things that are easy to get wrong here and fail quietly.
        #
        # COMPOSE_PROFILES: `docker compose up -d activepieces` fails with
        # "no such service: omniroute-base", because activepieces declares
        # depends_on on a service the vendored compose gates behind the `base`
        # profile. Without the profile active Compose cannot resolve it and
        # refuses the whole command. The list is derived from both compose
        # files rather than hardcoded, so it cannot drift when a profile is
        # added.
        #
        # --no-deps: without it, --force-recreate reaches through depends_on
        # and would recreate the gateway while rotating an Activepieces
        # credential.
        _rcr=0
        # shellcheck disable=SC2086
        COMPOSE_PROFILES="$(all_profiles)" \
            docker compose up -d --no-build --no-deps --force-recreate $s \
            > /tmp/king-rotate-recreate.$$ 2>&1 || _rcr=$?
        tail -3 /tmp/king-rotate-recreate.$$ | sed 's/^/    /'
        rm -f /tmp/king-rotate-recreate.$$
        if [ "$_rcr" -ne 0 ]; then
            c_red "  recreate FAILED — the new value is on disk but the service is still running the old one"
            printf '  Fix the service, then re-run:  ./scripts/king-rotate.sh --plan %s\n' "$v"
            return 1
        fi
    fi

    # ---- prove it ----
    printf '\n  verifying — a revoked key does not announce itself:\n'
    if [ ! -x ./scripts/verify-credentials.sh ]; then
        c_yell "  verify-credentials.sh not executable; rotation NOT recorded."
        printf '  Run it yourself before calling this done.\n'
        return 1
    fi
    # NOT `if ./scripts/verify-credentials.sh | sed ...`. A pipeline returns
    # its LAST command's status, so that tested `sed`, which always succeeds —
    # every rotation would have been recorded as verified no matter what the
    # verification actually said. The safety net was decorative.
    _vrc=0
    _vout=$(./scripts/verify-credentials.sh 2>&1) || _vrc=$?
    printf '%s\n' "$_vout" | sed 's/^/    /'
    case "$_vrc" in
        0)
            c_green "  verification passed."
            printf '%s rotated %s\n' "$v" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE"
            printf '  recorded in %s\n\n' "$STATE"
            ;;
        2)
            # Exit 2 means a service was not answering, so nothing was proved
            # wrong and nothing was proved right. Telling you to roll back here
            # would be the wrong remedy for the wrong diagnosis.
            c_yell "  NOT VERIFIED — a service was not answering. Nothing failed."
            printf '  Do NOT roll back on this alone. Start the service, then:\n'
            printf '    ./scripts/verify-credentials.sh\n'
            printf '  When it passes, record it:  ./scripts/king-rotate.sh --done %s\n\n' "$v"
            return 1
            ;;
        *)
            c_red "  VERIFICATION FAILED — the old value is still in $bk"
            printf '  roll back with:\n    cp -p %s %s\n' "$bk" "$f"
            [ -n "$s" ] && printf '    COMPOSE_PROFILES="%s" docker compose up -d --no-build --no-deps --force-recreate %s\n' "$(all_profiles)" "$s"
            return 1
            ;;
    esac
}

case "${1:---list}" in
    --list|-l)  do_list ;;
    --help|-h)  usage ;;
    --plan)     [ $# -ge 2 ] || { usage; exit 1; }; show_plan "$2" ;;
    --done)     [ $# -ge 2 ] || { usage; exit 1; }
                printf '%s rotated-by-hand %s\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE"
                c_green "  recorded $2 in $STATE" ;;
    -*)         usage; exit 1 ;;
    *)          rotate "$1" ;;
esac
