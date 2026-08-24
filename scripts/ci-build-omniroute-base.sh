#!/usr/bin/env bash
#
# ci-build-omniroute-base.sh — build the omniroute:base image on a CI runner.
#
# Every workflow job that needs a running OmniRoute builds this image first,
# so the logic lives here rather than being copy-pasted into each one.
#
# Two things this handles that a bare `docker build` does not:
#
# 1. Per-worker heap ceiling. `next build` generates static pages with 3
#    parallel workers that each inherit NODE_OPTIONS. OmniRoute's Dockerfile
#    sets --max-old-space-size=${OMNIROUTE_BUILD_MEMORY_MB} (issue #4076,
#    default 4096MB), which at the default gives those workers up to ~12GB of
#    combined potential heap. 1536MB x 3 workers is roughly 4.6GB instead.
#
# 2. Swap headroom, as mitigation for an intermittent runner death.
#
#    What is established: this step intermittently dies with "The runner has
#    received a shutdown signal" and exit 143, always at the same
#    "Generating static pages using 3 workers (440/587)" checkpoint. It is
#    not caused by any particular commit — on d583545 this exact step died in
#    one job while the identical command succeeded in another, on a different
#    runner, at the same moment.
#
#    What is NOT established is the cause, and earlier comments in this repo
#    overstated it. They asserted a 7GB runner being exhausted; the runners
#    actually report 15Gi total with ~14Gi available before the build starts,
#    so a 4.6GB heap ceiling does not obviously exhaust them. Exit 143 is
#    SIGTERM, which is GitHub's own runner-shutdown path, whereas the kernel
#    OOM-killer sends SIGKILL (137). Infrastructure preemption fits the
#    evidence at least as well as memory pressure does.
#
#    Swap is therefore deliberately framed as cheap headroom rather than a
#    proven fix: it costs nothing, it helps if the cause is memory pressure,
#    and it is harmless if the cause is preemption. Do not read a green run as
#    proof that it worked — the failure was always intermittent.
#
# Deliberately a plain `docker build` rather than `docker compose build`:
# overriding the build arg through a same-named service in docker-compose.yml
# was tried and is rejected at up/build time ("conflicts with imported
# resource") even though `docker compose config` accepts it. Tagging the image
# to match what the compose service already expects sidesteps the service
# graph entirely — callers then run `docker compose up` with no --build flag.
#
# Usage: ./scripts/ci-build-omniroute-base.sh
# Env:   OMNIROUTE_BUILD_MEMORY_MB (default 1536), CI_SWAP_SIZE (default 12G)

set -euo pipefail

BUILD_MEMORY_MB="${OMNIROUTE_BUILD_MEMORY_MB:-1536}"
SWAP_SIZE="${CI_SWAP_SIZE:-12G}"

cd "$(dirname "$0")/.."

provision_swap() {
  # Hosted runners keep their large scratch disk on /mnt; fall back to the
  # root filesystem if that is not how this runner is laid out.
  local swap_dir=/mnt
  [ -d "$swap_dir" ] || swap_dir=/
  local swapfile="${swap_dir%/}/ci-swapfile"

  echo "--- memory before ---"
  free -h || true

  # Existing swap must be off before its backing file can be replaced.
  sudo swapoff -a || true
  sudo rm -f "$swapfile"

  if ! sudo fallocate -l "$SWAP_SIZE" "$swapfile" 2>/dev/null; then
    # fallocate is unsupported on some filesystems; dd always works, just slower.
    echo "fallocate unavailable, falling back to dd"
    sudo dd if=/dev/zero of="$swapfile" bs=1M count=$((${SWAP_SIZE%G} * 1024)) status=none
  fi

  sudo chmod 600 "$swapfile"
  sudo mkswap "$swapfile" >/dev/null
  sudo swapon "$swapfile"

  echo "--- memory after ---"
  free -h || true
}

# Swap is a nice-to-have, not a hard requirement: a runner that refuses it can
# still build, it just has less margin. Failing the job here would trade a
# probabilistic failure for a guaranteed one.
if ! provision_swap; then
  echo "WARNING: could not provision swap; continuing with default runner memory" >&2
fi

echo "--- building omniroute:base (OMNIROUTE_BUILD_MEMORY_MB=${BUILD_MEMORY_MB}) ---"
docker build \
  --target runner-base \
  --build-arg "OMNIROUTE_BUILD_MEMORY_MB=${BUILD_MEMORY_MB}" \
  -t omniroute:base \
  omniroute/
