#!/usr/bin/env bash
#
# king-tls-patch.sh — replace the CVE-affected tls-client binary in the
# gateway image, without rebuilding the gateway.
#
#   --verify   check the source binary and the running container. Changes nothing.
#   --apply    build the patch layer, verify it, and cut the gateway over.
#   --rollback <tag>   put a previous image back.
#
# WHY THIS EXISTS, AND WHY IT IS NOT THE FIRST CHOICE.
#
# The right fix is a rebuild from source: `./scripts/king-maintenance.sh
# --rebuild`. Use that instead wherever it works. It does not work here, and
# that is measured rather than assumed — eight attempts on 2026-09-10/11:
#
#   turbopack  sizes itself to the cgroup and then exceeds it. Killed at
#              3.11 GB in a 3584 MB cage and at 3.99 GB in a 4608 MB cage —
#              87% of the limit both times. There is no cage this host can
#              afford that it will not fill.
#   webpack    is bounded by --max-old-space-size, but needs MORE than 4096 MB:
#              "FATAL ERROR: Ineffective mark-compacts near heap limit", with no
#              kernel OOM at all. Upstream raised its own default to 8192 for
#              the same reason. This host can offer ~4.8 GB while keeping a
#              1.16 GB gateway alive, so it is short either way.
#
# Swap does not help: V8 throws at its own ceiling rather than spilling.
#
# So the choice was never "patch the artefact or fix the build". It was "patch
# the artefact, take the gateway down for 1-1.5 hours, or leave a CVE in
# place". This is the cheapest of the three and the only one that costs no
# outage beyond a container recreate.
#
# WHAT IT DOES NOT DO. It does not update anything else in the image. The base
# is still the 2026-08-27 build, so OS packages inside it stay where they were.
# That is recorded in scripts/tls-client-pin.txt, and it is the reason this is
# a stopgap rather than an answer.
#
# On unbounded builds: this layer copies one file and deletes another. It
# compiles nothing. The 45-minute outage in docs/king-mistakes.md entry 1 came
# from a Next.js compile, not from `docker build` existing.
#
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1

TLS_VER="${KING_TLS_VERSION:-1.16.0}"
TLS_FILE="tls-client-linux-ubuntu-amd64-${TLS_VER}.so"
TLS_URL="https://github.com/bogdanfinn/tls-client/releases/download/v${TLS_VER}/${TLS_FILE}"
# Published by upstream in the release API's `digest` field for this asset, so
# this is checked against the source and not merely against what we downloaded.
TLS_SHA="${KING_TLS_SHA256:-2ec853496634545e7a7ea028715763948d55bbdd97aca7ecaa9fea8c2ebb08df}"
SRC_DIR="${KING_TLS_DIR:-$HOME/tlsfix}"
BIN_DIR="/app/node_modules/tls-client-node/bin"
BASE_IMAGE="omniroute:base"
# The container is named `omniroute`; the compose SERVICE is `omniroute-base`.
# Passing the container name gives "no such service" and the command fails.
GW_SERVICE="${KING_GW_SERVICE:-omniroute-base}"
CAND_IMAGE="omniroute:tls-${TLS_VER}"
GW_URL="http://127.0.0.1:20128/api/monitoring/health"

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yell()  { printf '\033[33m%s\033[0m\n' "$*"; }
step()    { printf '\n\033[1m== %s\033[0m\n' "$*"; }

gw_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$GW_URL" 2>/dev/null || echo 000; }

# sha256 of every .so in an image's bin directory, as "<sha>  <name>".
# node, not sha256sum: node is guaranteed present in this image, coreutils is not.
image_bins() {
    docker run --rm --entrypoint node "$1" -e '
const fs=require("fs"),c=require("crypto"),d=process.argv[1];
let out=[];
try { for (const f of fs.readdirSync(d).sort())
        out.push(c.createHash("sha256").update(fs.readFileSync(d+"/"+f)).digest("hex")+"  "+f); }
catch (e) { process.exit(3); }
process.stdout.write(out.join("\n"));' "$BIN_DIR" 2>/dev/null
}

# Does the package's own loader actually bring this binary up?
image_loads() {
    docker run --rm --entrypoint node "$1" -e '
const {ensureNativeBinding}=require("/app/node_modules/tls-client-node/dist/native.js");
ensureNativeBinding({}).then(b=>{console.log("loads, exports: "+Object.keys(b).sort().join(", "));process.exit(0)})
 .catch(e=>{console.log("FAILED: "+e.message);process.exit(1)});' 2>&1
}

# ------------------------------------------------------------------ source
ensure_source() {
    mkdir -p "$SRC_DIR"
    if [ ! -s "$SRC_DIR/$TLS_FILE" ]; then
        printf '  fetching %s\n' "$TLS_FILE"
        curl -sSL --max-time 180 -o "$SRC_DIR/$TLS_FILE.part" "$TLS_URL" || {
            c_red "  download failed"; return 1; }
        mv "$SRC_DIR/$TLS_FILE.part" "$SRC_DIR/$TLS_FILE"
    fi
    _got=$(sha256sum "$SRC_DIR/$TLS_FILE" | awk '{print $1}')
    if [ "$_got" != "$TLS_SHA" ]; then
        # Never build from a binary whose provenance does not check out. This
        # is the whole point of patching by digest rather than by version.
        c_red "  SHA256 MISMATCH — refusing to use this file"
        printf '  got      %s\n  expected %s\n  file     %s\n' "$_got" "$TLS_SHA" "$SRC_DIR/$TLS_FILE"
        return 1
    fi
    c_green "  source verified: $TLS_FILE matches the digest upstream publishes"
    return 0
}

# ------------------------------------------------------------------ verify
do_verify() {
    step "Source binary"
    ensure_source || return 1

    step "What the gateway is running now"
    _c=$(docker ps -q --filter "label=com.docker.compose.service=omniroute-base" 2>/dev/null | head -1)
    [ -n "$_c" ] || _c=$(docker ps -q --filter "name=^omniroute$" 2>/dev/null | head -1)
    if [ -z "$_c" ]; then
        c_yell "  gateway container not running"
    else
        docker exec "$_c" sh -c "ls -1 $BIN_DIR" 2>/dev/null | sed 's/^/    /'
        # Loaded lazily, so an empty answer here is the normal case and is the
        # fact that makes this CVE dormant rather than urgent.
        _mapped=$(docker exec "$_c" sh -c 'grep -c "tls-client.*so" /proc/1/maps 2>/dev/null' 2>/dev/null || true)
        printf '    mapped into the running process: %s\n' "${_mapped:-0}"
    fi

    step "Base image"
    if docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        image_bins "$BASE_IMAGE" | sed 's/^/    /'
    else
        c_red "  $BASE_IMAGE not present"; return 1
    fi
    printf '\n  Nothing was changed. Run --apply to patch.\n\n'
}

# ------------------------------------------------------------------- apply
do_apply() {
    step "1. Source binary"
    ensure_source || return 1

    step "2. Build the patch layer"
    # The RUN keeps exactly one binary rather than deleting a named old one:
    # the package's loader reads the DIRECTORY and takes the last match, so a
    # forgotten sibling would silently decide which binary runs.
    # NOT `if docker build ... | tail | sed`. A pipeline returns its LAST
    # command's status, so that tests `sed` and a failed build reads as a
    # success. This is the third time that shape has appeared in scripts
    # written this week; see docs/king-mistakes.md 34.
    _brc=0
    docker build -f - -t "$CAND_IMAGE" "$SRC_DIR" > /tmp/king-tls-build.$$ 2>&1 <<EOF || _brc=$?
FROM ${BASE_IMAGE}
COPY --chown=node:node ${TLS_FILE} ${BIN_DIR}/${TLS_FILE}
RUN cd ${BIN_DIR} \\
 && for f in tls-client-*; do [ "\$f" = "${TLS_FILE}" ] || rm -f "\$f"; done \\
 && chmod 755 ${TLS_FILE} \\
 && ls -la ${BIN_DIR}
EOF
    tail -6 /tmp/king-tls-build.$$ | sed 's/^/    /'
    rm -f /tmp/king-tls-build.$$
    if [ "$_brc" -ne 0 ]; then
        c_red "  build failed (exit $_brc)"; return 1
    fi
    docker image inspect "$CAND_IMAGE" >/dev/null 2>&1 || { c_red "  no image produced"; return 1; }

    step "3. Verify the patched image BEFORE touching the running one"
    _bins=$(image_bins "$CAND_IMAGE")
    printf '%s\n' "$_bins" | sed 's/^/    /'
    _n=$(printf '%s\n' "$_bins" | grep -c . || true)
    if [ "${_n:-0}" -ne 1 ]; then
        c_red "  expected exactly 1 binary, found ${_n:-0} — NOT deploying"
        return 1
    fi
    _got=$(printf '%s' "$_bins" | awk '{print $1}')
    if [ "$_got" != "$TLS_SHA" ]; then
        c_red "  the binary in the image is not the verified one — NOT deploying"
        printf '  got      %s\n  expected %s\n' "$_got" "$TLS_SHA"
        return 1
    fi
    c_green "  exactly one binary, and its digest is the one upstream publishes"

    _lrc=0
    _lout=$(image_loads "$CAND_IMAGE") || _lrc=$?
    printf '%s\n' "$_lout" | sed 's/^/    /'
    if [ "$_lrc" -ne 0 ]; then
        c_red "  the patched binary does not load — NOT deploying"
        return 1
    fi
    c_green "  the package's own loader brings it up"

    step "4. Rollback point"
    _stamp=$(date +%Y%m%d-%H%M)
    _roll="omniroute:rollback-$_stamp"
    docker tag "$BASE_IMAGE" "$_roll" || { c_red "  could not tag"; return 1; }
    printf '  %s\n' "$_roll"

    step "5. Cut over"
    # The container is named `omniroute`; the SERVICE is `omniroute-base`.
    # Passing the container name gave "no such service: omniroute", the compose
    # command failed, and the health loop then passed in 0s -- because the OLD
    # gateway was still up and answering. A cutover that never happened read as
    # a cutover that succeeded.
    #
    # So health is not the test. The test is that the container was REPLACED:
    # capture its id first, and require a different one afterwards.
    _before=$(docker ps -q --filter "label=com.docker.compose.service=${GW_SERVICE}" | head -1)
    printf '  gateway before: HTTP %s (container %s)\n' "$(gw_code)" "${_before:0:12}"
    docker tag "$CAND_IMAGE" "$BASE_IMAGE"
    _crc=0
    docker compose -f omniroute/docker-compose.yml --profile base up -d --no-build \
        --no-deps --force-recreate "$GW_SERVICE" > /tmp/king-tls-cutover.$$ 2>&1 || _crc=$?
    tail -3 /tmp/king-tls-cutover.$$ | sed 's/^/    /'
    rm -f /tmp/king-tls-cutover.$$
    if [ "$_crc" -ne 0 ]; then
        c_red "  recreate FAILED (exit $_crc) — the gateway still runs the old image"
        printf '  Nothing was lost: %s still points at the pre-patch image.\n' "$_roll"
        return 1
    fi
    _after=$(docker ps -q --filter "label=com.docker.compose.service=${GW_SERVICE}" | head -1)
    if [ -z "$_after" ] || [ "$_after" = "$_before" ]; then
        c_red "  the container was NOT replaced — compose reported success and changed nothing"
        printf '  before %s / after %s\n' "${_before:0:12}" "${_after:0:12}"
        return 1
    fi
    printf '  container replaced: %s -> %s\n' "${_before:0:12}" "${_after:0:12}"
    _i=0
    while [ "$_i" -lt 60 ]; do
        [ "$(gw_code)" = "200" ] && break
        _i=$((_i + 1)); sleep 3
    done
    if [ "$(gw_code)" != "200" ]; then
        c_red "  gateway did NOT come back"
        printf '  roll back:\n    ./scripts/king-tls-patch.sh --rollback %s\n' "$_roll"
        return 1
    fi
    c_green "  gateway healthy after $((_i * 3))s"

    step "6. Prove it on the RUNNING container, not the image"
    _c="$_after"
    _live=$(docker exec "$_c" sh -c "ls -1 $BIN_DIR" 2>/dev/null)
    printf '%s\n' "$_live" | sed 's/^/    /'
    # An assertion, not a printout. Step 6 caught the failed cutover above only
    # because a human read it; now it fails the script.
    if [ "$_live" != "$TLS_FILE" ]; then
        c_red "  the running gateway is NOT on $TLS_FILE — patch did not take"
        printf '  roll back:\n    ./scripts/king-tls-patch.sh --rollback %s\n' "$_roll"
        return 1
    fi
    _keys=$(docker exec "$_c" node -e '
const D=require("better-sqlite3")("/app/data/storage.sqlite",{readonly:true});
process.stdout.write(String(D.prepare("SELECT COUNT(*) c FROM api_keys").get().c));' 2>/dev/null || echo '?')
    printf '    API keys intact: %s\n' "$_keys"
    if [ "$_keys" != "7" ]; then
        c_yell "    expected 7 API keys — check before trusting this"
    fi
    # Print the script's own rollback, not a hand-written compose line. The
    # hand-written one named the container instead of the service and would
    # have failed exactly when it was needed most.
    printf '\n  rollback if anything looks wrong:\n    ./scripts/king-tls-patch.sh --rollback %s\n\n' "$_roll"
    c_green "  done. Update scripts/tls-client-pin.txt and re-run ./scripts/king-audit.sh -d J"
}

do_rollback() {
    _tag="${1:-}"
    [ -n "$_tag" ] || { c_red "  need a tag: --rollback omniroute:rollback-YYYYMMDD-HHMM"; return 1; }
    docker image inspect "$_tag" >/dev/null 2>&1 || { c_red "  no such image: $_tag"; return 1; }
    docker tag "$_tag" "$BASE_IMAGE"
    docker compose -f omniroute/docker-compose.yml --profile base up -d --no-build \
        --no-deps --force-recreate "$GW_SERVICE" 2>&1 | tail -3 | sed 's/^/    /'
    _i=0
    while [ "$_i" -lt 60 ]; do [ "$(gw_code)" = "200" ] && break; _i=$((_i + 1)); sleep 3; done
    printf '  gateway: HTTP %s after %ss\n' "$(gw_code)" "$((_i * 3))"
}

case "${1:---verify}" in
    --verify)   do_verify ;;
    --apply)    do_apply ;;
    --rollback) shift; do_rollback "${1:-}" ;;
    *)          sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
