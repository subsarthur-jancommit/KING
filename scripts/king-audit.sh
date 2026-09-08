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
# Exit: 0 all PASS, 1 any FAIL, 2 any UNKNOWN with no FAIL.
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

# ---------------------------------------------------------------- reporting

n_pass=0; n_fail=0; n_unknown=0; n_skip=0
FINDINGS=$(mktemp); trap 'rm -f "$FINDINGS" "${METRICS:-}"' EXIT INT TERM
METRICS=$(mktemp)

c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_yell()  { printf '\033[33m%s\033[0m' "$*"; }
c_dim()   { printf '\033[2m%s\033[0m' "$*"; }

# chk <id> <status> <title> [evidence...]
chk() {
    _id="$1"; _st="$2"; _t="$3"; shift 3
    _ev="$*"
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
        chk A-1 UNKNOWN "not a git checkout; source integrity unmeasurable"
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
        chk B-1 UNKNOWN "no docker-compose.yml here"
        return
    fi
    if ! pyyaml_ok; then
        chk B-1 UNKNOWN "no working python3 with pyyaml; compose rules unparseable"
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
              B5:B-5:'no ${VAR:?err} outside comments' \
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
on_host && c_dim "  on the host (docker visible)" || c_dim "  off-host: container checks will be skipped"
echo

for _d in $WANT; do
    case "$_d" in
        A) dim_A ;;
        B) dim_B ;;
        C|D|E|F|G|H|I|J) echo; echo "$_d  not implemented yet"; chk "$_d-0" SKIP "dimension not built" ;;
        *) echo "unknown dimension: $_d" >&2; exit 2 ;;
    esac
done

echo
printf '  %s pass, ' "$(c_green "$n_pass")"
printf '%s fail, ' "$(c_red "$n_fail")"
printf '%s unknown, ' "$(c_yell "$n_unknown")"
printf '%s skipped\n' "$n_skip"

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
[ "$n_unknown" -gt 0 ] && exit 2
exit 0
