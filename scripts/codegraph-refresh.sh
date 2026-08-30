#!/usr/bin/env bash
# Rebuild the code knowledge graph and restart the server that holds it.
#
# The schedule lives in a systemd timer, not in compose. A timer gives three
# things compose cannot: Persistent=true so a missed run catches up after the
# reboot a VPS eventually has, a randomised delay, and a place to hang the lock
# below. Scheduling inside compose would mean a sleep-loop entrypoint, turning
# a four-minute one-shot into a process holding its 4 GB ceiling all day.
#
#   ./scripts/codegraph-refresh.sh          # rebuild, verify, restart serve
#   ./scripts/codegraph-refresh.sh --check  # report staleness, change nothing
#
# Exit codes: 0 = graph is current, 1 = failed or (with --check) stale.

set -euo pipefail

cd "$(dirname "$0")/.."

LOCK=/tmp/codegraph-refresh.lock
MIN_NODES=${CODEGRAPH_MIN_NODES:-40000}

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# `-T` AND `</dev/null` on every `docker compose run` below, both load-bearing.
# compose otherwise attaches this script's stdin to the container, and the
# script then EATS whatever is feeding it: run over `ssh 'bash -s' <<EOF` it
# silently swallowed the rest of the remote script and looked like it had just
# finished early, exit 0 and all. -T alone did NOT fix it — measured — because
# -T only disables the pseudo-TTY, not the stdin attachment.
graph_commit() {
  docker compose --profile codegraph run --rm -T --no-deps --entrypoint sh \
    codegraph-serve -c 'sed -n "s/^commit=//p" /out/graphify-out/BUILD_INFO 2>/dev/null' \
    </dev/null 2>/dev/null | tr -d '\r\n' || true
}

head_commit() { git rev-parse HEAD; }

if [ "${1:-}" = "--check" ]; then
  built=$(graph_commit)
  live=$(head_commit)
  if [ -z "$built" ]; then
    red "No graph built yet (BUILD_INFO absent)."
    exit 1
  fi
  if [ "$built" != "$live" ]; then
    # Deliberately an error, not a warning. A graph that disagrees with the
    # tree answers confidently about code that has moved, and CLAUDE.md tells
    # agents to prefer it over reading files.
    red "Graph is STALE: built from ${built:0:8}, tree is at ${live:0:8}."
    exit 1
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    yellow "Graph matches HEAD (${built:0:8}), but the working tree is dirty."
    exit 0
  fi
  green "Graph is current (${built:0:8})."
  exit 0
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  yellow "Another refresh is already running; leaving it alone."
  exit 0
fi

# The build peaks at ~3.5 GB. A resident Ollama model holds ~2.5 GB. On a
# 7.8 GB host already running the gateway and the workflow engine, the two
# together do not fit — so the build refuses rather than letting the kernel
# choose a victim by RSS, which on this host would be Activepieces or the
# gateway, not this process.
#
# This block did nothing at all until 2026-08-30. It matched `docker ps` output
# against the literal name `ollama` with `grep -qx`, which needs the whole line;
# the container is `king-ollama-1`, so the condition was never once true. Two
# documents cited it as the safety property that made the collision impossible.
# Resolve the container through compose instead, which cannot drift from the
# service name.
ollama_cid=$(docker compose --profile localmodel ps -q ollama 2>/dev/null || true)
if [ -n "$ollama_cid" ]; then
  # `|| echo 0` used to live on this line. When `docker exec` failed, `loaded`
  # became the two-line string "0\n0", the numeric test below errored with
  # 'integer expected', and — because it is an `if` condition, where `set -e`
  # does not apply — the script carried straight on to a 4 GB build believing
  # nothing was resident. An instrument that cannot read must say so, not
  # answer zero.
  if ! raw=$(docker exec "$ollama_cid" ollama ps 2>&1); then
    red "Cannot read Ollama state: $raw"
    red "Refusing to start a 4 GB build without knowing whether a model is resident."
    exit 1
  fi
  loaded=$(printf '%s\n' "$raw" | tail -n +2 | grep -c . || true)
  case "$loaded" in
    '' | *[!0-9]*)
      red "Unparseable 'ollama ps' output, refusing to guess:"
      printf '%s\n' "$raw" >&2
      exit 1
      ;;
  esac
  if [ "$loaded" -gt 0 ]; then
    yellow "Ollama is holding $loaded model(s) resident; unloading before the build."
    docker exec "$ollama_cid" sh -c \
      'ollama ps --format "{{.Name}}" 2>/dev/null | while read -r m; do [ -n "$m" ] && ollama stop "$m"; done' \
      || yellow "Unload command failed; the memory check below is what actually protects the build."
  fi
fi

# Second, independent layer. The unload above can be skipped (no localmodel
# profile), can fail, or can race a request that reloads the model — so the one
# number that actually decides the outcome is read directly, immediately before
# the build. 3584 MB is the measured peak, not the 4096 MB ceiling: MemAvailable
# is a conservative kernel estimate and a floor at the ceiling would refuse
# builds that would have succeeded.
min_avail=${CODEGRAPH_MIN_AVAIL_MB:-3584}
avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)
if [ -z "$avail_kb" ]; then
  yellow "Cannot read MemAvailable from /proc/meminfo; proceeding without the memory check."
else
  avail_mb=$((avail_kb / 1024))
  if [ "$avail_mb" -lt "$min_avail" ]; then
    red "Only ${avail_mb} MB available; the build has measured a ${min_avail} MB peak."
    red "Refusing rather than letting the kernel pick a victim by RSS."
    docker stats --no-stream --format '  {{.Name}}  {{.MemUsage}}' 2>/dev/null | sort -k2 -h -r | head -5 >&2 || true
    exit 1
  fi
  green "${avail_mb} MB available (need ${min_avail} MB)."
fi

commit=$(head_commit)
echo "Building graph from ${commit:0:8}…"
CODEGRAPH_COMMIT="$commit" \
  docker compose --profile codegraph run --rm -T codegraph-build </dev/null

# graphify writes the graph before this script can see it, so the node floor is
# checked here rather than trusted. A graph that suddenly shrinks by half is a
# broken extraction, and serving it is worse than serving the previous one.
nodes=$(docker compose --profile codegraph run --rm -T --no-deps --entrypoint python \
  codegraph-serve -c \
  'import json;print(len(json.load(open("/out/graphify-out/graph.json"))["nodes"]))' \
  </dev/null 2>/dev/null | tr -d '\r\n')

if ! [ "${nodes:-0}" -ge "$MIN_NODES" ] 2>/dev/null; then
  red "Graph has ${nodes:-0} nodes, below the floor of $MIN_NODES. Not restarting the server."
  red "The previous graph is still being served. Investigate before retrying."
  exit 1
fi
green "Graph built: $nodes nodes, from ${commit:0:8}."

# graphify.serve loads the graph into memory at startup, so a rewritten
# graph.json changes nothing until the process restarts.
echo "Restarting codegraph-serve…"
docker compose --profile codegraph up -d --force-recreate codegraph-serve
green "Done."
