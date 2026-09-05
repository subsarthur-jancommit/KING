#!/usr/bin/env bash
#
# ci-build-omniroute-base.sh — provide the omniroute:base image on a CI runner.
#
# Every workflow job that needs a running OmniRoute calls this first, so the
# logic lives here rather than being copy-pasted into each one.
#
# It PULLS by default and builds only on request. That reversed on 2026-09-05,
# and the reason matters more than the mechanism.
#
# The build is broken by something outside this repository:
# `tls-client-node@0.2.0` resolves its native binary from a third party's
# GitHub releases at build time with no pin, and that project renamed its
# assets in v1.16.0. No commit here caused it and no commit here can fix it —
# the full account, including the lever that exists and cannot be reached, is
# in docs/king-mistakes.md. While it stands, every job that built this image
# failed before running a single assertion.
#
# That cost more than it looks. These three jobs do not exist to prove the
# vendored app compiles — `omniroute-smoke` does that, and it is red for this
# same reason, correctly. They exist to prove OUR wiring works against a
# running gateway: the compose graph, Caddy's routes, Activepieces reaching
# the gateway over the network, the sidecar's suite against a live /v1. All of
# that stopped being tested because of a build step none of it depends on.
#
# So: pull a published image of the exact version this repo vendors, and let
# the build question stay where it belongs. `omniroute-smoke` still answers
# it, and CI_OMNIROUTE_BUILD=1 restores the build here once upstream is fixed.
#
# Pinned by digest, not tag — tags are mutable, and CLAUDE.md requires a digest
# or an exact tag for every image. The digest is the multi-arch index, so it
# resolves correctly on any runner architecture.
#
# The version guard below is the point of failure to care about. A digest that
# silently disagrees with the vendored source would mean CI testing a gateway
# the repo does not ship — the exact "guard that does not cover the case it
# appears to cover" shape that docs/king-mistakes.md opens with. After a
# `git subtree pull`, this script fails loudly until the digest is updated.
#
# Usage: ./scripts/ci-build-omniroute-base.sh
# Env:   CI_OMNIROUTE_BUILD=1        build from source instead of pulling
#        OMNIROUTE_BUILD_MEMORY_MB   (build only, default 1536)
#        CI_SWAP_SIZE                (build only, default 12G)

set -euo pipefail

# ghcr.io/diegosouzapw/omniroute:3.8.50 — the OCI index digest, resolved
# 2026-09-05. Update BOTH lines together after a subtree pull; the guard below
# checks them against omniroute/package.json.
OMNIROUTE_IMAGE_VERSION="3.8.50"
OMNIROUTE_IMAGE_DIGEST="sha256:085c57adf499a8aaa9f35ccde95c0df9c11bd9ecd18d6c9edbf3b68b8079ba9d"
OMNIROUTE_IMAGE_REPO="ghcr.io/diegosouzapw/omniroute"

BUILD_MEMORY_MB="${OMNIROUTE_BUILD_MEMORY_MB:-1536}"
SWAP_SIZE="${CI_SWAP_SIZE:-12G}"

cd "$(dirname "$0")/.."

# Read the version the subtree actually vendors. If this and the pinned image
# disagree, the pull is testing a different gateway than the repo ships, and
# that must stop the job rather than quietly pass.
# One parser, used for both sides of the comparison. It reads a package.json on
# stdin so the host's file and the image's file go through identical code — two
# near-identical seds could disagree, and the guard would then be comparing
# parser quirks rather than versions.
parse_version() {
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

vendored_version() {
  parse_version < omniroute/package.json
}

pull_image() {
  local vendored
  vendored="$(vendored_version)"

  if [ -z "$vendored" ]; then
    echo "ERROR: could not read the version from omniroute/package.json." >&2
    return 1
  fi

  if [ "$vendored" != "$OMNIROUTE_IMAGE_VERSION" ]; then
    cat >&2 <<EOF
ERROR: the pinned image does not match the vendored source.

  omniroute/package.json : $vendored
  pinned in this script  : $OMNIROUTE_IMAGE_VERSION

CI would test a gateway this repo does not ship. Pull the matching tag's index
digest and update OMNIROUTE_IMAGE_VERSION and OMNIROUTE_IMAGE_DIGEST together:

  docker buildx imagetools inspect $OMNIROUTE_IMAGE_REPO:$vendored

If no published image exists for that version, set CI_OMNIROUTE_BUILD=1 and
build from source instead.
EOF
    return 1
  fi

  echo "--- pulling ${OMNIROUTE_IMAGE_REPO}:${OMNIROUTE_IMAGE_VERSION} by digest ---"
  docker pull "${OMNIROUTE_IMAGE_REPO}@${OMNIROUTE_IMAGE_DIGEST}"
  docker tag "${OMNIROUTE_IMAGE_REPO}@${OMNIROUTE_IMAGE_DIGEST}" omniroute:base

  # Assert against the image itself, not against the tag we just applied.
  # Verifying the tag we set would prove only that `docker tag` works.
  local in_image
  in_image="$(docker run --rm --entrypoint cat omniroute:base /app/package.json | parse_version)"

  if [ "$in_image" != "$OMNIROUTE_IMAGE_VERSION" ]; then
    echo "ERROR: pulled image reports version '$in_image', expected '$OMNIROUTE_IMAGE_VERSION'." >&2
    return 1
  fi

  echo "omniroute:base is ${OMNIROUTE_IMAGE_REPO}:${OMNIROUTE_IMAGE_VERSION} (${in_image}), pinned by digest."
}

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

build_image() {
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
}

if [ "${CI_OMNIROUTE_BUILD:-0}" = "1" ]; then
  build_image
else
  pull_image
fi
