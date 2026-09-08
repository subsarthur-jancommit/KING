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

DIMENSIONS="A B C D E F G H I J"
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
C-1
C-2
C-3
C-4
C-5
C-6
C-7
C-8
C-9
D-1
D-2
D-3
D-4
D-5
D-6
E-1
E-2
E-3
E-4
E-5
E-6
F-1
F-2
F-3
F-4
F-5
F-6
F-7
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
IMPL
}

manifest() {
    cat <<'MANIFEST'
A-1|repo vs origin/main: commit, ahead/behind
A-2|modified and untracked files on the host
A-3|file modes (executable bit) in git
A-4|omniroute/ subtree unmodified
A-5|running image tags vs what compose pins
A-6|local worktree vs origin
A-7|leftover .orig/.rej merge artefacts
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
C-1|every secret file and its backup variants are gitignored
C-2|no secret in git history
C-3|no placeholder value still installed
C-4|token to blast-radius map
C-5|public surface inventory: every reachable path and its anonymous status
C-6|every MCP: no token 401, wrong token 401, right token 200
C-7|secret file permissions are not world-readable
C-8|the agent egress allowlist is actually in force
C-9|the rotation list matches the secrets that exist
D-1|per container: memory, swap, restarts
D-2|healthcheck status
D-3|host memory against the codegraph floor, as the build will see it
D-4|OOM events in the kernel ring buffer
D-5|log sizes and rotation
D-6|reclaimable build cache, idle images, orphan volumes
E-1|every volume: size, contents, and whether anything backs it up
E-2|external Postgres reachable, and its size
E-3|journals exist, grow, and are readable
E-4|code graph freshness: BUILD_INFO commit vs HEAD vs origin
E-5|code graph correctness: it finds a file only the newest commit has
E-6|no test rows left in production tables
F-1|every MCP server: tools/list and one real call
F-2|offered tools vs allowlist vs NEVER_REGISTER
F-3|reroute status: the eight measured trigger phrases
F-4|model_overridden in the recent run journal
F-5|per-provider failure rate, and what reached the caller
F-6|the local model answers, and answers from this host
F-7|flow mirror matches the live Activepieces step
G-1|every guard with a self-test still passes it
G-2|every instrument measures what it claims
G-3|timers: last run, and whether any unit failed
G-4|deadman tolerance vs the worst legitimate gap
G-5|an alert reaches the phone, end to end
G-6|inventory of silenced-failure constructs in scripts/
H-1|CI jobs: green or red, and why
H-2|what CI does not cover
H-3|the test suite passes in a rebuilt container
H-4|environment-dependent tests
I-1|measured numbers in the docs vs today's measurement
I-2|commands in the docs actually run
I-3|cross-referenced file paths still exist
I-4|CLAUDE.md vs actual behaviour
J-1|pinned versions vs latest, and known CVEs
J-2|active upstream breakage
J-3|image age, origin, and whether it is still published
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
        _mismatch=""
        for svc in omniroute king-activepieces-1 king-ollama-1 king-caddy-1; do
            _img=$(docker inspect "$svc" --format '{{.Config.Image}}' 2>/dev/null || true)
            case "$_img" in
                *:latest) _mismatch="$_mismatch $svc=$_img" ;;
            esac
        done
        if [ -z "$_mismatch" ]; then
            chk A-5 PASS "no running container is on a :latest tag"
        else
            chk A-5 FAIL "container(s) running :latest — not reproducible" "$_mismatch"
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
        _envblank=$(docker exec -e OMNIROUTE_PUBLIC_DOMAIN= -e ACTIVEPIECES_PUBLIC_DOMAIN= \
            king-caddy-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 || true)
        if printf '%s' "$_envblank" | grep -q "Valid configuration"; then
            chk B-7b PASS "caddy still loads with every domain variable empty"
        else
            chk B-7b FAIL "empty domain variable breaks the whole config" \
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
comp = io.open("docker-compose.yml", encoding="utf-8").read()
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
    _units=$(find scripts -maxdepth 1 -name '*.timer' 2>/dev/null | wc -l | tr -d ' ')
    if have systemctl; then
        _live=$(systemctl --user list-timers --no-legend 2>/dev/null | awk '{print $NF}' \
                | sed 's/\.service$//' | grep -v '^$' | sort -u || true)
        _unversioned=""
        for _t in $_live; do
            case "$_t" in
                launchpadlib*|systemd-*) continue ;;
            esac
            [ -f "scripts/$_t.timer" ] || _unversioned="$_unversioned $_t"
        done
        if [ -z "$_unversioned" ]; then
            chk B-10 PASS "every active user timer has its unit in the repo" "$_units in scripts/"
        else
            chk B-10 FAIL "active timer(s) with no unit file in the repo" "$_unversioned"
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
    if [ -z "$_leaky" ]; then
        chk C-1 PASS "every secret file and its backup variants are gitignored"
    else
        chk C-1 FAIL "secret path(s) not ignored — one \`git add -A\` from a commit" \
            "$(printf '%s' "$_leaky" | tr ' ' '\n' | grep -v '^$' | head -4 | tr '\n' ' ')"
    fi

    # Untracked AND unignored files that look secret-bearing. This is the check
    # that would have caught providers.env.bak.20260906 the day it appeared.
    _stray=$(git status --porcelain --untracked-files=all 2>/dev/null \
             | awk '/^\?\?/ {print $2}' \
             | grep -iE '(^|/)\.env|secret|token|credential|\.bak(\.|$)|\.pem$|\.key$' || true)
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
        if [ "$_sock" = "true" ] && [ -n "$_exec" ]; then
            chk C-4 FAIL "AGENT_SIDECAR_AUTH_TOKEN is a ROOT credential, not a service token" \
                "docker.sock mounted rw + EXEC_ENABLED=$_exec: vps_exec can run --privileged -v /:/host"
        elif [ "$_sock" = "true" ]; then
            chk C-4 FAIL "sidecar holds a writable docker.sock (root-equivalent if exec is enabled)"
        else
            chk C-4 PASS "sidecar has no writable docker socket"
        fi
    else
        chk C-4 SKIP "not on the host; blast radius unmeasurable"
    fi

    # C-5/C-6: the public surface, and whether each door is actually locked.
    # Tested in BOTH directions — a 200 with no token is an open door, and a
    # 401 with the right token is a door nobody can use.
    if have curl; then
        _open=""
        for path in /king-agent/mcp /king-codegraph/mcp; do
            _code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
                    "https://gateway.arject.co$path" 2>/dev/null || echo 000)
            case "$_code" in
                401|403) : ;;
                000)     _open="$_open $path=unreachable" ;;
                *)       _open="$_open $path=$_code" ;;
            esac
        done
        if [ -z "$_open" ]; then
            chk C-5 PASS "every authenticated public path rejects an anonymous request"
        else
            chk C-5 FAIL "public path(s) answered without a token" "$_open"
        fi
    else
        chk C-5 UNKNOWN "curl unavailable; public surface unmeasurable"
    fi

    if [ -f agent-sidecar/.env ]; then
        _perm=$(stat -c '%a' agent-sidecar/.env 2>/dev/null || stat -f '%A' agent-sidecar/.env 2>/dev/null || true)
        case "$_perm" in
            ""|*[!0-9]*) chk C-7 UNKNOWN "could not read .env permissions" ;;
            *[2367])     chk C-7 FAIL "agent-sidecar/.env is world-readable" "mode $_perm" ;;
            *)           chk C-7 PASS "secret file permissions are not world-readable" "mode $_perm" ;;
        esac
    else
        chk C-7 SKIP "no agent-sidecar/.env here"
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
    if [ ! -f agent-sidecar/.env ]; then
        chk C-8 UNKNOWN "no agent-sidecar/.env here; egress allowlist unmeasurable"
    elif grep -qE '^AGENT_SIDECAR_MCP_ALLOWED_HOSTS=.+' agent-sidecar/.env 2>/dev/null; then
        chk C-8 PASS "agent MCP egress allowlist is set"
    else
        chk C-8 FAIL "no egress allowlist set for the agent's MCP hosts" \
            "the agent reads web pages; this is the boundary that bounds it"
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
                v=$(cat "$b/memory.swap.current" 2>/dev/null || echo 0)
                [ "$v" -gt 52428800 ] && printf '%s=%sMB ' "$c" "$((v/1048576))"
                break
            done
          done; true)
    metric d1_swapping "$(printf '%s' "$_sw" | wc -w | tr -d ' ')"
    if [ -z "$_sw" ]; then
        chk D-1 PASS "no container holds more than 50 MB of swap"
    else
        chk D-1 FAIL "container(s) swapping" "$_sw"
    fi

    _unhealthy=$(docker ps --format '{{.Names}} {{.Status}}' | grep -i 'unhealthy' || true)
    _restarts=$(for c in $(docker ps --format '{{.Names}}'); do
                  r=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)
                  [ "$r" -gt 3 ] && printf '%s=%s ' "$c" "$r"
                done; true)
    if [ -z "$_unhealthy" ] && [ -z "$_restarts" ]; then
        chk D-2 PASS "no unhealthy container, none restarting repeatedly"
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
    if _dm=$(dmesg 2>/dev/null); then
        _oom=$(printf '%s' "$_dm" | grep -ci 'out of memory\|oom-kill' || true)
        if [ "${_oom:-0}" -eq 0 ]; then
            chk D-4 PASS "no OOM kill in the kernel ring buffer"
        else
            chk D-4 FAIL "$_oom OOM event(s) in dmesg" "the kernel has been choosing victims by RSS"
        fi
    else
        chk D-4 UNKNOWN "dmesg unreadable (needs privileges); OOM history unknown"
    fi

    _pct=$(df / --output=pcent 2>/dev/null | tr -dc '0-9' || true)
    if [ -n "$_pct" ]; then
        metric d5_disk_pct "$_pct"
        if [ "$_pct" -lt 85 ]; then chk D-5 PASS "root filesystem ${_pct}% used"
        else chk D-5 FAIL "root filesystem ${_pct}% used" "reclaim before adding anything"; fi
    else
        chk D-5 UNKNOWN "cannot read disk usage"
    fi

    _recl=$(docker system df 2>/dev/null | awk '/Build Cache/ {print $NF}' | tr -dc '0-9.' || true)
    [ -n "$_recl" ] && metric d6_reclaimable_gb "$_recl"
    chk D-6 PASS "reclaimable build cache recorded" "${_recl:-unknown} (informational)"
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
    chk E-1 UNKNOWN "$_vols docker volume(s); no backup mechanism exists to verify" \
        "loss would be silent until needed — this is a decision, not a check"

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
    if have curl && [ -f .env ]; then
        chk E-6 UNKNOWN "alert table rows need the Activepieces API; check with ./scripts/alerts-report.sh" \
            "look for rows whose detail names a probe model such as hy3-free"
    else
        chk E-6 SKIP "cannot reach the alert table from here"
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

    # F-7: mirror vs live. A mirror that has drifted invites review of code
    # that is not running.
    if [ -f flows/gateway_monitor.step_1.js ]; then
        _mir=$(sed -n '/^import crypto/,$p' flows/gateway_monitor.step_1.js | wc -c | tr -d ' ')
        metric f7_mirror_bytes "$_mir"
        chk F-7 UNKNOWN "flow mirror is $_mir bytes; comparing to live needs the Activepieces API" \
            "run ap_read_step_code and diff below the header — not automatable from here"
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
    _sil=$(grep -c -- '|| true\|2>/dev/null\||| echo' scripts/*.sh 2>/dev/null | awk -F: '{t+=$2} END {print t+0}')
    metric g6_silenced "$_sil"
    chk G-6 UNKNOWN "$_sil silenced-failure construct(s) across scripts/" \
        "each is legitimate or a swallowed error; reviewable with: grep -n '|| true' scripts/*.sh"
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
    if [ -d agent-sidecar/tests ]; then
        _envdep=$(grep -rln 'os\.environ' agent-sidecar/tests 2>/dev/null \
                  | while read -r _f; do
                      grep -q 'monkeypatch\|conftest' "$_f" || printf '%s ' "$(basename "$_f")"
                    done)
        if [ -z "$_envdep" ]; then
            chk H-4 PASS "no test reads the environment without pinning it"
        else
            chk H-4 FAIL "test file(s) read os.environ without monkeypatch" "$_envdep"
        fi
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

    # I-1: numbers in prose rot silently. These are the load-bearing ones --
    # each is cited somewhere as a reason for a decision -- checked against
    # what the system says today rather than against memory.
    _wrong=""
    _floor=$(sed -n 's/.*CODEGRAPH_MIN_AVAIL_MB:-\([0-9]*\)}.*/\1/p' scripts/codegraph-refresh.sh 2>/dev/null | head -1)
    [ -n "$_floor" ] && ! grep -q "$_floor" docs/king-system.md 2>/dev/null && _wrong="$_wrong codegraph-floor=$_floor"
    _ntools=$(grep -c '^    "' agent-sidecar/src/agent_sidecar/config.py 2>/dev/null || true)
    if [ -f docs/king-system.md ] && [ -n "$_wrong" ]; then
        chk I-1 FAIL "measured value(s) in the code appear nowhere in the docs" "$_wrong"
    elif [ -f docs/king-system.md ]; then
        chk I-1 PASS "the load-bearing measured values still appear in the docs" "codegraph floor ${_floor:-?} MB"
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

    _stale=$(grep -l 'TODO\|FIXME\|XXX' docs/*.md 2>/dev/null | tr '\n' ' ' || true)
    if [ -z "$_stale" ]; then
        chk I-4 PASS "no TODO/FIXME left in the docs"
    else
        chk I-4 UNKNOWN "docs carrying TODO markers" "$_stale"
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
    # has drifted is the number that matters. Recorded rather than judged --
    # "newer exists" is not automatically "upgrade".
    _age=""
    for _sp in "binwiederhier/ntfy|$(grep -oE 'binwiederhier/ntfy:v[0-9.]+' docker-compose.yml 2>/dev/null | head -1)" \
               "postgres|$(grep -oE 'postgres:[0-9]+-alpine' docker-compose.yml 2>/dev/null | head -1)"; do
        _im=$(printf '%s' "$_sp" | cut -d'|' -f2)
        [ -n "$_im" ] && _age="$_age $_im"
    done
    if [ -n "$_age" ]; then
        chk J-1 UNKNOWN "pinned image(s) recorded; comparing to upstream needs a registry call" "$_age"
    else
        chk J-1 UNKNOWN "no pinned third-party image tags found to compare"
    fi

    _pinned=$(grep -c 'OMNIROUTE_IMAGE_DIGEST=' scripts/ci-build-omniroute-base.sh 2>/dev/null || true)
    if [ "${_pinned:-0}" -ge 1 ]; then
        chk J-3 PASS "the vendored gateway image is pinned by digest"
    else
        chk J-3 FAIL "no digest pin for the gateway image"
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
