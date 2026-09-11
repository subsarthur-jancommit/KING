#!/usr/bin/env bash
#
# king-maintenance.sh — the two jobs that need a window, run safely.
#
#   --plan          what would happen, and whether this host can do it. Changes nothing.
#   --rebuild       rebuild the gateway image (closes J-4 / CVE-2025-68121)
#   --os-updates    apply pending security updates, then report if a reboot is needed
#   --all           --rebuild then --os-updates
#
# WHY A SCRIPT AND NOT A CHECKLIST.
#
# The rebuild failed five times on 2026-09-10 and the first attempt took the
# host down for 45 minutes. Everything that made attempts 2-5 safe instead of
# catastrophic is mechanical and easy to forget at 1am:
#
#   * Build inside a `docker-container` buildx driver, never bare. A bare
#     `docker build` runs in the daemon, outside every cgroup, and nothing
#     bounds it — that is mistakes entry 1 and entry 30, the same fault twice.
#     buildkitd in a container is just a container, so `docker update --memory`
#     caps it and a runaway build dies alone.
#   * Watch the gateway from OUTSIDE the build and abort on real symptoms.
#   * Free the memory first. The build needs ~4.6 GB; this host has ~4.4 GB
#     free while serving ten containers, which is why every bounded attempt
#     OOMed. It stops activepieces, codegraph-serve and ollama BY CONTAINER ID
#     -- `docker compose stop activepieces` fails with "no such service:
#     omniroute-base", because its depends_on points into the profile-gated
#     vendored compose, and a stop that fails is memory the build never gets.
#   * Verify the new image BEFORE touching the running one.
#
# If anything fails, the trap restarts whatever this stopped. A failed rebuild
# must not leave the workflow engine down.
#
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1

GW_URL="http://127.0.0.1:20128/api/monitoring/health"
BUILDER="king-maint"
FREE_SERVICES="activepieces codegraph-serve ollama"   # stopped to make room, restarted after
CAGE_MB="${KING_BUILD_CAGE_MB:-4608}"
# V8 heap ceiling, deliberately well BELOW the cage. Attempt 2 on 2026-09-10
# set a 4096 MB heap inside a 2560 MB cage: V8 grew toward a limit the cgroup
# could not honour and the kernel killed it. Turbopack then compiles in native
# Rust memory OUTSIDE this heap (omniroute/Dockerfile:131), so the cage must
# hold heap + native + node. 2048 leaves ~2.5 GB of a 4608 MB cage for the part
# no flag can bound -- the part that killed attempts 2, 3 and 4.
HEAP_MB="${KING_BUILD_HEAP_MB:-2048}"
FLOOR_MB=400                                    # host MemAvailable abort floor
TLS_WANT=2ec853496634545e7a7ea028715763948d55bbdd97aca7ecaa9fea8c2ebb08df

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yell()  { printf '\033[33m%s\033[0m\n' "$*"; }
step()    { printf '\n\033[1m== %s\033[0m\n' "$*"; }

priv() { if sudo -n true 2>/dev/null; then sudo -n "$@"; else "$@"; fi; }
mem_avail() { awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo; }
gw_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$GW_URL" 2>/dev/null || echo 000; }

# Resolve a compose service to its running container id BY LABEL.
#
# `docker compose stop activepieces` does not work here and the reason is not
# obvious: activepieces declares `depends_on: [omniroute-base, ap-redis]`, and
# omniroute-base lives in the INCLUDED vendored compose behind the `base`
# profile. Without the right --profile flags Compose cannot resolve that
# dependency and fails the whole command with "no such service: omniroute-base"
# — so the stop silently did nothing, the memory was never freed, and the
# build refused to start for lack of room that was actually available.
# codegraph-serve has no depends_on, which is the only reason it worked and the
# only reason this looked like it was working at all.
#
# The label is what Compose itself stamps on the container, so this needs no
# profile knowledge and cannot drift when profiles change.
svc_cid() { docker ps -q --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -1; }

# What stopping that container would actually release, measured now.
svc_mb() {
    _c=$(svc_cid "$1")
    [ -n "$_c" ] || { printf '0'; return; }
    docker stats --no-stream --format '{{.MemUsage}}' "$_c" 2>/dev/null \
        | cut -d/ -f1 | awk '/GiB/{printf "%d", $1*1024} /MiB/{printf "%d", $1} /KiB/{printf "0"}'
}

STOPPED=""          # container ids, not service names — see svc_cid
restore_services() {
    [ -n "$STOPPED" ] || return 0
    printf '  restarting what this stopped:'
    for _c in $STOPPED; do
        printf ' %s' "$(docker inspect -f '{{.Name}}' "$_c" 2>/dev/null | tr -d /)"
        docker start "$_c" >/dev/null 2>&1
    done
    printf '\n'
    STOPPED=""
}
cleanup() {
    _rc=$?
    [ -n "${WATCHDOG_PID:-}" ] && kill "$WATCHDOG_PID" 2>/dev/null
    restore_services
    exit "$_rc"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------- plan
do_plan() {
    step "Can this host do the rebuild right now?"
    _now=$(mem_avail)
    _free=0
    for s in $FREE_SERVICES; do
        _c=$(svc_cid "$s")
        if [ -z "$_c" ]; then
            printf '  %-24s not running — nothing to free\n' "$s"
            continue
        fi
        _mb=$(svc_mb "$s")
        printf '  %-24s %s MB  (%s)\n' "$s" "${_mb:-0}" \
            "$(docker inspect -f '{{.Name}}' "$_c" 2>/dev/null | tr -d /)"
        _free=$((_free + ${_mb:-0}))
    done
    _after=$((_now + _free))
    printf '\n  MemAvailable now            %s MB\n' "$_now"
    printf '  released by stopping those  %s MB\n' "$_free"
    printf '  available to the build      %s MB\n' "$_after"
    # These are a snapshot. Ollama in particular evicts an idle model on its
    # own, so a number measured while one was loaded can be 1.3 GB stale by
    # the time --rebuild runs. Step 2 re-measures after stopping and refuses
    # on the real figure rather than this one.
    printf '  %s\n' "(snapshot — --rebuild re-measures after stopping and refuses on the real number)"
    printf '  cage this script would set  %s MB   (V8 heap %s MB)\n' "$CAGE_MB" "$HEAP_MB"
    if [ "$_after" -gt $((CAGE_MB + FLOOR_MB)) ]; then
        c_green "  OK — that leaves $((_after - CAGE_MB)) MB for the host, above the ${FLOOR_MB} MB floor."
    else
        c_red "  TIGHT — only $((_after - CAGE_MB)) MB would remain for the host."
        printf '  Lower the cage with KING_BUILD_CAGE_MB, or stop something else too.\n'
    fi
    printf '\n  disk: %s\n' "$(df -h / | tail -1 | awk '{print $4" free ("$5" used)"}')"
    printf '  gateway right now: HTTP %s\n' "$(gw_code)"

    step "Pending security updates"
    # NOT `|| echo 0`. That substitutes a plausible answer for a failure, and
    # it is the exact defect K-6 carried until 2026-09-10: apt with missing
    # lists exits ZERO and prints a tidy "0 upgraded", so neither the exit
    # status nor the count distinguishes "nothing pending" from "nothing to
    # read". G-6 caught this line the first time the audit ran over this file.
    #
    # `indextargets` lists the index files apt will actually read: 62 on this
    # host, 0 when the lists are gone. $(FILENAME) is apt's own format
    # template, not a shell expansion, so the single quotes are the point.
    # shellcheck disable=SC2016
    _idx=$(apt-get indextargets --format '$(FILENAME)' 2>/dev/null | grep -c . || true)
    _sec_out=$(priv sh -c 'apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null')
    _sec_rc=$?
    if [ "$_sec_rc" -ne 0 ] || [ -z "$_sec_out" ]; then
        c_yell "  apt could not answer (exit $_sec_rc) — that is not the same as zero"
    elif [ "${_idx:-0}" -eq 0 ]; then
        c_yell "  apt has no package indexes, so its answer means nothing — run: sudo apt-get update"
    else
        _sec=$(printf '%s\n' "$_sec_out" | grep -ci '^Inst.*security' || true)
        printf '  %s security update(s) pending (from %s index files)\n' "${_sec:-0}" "$_idx"
    fi
    printf '\n  Nothing above changed anything. Run --rebuild or --os-updates to act.\n\n'
}

# ---------------------------------------------------------------- rebuild
do_rebuild() {
    step "0. Restore point"
    if [ -x ./scripts/king-backup.sh ]; then
        ./scripts/king-backup.sh 2>&1 | tail -3 | sed 's/^/  /'
    else
        c_yell "  king-backup.sh not executable — continuing without a fresh restore point"
    fi

    step "1. Tag a rollback for the image that is running now"
    _stamp=$(date +%Y%m%d-%H%M)
    docker tag omniroute:base "omniroute:rollback-$_stamp" || { c_red "  could not tag"; return 1; }
    printf '  omniroute:rollback-%s\n' "$_stamp"

    step "2. Free memory"
    for s in $FREE_SERVICES; do
        _c=$(svc_cid "$s")
        if [ -z "$_c" ]; then
            printf '  %-18s not running\n' "$s"
            continue
        fi
        if docker stop "$_c" >/dev/null 2>&1; then
            STOPPED="$STOPPED $_c"
            printf '  %-18s stopped\n' "$s"
        else
            # Do not continue quietly. A stop that fails is memory this build
            # is counting on and will not get.
            c_red "  $s FAILED to stop — the build would be short its memory"
            return 1
        fi
    done
    _avail=$(mem_avail)
    printf '  MemAvailable now %s MB\n' "$_avail"
    if [ "$_avail" -lt $((CAGE_MB + FLOOR_MB)) ]; then
        c_red "  only ${_avail} MB free; a ${CAGE_MB} MB cage would leave the host under the ${FLOOR_MB} MB floor"
        printf '  Refusing to start. Lower it: KING_BUILD_CAGE_MB=%s ./scripts/king-maintenance.sh --rebuild\n' \
            "$((_avail - FLOOR_MB - 200))"
        return 1
    fi

    step "3. Bounded builder"
    docker buildx rm "$BUILDER" >/dev/null 2>&1
    docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null 2>&1 \
        || { c_red "  could not create the buildx builder"; return 1; }
    _bk="buildx_buildkit_${BUILDER}0"
    docker update --cpus=1.0 --memory="${CAGE_MB}m" --memory-swap="$((CAGE_MB + 1024))m" "$_bk" >/dev/null \
        || { c_red "  could not cap $_bk — refusing to build unbounded"; return 1; }
    printf '  %s capped at %s MB RSS, 1 CPU\n' "$_bk" "$CAGE_MB"
    printf '  (1 CPU is deliberate: it leaves the other core serving the stack)\n'

    step "4. Watchdog"
    ( fail=0; low=0
      while docker ps --format '{{.Names}}' | grep -qx "$_bk"; do
          c=$(gw_code); a=$(mem_avail)
          [ "$c" = "200" ] && fail=0 || fail=$((fail + 1))
          [ "$a" -lt "$FLOOR_MB" ] && low=$((low + 1)) || low=0
          if [ "$fail" -ge 3 ] || [ "$low" -ge 3 ]; then
              printf '\n  WATCHDOG ABORT (gateway=%s mem=%sMB) — stopping the build\n' "$c" "$a"
              docker stop -t 5 "$_bk" >/dev/null 2>&1; break
          fi
          sleep 15
      done ) &
    WATCHDOG_PID=$!
    printf '  watching: 3 missed health checks, or MemAvailable < %s MB\n' "$FLOOR_MB"

    step "5. Build (this is the long part — 30-90 min on one core)"
    # NOT `if docker buildx ... | tail | sed`. A pipeline's exit status is its
    # LAST command's, so that tested `sed` -- which always succeeds -- and a
    # failed build fell through to step 6 reporting "the TLS binary is not the
    # one on record" for an image that had never been built. Measured
    # 2026-09-11: npm ci died on a transient network error at Dockerfile:111
    # and the operator was told rebuilding was not the fix. It was.
    #
    # The full log goes to a file for the same reason: `tail -20` threw away
    # the part that said what actually happened.
    _blog="/tmp/king-build-$(date +%Y%m%d-%H%M%S).log"
    _brc=0
    docker buildx --builder "$BUILDER" build \
        -f omniroute/Dockerfile --target runner-base \
        --build-arg "OMNIROUTE_BASE_PATH=" \
        --build-arg "OMNIROUTE_BUILD_MEMORY_MB=${HEAP_MB}" \
        --load -t omniroute:candidate omniroute/ > "$_blog" 2>&1 || _brc=$?
    tail -20 "$_blog" | sed 's/^/  /'
    kill "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""
    if [ "$_brc" -ne 0 ]; then
        c_red "  build FAILED (exit $_brc) — the running image is untouched"
        printf '  full log: %s\n' "$_blog"
        # Name the cause rather than guessing, because the two look nothing
        # alike and the remedies are opposites.
        if grep -qi 'npm error network\|Temporary failure resolving\|Could not resolve host\|TLS handshake' "$_blog"; then
            c_yell "  cause: NETWORK, not memory. Nothing is wrong with this host's sizing."
            printf '  Check and retry: curl -sI https://registry.npmjs.org | head -1\n'
        elif grep -qi 'ResourceExhausted\|Killed\|heap out of memory\|Cannot allocate' "$_blog"; then
            c_yell "  cause: MEMORY."
            printf '  Turbopack needs ~3.11 GB RSS that no flag bounds; webpack needs ~3.9 GB\n'
            printf '  of V8 heap. Try KING_BUILD_CAGE_MB=5120, or build on a larger machine\n'
            printf '  and move the result with docker save + docker load.\n'
        else
            printf '  cause not recognised — read the log above before assuming it is memory.\n'
        fi
        return 1
    fi

    step "6. Verify the new image BEFORE touching the running one"
    _got=$(docker run --rm --entrypoint node omniroute:candidate -e '
const fs=require("fs"),c=require("crypto"),d="/app/node_modules/tls-client-node/bin";
const f=fs.readdirSync(d).filter(x=>x.endsWith(".so"))[0];
process.stdout.write(c.createHash("sha256").update(fs.readFileSync(d+"/"+f)).digest("hex"));' 2>/dev/null)
    if [ -z "$_got" ]; then
        # "could not read it" and "it is the wrong one" are different problems
        # with opposite remedies, and saying the second when it is the first
        # sent the operator to scripts/tls-client-pin.txt for a build that had
        # simply failed. Step 5 now returns before reaching here, but this must
        # not depend on that.
        c_red "  could not read the TLS binary out of omniroute:candidate — NOT deploying"
        printf '  The image may not exist or may not have built. Check the step 5 log.\n'
        return 1
    fi
    if [ "$_got" != "$TLS_WANT" ]; then
        c_red "  the TLS binary is the WRONG ONE — NOT deploying this image"
        printf '  got      %s\n  expected %s\n' "$_got" "$TLS_WANT"
        printf '  See scripts/tls-client-pin.txt. A rebuild is not the fix if this differs.\n'
        return 1
    fi
    c_green "  tls-client matches the digest upstream publishes for v1.16.0"
    # Same pipeline trap as step 5: capture the status, then print.
    _lrc=0
    _lout=$(docker run --rm --entrypoint node omniroute:candidate -e '
const {ensureNativeBinding}=require("/app/node_modules/tls-client-node/dist/native.js");
ensureNativeBinding({}).then(b=>{console.log("loads, exports: "+Object.keys(b).sort().join(", "));process.exit(0)})
 .catch(e=>{console.log("FAILED: "+e.message);process.exit(1)});' 2>&1) || _lrc=$?
    printf '%s\n' "$_lout" | sed 's/^/  /'
    if [ "$_lrc" -eq 0 ]; then
        c_green "  the new binary actually loads"
    else
        c_red "  the new binary does not load — NOT deploying"
        return 1
    fi

    step "7. Cut over (downtime is the recreate, ~15s, not the build)"
    docker tag omniroute:candidate omniroute:base
    docker compose -f omniroute/docker-compose.yml --profile base up -d --no-build \
        --force-recreate omniroute 2>&1 | tail -3 | sed 's/^/  /'
    _i=0
    while [ "$_i" -lt 60 ]; do
        [ "$(gw_code)" = "200" ] && break
        _i=$((_i + 1)); sleep 3
    done
    if [ "$(gw_code)" = "200" ]; then
        c_green "  gateway healthy after $((_i * 3))s"
    else
        c_red "  gateway did NOT come back"
        printf '  roll back:\n    docker tag omniroute:rollback-%s omniroute:base\n' "$_stamp"
        printf '    docker compose -f omniroute/docker-compose.yml --profile base up -d --no-build --force-recreate omniroute\n'
        return 1
    fi

    step "8. Restart what was stopped"
    restore_services

    step "9. Prove it"
    docker buildx rm "$BUILDER" >/dev/null 2>&1
    ./scripts/king-audit.sh -d J 2>&1 | grep -E 'J-4|J-5' | sed 's/^/  /'
    printf '\n  If J-4 is green, update scripts/tls-client-pin.txt history and commit.\n\n'
}

# ------------------------------------------------------------- os updates
do_os_updates() {
    step "Security updates"
    priv apt-get update -qq 2>/dev/null
    _list=$(priv sh -c 'apt-get -s upgrade 2>/dev/null | grep -i "^Inst.*security"')
    _n=$(printf '%s' "$_list" | grep -c . || true)
    if [ "${_n:-0}" -eq 0 ]; then
        c_green "  nothing pending"
        return 0
    fi
    printf '%s\n' "$_list" | awk '{print "  "$2" "$3}' | head -20
    printf '\n  %s package(s). Apply now? [y/N] ' "$_n"
    read -r ans; [ "$ans" = "y" ] || { printf '  stopped.\n'; return 0; }

    # needrestart in list mode: a glibc upgrade that bounces dockerd
    # unsupervised stops all ten containers. Decide that deliberately.
    priv env NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive \
        apt-get -y -o Dpkg::Options::=--force-confdef upgrade 2>&1 | tail -12 | sed 's/^/  /'

    step "Does anything need restarting?"
    priv needrestart -b 2>/dev/null | grep -E 'NEEDRESTART-(SVC|KSTA)' | head -12 | sed 's/^/  /' \
        || printf '  needrestart not available\n'
    if priv test -f /var/run/reboot-required; then
        c_yell "  A REBOOT IS REQUIRED."
        printf '  Ten containers stop and come back on their restart policy. The last\n'
        printf '  reboot (2026-09-10 12:25) took 15s for dockerd and the stack returned\n'
        printf '  on its own. Reboot when you are ready:\n\n    sudo reboot\n\n'
    else
        c_green "  no reboot flagged"
    fi
    printf '  Re-check with: ./scripts/king-audit.sh -d K\n\n'
}

case "${1:---plan}" in
    --plan)       do_plan ;;
    --rebuild)    do_rebuild ;;
    --os-updates) do_os_updates ;;
    --all)        do_rebuild && do_os_updates ;;
    *)            sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
