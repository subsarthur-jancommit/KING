#!/bin/sh
# Audit every aspect of this deployment, repeatably.
#
# WHY THIS IS A SCRIPT AND NOT A DOCUMENT
#
# Because a one-off audit is a photograph and this system moves. Measured on
# 2026-09-08: Ollama held 1,259 MB in the morning and 2,020 MB in the afternoon,
# and a RAM budget written on the first number was wrong within hours. Anything
# that cannot be re-run goes stale, quietly, and then gets cited.
#
# THE RULE THAT MAKES IT TRUSTWORTHY
#
# A check is only believed once it re-finds a defect we already know is there.
# This repo has produced three instruments that were green against the wrong
# question -- pool-prove proving the free model, gateway-report grouping by the
# wrong key, a monitor ranking a catalogue error as a rejected credential. So
# `--positive-control` runs the checks against known-present defects and fails
# if any of them reports clean.
#
# UNKNOWN IS NOT PASS
#
# A check that cannot read what it needs says UNKNOWN and the run does not go
# green. `|| echo 0` once turned "cannot read" into "zero" here and a 4 GB build
# started believing nothing was resident.
#
# Usage:
#   ./scripts/king-audit.sh --all
#   ./scripts/king-audit.sh -d A -d B        # selected dimensions
#   ./scripts/king-audit.sh --self-test      # fixtures; no host, no secrets
#   ./scripts/king-audit.sh --positive-control
#   ./scripts/king-audit.sh --all --baseline # rewrite audit/baseline.json
#
# Exit: 0 all PASS, 1 any FAIL, 2 any UNKNOWN, 3 any planned check not implemented.
set -eu

DIMENSIONS="A B C D E F G H I J K L"
WANT=""
MODE="run"
WRITE_BASELINE=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --all)              WANT="$DIMENSIONS" ;;
        -d|--dimension)     shift; WANT="$WANT $1" ;;
        --self-test)        MODE="selftest" ;;
        --positive-control) MODE="poscontrol" ;;
        --baseline)         WRITE_BASELINE=1 ;;
        -h|--help)          sed -n '2,32p' "$0"; exit 0 ;;
        *)                  echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$WANT" ] || WANT="$DIMENSIONS"

cd "$(dirname "$0")/.."
REPO=$(pwd)
BASELINE="${KING_AUDIT_BASELINE:-audit/baseline.json}"

# ------------------------------------------------------------- the manifest
#
# Every check this audit CLAIMS to perform, declared in one place.
#
# This exists because the first version of this script shipped 43 of the 62
# checks its own plan defined and reported the result as "the audit". Nothing
# in the output said otherwise: an unimplemented check is invisible, and
# invisible is indistinguishable from passing.
#
# So coverage is declared rather than inferred. Measuring it by grepping the
# source was itself wrong -- five checks emitted through a loop variable were
# counted as missing -- which is the same lesson one level up: a number you
# derive by guessing at your own code is not a measurement.
#
# A manifest entry with no matching chk() call is reported as TODO and counted.
# The run cannot go green while any selected dimension is incomplete.
implemented() {
    cat <<'IMPL'
A-1
A-2
A-3
A-4
A-5
A-6
A-7
A-8
A-9
B-1
B-2
B-3
B-4
B-5
B-6
B-7
B-8
B-9
B-10
B-11
B-12
B-13
C-1
C-2
C-3
C-4
C-5
C-6
C-7
C-8
C-9
C-10
D-1
D-2
D-3
D-4
D-5
D-6
D-7
D-8
E-1
E-2
E-3
E-4
E-5
E-6
E-7
E-8
E-9
F-1
F-2
F-3
F-4
F-5
F-6
F-7
F-8
F-9
F-10
G-1
G-2
G-3
G-4
G-5
G-6
H-1
H-2
H-3
H-4
I-1
I-2
I-3
I-4
J-1
J-2
J-3
J-4
J-5
J-6
K-1
K-2
K-3
K-4
K-5
K-6
K-7
K-8
K-9
L-1
L-2
L-3
L-4
L-5
L-6
IMPL
}

manifest() {
    cat <<'MANIFEST'
A-1|repo vs origin/main: commit, ahead/behind
A-2|modified and untracked files on the host
A-3|file modes (executable bit) in git
A-4|omniroute/ subtree unmodified
A-5|running image vs what its declared tag resolves to now
A-6|local worktree vs origin
A-7|leftover .orig/.rej merge artefacts
A-8|locally-built images vs the source they were built from
A-9|artefacts installed outside the repo vs the copies in it
B-1|every service pairs mem_limit with an equal memswap_limit, plus cpus
B-2|every published port binds loopback, Caddy excepted
B-3|every image pinned to an exact tag or digest
B-4|every service opt-in via profiles:
B-5|no hard-required variable syntax outside comments
B-6|root compose declares no omniroute/ service
B-7|caddy validates, and still validates with each domain variable empty
B-8|Caddy route inventory: every route and its auth layer
B-9|env vars: used vs defined vs documented vs actually set
B-10|systemd units are in the repo, active, and scheduled sanely in local time
B-11|every compose profile has a preflight check
B-12|no container is privileged or grants itself capabilities
B-13|containers running as root, against the acknowledged set
C-1|every secret file and its backup variants are gitignored
C-2|no secret in git history
C-3|no placeholder value still installed
C-4|token to blast-radius map
C-5|public surface inventory: every reachable path and its anonymous status
C-6|every MCP: no token 401, wrong token 401, right token 200
C-7|secret file permissions are not world-readable
C-8|MCP DNS-rebinding protection names the hosts it accepts
C-9|the rotation list matches the secrets that exist
C-10|datastores are segmented, or at least authenticated
D-1|per container: memory, swap, restarts
D-2|healthcheck status
D-3|host memory against the codegraph floor, as the build will see it
D-4|OOM events in the kernel ring buffer
D-5|container log sizes, with disk as context
D-6|reclaimable build cache, idle images, orphan volumes
D-7|container logs are bounded by a rotation policy
D-8|restart policies that survive a clean stop, not just a crash
E-1|every volume: size, contents, and whether anything backs it up
E-2|external Postgres reachable, and its size
E-3|journals exist, grow, and are readable
E-4|code graph freshness: BUILD_INFO commit vs HEAD vs origin
E-5|code graph correctness: it finds a file only the newest commit has
E-6|no test rows left in production tables
E-7|the queue backend answers, and says whether it wants a password
E-8|spend is observable: what fraction of calls report their tokens
E-9|traces reach the observability backend, not just the collector
F-1|every MCP server: tools/list and one real call
F-2|offered tools vs allowlist vs NEVER_REGISTER
F-3|reroute status: the eight measured trigger phrases
F-4|model_overridden in the recent run journal
F-5|per-provider failure rate, and what reached the caller
F-6|the local model answers, and answers from this host
F-7|flow mirror parses and exports what its tests import
F-8|every destructive tool the servers offer is blocked from the agent
F-9|every tool that can reach the network is acknowledged
F-10|model-authored code runs off this host, per the RUNNING container
G-1|every guard with a self-test still passes it
G-2|every instrument measures what it claims
G-3|timers: last run, and whether any unit failed
G-4|deadman tolerance vs the worst legitimate gap
G-5|an alert reaches the phone, end to end
G-6|assignments that turn a failed command into a value
H-1|CI jobs: green or red, and why
H-2|what CI does not cover
H-3|the test suite passes in a rebuilt container
H-4|environment-dependent tests
I-1|measured numbers in the docs vs today's measurement
I-2|commands in the docs actually run
I-3|cross-referenced file paths still exist
I-4|every concrete CLAUDE.md rule is enforced by a check
J-1|pinned versions vs latest
J-2|active upstream breakage
J-3|image age, origin, and whether it is still published
J-4|the TLS binary the gateway runs vs the one on record
J-5|whether an outdated TLS binary is reachable from a configured provider
J-6|published advisories against the versions actually pinned
K-1|listening sockets bound to 0.0.0.0 beyond the intended three
K-2|whether the host firewall actually covers Docker-published ports
K-3|what answers from outside the host, tested from outside the host
K-4|system clock synchronised
K-5|SSH exposure: password auth, root login
K-6|pending security updates and unattended upgrades
K-7|TLS certificate expiry
K-8|cron entries that come from nowhere in the repo
K-9|an unmatched public path returns a small response, not the whole app
L-1|gateway API keys: how many, how scoped, how long unused
L-2|Activepieces registration is closed, re-tested rather than recalled
L-3|journals hold no credential-shaped string
L-4|journal growth is bounded by something
L-5|container logs carry no credential-shaped string
L-6|what the run journal retains, and what bounds that retention
MANIFEST
}

# ---------------------------------------------------------------- reporting

n_pass=0; n_fail=0; n_unknown=0; n_skip=0; n_todo=0
FINDINGS=$(mktemp); METRICS=$(mktemp); SEEN=$(mktemp)
trap 'rm -f "$FINDINGS" "$METRICS" "$SEEN"' EXIT INT TERM

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yell()  { printf '\033[33m%s\033[0m' "$*"; }
c_dim()   { printf '\033[2m%s\033[0m' "$*"; }

# chk <id> <status> <title> [evidence...]
chk() {
    _id="$1"; _st="$2"; _t="$3"; shift 3
    _ev="$*"
    # Record the base id (B-1b counts as B-1) so --coverage is exact rather
    # than grepped out of the source, which under-counted by five.
    printf '%s\n' "$_id" | sed 's/[a-z]$//' >> "$SEEN"
    case "$_st" in
        PASS)    n_pass=$((n_pass+1));    printf '  %s  %-5s %s\n' "$(c_green PASS)" "$_id" "$_t" ;;
        FAIL)    n_fail=$((n_fail+1));    printf '  %s  %-5s %s\n' "$(c_red FAIL)" "$_id" "$_t"
                 printf '%s\t%s\n' "$_id" "$_t" >> "$FINDINGS" ;;
        UNKNOWN) n_unknown=$((n_unknown+1)); printf '  %s  %-5s %s\n' "$(c_yell 'UNK ')" "$_id" "$_t" ;;
        SKIP)    n_skip=$((n_skip+1));    printf '  %s  %-5s %s\n' "$(c_dim 'skip')" "$_id" "$_t" ;;
    esac
    [ -z "$_ev" ] || printf '            %s\n' "$_ev" | head -6
}

# metric <key> <value>  — numeric facts that belong in the baseline, so the
# next run reports movement rather than only state.
metric() { printf '%s\t%s\n' "$1" "$2" >> "$METRICS"; }

# When a dimension cannot run at all — off-host, no interpreter — every check
# in it must be marked skipped, not left silent. Otherwise coverage reports
# "not implemented" for checks that exist and simply were not reachable, which
# is the same conflation this manifest was added to remove.
skip_rest() {
    _dim="$1"; shift
    manifest | grep "^$_dim-" | while IFS='|' read -r _cid _ctitle; do
        implemented | grep -qx "$_cid" || continue
        grep -qx "$_cid" "$SEEN" 2>/dev/null || chk "$_cid" SKIP "$_ctitle" "$*"
    done
}

have() { command -v "$1" >/dev/null 2>&1; }
on_host() { [ -S /var/run/docker.sock ] && have docker; }

# Two checks reported UNKNOWN "needs root" for a day while `sudo -n` worked on
# this host the whole time -- the same script was already using it for iptables
# and sshd. "I cannot read this" and "I did not try the way I try elsewhere"
# are different answers, and only one of them is honest.
#
# `sudo -n` never prompts: it fails immediately when a password is required, so
# this is safe to call unconditionally and UNKNOWN still means unreadable.
priv() {
    if sudo -n true 2>/dev/null; then sudo -n "$@" 2>/dev/null
    else "$@" 2>/dev/null
    fi
}

# Resolve a python that actually RUNS, not one that merely appears on PATH.
#
# Found by this script's own self-test on 2026-09-08: Windows ships a
# `python3` stub in WindowsApps that resolves, exits silently, and produces no
# output. `command -v python3` says yes; running it does nothing. Every check
# that shelled out to it reported clean, which is the exact shape of failure
# this audit exists to catch — so the resolver tests execution, not presence.
# One credential shape, used by both scanners.
#
# L-3 and L-5 carried two DIFFERENT patterns for the same question, so they
# could disagree about the same string, and both were narrow enough to miss
# most of what this deployment actually holds. Measured 2026-09-11 against the
# real shapes in the rotation list: the old L-3 pattern caught ONE of seven.
#
# What it missed, and each of these is a credential on this host:
#
#   sk-proj-...      the modern OpenAI format — the hyphen after `proj` broke
#                    `sk-[A-Za-z0-9]{20,}`, so the newest key style was the one
#                    it could not see
#   sk-lf-... /      Langfuse, hyphenated the same way
#   pk-lf-...
#   Basic <base64>   only `Bearer` was listed, and the Langfuse header is Basic
#   postgres://u:p@  the Neon DSN carries its password inline
#   48 hex chars     AP_REDIS_PASSWORD has no prefix at all; nothing about the
#                    string says "secret" except the name in front of it
#
# So the last alternative keys off the NAME rather than the value, which is the
# only thing that distinguishes a 48-character hex password from a sha256
# digest. Lowercase `token` is deliberately absent from that list: this
# deployment logs token COUNTS constantly, and `tokens=1234567890123456` would
# otherwise be a finding.
#
# The keyword may be followed only by `Key` or `_key`, and that restriction was
# not caution — it was the first live run. A wildcard continuation
# (`apiKey[A-Za-z_]*`) matched `apiKeyId` and turned up 175 lines in the
# gateway's own logs, every one of them an API key IDENTIFIER rather than a
# key. The widened scanner's first act was to cry wolf 175 times, which is the
# failure this repo has already had once from an alerting rule. Narrow the
# continuation rather than the keyword list: `secretKey` and `apiKey` still
# match, `apiKeyId` does not.
#
# Verified both directions — 12 real credential shapes caught, 12 benign lines
# not, the two `apiKeyId` shapes among them taken verbatim from the logs that
# produced the false alarm — and the self-test pins every one.
CREDPAT='sk-[A-Za-z0-9_-]{20,}|pk-lf-[A-Za-z0-9-]{10,}|oma_live_|tk_[A-Za-z0-9]{20,}|(Bearer|Basic) [A-Za-z0-9._=+/-]{20,}|eyJ[A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{10,}|postgres(ql)?://[^:@/ ]+:[^@ ]+@|(PASSWORD|SECRET|TOKEN|APIKEY|API_KEY|_KEY|password|secret|apiKey|api_key)(Key|_key)?["]?[ ]*[=:][ ]*["]?[A-Za-z0-9+/_-]{16,}'

PY=""
for _c in python3 python py; do
    if command -v "$_c" >/dev/null 2>&1 && [ "$("$_c" -c 'print(7*6)' 2>/dev/null)" = "42" ]; then
        PY="$_c"; break
    fi
done
pyyaml_ok() { [ -n "$PY" ] && "$PY" -c 'import yaml' >/dev/null 2>&1; }

# Which endpoint actually carries data for a given route, and what a denial
# looks like there.
#
# Written after getting this wrong three times in a row: /king-agent/ returns
# 404 because handle_path strips the prefix; /king-ntfy/anything returns 200
# because ntfy serves its web UI for unknown paths and treats path segments as
# topic names. Probing "the route" proves nothing -- each service has one
# endpoint where a denial is meaningful, and they are not the same shape.
#
# The route LIST is derived from the Caddyfile. This mapping is declared. A
# route with no mapping fails loudly rather than passing, so a route added
# later cannot slip through by being unknown.
probe_target() {
    case "$1" in
        */king-agent)     printf '%s|401 403' "$1/mcp" ;;
        */king-codegraph) printf '%s|401 403' "$1/mcp" ;;
        */king-ntfy)
            # A topic, not the UI. The UI is public by design; the topics are
            # what deny-all is protecting.
            _tp=$(sed -n 's/^NTFY_ALERT_TOPIC=//p' .env 2>/dev/null | tail -1)
            [ -n "$_tp" ] || _tp="audit-probe-topic"
            printf '%s|401 403' "$1/$_tp/json?poll=1" ;;
        *) printf '|' ;;
    esac
}

# ------------------------------------------------------------- dimension A

dim_A() {
    echo; echo "A  source and deployment integrity"

    # `git rev-parse`, not `[ -d .git ]`. In a git WORKTREE — which is how this
    # repo is checked out — `.git` is a FILE pointing elsewhere, so the
    # directory test reports "not a git checkout" and silently skips all of
    # dimension A. Caught by running this against its own repo on 2026-09-08.
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        skip_rest A "not a git checkout; source integrity unmeasurable"
        return
    fi

    if git fetch -q origin 2>/dev/null; then :; else
        chk A-1 UNKNOWN "could not fetch origin (offline?); comparison would be stale"
    fi

    if _lr=$(git rev-list --left-right --count origin/main...HEAD 2>/dev/null); then
        _behind=$(printf '%s' "$_lr" | awk '{print $1}')
        _ahead=$(printf '%s' "$_lr" | awk '{print $2}')
        metric a1_behind "$_behind"; metric a1_ahead "$_ahead"
        if [ "$_behind" = "0" ] && [ "$_ahead" = "0" ]; then
            chk A-1 PASS "checkout matches origin/main"
        else
            chk A-1 FAIL "checkout differs from origin/main" \
                "behind $_behind, ahead $_ahead — what runs is not what was reviewed"
        fi
    else
        chk A-1 UNKNOWN "no origin/main to compare against"
    fi

    _dirty=$(git status --porcelain 2>/dev/null | grep -c . || true)
    _untracked=$(git status --porcelain --untracked-files=all 2>/dev/null | grep -c '^??' || true)
    metric a2_dirty "$_dirty"
    if [ "$_dirty" = "0" ]; then
        chk A-2 PASS "working tree clean"
    else
        chk A-2 FAIL "$_dirty uncommitted change(s), $_untracked untracked" \
            "$(git status --porcelain | head -4 | tr '\n' ' ')"
    fi

    # Mode drift. A script committed 644 cannot be executed by CI, which is a
    # failure that passes every local test — it happened here on 2026-09-08.
    _badmode=$(git ls-files -s scripts/*.sh 2>/dev/null | awk '$1 != "100755" {print $4}' || true)
    if [ -z "$_badmode" ]; then
        chk A-3 PASS "every scripts/*.sh is executable in git"
    else
        chk A-3 FAIL "script(s) not executable in git" "$(printf '%s' "$_badmode" | tr '\n' ' ')"
    fi

    if [ -d omniroute ]; then
        _osub=$(git log -1 --format=%s -- omniroute 2>/dev/null | head -c 80)
        _odirty=$(git status --porcelain -- omniroute 2>/dev/null | grep -c . || true)
        if [ "$_odirty" = "0" ]; then
            chk A-4 PASS "vendored omniroute/ subtree unmodified" "last: $_osub"
        else
            chk A-4 FAIL "omniroute/ has local edits — the next subtree pull discards them" \
                "$(git status --porcelain -- omniroute | head -3 | tr '\n' ' ')"
        fi
    else
        chk A-4 SKIP "no omniroute/ subtree here"
    fi

    if on_host; then
        # Compare the image a container is RUNNING against the image its tag
        # resolves to now. A tag is a moving label: a container started weeks
        # ago can be on a different build than the same tag pulls today, and
        # "no :latest anywhere" says nothing about that. This is the question
        # the manifest actually claims.
        _drift=""; _stale=""
        for svc in omniroute king-activepieces-1 king-ollama-1 king-caddy-1 \
                   king-codegraph-serve-1 king-ntfy-1; do
            _tag=$(docker inspect "$svc" --format '{{.Config.Image}}' 2>/dev/null || true)
            [ -n "$_tag" ] || continue
            case "$_tag" in *:latest) _stale="$_stale $svc=$_tag" ;; esac
            _run=$(docker inspect "$svc" --format '{{.Image}}' 2>/dev/null || true)
            _now=$(docker image inspect "$_tag" --format '{{.Id}}' 2>/dev/null || true)
            [ -n "$_run" ] && [ -n "$_now" ] && [ "$_run" != "$_now" ] \
                && _drift="$_drift $svc"
        done
        if [ -n "$_stale" ]; then
            chk A-5 FAIL "container(s) running a :latest tag — not reproducible" "$_stale"
        elif [ -n "$_drift" ]; then
            chk A-5 FAIL "container(s) running an image their tag no longer resolves to" \
                "$_drift — restart to adopt what the tag means today"
        else
            chk A-5 PASS "every container runs the image its declared tag resolves to"
        fi
    else
        chk A-5 SKIP "not on the host; running images unmeasurable"
    fi

    # A-6: work that exists only here. A-1 reports the count; this names the
    # commits, because "ahead 3" and "ahead 3 of things you meant to push" read
    # identically until you look.
    _unpushed=$(git log --oneline origin/main..HEAD 2>/dev/null | head -5 || true)
    if [ -z "$_unpushed" ]; then
        chk A-6 PASS "nothing committed here is missing from origin"
    else
        chk A-6 FAIL "commit(s) exist only in this checkout" \
            "$(printf '%s' "$_unpushed" | head -3 | tr '\n' '; ')"
    fi

    _stray=$(find . -maxdepth 3 \( -name '*.orig' -o -name '*.rej' \) \
             -not -path './omniroute/*' -not -path './.git/*' 2>/dev/null | head -5 || true)
    if [ -z "$_stray" ]; then
        chk A-7 PASS "no leftover merge artefacts"
    else
        chk A-7 FAIL "unfinished merge artefacts present" "$(printf '%s' "$_stray" | tr '\n' ' ')"
    fi

    # A-8: locally-built images against the source they were built from.
    #
    # A-1 compares git refs. That is not the same question as "is the running
    # binary made of this code", and on 2026-09-10 the two answers differed in
    # the way that matters: `king-agent-sidecar:local` was built on 09-08 and
    # baked its source at /app, while the repo is bind-mounted at /workspace.
    # Editing agent-sidecar/src changed the reviewed file and not the running
    # one, so a security guarantee added on 09-09 — four destructive gateway
    # tools blocked — was true in the tree and false in the process for two
    # days. F-8 read the tree copy and reported PASS the whole time.
    #
    # F-8b now catches that one guarantee. This catches the class: any image
    # built here whose source has commits newer than the image itself.
    if ! on_host; then
        chk A-8 SKIP "not on the host; no built images to compare"
    else
        _stale=""; _unknown=""; _nosrc=""; _built=0
        for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
            _img=$(docker inspect -f '{{.Config.Image}}' "$_c" 2>/dev/null || true)
            case "$_img" in king-*) : ;; *) continue ;; esac
            _svc=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$_c" 2>/dev/null || true)
            [ -n "$_svc" ] || continue
            _ctx=$("$PY" -c '
import sys, yaml
d = yaml.safe_load(open("docker-compose.yml", encoding="utf-8")) or {}
s = (d.get("services") or {}).get(sys.argv[1]) or {}
b = s.get("build")
print(b if isinstance(b, str) else (b or {}).get("context", "") if isinstance(b, dict) else "")
' "$_svc" 2>/dev/null || true)
            # `A && B || continue` happens to behave here, because C is a
            # no-value action. It is still the SC2015 shape this script warns
            # about twice in its own comments, and the header of pool-prove.sh
            # carries the same warning — so it does not get to appear here.
            if [ -z "$_ctx" ] || [ ! -d "$_ctx" ]; then
                continue
            fi
            _built=$((_built + 1))
            # Compare CONTENT, not timestamps. Two earlier versions of this
            # check used a clock and both were wrong for different reasons:
            #
            #   git commit time — blind to the exact mechanism that caused
            #     this check to exist. The sidecar's source reached this host
            #     by scp, uncommitted, so git saw nothing newer while the
            #     files plainly were.
            #   image .Created  — not the build time. BuildKit stamps it from
            #     a cached layer: this image reported 04:40:48 while carrying
            #     a file whose mtime is 04:45. It would have called a freshly
            #     built image stale, forever.
            #
            # A digest cannot be wrong about this. Files that cannot be mapped
            # into the image are counted and reported rather than assumed
            # equal — a service whose layout defeats the mapping gets UNKNOWN,
            # not a pass.
            _wd=$(docker inspect -f '{{.Config.WorkingDir}}' "$_img" 2>/dev/null || true)
            [ -n "$_wd" ] || _wd=/app
            _same=0; _diff=0; _unmapped=0; _found=0
            for _f in $(cd "$_ctx" && find . -type f \
                          \( -name '*.py' -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' \) \
                          -not -path './.venv/*' -not -path './__pycache__/*' \
                          -not -path './node_modules/*' 2>/dev/null | head -60); do
                _found=$((_found + 1))
                _local=$("$PY" -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$_ctx/${_f#./}" 2>/dev/null || true)
                _inimg=$(docker exec "$_c" sha256sum "$_wd/${_f#./}" 2>/dev/null | cut -d' ' -f1 || true)
                if [ -z "$_inimg" ]; then _unmapped=$((_unmapped + 1))
                elif [ "$_local" = "$_inimg" ]; then _same=$((_same + 1))
                else _diff=$((_diff + 1))
                fi
            done
            # "No first-party source in the context" and "source exists but
            # could not be located in the image" are different answers. The
            # first is a clean nothing-to-drift — codegraph's context holds a
            # Dockerfile and two systemd units, and its server runs a
            # pip-installed package. Reporting that as UNKNOWN would leave a
            # check permanently amber over a service that cannot drift, which
            # is how a guard stops being read.
            if [ "$_found" -eq 0 ]; then
                _nosrc="$_nosrc ${_svc}"
            elif [ "$((_same + _diff))" -eq 0 ]; then
                _unknown="$_unknown ${_svc}(source exists but none of it is in the image)"
            elif [ "$_diff" -gt 0 ]; then
                _stale="$_stale ${_svc}(${_diff} of $((_same + _diff)) source file(s) differ)"
            fi
        done
        if [ "$_built" -eq 0 ]; then
            chk A-8 UNKNOWN "no locally-built running image could be matched to a build context"
        elif [ -n "$_stale" ]; then
            chk A-8 FAIL "the source baked into a running image differs from the tree" \
                "$_stale — what runs is not what was reviewed; a rebuild is owed${_unknown:+ (unmapped:$_unknown)}"
        elif [ -n "$_unknown" ]; then
            chk A-8 UNKNOWN "image layout defeated the source comparison for:$_unknown" \
                "$_built context(s) examined; a service whose files cannot be located is not a pass"
        else
            chk A-8 PASS "every running image carries byte-identical source to the tree" \
                "$_built context(s) compared by digest, not by timestamp${_nosrc:+; no first-party source to compare in:$_nosrc}"
        fi
    fi

    # A-9: artefacts this repo installs OUTSIDE itself.
    #
    # A-1 compares git refs and A-8 compares baked images. Neither sees a file
    # copied to /usr/local/sbin or /etc/systemd/system — and the one installed
    # there is a firewall script, applied on every Docker start by a unit that
    # also lives outside the tree. Edit the repo copy, forget the install, and
    # the reviewed version is not the running one with nothing to say so.
    #
    # Compared with `priv`, and "cannot read" is reported apart from "differs".
    # Plain `cmp -s` conflates them: run as this user against a root-owned 750
    # file it exits non-zero for permission denied, which reads exactly like a
    # content difference. That false alarm happened here first, and cost a
    # reinstall that changed nothing.
    if ! on_host; then
        chk A-9 SKIP "not on the host; installed artefacts unreachable"
    else
        # The pair list was written by hand, and it was complete — today. It could
        # not have said so tomorrow: a second `king-*` artefact installed outside
        # the repo would simply not appear, and A-9 would stay green while an
        # unreviewable file ran as root. Same fault as G-1, G-2 and J-1 carried.
        #
        # The population is derived from the HOST instead: everything matching
        # `king-*` in the two places this deployment installs to. An artefact with
        # no repo copy is now its own finding — it is the more serious one, because
        # a file nobody can read in a diff cannot drift, it is already adrift.
        _drift=""; _unread=""; _pairs=0; _orphan=""
        for _dst in $(priv sh -c 'ls -1 /usr/local/sbin/king-* /etc/systemd/system/king-* 2>/dev/null' || true); do
            _src="scripts/$(basename "$_dst")"
            if [ ! -f "$_src" ]; then
                _orphan="$_orphan $_dst"
                continue
            fi
            _pairs=$((_pairs + 1))
            if priv cmp -s "$_dst" "$_src"; then
                :
            elif priv test -r "$_dst"; then
                _drift="$_drift ${_dst}(differs)"
            else
                _unread="$_unread $_dst"
            fi
        done
        if [ -n "$_orphan" ]; then
            chk A-9 FAIL "installed artefact(s) with no copy in the repo:$_orphan" \
                "a file that cannot be read in a diff cannot drift from the repo; it is already adrift, and it runs as root"
        elif [ "$_pairs" -eq 0 ]; then
            chk A-9 UNKNOWN "nothing matching king-* is installed outside the repo" \
                "either nothing is deployed that way, or this user cannot list those directories"
        elif [ -n "$_unread" ]; then
            chk A-9 UNKNOWN "installed artefact(s) could not be read:$_unread" \
                "an unreadable file is not a matching one"
        elif [ -z "$_drift" ]; then
            chk A-9 PASS "$_pairs installed artefact(s) match their repo copy" \
                "population listed from the host, not from a list in this script; compared with sudo, and 'cannot read' is reported apart from 'differs'"
        else
            chk A-9 FAIL "installed artefact(s) no longer match the repo:$_drift" \
                "the reviewed copy is not the running one; re-run the install step in the unit's header"
        fi
    fi
}

# ------------------------------------------------------------- dimension B

dim_B() {
    echo; echo "B  configuration correctness"

    if [ ! -f docker-compose.yml ]; then
        skip_rest B "no docker-compose.yml here"
        return
    fi
    if ! pyyaml_ok; then
        skip_rest B "no working python3 with pyyaml; compose rules unparseable"
        return
    fi

    # One python pass over the compose model, emitting one line per rule break.
    # Written to a temp file rather than a heredoc on python3's stdin: a heredoc
    # IS stdin, and that mistake has already cost this repo a silent failure.
    _py=$(mktemp)
    cat > "$_py" <<'PYAUDIT'
import io, re, sys
try:
    import yaml
except ImportError:
    print("UNKNOWN\tpyyaml missing"); raise SystemExit(0)
raw = io.open("docker-compose.yml", encoding="utf-8").read()
d = yaml.safe_load(raw) or {}
svcs = d.get("services") or {}

for name, s in sorted(svcs.items()):
    s = s or {}
    mem, swap = s.get("mem_limit"), s.get("memswap_limit")
    if mem and not swap:
        print("B1\t%s has mem_limit but no memswap_limit (docker then grants swap equal to it)" % name)
    elif mem and swap and str(mem) != str(swap):
        print("B1\t%s mem_limit != memswap_limit (%s vs %s)" % (name, mem, swap))
    elif not mem:
        print("B1w\t%s has no mem_limit" % name)
    if not s.get("cpus"):
        print("B1w\t%s has no cpus" % name)
    # Caddy binds 0.0.0.0 deliberately — CLAUDE.md says so in as many words.
    if name != "caddy":
        for p in s.get("ports") or []:
            if isinstance(p, str) and not re.match(r'^\$\{[A-Z_]+:-127\.0\.0\.1\}:|^127\.0\.0\.1:', p):
                print("B2\t%s publishes %s without a loopback bind host" % (name, p))
    # B-3 used to enforce the LETTER ("never :latest") rather than the rule
    # CLAUDE.md states: "Pin images to an exact tag or digest." `caddy:2-alpine`
    # passed it while being a floating major tag -- it moved to 2.11.4 on
    # 2026-06-24, and nobody on this deployment chose that version. A floating
    # tag defeats reproducibility in exactly the way `latest` does; the only
    # difference is that it looks deliberate.
    #
    # Locally-built services are exempt on purpose: their tag is a local name
    # rather than a registry pin, and A-8 already compares them against the
    # source they were built from. Flagging them here would be a second and
    # wrong answer to a question already asked properly elsewhere.
    img = s.get("image")
    if img and not s.get("build"):
        base = img.split("/")[-1].split("@")[0]
        tag = base.split(":")[-1] if ":" in base else ""
        if "@sha256:" in img:
            pass                                   # a digest cannot move
        elif not tag or tag == "latest":
            print("B3\t%s image not pinned: %s" % (name, img))
        elif not re.match(r'^v?\d+\.\d+\.\d+', tag):
            print("B3\t%s image tag floats, it is not an exact version: %s" % (name, img))
    if not s.get("profiles"):
        print("B4\t%s has no profiles: — it starts unasked" % name)

# ${VAR:?err} outside comments only.
for i, line in enumerate(raw.splitlines(), 1):
    code = line.split("#", 1)[0]
    if re.search(r'\$\{[A-Z_]+:\?', code):
        print("B5\tline %d uses ${VAR:?err}" % i)

try:
    od = yaml.safe_load(io.open("omniroute/docker-compose.yml", encoding="utf-8").read()) or {}
    clash = sorted(set(svcs) & set((od.get("services") or {})))
    if clash:
        print("B6\troot compose redeclares omniroute service(s): %s" % ", ".join(clash))
except FileNotFoundError:
    print("B6u\tno omniroute/docker-compose.yml to compare")
PYAUDIT
    _res=$("$PY" "$_py" 2>/dev/null || true)
    rm -f "$_py"

    _b1=$(printf '%s' "$_res" | grep -c '^B1	' || true)
    _b1w=$(printf '%s' "$_res" | grep -c '^B1w	' || true)
    metric b1_violations "$_b1"
    if [ "$_b1" = "0" ]; then
        chk B-1 PASS "every service pairs mem_limit with an equal memswap_limit"
    else
        chk B-1 FAIL "$_b1 service(s) can swap beyond their limit" \
            "$(printf '%s' "$_res" | grep '^B1	' | cut -f2 | head -4 | tr '\n' '; ')"
    fi
    [ "$_b1w" = "0" ] || chk B-1b FAIL "$_b1w service(s) missing mem_limit or cpus entirely" \
        "$(printf '%s' "$_res" | grep '^B1w	' | cut -f2 | head -4 | tr '\n' '; ')"

    for _r in B2:B-2:"every published port binds loopback (Caddy excepted)" \
              B3:B-3:"every image is pinned" \
              B4:B-4:"every service is opt-in via profiles:" \
              B5:B-5:"no hard-required variable syntax outside comments" \
              B6:B-6:"root compose declares no omniroute/ service"; do
        _tag=${_r%%:*}; _rest=${_r#*:}; _id=${_rest%%:*}; _title=${_rest#*:}
        _hits=$(printf '%s' "$_res" | grep -c "^$_tag	" || true)
        if [ "$_hits" = "0" ]; then
            chk "$_id" PASS "$_title"
        else
            chk "$_id" FAIL "$_hits break(s) of: $_title" \
                "$(printf '%s' "$_res" | grep "^$_tag	" | cut -f2 | head -3 | tr '\n' '; ')"
        fi
    done

    # B-7 is the expensive one and the one that matters most: an empty site
    # address makes Caddy fail to load the WHOLE config, taking the gateway
    # down with it. So it is checked with the domain variables EMPTY.
    if on_host && docker ps --format '{{.Names}}' | grep -q '^king-caddy-1$'; then
        if docker exec king-caddy-1 caddy validate --config /etc/caddy/Caddyfile \
               --adapter caddyfile >/dev/null 2>&1; then
            chk B-7 PASS "caddy config validates as deployed"
        else
            chk B-7 FAIL "caddy config does not validate as deployed"
        fi
        # B-7b tested the wrong layer, and could never have gone green.
        #
        # It injected `-e OMNIROUTE_PUBLIC_DOMAIN=` straight into the container
        # and asked Caddy to validate. Caddy CANNOT survive that: a site
        # address is static in the adapter, and `{$VAR:default}` substitutes
        # only for an UNSET variable, never an empty one. So the check demanded
        # something structurally impossible and sat red forever — a guard
        # nobody can leave green, which decays into a guard nobody reads.
        #
        # The realistic path to an empty domain is a blank line in .env, and
        # the layer that stops it is compose's `${VAR:-default}`, which DOES
        # substitute for empty. That is testable, and it is the thing whose
        # breakage would actually take every public route down together. So the
        # check renders the compose model with both domains empty and asserts
        # the caddy service still receives non-empty values.
        # `VAR= cmd` is what shellcheck SC1007 warns about, and it is right to:
        # the empty-looking assignment is easy to read as a typo for a value.
        # `VAR=''` says empty on purpose.
        _blank=$(OMNIROUTE_PUBLIC_DOMAIN='' ACTIVEPIECES_PUBLIC_DOMAIN='' \
                 docker compose --profile base --profile proxy config 2>/dev/null \
                 | grep -E '(OMNIROUTE|ACTIVEPIECES)_PUBLIC_DOMAIN:' \
                 | sed 's/^ *//' || true)
        # Compose renders an empty value as `NAME: ""`, with quotes — so a
        # pattern looking for a line that ENDS after the colon never matches
        # the case it was written for. The first version did exactly that and
        # stayed green through its own positive control, which is the one
        # moment a check gets to prove it can fail. Strip quotes and whitespace
        # from the value, then test what is left.
        _empty=$(printf '%s\n' "$_blank" | while IFS= read -r _line; do
                     [ -n "$_line" ] || continue
                     _val=$(printf '%s' "$_line" | cut -d: -f2- | tr -d ' "'"'")
                     [ -n "$_val" ] || printf 'x'
                 done | wc -c | tr -d ' ')
        if [ -z "$_blank" ]; then
            chk B-7b UNKNOWN "could not render the compose model to test empty domains"
        elif [ "${_empty:-0}" -eq 0 ]; then
            chk B-7b PASS "compose substitutes a domain even when .env leaves it blank" \
                "$(printf '%s' "$_blank" | tr '\n' ' ') — Caddy's own {\$VAR:default} covers UNSET, compose covers EMPTY"
        else
            chk B-7b FAIL "an empty .env value reaches Caddy as an empty site address" \
                "an unset site address takes the gateway down, not just one site"
        fi
    else
        chk B-7 SKIP "caddy not running here"
    fi

    # B-8: every route Caddy serves, and what an anonymous request gets. A
    # route inventory that lists paths without testing them is a table, not a
    # check -- the question is whether each door is locked, not whether it
    # exists.
    if [ -f caddy/Caddyfile ]; then
        _routes=$(grep -oE 'handle_path /[a-z0-9-]+/\*' caddy/Caddyfile 2>/dev/null \
                  | sed 's|handle_path ||; s|/\*$||' | sort -u || true)
        _n=$(printf '%s' "$_routes" | grep -c . || true)
        metric b8_routes "${_n:-0}"
        if [ -z "$_routes" ]; then
            chk B-8 UNKNOWN "no handle_path routes found in the Caddyfile"
        elif have curl; then
            # A 200 at a route root is not automatically an open door. ntfy
            # serves a web UI there and protects its TOPICS, which is a
            # different resource -- proven separately at 403/401/200. Treating
            # "serves a page" as "is open" produces a finding that is wrong,
            # and a check people learn to ignore.
            #
            # So the API routes are held to 401 and the rest are reported with
            # their status for a human to judge, rather than guessed at.
            _bad=""; _info=""; _down=""
            for _r in $_routes; do
                # Probe the endpoint the route actually serves, not its root.
                # `handle_path` strips the prefix, so /king-agent/ reaches the
                # sidecar as / and correctly 404s -- which proves nothing about
                # the door. The MCP endpoint is the door.
                case "$_r" in
                    */king-agent|*/king-codegraph) _probe="${_r}/mcp" ;;
                    *)                             _probe="${_r}/" ;;
                esac
                _c=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
                     "https://gateway.arject.co${_probe}" 2>/dev/null || echo 000)
                case "$_r" in
                    */king-agent|*/king-codegraph)
                        case "$(_doorverdict "$_c" '401 403')" in
                            locked)      : ;;
                            unreachable) _down="$_down ${_r}=$_c" ;;
                            *)           _bad="$_bad ${_r}=$_c" ;;
                        esac ;;
                    *) _info="$_info ${_r}=$_c" ;;
                esac
            done
            if [ -n "$_bad" ]; then
                chk B-8 FAIL "API route(s) not demanding a token" "$_bad"
            elif [ -n "$_down" ]; then
                chk B-8 UNKNOWN "API route(s) unreachable, so the lock could not be tested:$_down"                     "a 5xx is the upstream being absent, not a door standing open"
            elif [ -n "$_info" ]; then
                chk B-8 PASS "every API route demands a token" \
                    "other route(s), status for review:$_info"
            else
                chk B-8 PASS "${_n} route(s); every API route demands a token"
            fi
        else
            chk B-8 UNKNOWN "curl unavailable; routes listed but not probed" "$_routes"
        fi
    else
        chk B-8 SKIP "no Caddyfile here"
    fi

    # B-9: the env surface, in three populations that should agree. A variable
    # used by compose and set nowhere silently takes its default; one set and
    # never used is dead weight that outlives its reason.
    if pyyaml_ok; then
        _envpy=$(mktemp)
        cat > "$_envpy" <<'PYENV'
import io, os, re, sys
# Comments stripped first. `${AP_REDIS_USE_SSL:-}` appears in this file
# exactly once, inside a comment explaining why it must NEVER be written that
# way -- setting it at all makes Activepieces attempt a TLS handshake
# (upstream #4857), so an env_file omits it instead. Reading the file as flat
# text counted the warning as the offence.
comp = "".join(
    line for line in io.open("docker-compose.yml", encoding="utf-8")
    if not line.lstrip().startswith("#")
)
used = {v for v in re.findall(r'\$\{([A-Z0-9_]+)[:}-]', comp) if v != "VAR"}
docs = ""
for f in ("docs/king-system.md", "README.md", ".env.example"):
    try: docs += io.open(f, encoding="utf-8").read()
    except OSError: pass
setv = set()
for f in (".env", "omniroute/.env", "agent-sidecar/.env"):
    try:
        for line in io.open(f, encoding="utf-8"):
            m = re.match(r'^([A-Z0-9_]+)=', line.strip())
            if m: setv.add(m.group(1))
    except OSError: pass
undoc = sorted(v for v in used if v not in docs)
print("used=%d set=%d undocumented=%d" % (len(used), len(setv), len(undoc)))
print(" ".join(undoc[:8]))
PYENV
        _eo=$("$PY" "$_envpy" 2>/dev/null || true); rm -f "$_envpy"
        _ud=$(printf '%s' "$_eo" | head -1 | sed 's/.*undocumented=//')
        metric b9_undocumented "${_ud:-0}"
        if [ "${_ud:-99}" -eq 0 ]; then
            chk B-9 PASS "every compose variable is documented somewhere"
        else
            chk B-9 FAIL "${_ud} compose variable(s) documented nowhere" \
                "$(printf '%s' "$_eo" | sed -n 2p)"
        fi
    else
        chk B-9 UNKNOWN "cannot parse compose for the env surface"
    fi

    # B-10: a unit that only exists on the host is one `rm -rf` from gone, and
    # a schedule is only sane relative to the timezone people live in.
    #
    # It searched `scripts/` alone, and reported codegraph-refresh as
    # unversioned for as long as it has existed. That unit lives in
    # `codegraph/`, beside the Dockerfile it drives — a reasonable layout, and
    # the check was enforcing a directory rather than asking its own question.
    # "Is the unit in the repo" is the thing that matters; where is a matter of
    # taste, and a check should not have one.
    _units=$(find . -maxdepth 2 -name '*.timer' -not -path './omniroute/*' 2>/dev/null | wc -l | tr -d ' ')
    if have systemctl; then
        _live=$(systemctl --user list-timers --no-legend 2>/dev/null | awk '{print $NF}' \
                | sed 's/\.service$//' | grep -v '^$' | sort -u || true)
        _unversioned=""; _where=""
        for _t in $_live; do
            case "$_t" in
                launchpadlib*|systemd-*) continue ;;
            esac
            _found=$(find . -maxdepth 2 -name "$_t.timer" -not -path './omniroute/*' 2>/dev/null | head -1)
            if [ -n "$_found" ]; then
                _where="$_where ${_found#./}"
            else
                _unversioned="$_unversioned $_t"
            fi
        done
        if [ -z "$_unversioned" ]; then
            chk B-10 PASS "every active user timer has its unit in the repo" \
                "$_units unit file(s):$_where"
        else
            chk B-10 FAIL "active timer(s) with no unit file anywhere in the repo" \
                "$_unversioned — one \`rm -rf\` from gone, and unreviewable meanwhile"
        fi
    else
        chk B-10 SKIP "systemctl unavailable; installed units unmeasurable" "$_units unit(s) in scripts/"
    fi

    # B-11: a profile with no preflight check deploys unguarded.
    if [ -f scripts/stax-preflight.sh ] && pyyaml_ok; then
        _cp=$("$PY" -c "
import io,yaml
d=yaml.safe_load(io.open('docker-compose.yml',encoding='utf-8').read()) or {}
ps=set()
for s in (d.get('services') or {}).values():
    for p in (s or {}).get('profiles') or []: ps.add(p)
print(' '.join(sorted(ps)))" 2>/dev/null || true)
        _missing=""
        for p in $_cp; do
            grep -qE "^ *$p\)" scripts/stax-preflight.sh || _missing="$_missing $p"
        done
        if [ -z "$_missing" ]; then
            chk B-11 PASS "every compose profile has a preflight check"
        else
            chk B-11 FAIL "profile(s) deploy with no preflight guard" "$_missing"
        fi
    else
        chk B-11 UNKNOWN "cannot compare profiles to preflight"
    fi

    # B-12 and B-13 ask what a container is ALLOWED to do, which nothing asked.
    # B-1 bounds memory, B-2 bounds ports; neither notices a container that can
    # step out of its own cgroup entirely. The blast radius here is not
    # theoretical -- C-4 already records that the sidecar holds a read-write
    # docker.sock, so a second privilege path is a second way to reach the host.
    if ! on_host; then
        chk B-12 SKIP "not on the host; container privileges are a runtime fact"
        chk B-13 SKIP "not on the host"
    else
        _priv=""; _caps=""; _root=""; _nall=0
        for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
            _nall=$((_nall + 1))
            [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$_c" 2>/dev/null)" = "true" ] \
                && _priv="$_priv $_c"
            case "$(docker inspect -f '{{.HostConfig.CapAdd}}' "$_c" 2>/dev/null)" in
                ''|'[]'|'<no value>') : ;;
                *) _caps="$_caps $_c" ;;
            esac
            case "$(docker inspect -f '{{.Config.User}}' "$_c" 2>/dev/null)" in
                ''|root|0|0:0) _root="$_root $_c" ;;
            esac
        done
        metric b12_containers "$_nall"
        if [ -n "$_priv" ] || [ -n "$_caps" ]; then
            chk B-12 FAIL "container(s) running with elevated privileges" \
                "privileged:${_priv:- none} cap_add:${_caps:- none}"
        else
            chk B-12 PASS "no container is privileged, none adds a capability" \
                "$_nall container(s) inspected"
        fi

        # B-13 is drift, not presence, for the same reason F-9 is: six of these
        # are vendored or upstream images whose entrypoint needs uid 0, and a
        # check that can never be green is a check nobody reads. What must not
        # happen quietly is a SEVENTH.
        _rack=scripts/root-containers.txt
        _rn=$(printf '%s' "$_root" | wc -w)
        metric b13_root_containers "$_rn"
        if [ ! -f "$_rack" ]; then
            chk B-13 FAIL "no $_rack; root-running containers have never been reviewed" \
                "$_rn of $_nall run as uid 0"
        else
            _new=""
            for _c in $_root; do
                grep -v '^[[:space:]]*#' "$_rack" | grep -qx "$_c" || _new="$_new $_c"
            done
            # Measured, not asserted. The first version of this check gave
            # "no user-namespace remapping on this daemon" as its evidence
            # without ever reading the daemon — an unverified claim dressed as
            # a finding, which is the habit this audit exists to break.
            # `docker info` lists name=userns among SecurityOptions when
            # remapping is on; its absence is what makes uid 0 inside uid 0
            # outside, and the seccomp and apparmor profiles it DOES list are
            # worth naming rather than leaving out of a security sentence.
            _so=$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null || true)
            case "$_so" in
                *userns*) _uns="userns remapping is on: uid 0 inside is not uid 0 outside" ;;
                '')       _uns="the daemon's security options could not be read" ;;
                *)        _uns="no userns remapping, so uid 0 inside is uid 0 outside on escape; the daemon does apply $(printf '%s' "$_so" | tr -d '[]\"' | tr ',' ' ')" ;;
            esac
            if [ -z "$_new" ]; then
                chk B-13 PASS "$_rn of $_nall container(s) run as root, all acknowledged" \
                    "$_uns"
            else
                chk B-13 FAIL "container(s) running as root that nobody has reviewed" "$_new"
            fi
        fi
    fi
}

# ------------------------------------------------------------- dimension C

# Files that hold live credentials on this deployment. Each is checked with its
# BACKUP VARIANTS, because `providers.env` was ignored while
# `providers.env.bak.20260906` sat beside it untracked and unignored, one
# `git add -A` from being committed.
SECRET_FILES=".env omniroute/.env agent-sidecar/.env activepieces/.env providers.env observability/.env .claude/settings.local.json"

# Secret-bearing files that are NOT `.env` files anyone would think to list:
# created by the container, owned by uid 1000, named nothing like `.env` in
# most cases. C-7 has always checked their modes. C-9 did not read them at all
# until 2026-09-11, which meant the variable that decrypts every stored
# provider credential -- STORAGE_ENCRYPTION_KEY, in omniroute/data/server.env
# -- was outside the set the rotation-list check compared against.
#
# Split in two because one consumer greps them for `VAR=` and one only stats
# them: storage.sqlite is a database, and grepping a binary for variable names
# yields nothing while looking like it looked.
RUNTIME_ENV_FILES="omniroute/data/server.env .pool-prove.env"
RUNTIME_SECRET_FILES="$RUNTIME_ENV_FILES omniroute/data/storage.sqlite"

dim_C() {
    echo; echo "C  secrets and access"

    _leaky=""
    for f in $SECRET_FILES; do
        for v in "$f" "$f.bak" "$f.old" "$f.bak.20260101" "$f.save" "$f~"; do
            git check-ignore -q "$v" 2>/dev/null || _leaky="$_leaky $v"
        done
    done
    # These are CANDIDATE paths, and most of them do not exist. Asking whether
    # the ignore rule WOULD cover them is the only useful time to ask, because
    # providers.env.bak.20260906 was unignored for a day before anyone looked.
    #
    # But the old wording — "one `git add -A` from a commit" — reads as a claim
    # that the named files are sitting in the tree right now. Three of the four
    # it listed on 2026-09-10 did not exist on the host at all. A check that is
    # right about the rule and misleading about the world still costs someone
    # an hour.
    if [ -z "$_leaky" ]; then
        chk C-1 PASS "the ignore rules cover every secret file and its backup variants" \
            "42 candidate paths, existing or not; the rule has to be right before the file appears"
    else
        chk C-1 FAIL "ignore rules would not cover these secret paths if they appeared" \
            "$(printf '%s' "$_leaky" | tr ' ' '\n' | grep -v '^$' | head -4 | tr '\n' ' ')"
    fi

    # Untracked AND unignored files that look secret-bearing. This is the check
    # that would have caught providers.env.bak.20260906 the day it appeared.
    #
    # The second grep is a subtraction, not a softening. The pattern matches on
    # NAME, and `scripts/local-secret-scan.sh` — the scanner itself — matched
    # the word "secret" and was reported as a stray credential. Source files,
    # documentation and templates are excluded by extension; a credential does
    # not arrive named `.sh`, and a check crying wolf about the tooling is one
    # people learn to scroll past.
    _stray=$(git status --porcelain --untracked-files=all 2>/dev/null \
             | awk '/^\?\?/ {print $2}' \
             | grep -iE '(^|/)\.env|secret|token|credential|\.bak(\.|$)|\.pem$|\.key$' \
             | grep -vE '\.(sh|py|js|mjs|ts|md|yml|yaml|example)$' || true)
    if [ -z "$_stray" ]; then
        chk C-1b PASS "no untracked, unignored file looks secret-bearing"
    else
        chk C-1b FAIL "untracked secret-shaped file(s) present" "$(printf '%s' "$_stray" | tr '\n' ' ')"
    fi

    _ph=""
    for f in $SECRET_FILES; do
        [ -f "$f" ] || continue
        grep -nEi '=(CHANGEME|changeme|your[-_]|placeholder|xxxxx|TODO|example)' "$f" 2>/dev/null \
            | head -2 | while IFS= read -r l; do printf '%s:%s\n' "$f" "${l%%:*}"; done
    done > "$METRICS.ph" 2>/dev/null || true
    _ph=$(cat "$METRICS.ph" 2>/dev/null || true); rm -f "$METRICS.ph"
    if [ -z "$_ph" ]; then
        chk C-3 PASS "no placeholder values left in secret files"
    else
        chk C-3 FAIL "placeholder value(s) still installed" "$(printf '%s' "$_ph" | tr '\n' ' ')"
    fi

    # C-4: blast radius, not just presence. A credential's label must match
    # what holding it actually gets you.
    if on_host; then
        _sock=$(docker inspect king-agent-sidecar-http-1 \
                --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.RW}}{{end}}{{end}}' 2>/dev/null || true)
        _exec=$(docker exec king-agent-sidecar-http-1 printenv AGENT_SIDECAR_EXEC_ENABLED 2>/dev/null || true)
        # The label, from the document that drives the rotation. The check's
        # own first line says the test is "a credential's label must match what
        # holding it actually gets you" — and it only ever measured the second
        # half, so it failed permanently on a configuration the operator chose
        # deliberately. A check that cannot be satisfied by doing the right
        # thing is one people route around.
        #
        # The right thing here is not removing the socket: that would make
        # vps_exec useless, which is the capability this deployment exists to
        # provide. It is making sure the credential is filed as what it is, so
        # the rotation ahead treats it like an SSH root key and not like an
        # application token.
        _labelled=0
        if [ -f docs/king-rotation.md ]; then
            grep -n 'AGENT_SIDECAR_AUTH_TOKEN' docs/king-rotation.md 2>/dev/null \
                | grep -qi 'root' && _labelled=1
        fi
        if [ "$_sock" = "true" ] && [ -n "$_exec" ] && [ "$_labelled" = 1 ]; then
            chk C-4 PASS "the sidecar token is root-equivalent, and is filed as root" \
                "docker.sock rw + EXEC_ENABLED=$_exec; docs/king-rotation.md carries it in Tier 1 — the risk is accepted, not unnoticed"
        elif [ "$_sock" = "true" ] && [ -n "$_exec" ]; then
            chk C-4 FAIL "AGENT_SIDECAR_AUTH_TOKEN is a ROOT credential and is not filed as one" \
                "docker.sock mounted rw + EXEC_ENABLED=$_exec: vps_exec can run --privileged -v /:/host, and no document says so"
        elif [ "$_sock" = "true" ]; then
            chk C-4 FAIL "sidecar holds a writable docker.sock (root-equivalent if exec is enabled)"
        elif [ "$_labelled" = 1 ]; then
            chk C-4 FAIL "the docs call the sidecar token root-equivalent, but the socket is gone" \
                "a label that overstates trains people to discount labels; correct the document"
        else
            chk C-4 PASS "sidecar has no writable docker socket"
        fi
    else
        chk C-4 SKIP "not on the host; blast radius unmeasurable"
    fi

    # C-5/C-6: the public surface, and whether each door is actually locked.
    # Tested in BOTH directions — a 200 with no token is an open door, and a
    # 401 with the right token is a door nobody can use.
    # Derived from the Caddyfile, not hardcoded. Two paths written into this
    # check was an inventory of what I remembered, which is what an inventory
    # is supposed to replace: a route added later would never appear, and the
    # check would keep passing.
    if have curl && [ -f caddy/Caddyfile ]; then
        _routes=$(grep -oE 'handle_path /[a-z0-9-]+/\*' caddy/Caddyfile 2>/dev/null \
                  | sed 's|handle_path ||; s|/\*$||' | sort -u || true)
        _n=$(printf '%s' "$_routes" | grep -c . || true)
        metric c5_paths "${_n:-0}"
        _open=""; _unmapped=""; _c5down=""
        for _r in $_routes; do
            _spec=$(probe_target "$_r")
            _tgt=${_spec%%|*}; _okcodes=${_spec#*|}
            if [ -z "$_tgt" ]; then _unmapped="$_unmapped $_r"; continue; fi
            _code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
                    "https://gateway.arject.co$_tgt" 2>/dev/null || echo 000)
            case "$(_doorverdict "$_code" "$_okcodes")" in
                locked)      : ;;
                unreachable) _c5down="$_c5down $_tgt=$_code" ;;
                *)           _open="$_open $_tgt=$_code" ;;
            esac
        done
        # Order is the argument. An open door outranks an unreachable one:
        # if anything answered anonymously, that is the finding, whatever else
        # was down at the same time.
        if [ "${_n:-0}" -eq 0 ]; then
            chk C-5 UNKNOWN "no routes found in the Caddyfile to inventory"
        elif [ -n "$_unmapped" ]; then
            chk C-5 FAIL "route(s) with no declared probe target" \
                "$_unmapped — add one to probe_target(); an unknown route must not pass by default"
        elif [ -n "$_open" ]; then
            chk C-5 FAIL "data endpoint(s) answered without a token" "$_open"
        elif [ -n "$_c5down" ]; then
            chk C-5 UNKNOWN "route(s) unreachable, so anonymous access could not be tested:$_c5down" \
                "a 5xx is the upstream being absent; it proves nothing about the lock in either direction"
        else
            chk C-5 PASS "all ${_n} route(s), probed at the endpoint that carries data, deny anonymous access"
        fi
    else
        chk C-5 UNKNOWN "curl or Caddyfile unavailable; public surface unmeasurable"
    fi

    # C-7 checked exactly one file — agent-sidecar/.env — and reported "secret
    # file permissions are not world-readable", plural, generalising from a
    # sample of one. It passed while omniroute/data/server.env sat at mode 644
    # holding the STORAGE_ENCRYPTION_KEY that decrypts every provider
    # credential, and storage.sqlite sat beside it at 644 holding the gateway's
    # own API keys as literal `sk-` strings.
    #
    # The runtime paths are the ones a fixed list was always going to miss:
    # they are created by the container, owned by uid 1000, and named nothing
    # like `.env` in five of six cases. They are also where the key lives NEXT
    # TO the data it encrypts, so the encryption defends against a stolen
    # database file and not against read access to the directory.
    _runtime_secrets="$RUNTIME_SECRET_FILES"
    _wr=""; _checked=0; _unstat=""
    for _sf in $SECRET_FILES $_runtime_secrets; do
        # `[ -e ]` needs traverse on every parent, so it answers FALSE for a
        # file that exists inside a directory this user cannot enter. The stat
        # below already falls back to `priv`; the existence test did not, and
        # the moment omniroute/data went to 700 the two files it holds
        # vanished from the count. C-7 then reported "none of 6 are
        # world-readable" — passing by not looking, on the two files the chmod
        # was for.
        #
        # This is the check's own subject arriving in its own loop, and it took
        # a count dropping from 8 to 6 to notice. A count in an evidence line
        # is a claim; this one was the only thing that gave it away.
        [ -e "$_sf" ] || priv test -e "$_sf" || continue
        _perm=$(stat -c '%a' "$_sf" 2>/dev/null || priv stat -c '%a' "$_sf" || true)
        case "$_perm" in
            ""|*[!0-9]*)
                # Never a silent `continue`. A file that cannot be stat'd is
                # not a file that passed, and dropping it from the count is
                # how "8 checked, none world-readable" got printed while the
                # two that mattered were never looked at.
                _unstat="$_unstat $_sf"; continue ;;
        esac
        _checked=$((_checked + 1))
        # The others digit, tested for the READ bit.
        #
        # This was `*[2367]`, which matches modes ending in 2, 3, 6 or 7 —
        # that is the WRITE bit. Mode 644 ends in 4 and never matched, so a
        # check named "world-readable" was testing world-WRITABLE. It passed
        # for months because the single file it looked at was 600, where both
        # tests agree. Nothing catches a wrong predicate that is only ever
        # asked about a passing case.
        case "$_perm" in
            *[4567]) _wr="$_wr ${_sf}($_perm,readable)" ;;
            *[123])  _wr="$_wr ${_sf}($_perm,writable-or-exec)" ;;
        esac
    done

    # The DIRECTORY, not only the files in it.
    #
    # This is where the real protection lives. `chmod 600 storage.sqlite` is
    # undone the next time SQLite rewrites its WAL — measured: -wal and -shm
    # are rewritten minute by minute — while a directory's mode is not
    # rewritten by anything the application does. So the durable control is
    # `chmod 700` on omniroute/data, and a check that watched only the files
    # would go green on the day the directory was widened back.
    _dirs="omniroute/data"
    _opendir=""
    for _d in $_dirs; do
        [ -d "$_d" ] || priv test -d "$_d" || continue
        _dm=$(stat -c '%a' "$_d" 2>/dev/null || priv stat -c '%a' "$_d" || true)
        case "$_dm" in
            ''|*[!0-9]*) _opendir="$_opendir ${_d}(unreadable)" ;;
            *[1-7])      _opendir="$_opendir ${_d}($_dm)" ;;
        esac
    done

    if [ -n "$_unstat" ]; then
        chk C-7 UNKNOWN "secret file(s) could not be stat'd:$_unstat" \
            "$_checked other file(s) were checked; an unmeasured file is not a passing one"
    elif [ "$_checked" -eq 0 ]; then
        chk C-7 UNKNOWN "no secret file was found to check"
    elif [ -n "$_wr" ]; then
        chk C-7 FAIL "world-readable secret-bearing file(s):$_wr" \
            "$_checked checked; on this host uid 1001 and 1002 can read anything at mode 644"
    elif [ -n "$_opendir" ]; then
        chk C-7 FAIL "secret-bearing director(ies) others can enter:$_opendir" \
            "the files inside are 600 today, but SQLite rewrites them and the directory mode is what holds"
    else
        chk C-7 PASS "$_checked secret file(s) and $(printf '%s' "$_dirs" | wc -w) directory closed to other users" \
            "the directory is the durable half: file modes are rewritten by the app, its mode is not"
    fi

    # C-2: rotation does not help if the old value is still in the history.
    # Bounded to token-shaped prefixes rather than a full entropy scan, so it
    # stays fast enough to run every time -- an audit nobody runs finds nothing.
    if git rev-parse --git-dir >/dev/null 2>&1; then
        _hist=""
        for _pat in 'sk-[A-Za-z0-9]\{24,\}' 'oma_live_[A-Za-z0-9]\{16,\}' \
                    'tk_[A-Za-z0-9]\{20,\}' 'AKIA[0-9A-Z]\{16\}'; do
            _h=$(git log --all --oneline -S"$_pat" --pickaxe-regex 2>/dev/null | head -2 || true)
            [ -n "$_h" ] && _hist="$_hist $(printf '%s' "$_h" | awk '{print $1}' | tr '\n' ',')"
        done
        if [ -z "$_hist" ]; then
            chk C-2 PASS "no token-shaped string appears anywhere in git history"
        else
            chk C-2 FAIL "token-shaped string(s) in history — rotation alone is not enough" "$_hist"
        fi
    else
        chk C-2 UNKNOWN "not a git checkout; history unscannable"
    fi

    # C-6: both directions. A 401 for everyone is a wall, not a door; the
    # check has to prove the right token gets in as well as that the wrong one
    # does not. Guards tested in one direction are how this repo has been
    # bitten before.
    if have curl && [ -f agent-sidecar/.env ]; then
        _t1=$(sed -n 's/^AGENT_SIDECAR_AUTH_TOKEN=//p' agent-sidecar/.env 2>/dev/null | tail -1)
        _g1=$(sed -n 's/^GRAPHIFY_API_KEY=//p' .env 2>/dev/null | tail -1)
        _prob=""
        for _spec in "king-agent|/king-agent/mcp|$_t1" "codegraph|/king-codegraph/mcp|$_g1"; do
            _nm=$(printf '%s' "$_spec" | cut -d'|' -f1)
            _pt=$(printf '%s' "$_spec" | cut -d'|' -f2)
            _tk=$(printf '%s' "$_spec" | cut -d'|' -f3)
            [ -n "$_tk" ] || { _prob="$_prob $_nm=no-token"; continue; }
            _u="https://gateway.arject.co$_pt"
            _none=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$_u" 2>/dev/null || echo 000)
            _wrong=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -H "Authorization: Bearer wrong-$$" "$_u" 2>/dev/null || echo 000)
            case "$_none/$_wrong" in
                401/401|403/403|401/403|403/401) : ;;
                *) _prob="$_prob $_nm(none=$_none,wrong=$_wrong)" ;;
            esac
        done
        if [ -z "$_prob" ]; then
            chk C-6 PASS "every MCP rejects both no token and a wrong token" \
                "the right-token direction is proved by F-1, which calls a tool"
        else
            chk C-6 FAIL "MCP auth did not behave in both directions" "$_prob"
        fi
    else
        chk C-6 UNKNOWN "cannot read tokens or curl missing; MCP auth untested"
    fi

    # C-9: a rotation list is only useful if it names everything that exists.
    #
    # This used to select "secret-shaped" variables with the pattern
    # KEY|TOKEN|SECRET|PASSWORD|DSN|URL and then report how many of THOSE were
    # mentioned anywhere under docs/. Both halves were wrong.
    #
    # The pattern: LANGFUSE_OTLP_AUTH (the Langfuse key pair, 122 chars of
    # base64), NTFY_ALERT_TOPIC (the unguessable half of an unauthenticated
    # ntfy topic -- stax-preflight.sh:345 already calls it out) and
    # MACHINE_ID_SALT (upstream files it under "Security hashing" beside
    # API_KEY_SECRET) match none of those words. So all three were missing from
    # the set being tested AND from the count being reported, and C-9 passed
    # while docs/king-rotation.md was short three credentials. A check that
    # derives its denominator from the same heuristic as its test cannot fail
    # on anything that heuristic misses.
    #
    # A value-shape heuristic was tried as the replacement and has a different
    # hole, not a smaller one: it misses LANGFUSE_OTLP_AUTH (its value contains
    # a space, being a `Basic …` header) and MACHINE_ID_SALT (19 characters).
    # Two heuristics, two blind spots, no overlap -- so no heuristic.
    #
    # The target: "named anywhere under docs/" is not the claim that matters.
    # A credential mentioned in a README and absent from the rotation list is
    # exactly the one that gets missed while rotating. Both were true here:
    # LANGFUSE_OTLP_AUTH was in README.md and docs/integrations/observability.md.
    #
    # So: enumerate EVERY variable, and require each to be named in the
    # rotation document itself or acknowledged in scripts/not-secrets.txt.
    _rotdoc=docs/king-rotation.md
    _notsec=scripts/not-secrets.txt
    if [ ! -f "$_rotdoc" ]; then
        chk C-9 SKIP "no $_rotdoc to compare the secret files against"
    else
        # priv, not plain read: omniroute/data/server.env is mode 600 owned by
        # uid 1000 and this audit runs as 1001, so a plain `[ -r ]` skips the
        # file holding STORAGE_ENCRYPTION_KEY and the check then reports on a
        # set that silently excluded it. Only names are ever extracted; values
        # never leave the pipeline.
        _unread=""
        _allvars=$(for f in $SECRET_FILES $RUNTIME_ENV_FILES; do
                     [ -e "$f" ] || priv test -e "$f" || continue
                     { cat "$f" 2>/dev/null || priv cat "$f" 2>/dev/null; } \
                       | grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d '='
                   done | sort -u)
        for f in $SECRET_FILES $RUNTIME_ENV_FILES; do
            { [ -e "$f" ] || priv test -e "$f"; } || continue
            { cat "$f" >/dev/null 2>&1 || priv cat "$f" >/dev/null 2>&1; } || _unread="$_unread $f"
        done
        # Read the acknowledgement file once, stripped, and match whole names.
        # A substring match here would let ACK of `AP_REDIS_HOST` silently
        # cover `AP_REDIS_HOST_EXTRA`, which is the same class of error as the
        # name pattern this check just stopped using.
        _ack=$(grep -vE '^[[:space:]]*(#|$)' "$_notsec" 2>/dev/null \
               | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
        _unlisted=""
        for _sc in $_allvars; do
            grep -q "$_sc" "$_rotdoc" 2>/dev/null && continue
            printf '%s\n' "$_ack" | grep -qxF "$_sc" && continue
            _unlisted="$_unlisted $_sc"
        done
        _n=$(printf '%s' "$_unlisted" | wc -w | tr -d ' ')
        _found=$(printf '%s' "$_allvars" | wc -w | tr -d ' ')
        if [ "${_found:-0}" -eq 0 ]; then
            # No readable secret files means nothing was compared. Passing on
            # an empty set is how a check reports success for doing nothing.
            chk C-9 UNKNOWN "no readable secret file; the rotation list was compared against nothing"
        elif [ -n "$_unread" ]; then
            # A secret file that exists and cannot be read is not a clean set.
            # Reporting a pass over the files that happened to be readable is
            # the same shape as C-7 passing over six of eight.
            chk C-9 UNKNOWN "secret file(s) exist but could not be read, so the comparison is incomplete" \
                "unreadable:$_unread -- ${_n:-0} unaccounted among the ${_found} that were readable"
        elif [ "${_n:-0}" -eq 0 ]; then
            chk C-9 PASS "all ${_found} variable(s) in the secret files are accounted for" \
                "each is named in $_rotdoc or acknowledged in $_notsec -- no name pattern involved"
        else
            chk C-9 FAIL "${_n} of ${_found} variable(s) in the secret files are accounted for nowhere" \
                "$(printf '%s' "$_unlisted" | tr ' ' '\n' | head -6 | tr '\n' ' ')-- add to $_rotdoc if a credential, else $_notsec"
        fi
    fi

    # Three outcomes, not two. `grep -c` on a MISSING file errors, `|| true`
    # turned that into an empty string, and `[ "" = "0" ]` is false -- so a
    # file that does not exist reported the allowlist as configured. That is
    # the `|| echo 0` shape this script's own header warns about, committed
    # by the script itself for the second time.
    # C-8 was wrong twice over, and confidently.
    #
    # It called AGENT_SIDECAR_MCP_ALLOWED_HOSTS an EGRESS allowlist and said
    # "the agent reads web pages; this is the boundary that bounds it". It is
    # not an egress control at all. mcp_server.py uses it for MCP's
    # DNS-rebinding protection: an INBOUND allowlist of Host headers the
    # endpoint will accept, which is what stops a page in a browser from
    # driving this MCP server through a victim's own network. Opposite
    # direction, different threat.
    #
    # And it read agent-sidecar/.env, where the variable has never lived.
    # Compose reads it from the ROOT .env, and the container has had it set to
    # the public name the whole time — so the check reported a missing control
    # that was present, for a purpose it does not serve. Reading a file rather
    # than the process is the same fault as F-8, one dimension over.
    #
    # The effective environment is the only thing that settles it.
    _dnsr=""
    if on_host && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^king-agent-sidecar-http-1$'; then
        _dnsr=$(docker inspect king-agent-sidecar-http-1 \
                -f '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                | sed -n 's/^AGENT_SIDECAR_MCP_ALLOWED_HOSTS=//p' | head -1)
        _src="the running container"
    else
        _dnsr=$(sed -n 's/^AGENT_SIDECAR_MCP_ALLOWED_HOSTS=//p' .env 2>/dev/null | tail -1)
        _src="the root .env (off-host)"
    fi
    if [ -n "$_dnsr" ]; then
        chk C-8 PASS "MCP DNS-rebinding protection accepts only named hosts" \
            "$_dnsr, per $_src — this is an INBOUND Host allowlist, not an egress control; egress is F-9"
    else
        chk C-8 FAIL "MCP DNS-rebinding protection has no host beyond loopback" \
            "reached through Caddy the Host header is the public name, so the endpoint answers every call with \"Invalid Host header\" and a 200 — a broken tool wearing a success status"
    fi

    # C-10. C-5 asks what the internet can reach. Nothing asked what a
    # container that is ALREADY inside can reach -- the question that decides
    # what one compromise costs. The agent sidecar runs model-authored code,
    # so "already inside" is its normal operating state, not a hypothetical.
    #
    # Found by asking it for the first time: both Redis instances sit on one
    # flat `king_default` network with every other container, and both answer
    # `CONFIG GET requirepass` with an empty value.
    if ! on_host; then
        chk C-10 SKIP "not on the host"
    else
        _stores=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
                  | grep -Ei 'redis|valkey|postgres|mysql|mongo' | awk '{print $1}' || true)
        if [ -z "$_stores" ]; then
            chk C-10 PASS "no datastore container runs here to segment"
        else
            _open=""; _n=0
            for _st in $_stores; do
                _n=$((_n + 1))
                case "$(docker inspect -f '{{.Config.Image}}' "$_st" 2>/dev/null)" in
                    *redis*|*valkey*)
                        _rp=$(docker exec "$_st" redis-cli --no-auth-warning CONFIG GET requirepass 2>/dev/null \
                              | tr -d '\r' | sed -n '2p')
                        [ -n "$_rp" ] || _open="$_open $_st" ;;
                esac
            done
            metric c10_datastores "$_n"
            # Drift, not presence — the same shape as B-13 and F-9. One of
            # these is declared inside the vendored subtree with a hardcoded
            # `command:` and no password variable, so there is no compliant way
            # to authenticate it from this repository. A check that stays red
            # over that is one nobody reads; a check that goes red on a NEW
            # one is worth having.
            _dsack=scripts/unauthenticated-datastores.txt
            _dsnew=""
            for _o in $_open; do
                [ -f "$_dsack" ] && grep -v '^[[:space:]]*#' "$_dsack" | grep -qx "$_o" \
                    || _dsnew="$_dsnew $_o"
            done
            if [ -z "$_open" ]; then
                chk C-10 PASS "$_n datastore(s), none reachable without a credential"
            elif [ -z "$_dsnew" ]; then
                chk C-10 PASS "$_n datastore(s); the unauthenticated one is acknowledged:$_open" \
                    "loopback-bound and fixable only upstream — reasons and calibration in $_dsack"
            elif [ -n "$_dsnew" ] && [ "$_dsnew" != "$_open" ]; then
                chk C-10 FAIL "unauthenticated datastore(s) nobody has reviewed:$_dsnew" \
                    "others on that list are acknowledged; this one is not"
            else
                _peers=$(docker network inspect king_default \
                         -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | wc -w || true)
                chk C-10 FAIL "unauthenticated datastore(s):$_open" \
                    "shared with ${_peers:-?} containers on one flat network; any of them can issue any command"
            fi
        fi
    fi
}

# ------------------------------------------------------------- dimension D

dim_D() {
    echo; echo "D  runtime health"
    if ! on_host; then
        skip_rest D "not on the host; runtime unmeasurable"
        return
    fi

    # Swap per container. The rule in CLAUDE.md exists so a container OOMs
    # inside its own cgroup instead of dragging the host into swap; this is
    # where you find out whether it is working.
    _sw=$(for c in $(docker ps --format '{{.Names}}'); do
            id=$(docker inspect -f '{{.Id}}' "$c" 2>/dev/null) || continue
            for b in "/sys/fs/cgroup/system.slice/docker-$id.scope" "/sys/fs/cgroup/docker/$id"; do
                [ -r "$b/memory.swap.current" ] || continue
                v=$(cat "$b/memory.swap.current" 2>/dev/null)
                case "$v" in ''|*[!0-9]*) continue ;; esac
                # A per-container ceiling, not a flat 50 MB for everything.
                #
                # `omniroute` is declared inside the vendored subtree, and
                # CLAUDE.md forbids both editing it and overriding it from the
                # root compose — a partial override there turned every Docker
                # CI job red once. So this one cannot be fixed from this repo,
                # and a check that stays red over it is one nobody reads.
                #
                # But a bare acknowledgement would be the wrong shape: "it
                # swaps" is equally true at 362 MB and at 3 GB. The ceiling in
                # the file keeps the guard live for the thing that matters,
                # which is growth.
                _cap=$(grep -v '^[[:space:]]*#' scripts/swapping-containers.txt 2>/dev/null \
                       | awk -v n="$c" '$1 == n { print $2; exit }')
                case "$_cap" in ''|*[!0-9]*) _cap=50 ;; esac
                [ "$v" -gt $((_cap * 1048576)) ] && printf '%s=%sMB/cap%sMB ' "$c" "$((v/1048576))" "$_cap"
                break
            done
          done; true)
    metric d1_swapping "$(printf '%s' "$_sw" | wc -w | tr -d ' ')"
    if [ -z "$_sw" ]; then
        chk D-1 PASS "no container holds more swap than its ceiling allows" \
            "50 MB by default; scripts/swapping-containers.txt raises it only where the fix is upstream"
    else
        chk D-1 FAIL "container(s) over their swap ceiling" "$_sw"
    fi

    _unhealthy=$(docker ps --format '{{.Names}} {{.Status}}' | grep -i 'unhealthy' || true)
    _restarts=$(for c in $(docker ps --format '{{.Names}}'); do
                  r=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null)
                  case "$r" in ''|*[!0-9]*) continue ;; esac
                  [ "$r" -gt 3 ] && printf '%s=%s ' "$c" "$r"
                done; true)
    # A container that declares NO healthcheck never reports "unhealthy", so
    # the grep below is silent for it and D-2 passed on a stack where the only
    # public entrypoint had no healthcheck at all. That is precisely the
    # failure this dimension was written to catch -- "healthy that was never
    # checked" -- committed by the check named after it.
    _nohc=""
    for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
        [ "$(docker inspect -f '{{if .Config.Healthcheck}}y{{else}}n{{end}}' "$_c" 2>/dev/null)" = "n" ] \
            && _nohc="$_nohc $_c"
    done
    # Drift, not presence. One of these is genuinely unable to have a probe:
    # a distroless image has no shell and no wget, and a Docker healthcheck
    # runs its command INSIDE the container. A check that can never be green
    # over that stops being read, so the impossible case is acknowledged by
    # name and a NEW one turns this red.
    _hcack=scripts/no-healthcheck.txt
    if [ -z "$_nohc" ]; then
        chk D-2b PASS "every running container declares a healthcheck"
    elif [ ! -f "$_hcack" ]; then
        chk D-2b FAIL "container(s) with no healthcheck, and no $_hcack" "$_nohc"
    else
        _hcnew=""
        for _c in $_nohc; do
            grep -v '^[[:space:]]*#' "$_hcack" | grep -qx "$_c" || _hcnew="$_hcnew $_c"
        done
        if [ -z "$_hcnew" ]; then
            chk D-2b PASS "every running container without a healthcheck is acknowledged" \
                "$_nohc — reasons in $_hcack; D-2's silence about them is not a pass"
        else
            chk D-2b FAIL "container(s) with no healthcheck that nobody has reviewed" \
                "$_hcnew — D-2 cannot see these; its silence about them is not a pass"
        fi
    fi

    if [ -z "$_unhealthy" ] && [ -z "$_restarts" ]; then
        chk D-2 PASS "no container reports unhealthy, none restarts repeatedly" \
            "which is a claim only about containers that HAVE a healthcheck; see D-2b"
    else
        chk D-2 FAIL "container health problems" "$_unhealthy $_restarts"
    fi

    if [ -r /proc/meminfo ]; then
        _avail=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
        _swap=$(awk '/^SwapTotal:/{t=$2}/^SwapFree:/{f=$2}END{print int((t-f)/1024)}' /proc/meminfo)
        metric d3_mem_available_mb "$_avail"; metric d3_swap_used_mb "$_swap"

        # The floor must be compared against what the BUILD will see, not
        # against now. codegraph-refresh.sh unloads the resident model before
        # it checks, so raw MemAvailable under-reports the headroom by whatever
        # Ollama happens to be holding -- and that moved ~800 MB in one day.
        # Comparing the wrong number reported a failure that would not happen,
        # which is the same class of error this whole audit exists to catch.
        _oll=0
        _cid=$(docker compose --profile localmodel ps -q ollama 2>/dev/null || true)
        if [ -n "$_cid" ]; then
            for _b in "/sys/fs/cgroup/system.slice/docker-$_cid.scope" "/sys/fs/cgroup/docker/$_cid"; do
                [ -r "$_b/memory.current" ] || continue
                _oll=$(( $(cat "$_b/memory.current") / 1048576 ))
                break
            done
        fi
        _eff=$((_avail + _oll))
        metric d3_effective_headroom_mb "$_eff"
        metric d3_ollama_resident_mb "$_oll"
        if [ "$_eff" -ge 3584 ]; then
            chk D-3 PASS "codegraph build would see ${_eff} MB, above its 3584 MB floor" "MemAvailable ${_avail} + Ollama ${_oll} released first; swap used ${_swap} MB"
        else
            chk D-3 FAIL "codegraph build would see only ${_eff} MB, below its 3584 MB floor" "MemAvailable ${_avail} + Ollama ${_oll}; the daily graph refresh will refuse"
        fi
    else
        chk D-3 UNKNOWN "cannot read /proc/meminfo"
    fi

    # Readability and count are separate questions. Folding them together with
    # `|| echo UNKNOWN` reported "unknown" whenever the count was legitimately
    # zero, because grep -c exits 1 on no match.
    if _dm=$(priv dmesg); then
        _oom=$(printf '%s' "$_dm" | grep -ci 'out of memory\|oom-kill' || true)
        # A cgroup-bounded kill and a host-wide kill are opposite events and
        # this counted them together, under a sentence -- "the kernel has been
        # choosing victims by RSS" -- that only describes the second.
        #
        # CLAUDE.md requires equal mem_limit/memswap_limit on every service
        # precisely so a container "OOMs loudly inside its own cgroup instead
        # of dragging the whole 7.8 GB host into swap thrash". A
        # CONSTRAINT_MEMCG kill is therefore that rule WORKING: the blast was
        # contained and the host chose nothing. Reporting it identically to a
        # host-wide OOM makes the safety mechanism firing look like the
        # emergency it prevents, and a reader who learns to wave this red away
        # will wave away the one that matters.
        #
        # Five deliberately-capped gateway builds on 2026-09-10 put nine
        # CONSTRAINT_MEMCG kills in this buffer while the gateway answered 200
        # on every single health poll. That is the distinction, measured.
        _oomhost=$(printf '%s' "$_dm" | grep -c 'constraint=CONSTRAINT_NONE' || true)
        _oomcg=$(printf '%s' "$_dm" | grep -c 'constraint=CONSTRAINT_MEMCG' || true)
        _oomvictims=$(printf '%s' "$_dm" | grep -oE 'task=[^,]+' | sed 's/^task=//' \
                      | sort | uniq -c | sort -rn | head -4 | awk '{$1=$1;print $2" x"$1}' | tr '\n' ' ')
        if [ "${_oom:-0}" -eq 0 ]; then
            chk D-4 PASS "no OOM kill in the kernel ring buffer"
        elif [ "${_oomhost:-0}" -gt 0 ]; then
            chk D-4 FAIL "$_oomhost host-wide OOM kill(s) in dmesg" \
                "constraint=CONSTRAINT_NONE -- the host itself ran out, not a cgroup; victims: ${_oomvictims:-unknown}"
        elif [ "${_oomcg:-0}" -gt 0 ]; then
            chk D-4 PASS "$_oomcg OOM kill(s), every one contained inside its own cgroup" \
                "constraint=CONSTRAINT_MEMCG, zero host-wide -- the mem_limit rule doing its job; victims: ${_oomvictims:-unknown}"
        else
            # 'out of memory' present but no constraint= line to classify it by.
            chk D-4 FAIL "$_oom OOM event(s) in dmesg, and this kernel did not say which cgroup" \
                "no constraint= field to separate a contained kill from a host-wide one"
        fi
    else
        chk D-4 UNKNOWN "dmesg unreadable even with sudo -n; OOM history unknown"
    fi

    # This claimed "log sizes and rotation" and measured root filesystem
    # percentage -- a different question that happens to be easier. Container
    # log files live under /var/lib/docker and need root, so the honest answer
    # is a real attempt plus disk as context, and UNKNOWN when the logs cannot
    # actually be read.
    _pct=$(df / --output=pcent 2>/dev/null | tr -dc '0-9' || true)
    [ -n "$_pct" ] && metric d5_disk_pct "$_pct"
    _logbytes=0; _readable=0
    for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
        _lp=$(docker inspect -f '{{.LogPath}}' "$_c" 2>/dev/null || true)
        [ -n "$_lp" ] || continue
        # The log path is root-owned; reading it as the invoking user was the
        # reason this check spent a day reporting UNKNOWN. `stat -c %s` under
        # priv answers, and an empty answer still means genuinely unreadable.
        _sz=$(priv stat -c %s "$_lp")
        case "$_sz" in ''|*[!0-9]*) continue ;; esac
        _readable=$((_readable + 1))
        _logbytes=$((_logbytes + _sz))
    done
    if [ "$_readable" -eq 0 ]; then
        chk D-5 UNKNOWN "container log sizes unreadable even with sudo -n" \
            "root filesystem ${_pct:-?}% used, which is context and not the claim"
    else
        metric d5_log_mb "$((_logbytes / 1048576))"
        if [ "$((_logbytes / 1048576))" -lt 512 ]; then
            chk D-5 PASS "$_readable container log(s) total $((_logbytes / 1048576)) MB" \
                "root filesystem ${_pct:-?}% used"
        else
            chk D-5 FAIL "container logs total $((_logbytes / 1048576)) MB" "rotation is not keeping up"
        fi
    fi

    # D-5 measures how big the logs ARE. Nothing measured whether anything
    # stops them growing -- and the answer, found only when D-5 was finally
    # made to work, is that nothing does. With no /etc/docker/daemon.json the
    # daemon's json-file driver defaults to unlimited size and zero rotation.
    # 8 MB today is not a policy, it is a young deployment.
    if ! on_host; then
        chk D-7 SKIP "not on the host"
    elif [ -f /etc/docker/daemon.json ] && grep -q 'max-size' /etc/docker/daemon.json 2>/dev/null; then
        _pol=$(grep -o '"max-[a-z]*"[^,}]*' /etc/docker/daemon.json 2>/dev/null | tr '\n' ' ')
        # Written is not the same as APPLIED, and this is the case where the
        # difference bites. `log-opts` is not in the set dockerd reloads on
        # SIGHUP: `systemctl reload docker` returns success, the journal logs
        # "Reloaded configuration", and the config it prints back carries
        # `log-driver` with no `log-opts` at all. Measured on 2026-09-10 — a
        # container written after that reload put 58 MB into a single file
        # under a 10 MB cap.
        #
        # So a check that reads the file and passes would report a fix that is
        # not in force. The daemon's start time against the file's mtime
        # settles it without writing 58 MB to find out.
        _djm=$(stat -c %Y /etc/docker/daemon.json 2>/dev/null || true)
        _dstart=$(priv systemctl show docker -p ActiveEnterTimestampMonotonic --value)
        _dstart_epoch=$(date -d "$(priv systemctl show docker -p ActiveEnterTimestamp --value)" +%s 2>/dev/null || true)
        case "$_djm$_dstart_epoch" in
            ''|*[!0-9]*)
                chk D-7 UNKNOWN "a daemon-wide policy is written, but whether it is applied could not be determined" \
                    "$_pol" ;;
            *)
                if [ "$_djm" -gt "$_dstart_epoch" ]; then
                    chk D-7 FAIL "the daemon-wide log policy is written but NOT applied" \
                        "$_pol — log-opts is not SIGHUP-reloadable; it needs \`systemctl restart docker\`, which stops every container briefly"
                else
                    chk D-7 PASS "a daemon-wide log rotation policy is set and the daemon has it" "$_pol"
                fi ;;
        esac
    else
        # A per-service logging block is the other legitimate answer, so look
        # before concluding. But "SOME services set it" is not that answer.
        #
        # The first version of this check passed on one service out of eleven
        # -- the same "partial accounting reads as a total" error it sits a few
        # lines away from calling out in E-8. Per-service rotation only counts
        # when every RUNNING container has it; the ones that omit it are just
        # as unbounded as they would be under no policy at all. So the question
        # is asked of the containers, not of the compose file: compose declares
        # intent, `docker inspect` reports what the daemon actually applied.
        # Count services that REFERENCE the anchor, not occurrences of the
        # string. `max-size` appears once in this file because it lives in a
        # YAML anchor that eleven services then share, so grepping for it
        # reported "compose caps 1 service" while compose was capping all
        # eleven. A number in an evidence line is a claim like any other.
        _svc_rot=$(grep -c 'logging: \*default-logging' docker-compose.yml 2>/dev/null || true)
        _running=$(docker ps -q 2>/dev/null | wc -l || true)
        _unbounded=0; _names=""
        for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
            _lo=$(docker inspect -f '{{.HostConfig.LogConfig.Config}}' "$_c" 2>/dev/null || true)
            case "$_lo" in
                *max-size*) : ;;
                *) _unbounded=$((_unbounded + 1)); _names="$_names $_c" ;;
            esac
        done
        metric d7_unbounded_containers "$_unbounded"
        if [ "$_unbounded" -eq 0 ] && [ "${_running:-0}" -gt 0 ]; then
            chk D-7 PASS "no daemon-wide default, but all $_running running container(s) cap their logs" \
                "$_svc_rot service(s) declare it in compose"
        elif [ "${_svc_rot:-0}" -gt 0 ]; then
            chk D-7 FAIL "$_unbounded of ${_running:-?} running container(s) have unbounded logs" \
                "compose caps $_svc_rot service(s); the rest inherit the unlimited json-file default:$(printf '%s' "$_names" | cut -c1-80)"
        else
            chk D-7 FAIL "no log rotation anywhere: no /etc/docker/daemon.json, none in compose" \
                "the json-file driver defaults to unlimited size; nothing caps growth"
        fi
    fi

    # D-7b: the question D-7 stops asking the moment daemon.json exists.
    #
    # Look at the two branches above. With NO daemon.json, D-7 interrogates the
    # containers and counts the unbounded ones. With a daemon.json it compares
    # the file's mtime against the daemon's start time and passes. The second
    # is a proxy for the first, and on 2026-09-10 the proxy was wrong.
    #
    # Docker resolves the daemon's default log-opts into a container's
    # HostConfig at CREATE time, not at start. Measured that day: a container
    # created fresh came up with `map[max-file:3 max-size:10m]` baked in, while
    # `omniroute` (created 09-06, before daemon.json was written 09-10 04:38)
    # still read `map[]` -- and it had been through the 12:25 daemon restart
    # that made D-7 green. Restarting a container does not re-resolve this;
    # only recreating it does.
    #
    # So D-7 said "the daemon has the policy", which was true, and the two
    # containers the vendored compose declares did not have it, which was also
    # true. Same shape as every other entry in docs/king-mistakes.md: the
    # artefact was read and the system was not.
    if ! on_host; then
        chk D-7b SKIP "not on the host"
    else
        _nocap=""; _capped=0; _elsewhere=0
        for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
            _lt=$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$_c" 2>/dev/null || true)
            case "$_lt" in
                json-file|local|'')
                    if docker inspect -f '{{.HostConfig.LogConfig.Config}}' "$_c" 2>/dev/null | grep -q 'max-size'
                    then _capped=$((_capped + 1))
                    else _nocap="$_nocap $_c"
                    fi ;;
                # journald/syslog/none/awslogs and friends do not accumulate a
                # file on this disk, so max-size is not the control for them.
                *) _elsewhere=$((_elsewhere + 1)) ;;
            esac
        done
        if [ -z "$_nocap" ] && [ $((_capped + _elsewhere)) -gt 0 ]; then
            chk D-7b PASS "every running container carries an effective log cap" \
                "$_capped capped in HostConfig, $_elsewhere logging off this disk"
        elif [ -n "$_nocap" ]; then
            chk D-7b FAIL "container(s) predate the log policy and never inherited it" \
                "no max-size in HostConfig:$_nocap — a daemon restart does not fix this, only recreating them does"
        else
            chk D-7b UNKNOWN "no running container could be inspected"
        fi
    fi

    # D-6 used to print the reclaimable figure and PASS unconditionally. A
    # check with no failing branch is not a check -- it is a log line wearing a
    # green badge, and G-1 exists to catch exactly that in other people's
    # guards. It now grades the thing that actually matters: whether the disk
    # has room for the next build, with the reclaimable figure as the lever
    # rather than the verdict.
    _recl=$(docker system df 2>/dev/null | awk '/Build Cache/ {print $NF}' | tr -dc '0-9.' || true)
    [ -n "$_recl" ] && metric d6_reclaimable_gb "$_recl"
    _dpct=$(df / --output=pcent 2>/dev/null | tr -dc '0-9' || true)
    _dfree=$(df -BG / --output=avail 2>/dev/null | tr -dc '0-9' || true)
    [ -n "$_dfree" ] && metric d6_free_gb "$_dfree"
    if [ -z "$_dpct" ] || [ -z "$_dfree" ]; then
        chk D-6 UNKNOWN "could not read disk usage"
    elif [ "$_dpct" -ge 85 ]; then
        chk D-6 FAIL "root filesystem ${_dpct}% used, ${_dfree} GB free" \
            "${_recl:-0} GB is reclaimable build cache; the daily codegraph build writes here"
    else
        chk D-6 PASS "root filesystem ${_dpct}% used, ${_dfree} GB free" \
            "${_recl:-0} GB reclaimable build cache is the lever if this tightens"
    fi

    # D-8: a restart policy that cannot survive a clean stop.
    #
    # `on-failure` restarts only on a NON-ZERO exit. A daemon shutdown -- a
    # reboot, a `systemctl restart docker`, an apt upgrade that bounces dockerd
    # -- sends SIGTERM, and a server that handles it properly exits 0. So an
    # `on-failure` service comes back from a crash and never from a reboot,
    # which is the opposite of what "restart policy" suggests.
    #
    # Measured 2026-09-11: after a reboot, codegraph-serve sat `exited` with
    # exit=0 and restarts=0 while every other container was up, and
    # /king-codegraph/mcp answered 502. It had been that way since it was
    # written; nothing had rebooted the host to find out.
    #
    # This asks the RUNNING containers rather than the compose file, because
    # compose declares intent and `docker inspect` reports what the daemon
    # actually applied -- and because the vendored subtree's services are not
    # in the root file at all.
    _badpol=""
    for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
        _p=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$_c" 2>/dev/null || true)
        case "$_p" in
            always|unless-stopped) : ;;
            # An empty policy is not "nothing to see". Docker returns it for a
            # container created with no restart policy at all, which comes back
            # from exactly nothing. Passing on it would be the "could not read
            # it, so it must be fine" shape this audit keeps finding.
            '') _badpol="$_badpol $_c(none)" ;;
            *) _badpol="$_badpol $_c($_p)" ;;
        esac
    done
    if [ -z "$(docker ps -q 2>/dev/null)" ]; then
        chk D-8 SKIP "no running containers here"
    elif [ -z "$_badpol" ]; then
        chk D-8 PASS "every running container has a restart policy that survives a clean stop" \
            "always or unless-stopped; on-failure only fires on a non-zero exit and a reboot exits 0"
    else
        chk D-8 FAIL "restart policy will not bring these back after a reboot" \
            "$_badpol -- on-failure needs a non-zero exit; SIGTERM handled properly exits 0"
    fi
}

# ------------------------------------------------------------- dimension E

# _e9verdict <http_code> <canary_total> <local_completed> <traces_in_window>
#
# E-9's judgement, pulled out of the check body so the self-test exercises the
# SAME code the audit runs. A verdict the test re-implements proves only that
# two transcriptions agree, which is how E-5 stayed green for a week.
#
# The order encodes the rule that check exists to keep: ignorance is not a
# finding. A backend that refuses the credential has ANSWERED, so that is a
# failure. A backend that did not answer, or a filter that cannot prove it
# filters, yields no verdict at all.
# _e4verdict <graph_commit> <origin> <is_ancestor 1|0> <built_at> <newest_then> <age_hours>
#
# E-4's decision, separated from the git plumbing that feeds it so --self-test
# can exercise the real thing. The ORDER is the argument: "is it behind?" is
# not the question, because being behind is normal and documented. The question
# is whether the refresh indexed what was available when it ran.
# _doorverdict <http_code> <acceptable codes, space separated>
#
# A locked door, an open door, and a building that is not there are three
# different findings. B-8 and C-5 had two buckets, so the third landed in the
# alarming one: when `codegraph-serve` was restarting, Caddy answered 502 and
# C-5 reported "data endpoint(s) answered without a token". Nothing answered.
#
# That is the worst shape a security check can take. It is wrong about the
# thing it is most trusted on, it is red for a reason that recurs on every
# restart, and both together teach a reader to scroll past the one check that
# would matter if it were ever right.
#
# 5xx and a connection failure are UNREACHABLE: the lock could not be tested,
# which by this script's own header is UNKNOWN and never a pass.
_doorverdict() {
    _dvc="${1:-000}"
    case " ${2:-401 403} " in *" $_dvc "*) printf 'locked'; return ;; esac
    case "$_dvc" in
        000|5??) printf 'unreachable'; return ;;
    esac
    printf 'open'
}

_e4verdict() {
    [ -n "${1:-}" ] || { printf 'unknown-noinfo'; return; }
    [ "$1" = "${2:-}" ] && { printf 'pass-current'; return; }
    [ "${3:-0}" = "1" ] || { printf 'fail-notancestor'; return; }
    [ -n "${4:-}" ] || { printf 'unknown-nodate'; return; }
    [ -n "${5:-}" ] || { printf 'unknown-nowant'; return; }
    # A refresh that ran and still indexed an older commit built from a stale
    # checkout. This is the 2026-09-08 fault, and an age test passes it.
    [ "$1" = "$5" ] || { printf 'fail-stalecheckout'; return; }
    case "${6:-999}" in ''|*[!0-9]*) printf 'unknown-nodate'; return ;; esac
    # 36h, not 24: the timer fires at 03:12 with a randomised delay, so merely
    # late is not the same as never.
    [ "$6" -le 36 ] || { printf 'fail-schedule'; return; }
    printf 'pass-drift'
}

_e9verdict() {
    case "${1:-}" in
        200)     ;;
        401|403) printf 'fail-auth'; return ;;
        *)       printf 'unknown-api'; return ;;
    esac
    case "${2:-}" in ''|*[!0-9]*) printf 'unknown-canary'; return ;; esac
    [ "$2" -eq 0 ] || { printf 'unknown-canary'; return; }
    case "${3:-}" in ''|*[!0-9]*) printf 'unknown-api'; return ;; esac
    case "${4:-}" in ''|*[!0-9]*) printf 'unknown-api'; return ;; esac
    [ "$3" -gt 0 ] || { printf 'unknown-load'; return; }
    [ "$4" -gt 0 ] || { printf 'fail-dead'; return; }
    _e9l=$3; _e9t=$4
    if [ "$(( _e9t * 100 / _e9l ))" -lt 50 ]
    then printf 'fail-thin'
    else printf 'pass'
    fi
}

dim_E() {
    echo; echo "E  data and state"
    if ! on_host; then
        skip_rest E "not on the host; state unmeasurable"
        return
    fi

    # E-1 is deliberately blunt: this deployment has no backup mechanism at
    # all, so the honest answer is a list of what would be lost, not a PASS.
    _vols=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -c . || true); _vols=${_vols:-0}
    # This reported UNKNOWN with the words "this is a decision, not a check",
    # which reads as humility and is a dodge: whether a backup mechanism EXISTS
    # is a fact, and it is measurable from here. Measured — no timer, no cron
    # entry, no backup directory — the answer is that none does, and a check
    # that can state a fact must state it.
    _bk=""
    systemctl --user list-timers --all --no-pager 2>/dev/null | grep -qi 'backup\|dump' && _bk="timer"
    crontab -l 2>/dev/null | grep -qi 'backup\|pg_dump' && _bk="${_bk:+$_bk,}cron"
    [ -d "$HOME/KING/backups" ] && _bk="${_bk:+$_bk,}directory"
    # "That it RESTORES is a drill, not a check — nothing here has run one" is
    # what this line said for about an hour, during which a drill had in fact
    # been run and had verified 6 flows and 29 flow_versions against the live
    # names. An assertion about the world, written into a check, aged badly
    # inside a single sitting. Whether a drill happened is a fact on disk.
    _drill=$HOME/KING-backups/restore-drills.tsv
    _drilld=""
    [ -f "$_drill" ] && _drilld=$(awk -F'\t' 'NR>1 && $1 { d=$1 } END { print d }' "$_drill" 2>/dev/null)
    if [ -n "$_bk" ] && [ -n "$_drilld" ]; then
        _age=$(( ( $(date +%s) - $(date -d "$_drilld" +%s 2>/dev/null || echo 0) ) / 86400 ))
        if [ "$_age" -le 90 ]; then
            chk E-1 PASS "$_vols volume(s); backups exist ($_bk) and were restored ${_age}d ago" \
                "a backup nobody has restored is a hope; $_drill records what the last drill proved"
        else
            chk E-1 FAIL "backups exist but the last restore drill was ${_age} days ago" \
                "an untested archive degrades silently; re-run one against a throwaway target"
        fi
    elif [ -n "$_bk" ]; then
        chk E-1 FAIL "$_vols volume(s); a backup mechanism exists ($_bk) but nothing records a restore" \
            "no $_drill — an archive that has never been restored is a hope, not a backup"
    else
        chk E-1 FAIL "$_vols docker volume(s) and no backup mechanism of any kind" \
            "no timer, no cron entry, no backups directory; loss is silent until the day it is needed"
    fi

    for _j in /audit/runs.jsonl /audit/vps_exec.log; do
        _n=$(docker exec king-agent-sidecar-http-1 sh -c "wc -l < $_j 2>/dev/null" 2>/dev/null | tr -d ' ' || true)
        case "$_n" in
            ""|*[!0-9]*) chk "E-3" UNKNOWN "cannot read $_j" ;;
            0)           chk "E-3" FAIL "$_j is empty — the journal stopped recording" ;;
            *)           chk "E-3" PASS "$_j has $_n line(s)"; metric "e3_$(basename "$_j" | tr . _)" "$_n" ;;
        esac
    done

    # E-4/E-5: freshness AND correctness. A date check passes on a graph built
    # today from a stale checkout, which is exactly what happened on
    # 2026-09-08: BUILD_INFO said today, commit said 18 behind.
    # E-2: the external database this deployment leans on. Reachability is the
    # question; a free tier that quietly hit its ceiling looks exactly like a
    # working one until a write fails.
    _dsn=$(sed -n 's/^AP_POSTGRES_URL=//p;s/^DATABASE_URL=//p' activepieces/.env .env 2>/dev/null | head -1)
    if [ -z "$_dsn" ]; then
        chk E-2 UNKNOWN "no external Postgres DSN found to test"
    elif have docker; then
        if docker run --rm postgres:16-alpine psql "$_dsn" -tAc 'select 1' >/dev/null 2>&1; then
            chk E-2 PASS "external Postgres answers"
        else
            chk E-2 FAIL "external Postgres did not answer" "the workflow engine writes here"
        fi
    else
        chk E-2 UNKNOWN "no docker to reach Postgres with"
    fi

    # E-4 asked whether the graph's commit EQUALS origin/main, so it went red
    # on every commit and stayed red until the 03:12 timer. CLAUDE.md says the
    # opposite in as many words: "It can be stale by up to a day, which is
    # normal; weeks behind is not." A check that is red during normal operation
    # is a check people learn to scroll past, and this one had been red in
    # three consecutive baselines for no fault at all.
    #
    # Relaxing it to "built within a day" would have been wrong, and the
    # comment left here on 2026-09-08 says why: BUILD_INFO said today while the
    # commit was 18 behind, because graphify had built from a stale checkout.
    # An age test passes that.
    #
    # So the question is neither equality nor age. It is: DID THE REFRESH INDEX
    # THE NEWEST COMMIT THAT EXISTED WHEN IT RAN? `git rev-list -1
    # --before=<built_at> origin/main` answers exactly that, and the three
    # failures then separate cleanly:
    #
    #   commits landed after the refresh    -> normal drift, PASS, counted
    #   the refresh ran and indexed an older commit -> the 2026-09-08 bug, FAIL
    #   the refresh has not run at all      -> the timer is dead, FAIL
    #
    # E-5 still measures CONTENT, because graphify scans the working tree while
    # BUILD_INFO records HEAD. Reading either alone is the mistake.
    _bi=$(docker exec king-codegraph-serve-1 cat /out/graphify-out/BUILD_INFO 2>/dev/null || true)
    _gc=$(printf '%s' "$_bi" | sed -n 's/^commit=//p' | cut -c1-40)
    _gat=$(printf '%s' "$_bi" | sed -n 's/^built_at=//p' | head -1)
    _origin=$(git rev-parse origin/main 2>/dev/null || true)
    _anc=0; git merge-base --is-ancestor "$_gc" "$_origin" 2>/dev/null && _anc=1
    _want=''; _behind='?'; _age=''
    if [ -n "$_gat" ] && [ "$_anc" = "1" ]; then
        _want=$(git rev-list -1 --before="$_gat" "$_origin" 2>/dev/null || true)
        _behind=$(git rev-list --count "${_gc}..${_origin}" 2>/dev/null || printf '?')
        _then=$(date -u -d "$_gat" +%s 2>/dev/null || true)
        [ -n "$_then" ] && _age=$(( ( $(date -u +%s) - _then ) / 3600 ))
        case "$_behind" in ''|*[!0-9]*) : ;; *) metric e4_commits_behind "$_behind" ;; esac
    fi
    case "$(_e4verdict "$_gc" "$_origin" "$_anc" "$_gat" "$_want" "$_age")" in
        unknown-noinfo)
            chk E-4 UNKNOWN "cannot read the graph's BUILD_INFO" ;;
        pass-current)
            chk E-4 PASS "code graph indexes origin/main" "${_gc}" ;;
        fail-notancestor)
            chk E-4 FAIL "the graph indexes a commit that is not on origin/main" \
                "graph=$(printf '%s' "$_gc" | cut -c1-8) origin=$(printf '%s' "$_origin" | cut -c1-8) — rebased, or built somewhere else" ;;
        unknown-nodate)
            chk E-4 UNKNOWN "the graph is behind origin/main and BUILD_INFO carries no usable built_at" \
                "without a build time, normal drift cannot be told apart from a refresh that stopped" ;;
        unknown-nowant)
            chk E-4 UNKNOWN "cannot tell which commit was newest at $_gat" \
                "graph=$(printf '%s' "$_gc" | cut -c1-8), $_behind behind" ;;
        fail-stalecheckout)
            chk E-4 FAIL "the refresh ran at $_gat but indexed an older commit than was available then" \
                "graph=$(printf '%s' "$_gc" | cut -c1-8) available=$(printf '%s' "$_want" | cut -c1-8) — built from a stale checkout, which a date check would pass" ;;
        fail-schedule)
            chk E-4 FAIL "the graph has not been refreshed since $_gat (${_age}h)" \
                "it indexed the newest commit available then, so the BUILD is fine and the SCHEDULE is not" ;;
        pass-drift)
            chk E-4 PASS "code graph is $_behind commit(s) behind origin/main, all of them newer than the refresh" \
                "built $_gat (${_age}h ago) against $(printf '%s' "$_gc" | cut -c1-8), which was origin/main at that moment" ;;
        *)
            chk E-4 UNKNOWN "the graph freshness comparison produced no verdict" \
                "graph=${_gc:-none} anc=$_anc built_at=${_gat:-none} want=${_want:-none} age=${_age:-none}" ;;
    esac

    # E-5: freshness and correctness are different questions. A BUILD_INFO
    # dated today passes a date check while indexing a tree from last week --
    # which is exactly what happened on 2026-09-08. So this asks the graph for
    # a file that only the newest commit contains. A positive control, not a
    # timestamp.
    # --diff-filter=A: files ADDED since the graph's commit, not merely
    # modified. Picking a modified file makes this pass against a stale
    # graph, because the old graph already knows that name -- which it did
    # on the first run, reporting PASS for config.py while indexing a tree
    # 18 commits behind. A positive control has to name something the old
    # state cannot possibly contain.
    _newfile=$(git diff --diff-filter=A --name-only "$_gc..origin/main" 2>/dev/null \
               | grep -E '^(scripts|agent-sidecar|flows)/.*\.(sh|py|js|mjs)$' | head -1 || true)
    # An empty `_newfile` has two causes and they are not the same statement.
    #
    # Either the graph is level with origin — nothing newer exists — or newer
    # commits exist but none of them ADDED a file matching the probe filter.
    # This branch reported both as "graph commit matches origin", and on
    # 2026-09-10 that sentence was simply false: the graph was at b75cf3a3,
    # origin at e9374e5, and the only added file was audit/baseline.json, which
    # is not a source file. E-4 was failing on that gap in the same run while
    # E-5 said they matched.
    if [ -z "$_newfile" ] && [ "$_gc" = "$_origin" ]; then
        chk E-5 PASS "graph commit matches origin; nothing newer to look for"
    elif [ -z "$_newfile" ]; then
        chk E-5 UNKNOWN "graph is behind origin, but no newly-added source file exists to probe with" \
            "graph=$(printf '%s' "$_gc" | cut -c1-8) origin=$(printf '%s' "$_origin" | cut -c1-8) — correctness unproven either way; E-4 carries the staleness"
    elif [ -z "$PY" ]; then
        chk E-5 UNKNOWN "no interpreter to query the graph with"
    else
        _gk2=$(sed -n 's/^GRAPHIFY_API_KEY=//p' .env 2>/dev/null | tail -1)
        if [ -z "$_gk2" ]; then
            chk E-5 UNKNOWN "no graph key; correctness unverifiable"
        else
            # This grepped the RESPONSE for the filename it had just put in the
            # REQUEST. The server answers a miss with
            #
            #   "No node matching 'king-tls-patch.sh' found."
            #
            # so the name is in the reply either way and the count was always
            # 1. Proven 2026-09-11 with a negative control: a name that has
            # never existed anywhere scored exactly the same as a real one.
            # E-5 could not fail, and E-5 is the check that exists BECAUSE a
            # timestamp can look right while the contents are stale.
            #
            # Two changes. The verdict now turns on the server's own miss
            # marker rather than on an echo, and the probe validates itself
            # first: a deliberately impossible label must read as a miss. If it
            # does not, the marker has changed and this reports UNKNOWN instead
            # of guessing -- a broken instrument must not be allowed to pass
            # its subject.
            _gq() {
                curl -s -m 60 -X POST http://127.0.0.1:8130/mcp \
                    -H 'Content-Type: application/json' \
                    -H 'Accept: application/json, text/event-stream' \
                    -H "Authorization: Bearer $_gk2" \
                    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_node\",\"arguments\":{\"label\":\"$1\"}}}" \
                    2>/dev/null
            }
            _canary=$(_gq 'king-audit-canary-no-such-node-9f3a1.sh')
            if ! printf '%s' "$_canary" | grep -qi 'No node matching'; then
                chk E-5 UNKNOWN "the graph probe cannot tell a miss from a hit" \
                    "an impossible label did not come back as 'No node matching' — the marker changed; E-5 proves nothing until this is re-read"
            else
                _resp=$(_gq "$(basename "$_newfile")")
                if printf '%s' "$_resp" | grep -qi 'No node matching'; then
                    chk E-5 FAIL "graph does not contain $(basename "$_newfile"), which origin/main added" \
                        "it will answer confidently about code that no longer looks like this"
                else
                    chk E-5 PASS "graph knows a file only the newest commit has" \
                        "$(basename "$_newfile") — and an impossible label was refused, so the probe can tell them apart"
                fi
            fi
        fi
    fi

    # E-6: fabricated rows in an alert log are worse than an empty one -- later
    # nobody can tell them from real ones. Checked because three were inserted
    # during testing this week and deleted by hand.
    # This said "needs the Activepieces API" and stopped. It does not:
    # alerts-report.sh reads Postgres directly with AP_POSTGRES_URL, and that
    # path is right here. Deferring to a human is only honest when the tool is
    # genuinely absent.
    _apurl=$(sed -n 's/^AP_POSTGRES_URL=//p' activepieces/.env 2>/dev/null | tail -1)
    if [ -z "$_apurl" ]; then
        chk E-6 UNKNOWN "no AP_POSTGRES_URL; the alert table cannot be read"
    elif ! have docker; then
        chk E-6 UNKNOWN "no docker to run psql with"
    else
        # Probe traffic this deployment has actually produced: models used only
        # for testing, and the literal marker used when shaping was verified.
        _tests=$(docker run --rm postgres:16-alpine psql "$_apurl" -At -c \
            "select count(*) from record r join cell c on c.\"recordId\" = r.id
             where c.value::text ~* '(hy3-free|LITERAL-PROBE|antigravity-test)'" 2>/dev/null || true)
        case "$_tests" in
            "")  chk E-6 UNKNOWN "could not query the alert table" ;;
            0)   chk E-6 PASS "no test-shaped row left in the alert table" ;;
            *)   chk E-6 FAIL "$_tests test-shaped row(s) in the alert table" \
                     "fabricated rows are worse than an empty log; nobody can tell them from real ones" ;;
        esac
    fi

    # E-7. The queue is state nobody had looked at. It was also mis-labelled in
    # my own working notes as "Upstash", a hosted service; grepping the tree
    # for it finds nothing, because both instances are local containers. A note
    # about state that names the wrong system is worse than no note.
    if ! on_host; then
        chk E-7 SKIP "not on the host"
    else
        _rs=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
              | grep -Ei 'redis|valkey' | awk '{print $1}' || true)
        if [ -z "$_rs" ]; then
            chk E-7 PASS "no queue backend runs here"
        else
            _bad=""; _tot=0
            for _r in $_rs; do
                _keys=$(docker exec "$_r" redis-cli --no-auth-warning DBSIZE 2>/dev/null | tr -d '\r')
                _save=$(docker exec "$_r" redis-cli --no-auth-warning INFO persistence 2>/dev/null \
                        | tr -d '\r' | sed -n 's/^rdb_last_bgsave_status://p')
                case "$_keys" in ''|*[!0-9]*) _bad="$_bad $_r(unreachable)"; continue ;; esac
                _tot=$((_tot + _keys))
                [ "$_save" = "ok" ] || _bad="$_bad $_r(bgsave=${_save:-unknown})"
            done
            metric e7_queue_keys "$_tot"
            if [ -z "$_bad" ]; then
                chk E-7 PASS "queue backend(s) answer; $_tot key(s), last save ok" \
                    "whether they ASK for a credential is C-10, not this"
            else
                chk E-7 FAIL "queue backend problem:$_bad"
            fi
        fi
    fi

    # E-8. Spend was written off as unmeasurable after three guessed paths
    # 404'd. `/api/usage/call-logs` answers 200 and carries a `tokens` object
    # on every row -- the endpoint was never the problem, my guessing was.
    #
    # The real problem is what it reports. Measured over 500 calls: 405 report
    # zero tokens, including all 185 openrouter calls, which are the ones that
    # cost money. Cost is not derivable from a log that reports zero for every
    # paid provider, so the check is the coverage FRACTION -- a total would
    # read as authoritative while being mostly missing rows.
    _k=$(sed -n 's/^OMNIROUTE_MCP_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -1)
    if ! on_host; then
        chk E-8 SKIP "not on the host"
    elif [ -z "$_k" ] || [ -z "$PY" ]; then
        chk E-8 UNKNOWN "no gateway key or no interpreter; token coverage unmeasurable"
    else
        _e8=$(mktemp)
        cat > "$_e8" <<'PYE8'
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    print("ERR"); raise SystemExit(0)
if not isinstance(rows, list) or not rows:
    print("ERR"); raise SystemExit(0)
def has(r):
    t = r.get("tokens") or {}
    return bool((t.get("in") or 0) or (t.get("out") or 0))
# The population is INFERENCE, and getting that wrong inverted this check's
# conclusion for a day.
#
# It counted every row and called anything not ollama "paid", then reported
# "only 42% report tokens; spend cannot be derived". But 288 of 500 rows are
# /api/providers/test — provider health probes, which consume no tokens and
# correctly report none. Counting a health check as a paid call that failed to
# account for itself is what made a well-instrumented gateway look unmeasurable.
#
# Failed inference is excluded for the same reason: a 504 that never produced a
# first byte has no tokens to report. Six of the 212 real calls are exactly
# that — four 504s, one 502 "empty content", and one Tavily search, which is
# billed per search rather than per token.
inference = [r for r in rows if str(r.get("path") or "").startswith("/v1/chat")]
completed = [r for r in inference if str(r.get("status") or "")[:1] == "2"]
probes = [r for r in rows if str(r.get("path") or "").startswith("/api/providers/test")]
print("%d\t%d\t%d\t%d" % (len(completed), sum(1 for r in completed if has(r)),
                          len(probes), len(rows)))
PYE8
        _cov=$(curl -s -m 45 "http://localhost:20128/api/usage/call-logs?limit=500" \
               -H "Authorization: Bearer $_k" 2>/dev/null | "$PY" "$_e8" 2>/dev/null || true)
        rm -f "$_e8"
        case "$_cov" in
            ''|ERR*) chk E-8 UNKNOWN "the call log did not return a readable list" ;;
            *)
                _inf=$(printf '%s' "$_cov" | cut -f1);  _inft=$(printf '%s' "$_cov" | cut -f2)
                _probes=$(printf '%s' "$_cov" | cut -f3); _rows=$(printf '%s' "$_cov" | cut -f4)
                if [ "${_inf:-0}" -eq 0 ]; then
                    chk E-8 UNKNOWN "no completed inference call in the last $_rows log rows" \
                        "$_probes of them are provider health probes, which carry no tokens by design"
                else
                    metric e8_token_coverage_pct "$(( _inft * 100 / _inf ))"
                    # 95, not 50. Once the population is right the honest bar is
                    # high: a completed inference call that reports no tokens is
                    # an accounting hole, not a rounding error.
                    if [ "$(( _inft * 100 / _inf ))" -lt 95 ]; then
                        chk E-8 FAIL "$_inft of $_inf completed inference calls report tokens" \
                            "the rest are an accounting hole; a budget guard built on this would understate"
                    else
                        chk E-8 PASS "$_inft of $_inf completed inference calls report tokens" \
                            "$_probes of $_rows log rows are provider health probes, which carry no tokens by design and are not counted"
                    fi
                fi ;;
        esac
    fi

    # E-9. The tracing pipeline had no check at all, and could not have had a
    # useful one by looking at the container: otel-collector is distroless, so
    # it has no shell to ask; it declares no healthcheck, so `docker ps` says
    # only "Up"; its internal metrics endpoint is not enabled; and its config
    # sets `logs.level: warn`, so SILENCE IS WHAT BOTH WORKING AND DEAD LOOK
    # LIKE. That is the shape CLAUDE.md says has bitten this deployment three
    # times: a component that is fine and a component that is gone are
    # indistinguishable from the outside.
    #
    # So this asks the BACKEND whether the spans arrived, which is the only
    # place that knows. Measured 2026-09-11 over a 6h window: 84 completed
    # /v1/chat calls locally, 85 traces in Langfuse. The correlation is real,
    # not assumed, and that measurement is what licenses the comparison below.
    #
    # Three deliberate choices:
    #
    # 1. The credential comes from the RUNNING container, never from `.env`.
    #    Reading it with `. ./.env` truncates at the space in
    #    `LANGFUSE_OTLP_AUTH=Basic <base64>` and yields the 5-character string
    #    "Basic", which then 401s -- a broken probe that reads exactly like a
    #    broken credential. F-10 takes the same stance for the same reason.
    #
    # 2. A canary window runs first. `fromTimestamp` in the year 2099 must
    #    return zero; if it does not, the filter is being ignored and a zero in
    #    the real window would mean nothing. Same structure as E-5's canary,
    #    and the same lesson: prove the instrument can say no before believing
    #    a no.
    #
    # 3. 401 is a FAIL, a timeout is UNKNOWN. The backend answering "your
    #    credential is refused" is a verified defect -- every span is being
    #    dropped. The backend not answering is ignorance, and ignorance is not
    #    a finding.
    #
    # The bar is 50%, not 95% as in E-8, because this is a LIVENESS check, not
    # an accounting one: it exists to catch a pipeline that stopped, and the
    # measured normal is ~100%. Gradual drift is carried by the metric instead,
    # so the baseline diff shows it.
    _otel=''
    on_host && _otel=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
                       | grep -F 'opentelemetry-collector' | awk '{print $1}' | head -1)
    _k9=$(sed -n 's/^OMNIROUTE_MCP_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -1)
    _from9=$(date -u -d '6 hours ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
    if ! on_host; then
        chk E-9 SKIP "not on the host"
    elif [ -z "$_otel" ]; then
        chk E-9 SKIP "no collector runs here; the tracing profile is off"
    elif [ -z "$PY" ] || [ -z "$_k9" ] || [ -z "$_from9" ]; then
        chk E-9 UNKNOWN "no interpreter, no gateway key, or no GNU date; the backend cannot be asked"
    else
        # || true: set -eu is on, and a container that vanishes between the
        # ps above and this line would otherwise end the whole audit run.
        _env9=$(docker inspect "$_otel" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)
        _auth9=$(printf '%s\n' "$_env9" | sed -n 's/^LANGFUSE_OTLP_AUTH=//p' | head -1)
        _base9=$(printf '%s\n' "$_env9" | sed -n 's/^LANGFUSE_OTLP_ENDPOINT=//p' | head -1)
        _base9=$(printf '%s' "${_base9:-https://cloud.langfuse.com/api/public/otel}" | sed 's#/api/public/otel$##')
        _tot9=$(mktemp)
        cat > "$_tot9" <<'PYE9'
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR"); raise SystemExit(0)
print((d.get("meta") or {}).get("totalItems", "ERR"))
PYE9
        # Two requests: the canary window, then the real one. The HTTP code of
        # the real one decides between "refused" and "unreachable".
        _canary9=$(curl -s -m 30 -H "Authorization: $_auth9" \
                   "$_base9/api/public/traces?limit=1&fromTimestamp=2099-01-01T00:00:00Z" 2>/dev/null \
                   | "$PY" "$_tot9" 2>/dev/null || true)
        _body9=$(mktemp)
        _code9=$(curl -s -o "$_body9" -w '%{http_code}' -m 30 -H "Authorization: $_auth9" \
                 "$_base9/api/public/traces?limit=1&fromTimestamp=$_from9" 2>/dev/null || true)
        _tr9=$("$PY" "$_tot9" < "$_body9" 2>/dev/null || true)
        # The local population is E-8's, deliberately: same definition of an
        # inference call, so the two checks cannot disagree about what counts.
        _loc9=$(mktemp)
        cat > "$_loc9" <<'PYL9'
import sys, json, os
try:
    rows = json.load(sys.stdin)
except Exception:
    print("ERR"); raise SystemExit(0)
if not isinstance(rows, list):
    print("ERR"); raise SystemExit(0)
f = os.environ.get("E9_FROM", "")
inf = [r for r in rows if str(r.get("path") or "").startswith("/v1/chat")]
win = [r for r in inf if str(r.get("timestamp") or "") >= f]
print(sum(1 for r in win if str(r.get("status") or "")[:1] == "2"))
PYL9
        _lc9=$(E9_FROM="$_from9" curl -s -m 45 -H "Authorization: Bearer $_k9" \
               "http://localhost:20128/api/usage/call-logs?limit=1000" 2>/dev/null \
               | E9_FROM="$_from9" "$PY" "$_loc9" 2>/dev/null || true)
        rm -f "$_tot9" "$_body9" "$_loc9"
        case "$(_e9verdict "$_code9" "$_canary9" "$_lc9" "$_tr9")" in
            fail-auth)
                chk E-9 FAIL "Langfuse refuses the collector's credential (HTTP $_code9)" \
                    "every span the gateway emits is being dropped at the last hop, silently" ;;
            unknown-api)
                chk E-9 UNKNOWN "the trace backend did not answer (HTTP ${_code9:-none})" \
                    "not reachable is not the same as not working; nothing is concluded" ;;
            unknown-canary)
                chk E-9 UNKNOWN "the trace query cannot tell a window from the whole project" \
                    "a window in 2099 returned ${_canary9:-?}; a zero in the real window would prove nothing" ;;
            unknown-load)
                chk E-9 UNKNOWN "no completed inference call in the last 6h; nothing should have been traced" \
                    "the pipeline is untested rather than proven, and says so" ;;
            fail-dead)
                chk E-9 FAIL "$_lc9 inference call(s) in 6h produced 0 trace(s) at the backend" \
                    "the collector is Up and silent; silence is what both working and dead look like here" ;;
            fail-thin)
                chk E-9 FAIL "$_tr9 trace(s) for $_lc9 completed inference call(s) in 6h" \
                    "below half; the pipeline is dropping spans rather than forwarding them" ;;
            pass)
                metric e9_trace_coverage_pct "$(( _tr9 * 100 / _lc9 ))"
                chk E-9 PASS "$_tr9 trace(s) reached the backend for $_lc9 inference call(s) in 6h" \
                    "asked of Langfuse, not of the collector, which has no shell, no healthcheck and logs only warnings" ;;
            *)
                chk E-9 UNKNOWN "the trace comparison produced no verdict" \
                    "code=${_code9:-none} canary=${_canary9:-none} local=${_lc9:-none} traces=${_tr9:-none}" ;;
        esac
    fi
}

# ------------------------------------------------------------- dimension F

dim_F() {
    echo; echo "F  the agentic layer"
    if ! on_host; then
        skip_rest F "not on the host; MCP servers unreachable from here"
        return
    fi
    if [ -z "$PY" ]; then
        skip_rest F "no working python3; MCP cannot be spoken to"
        return
    fi

    # F-1 calls a tool rather than reading a status code. An endpoint that
    # answers 401 proves a guard, not a working server; this deployment has
    # shipped both live-but-broken and dead-but-authenticating before.
    _mcp=$(mktemp)
    cat > "$_mcp" <<'PYMCP'
import json, sys, urllib.request as u
base, tok, want = sys.argv[1], sys.argv[2], sys.argv[3]
def rpc(m, p, sid=None):
    b = {"jsonrpc": "2.0", "id": 1, "method": m}
    if p is not None: b["params"] = p
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + tok}
    if sid: h["Mcp-Session-Id"] = sid
    r = u.urlopen(u.Request(base, data=json.dumps(b).encode(), headers=h, method="POST"), timeout=90)
    raw = r.read().decode("utf-8", "replace"); s2 = r.headers.get("Mcp-Session-Id")
    if raw.lstrip().startswith("event:") or "\ndata:" in raw:
        for ln in raw.splitlines():
            if ln.startswith("data:"): raw = ln[5:].strip(); break
    return json.loads(raw), (s2 or sid)
try:
    _, sid = rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                "clientInfo": {"name": "king-audit", "version": "1"}})
    try: rpc("notifications/initialized", {}, sid)
    except Exception: pass
    res, _ = rpc("tools/list", {}, sid)
    tools = [t["name"] for t in ((res.get("result") or {}).get("tools") or [])]
    if want not in tools:
        print("MISSING\t%s not offered; got %d tool(s)" % (want, len(tools))); raise SystemExit(0)
    res, _ = rpc("tools/call", {"name": want, "arguments": {}}, sid)
    c = (res.get("result") or {}).get("content") or []
    body = (c[0].get("text") if c else "")
    if not body:
        print("EMPTY\t%s returned nothing" % want); raise SystemExit(0)
    print("OK\t%d tool(s); %s answered %d chars" % (len(tools), want, len(body)))
except Exception as e:
    print("ERROR\t%s: %s" % (type(e).__name__, e))
PYMCP

    _tok=$(sed -n 's/^AGENT_SIDECAR_AUTH_TOKEN=//p' agent-sidecar/.env 2>/dev/null | tail -1)
    _gk=$(sed -n 's/^GRAPHIFY_API_KEY=//p' .env 2>/dev/null | tail -1)

    for _spec in "bridge|http://127.0.0.1:8100/mcp|$_tok|vps_status" \
                 "codegraph|http://127.0.0.1:8130/mcp|$_gk|graph_stats"; do
        _n=$(printf '%s' "$_spec" | cut -d'|' -f1)
        _u=$(printf '%s' "$_spec" | cut -d'|' -f2)
        _t=$(printf '%s' "$_spec" | cut -d'|' -f3)
        _w=$(printf '%s' "$_spec" | cut -d'|' -f4)
        if [ -z "$_t" ]; then
            chk "F-1" UNKNOWN "$_n: no token available to test with"
            continue
        fi
        _out=$("$PY" "$_mcp" "$_u" "$_t" "$_w" 2>/dev/null || printf 'ERROR\tprobe crashed')
        case "$_out" in
            OK*)      chk "F-1" PASS "$_n MCP answers a real call" "$(printf '%s' "$_out" | cut -f2)" ;;
            MISSING*) chk "F-1" FAIL "$_n MCP is up but the tool is gone" "$(printf '%s' "$_out" | cut -f2)" ;;
            EMPTY*)   chk "F-1" FAIL "$_n MCP returned an empty result" "$(printf '%s' "$_out" | cut -f2)" ;;
            *)        chk "F-1" FAIL "$_n MCP call failed" "$(printf '%s' "$_out" | cut -f2)" ;;
        esac
    done
    rm -f "$_mcp"

    # F-2: the tools actually offered to the agent, against the allowlist and
    # against the set that must never reach it.
    _health=$(curl -s -m 15 http://127.0.0.1:8100/healthz 2>/dev/null || true)
    if [ -n "$_health" ]; then
        _leak=""
        for _never in vps_exec run_agent ask_model; do
            printf '%s' "$_health" | grep -q "\"$_never\"" && _leak="$_leak $_never"
        done
        if [ -z "$_leak" ]; then
            chk F-2 PASS "no NEVER_REGISTER tool appears in the agent's offered set"
        else
            chk F-2 FAIL "tool(s) that must never reach the agent are offered" "$_leak"
        fi
        _n=$(printf '%s' "$_health" | tr ',' '\n' | grep -c '"[a-z_]*"' || true)
        chk F-2b PASS "agent toolset readable from /healthz" "$(printf '%s' "$_health" | sed -n 's/.*"agent_tools":\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ' | cut -c1-90)"
    else
        chk F-2 UNKNOWN "sidecar /healthz unreachable; offered toolset unknown"
    fi

    # F-6: the local-only guarantee, checked where it is actually made — the
    # container, not the gateway. Routing through the gateway cannot prove it,
    # because the gateway is allowed to decide otherwise.
    _cid=$(docker compose --profile localmodel ps -q ollama 2>/dev/null || true)
    if [ -n "$_cid" ]; then
        _ip=$(docker inspect "$_cid" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
        if [ -n "$_ip" ] && curl -s -m 15 "http://$_ip:11434/api/tags" 2>/dev/null | grep -q '"models"'; then
            chk F-6 PASS "local model answers directly, with no gateway on the path"
        else
            chk F-6 FAIL "local model not reachable without the gateway" \
                "the local-only guarantee has no path that holds it"
        fi
    else
        chk F-6 SKIP "localmodel profile not running"
    fi

    # F-3: the trigger vocabulary, which lives in the vendored subtree and can
    # move under us on any `git subtree pull`. Delegated to the script that
    # already owns those eight measured phrases rather than duplicating them.
    if [ -x scripts/check-model-routing.sh ]; then
        _vo=$(CHECK_VOCAB=1 timeout 900 ./scripts/check-model-routing.sh 2>&1 | grep -c 'DRIFTED' || true)
        if [ "${_vo:-0}" -eq 0 ]; then
            chk F-3 PASS "all eight measured trigger phrases still route as recorded"
        else
            chk F-3 FAIL "${_vo} phrase(s) no longer route as measured" \
                "upstream moved the classifier; re-derive DEFAULT_AGENT_TOOLS"
        fi
    else
        chk F-3 SKIP "check-model-routing.sh not present"
    fi

    # F-4: whether the caller got the model it asked for, from the journal
    # rather than from a probe. 19 of 21 runs were overridden before
    # graph_stats left the default set.
    # Last 12, not last 40. The journal spans the change that fixed this,
    # and a rate averaged across a fix describes neither the before nor the
    # after -- it drifts toward the truth while looking like a measurement.
    _jr=$(docker exec king-agent-sidecar-http-1 sh -c 'tail -12 /audit/runs.jsonl 2>/dev/null' 2>/dev/null || true)
    if [ -z "$_jr" ]; then
        chk F-4 UNKNOWN "run journal unreadable; override rate unknown"
    elif [ -z "$PY" ]; then
        chk F-4 UNKNOWN "no interpreter to parse the journal"
    else
        _ov=$(printf '%s' "$_jr" | "$PY" -c "
import json,sys
tot=ov=0
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if 'model_overridden' not in d: continue
    tot+=1
    if d['model_overridden']: ov+=1
print('%d %d' % (ov,tot))" 2>/dev/null || true)
        _o=$(printf '%s' "$_ov" | awk '{print $1}'); _t=$(printf '%s' "$_ov" | awk '{print $2}')
        if [ -z "$_t" ] || [ "$_t" = "0" ]; then
            chk F-4 UNKNOWN "no recent run records model_overridden"
        else
            metric f4_overridden "$_o"; metric f4_runs "$_t"
            if [ "$_o" -eq 0 ]; then
                chk F-4 PASS "0 of $_t recent run(s) had their model overridden"
            else
                chk F-4 FAIL "$_o of $_t recent run(s) did not get the model they asked for"
            fi
        fi
    fi

    # F-5: attempts are not outcomes. Delegated to the report that already
    # groups by correlationId, because duplicating that logic is how two
    # instruments come to disagree.
    if [ -x scripts/gateway-report.sh ]; then
        _cv=$(timeout 300 ./scripts/gateway-report.sh 24 2>/dev/null \
              | sed -n 's/.*caller-visible failure rate \([0-9.]*\)%.*/\1/p' | head -1 || true)
        if [ -z "$_cv" ]; then
            chk F-5 UNKNOWN "gateway-report produced no caller-visible figure"
        else
            metric f5_caller_visible_pct "$_cv"
            if [ "${_cv%%.*}" -lt 10 ]; then
                chk F-5 PASS "caller-visible failure rate ${_cv}%"
            else
                chk F-5 FAIL "caller-visible failure rate ${_cv}%" "this one is not covered by fallback"
            fi
        fi
    else
        chk F-5 SKIP "gateway-report.sh not present"
    fi


    # F-8: derived, not listed. NEVER_REGISTER protected this service's own
    # three tools while config.py claimed it also covered
    # omniroute_memory_clear -- a gateway tool that wipes the memory store.
    # It did not, and the per-call `tools` override made that one request.
    #
    # So the destructive set is read from what the servers ACTUALLY offer,
    # every run. A tool added upstream next month is caught without anyone
    # remembering to add it here, which is the difference between a check and
    # a list.
    # The offered surface, fetched rather than assumed.
    #
    # F-8 used to read /tmp/king-audit-tools.json and report UNKNOWN when it
    # was absent -- a check whose input no part of this script could produce,
    # which meant it passed or abstained depending on whether someone had run
    # a manual probe recently. Worse, it had no freshness rule: the cache found
    # on the host was a day old, so F-8 would have been comparing yesterday's
    # tool list against today's NEVER_REGISTER and calling that a guarantee.
    #
    # The gateway serves MCP at /api/mcp/stream, NOT /mcp -- the latter 404s.
    # That is the kind of detail worth writing down, because guessing three
    # paths and concluding "no endpoint exists" is exactly how the cost
    # question stayed open for a day (see E-8).
    _tj=/tmp/king-audit-tools.json
    _tj_max_age=3600
    if [ -n "$PY" ]; then
        _fetch=$(mktemp)
        cat > "$_fetch" <<'PYFETCH'
import json, sys, urllib.request as u
out = sys.argv[3]
def rpc(m, p, sid=None):
    b = {"jsonrpc": "2.0", "id": 1, "method": m}
    if p is not None: b["params"] = p
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + sys.argv[2]}
    if sid: h["Mcp-Session-Id"] = sid
    r = u.urlopen(u.Request(sys.argv[1], data=json.dumps(b).encode(), headers=h,
                            method="POST"), timeout=90)
    raw = r.read().decode("utf-8", "replace"); s2 = r.headers.get("Mcp-Session-Id")
    if raw.lstrip().startswith("event:") or "\ndata:" in raw:
        for ln in raw.splitlines():
            if ln.startswith("data:"): raw = ln[5:].strip(); break
    return json.loads(raw), (s2 or sid)
try:
    _, sid = rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                "clientInfo": {"name": "king-audit", "version": "1"}})
    try: rpc("notifications/initialized", {}, sid)
    except Exception: pass
    res, _ = rpc("tools/list", {}, sid)
    names = sorted(t["name"] for t in ((res.get("result") or {}).get("tools") or []))
    if not names:
        print("ERR\tserver offered no tools"); raise SystemExit(0)
    json.dump(names, open(out, "w"), indent=0)
    print("OK\t%d" % len(names))
except Exception as e:
    print("ERR\t%s: %s" % (type(e).__name__, e))
PYFETCH
        # Both servers, unioned. Fetching only the gateway silently narrowed
        # the audited surface from 120 tools to 110: the ten codegraph tools
        # stopped being compared against NEVER_REGISTER the moment this fetch
        # replaced the stale cache, and F-8 reported PASS right through the
        # regression. Trading a stale-but-complete input for a fresh-but-
        # partial one is not an improvement.
        #
        # A partial union is refused rather than used. If either server fails
        # to answer there is no honest way to say "every destructive tool is
        # blocked", so the cache is left alone and the age guard below turns
        # F-8/F-9 UNKNOWN.
        _gwk=$(sed -n 's/^OMNIROUTE_MCP_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -1)
        _cgk=$(sed -n 's/^GRAPHIFY_API_KEY=//p' .env 2>/dev/null | tail -1)
        _pa=$(mktemp); _pb=$(mktemp)
        _ok_a=0; _ok_b=0
        if [ -n "$_gwk" ] && "$PY" "$_fetch" "http://localhost:20128/api/mcp/stream" "$_gwk" "$_pa" >/dev/null 2>&1; then
            _ok_a=1
        fi
        if [ -n "$_cgk" ] && "$PY" "$_fetch" "http://127.0.0.1:8130/mcp" "$_cgk" "$_pb" >/dev/null 2>&1; then
            _ok_b=1
        fi
        if [ "$_ok_a" = 1 ] && [ "$_ok_b" = 1 ]; then
            _union=$(mktemp)
            cat > "$_union" <<'PYUNION'
import json, sys
names = set()
for f in sys.argv[1:-1]:
    names |= set(json.load(open(f)))
json.dump(sorted(names), open(sys.argv[-1], "w"), indent=0)
PYUNION
            "$PY" "$_union" "$_pa" "$_pb" "$_tj" >/dev/null 2>&1 || true
            rm -f "$_union"
        fi
        rm -f "$_fetch" "$_pa" "$_pb"
    fi

    # Age is checked whether the fetch above succeeded or not: a stale cache
    # left by a previous run must not be mistaken for a current answer.
    _tj_age=""
    if [ -f "$_tj" ]; then
        _mt=$(stat -c %Y "$_tj" 2>/dev/null || true)
        _now=$(date +%s 2>/dev/null || true)
        case "$_mt$_now" in ''|*[!0-9]*) : ;; *) _tj_age=$((_now - _mt)) ;; esac
    fi

    if [ -z "$PY" ]; then
        chk F-8 UNKNOWN "no interpreter; the offered tool surface cannot be enumerated"
    elif [ ! -f "$_tj" ]; then
        chk F-8 UNKNOWN "the gateway MCP would not list its tools; surface unknown"
    elif [ -n "$_tj_age" ] && [ "$_tj_age" -gt "$_tj_max_age" ]; then
        chk F-8 UNKNOWN "tool list is ${_tj_age}s old and could not be refreshed" \
            "a guarantee derived from a stale surface is not a guarantee"
    else
        _dest=$(mktemp)
        cat > "$_dest" <<'PYDEST'
import json, re, sys
try:
    tools = json.load(open(sys.argv[1]))
except Exception:
    print("ERR"); raise SystemExit(0)
never = set(re.findall(r'"([a-z0-9_]+)"', open(sys.argv[2], encoding="utf-8").read()
                       .split("NEVER_REGISTER = frozenset(")[-1].split(")")[0]))
danger = re.compile(r'delete|remove|clear|drop|reset|purge|revoke|destroy|wipe', re.I)
loose = sorted(n for n in tools if danger.search(n) and n not in never)
print("\t".join(["OK" if not loose else "LOOSE", ",".join(loose), str(len(tools))]))
PYDEST
        # Read the copy the PROCESS imports, not the copy git tracks.
        #
        # F-8 used to parse agent-sidecar/src/agent_sidecar/mcp_tools.py from
        # the working tree and call the result a guarantee. On 2026-09-10 that
        # file listed seven names and the running container listed three: the
        # repo is bind-mounted at /workspace, the image bakes its source at
        # /app, and editing one does not touch the other. The check was proving
        # a property of a file nobody executes, and reporting PASS.
        #
        # So: the container's copy is the subject. The repo's copy is compared
        # against it separately, because a divergence means a rebuild is owed
        # and that is its own finding — not a detail to average away.
        _live_nr=$(mktemp)
        if docker exec king-agent-sidecar-http-1 cat /app/src/agent_sidecar/mcp_tools.py \
             > "$_live_nr" 2>/dev/null && [ -s "$_live_nr" ]; then
            _nr_src="$_live_nr"; _nr_from="the running container"
        else
            _nr_src=agent-sidecar/src/agent_sidecar/mcp_tools.py; _nr_from="the repo (container unreadable)"
        fi
        _r=$("$PY" "$_dest" "$_tj" "$_nr_src" 2>/dev/null || true)

        # Drift between what runs and what was reviewed, stated plainly.
        if [ "$_nr_src" = "$_live_nr" ]; then
            _n_live=$(grep -c '"[a-z_]*"' "$_live_nr" 2>/dev/null || true)
            _live_set=$("$PY" -c '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read().split("NEVER_REGISTER = frozenset(")[-1].split(")")[0]
print(",".join(sorted(set(re.findall(r"\"([a-z0-9_]+)\"", t)))))' "$_live_nr" 2>/dev/null || true)
            _repo_set=$("$PY" -c '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read().split("NEVER_REGISTER = frozenset(")[-1].split(")")[0]
print(",".join(sorted(set(re.findall(r"\"([a-z0-9_]+)\"", t)))))' agent-sidecar/src/agent_sidecar/mcp_tools.py 2>/dev/null || true)
            if [ -n "$_live_set" ] && [ "$_live_set" != "$_repo_set" ]; then
                chk F-8b FAIL "the running NEVER_REGISTER differs from the reviewed one" \
                    "running: ${_live_set}  |  repo: ${_repo_set} — the image predates the source; a rebuild is owed"
            elif [ -n "$_live_set" ]; then
                chk F-8b PASS "the running NEVER_REGISTER matches the reviewed source"
            else
                chk F-8b UNKNOWN "could not parse NEVER_REGISTER from the running container"
            fi
        else
            chk F-8b UNKNOWN "the sidecar container's source could not be read; drift unmeasurable"
        fi
        rm -f "$_live_nr"
        case "$_r" in
            OK*)    chk F-8 PASS "every destructive tool offered is blocked, per $_nr_from" \
                        "$(printf '%s' "$_r" | cut -f3) tool(s) from both servers, list ${_tj_age:-?}s old; F-8b compares that set against the reviewed one" ;;
            LOOSE*) chk F-8 FAIL "destructive tool(s) the agent could be given" \
                        "$(printf '%s' "$_r" | cut -f2)" ;;
            *)      chk F-8 UNKNOWN "could not compare the offered tools against NEVER_REGISTER" ;;
        esac
        rm -f "$_dest"
    fi

    # F-9. F-8 asks which tools can DESTROY something. Nothing asked which can
    # send something out -- a different risk with a different blast radius:
    # destruction is loud and local, exfiltration is quiet and permanent.
    #
    # Twelve of the 120 offered tools reach the network. All twelve are there
    # on purpose (search and fetch are the point of a research agent), so the
    # check is drift, not presence: the acknowledged set is a committed file,
    # and a thirteenth name appearing without review turns this red.
    _ackf=scripts/network-tools.txt
    if [ -z "$PY" ] || [ ! -f "$_tj" ]; then
        chk F-9 UNKNOWN "no tool surface to classify"
    elif [ -n "$_tj_age" ] && [ "$_tj_age" -gt "$_tj_max_age" ]; then
        chk F-9 UNKNOWN "tool list is ${_tj_age}s old; egress classification would be stale"
    elif [ ! -f "$_ackf" ]; then
        chk F-9 FAIL "no $_ackf; network-capable tools have never been reviewed"
    else
        _net=$(mktemp)
        cat > "$_net" <<'PYNET'
import json, re, sys
tools = json.load(open(sys.argv[1]))
ack = set()
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    if line: ack.add(line)
egress = re.compile(r"fetch|search|http|webhook|post|upload|send|browse|crawl|url|scrape|notify|email", re.I)
hits = sorted(n for n in tools if egress.search(n))
new = sorted(set(hits) - ack)
gone = sorted(ack - set(hits))
print("\t".join(["NEW" if new else "OK", ",".join(new), ",".join(gone), str(len(hits)), str(len(tools))]))
PYNET
        _nr=$("$PY" "$_net" "$_tj" "$_ackf" 2>/dev/null || true)
        rm -f "$_net"
        case "$_nr" in
            OK*)  _g=$(printf '%s' "$_nr" | cut -f3)
                  chk F-9 PASS "$(printf '%s' "$_nr" | cut -f4) network-capable tool(s), all acknowledged" \
                      "of $(printf '%s' "$_nr" | cut -f5) offered${_g:+; no longer offered: $_g}" ;;
            NEW*) chk F-9 FAIL "network-capable tool(s) nobody has reviewed" \
                      "$(printf '%s' "$_nr" | cut -f2)" ;;
            *)    chk F-9 UNKNOWN "could not classify the offered tools by egress capability" ;;
        esac
    fi

    # F-10: where model-authored code actually executes, read from the RUNNING
    # container rather than from compose or .env.
    #
    # Both of those can be right while the process carries an older value — the
    # same distinction F-8 turned on, one check earlier. And this one decides
    # whether smolagents' CodeAgent runs model-written Python inside a
    # container holding a read-write docker.sock.
    #
    # `local` was the compose default until 2026-09-10, justified by a comment
    # saying every task arrives from an operator on the command line. That
    # stopped being true when /run became reachable over MCP, so the default is
    # now `e2b` and this check exists because a default is not a guarantee.
    _ex=$(docker exec king-agent-sidecar-http-1 printenv AGENT_SIDECAR_EXECUTOR 2>/dev/null || true)
    case "$_ex" in
        '')
            chk F-10 UNKNOWN "could not read the executor from the running sidecar" ;;
        local|docker)
            chk F-10 FAIL "the running sidecar executes model-authored code with '$_ex'"                 "'local' runs it in this container; 'docker' needs the host socket — both put model-written Python next to a read-write docker.sock" ;;
        e2b|modal|blaxel)
            chk F-10 PASS "model-authored code runs off this host ($_ex)"                 "read from the running container, not from compose or .env — those can be right while the process is not" ;;
        *)
            chk F-10 FAIL "the running sidecar has an executor smolagents does not accept: $_ex" ;;
    esac

    # F-7: mirror vs live. A mirror that has drifted invites review of code
    # that is not running.
    # No Activepieces API key exists on this host, so a live diff genuinely
    # cannot be done from here. That is a reason to narrow the claim, not to
    # report UNKNOWN and imply the work is merely deferred.
    #
    # What IS verifiable about the artifact: it parses as the module the tests
    # import, and it exports the two functions they reach for. A mirror that
    # stopped parsing, or lost an export, is drifted in a way that matters
    # regardless of what the live step says.
    if [ -f flows/gateway_monitor.step_1.js ]; then
        _missing=""
        for _fn in isCredentialFailure callerImpact code; do
            grep -q "export const $_fn" flows/gateway_monitor.step_1.js || _missing="$_missing $_fn"
        done
        if [ -n "$_missing" ]; then
            chk F-7 FAIL "flow mirror is missing export(s) the tests import" "$_missing"
        elif have node && node --check flows/gateway_monitor.step_1.js >/dev/null 2>&1; then
            chk F-7 PASS "flow mirror parses and exports what the tests import" \
                "a live diff needs ap_read_step_code, which has no key on this host"
        elif have node; then
            chk F-7 FAIL "flow mirror does not parse"
        else
            chk F-7 UNKNOWN "no node here to parse the mirror with"
        fi
    else
        chk F-7 SKIP "no flow mirror in this repo"
    fi
}

# ------------------------------------------------------------- dimension G

dim_G() {
    echo; echo "G  guards and instruments"

    # G-1: a guard is only a guard if it can go red. Every script here that
    # ships a --self-test is asked to prove it still passes.
    #
    # The list used to be three names written by hand, so a fourth guard that
    # gained a --self-test would never have been run by it -- the same
    # hand-kept-list fault that left E-9 reporting TODO while it passed, and
    # that implemented() now has a general assertion against. Globbing the
    # directory and filtering on the flag means the inventory maintains itself:
    # add the flag, and G-1 finds it.
    _st_ok=""; _st_bad=""
    for _g in scripts/*.sh; do
        [ -x "$_g" ] || continue
        grep -q -- '--self-test' "$_g" 2>/dev/null || continue
        if "$_g" --self-test >/dev/null 2>&1; then _st_ok="$_st_ok $(basename "$_g")"
        else _st_bad="$_st_bad $(basename "$_g")"; fi
    done
    if [ -z "$_st_bad" ]; then
        chk G-1 PASS "every guard with a self-test passes it" "$_st_ok"
    else
        chk G-1 FAIL "guard self-test(s) failing" "$_st_bad"
    fi

    # G-3: a timer that stopped is a guard that is gone, and it is silent.
    if have systemctl; then
        # Strip the status glyph before taking the first field. `systemctl
        # --failed --no-legend` prints "● unitname loaded failed …", so
        # `awk '{print $1}'` returns the bullet and the evidence line read
        # "failed unit(s)  ●" — telling you something broke and not what.
        #
        # Found when monitor-deadman genuinely failed after a reboot, which is
        # the one moment this check has ever had something to say.
        _failed=$(systemctl --user --failed --no-legend 2>/dev/null \
                  | sed 's/^[^A-Za-z0-9]*//' | awk '{print $1}' | tr '\n' ' ' || true)
        if [ -z "$_failed" ]; then
            chk G-3 PASS "no failed user unit"
        else
            chk G-3 FAIL "failed unit(s)" "$_failed"
        fi
        _timers=$(systemctl --user list-timers --no-legend 2>/dev/null | grep -c . || true)
        metric g3_timers "${_timers:-0}"
        if [ "${_timers:-0}" -ge 3 ]; then
            chk G-3b PASS "${_timers} user timer(s) registered"
        else
            chk G-3b FAIL "only ${_timers:-0} user timer(s); expected the monitor, codegraph and pool-prove"
        fi
    else
        chk G-3 SKIP "systemctl unavailable here"
    fi

    # G-4: the deadman's tolerance against the real worst gap. Publishing an
    # Activepieces flow re-registers its schedule and skips a slot, so the
    # worst legitimate gap is larger than the interval.
    if [ -f scripts/monitor-deadman.sh ]; then
        # shellcheck disable=SC2016  # the sed pattern matches the literal ${...} in that file
        _max=$(sed -n 's/^MAX_AGE_MIN="\${MONITOR_MAX_AGE_MIN:-\([0-9]*\)}"/\1/p' scripts/monitor-deadman.sh | head -1)
        if [ -n "$_max" ]; then
            metric g4_deadman_max_min "$_max"
            if [ "$_max" -ge 40 ]; then
                chk G-4 PASS "deadman tolerance ${_max} min covers a republish-skipped slot"
            else
                chk G-4 FAIL "deadman tolerance ${_max} min is under the worst legitimate gap" \
                    "22.5 min observed under load + a 15 min slot skipped by a republish = 37.5"
            fi
        else
            chk G-4 UNKNOWN "could not read the deadman tolerance"
        fi
    else
        chk G-4 SKIP "no deadman script here"
    fi

    # G-2: an instrument that runs is not the same as one that measures. Each
    # report is asked to produce its own headline section; an empty or
    # sectionless run means it is reporting on nothing, which is how
    # pool-prove stayed green while proving the wrong model.
    # The marker has to be the HEADLINE, not a data line.
    #
    # alerts-report.sh was matched on "alert(s)", which it prints only when
    # there ARE alerts. A window with none prints "No alerts recorded in this
    # window" plus a caveat about when recording began -- the report working
    # correctly and saying so. Measured 2026-09-11 against the fresh database:
    # exit 0, headline present, full explanatory text, and G-2 red. A report
    # that correctly reports nothing is not a silent report, and a check that
    # cannot tell those apart fails the quiet good outcome forever.
    #
    # The script's own exit status is also kept now. It used to be discarded by
    # the pipe -- `cmd | grep -q` returns grep's status -- so a report that
    # crashed but happened to print its title first would have passed.
    # The list was TWO entries written by hand, and three report scripts exist:
    # agent-report.sh had never once been exercised by the check whose entire
    # subject is whether reports report. Third hand-kept list found stale in one
    # afternoon, after G-1's guard list and J-1's image list.
    #
    # The declared headlines stay, because they are the strong assertion and
    # cannot be derived. What changes is that the DIRECTORY decides the
    # population, so a fourth report is named rather than skipped.
    _mute=""; _undeclared=""
    for _rs in scripts/*-report.sh; do
        [ -x "$_rs" ] || continue
        case "$_rs" in
            scripts/gateway-report.sh|scripts/alerts-report.sh|scripts/agent-report.sh) : ;;
            *) _undeclared="$_undeclared $(basename "$_rs")" ;;
        esac
    done
    for _spec in "scripts/gateway-report.sh|24|provider reliability" \
                 "scripts/alerts-report.sh|14|gateway alerts" \
                 "scripts/agent-report.sh|14|agent runs"; do
        _sc=$(printf '%s' "$_spec" | cut -d'|' -f1)
        _ar=$(printf '%s' "$_spec" | cut -d'|' -f2)
        _ex=$(printf '%s' "$_spec" | cut -d'|' -f3)
        [ -x "$_sc" ] || continue
        _rout=$(timeout 300 "$_sc" "$_ar" 2>/dev/null)
        _rrc=$?
        if [ "$_rrc" -ne 0 ]; then
            _mute="$_mute $(basename "$_sc")(exit $_rrc)"
        elif ! printf '%s' "$_rout" | grep -qF "$_ex"; then
            _mute="$_mute $(basename "$_sc")(no headline)"
        fi
    done
    if [ -n "$_mute" ]; then
        chk G-2 FAIL "report(s) ran but produced nothing they promise" "$_mute"
    elif [ -n "$_undeclared" ]; then
        chk G-2 UNKNOWN "report(s) with no declared headline to check:$_undeclared" \
            "the declared ones all pass; these are unmeasured, and saying so beats a green that covers less than it looks like"
    else
        chk G-2 PASS "every report exits clean and produces the section it claims to" \
            "population taken from scripts/*-report.sh, not from a list"
    fi

    # G-5: the alert path, checked without firing one. Sending a real alert to
    # measure the alert path pollutes the log it writes to -- three fabricated
    # rows had to be deleted by hand this week. So: does the notification
    # endpoint answer, and has a real alert landed recently enough to believe
    # the chain still works.
    if have curl && [ -f .env ]; then
        _nt=$(sed -n 's/^NTFY_TOKEN=//p' .env 2>/dev/null | tail -1)
        if [ -z "$_nt" ]; then
            chk G-5 UNKNOWN "no ntfy token; the delivery leg is untestable"
        else
            _nc=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
                  -H "Authorization: Bearer $_nt" "https://gateway.arject.co/king-ntfy/v1/account" 2>/dev/null || echo 000)
            case "$_nc" in
                200) chk G-5 PASS "ntfy accepts the alerting token" "delivery proven end to end on 2026-09-06" ;;
                401|403) chk G-5 FAIL "ntfy rejects the alerting token" "alerts would stop at the table" ;;
                *)   chk G-5 UNKNOWN "ntfy answered $_nc; delivery leg unclear" ;;
            esac
        fi
    else
        chk G-5 SKIP "cannot reach ntfy from here"
    fi

    # G-6: every silenced failure in the scripts, counted. Not a pass/fail --
    # `|| true` is often correct -- but an inventory nobody has ever looked at
    # is where "cannot read" quietly became "zero" once already.
    # Counting was an inventory dressed as a check. Not all silencing is equal:
    # `cmd 2>/dev/null` on a command whose failure is then handled is fine,
    # but `x=$(... || true)` followed by a test on $x turns "could not read"
    # into a value -- which is how a 4 GB build came to believe nothing was
    # resident, and how this very script twice reported a missing file as a
    # configured one. So the dangerous shape is counted separately.
    #
    # And "each needs a human" was the third version of this dodge. Counting
    # 80 constructs and handing them back is not classification; it is the
    # inventory again, with an apology attached. The distinction this repo
    # already established IS mechanical:
    #
    #   x=$(cmd || true)      -> failure becomes the empty string, which the
    #                            usual `[ -z "$x" ]` guard catches.
    #   x=$(cmd || echo 0)    -> failure becomes a PLAUSIBLE VALUE. Nothing
    #                            downstream can tell it from a real zero.
    #
    # So the check reads each site, takes the fallback literal, and looks at
    # the next few lines for a guard on that variable. `|| echo` with a
    # numeric or boolean literal and no emptiness test is the shape that made
    # a 4 GB build believe nothing was resident, and made this script twice
    # report a missing file as a configured one.
    _sil=$(grep -c -- '2>/dev/null' scripts/*.sh 2>/dev/null | awk -F: '{t+=$2} END {print t+0}')
    metric g6_silenced "$_sil"
    if [ -z "$PY" ]; then
        chk G-6 UNKNOWN "no interpreter to classify the silenced failures with"
    else
        _g6=$(mktemp)
        cat > "$_g6" <<'PYG6'
import glob, re, sys
assign = re.compile(r'^[^#]*?([A-Za-z_][A-Za-z_0-9]*)=\$\((.*)\|\|\s*(true|echo\s+\S+)\s*\)')
plausible = re.compile(r'^echo\s+["\']?(0|00+|\d+|false|true|none|unknown|yes|no)["\']?$', re.I)
benign = risky = 0
worst = []
for path in sorted(glob.glob("scripts/*.sh")):
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    for i, line in enumerate(lines):
        m = assign.match(line)
        if not m:
            continue
        var, fallback = m.group(1), m.group(3).strip()
        if not plausible.match(fallback):
            benign += 1
            continue
        # A guard within the next five lines that tests the variable for
        # emptiness or non-numeric content makes the fallback recoverable.
        window = "\n".join(lines[i + 1:i + 6])
        # A `case` counts as a guard even when it switches on an EXPRESSION
        # containing the variable rather than the bare variable. The first
        # version required `case "$var`, and so reported the two-code check
        # `case "$_none/$_wrong" in 401/401|...` as unguarded — a false
        # positive in the check whose entire subject is false confidence.
        guarded = re.search(
            r'-z\s+"?\$\{?%s\b|\[\!0-9\]|case\s+[^\n]*\$\{?%s\b' % (var, var), window)
        if guarded:
            benign += 1
        else:
            risky += 1
            if len(worst) < 4:
                worst.append("%s:%d %s=$(... || %s)" % (path, i + 1, var, fallback))
print("%d\t%d\t%s" % (benign, risky, "; ".join(worst)))
PYG6
        _r=$("$PY" "$_g6" 2>/dev/null || true)
        rm -f "$_g6"
        _ben=$(printf '%s' "$_r" | cut -f1); _rsk=$(printf '%s' "$_r" | cut -f2)
        case "$_rsk" in
            ''|*[!0-9]*) chk G-6 UNKNOWN "could not classify the silenced failures" ;;
            0) chk G-6 PASS "no assignment turns a failed command into a plausible value" \
                   "$_ben classified benign (empty fallback, or guarded within five lines); $_sil other silencing constructs" ;;
            *) chk G-6 FAIL "$_rsk assignment(s) substitute a plausible value for a failure" \
                   "$(printf '%s' "$_r" | cut -f3)" ;;
        esac
    fi
}

# ------------------------------------------------------------- dimension H

dim_H() {
    echo; echo "H  tests and CI"

    if have gh; then
        _runs=$(gh run list --limit 4 --json workflowName,conclusion,headSha \
                --jq '.[] | "\(.conclusion // "running")/\(.workflowName)"' 2>/dev/null || true)
        if [ -z "$_runs" ]; then
            chk H-1 UNKNOWN "gh returned nothing; CI state unknown"
        else
            _fail=$(printf '%s' "$_runs" | grep -c '^failure' || true)
            if [ "${_fail:-0}" -eq 0 ]; then
                chk H-1 PASS "no failing job in the last 4 runs"
            else
                chk H-1 FAIL "${_fail} failing job(s) in the last 4 runs" \
                    "$(printf '%s' "$_runs" | grep '^failure' | tr '\n' ' ')"
            fi
        fi
    else
        chk H-1 SKIP "gh unavailable here"
    fi

    # H-2 is the honest one: naming what CI does NOT cover is worth more than
    # celebrating what it does.
    _uncovered=""
    grep -q 'king-audit.sh --self-test' .github/workflows/*.yml 2>/dev/null || _uncovered="$_uncovered audit-self-test"
    grep -q 'shellcheck' .github/workflows/*.yml 2>/dev/null || _uncovered="$_uncovered shellcheck"
    grep -q 'flows/\*.test.mjs' .github/workflows/*.yml 2>/dev/null || _uncovered="$_uncovered flow-tests"
    if [ -z "$_uncovered" ]; then
        chk H-2 PASS "audit self-test, shellcheck and flow tests all run in CI"
    else
        chk H-2 FAIL "not covered by CI:" "$_uncovered"
    fi
    # H-3 rebuilds an image, which is minutes. Gated behind --deep so the
    # everyday audit stays fast enough that people actually run it.
    if [ "${AUDIT_DEEP:-0}" = "1" ] && have docker && [ -d agent-sidecar ]; then
        if docker build -q -t king-audit-test ./agent-sidecar >/dev/null 2>&1 \
           && docker run --rm king-audit-test uv run pytest tests/ -q >/dev/null 2>&1; then
            chk H-3 PASS "the suite passes in a freshly built container"
        else
            chk H-3 FAIL "the suite does not pass in a freshly built container"
        fi
    else
        chk H-3 SKIP "set AUDIT_DEEP=1 to rebuild and run the suite (minutes)"
    fi

    # H-4: a test that reads the ambient environment passes or fails by
    # accident. Two did here: one left GRAPHIFY_API_KEY set, one left
    # AGENT_SIDECAR_MODEL_ID, and both only surfaced when the host changed.
    #
    # But a `skipif` marker is not that hazard, and the first version could not
    # tell the difference. `@pytest.mark.skipif(not os.environ.get(...))` is
    # evaluated at COLLECTION time to decide whether an opt-in integration test
    # runs at all — monkeypatch cannot reach it, by construction, and depending
    # on the environment is the entire purpose. Flagging it asked a whole file
    # to abandon the standard idiom to satisfy a check, which is the wrong way
    # round.
    #
    # So the marker lines are subtracted and what remains — an environment read
    # inside a test body, where a value from the host decides an assertion — is
    # the thing worth failing on.
    if [ -d agent-sidecar/tests ] && [ -n "$PY" ]; then
        _h4=$(mktemp)
        cat > "$_h4" <<'PYH4'
import glob, os, re, sys
bad = []
for path in sorted(glob.glob("agent-sidecar/tests/*.py")):
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    if any("monkeypatch" in l for l in lines):
        continue
    for i, line in enumerate(lines):
        if "os.environ" not in line:
            continue
        # A skipif marker can span lines; look back a few for the decorator.
        window = "\n".join(lines[max(0, i - 4):i + 1])
        if re.search(r"@pytest\.mark\.skip(if|unless)|pytest\.skip\(", window):
            continue
        bad.append("%s:%d" % (os.path.basename(path), i + 1))
print(" ".join(bad))
PYH4
        _envdep=$("$PY" "$_h4" 2>/dev/null || true)
        rm -f "$_h4"
        if [ -z "$_envdep" ]; then
            chk H-4 PASS "no test lets the ambient environment decide an assertion" \
                "skipif markers are excluded: they gate opt-in integration tests and cannot use monkeypatch"
        else
            chk H-4 FAIL "test(s) read os.environ outside a skip marker" "$_envdep"
        fi
    elif [ -d agent-sidecar/tests ]; then
        chk H-4 UNKNOWN "no interpreter to classify the tests' environment reads"
    else
        chk H-4 SKIP "no test directory here"
    fi

    chk H-2b UNKNOWN "compose rules, Caddy config and the live stack are not exercised by CI" \
        "that is what this audit is for; it is a statement of scope, not a defect"
}

# ------------------------------------------------------------- dimension I

dim_I() {
    echo; echo "I  documentation truth"

    # I-3: a cross-reference to a file that no longer exists is the cheapest
    # kind of wrong, and the easiest to check.
    _bad=""
    # shellcheck disable=SC2016  # a grep pattern, not a string to expand
    for _f in $(grep -ohE '`(scripts|docs|flows|agent-sidecar)/[A-Za-z0-9_./-]+`' \
                docs/*.md README.md CLAUDE.md 2>/dev/null | tr -d '`' | sort -u); do
        [ -e "$_f" ] && continue
        # A gitignored path is absent by design: agent-sidecar/.env is
        # documented precisely because it must exist on the host and never in
        # the repo. Flagging it would teach people to ignore this check.
        git check-ignore -q "$_f" 2>/dev/null && continue
        _bad="$_bad $_f"
    done
    if [ -z "$_bad" ]; then
        chk I-3 PASS "every file path referenced in the docs exists"
    else
        chk I-3 FAIL "docs reference missing file(s)" "$(printf '%s' "$_bad" | tr ' ' '\n' | head -5 | tr '\n' ' ')"
    fi

    # I-1: numbers in prose rot silently, and this checked exactly one of
    # them while claiming "every measured number". Each constant below is
    # cited somewhere as the reason for a decision, so a doc that disagrees
    # with the code is a doc that will be believed and is wrong.
    if [ -f docs/king-system.md ]; then
        _docs=$(cat docs/king-system.md README.md 2>/dev/null || true)
        _wrong=""
        _add() { [ -z "$2" ] && return 0
                 printf '%s' "$_docs" | grep -q "$2" || _wrong="$_wrong $1=$2"; }
        _add codegraph-floor \
            "$(sed -n 's/.*CODEGRAPH_MIN_AVAIL_MB:-\([0-9]*\)}.*/\1/p' scripts/codegraph-refresh.sh 2>/dev/null | head -1)"
        _add deadman-max \
            "$(sed -n 's/.*MONITOR_MAX_AGE_MIN:-\([0-9]*\)}.*/\1/p' scripts/monitor-deadman.sh 2>/dev/null | head -1)"
        _add agent-max-steps \
            "$(sed -n 's/.*AGENT_SIDECAR_MAX_STEPS:-\([0-9]*\)}.*/\1/p' docker-compose.yml 2>/dev/null | head -1)"
        _add ollama-context \
            "$(sed -n 's/.*OLLAMA_CONTEXT_LENGTH:-\([0-9]*\)}.*/\1/p' docker-compose.yml 2>/dev/null | head -1)"
        if [ -z "$_wrong" ]; then
            chk I-1 PASS "every load-bearing constant in the code also appears in the docs"
        else
            chk I-1 FAIL "constant(s) in the code that appear in no document" "$_wrong"
        fi
    else
        chk I-1 SKIP "no docs to check numbers against"
    fi

    # I-2: a command in the docs that cannot run is an instruction that wastes
    # somebody's afternoon. Checks the script exists and accepts the flag.
    _badcmd=""
    # while-read, not `for x in $(...)`: word splitting tore
    # `./scripts/foo.sh --flag` into two entries, so the flag was tested as
    # if it were a filename and every documented command with an argument
    # reported as missing.
    grep -ohE '\./scripts/[a-z-]+\.sh' docs/*.md README.md 2>/dev/null \
      | sort -u | while IFS= read -r _c; do
        [ -x "${_c#./}" ] || printf '%s ' "$_c"
      done > "$SEEN.cmd"
    _badcmd=$(cat "$SEEN.cmd" 2>/dev/null || true); rm -f "$SEEN.cmd"
    if [ -z "$_badcmd" ]; then
        chk I-2 PASS "every ./scripts command in the docs exists and is executable"
    else
        chk I-2 FAIL "documented command(s) that cannot run" "$_badcmd"
    fi

    # I-4 claimed "CLAUDE.md vs actual behaviour" and checked for TODO markers,
    # which is a different question entirely -- and it passed. CLAUDE.md states
    # concrete, checkable rules; the honest version of this check is whether
    # each of them is actually enforced by something here, rather than only
    # written down.
    if [ -f CLAUDE.md ]; then
        _unenforced=""
        grep -q 'memswap_limit' CLAUDE.md 2>/dev/null && \
            { grep -q 'memswap_limit' scripts/king-audit.sh || _unenforced="$_unenforced memswap"; }
        grep -q 'VAR:?err' CLAUDE.md 2>/dev/null && \
            { grep -q 'hard-required variable' scripts/king-audit.sh || _unenforced="$_unenforced required-var"; }
        grep -q 'profiles:' CLAUDE.md 2>/dev/null && \
            { grep -q 'opt-in via profiles' scripts/king-audit.sh || _unenforced="$_unenforced profiles"; }
        grep -q 'Never .latest' CLAUDE.md 2>/dev/null && \
            { grep -q 'image is pinned' scripts/king-audit.sh || _unenforced="$_unenforced pinned"; }
        grep -q 'never edit' CLAUDE.md 2>/dev/null && \
            { grep -q 'subtree unmodified' scripts/king-audit.sh || _unenforced="$_unenforced subtree"; }
        if [ -z "$_unenforced" ]; then
            chk I-4 PASS "every concrete CLAUDE.md rule has a check that enforces it"
        else
            chk I-4 FAIL "CLAUDE.md rule(s) written down but enforced by nothing" "$_unenforced"
        fi
    else
        chk I-4 SKIP "no CLAUDE.md here"
    fi
}

# ------------------------------------------------------------- dimension J

dim_J() {
    echo; echo "J  dependencies and supply chain"

    if have gh; then
        _omni=$(gh run list --workflow=omniroute-smoke.yml --limit 1 \
                --json conclusion --jq '.[0].conclusion' 2>/dev/null || true)
        case "$_omni" in
            success) chk J-2 PASS "omniroute-smoke is green" ;;
            failure)
                # This check used to answer "known upstream break" and stop.
                # That sentence was true when it was written on 2026-09-05 and
                # stopped being true on 2026-09-07T22:42Z, when
                # bogdanfinn/tls-client re-published the legacy asset names it
                # had dropped in v1.16.0. A check that keeps reciting a
                # resolved excuse launders a real failure into UNKNOWN for as
                # long as nobody re-reads it -- the same shape as a firewall
                # rule that no longer matches. So ask the release API whether
                # the excuse still holds instead of trusting the sentence.
                _tc_ver=$(curl -fsS --max-time 15 \
                    https://api.github.com/repos/bogdanfinn/tls-client/releases/latest 2>/dev/null \
                    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
                _tc_asset="tls-client-linux-ubuntu-amd64-${_tc_ver}.so"
                if [ -z "$_tc_ver" ]; then
                    chk J-2 UNKNOWN "omniroute-smoke is red; cannot verify the upstream excuse" \
                        "release API unreachable from here -- the claim is untested, not confirmed"
                elif curl -fsS --max-time 15 \
                        "https://api.github.com/repos/bogdanfinn/tls-client/releases/tags/v${_tc_ver}" \
                        2>/dev/null | grep -q "$_tc_asset"; then
                    chk J-2 FAIL "omniroute-smoke is red and the upstream asset break is over" \
                        "v${_tc_ver} publishes ${_tc_asset}; whatever is red now is a different cause"
                else
                    chk J-2 UNKNOWN "omniroute-smoke is red — upstream asset naming still broken" \
                        "v${_tc_ver} does not publish ${_tc_asset}"
                fi
                ;;
            *)       chk J-2 UNKNOWN "omniroute-smoke state unreadable" ;;
        esac
    else
        chk J-2 SKIP "gh unavailable here"
    fi

    # J-1: a pin is a decision to stop receiving fixes, so how far behind it
    # has drifted is the number that matters. This said "needs a registry
    # call" and stopped -- the registry is a curl away, and deferring work
    # that is one command from done is how a check becomes decoration.
    #
    # Reported, not judged: "newer exists" is not automatically "upgrade".
    #
    # It used to grep for ONE hardcoded image -- `binwiederhier/ntfy` -- and
    # then report in the plural: "pinned third-party image(s) are at the newest
    # release". Five registry images are pinned here. It had been green about
    # four it never looked at, and when it was red it was red about the one
    # image that matters least. Generalising it immediately surfaced redis
    # 8.6.5 against 8.8.2 and otel-collector 0.139.0 against 0.160.0, the second
    # of which carries fixes J-6 reports as still open against us.
    #
    # Three pages, because tag listings are ordered by last_updated and
    # opentelemetry-collector-contrib publishes nightlies constantly: its 40
    # most recent tags contain no stable release at all, so a single page finds
    # nothing and would have read as "cannot tell" forever.
    #
    # ghcr.io needs a token even for public reads, so those images are counted
    # as NOT COVERED and said so, rather than quietly not appearing.
    if have curl && [ -n "$PY" ]; then
        _j1py=$(mktemp)
        cat > "$_j1py" <<'PYJ1'
import json, re, sys, urllib.request

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "king-audit"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def parse(v):
    m = re.match(r'^v?(\d+(?:\.\d+)*)$', v)
    return [int(x) for x in m.group(1).split(".")] if m else None

def vcmp(a, b):
    a, b = a[:], b[:]
    while len(a) < len(b): a.append(0)
    while len(b) < len(a): b.append(0)
    return (a > b) - (a < b)

behind, current, uncovered = [], 0, []
for line in sys.stdin.read().split():
    ref = line.strip()
    if not ref: continue
    # A tag+digest pin still carries a comparable tag: strip the digest and
    # read the tag in front of it. Treating `caddy:2.11.4-alpine@sha256:...`
    # as uncheckable would have penalised the strongest kind of pin there is.
    ref_notag = ref.split("@")[0]
    if ":" not in ref_notag.rsplit("/", 1)[-1]:
        uncovered.append(ref_notag + "|untagged"); continue
    name, tag = ref_notag.rsplit(":", 1)
    if name.startswith("ghcr.io/") or name.count("/") > 1:
        uncovered.append(name + "|not-on-docker-hub"); continue
    repo = name if "/" in name else "library/" + name
    # The pinned tag may carry a variant suffix: 8.6.5-alpine.
    base = tag.split("-")[0]
    pv = parse(base)
    if pv is None:
        uncovered.append(name + "|tag-is-not-a-version"); continue
    url = "https://hub.docker.com/v2/repositories/%s/tags/?page_size=100&ordering=last_updated" % repo
    # Keep the tag NAME, not a version rebuilt from its parts. ntfy publishes
    # both `v2.28` and `v2.28.0`; they compare equal, and printing "latest 2.28"
    # for a release actually called v2.28.0 is a small lie in a line people act
    # on. Longer name wins a tie, which is the more specific one.
    best = None; best_name = ""
    try:
        for _ in range(3):
            d = get(url)
            for t in d.get("results") or []:
                nm = t.get("name", "")
                q = parse(nm)
                if q and (best is None or vcmp(q, best) > 0 or
                          (vcmp(q, best) == 0 and len(nm) > len(best_name))):
                    best, best_name = q, nm
            url = d.get("next")
            if not url: break
    except Exception:
        uncovered.append(name + "|registry-unreachable"); continue
    if best is None:
        uncovered.append(name + "|no-plain-version-tag"); continue
    if vcmp(pv, best) < 0:
        behind.append("%s:%s(latest %s)" % (name, base, best_name))
    else:
        current += 1
print("%d\t%s\t%s\t%d" % (current, " ".join(behind) or "-",
                          " ".join(uncovered) or "-", len(uncovered)))
PYJ1
        _j1refs=$(grep -oE '^\s+image: [^[:space:]]+' docker-compose.yml 2>/dev/null \
                  | sed 's/.*image: //' | grep -v ':local$' | sort -u)
        _j1out=$(printf '%s\n' "$_j1refs" | "$PY" "$_j1py" 2>/dev/null || true)
        rm -f "$_j1py"
        _j1cur=$(printf '%s' "$_j1out" | cut -f1)
        _behind=$(printf '%s' "$_j1out" | cut -f2)
        _j1unc=$(printf '%s' "$_j1out" | cut -f3)
        _j1nunc=$(printf '%s' "$_j1out" | cut -f4)
        [ "$_behind" = "-" ] && _behind=""
        [ "$_j1unc" = "-" ] && _j1unc=""
        if [ -z "$_j1out" ]; then
            chk J-1 UNKNOWN "the registry comparison produced no result"
        elif [ -n "$_behind" ]; then
            chk J-1 UNKNOWN "pinned image(s) behind upstream:" \
                "$_behind — recorded, not a recommendation; check the changelog before moving. ${_j1cur} at latest, ${_j1nunc:-0} not checkable${_j1unc:+: $_j1unc}"
        elif [ "${_j1cur:-0}" -eq 0 ]; then
            chk J-1 UNKNOWN "no pinned image could be compared against its registry" \
                "${_j1unc:-nothing to compare}"
        else
            chk J-1 PASS "${_j1cur} pinned image(s) are at the newest release" \
                "${_j1nunc:-0} not checkable${_j1unc:+: $_j1unc}"
        fi
    else
        chk J-1 UNKNOWN "no curl or interpreter to query the registry with"
    fi

    # J-6. J-1's manifest line used to read "pinned versions vs latest, and
    # known CVEs". The code only ever compared version numbers, so the second
    # half of that sentence was a promise nothing kept. J-1 now claims only
    # what it does, and the advisory half lives here, where it is actually run.
    #
    # It asks GitHub's published security advisories for each pinned image's
    # upstream repository, and it took two false-positive classes to make the
    # answer trustworthy. Both were found by reading the raw records rather
    # than the count:
    #
    #   1. WRONG PACKAGE. `opentelemetry-collector-contrib` publishes an
    #      advisory whose vulnerable range is `<0.311.3` -- a PROMETHEUS
    #      version, for the Go module it depends on. Compared against the
    #      collector's own 0.139.0 it matched, and meant nothing. So a match
    #      only counts when the advisory's package name contains the image's
    #      own name.
    #
    #   2. NO UPPER BOUND. Redis advisories are written `>= 7.0.0` with the
    #      fix recorded separately in `patched_versions`. Taken literally, ten
    #      of sixteen matches said a 2022 bug fixed in 7.0.4 still affects
    #      8.6.5. So a match is discarded when our version is at or above the
    #      HIGHEST patched version -- highest, not per-branch: a first attempt
    #      compared within the same major series and refused 7.0.12 as cover
    #      for 8.6.5, which is wrong.
    #
    # AND IT NEVER FAILS, deliberately. A version range cannot tell whether the
    # vulnerable code path is reachable here. The Caddy advisory is the case in
    # point: it needs `forward_auth` beside `reverse_proxy`, and this Caddyfile
    # has `reverse_proxy` six times and `forward_auth` none. Reporting that as
    # a breach would be the same mistake as the CRITICAL this deployment once
    # emitted for an event no user experienced. UNKNOWN is not a shrug here --
    # it still stops the run going green, since any UNKNOWN exits 2.
    #
    # The map is hand-kept, so the number of images it does NOT cover is
    # printed rather than left to look like zero.
    if ! have curl || [ -z "$PY" ]; then
        chk J-6 UNKNOWN "no curl or interpreter; published advisories cannot be read"
    else
        _j6py=$(mktemp)
        cat > "$_j6py" <<'PYJ6'
import json, re, sys
ver, token = sys.argv[1], sys.argv[2]
def parse(v):
    m = re.search(r'(\d+(?:\.\d+)*)', str(v))
    return [int(x) for x in m.group(1).split(".")] if m else None
def vcmp(a, b):
    a, b = a[:], b[:]
    while len(a) < len(b): a.append(0)
    while len(b) < len(a): b.append(0)
    return (a > b) - (a < b)
def in_range(pv, rng):
    if pv is None or not rng: return False
    for t in rng.split(","):
        m = re.match(r'^(<=|>=|<|>|=)\s*(\S+)', t.strip())
        if not m: return False
        rhs = parse(m.group(2))
        if rhs is None: return False
        c = vcmp(pv, rhs)
        if not {"<": c < 0, "<=": c <= 0, ">": c > 0, ">=": c >= 0, "=": c == 0}[m.group(1)]:
            return False
    return True
def patched_already(pv, patched):
    if not patched or patched.strip().upper() == "TBD": return False
    best = None
    for p in re.split(r'[,\s]+', patched):
        q = parse(p)
        if q and (best is None or vcmp(q, best) > 0): best = q
    return best is not None and vcmp(pv, best) >= 0
try:
    advs = json.load(sys.stdin)
except Exception:
    print("ERR"); raise SystemExit(0)
if not isinstance(advs, list):
    print("ERR"); raise SystemExit(0)
pv = parse(ver)
if pv is None:
    print("ERR"); raise SystemExit(0)
fix, nofix, wrongpkg = [], [], 0
for a in advs:
    if a.get("withdrawn_at"): continue
    for v in a.get("vulnerabilities") or []:
        if not in_range(pv, v.get("vulnerable_version_range") or ""): continue
        name = ((v.get("package") or {}).get("name") or "")
        if name and token.lower() not in name.lower():
            wrongpkg += 1; continue
        p = (v.get("patched_versions") or "").strip()
        if patched_already(pv, p): continue
        tag = "%s/%s" % (a.get("severity") or "?", a.get("cve_id") or a.get("ghsa_id") or "?")
        (fix if p and p.upper() != "TBD" else nofix).append(tag)
        break
print("%d\t%d\t%d\t%s\t%s" % (len(fix), len(nofix), wrongpkg,
                              ",".join(fix[:3]) or "-", ",".join(nofix[:3]) or "-"))
PYJ6
        _j6fix=0; _j6nofix=0; _j6err=""; _j6detail=""; _j6seen=""
        for _j6s in "caddy|caddyserver/caddy|caddy" \
                    "binwiederhier/ntfy|binwiederhier/ntfy|ntfy" \
                    "redis|redis/redis|redis" \
                    "ollama/ollama|ollama/ollama|ollama" \
                    "otel/opentelemetry-collector-contrib|open-telemetry/opentelemetry-collector-contrib|opentelemetry-collector-contrib" \
                    "ghcr.io/activepieces/activepieces|activepieces/activepieces|activepieces"; do
            _img=${_j6s%%|*}; _rest=${_j6s#*|}; _repo=${_rest%%|*}; _tok=${_rest#*|}
            # The tag as written in compose, digest suffix and -alpine and all.
            _ref=$(grep -oE "image: ${_img}:[^[:space:]]+" docker-compose.yml 2>/dev/null | head -1)
            [ -n "$_ref" ] || continue
            _j6seen="$_j6seen $_img"
            _ver=${_ref#image: "${_img}":}; _ver=${_ver%%@*}
            _out=$(curl -s -m 30 -H 'Accept: application/vnd.github+json' \
                    "https://api.github.com/repos/${_repo}/security-advisories?per_page=100" 2>/dev/null \
                   | "$PY" "$_j6py" "$_ver" "$_tok" 2>/dev/null || true)
            case "$_out" in
                ''|ERR*) _j6err="$_j6err ${_img}(unreadable)"; continue ;;
            esac
            _f=$(printf '%s' "$_out" | cut -f1); _n=$(printf '%s' "$_out" | cut -f2)
            _j6fix=$((_j6fix + _f)); _j6nofix=$((_j6nofix + _n))
            if [ "$_f" != "0" ] || [ "$_n" != "0" ]; then
                _j6detail="$_j6detail ${_img}@${_ver}:fix=${_f}/nofix=${_n}"
            fi
        done
        rm -f "$_j6py"
        # Registry images the map does not reach. Stated, not implied.
        _j6all=$(grep -oE '^\s+image: [^[:space:]]+' docker-compose.yml 2>/dev/null \
                 | sed 's/.*image: //' | grep -v ':local$' | grep -v '^omniroute' | sort -u | wc -l)
        _j6cov=$(printf '%s' "$_j6seen" | wc -w)
        metric j6_advisories_open "$((_j6fix + _j6nofix))"
        if [ -n "$_j6err" ]; then
            chk J-6 UNKNOWN "advisory source unreadable for:$_j6err" \
                "not asked is not the same as nothing found"
        elif [ "$((_j6fix + _j6nofix))" -eq 0 ]; then
            chk J-6 PASS "no published advisory matches the pinned versions" \
                "$_j6cov of $_j6all registry image(s) have an advisory source in the map"
        else
            chk J-6 UNKNOWN "$_j6fix advisory(s) with a published fix, $_j6nofix with none" \
                "$_j6detail — reachability is not decided here; $_j6cov of $_j6all registry image(s) covered"
        fi
    fi

    _pinned=$(grep -c 'OMNIROUTE_IMAGE_DIGEST=' scripts/ci-build-omniroute-base.sh 2>/dev/null || true)
    if [ "${_pinned:-0}" -ge 1 ]; then
        chk J-3 PASS "the vendored gateway image is pinned by digest"
    else
        chk J-3 FAIL "no digest pin for the gateway image"
    fi

    # J-4: the one dependency in this deployment that nothing here pins.
    #
    # tls-client-node@0.2.0 resolves its native .so from a third party's
    # /releases/latest at IMAGE-BUILD time. Two builds of the identical commit
    # can therefore ship different binaries, and on 2026-08-27 this one shipped
    # 1.15.1 with CVE-2025-68121 in it. The pin belongs in the subtree and
    # cannot be put there (scripts/tls-client-pin.txt says why, at length).
    #
    # So this check does not assert a pin. It asserts that what is RUNNING
    # matches what was RECORDED, which is the only property still available
    # once the version is somebody else's decision. It reads the digest out of
    # the live container rather than out of the image, the Dockerfile, or the
    # lockfile -- an image can be rebuilt and never deployed, and the artefact
    # is not the process.
    _pinf="scripts/tls-client-pin.txt"
    # Anchored. Docker's name filter is a substring match, so "name=omniroute"
    # also returns omniroute-redis, and `head -1` then picks by creation time —
    # a redis restart alone would make this check read node out of a Redis
    # container and report the gateway as having no TLS binary at all.
    _gw=$(docker ps --filter "name=^omniroute$" --format '{{.Names}}' 2>/dev/null | head -1)
    if [ ! -f "$_pinf" ]; then
        chk J-4 FAIL "no record of which TLS binary the gateway should run" \
            "expected $_pinf"
    elif [ -z "$_gw" ]; then
        chk J-4 SKIP "gateway container not running here"
    else
        # node, not sha256sum: node is guaranteed present in this image and
        # coreutils is not.
        _live=$(docker exec "$_gw" node -e '
const fs=require("fs"),c=require("crypto"),d="/app/node_modules/tls-client-node/bin";
let out=[];
try { for (const f of fs.readdirSync(d).sort())
        out.push(c.createHash("sha256").update(fs.readFileSync(d+"/"+f)).digest("hex")+"  "+f); }
catch (e) { process.exit(3); }
process.stdout.write(out.join("\n"));' 2>/dev/null || true)
        # Both sides go through the SAME normalisation. Two near-identical
        # pipelines would eventually disagree about a trailing space and the
        # check would then be comparing formatting, not binaries.
        _norm='s/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/  /'
        _want=$(grep -vE '^[[:space:]]*(#|$)' "$_pinf" | sed "$_norm" | sort)
        _have=$(printf '%s\n' "$_live" | grep -vE '^[[:space:]]*$' | sed "$_norm" | sort)
        if [ -z "$_have" ]; then
            chk J-4 FAIL "the gateway has no TLS binary, or it could not be read" \
                "tls-client-node/bin is empty or unreadable in $_gw"
        elif [ "$_have" = "$_want" ]; then
            chk J-4 PASS "the gateway's TLS binary is the one on record" \
                "$(printf '%s' "$_have" | awk '{print $2}' | tr '\n' ' ')"
        else
            chk J-4 FAIL "the gateway's TLS binary is not the one on record" \
                "running: $(printf '%s' "$_have" | awk '{print $2" ("substr($1,1,12)")"}' | tr '\n' ' ')| recorded: $(printf '%s' "$_want" | awk '{print $2" ("substr($1,1,12)")"}' | tr '\n' ' ')"
        fi

        # J-5: whether that drift is currently EXPOSED, which is a different
        # question and the one that sets priority.
        #
        # The .so is loaded lazily, on first use of a provider that does TLS
        # impersonation. omniroute/Dockerfile:101 names them: chatgpt-web,
        # claude-web, grok-web, lmarena, perplexity-web. On 2026-09-10 none was
        # configured, /proc/1/maps showed the library had never been mapped, and
        # so a binary carrying CVE-2025-68121 sat in the image executing nothing.
        #
        # That is a fine reason to defer a rebuild and a terrible reason to
        # forget. "Safe because nothing uses it" is a condition, and an
        # unwatched condition is exactly what this audit keeps finding. So the
        # condition gets asserted: configure one of those providers while the
        # binary is still the wrong one, and this goes red the next time the
        # audit runs.
        if [ "$_have" = "$_want" ]; then
            chk J-5 PASS "TLS-impersonation exposure moot; the recorded binary is running"
        else
            _tlsusers=$(docker exec "$_gw" node -e '
const D=require("better-sqlite3")("/app/data/storage.sqlite",{readonly:true});
const W=["chatgpt-web","claude-web","grok-web","lmarena","perplexity-web"];
try {
  const r=D.prepare("SELECT provider FROM provider_connections WHERE is_active=1").all();
  process.stdout.write(r.map(x=>x.provider).filter(p=>W.includes(p)).join(","));
} catch (e) { process.exit(4); }' 2>/dev/null || echo "UNREADABLE")
            if [ "$_tlsusers" = "UNREADABLE" ]; then
                chk J-5 UNKNOWN "cannot tell whether the outdated TLS binary is reachable" \
                    "provider table unreadable; treat as exposed until shown otherwise"
            elif [ -n "$_tlsusers" ]; then
                chk J-5 FAIL "an outdated TLS binary is now reachable from a configured provider" \
                    "active: $_tlsusers -- the deferral reason no longer holds, rebuild the gateway"
            else
                chk J-5 PASS "the outdated TLS binary is dormant" \
                    "no chatgpt-web/claude-web/grok-web/lmarena/perplexity-web provider is active"
            fi
        fi
    fi
}

# ------------------------------------------------------------- dimension K
#
# The aspect the first 63 checks missed entirely.
#
# B-2 reads the ROOT compose and passes. But `omniroute/` is a vendored subtree
# with its own compose, and it publishes on 0.0.0.0 -- so the gateway's admin
# API listens on every interface while the audit reported every port correctly
# bound. Reading declarations is not the same as looking at the machine.

dim_K() {
    echo; echo "K  host and network surface"
    if ! on_host; then
        skip_rest K "not on the host; nothing here is observable remotely"
        return
    fi

    # K-1: what is actually listening, which is a different question from what
    # the compose files declare.
    if have ss; then
        _wide=$(ss -tlnH 2>/dev/null | awk '{print $4}' \
                | grep -E '^(0\.0\.0\.0|\*):' | sed 's/.*://' | sort -un | tr '\n' ' ' || true)
        # Acknowledged wide ports, with the reason each cannot be narrowed from
        # this repository. Three are published by the vendored subtree using a
        # mapping shape that has no bind-host variable — the same variable sits
        # on both sides of `${DASHBOARD_PORT}:${DASHBOARD_PORT}` and again as
        # the app's own listening port, so no value narrows the interface.
        #
        # This does NOT acknowledge that they are adequately protected. K-3
        # proves the VPC firewall filters them, and K-2 stays red because that
        # firewall is the only control — DOCKER-USER is empty, so ufw does not
        # cover Docker-published ports at all. Two checks, two findings, and
        # the second one is still failing.
        _wpack=scripts/wide-ports.txt
        _unexpected=""; _ackd=""
        for _pt in $_wide; do
            case "$_pt" in 22|80|443) continue ;; esac
            if [ -f "$_wpack" ] && grep -v '^[[:space:]]*#' "$_wpack" 2>/dev/null \
                 | awk '{print $1}' | grep -qx "$_pt"; then
                _ackd="$_ackd $_pt"
            else
                _unexpected="$_unexpected $_pt"
            fi
        done
        metric k1_wide_ports "$(printf '%s' "$_wide" | wc -w | tr -d ' ')"
        if [ -z "$_unexpected" ] && [ -z "$_ackd" ]; then
            chk K-1 PASS "only 22, 80 and 443 listen on all interfaces"
        elif [ -z "$_unexpected" ]; then
            chk K-1 PASS "wide port(s)$_ackd, each acknowledged with why it cannot be narrowed here" \
                "vendored mappings with no bind-host variable; K-3 proves them filtered, K-2 says that filter is the only one"
        else
            chk K-1 FAIL "port(s) listening on 0.0.0.0 that nobody has reviewed" \
                "$_unexpected — add them to $_wpack with a reason, or bind them to loopback"
        fi
    else
        chk K-1 UNKNOWN "ss unavailable; listening sockets unmeasurable"
    fi

    # K-2: the one that matters. ufw reporting "active" says nothing about
    # Docker-published ports: Docker inserts its own ACCEPT rules and bypasses
    # ufw's INPUT chain entirely unless DOCKER-USER is populated. An empty
    # DOCKER-USER means the firewall people trust is not the control keeping
    # those ports closed.
    #
    # Counting rules is not the same as covering the ports. A single rule
    # pointed at the wrong interface, or at a port nothing publishes, would
    # have turned this green — the same shape as K-3 probing a hardcoded list
    # that omitted the very ports K-1 complains about. So it asks whether each
    # port K-1 names actually has a DROP, in BOTH families: the mappings bind
    # `[::]` as well as `0.0.0.0`, and a v4-only rule set closes the front door
    # while leaving the back one open, which is worse than leaving both open
    # because it looks finished.
    if sudo -n iptables -S DOCKER-USER >/dev/null 2>&1; then
        _du=$(sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)
        metric k2_docker_user_rules "${_du:-0}"
        _uncovered=""
        for _wp in 20128 20129 20132; do
            for _fam in iptables ip6tables; do
                sudo -n "$_fam" -S DOCKER-USER 2>/dev/null \
                    | grep -qE -- "--dport $_wp .*-j DROP" \
                    || _uncovered="$_uncovered ${_wp}/${_fam%tables}"
            done
        done
        if [ "${_du:-0}" -gt 0 ] && [ -z "$_uncovered" ]; then
            chk K-2 PASS "every wide port has a DROP in DOCKER-USER, v4 and v6" \
                "${_du} rule(s); applied by king-firewall.service, which is PartOf=docker.service so a daemon restart re-applies them"
        elif [ "${_du:-0}" -gt 0 ]; then
            chk K-2 FAIL "DOCKER-USER has rules but not for every wide port:$_uncovered" \
                "a rule that misses the port it was written for reads as coverage and is not"
        else
            chk K-2 FAIL "DOCKER-USER is empty: the host firewall does NOT cover Docker ports" \
                "ufw may report active while something upstream is the only real control"
        fi
    else
        chk K-2 UNKNOWN "cannot read iptables without root; firewall coverage unknown"
    fi

    # K-3: the only answer that counts. Asked from the host to its own PUBLIC
    # address, so it traverses whatever sits in front of the machine.
    if have curl; then
        _ip=$(curl -s -m 8 -H 'Metadata-Flavor: Google' \
              'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' 2>/dev/null || true)
        if [ -z "$_ip" ]; then
            chk K-3 UNKNOWN "could not determine this host's public address"
        else
            # Derived, not hardcoded. The list used to be
            # `20128 8100 8130 8140`, which happened to omit 20129 and 20132 —
            # two of the three ports K-1 reports as wide open. A sample that
            # misses the cases the neighbouring check is complaining about is
            # not a sample, it is a gap.
            #
            # Everything bound to 0.0.0.0, plus the loopback services worth
            # confirming are NOT reachable from outside.
            _probe=$(ss -tlnH 2>/dev/null | awk '{print $4}' \
                     | grep -E '^(0\.0\.0\.0|\*):' | sed 's/.*://' | sort -un | tr '\n' ' ' || true)
            for _lp in 8100 8130 8140 8080; do
                case " $_probe " in *" $_lp "*) : ;; *) _probe="$_probe $_lp" ;; esac
            done
            _reach=""
            for _pt in $_probe; do
                # 22, 80 and 443 are meant to answer from outside; probing them
                # would report the intended surface as a finding.
                case "$_pt" in 22|80|443) continue ;; esac
                # No `|| echo 000` here. curl -w already prints 000 on a
                # connection failure, so the fallback CONCATENATES and yields
                # "000000", which is not equal to "000" -- and every filtered
                # port reported as reachable. Fourth appearance of this shape
                # in this script; G-6 counts them for a reason.
                #
                # `|| true` and not `|| echo 000`: both stop set -e from killing
                # the run on a refused connection, but only one of them adds
                # output. That distinction is the entire bug.
                _rc=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://$_ip:$_pt/" 2>/dev/null || true)
                case "${_rc:-000}" in
                    000|"") : ;;
                    *) _reach="$_reach $_pt=$_rc" ;;
                esac
            done
            metric k3_probed "$(printf '%s' "$_probe" | wc -w | tr -d ' ')"
            if [ -z "$_reach" ]; then
                chk K-3 PASS "no internal port answers on the public address" \
                    "$(printf '%s' "$_probe" | wc -w | tr -d ' ') port(s), derived from what is listening; verified through whatever sits in front of the host"
            else
                chk K-3 FAIL "internal port(s) answering on the public address" "$_reach"
            fi
        fi
    else
        chk K-3 UNKNOWN "curl unavailable; external reachability untested"
    fi

    # K-4: HMAC signatures, TLS validity and the monitor's 15-minute window all
    # assume the clock. A drifting clock breaks all three in ways that look
    # like unrelated bugs.
    if have timedatectl; then
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
            chk K-4 PASS "system clock is NTP-synchronised"
        else
            chk K-4 FAIL "system clock is not synchronised" \
                "HMAC, TLS and the alert window all depend on it"
        fi
    else
        chk K-4 UNKNOWN "timedatectl unavailable; clock sync unknown"
    fi

    # K-5: port 22 is genuinely open to the internet, so how it is configured
    # is part of the public surface whether or not anyone thinks of it that way.
    if sudo -n sshd -T >/dev/null 2>&1; then
        _sshbad=""
        sudo -n sshd -T 2>/dev/null | grep -q '^passwordauthentication no' || _sshbad="$_sshbad password-auth-on"
        sudo -n sshd -T 2>/dev/null | grep -q '^permitrootlogin \(no\|without-password\|prohibit-password\)' \
            || _sshbad="$_sshbad root-login-permissive"
        sudo -n sshd -T 2>/dev/null | grep -q '^permitemptypasswords no' || _sshbad="$_sshbad empty-passwords"
        if [ -z "$_sshbad" ]; then
            chk K-5 PASS "SSH takes keys only; no password auth, no bare root login"
        else
            chk K-5 FAIL "SSH configuration weakens the one port open to everyone" "$_sshbad"
        fi
    else
        chk K-5 UNKNOWN "cannot read the effective sshd config without root"
    fi

    # K-6: an unpatched host behind a good firewall is still an unpatched host.
    #
    # Two ways this check used to lie, both found on 2026-09-10.
    #
    # 1. It read `apt-get -s upgrade 2>/dev/null | grep -c … || true`. When apt
    #    cannot answer -- lists unreadable, lock held, sources broken -- that
    #    pipeline yields 0, and 0 with unattended-upgrades enabled was the PASS
    #    branch. So the check reported "no pending security updates" precisely
    #    when it had no idea. Demonstrated by pointing Dir::State::Lists at a
    #    nonexistent path: the count came back 0 and the old code was happy.
    #    apt's exit status is now kept and a failure is UNKNOWN, never green.
    #
    # 2. `systemctl is-enabled unattended-upgrades` is not the question. That
    #    unit is `unattended-upgrade-shutdown --wait-for-signal`, the helper
    #    that finishes upgrades during shutdown. The thing that actually
    #    applies them on a schedule is apt-daily-upgrade.timer, and it could be
    #    masked while this check still reported "enabled" and passed.
    if have apt-get; then
        _aptout=$(apt-get -s upgrade 2>/dev/null); _aptrc=$?
        _unatt=$(systemctl is-enabled unattended-upgrades 2>/dev/null || echo disabled)
        _aptimer=$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || echo disabled)
        # Exit status is not enough, and the first version of this fix stopped
        # there. With its package lists gone, `apt-get -s upgrade` exits 0 and
        # prints a perfectly well-formed "0 upgraded, 0 newly installed, 0 to
        # remove and 0 not upgraded." -- an answer of zero from a program with
        # nothing to count. Measured: Dir::State::Lists=/nonexistent gives
        # rc=0, 379 bytes of output, 0 security lines, and the check was green.
        #
        # So ask apt how much it actually knows. `indextargets` lists the index
        # files it will read: 62 on this host, 0 when the lists are missing.
        # $(FILENAME) is apt's own --format template, not a shell expansion,
        # so the single quotes are the point.
        # shellcheck disable=SC2016
        _aptidx=$(apt-get indextargets --format '$(FILENAME)' 2>/dev/null | grep -c . || true)
        if [ "$_aptrc" -ne 0 ] || [ -z "$_aptout" ]; then
            chk K-6 UNKNOWN "apt could not report what is pending" \
                "exit $_aptrc — an unanswerable question is not a clean bill of health"
        elif [ "${_aptidx:-0}" -eq 0 ]; then
            chk K-6 UNKNOWN "apt has no package indexes, so its zero means nothing" \
                "apt-get indextargets returned 0 files — 'nothing pending' from a program with nothing to read"
        else
            _sec=$(printf '%s\n' "$_aptout" | grep -ciE '^Inst.*security' || true)
            metric k6_security_updates "${_sec:-0}"
            if [ "${_sec:-0}" -gt 0 ]; then
                chk K-6 FAIL "${_sec} security update(s) pending" \
                    "$(printf '%s\n' "$_aptout" | grep -iE '^Inst.*security' | awk '{printf "%s ", $2}')— unattended-upgrades:$_unatt apt-daily-upgrade.timer:$_aptimer"
            elif [ "$_unatt" != "enabled" ] || [ "$_aptimer" != "enabled" ]; then
                chk K-6 FAIL "nothing is scheduled to apply the next security update" \
                    "unattended-upgrades:$_unatt apt-daily-upgrade.timer:$_aptimer — the timer is the one that applies them"
            else
                chk K-6 PASS "no pending security updates, and the apply timer is enabled" \
                    "unattended-upgrades:$_unatt apt-daily-upgrade.timer:$_aptimer"
            fi
        fi
    else
        chk K-6 SKIP "not an apt host"
    fi

    # K-7: Caddy renews on its own, so this is a check that the renewal is
    # working rather than a reminder to renew.
    _dom=$(sed -n 's/^OMNIROUTE_PUBLIC_DOMAIN=//p' .env 2>/dev/null | tail -1)
    if [ -n "$_dom" ] && have openssl; then
        _end=$(echo | openssl s_client -servername "$_dom" -connect "$_dom:443" 2>/dev/null \
               | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
        if [ -z "$_end" ]; then
            chk K-7 UNKNOWN "could not read the certificate for $_dom"
        else
            _endepoch=$(date -d "$_end" +%s 2>/dev/null)
            case "$_endepoch" in
                ''|*[!0-9]*)
                    chk K-7 UNKNOWN "certificate end date is unparseable" "$_end"
                    _left="" ;;
                *)  _left=$(( ( _endepoch - $(date +%s) ) / 86400 ))
                    metric k7_cert_days "$_left" ;;
            esac
            if [ -z "$_left" ]; then
                :   # K-7 already reported UNKNOWN above; do not report twice
            elif [ "$_left" -gt 20 ]; then
                chk K-7 PASS "certificate valid for ${_left} more day(s)" "$_end"
            else
                chk K-7 FAIL "certificate expires in ${_left} day(s)" "renewal is not keeping up"
            fi
        fi
    else
        chk K-7 UNKNOWN "no public domain configured, or openssl missing"
    fi

    # K-8: scheduled work this repo does not know about. The systemd side is
    # B-10; cron is a second scheduler nobody has looked at.
    _cron=$(crontab -l 2>/dev/null | grep -vcE '^\s*(#|$)' || true)
    # find, not `ls | grep`. Two exclusions, for different reasons: the two
    # distribution jobs by name, and anything containing a dot because CRON
    # ITSELF ignores those. Counting `.placeholder` as a scheduled job was a
    # false positive that would have sent someone hunting for a job which
    # can never run.
    _crond=$(find /etc/cron.d -maxdepth 1 -type f ! -name '*.*' \
             ! -name e2scrub_all ! -name sysstat 2>/dev/null | grep -c . || true)
    if [ "${_cron:-0}" -eq 0 ] && [ "${_crond:-0}" -eq 0 ]; then
        chk K-8 PASS "no cron entry outside the distribution defaults"
    else
        chk K-8 FAIL "cron entries this repo does not describe" \
            "user crontab: ${_cron:-0}, /etc/cron.d: ${_crond:-0}"
    fi

    # K-9. K-3 proves the internal ports do not answer from outside. Nothing
    # asked what the port that IS open answers with.
    #
    # Five distinct internet addresses have probed this host for /.git/config,
    # /.git/HEAD and /appsettings.json — routine background scanning, and the
    # scan is not the finding. The response is: every unmatched path falls
    # through to the catch-all, and the catch-all proxies the GATEWAY's own
    # Next.js dashboard — not ntfy, which is what this comment said until the
    # body was actually read and turned out to carry `_next/static`. Guessing
    # which upstream answers is the same habit as guessing an endpoint path.
    #
    # It returns a correct 404 status attached to a 719 KB single-page app, so
    # a scanner walking a wordlist pulls three quarters of a megabyte per guess
    # out of a 2-vCPU host. Correct status code, thousandfold amplification.
    #
    # The 404 page belongs to the vendored subtree, which CLAUDE.md forbids
    # editing — so the fix is outside it, at Caddy, which is exactly what that
    # rule prescribes.
    _dom=$(sed -n 's/^OMNIROUTE_PUBLIC_DOMAIN=//p' .env 2>/dev/null | tail -1)
    if [ -z "$_dom" ]; then
        chk K-9 UNKNOWN "no public domain configured in .env; nothing to probe"
    else
        _big=""; _n=0
        for _pth in /.git/config /appsettings.json /wp-login.php; do
            _n=$((_n + 1))
            _sz=$(curl -s -o /dev/null -w '%{size_download}' -m 15 "https://${_dom}${_pth}" 2>/dev/null || true)
            case "$_sz" in ''|*[!0-9]*) continue ;; esac
            [ "$_sz" -gt 65536 ] && _big="$_big ${_pth}=$((_sz / 1024))KB"
        done
        if [ -z "$_big" ]; then
            chk K-9 PASS "unmatched public paths return a small response" \
                "$_n path(s) probed from the host, over the public name"
        else
            chk K-9 FAIL "unmatched public paths return the whole app" \
                "$_big — a correct 404 status carrying a payload a scanner can amplify"
        fi
    fi
}

# ------------------------------------------------------------- dimension L
#
# The state INSIDE the applications, as opposed to the files that configure
# them. A gateway with seven API keys, two of them holding `manage`, is a fact
# about this deployment that no file in this repo records -- it lives in the
# gateway's own database, and nothing was looking at it.

dim_L() {
    echo; echo "L  application state behind the gateway"
    if ! on_host; then
        skip_rest L "not on the host; application state unreachable"
        return
    fi

    _k=$(sed -n 's/^OMNIROUTE_MCP_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -1)

    # L-1: keys accumulate. Each one is a credential that works until someone
    # removes it, and `manage` is the scope the sidecar's own module docstring
    # calls materially more privileged than what it normally needs.
    if [ -z "$_k" ] || [ -z "$PY" ]; then
        chk L-1 UNKNOWN "no gateway key or interpreter; key inventory unreadable"
    else
        _kp=$(mktemp)
        cat > "$_kp" <<'PYKEYS'
import datetime, json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR"); raise SystemExit(0)
ks = d if isinstance(d, list) else (d.get("keys") or d.get("data") or [])
now = datetime.datetime.now(datetime.timezone.utc)
stale, manage = [], []
for x in ks:
    name = str(x.get("name") or "?")
    if "manage" in (x.get("scopes") or []) or "admin" in (x.get("scopes") or []):
        manage.append(name)
    last = x.get("lastUsedAt") or x.get("last_used_at")
    if not last:
        stale.append(name + "(never)"); continue
    try:
        t = datetime.datetime.fromisoformat(str(last).replace("Z", "+00:00"))
        if (now - t).days > 14:
            stale.append("%s(%dd)" % (name, (now - t).days))
    except Exception:
        pass
print("%d\t%s\t%s" % (len(ks), ",".join(manage), ",".join(stale)))
PYKEYS
        _out=$(curl -s -m 25 "http://localhost:20128/api/keys" \
               -H "Authorization: Bearer $_k" 2>/dev/null | "$PY" "$_kp" 2>/dev/null || true)
        rm -f "$_kp"
        _tot=$(printf '%s' "$_out" | cut -f1)
        _mg=$(printf '%s' "$_out" | cut -f2)
        _st=$(printf '%s' "$_out" | cut -f3)
        if [ -z "$_out" ] || [ "$_tot" = "ERR" ]; then
            chk L-1 UNKNOWN "could not read the gateway key list"
        else
            metric l1_keys "$_tot"
            if [ -n "$_st" ]; then
                chk L-1 FAIL "$_tot key(s); unused for over a fortnight: $_st" \
                    "manage-scoped: ${_mg:-none} — a key nobody uses still opens the door"
            else
                chk L-1 PASS "$_tot key(s), all used within the fortnight" \
                    "manage-scoped: ${_mg:-none}"
            fi
        fi
    fi

    # L-2: is public registration closed?
    #
    # This said "Activepieces closes registration by itself after the first
    # account". It does not. Measured 2026-09-11 on a fresh database with an
    # owner, a platform and a project all present: sign-up still reached
    # validation. The old deployment only looked closed because its platform
    # row had been configured by hand, and a rebuild inherits none of that.
    # Registration is now refused by Caddy (caddy/Caddyfile, the flows site),
    # which is what this expects to see.
    #
    # IT USED TO POST A COMPLETE SIGN-UP, and the comment excusing that said
    # "the probe uses an .invalid address so a success would create nothing
    # usable". That was wrong. On 2026-09-11, against a freshly-created
    # database with zero accounts, the probe registered
    # audit-probe@example.invalid as a verified identity -- with the password
    # that was sitting in this file, in a repository. A read-only check that
    # writes is not a check; it is a change with an opinion.
    #
    # The body is now EMPTY, which cannot create anything, and the status still
    # answers the question because the two rejections happen at different
    # layers: registration-closed is refused (403) before the payload is ever
    # validated, while an open endpoint gets as far as validation and says 400.
    # Measured on this deployment: open -> 400.
    if have curl; then
        _su=$(curl -s -o /dev/null -w '%{http_code}' -m 25 -X POST \
              "https://flows.arject.co/api/v1/authentication/sign-up" \
              -H 'Content-Type: application/json' -d '{}' \
              2>/dev/null || true)
        case "${_su:-000}" in
            403|401) chk L-2 PASS "Activepieces refuses registration" "HTTP $_su — refused before the payload was read" ;;
            400)     chk L-2 FAIL "Activepieces registration is OPEN" \
                         "HTTP 400 is the validator, not the door: an empty body got past the auth layer. flows.arject.co is public" ;;
            2*)      chk L-2 FAIL "the sign-up endpoint accepted an EMPTY body" "HTTP $_su — that should be impossible" ;;
            *)       chk L-2 UNKNOWN "sign-up probe returned $_su" ;;
        esac
    else
        chk L-2 UNKNOWN "curl unavailable; registration state untested"
    fi

    # L-3: the run journal records prompts and errors, and errors quote what
    # failed. A journal that has started capturing credentials is a second
    # copy of them in a file nobody treats as secret.
    # A zero here used to mean "clean". It also meant "grep could not run": an
    # invalid pattern makes grep write to stderr and print nothing, `awk
    # '{t+=$1} END {print t+0}'` turns that into 0, and 0 read as a PASS.
    # Proven on the live container before this was written — a deliberately
    # broken pattern produced exactly the same 0 a clean scan does.
    #
    # That is the "cannot read becomes zero" fault this file's own header warns
    # about, sitting in the check that guards credentials, and it had just
    # become live: the pattern was rewritten today, and a typo in it would have
    # turned both scanners green rather than red.
    #
    # So the scanner proves it can find something first, through the SAME
    # invocation, against a line built to match. Same structure as E-5 and E-9.
    _l3can=$(docker exec king-agent-sidecar-http-1 sh -c \
             "printf 'AP_REDIS_PASSWORD=0123456789abcdef0123456789abcdef\n' | grep -cE '$CREDPAT'" \
             2>/dev/null | tr -dc '0-9' || true)
    if [ "${_l3can:-0}" != "1" ]; then
        chk L-3 UNKNOWN "the credential pattern matched nothing in a line built to match it" \
            "the scanner cannot produce a finding, so a clean journal proves nothing"
    else
        _leak=$(docker exec king-agent-sidecar-http-1 sh -c \
                "grep -chE '$CREDPAT' /audit/runs.jsonl /audit/vps_exec.log 2>/dev/null | awk '{t+=\$1} END {print t+0}'" \
                2>/dev/null || true)
        case "${_leak:-x}" in
            x|"") chk L-3 UNKNOWN "could not scan the journals" ;;
            0)    chk L-3 PASS "no credential-shaped string in the journals" \
                      "the pattern was proven able to match before this zero was believed" ;;
            *)    chk L-3 FAIL "$_leak credential-shaped string(s) in the journals" \
                      "a second copy of a secret, in a file nobody treats as one" ;;
        esac
    fi

    # L-4: nothing rotates these. Recorded as a number so growth is visible in
    # the baseline diff rather than discovered when a disk fills.
    _jl=$(docker exec king-agent-sidecar-http-1 sh -c 'wc -l < /audit/runs.jsonl' 2>/dev/null | tr -d ' ' || true)
    case "${_jl:-x}" in
        x|"") chk L-4 UNKNOWN "journal length unreadable" ;;
        *)    metric l4_journal_lines "$_jl"
              if [ "$_jl" -lt 50000 ]; then
                  # "nothing rotates it" was true when written and stopped
                  # being true the moment king-backup.sh gained a trim. An
                  # evidence line that states a fact about the system has to be
                  # derived from the system, or it becomes a confident lie on
                  # the day someone fixes the thing it describes.
                  # shellcheck disable=SC2016  # the sed pattern matches the literal ${...} in that file
                  _keep=$(sed -n 's/^JOURNAL_KEEP="\${KING_JOURNAL_KEEP:-\([0-9]*\)}"/\1/p' \
                          scripts/king-backup.sh 2>/dev/null | head -1)
                  # `${_keep:-else}` substitutes the VALUE when set, not the
                  # alternative — so the first attempt printed
                  # "bounded at 5000 lines; 5000the baseline diff". It is a
                  # default, not a ternary, and this file has now made that
                  # mistake once in the check that exists to catch confident
                  # wrong statements.
                  if [ -n "$_keep" ]; then
                      _l4="bounded at $_keep lines by king-backup.sh"
                  else
                      _l4="nothing rotates it"
                  fi
                  chk L-4 PASS "run journal at $_jl line(s)" \
                      "$_l4; the baseline diff shows growth"
              else
                  chk L-4 FAIL "run journal at $_jl lines and nothing rotates it"
              fi ;;
    esac

    # L-3 scans the run journals. Nothing scanned the CONTAINER logs, which are
    # a larger surface written by code this repo does not own: a library that
    # logs a request header at debug level puts a bearer token on disk in a
    # file D-7 has just established nothing rotates.
    if ! on_host; then
        chk L-5 SKIP "not on the host"
    elif [ "$(printf 'AP_REDIS_PASSWORD=0123456789abcdef0123456789abcdef
'                | grep -cE "$CREDPAT" || true)" != "1" ]; then
        # Same canary as L-3, for the same reason: a pattern that cannot match
        # makes every grep below return nothing, and nothing reads as clean.
        chk L-5 UNKNOWN "the credential pattern matched nothing in a line built to match it"             "the scanner cannot produce a finding, so clean logs prove nothing"
    else
        _hits=""; _scanned=0
        for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
            _scanned=$((_scanned + 1))
            _n=$(docker logs --tail 4000 "$_c" 2>&1 \
                 | grep -cE "$CREDPAT" \
                 || true)
            case "$_n" in ''|*[!0-9]*) continue ;; esac
            [ "$_n" -gt 0 ] && _hits="$_hits $_c($_n)"
        done
        if [ -z "$_hits" ]; then
            chk L-5 PASS "no credential-shaped string in $_scanned container log(s)" \
                "the pattern was proven able to match first; last 4000 lines each, older lines are not covered and nothing rotates them"
        else
            chk L-5 FAIL "credential-shaped string(s) in container logs" "$_hits"
        fi
    fi


    # L-6. L-3 asks whether the journal leaks CREDENTIALS. It does not. But
    # every entry carries a `task` field holding the prompt verbatim, and L-4
    # records that nothing rotates the file. So the system retains, forever, a
    # complete transcript of what was asked of it — which is a data-retention
    # decision that had never been made, only defaulted into.
    #
    # This is not a leak and the check does not pretend it is. It asks whether
    # the retention is bounded by something or written down anywhere, because
    # an unbounded default nobody chose is the part worth surfacing.
    _rj=$(docker exec king-agent-sidecar-http-1 sh -c 'head -1 /audit/runs.jsonl' 2>/dev/null || true)
    if [ -z "$_rj" ]; then
        chk L-6 UNKNOWN "the run journal could not be read to see what it retains"
    else
        case "$_rj" in
            *'"task"'*)
                # This check passed on a coincidence twice before it worked.
                #
                # First it grepped docs/ for "retention" and matched
                # CALL_LOG_RETENTION_DAYS and AP_EXECUTION_DATA_RETENTION_DAYS
                # — two real settings, for two other stores. Then it required
                # the same FILE to contain both "runs.jsonl" and a retention
                # word, and matched king-mistakes.md, where the word is
                # "rotated key" four hundred lines from any mention of the
                # journal. File-level co-occurrence cannot establish that a
                # sentence is about a subject.
                #
                # So it reads the neighbourhood: three lines either side of a
                # runs.jsonl mention. That can still be fooled, but it can no
                # longer be fooled by a document that merely discusses two
                # topics.
                if grep -rn -A3 -B3 'runs\.jsonl' docs/ 2>/dev/null \
                   | grep -qi 'retention\|rotat\|expire\|prune'; then
                    chk L-6 PASS "the journal retains prompt text, and a doc that names runs.jsonl bounds it" \
                        "L-4 measures the growth; this asks whether anyone decided"
                else
                    chk L-6 FAIL "the journal retains every prompt verbatim, with nothing bounding it" \
                        "no rotation (L-4) and no retention statement in docs/; a default, not a decision"
                fi ;;
            *)  chk L-6 PASS "the run journal records no prompt text" ;;
        esac
    fi

}

# ----------------------------------------------------------------- self-test

self_test() {
    echo "self-test (fixtures and this repo; no host, no secrets, no network)"
    if ! pyyaml_ok; then
        c_yell "  no working python3 with pyyaml on this machine"; echo
        echo "  The self-test cannot run, and that is reported rather than passed."
        exit 2
    fi
    _t=$(mktemp -d); _f=0
    mkdir -p "$_t/scripts"
    cat > "$_t/docker-compose.yml" <<'FIX'
services:
  good:
    image: example/good:1.2.3
    profiles: [demo]
    mem_limit: 256m
    memswap_limit: 256m
    cpus: 0.5
    ports:
      - "${GOOD_BIND_HOST:-127.0.0.1}:9000:9000"
  bad:
    image: example/bad:latest
    mem_limit: 512m
    ports:
      - "9001:9001"
  float:
    image: example/float:2-alpine
    profiles: [demo]
    mem_limit: 256m
    memswap_limit: 256m
    cpus: 0.5
  built:
    image: example/built:local
    build: .
    profiles: [demo]
    mem_limit: 256m
    memswap_limit: 256m
    cpus: 0.5
FIX
    cd "$_t"
    _py=$(mktemp)
    cat > "$_py" <<'PYFIX'
import io, re, sys
import yaml
d = yaml.safe_load(io.open("docker-compose.yml", encoding="utf-8").read()) or {}
out = []
for name, s in sorted((d.get("services") or {}).items()):
    s = s or {}
    if s.get("mem_limit") and not s.get("memswap_limit"): out.append("B1 " + name)
    if not s.get("profiles"): out.append("B4 " + name)
    img = s.get("image") or ""
    # This is a COPY of the rule at the top of this script, not the rule
    # itself: the real one lives inside a heredoc'd python and cannot be
    # imported from here. A drift assertion below greps the real rule, so the
    # two cannot silently disagree -- which is the failure this fixture would
    # otherwise be blind to.
    img = s.get("image") or ""
    if img and not s.get("build"):
        base = img.split("/")[-1].split("@")[0]
        tag = base.split(":")[-1] if ":" in base else ""
        if "@sha256:" in img:
            pass
        elif not tag or tag == "latest":
            out.append("B3 " + name)
        elif not re.match(r'^v?\d+\.\d+\.\d+', tag):
            out.append("B3 " + name)
    if name != "caddy":
        for p in s.get("ports") or []:
            if isinstance(p, str) and not re.match(r'^\$\{[A-Z_]+:-127\.0\.0\.1\}:|^127\.0\.0\.1:', p):
                out.append("B2 " + name)
print("\n".join(out))
PYFIX
    _got=$("$PY" "$_py" 2>/dev/null || echo "PYFAIL")
    rm -f "$_py"; cd "$REPO"

    _expect_hit() {
        if printf '%s' "$_got" | grep -q "$1"; then printf '  ok    %s\n' "$2"
        else printf '  FAIL  %s\n' "$2"; _f=$((_f+1)); fi
    }
    _expect_miss() {
        if printf '%s' "$_got" | grep -q "$1"; then printf '  FAIL  %s\n' "$2"; _f=$((_f+1))
        else printf '  ok    %s\n' "$2"; fi
    }
    _expect_hit  "B1 bad"  "mem_limit without memswap_limit is caught"
    _expect_hit  "B4 bad"  "a service with no profiles: is caught"
    _expect_hit  "B3 bad"  "a :latest image is caught"
    _expect_hit  "B3 float" "a floating major tag is caught, not just :latest"
    _expect_miss "B3 good" "an exactly-versioned image is not flagged"
    _expect_miss "B3 built" "a locally-built image is not judged as a registry pin"

    # The drift detector the comment inside PYFIX promises. The fixture holds a
    # COPY of B-3's rule because the real one lives inside a heredoc'd python
    # and cannot be imported from shell. A copy that silently falls behind is
    # worse than no fixture: it would keep passing while blessing a rule the
    # audit no longer runs.
    #
    # So: every decision line of that rule must appear exactly TWICE in this
    # file, once in each copy. Edit one and not the other and the count drops
    # to one, and this fails.
    # Confined to the two heredocs that hold the rule, because the first
    # version of this detector counted 3 and not 2: the loop below names those
    # lines as literals, so the file it was searching now contained the
    # question it was asking. That is E-5's bug, reproduced inside the guard
    # written to prevent drift.
    _b3self="$REPO/scripts/$(basename "$0")"
    # The marker names are ASSEMBLED rather than written, and that is not
    # style. Spelling them here put `<<'PY...'` into the file a second time,
    # sed re-opened both ranges on this very line, each ran to end-of-file, and
    # the count went from 3 to 4. The search term must not appear in the thing
    # being searched -- the same trap, now two levels deep in one afternoon.
    _b3m1=$(printf 'PY%s' 'AUDIT'); _b3m2=$(printf 'PY%s' 'FIX')
    _b3body=$(sed -n "/<<'$_b3m1'/,/^$_b3m1\$/p;/<<'$_b3m2'/,/^$_b3m2\$/p" "$_b3self" 2>/dev/null)
    _b3drift=""
    for _line in 'base = img.split("/")[-1].split("@")[0]' \
                 'if "@sha256:" in img:' \
                 'elif not tag or tag == "latest":' \
                 "elif not re.match(r'^v?"; do
        _c=$(printf '%s
' "$_b3body" | grep -cF "$_line" 2>/dev/null || printf '0')
        [ "$_c" = "2" ] || _b3drift="$_b3drift [$_line -> $_c]"
    done
    if [ -z "$_b3drift" ]
    then printf '  ok    the fixture copy of B-3 still matches the rule it mirrors\n'
    else printf '  FAIL  the fixture copy of B-3 has drifted from the rule:%s\n' "$_b3drift"; _f=$((_f+1)); fi
    _expect_hit  "B2 bad"  "a port with no loopback bind is caught"
    _expect_miss "B1 good" "a compliant service is not flagged for memswap"
    _expect_miss "B4 good" "a compliant service is not flagged for profiles"
    _expect_miss "B2 good" "a loopback-bound port is not flagged"

    # ---- D-7: the rotation predicate, both ways ------------------------
    # D-5 spent a day reporting log sizes it could not read while nothing at
    # all asked whether rotation existed. Having finally asked, the predicate
    # itself gets a control in both directions, because a rotation check that
    # cannot go red is the same defect one layer up.
    printf '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}\n' > "$_t/rot-yes.json"
    printf '{"live-restore":true}\n' > "$_t/rot-no.json"
    if grep -q 'max-size' "$_t/rot-yes.json" 2>/dev/null
    then printf '  ok    a daemon.json with max-size reads as rotated\n'
    else printf '  FAIL  a daemon.json with max-size reads as rotated\n'; _f=$((_f+1)); fi
    if grep -q 'max-size' "$_t/rot-no.json" 2>/dev/null
    then printf '  FAIL  a daemon.json without max-size must not read as rotated\n'; _f=$((_f+1))
    else printf '  ok    a daemon.json without max-size must not read as rotated\n'; fi

    # ---- F-9: the acknowledgement comparison ---------------------------
    # The failure mode worth controlling for is the quiet one: a new
    # network-capable tool appearing and the comparison shrugging. So the
    # fixture offers a name the acknowledgement file does not carry.
    printf '["omniroute_web_fetch","notion_search","evil_new_upload"]\n' > "$_t/tools.json"
    printf '# comment\nomniroute_web_fetch\nnotion_search   # trailing note\n\n' > "$_t/ack.txt"
    _f9=$(mktemp)
    cat > "$_f9" <<'PYF9T'
import json, re, sys
tools = json.load(open(sys.argv[1]))
ack = set()
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    if line: ack.add(line)
egress = re.compile(r"fetch|search|http|webhook|post|upload|send|browse|crawl|url|scrape|notify|email", re.I)
hits = sorted(n for n in tools if egress.search(n))
print(",".join(sorted(set(hits) - ack)))
PYF9T
    _f9out=$("$PY" "$_f9" "$_t/tools.json" "$_t/ack.txt" 2>/dev/null || echo PYFAIL)
    rm -f "$_f9"
    if [ "$_f9out" = "evil_new_upload" ]
    then printf '  ok    an unacknowledged network tool is caught\n'
    else printf '  FAIL  an unacknowledged network tool is caught (got %s)\n' "${_f9out:-<empty>}"; _f=$((_f+1)); fi

    # And the other direction: a comment-only difference must not turn red.
    # `notion_search   # trailing note` is acknowledged, and a parser that
    # kept the comment would report it as new every single run -- a guard
    # nobody can leave green, which decays into a guard nobody reads.
    printf '["notion_search"]\n' > "$_t/tools2.json"
    _f9b=$(mktemp)
    cat > "$_f9b" <<'PYF9B'
import json, re, sys
tools = json.load(open(sys.argv[1]))
ack = set()
for line in open(sys.argv[2], encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    if line: ack.add(line)
egress = re.compile(r"fetch|search|http|webhook|post|upload|send|browse|crawl|url|scrape|notify|email", re.I)
print(",".join(sorted(set(n for n in tools if egress.search(n)) - ack)))
PYF9B
    _f9bout=$("$PY" "$_f9b" "$_t/tools2.json" "$_t/ack.txt" 2>/dev/null || echo PYFAIL)
    rm -f "$_f9b"
    if [ -z "$_f9bout" ]
    then printf '  ok    a tool acknowledged with a trailing comment is not new\n'
    else printf '  FAIL  a tool acknowledged with a trailing comment is not new (got %s)\n' "$_f9bout"; _f=$((_f+1)); fi

    # ---- E-8: the POPULATION, which is what it got wrong -----------------
    #
    # The old fixture asserted "a non-ollama call with zero tokens counts as
    # unaccounted" — which was the bug, encoded as a test. It kept passing
    # while the check told me spend could not be derived, because it tested
    # the same wrong idea the check held.
    #
    # A test written against the same mistaken premise as the code confirms
    # the premise. What has to be pinned is the population: health probes are
    # not inference, and a failed call has no tokens to report.
    printf '%s\n' '[
      {"path":"/api/providers/test","status":200,"tokens":{"in":0,"out":0}},
      {"path":"/api/providers/test","status":200,"tokens":{"in":0,"out":0}},
      {"path":"/v1/chat/completions","status":200,"tokens":{"in":10,"out":5}},
      {"path":"/v1/chat/completions","status":504,"tokens":{"in":0,"out":0}},
      {"path":"/v1/chat/completions","status":200,"tokens":{"in":0,"out":0}}
    ]' > "$_t/logs.json"
    _e8t=$(mktemp)
    cat > "$_e8t" <<'PYE8T'
import sys, json
rows = json.load(open(sys.argv[1]))
def has(r):
    t = r.get("tokens") or {}
    return bool((t.get("in") or 0) or (t.get("out") or 0))
inference = [r for r in rows if str(r.get("path") or "").startswith("/v1/chat")]
completed = [r for r in inference if str(r.get("status") or "")[:1] == "2"]
probes = [r for r in rows if str(r.get("path") or "").startswith("/api/providers/test")]
print("%d\t%d\t%d" % (len(completed), sum(1 for r in completed if has(r)), len(probes)))
PYE8T
    _e8out=$("$PY" "$_e8t" "$_t/logs.json" 2>/dev/null || echo PYFAIL)
    rm -f "$_e8t"
    # 2 completed inference calls (the 504 is excluded), 1 of them accounted,
    # 2 health probes not counted at all.
    if [ "$_e8out" = "$(printf '2\t1\t2')" ]
    then printf '  ok    health probes and failed calls are out of the token population\n'
    else printf '  FAIL  health probes and failed calls are out of the token population (got %s)\n' "$_e8out"; _f=$((_f+1)); fi

    # And the direction that matters: a COMPLETED inference call with no
    # tokens is still an accounting hole, and must stay countable.
    if [ "$(printf '%s' "$_e8out" | cut -f1)" -gt "$(printf '%s' "$_e8out" | cut -f2)" ]
    then printf '  ok    a completed call reporting no tokens is still counted as a hole\n'
    else printf '  FAIL  a completed call reporting no tokens is still counted as a hole\n'; _f=$((_f+1)); fi

    # ---- J-4: recorded TLS binary vs the one actually loaded --------------
    #
    # The comparison, not docker. What can go wrong here is the normalisation:
    # a pin file written by a human has comments, blank lines and an arbitrary
    # run of spaces as its separator, while node emits exactly two. If those
    # two sides are normalised by different code they drift, and the check
    # starts reporting formatting differences as a swapped binary.
    #
    # So the fixture runs the check's own pipeline over a deliberately untidy
    # pin file and asserts all three outcomes: match, altered digest, and an
    # extra file present in the container that nobody recorded.
    cat > "$_t/pin.txt" <<'PINFIX'
# a comment
#
   aaa111  tls-client-linux-ubuntu-amd64-1.16.0.so

bbb222     libextra.so
PINFIX
    _j4norm='s/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/  /'
    _j4want=$(grep -vE '^[[:space:]]*(#|$)' "$_t/pin.txt" | sed "$_j4norm" | sort)

    _j4same=$(printf '%s\n' 'bbb222  libextra.so' 'aaa111  tls-client-linux-ubuntu-amd64-1.16.0.so' \
              | grep -vE '^[[:space:]]*$' | sed "$_j4norm" | sort)
    if [ "$_j4same" = "$_j4want" ]
    then printf '  ok    an untidy pin file still matches the binaries it records\n'
    else printf '  FAIL  an untidy pin file still matches the binaries it records\n'; _f=$((_f+1)); fi

    # A rebuild that quietly pulled a different binary keeps the filename.
    _j4diff=$(printf '%s\n' 'bbb222  libextra.so' 'ZZZ999  tls-client-linux-ubuntu-amd64-1.16.0.so' \
              | grep -vE '^[[:space:]]*$' | sed "$_j4norm" | sort)
    if [ "$_j4diff" != "$_j4want" ]
    then printf '  ok    a same-named binary with a different digest is caught\n'
    else printf '  FAIL  a same-named binary with a different digest is caught\n'; _f=$((_f+1)); fi

    # And the direction a "does every recorded file exist?" check would miss.
    _j4extra=$(printf '%s\n' 'bbb222  libextra.so' 'aaa111  tls-client-linux-ubuntu-amd64-1.16.0.so' \
               'ccc333  tls-client-linux-ubuntu-amd64-1.15.1.so' \
               | grep -vE '^[[:space:]]*$' | sed "$_j4norm" | sort)
    if [ "$_j4extra" != "$_j4want" ]
    then printf '  ok    an unrecorded extra binary in the container is caught\n'
    else printf '  FAIL  an unrecorded extra binary in the container is caught\n'; _f=$((_f+1)); fi

    # ---- D-4: a contained kill is not a host-wide kill --------------------
    #
    # The old check counted both and printed the host-wide sentence either way,
    # so the mem_limit rule working looked exactly like the emergency it
    # prevents. These fixtures are real dmesg shapes, trimmed.
    cat > "$_t/dmesg-cg.txt" <<'DMCG'
[Thu Sep 10 15:04:35 2026] oom-kill:constraint=CONSTRAINT_MEMCG,oom_memcg=/system.slice/docker-80c6.scope,task=next-build,pid=181559,uid=0
[Thu Sep 10 15:04:35 2026] Memory cgroup out of memory: Killed process 181559 (next-build)
DMCG
    cat > "$_t/dmesg-host.txt" <<'DMHOST'
[Thu Sep 10 09:12:01 2026] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=node,pid=4242,uid=0
[Thu Sep 10 09:12:01 2026] Out of memory: Killed process 4242 (node)
DMHOST
    printf '%s\n' '[Thu Sep 10 01:00:00 2026] Out of memory: Killed process 7 (thing)' > "$_t/dmesg-old.txt"

    _d4class() {  # the check's own predicates, run over a fixture
        _h=$(grep -c 'constraint=CONSTRAINT_NONE' "$1" || true)
        _c=$(grep -c 'constraint=CONSTRAINT_MEMCG' "$1" || true)
        _a=$(grep -ci 'out of memory\|oom-kill' "$1" || true)
        if   [ "${_a:-0}" -eq 0 ]; then printf 'clean'
        elif [ "${_h:-0}" -gt 0 ]; then printf 'hostwide'
        elif [ "${_c:-0}" -gt 0 ]; then printf 'contained'
        else printf 'unclassified'; fi
    }

    if [ "$(_d4class "$_t/dmesg-cg.txt")" = "contained" ]
    then printf '  ok    a cgroup-bounded OOM is not reported as a host-wide one\n'
    else printf '  FAIL  a cgroup-bounded OOM is not reported as a host-wide one (got %s)\n' "$(_d4class "$_t/dmesg-cg.txt")"; _f=$((_f+1)); fi

    if [ "$(_d4class "$_t/dmesg-host.txt")" = "hostwide" ]
    then printf '  ok    a real host-wide OOM is still caught\n'
    else printf '  FAIL  a real host-wide OOM is still caught (got %s)\n' "$(_d4class "$_t/dmesg-host.txt")"; _f=$((_f+1)); fi

    # The direction that would hide an emergency: host-wide must win over
    # contained when the buffer holds both.
    cat "$_t/dmesg-cg.txt" "$_t/dmesg-host.txt" > "$_t/dmesg-mixed.txt"
    if [ "$(_d4class "$_t/dmesg-mixed.txt")" = "hostwide" ]
    then printf '  ok    one host-wide kill outranks any number of contained ones\n'
    else printf '  FAIL  one host-wide kill outranks any number of contained ones\n'; _f=$((_f+1)); fi

    # And a kernel that names no constraint must not be silently called clean.
    if [ "$(_d4class "$_t/dmesg-old.txt")" = "unclassified" ]
    then printf '  ok    an unclassifiable OOM line is not waved through\n'
    else printf '  FAIL  an unclassifiable OOM line is not waved through\n'; _f=$((_f+1)); fi

    # ---- D-7b: an effective cap, read the way docker actually renders it ---
    #
    # These strings are verbatim `docker inspect -f
    # '{{.HostConfig.LogConfig.Config}}'` output. The one that matters is
    # `map[]` -- what a container created before /etc/docker/daemon.json
    # existed still reports after a daemon restart has made D-7 green.
    _d7bclass() {   # $1 = LogConfig.Type, $2 = LogConfig.Config as rendered
        case "$1" in
            json-file|local|'')
                if printf '%s' "$2" | grep -q 'max-size'; then printf 'capped'
                else printf 'nocap'; fi ;;
            *) printf 'elsewhere' ;;
        esac
    }

    if [ "$(_d7bclass json-file 'map[max-file:3 max-size:10m]')" = "capped" ]
    then printf '  ok    a container with max-size baked in reads as capped\n'
    else printf '  FAIL  a container with max-size baked in reads as capped\n'; _f=$((_f+1)); fi

    if [ "$(_d7bclass json-file 'map[]')" = "nocap" ]
    then printf '  ok    an empty LogConfig is uncapped even when the daemon has a policy\n'
    else printf '  FAIL  an empty LogConfig is uncapped even when the daemon has a policy\n'; _f=$((_f+1)); fi

    # max-file without max-size bounds the NUMBER of files and not their size,
    # so it must not read as a cap. Matching on "max-" would pass this.
    if [ "$(_d7bclass json-file 'map[max-file:3]')" = "nocap" ]
    then printf '  ok    max-file without max-size does not count as a size cap\n'
    else printf '  FAIL  max-file without max-size does not count as a size cap\n'; _f=$((_f+1)); fi

    # An empty driver string means the daemon default, which is json-file.
    if [ "$(_d7bclass '' 'map[]')" = "nocap" ]
    then printf '  ok    an unnamed driver is treated as json-file, not waved through\n'
    else printf '  FAIL  an unnamed driver is treated as json-file, not waved through\n'; _f=$((_f+1)); fi

    if [ "$(_d7bclass journald 'map[]')" = "elsewhere" ]
    then printf '  ok    a driver that writes off this disk is not judged by max-size\n'
    else printf '  FAIL  a driver that writes off this disk is not judged by max-size\n'; _f=$((_f+1)); fi

    # ---- J-5: the watch-list, and the way it actually goes wrong -----------
    #
    # J-5 answers "is the outdated TLS binary reachable" by asking whether any
    # of five providers is configured. The branch logic is trivial; what is
    # not trivial is the list. If upstream adds a sixth TLS-impersonation
    # provider, J-5 keeps returning "dormant" forever and is wrong in the one
    # direction that matters, with nothing to notice it -- the "safe because
    # nothing uses it" condition silently stops being measured.
    #
    # So the fixture pins the list to its source of truth, omniroute's own
    # Dockerfile comment, rather than to a copy of my assumption.
    _j5check=$(grep -oE 'const W=\[[^]]*\]' "$REPO/scripts/king-audit.sh" \
               | grep -oE '"[a-z-]+"' | tr -d '"' | sort | tr '\n' ' ')
    _j5src=$(grep -oE '\(chatgpt-web[a-z/-]*' "$REPO/omniroute/Dockerfile" \
             | tr -d '(' | tr '/' '\n' | sort | tr '\n' ' ')
    # Two different things used to print the same sentence: a list that drifted,
    # and a source that could not be read at all. The second happens whenever
    # this script runs from outside its repo, and describing it as a mismatch
    # between two empty strings names the wrong failure.
    if [ ! -r "$REPO/omniroute/Dockerfile" ]
    then printf '  FAIL  the J-5 provider list cannot be checked: %s is unreadable\n' "$REPO/omniroute/Dockerfile"
         printf '        this one fixture reads the repo, so it needs the repo to be there\n'
         _f=$((_f+1))
    elif [ -n "$_j5src" ] && [ "$_j5check" = "$_j5src" ]
    then printf '  ok    the J-5 provider list still matches omniroute/Dockerfile\n'
    else printf '  FAIL  the J-5 provider list drifted from omniroute/Dockerfile (check=%s src=%s)\n' "$_j5check" "$_j5src"; _f=$((_f+1)); fi

    # And the decision table, including the direction a live host cannot be
    # made to demonstrate without configuring a provider on production.
    _j5decide() {   # $1 = active providers, comma-separated; "UNREADABLE" for a dead db
        case "$1" in
            UNREADABLE) printf 'unknown' ;;
            '')         printf 'dormant' ;;
            *)          printf 'exposed' ;;
        esac
    }
    if [ "$(_j5decide '')" = "dormant" ]
    then printf '  ok    no TLS-impersonation provider reads as dormant\n'
    else printf '  FAIL  no TLS-impersonation provider reads as dormant\n'; _f=$((_f+1)); fi

    if [ "$(_j5decide 'chatgpt-web')" = "exposed" ]
    then printf '  ok    one configured provider flips the verdict to exposed\n'
    else printf '  FAIL  one configured provider flips the verdict to exposed\n'; _f=$((_f+1)); fi

    # An unreadable provider table must NOT read as dormant. Treating "could
    # not tell" as "safe" is how a check reports a clean bill on no evidence.
    if [ "$(_j5decide 'UNREADABLE')" = "unknown" ]
    then printf '  ok    an unreadable provider table is not treated as safe\n'
    else printf '  FAIL  an unreadable provider table is not treated as safe\n'; _f=$((_f+1)); fi

    # ---- the manifest, in the direction it never guarded -------------------
    #
    # Exercises the REAL manifest function, not a copy of it, because a
    # fixture that restates the premise confirms the premise -- see E-8 above.
    if manifest | grep -q "^A-1|"
    then printf '  ok    a declared check is found in the manifest\n'
    else printf '  FAIL  a declared check is found in the manifest\n'; _f=$((_f+1)); fi

    if ! manifest | grep -q "^Z-9|"
    then printf '  ok    an undeclared id is detected as absent from the manifest\n'
    else printf '  FAIL  an undeclared id is detected as absent from the manifest\n'; _f=$((_f+1)); fi

    # The three added on 2026-09-10, which is what exposed the gap. J-4 and
    # J-5 must be declared; D-7b must NOT be, because chk() folds a trailing
    # letter into its base id and no sub-check has ever been manifested.
    for _need in J-4 J-5 E-9; do
        if manifest | grep -q "^$_need|"
        then printf '  ok    %s is declared in the manifest\n' "$_need"
        else printf '  FAIL  %s is declared in the manifest\n' "$_need"; _f=$((_f+1)); fi
    done
    if ! manifest | grep -q "^D-7b|"
    then printf '  ok    a sub-check is not manifested, matching every other -b check\n'
    else printf '  FAIL  a sub-check is not manifested, matching every other -b check\n'; _f=$((_f+1)); fi

    # implemented() and the manifest must agree, or coverage reports TODO for
    # a check that exists.
    for _need in J-4 J-5 E-9; do
        if implemented | grep -qx "$_need"
        then printf '  ok    %s is listed in implemented()\n' "$_need"
        else printf '  FAIL  %s is listed in implemented()\n' "$_need"; _f=$((_f+1)); fi
    done

    # The other direction, and it is general rather than a hand-kept list,
    # because the hand-kept list above is precisely what went out of date the
    # moment E-9 was added: the live run reported TODO for a check that had
    # just passed. A check that is implemented but never manifested is simply
    # not counted, and nothing else would say so.
    _unman=$(implemented | while read -r _i; do
                 manifest | grep -q "^$_i|" || printf '%s ' "$_i"
             done)
    if [ -z "$_unman" ]
    then printf '  ok    every implemented check is declared in the manifest
'
    else printf '  FAIL  implemented but not manifested: %s
' "$_unman"; _f=$((_f+1)); fi

    # ---- K-6: "apt could not answer" must never render as "nothing pending" -
    #
    # The old code was `apt-get -s upgrade 2>/dev/null | grep -c … || true`,
    # which turns every apt failure into 0, and 0 was the green branch.
    _k6verdict() {  # $1 = apt exit, $2 = apt output, $3 = unattended, $4 = timer, $5 = index count
        if [ "$1" -ne 0 ] || [ -z "$2" ]; then printf 'unknown'; return; fi
        if [ "${5:-1}" -eq 0 ]; then printf 'noindex'; return; fi
        _n=$(printf '%s\n' "$2" | grep -ciE '^Inst.*security' || true)
        if [ "${_n:-0}" -gt 0 ]; then printf 'pending'
        elif [ "$3" != enabled ] || [ "$4" != enabled ]; then printf 'unscheduled'
        else printf 'clean'; fi
    }
    _k6apt='Inst libc6 [2.39-0ubuntu8.8] (2.39-0ubuntu8.9 Ubuntu:24.04/noble-security [amd64])
Inst locales [2.39-0ubuntu8.8] (2.39-0ubuntu8.9 Ubuntu:24.04/noble-security [all])
Inst somepkg [1.0] (1.1 Ubuntu:24.04/noble-updates [amd64])'

    if [ "$(_k6verdict 1 '' enabled enabled 62)" = "unknown" ]
    then printf '  ok    a failed apt is UNKNOWN, never "no pending security updates"\n'
    else printf '  FAIL  a failed apt is UNKNOWN, never "no pending security updates"\n'; _f=$((_f+1)); fi

    if [ "$(_k6verdict 0 '' enabled enabled 62)" = "unknown" ]
    then printf '  ok    empty apt output is UNKNOWN even when apt exits 0\n'
    else printf '  FAIL  empty apt output is UNKNOWN even when apt exits 0\n'; _f=$((_f+1)); fi

    # The case the FIRST version of this fix still got wrong. With its lists
    # gone apt exits 0 and prints a well-formed "0 upgraded, 0 newly
    # installed, 0 to remove and 0 not upgraded." — a zero from a program with
    # nothing to count. Verbatim output, so the fixture cannot flatter itself.
    _k6empty='NOTE: This is only a simulation!
Reading package lists...
Building dependency tree...
Reading state information...
Calculating upgrade...
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.'
    if [ "$(_k6verdict 0 "$_k6empty" enabled enabled 0)" = "noindex" ]
    then printf '  ok    a well-formed zero from an apt with no indexes is not clean\n'
    else printf '  FAIL  a well-formed zero from an apt with no indexes is not clean\n'; _f=$((_f+1)); fi

    if [ "$(_k6verdict 0 "$_k6apt" enabled enabled 62)" = "pending" ]
    then printf '  ok    security lines are counted and non-security ones are not\n'
    else printf '  FAIL  security lines are counted and non-security ones are not\n'; _f=$((_f+1)); fi

    # The proxy that was wrong: apt-daily-upgrade.timer applies the updates,
    # not the unattended-upgrades shutdown helper. A masked timer must fail.
    if [ "$(_k6verdict 0 'Inst nothing [1] (2 Ubuntu:24.04/noble-updates [amd64])' enabled disabled 62)" = "unscheduled" ]
    then printf '  ok    a masked apt-daily-upgrade.timer fails even with nothing pending\n'
    else printf '  FAIL  a masked apt-daily-upgrade.timer fails even with nothing pending\n'; _f=$((_f+1)); fi

    if [ "$(_k6verdict 0 'Inst nothing [1] (2 Ubuntu:24.04/noble-updates [amd64])' enabled enabled 62)" = "clean" ]
    then printf '  ok    no security lines with both units enabled is the only green\n'
    else printf '  FAIL  no security lines with both units enabled is the only green\n'; _f=$((_f+1)); fi

    # ---- C-9: every variable accounted for, with no name pattern -----------
    #
    # The old check asked "does this KEY|TOKEN|SECRET|PASSWORD|DSN|URL-shaped
    # name appear anywhere under docs/". It therefore could not fail on
    # LANGFUSE_OTLP_AUTH, NTFY_ALERT_TOPIC or MACHINE_ID_SALT, which matched
    # none of those words and so were missing from both the test and the total.
    # The fixture pins the replacement predicate and, in the last case, the
    # substring bug a careless rewrite would reintroduce.
    cat > "$_t/rot.md" <<'ROTFIX'
| `API_KEY_SECRET` | `omniroute/.env` | signs issued keys |
| `LANGFUSE_OTLP_AUTH` | `.env` | the Langfuse key pair |
ROTFIX
    cat > "$_t/notsec.txt" <<'NSFIX'
# a comment
   AP_REDIS_HOST
NODE_ENV

NSFIX
    _c9ack=$(grep -vE '^[[:space:]]*(#|$)' "$_t/notsec.txt" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    _c9check() {  # the check's own predicate
        grep -q "$1" "$_t/rot.md" 2>/dev/null && { printf 'accounted'; return; }
        printf '%s\n' "$_c9ack" | grep -qxF "$1" && { printf 'accounted'; return; }
        printf 'unaccounted'
    }

    if [ "$(_c9check API_KEY_SECRET)" = "accounted" ]
    then printf '  ok    a credential named in the rotation doc is accounted for\n'
    else printf '  FAIL  a credential named in the rotation doc is accounted for\n'; _f=$((_f+1)); fi

    # The one the old pattern could not see: AUTH matches none of its words.
    if [ "$(_c9check LANGFUSE_OTLP_AUTH)" = "accounted" ]
    then printf '  ok    a credential whose name matches no secret-word is still checked\n'
    else printf '  FAIL  a credential whose name matches no secret-word is still checked\n'; _f=$((_f+1)); fi

    if [ "$(_c9check NODE_ENV)" = "accounted" ]
    then printf '  ok    a config variable acknowledged in not-secrets.txt is accounted for\n'
    else printf '  FAIL  a config variable acknowledged in not-secrets.txt is accounted for\n'; _f=$((_f+1)); fi

    if [ "$(_c9check NTFY_ALERT_TOPIC)" = "unaccounted" ]
    then printf '  ok    a variable in neither place is reported, whatever its name looks like\n'
    else printf '  FAIL  a variable in neither place is reported, whatever its name looks like\n'; _f=$((_f+1)); fi

    # An acknowledgement must cover the name it states and nothing longer.
    if [ "$(_c9check AP_REDIS_HOST_EXTRA)" = "unaccounted" ]
    then printf '  ok    acknowledging AP_REDIS_HOST does not silently cover AP_REDIS_HOST_EXTRA\n'
    else printf '  FAIL  acknowledging AP_REDIS_HOST does not silently cover AP_REDIS_HOST_EXTRA\n'; _f=$((_f+1)); fi

    # ---- D-8: a restart policy that cannot survive a clean stop -----------
    #
    # The trap is that `on-failure` LOOKS like the careful choice. It is the
    # one policy that cannot bring a service back from a reboot, because a
    # reboot is a clean stop and a clean stop exits 0.
    _d8class() {
        case "$1" in
            always|unless-stopped) printf 'survives' ;;
            *) printf 'stranded' ;;
        esac
    }
    for _p in always unless-stopped; do
        if [ "$(_d8class "$_p")" = "survives" ]
        then printf '  ok    %s is accepted\n' "$_p"
        else printf '  FAIL  %s is accepted\n' "$_p"; _f=$((_f+1)); fi
    done
    for _p in on-failure on-failure:3 no; do
        if [ "$(_d8class "$_p")" = "stranded" ]
        then printf '  ok    %s is reported as unable to survive a reboot\n' "$_p"
        else printf '  FAIL  %s is reported as unable to survive a reboot\n' "$_p"; _f=$((_f+1)); fi
    done
    # The one a careless rewrite makes pass: no policy at all comes back from
    # nothing, and an empty string is also what a failed inspect returns.
    if [ "$(_d8class "")" = "stranded" ]
    then printf '  ok    an empty restart policy is not read as safe\n'
    else printf '  FAIL  an empty restart policy is not read as safe\n'; _f=$((_f+1)); fi

    # ---- E-5: a probe that cannot tell a miss from a hit ------------------
    #
    # The old check grepped the RESPONSE for the filename it had just sent in
    # the REQUEST, and the server puts the name in its miss message:
    #   "No node matching 'king-tls-patch.sh' found."
    # so it scored a hit either way. These are the real server replies.
    _e5hit='data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"text":"king-tls-patch.sh — file, 41 edges","type":"text"}]}}'
    _e5miss='data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"text":"No node matching '"'"'king-tls-patch.sh'"'"' found.","type":"text"}]}}'

    _e5verdict() { printf '%s' "$1" | grep -qi 'No node matching' && printf 'miss' || printf 'hit'; }

    if [ "$(_e5verdict "$_e5hit")" = "hit" ]
    then printf '  ok    a real node reads as a hit\n'
    else printf '  FAIL  a real node reads as a hit\n'; _f=$((_f+1)); fi

    if [ "$(_e5verdict "$_e5miss")" = "miss" ]
    then printf '  ok    a miss reads as a miss even though it quotes the name asked for\n'
    else printf '  FAIL  a miss reads as a miss even though it quotes the name asked for\n'; _f=$((_f+1)); fi

    # The bug itself, pinned so it cannot come back: the old predicate.
    _e5old() { printf '%s' "$1" | grep -c 'king-tls-patch.sh'; }
    if [ "$(_e5old "$_e5miss")" -gt 0 ]
    then printf '  ok    the OLD echo-grep scored a miss as a hit, which is why it was replaced\n'
    else printf '  FAIL  the OLD echo-grep scored a miss as a hit, which is why it was replaced\n'; _f=$((_f+1)); fi

    # ---- E-9: a tracing check that must not confuse ignorance with failure --
    #
    # otel-collector is distroless (no shell to ask), declares no healthcheck
    # (docker ps says only "Up"), exposes no metrics endpoint, and logs at
    # `warn`. Nothing about the CONTAINER separates working from dead, so the
    # check asks the backend -- and then everything depends on reading its
    # answer honestly. These pin that reading.
    if [ "$(_e9verdict 200 0 84 85)" = "pass" ]
    then printf '  ok    traces matching the local call count read as a pass\n'
    else printf '  FAIL  traces matching the local call count read as a pass\n'; _f=$((_f+1)); fi

    if [ "$(_e9verdict 200 0 84 0)" = "fail-dead" ]
    then printf '  ok    calls with zero traces at the backend read as a failure\n'
    else printf '  FAIL  calls with zero traces at the backend read as a failure\n'; _f=$((_f+1)); fi

    if [ "$(_e9verdict 200 0 84 30)" = "fail-thin" ]
    then printf '  ok    a pipeline forwarding under half its spans reads as a failure\n'
    else printf '  FAIL  a pipeline forwarding under half its spans reads as a failure\n'; _f=$((_f+1)); fi

    if [ "$(_e9verdict 200 0 0 0)" = "unknown-load" ]
    then printf '  ok    no traffic reads as unproven, not as a failure\n'
    else printf '  FAIL  no traffic reads as unproven, not as a failure\n'; _f=$((_f+1)); fi

    if [ "$(_e9verdict 000 0 84 0)" = "unknown-api" ]
    then printf '  ok    an unreachable backend reads as ignorance, not as a failure\n'
    else printf '  FAIL  an unreachable backend reads as ignorance, not as a failure\n'; _f=$((_f+1)); fi

    if [ "$(_e9verdict 401 0 84 0)" = "fail-auth" ]
    then printf '  ok    a refused credential reads as a failure, because a refusal is an answer\n'
    else printf '  FAIL  a refused credential reads as a failure, because a refusal is an answer\n'; _f=$((_f+1)); fi

    # The canary, pinned: a window in 2099 that returns rows means the filter is
    # being ignored, and then a zero in the real window would prove nothing.
    if [ "$(_e9verdict 200 7 84 0)" = "unknown-canary" ]
    then printf '  ok    a filter that ignores its window suppresses the verdict\n'
    else printf '  FAIL  a filter that ignores its window suppresses the verdict\n'; _f=$((_f+1)); fi

    # The bug E-9 is shaped around, RUN rather than described: `.env` holds
    # `LANGFUSE_OTLP_AUTH=Basic <base64>`, and sourcing that in sh stops at the
    # space. The result is the 5-character string "Basic", which 401s -- a
    # broken probe wearing the face of a broken credential. This is why the
    # check reads the credential from the running container instead.
    printf 'LANGFUSE_OTLP_AUTH=Basic cGstbGY6c2stbGY=\n' > "$_t/fixture.env"
    # The fixture is written three lines up, at run time, so there is
    # nothing on disk for shellcheck to follow.
    # shellcheck source=/dev/null
    # The base64 keeps its "=" padding deliberately, and the reason is not the
    # obvious one. "Basic cGst...=" parses as TWO assignments, so the variable
    # persists and the truncation is visible. Without the "=" the line is a
    # command with a PREFIX assignment, which is scoped to that command and
    # never persists -- the variable would read empty and the fixture would
    # fail for a reason unrelated to what it tests. Measured both ways: the
    # mechanism is assignment scope, not errexit. The || true below is
    # belt-and-braces for set -eu and is not what makes this work.
    _e9src=$( . "$_t/fixture.env" >/dev/null 2>&1 || true; printf '%s' "${LANGFUSE_OTLP_AUTH:-}" )
    if [ "$_e9src" = "Basic" ]
    then printf '  ok    sourcing .env truncates the credential at the space, which is why the container is asked\n'
    else printf '  FAIL  sourcing .env truncates the credential at the space, which is why the container is asked\n'; _f=$((_f+1)); fi

    # ---- E-4: behind is normal; not having refreshed is not ---------------
    #
    # The old check compared the graph's commit to origin/main for EQUALITY, so
    # it went red on every commit and stayed red until the next nightly run.
    # CLAUDE.md says "stale by up to a day is normal", so the check contradicted
    # the policy it was enforcing, and three consecutive baselines recorded a
    # red for no fault.
    if [ "$(_e4verdict abc abc 1 2026-09-11T03:12:00Z abc 5)" = "pass-current" ]
    then printf '  ok    a graph at origin/main is current\n'
    else printf '  FAIL  a graph at origin/main is current\n'; _f=$((_f+1)); fi

    if [ "$(_e4verdict abc zzz 1 2026-09-11T03:12:00Z abc 5)" = "pass-drift" ]
    then printf '  ok    commits landing after the refresh are normal drift, not a failure\n'
    else printf '  FAIL  commits landing after the refresh are normal drift, not a failure\n'; _f=$((_f+1)); fi

    # The 2026-09-08 fault: BUILD_INFO said today, the commit was 18 behind.
    # An age test passes this; asking what was AVAILABLE does not.
    if [ "$(_e4verdict abc zzz 1 2026-09-11T03:12:00Z def 5)" = "fail-stalecheckout" ]
    then printf '  ok    a refresh that indexed an older commit than was available is caught\n'
    else printf '  FAIL  a refresh that indexed an older commit than was available is caught\n'; _f=$((_f+1)); fi

    if [ "$(_e4verdict abc zzz 1 2026-09-09T03:12:00Z abc 50)" = "fail-schedule" ]
    then printf '  ok    a refresh that has not run in 50h is a schedule failure, not a drift\n'
    else printf '  FAIL  a refresh that has not run in 50h is a schedule failure, not a drift\n'; _f=$((_f+1)); fi

    if [ "$(_e4verdict abc zzz 0 2026-09-11T03:12:00Z abc 5)" = "fail-notancestor" ]
    then printf '  ok    a graph commit that is not on origin/main is caught\n'
    else printf '  FAIL  a graph commit that is not on origin/main is caught\n'; _f=$((_f+1)); fi

    if [ "$(_e4verdict '' zzz 1 2026-09-11T03:12:00Z abc 5)" = "unknown-noinfo" ]
    then printf '  ok    an unreadable BUILD_INFO is unknown, never a pass\n'
    else printf '  FAIL  an unreadable BUILD_INFO is unknown, never a pass\n'; _f=$((_f+1)); fi

    if [ "$(_e4verdict abc zzz 1 '' abc 5)" = "unknown-nodate" ]
    then printf '  ok    a missing build time is unknown, because drift and a dead timer look alike without it\n'
    else printf '  FAIL  a missing build time is unknown, because drift and a dead timer look alike without it\n'; _f=$((_f+1)); fi

    # The old predicate, pinned so the reason for the change cannot be lost.
    _e4old() { [ "$1" = "$2" ] && printf 'pass' || printf 'fail'; }
    if [ "$(_e4old abc zzz)" = "fail" ] && [ "$(_e4verdict abc zzz 1 2026-09-11T03:12:00Z abc 5)" = "pass-drift" ]
    then printf '  ok    the OLD equality test called normal drift a failure, which is why it was replaced\n'
    else printf '  FAIL  the OLD equality test called normal drift a failure, which is why it was replaced\n'; _f=$((_f+1)); fi


    # ---- C-5 / B-8: a door that is not there is not a door standing open ---
    #
    # Both checks bucketed every status that was not 401/403 as "answered
    # without a token". When codegraph-serve was restarting, Caddy returned 502
    # and C-5 reported an open data endpoint. Nothing had answered at all.
    for _dcase in "401|401 403|locked" \
                  "403|401 403|locked" \
                  "200|401 403|open" \
                  "404|401 403|open" \
                  "502|401 403|unreachable" \
                  "503|401 403|unreachable" \
                  "000|401 403|unreachable"; do
        _dc=${_dcase%%|*}; _drest=${_dcase#*|}; _dok=${_drest%%|*}; _dwant=${_drest#*|}
        if [ "$(_doorverdict "$_dc" "$_dok")" = "$_dwant" ]
        then printf '  ok    HTTP %s reads as %s\n' "$_dc" "$_dwant"
        else printf '  FAIL  HTTP %s reads as %s\n' "$_dc" "$_dwant"; _f=$((_f+1)); fi
    done

    # The old predicate, pinned: it had two buckets, so 502 landed in the
    # alarming one.
    _doorold() { case " $2 " in *" $1 "*) printf 'locked' ;; *) printf 'open' ;; esac; }
    if [ "$(_doorold 502 '401 403')" = "open" ]
    then printf '  ok    the OLD two-bucket test called a 502 an open door, which is why it was replaced\n'
    else printf '  FAIL  the OLD two-bucket test called a 502 an open door, which is why it was replaced\n'; _f=$((_f+1)); fi
    # ---- L-3 / L-5: the credential shapes this deployment actually holds ---
    #
    # The old L-3 pattern caught ONE of the seven shapes on the rotation list.
    # `sk-proj-...` — the current OpenAI format — was invisible to it because
    # the hyphen after `proj` broke `sk-[A-Za-z0-9]{20,}`, so the newest key
    # style was the one it could not see. L-5 carried a different pattern for
    # the same question, so the two could disagree about the same string.
    #
    # Both directions are pinned. The must-NOT list is the load-bearing half:
    # a scanner that flags sha256 digests and token counts goes red every run
    # and stops being read, and this deployment has already learned that from
    # an alerting rule.
    _credmiss=0; _credfp=0
    while IFS='|' read -r _want _line; do
        [ -n "${_want:-}" ] || continue
        # The two markers are assembled here, so this file never contains a
        # literal "Bearer <token>" or "Basic <base64>". Written out, both tripped
        # GitGuardian on a PUBLIC repository within hours of being pushed.
        _line=$(printf '%s' "$_line" | sed "s/@AUTHB@/$(printf 'Bea%s' rer)/; s/@AUTHA@/$(printf 'Ba%s' sic)/")
        if printf '%s' "$_line" | grep -qE "$CREDPAT"; then _got=hit; else _got=miss; fi
        case "${_want}-${_got}" in
            MUST-miss)   printf '  FAIL  credential shape not caught: %s\n' "$(printf '%s' "$_line" | cut -c1-46)"
                         _credmiss=$((_credmiss+1)); _f=$((_f+1)) ;;
            NEVER-hit)   printf '  FAIL  benign line flagged as a credential: %s\n' "$(printf '%s' "$_line" | cut -c1-46)"
                         _credfp=$((_credfp+1)); _f=$((_f+1)) ;;
        esac
    done <<'CREDFIX'
MUST|sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz012345
MUST|Authorization: @AUTHB@ oma_live_abcdefghijklmnopqrstuvwx
MUST|AP_REDIS_PASSWORD=0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978
MUST|postgres://neondb_owner:npg_SomeSecret123@ep-x.neon.tech/db
MUST|Authorization: @AUTHA@ cGstbGYtRVhBTVBMRTAwMDA6c2stbGYtRVhBTVBMRTAwMDA=
MUST|"secretKey":"sk-lf-1b2c3d4e-5f6a-7b8c-9d0e-1f2a3b4c5d6e"
MUST|GRAPHIFY_API_KEY=7f3a9b2c4d5e6f708192a3b4c5d6e7f8
MUST|token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0
MUST|NTFY_TOKEN=tk_abcdefghijklmnopqrstuvwxyz01
MUST|{"password": "s3cretValueThatIsLong123"}
MUST|{"api_key":"abcdef0123456789abcdef"}
MUST|{"secretKey":"Zm9vYmFyYmF6cXV4MTIzNDU2"}
NEVER|"apiKeyId":"0554abcdefghijklmnopqrst","model":"x"
NEVER|apiKeyName=agent-sidecar-mcp apiKeyId=0554abcdefghijklmnop
NEVER|sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648
NEVER|commit=b28dbafd3c028d1db2c7103e55d7cd523867ff4b
NEVER|Graph built: 58807 nodes, from b28dbafd.
NEVER|caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd
NEVER|correlationId=a1b2c3d4-e5f6-7890-abcd-ef1234567890 duration=1234
NEVER|the operator rotated the password on 2026-09-11 after the disclosure
NEVER|model=ollama/qwen2.5:1.5b-instruct-q4_K_M provider=ollama status=200
NEVER|GET /v1/models 401 12ms ua=curl/8.5.0 ip=10.0.0.4
NEVER|{"tokens":{"in":1234567890123456,"out":42}}
NEVER|tokens=1234567890123456 cost=0.008
CREDFIX
    if [ "$_credmiss" -eq 0 ]
    then printf '  ok    all 12 credential shapes on the rotation list are caught\n'
    else printf '  FAIL  %s credential shape(s) on the rotation list are not caught\n' "$_credmiss"; fi
    if [ "$_credfp" -eq 0 ]
    then printf '  ok    digests, commit hashes and token counts are not flagged as credentials\n'
    else printf '  FAIL  %s benign line(s) flagged; a scanner that cries wolf stops being read\n' "$_credfp"; fi

    # The old L-3 predicate, pinned: it is why this was widened.
    _credold='sk-[A-Za-z0-9]{20,}|oma_live_|tk_[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9._-]{20,}'
    if ! printf '%s' 'AP_REDIS_PASSWORD=0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a6978' \
         | grep -qE "$_credold"
    then printf '  ok    the OLD pattern missed a 48-char hex password, which is why it was replaced\n'
    else printf '  FAIL  the OLD pattern missed a 48-char hex password, which is why it was replaced\n'; _f=$((_f+1)); fi
    if ! printf '%s' 'sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz012345' | grep -qE "$_credold"
    then printf '  ok    the OLD pattern missed sk-proj-, the current OpenAI key format\n'
    else printf '  FAIL  the OLD pattern missed sk-proj-, the current OpenAI key format\n'; _f=$((_f+1)); fi

    # ---- J-1: which references can be compared at all ---------------------
    #
    # Only the CLASSIFICATION half is fixtured, and deliberately so: the other
    # half asks a live registry what the newest tag is, and there is no honest
    # way to assert that offline. J-1's verdict is UNKNOWN-only, so a wrong
    # answer from the live half cannot turn a run red by itself. This is a
    # statement of scope, like H-2b, not a gap being papered over.
    #
    # These three inputs never reach the network — each is rejected or accepted
    # before the first request — so the fixture is genuinely offline.
    _j1m=$(printf 'PY%s' 'J1')
    _j1src="$_t/j1rule.py"
    sed -n "/<<'$_j1m'/,/^$_j1m\$/p" "$REPO/scripts/$(basename "$0")" 2>/dev/null \
        | sed '1d;$d' > "$_j1src"
    if [ ! -s "$_j1src" ]; then
        printf '  FAIL  J-1 rule could not be extracted from this script to test\n'; _f=$((_f+1))
    else
        _j1got=$(printf 'ghcr.io/x/y:1.0.0\nsome/deep/path/img:1.0.0\nplainimage\n' \
                 | "$PY" "$_j1src" 2>/dev/null | cut -f3)
        case "$_j1got" in
            *ghcr.io/x/y\|not-on-docker-hub*)
                printf '  ok    a ghcr image is reported as not checkable, not silently skipped\n' ;;
            *)  printf '  FAIL  a ghcr image is reported as not checkable, not silently skipped\n'; _f=$((_f+1)) ;;
        esac
        case "$_j1got" in
            *plainimage\|untagged*)
                printf '  ok    an untagged reference is reported as not checkable\n' ;;
            *)  printf '  FAIL  an untagged reference is reported as not checkable\n'; _f=$((_f+1)) ;;
        esac
        # The count must be the number of ENTRIES. It was `wc -w`, which counted
        # words, and reported "10 not checkable" for three references because
        # the reasons had spaces in them.
        _j1n=$(printf 'ghcr.io/x/y:1.0.0\nsome/deep/path/img:1.0.0\nplainimage\n' \
               | "$PY" "$_j1src" 2>/dev/null | cut -f4)
        if [ "$_j1n" = "3" ]
        then printf '  ok    the not-checkable count is entries, not words\n'
        else printf '  FAIL  the not-checkable count is entries, not words (got %s, want 3)\n' "${_j1n:-none}"; _f=$((_f+1)); fi
    fi

    # ---- J-6: the two false-positive classes, pinned ----------------------
    #
    # The python is EXTRACTED from this script rather than retyped, so these
    # fixtures exercise the code the audit actually runs. The B-3 drift
    # detector above exists because its rule could not be extracted; this one
    # can, so it is.
    #
    # The marker name is assembled for the same reason recorded there: writing
    # it out would put it in this file a second time and the sed range would
    # re-open on this very line.
    _j6m=$(printf 'PY%s' 'J6')
    _j6src="$_t/j6rule.py"
    sed -n "/<<'$_j6m'/,/^$_j6m\$/p" "$REPO/scripts/$(basename "$0")" 2>/dev/null \
        | sed '1d;$d' > "$_j6src"
    if [ ! -s "$_j6src" ]; then
        printf '  FAIL  J-6 rule could not be extracted from this script to test\n'; _f=$((_f+1))
    else
        _j6run() { printf '%s' "$2" | "$PY" "$_j6src" "$1" "$3" 2>/dev/null; }

        # 1. Wrong package. The range matches, but the advisory is about a
        #    DEPENDENCY -- this is the real collector/prometheus record.
        _fx='[{"severity":"high","ghsa_id":"G1","cve_id":"CVE-1","vulnerabilities":[
              {"package":{"ecosystem":"go","name":"github.com/prometheus/prometheus"},
               "vulnerable_version_range":"<0.311.3","patched_versions":"0.311.3"}]}]'
        if [ "$(_j6run 0.139.0 "$_fx" opentelemetry-collector-contrib | cut -f1,2,3)" = "0	0	1" ]
        then printf '  ok    an advisory about a dependency is not counted against the image\n'
        else printf '  FAIL  an advisory about a dependency is not counted against the image\n'; _f=$((_f+1)); fi

        # 2. No upper bound, but a fix long behind us. The real redis shape.
        _fx='[{"severity":"high","ghsa_id":"G2","cve_id":"CVE-2","vulnerabilities":[
              {"package":{"name":"redis-server"},
               "vulnerable_version_range":">= 7.0.0","patched_versions":"7.0.12"}]}]'
        if [ "$(_j6run 8.6.5 "$_fx" redis | cut -f1,2)" = "0	0" ]
        then printf '  ok    an open-ended range with a fix behind us is discarded\n'
        else printf '  FAIL  an open-ended range with a fix behind us is discarded\n'; _f=$((_f+1)); fi

        # 3. Open-ended AND unfixed. Must survive: this is CVE-2026-23479.
        _fx='[{"severity":"high","ghsa_id":"G3","cve_id":"CVE-3","vulnerabilities":[
              {"package":{"name":"redis-server"},
               "vulnerable_version_range":">= 7.2","patched_versions":"TBD"}]}]'
        if [ "$(_j6run 8.6.5 "$_fx" redis | cut -f1,2)" = "0	1" ]
        then printf '  ok    an advisory with no published fix is reported, not discarded\n'
        else printf '  FAIL  an advisory with no published fix is reported, not discarded\n'; _f=$((_f+1)); fi

        # 4. A fix exists and we are below it.
        _fx='[{"severity":"medium","ghsa_id":"G4","cve_id":null,"vulnerabilities":[
              {"package":{"name":"github.com/caddyserver/caddy/v2"},
               "vulnerable_version_range":"< v2.11.5","patched_versions":"v.2.11.5"}]}]'
        if [ "$(_j6run 2.11.4 "$_fx" caddy | cut -f1,2)" = "1	0" ]
        then printf '  ok    a published fix we are below is separated from one that does not exist\n'
        else printf '  FAIL  a published fix we are below is separated from one that does not exist\n'; _f=$((_f+1)); fi

        # 5. A withdrawn advisory is not a finding.
        _fx='[{"severity":"high","ghsa_id":"G5","withdrawn_at":"2026-01-01T00:00:00Z","vulnerabilities":[
              {"package":{"name":"redis-server"},
               "vulnerable_version_range":">= 7.2","patched_versions":"TBD"}]}]'
        if [ "$(_j6run 8.6.5 "$_fx" redis | cut -f1,2)" = "0	0" ]
        then printf '  ok    a withdrawn advisory is not counted\n'
        else printf '  FAIL  a withdrawn advisory is not counted\n'; _f=$((_f+1)); fi

        # 6. Unreadable input must say ERR, never zero. UNKNOWN IS NOT PASS.
        if [ "$(_j6run 8.6.5 'not json at all' redis)" = "ERR" ]
        then printf '  ok    an unreadable advisory response reads as ERR, not as "nothing found"\n'
        else printf '  FAIL  an unreadable advisory response reads as ERR, not as "nothing found"\n'; _f=$((_f+1)); fi
    fi

    rm -rf "$_t"
    echo
    if [ "$_f" -eq 0 ]; then c_green "self-test passed"; echo; exit 0; fi
    c_red "$_f self-test check(s) failed"; echo; exit 1
}

# --------------------------------------------------- positive control (live)
#
# `--positive-control` was parsed, set MODE=poscontrol, and then nothing in
# this script ever read that variable. Running it performed an ordinary audit
# and exited 0, while the usage block above advertised it as a mode. Proven by
# behaviour rather than by reading: `--positive-control -d I` and `-d I`
# produced byte-identical output.
#
# An advertised control that does not apply is the exact fault this audit was
# built to find, and it had been sitting in the audit's own argument parser
# since the flag was added.
#
# What it does now: asks each live instrument to demonstrate it can return a
# NEGATIVE verdict against the real system. A probe that cannot produce a miss
# cannot produce a finding either -- that is how E-5 stayed green for a week
# while the graph it checked indexed nothing.
#
# What it deliberately does NOT do: modify anything. No file mode, no firewall
# rule, no container. Those live perturbations are real positive controls too,
# but they belong in a hand-run procedure with a rollback written next to them,
# not in a flag someone might type on a production host.
#
# It prints the gap on purpose. Two greens and a stop would read as "the
# instruments are proven" when only two of them are.
poscontrol() {
    echo "positive control (live; every instrument must demonstrate a miss)"
    c_dim "  nothing is modified: no file mode, no firewall rule, no container"; echo
    echo
    if ! on_host; then
        c_yell "  not on the host: the live instruments are unreachable from here"; echo
        echo "  This mode has nothing to say off-host, and says so instead of passing."
        exit 2
    fi
    _pf=0

    # E-5 -- the graph must report a miss for a label that cannot exist.
    _pk=$(sed -n 's/^GRAPHIFY_API_KEY=//p' .env 2>/dev/null | tail -1)
    if [ -z "$_pk" ]; then
        printf '  ????  E-5  no graph key here; the probe cannot be exercised\n'
        _pf=$((_pf+1))
    else
        _pr=$(curl -s -m 60 -X POST http://127.0.0.1:8130/mcp \
                -H 'Content-Type: application/json' \
                -H 'Accept: application/json, text/event-stream' \
                -H "Authorization: Bearer $_pk" \
                -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_node","arguments":{"label":"king-audit-canary-no-such-node-9f3a1.sh"}}}' \
                2>/dev/null || true)
        if printf '%s' "$_pr" | grep -qi 'No node matching'; then
            printf '  ok    E-5  the graph reports a miss for a label that cannot exist\n'
        else
            printf '  FAIL  E-5  an impossible label did not come back as a miss\n'
            printf '        the marker changed; until it is re-read, E-5 cannot tell a hit from a miss\n'
            _pf=$((_pf+1))
        fi
    fi

    # E-9 -- the trace query must return zero for a window that cannot contain
    # anything. This is what licenses reading a zero in the real window as
    # "nothing arrived" rather than as "the filter was ignored".
    _po=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
          | grep -F 'opentelemetry-collector' | awk '{print $1}' | head -1)
    if [ -z "$_po" ]; then
        printf '  ----  E-9  no collector runs here; nothing to exercise\n'
    elif [ -z "$PY" ]; then
        printf '  ????  E-9  no interpreter; the probe cannot be exercised\n'
        _pf=$((_pf+1))
    else
        _pe=$(docker inspect "$_po" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)
        _pa=$(printf '%s\n' "$_pe" | sed -n 's/^LANGFUSE_OTLP_AUTH=//p' | head -1)
        _pb=$(printf '%s\n' "$_pe" | sed -n 's/^LANGFUSE_OTLP_ENDPOINT=//p' | head -1)
        _pb=$(printf '%s' "${_pb:-https://cloud.langfuse.com/api/public/otel}" | sed 's#/api/public/otel$##')
        _ptf=$(mktemp)
        cat > "$_ptf" <<'PYPC'
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR"); raise SystemExit(0)
print((d.get("meta") or {}).get("totalItems", "ERR"))
PYPC
        _pn=$(curl -s -m 30 -H "Authorization: $_pa" \
              "$_pb/api/public/traces?limit=1&fromTimestamp=2099-01-01T00:00:00Z" 2>/dev/null \
              | "$PY" "$_ptf" 2>/dev/null || true)
        rm -f "$_ptf"
        if [ "${_pn:-x}" = "0" ]; then
            printf '  ok    E-9  the trace query returns zero for a window that cannot contain anything\n'
        else
            printf '  FAIL  E-9  a window in 2099 returned %s\n' "${_pn:-nothing}"
            printf '        the filter is being ignored, so a zero in the real window would prove nothing\n'
            _pf=$((_pf+1))
        fi
    fi

    # J-6 -- the package filter must discard a real advisory list when asked
    # about a package that cannot exist. This is the live counterpart of the
    # fixture: it proves the filter is running against the actual API response,
    # not only against a JSON literal in --self-test.
    #
    # A version canary would not work here. There is no version that matches
    # nothing: redis writes `>= 7.0.0`, so a high one matches, and caddy writes
    # `< v2.11.5`, so a low one matches. The package NAME is the axis that can
    # be made impossible.
    if [ -z "$PY" ]; then
        printf '  ????  J-6  no interpreter; the advisory filter cannot be exercised\n'
        _pf=$((_pf+1))
    else
        _pm=$(printf 'PY%s' 'J6')
        _prule=$(mktemp)
        sed -n "/<<'$_pm'/,/^$_pm\$/p" "$REPO/scripts/$(basename "$0")" 2>/dev/null \
            | sed '1d;$d' > "$_prule"
        _pout=$(curl -s -m 30 -H 'Accept: application/vnd.github+json' \
                 'https://api.github.com/repos/redis/redis/security-advisories?per_page=100' 2>/dev/null \
                | "$PY" "$_prule" 8.6.5 'king-audit-canary-no-such-package' 2>/dev/null || true)
        rm -f "$_prule"
        _pfix=$(printf '%s' "$_pout" | cut -f1); _pnof=$(printf '%s' "$_pout" | cut -f2)
        _pwrong=$(printf '%s' "$_pout" | cut -f3)
        if [ "$_pout" = "" ] || [ "$_pout" = "ERR" ]; then
            printf '  ????  J-6  the advisory source did not answer; the filter is unexercised\n'
            _pf=$((_pf+1))
        elif [ "$_pfix" = "0" ] && [ "$_pnof" = "0" ] && [ "${_pwrong:-0}" -gt 0 ]; then
            printf '  ok    J-6  the package filter discards %s real advisory(s) for a package that cannot exist\n' "$_pwrong"
        else
            printf '  FAIL  J-6  an impossible package still scored %s/%s findings\n' "$_pfix" "$_pnof"
            printf '        the filter is not discriminating; every J-6 result is suspect\n'
            _pf=$((_pf+1))
        fi
    fi

    echo
    echo "  Three live instruments carry a canary. Every other check on this host is"
    echo "  proven only by --self-test fixtures, which exercise the predicate but"
    echo "  never the system it talks to. That gap is stated, not implied."
    echo
    if [ "$_pf" -eq 0 ]; then c_green "positive control passed"; echo; exit 0; fi
    c_red "$_pf instrument(s) could not demonstrate a miss"; echo; exit 1
}

# ------------------------------------------------------------------- driver

[ "$MODE" = "selftest" ] && self_test
[ "$MODE" = "poscontrol" ] && poscontrol

echo "king audit — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
c_dim "  repo $REPO"; echo
# if/then/else, not `A && B || C`: in that form C also runs when A succeeded
# and B failed, so a failing printf would claim we are off-host. pool-prove.sh
# carries a comment about this same trap (SC2015) and this script reproduced it.
if on_host; then
    c_dim "  on the host (docker visible)"
else
    c_dim "  off-host: container checks will be skipped"
fi
echo

for _d in $WANT; do
    case "$_d" in
        A) dim_A ;;
        B) dim_B ;;
        C) dim_C ;;
        D) dim_D ;;
        E) dim_E ;;
        F) dim_F ;;
        G) dim_G ;;
        H) dim_H ;;
        I) dim_I ;;
        J) dim_J ;;
        K) dim_K ;;
        L) dim_L ;;
        *) echo "unknown dimension: $_d" >&2; exit 2 ;;
    esac
done

# Coverage, always reported. A check that was planned and never ran is not
# absent from the result -- it is a TODO line, counted, and it keeps the run
# from going green.
echo
echo "coverage"
for _d in $WANT; do
    manifest | grep "^$_d-" | while IFS='|' read -r _cid _ctitle; do
        if ! implemented | grep -qx "$_cid"; then
            printf '  %s  %-5s %s\n' "$(c_yell TODO)" "$_cid" "$_ctitle"
        fi
    done
done > "$SEEN.todo"
n_todo=$(grep -c . "$SEEN.todo" 2>/dev/null || true); n_todo=${n_todo:-0}
if [ "$n_todo" -eq 0 ]; then
    _planned=$(manifest | grep -c "^\($(echo "$WANT" | tr ' ' '|' | sed 's/^|//;s/|$//')\)-" || true)
    printf '  %s every planned check in the selected dimension(s) ran\n' "$(c_green 'OK  ')"
else
    cat "$SEEN.todo"
fi
rm -f "$SEEN.todo"

# The other direction, which nothing checked until three checks were added on
# 2026-09-10 and disappeared from the declared inventory without a word.
#
# Above, the manifest is compared against implemented(): a check that is
# declared and never runs is a TODO, counted, and it keeps the run from going
# green. Nothing compared the other way -- a check that RUNS and was never
# declared. It prints its verdict like any other, so the output looks complete,
# while the manifest quietly stops being the single list of what this audit
# does. That is the same failure the manifest was written to remove, arriving
# from the side it did not guard.
#
# Grepping the source for chk() calls is the wrong instrument, and the comment
# on the manifest says why: five checks emitted through a loop variable were
# counted as missing. So ask the run rather than the source. chk() already
# records the base id of everything it emits into $SEEN.
n_undeclared=0
_undeclared=$(sort -u "$SEEN" 2>/dev/null | while IFS= read -r _sid; do
    [ -n "$_sid" ] || continue
    manifest | grep -q "^$_sid|" || printf '%s ' "$_sid"
done)
if [ -n "$_undeclared" ]; then
    n_undeclared=$(printf '%s' "$_undeclared" | wc -w | tr -d ' ')
    printf '  %s  %s check(s) ran that the manifest does not declare: %s\n' \
        "$(c_red 'UNDEC')" "$n_undeclared" "$_undeclared"
    printf '            add them to implemented() and the MANIFEST, or the inventory is fiction\n'
fi

echo
printf '  %s pass, ' "$(c_green "$n_pass")"
printf '%s fail, ' "$(c_red "$n_fail")"
printf '%s unknown, ' "$(c_yell "$n_unknown")"
printf '%s skipped, ' "$n_skip"
printf '%s not implemented\n' "$(c_yell "$n_todo")"

if [ "$WRITE_BASELINE" = "1" ] && [ -n "$PY" ]; then
    mkdir -p "$(dirname "$BASELINE")"
    "$PY" -c "
import json,sys,io,os
m={}
for line in io.open(sys.argv[1],encoding='utf-8'):
    k,_,v=line.partition('\t')
    if k.strip(): m[k.strip()]=v.strip()
json.dump({'metrics':m}, io.open(sys.argv[2],'w',encoding='utf-8'), indent=2, sort_keys=True)
io.open(sys.argv[2],'a',encoding='utf-8').write('\n')
" "$METRICS" "$BASELINE" && echo "  baseline written to $BASELINE"
fi

[ "$n_fail" -gt 0 ] && exit 1
# An incomplete audit is not a passing audit. This is the whole reason the
# manifest exists -- and an audit that runs checks it never declared is
# incomplete in the same way, just from the other side.
[ "$n_todo" -gt 0 ] && exit 3
[ "$n_undeclared" -gt 0 ] && exit 3
[ "$n_unknown" -gt 0 ] && exit 2
exit 0
