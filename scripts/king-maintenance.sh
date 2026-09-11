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
#     OOMed. Stopping activepieces and codegraph-serve releases ~1.3 GB.
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
FREE_SERVICES="activepieces codegraph-serve"   # stopped to make room, restarted after
CAGE_MB="${KING_BUILD_CAGE_MB:-4608}"
HEAP_MB="${KING_BUILD_HEAP_MB:-3584}"
FLOOR_MB=400                                    # host MemAvailable abort floor
TLS_WANT=2ec853496634545e7a7ea028715763948d55bbdd97aca7ecaa9fea8c2ebb08df

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yell()  { printf '\033[33m%s\033[0m\n' "$*"; }
step()    { printf '\n\033[1m== %s\033[0m\n' "$*"; }

priv() { if sudo -n true 2>/dev/null; then sudo -n "$@"; else "$@"; fi; }
mem_avail() { awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo; }
gw_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$GW_URL" 2>/dev/null || echo 000; }

STOPPED=""
restore_services() {
    [ -n "$STOPPED" ] || return 0
    printf '  restarting what this stopped: %s\n' "$STOPPED"
    # shellcheck disable=SC2086
    docker compose up -d --no-build $STOPPED >/dev/null 2>&1
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
        _c=$(docker ps --filter "name=$s" --format '{{.Names}}' 2>/dev/null | head -1)
        [ -n "$_c" ] || continue
        _u=$(docker stats --no-stream --format '{{.MemUsage}}' "$_c" 2>/dev/null | cut -d/ -f1)
        printf '  %-24s currently using %s\n' "$_c" "${_u:-?}"
        _mb=$(printf '%s' "$_u" | awk '/GiB/{printf "%d", $1*1024} /MiB/{printf "%d", $1}')
        _free=$((_free + ${_mb:-0}))
    done
    _after=$((_now + _free))
    printf '\n  MemAvailable now            %s MB\n' "$_now"
    printf '  released by stopping those  %s MB\n' "$_free"
    printf '  available to the build      %s MB\n' "$_after"
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
    _sec=$(priv sh -c 'apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -ci "^Inst.*security"' 2>/dev/null || echo 0)
    printf '  %s security update(s) pending\n' "${_sec:-0}"
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
        docker compose stop "$s" >/dev/null 2>&1 && STOPPED="$STOPPED $s"
    done
    printf '  stopped:%s\n  MemAvailable now %s MB\n' "${STOPPED:- nothing}" "$(mem_avail)"

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
    if docker buildx --builder "$BUILDER" build \
        -f omniroute/Dockerfile --target runner-base \
        --build-arg "OMNIROUTE_BASE_PATH=" \
        --build-arg "OMNIROUTE_BUILD_MEMORY_MB=${HEAP_MB}" \
        --load -t omniroute:candidate omniroute/ 2>&1 | tail -20 | sed 's/^/  /'
    then :; else
        c_red "  build failed — the running image is untouched"
        printf '  Turbopack needs ~3.11 GB RSS that no flag bounds; webpack needs ~3.9 GB\n'
        printf '  of V8 heap. Try KING_BUILD_CAGE_MB=5120, or build on a larger machine\n'
        printf '  and move the result with docker save + docker load.\n'
        return 1
    fi
    kill "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""

    step "6. Verify the new image BEFORE touching the running one"
    _got=$(docker run --rm --entrypoint node omniroute:candidate -e '
const fs=require("fs"),c=require("crypto"),d="/app/node_modules/tls-client-node/bin";
const f=fs.readdirSync(d).filter(x=>x.endsWith(".so"))[0];
process.stdout.write(c.createHash("sha256").update(fs.readFileSync(d+"/"+f)).digest("hex"));' 2>/dev/null)
    if [ "$_got" != "$TLS_WANT" ]; then
        c_red "  the TLS binary is not the one on record — NOT deploying this image"
        printf '  got      %s\n  expected %s\n' "${_got:-<unreadable>}" "$TLS_WANT"
        printf '  See scripts/tls-client-pin.txt. Rebuilding is not the fix if this differs.\n'
        return 1
    fi
    c_green "  tls-client matches the digest upstream publishes for v1.16.0"
    if docker run --rm --entrypoint node omniroute:candidate -e '
const {ensureNativeBinding}=require("/app/node_modules/tls-client-node/dist/native.js");
ensureNativeBinding({}).then(b=>{console.log("  loads, exports: "+Object.keys(b).sort().join(", "));process.exit(0)})
 .catch(e=>{console.log("  FAILED: "+e.message);process.exit(1)});' 2>&1 | sed 's/^/  /'
    then c_green "  the new binary actually loads"
    else c_red "  the new binary does not load — NOT deploying"; return 1; fi

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
