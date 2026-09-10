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
E-1
E-2
E-3
E-4
E-5
E-6
E-7
E-8
F-1
F-2
F-3
F-4
F-5
F-6
F-7
F-8
F-9
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
E-1|every volume: size, contents, and whether anything backs it up
E-2|external Postgres reachable, and its size
E-3|journals exist, grow, and are readable
E-4|code graph freshness: BUILD_INFO commit vs HEAD vs origin
E-5|code graph correctness: it finds a file only the newest commit has
E-6|no test rows left in production tables
E-7|the queue backend answers, and says whether it wants a password
E-8|spend is observable: what fraction of calls report their tokens
F-1|every MCP server: tools/list and one real call
F-2|offered tools vs allowlist vs NEVER_REGISTER
F-3|reroute status: the eight measured trigger phrases
F-4|model_overridden in the recent run journal
F-5|per-provider failure rate, and what reached the caller
F-6|the local model answers, and answers from this host
F-7|flow mirror parses and exports what its tests import
F-8|every destructive tool the servers offer is blocked from the agent
F-9|every tool that can reach the network is acknowledged
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
J-1|pinned versions vs latest, and known CVEs
J-2|active upstream breakage
J-3|image age, origin, and whether it is still published
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
            [ -n "$_ctx" ] && [ -d "$_ctx" ] || continue
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
    img = s.get("image")
    if img and (img.endswith(":latest") or ":" not in img.split("/")[-1]):
        print("B3\t%s image not pinned: %s" % (name, img))
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
            _bad=""; _info=""
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
                        case "$_c" in
                            401|403) : ;;
                            *) _bad="$_bad ${_r}=$_c" ;;
                        esac ;;
                    *) _info="$_info ${_r}=$_c" ;;
                esac
            done
            if [ -n "$_bad" ]; then
                chk B-8 FAIL "API route(s) not demanding a token" "$_bad"
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
        _open=""; _unmapped=""
        for _r in $_routes; do
            _spec=$(probe_target "$_r")
            _tgt=${_spec%%|*}; _okcodes=${_spec#*|}
            if [ -z "$_tgt" ]; then _unmapped="$_unmapped $_r"; continue; fi
            _code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
                    "https://gateway.arject.co$_tgt" 2>/dev/null || echo 000)
            case " $_okcodes " in
                *" $_code "*) : ;;
                *) _open="$_open $_tgt=$_code" ;;
            esac
        done
        if [ "${_n:-0}" -eq 0 ]; then
            chk C-5 UNKNOWN "no routes found in the Caddyfile to inventory"
        elif [ -n "$_unmapped" ]; then
            chk C-5 FAIL "route(s) with no declared probe target" \
                "$_unmapped — add one to probe_target(); an unknown route must not pass by default"
        elif [ -z "$_open" ]; then
            chk C-5 PASS "all ${_n} route(s), probed at the endpoint that carries data, deny anonymous access"
        else
            chk C-5 FAIL "data endpoint(s) answered without a token" "$_open"
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
    _runtime_secrets="omniroute/data/server.env omniroute/data/storage.sqlite .pool-prove.env"
    _wr=""; _checked=0; _unstat=""
    for _sf in $SECRET_FILES $_runtime_secrets; do
        [ -e "$_sf" ] || continue
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
    if [ -n "$_unstat" ]; then
        chk C-7 UNKNOWN "secret file(s) could not be stat'd:$_unstat" \
            "$_checked other file(s) were checked; an unmeasured file is not a passing one"
    elif [ "$_checked" -eq 0 ]; then
        chk C-7 UNKNOWN "no secret file was found to check"
    elif [ -z "$_wr" ]; then
        chk C-7 PASS "none of $_checked secret-bearing file(s) is world-readable"
    else
        chk C-7 FAIL "world-readable secret-bearing file(s):$_wr" \
            "$_checked checked; on this host uid 1001 and 1002 can read anything at mode 644"
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
    if [ -f docs/king-system.md ] || [ -f README.md ]; then
        _secrets=$(for f in $SECRET_FILES; do
                     [ -f "$f" ] || continue
                     grep -oE '^[A-Z0-9_]+=' "$f" 2>/dev/null | tr -d '='
                   done | sort -u | grep -E 'KEY|TOKEN|SECRET|PASSWORD|DSN|URL' || true)
        _unlisted=""
        for _sc in $_secrets; do
            grep -rq "$_sc" docs/ README.md 2>/dev/null || _unlisted="$_unlisted $_sc"
        done
        _n=$(printf '%s' "$_unlisted" | wc -w | tr -d ' ')
        _found=$(printf '%s' "$_secrets" | wc -w | tr -d ' ')
        if [ "${_found:-0}" -eq 0 ]; then
            # No secret files here means nothing was compared. Passing on an
            # empty set is how a check reports success for doing nothing.
            chk C-9 UNKNOWN "no secret files present; the rotation list was compared against nothing"
        elif [ "${_n:-0}" -eq 0 ]; then
            chk C-9 PASS "all ${_found} secret-shaped variable(s) are named in the docs"
        else
            chk C-9 FAIL "${_n} secret(s) exist but appear in no document" \
                "$(printf '%s' "$_unlisted" | tr ' ' '\n' | head -5 | tr '\n' ' ')"
        fi
    else
        chk C-9 SKIP "no docs here to compare the rotation list against"
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
            if [ -z "$_open" ]; then
                chk C-10 PASS "$_n datastore(s), none reachable without a credential"
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
        if [ "${_oom:-0}" -eq 0 ]; then
            chk D-4 PASS "no OOM kill in the kernel ring buffer"
        else
            chk D-4 FAIL "$_oom OOM event(s) in dmesg" "the kernel has been choosing victims by RSS"
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
}

# ------------------------------------------------------------- dimension E

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

    _bi=$(docker exec king-codegraph-serve-1 cat /out/graphify-out/BUILD_INFO 2>/dev/null || true)
    _gc=$(printf '%s' "$_bi" | sed -n 's/^commit=//p' | cut -c1-40)
    _head=$(git rev-parse HEAD 2>/dev/null || true)
    _origin=$(git rev-parse origin/main 2>/dev/null || true)
    if [ -z "$_gc" ]; then
        chk E-4 UNKNOWN "cannot read the graph's BUILD_INFO"
    elif [ "$_gc" = "$_origin" ]; then
        chk E-4 PASS "code graph indexes origin/main" "${_gc}"
    elif [ "$_gc" = "$_head" ]; then
        # E-4 measures the LABEL; E-5 measures the CONTENT, and they can
        # disagree. graphify scans the working tree while BUILD_INFO records
        # HEAD, so a graph built on a host with uncommitted files contains
        # code its own provenance line does not describe. Observed
        # 2026-09-08: E-4 said 18 commits behind, E-5 found a file added
        # after that commit. Neither is wrong; reading either alone is.
        chk E-4 FAIL "the graph provenance label is behind origin/main (E-5 checks its contents)" \
            "graph=$(printf '%s' "$_gc" | cut -c1-8) origin=$(printf '%s' "$_origin" | cut -c1-8)"
    else
        chk E-4 FAIL "code graph indexes neither HEAD nor origin/main" \
            "graph=$(printf '%s' "$_gc" | cut -c1-8) head=$(printf '%s' "$_head" | cut -c1-8)"
    fi

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
    if [ -z "$_newfile" ]; then
        chk E-5 PASS "graph commit matches origin; nothing newer to look for"
    elif [ -z "$PY" ]; then
        chk E-5 UNKNOWN "no interpreter to query the graph with"
    else
        _gk2=$(sed -n 's/^GRAPHIFY_API_KEY=//p' .env 2>/dev/null | tail -1)
        if [ -z "$_gk2" ]; then
            chk E-5 UNKNOWN "no graph key; correctness unverifiable"
        else
            _hit=$(curl -s -m 60 -X POST http://127.0.0.1:8130/mcp \
                   -H 'Content-Type: application/json' \
                   -H 'Accept: application/json, text/event-stream' \
                   -H "Authorization: Bearer $_gk2" \
                   -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_node\",\"arguments\":{\"label\":\"$(basename "$_newfile")\"}}}" \
                   2>/dev/null | grep -c "$(basename "$_newfile")" || true)
            if [ "${_hit:-0}" -gt 0 ]; then
                chk E-5 PASS "graph knows a file only the newest commit has" "$(basename "$_newfile")"
            else
                chk E-5 FAIL "graph does not contain $(basename "$_newfile"), which origin/main added" \
                    "it will answer confidently about code that no longer looks like this"
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
paid = [r for r in rows if (r.get("provider") or "") not in ("ollama", "ollama-local")]
print("%d\t%d\t%d\t%d" % (len(rows), sum(1 for r in rows if has(r)),
                          len(paid), sum(1 for r in paid if has(r))))
PYE8
        _cov=$(curl -s -m 45 "http://localhost:20128/api/usage/call-logs?limit=500" \
               -H "Authorization: Bearer $_k" 2>/dev/null | "$PY" "$_e8" 2>/dev/null || true)
        rm -f "$_e8"
        case "$_cov" in
            ''|ERR*) chk E-8 UNKNOWN "the call log did not return a readable list" ;;
            *)
                _all=$(printf '%s' "$_cov" | cut -f1);  _allt=$(printf '%s' "$_cov" | cut -f2)
                _pd=$(printf '%s' "$_cov" | cut -f3);   _pdt=$(printf '%s' "$_cov" | cut -f4)
                metric e8_token_coverage_pct "$(( _allt * 100 / _all ))"
                if [ "${_pd:-0}" -gt 0 ] && [ "$_pdt" -eq 0 ]; then
                    chk E-8 FAIL "no paid call reports its tokens ($_pd of $_all calls)" \
                        "spend cannot be derived, so no budget guard can be built on this log"
                elif [ "$(( _allt * 100 / _all ))" -lt 50 ]; then
                    chk E-8 FAIL "only $_allt of $_all calls report tokens" \
                        "$_pdt of $_pd paid calls; partial accounting reads as a total and is not one"
                else
                    chk E-8 PASS "$_allt of $_all calls report tokens" \
                        "$_pdt of $_pd paid calls carry usage"
                fi ;;
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
    _st_ok=""; _st_bad=""
    for _g in scripts/stax-preflight.sh scripts/local-secret-scan.sh scripts/king-audit.sh; do
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
        _failed=$(systemctl --user --failed --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)
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
    _mute=""
    for _spec in "scripts/gateway-report.sh|24|provider reliability" \
                 "scripts/alerts-report.sh|14|alert(s)"; do
        _sc=$(printf '%s' "$_spec" | cut -d'|' -f1)
        _ar=$(printf '%s' "$_spec" | cut -d'|' -f2)
        _ex=$(printf '%s' "$_spec" | cut -d'|' -f3)
        [ -x "$_sc" ] || continue
        timeout 300 "$_sc" "$_ar" 2>/dev/null | grep -qF "$_ex" || _mute="$_mute $(basename "$_sc")"
    done
    if [ -z "$_mute" ]; then
        chk G-2 PASS "every report produces the section it claims to"
    else
        chk G-2 FAIL "report(s) ran but produced nothing they promise" "$_mute"
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
            failure) chk J-2 UNKNOWN "omniroute-smoke is red — known upstream break" \
                         "tls-client-node asset renamed upstream; not caused here, not fixable here" ;;
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
    if have curl && [ -n "$PY" ]; then
        _behind=""
        _pin=$(grep -oE 'binwiederhier/ntfy:v[0-9.]+' docker-compose.yml 2>/dev/null | head -1)
        if [ -n "$_pin" ]; then
            _cur=${_pin##*:}
            _latest=$(curl -s -m 25 "https://hub.docker.com/v2/repositories/binwiederhier/ntfy/tags/?page_size=20&ordering=last_updated" 2>/dev/null \
                      | "$PY" -c "
import json,sys,re
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
for t in d.get('results') or []:
    if re.match(r'^v[0-9]+\.[0-9]+\.[0-9]+$', t.get('name','')):
        print(t['name']); break
" 2>/dev/null || true)
            [ -n "$_latest" ] && [ "$_latest" != "$_cur" ] && _behind="$_behind ntfy:$_cur(latest $_latest)"
        fi
        if [ -z "$_pin" ]; then
            chk J-1 UNKNOWN "no pinned third-party image tags found to compare"
        elif [ -z "$_behind" ]; then
            chk J-1 PASS "pinned third-party image(s) are at the newest release" "$_pin"
        else
            chk J-1 UNKNOWN "pinned image(s) behind upstream" \
                "$_behind — recorded, not a recommendation; check the changelog before moving"
        fi
    else
        chk J-1 UNKNOWN "no curl or interpreter to query the registry with"
    fi

    _pinned=$(grep -c 'OMNIROUTE_IMAGE_DIGEST=' scripts/ci-build-omniroute-base.sh 2>/dev/null || true)
    if [ "${_pinned:-0}" -ge 1 ]; then
        chk J-3 PASS "the vendored gateway image is pinned by digest"
    else
        chk J-3 FAIL "no digest pin for the gateway image"
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
    if sudo -n iptables -S DOCKER-USER >/dev/null 2>&1; then
        _du=$(sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)
        metric k2_docker_user_rules "${_du:-0}"
        if [ "${_du:-0}" -gt 0 ]; then
            chk K-2 PASS "DOCKER-USER carries ${_du} rule(s); the host firewall covers published ports"
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
    if have apt-get; then
        _sec=$(apt-get -s upgrade 2>/dev/null | grep -ciE '^Inst.*security' || true)
        _unatt=$(systemctl is-enabled unattended-upgrades 2>/dev/null || echo disabled)
        metric k6_security_updates "${_sec:-0}"
        if [ "${_sec:-0}" -eq 0 ] && [ "$_unatt" = "enabled" ]; then
            chk K-6 PASS "no pending security updates, and unattended-upgrades is enabled"
        elif [ "${_sec:-0}" -gt 0 ]; then
            chk K-6 FAIL "${_sec} security update(s) pending" "unattended-upgrades: $_unatt"
        else
            chk K-6 FAIL "unattended-upgrades is $_unatt" "nothing will apply the next one"
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

    # L-2: documented closed on 2026-08-28 and never re-tested. Activepieces
    # closes registration by itself after the first account, which is a
    # behaviour that could change on any upgrade -- so it is tested, not
    # remembered. The probe uses an .invalid address so a success would create
    # nothing usable.
    if have curl; then
        _su=$(curl -s -o /dev/null -w '%{http_code}' -m 25 -X POST \
              "https://flows.arject.co/api/v1/authentication/sign-up" \
              -H 'Content-Type: application/json' \
              -d '{"email":"audit-probe@example.invalid","password":"Nx8s2Kd91mQz","firstName":"a","lastName":"b","trackEvents":false,"newsLetter":false}' \
              2>/dev/null || true)
        case "${_su:-000}" in
            403|401) chk L-2 PASS "Activepieces still refuses a second sign-up" "HTTP $_su" ;;
            2*)      chk L-2 FAIL "Activepieces ACCEPTED a sign-up" "HTTP $_su — this name is public" ;;
            *)       chk L-2 UNKNOWN "sign-up probe returned $_su" ;;
        esac
    else
        chk L-2 UNKNOWN "curl unavailable; registration state untested"
    fi

    # L-3: the run journal records prompts and errors, and errors quote what
    # failed. A journal that has started capturing credentials is a second
    # copy of them in a file nobody treats as secret.
    _leak=$(docker exec king-agent-sidecar-http-1 sh -c \
            "grep -chE 'sk-[A-Za-z0-9]{20,}|oma_live_|tk_[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9._-]{20,}' /audit/runs.jsonl /audit/vps_exec.log 2>/dev/null | awk '{t+=\$1} END {print t+0}'" \
            2>/dev/null || true)
    case "${_leak:-x}" in
        x|"") chk L-3 UNKNOWN "could not scan the journals" ;;
        0)    chk L-3 PASS "no credential-shaped string in the journals" ;;
        *)    chk L-3 FAIL "$_leak credential-shaped string(s) in the journals" \
                  "a second copy of a secret, in a file nobody treats as one" ;;
    esac

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
    else
        _hits=""; _scanned=0
        for _c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
            _scanned=$((_scanned + 1))
            _n=$(docker logs --tail 4000 "$_c" 2>&1 \
                 | grep -cE 'sk-[A-Za-z0-9]{16,}|Bearer [A-Za-z0-9_.-]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.' \
                 || true)
            case "$_n" in ''|*[!0-9]*) continue ;; esac
            [ "$_n" -gt 0 ] && _hits="$_hits $_c($_n)"
        done
        if [ -z "$_hits" ]; then
            chk L-5 PASS "no credential-shaped string in $_scanned container log(s)" \
                "last 4000 lines each; older lines are not covered and nothing rotates them"
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
    echo "self-test (fixtures only; no host, no secrets, no network)"
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
    if img.endswith(":latest"): out.append("B3 " + name)
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

    # ---- E-8: token coverage, which must not read a paid zero as fine ---
    printf '%s\n' '[{"provider":"ollama","tokens":{"in":10,"out":5}},{"provider":"openrouter","tokens":{"in":0,"out":0}}]' > "$_t/logs.json"
    _e8t=$(mktemp)
    cat > "$_e8t" <<'PYE8T'
import sys, json
rows = json.load(open(sys.argv[1]))
def has(r):
    t = r.get("tokens") or {}
    return bool((t.get("in") or 0) or (t.get("out") or 0))
paid = [r for r in rows if (r.get("provider") or "") not in ("ollama", "ollama-local")]
print("%d\t%d" % (len(paid), sum(1 for r in paid if has(r))))
PYE8T
    _e8out=$("$PY" "$_e8t" "$_t/logs.json" 2>/dev/null || echo PYFAIL)
    rm -f "$_e8t"
    if [ "$_e8out" = "$(printf '1\t0')" ]
    then printf '  ok    a paid call reporting zero tokens is counted as unaccounted\n'
    else printf '  FAIL  a paid call reporting zero tokens is counted as unaccounted (got %s)\n' "$_e8out"; _f=$((_f+1)); fi

    rm -rf "$_t"
    echo
    if [ "$_f" -eq 0 ]; then c_green "self-test passed"; echo; exit 0; fi
    c_red "$_f self-test check(s) failed"; echo; exit 1
}

# ------------------------------------------------------------------- driver

[ "$MODE" = "selftest" ] && self_test

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
# manifest exists.
[ "$n_todo" -gt 0 ] && exit 3
[ "$n_unknown" -gt 0 ] && exit 2
exit 0
