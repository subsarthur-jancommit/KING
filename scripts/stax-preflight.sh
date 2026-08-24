#!/usr/bin/env bash
#
# stax-preflight.sh — deploy guard for the STAX profiles.
#
# Why this exists rather than compose-native `${VAR:?err}` guards: Compose
# interpolates required variables across the ENTIRE merged model before it
# filters services by profile. A `${OH_AGENT_CANVAS_SECRET_KEY:?set me}` in
# the openhands service therefore breaks `docker compose --profile base up`
# for someone who never asked for openhands. Verified directly against
# Docker Compose v5.1.1:
#
#   services: {always-on: {...}, gated: {environment: [X=${MUST:?}], profiles: [gated]}}
#   $ docker compose config --services      # no profile selected
#   error while interpolating services.gated.environment.[]: required
#   variable MUST is missing a value
#
# So the checks that must be profile-scoped live here instead, where scoping
# is trivial. Run this before `docker compose ... up` on any host that is not
# your laptop.
#
# Usage:
#   ./scripts/stax-preflight.sh base                       # OmniRoute only
#   ./scripts/stax-preflight.sh base agent-sidecar
#   ./scripts/stax-preflight.sh base openhands observability
#   ./scripts/stax-preflight.sh --self-test                # verify this script
#
# Exit codes: 0 = safe to deploy, 1 = at least one blocking problem.

set -euo pipefail

readonly PLACEHOLDER_OH_SECRET='CHANGEME-openssl-rand-base64-32'

# Upstream Langfuse ships these as literal defaults with a `# CHANGEME`
# comment; they are published values, not secrets.
readonly PLACEHOLDER_NEXTAUTH='mysecret'
readonly PLACEHOLDER_MINIO_PASSWORD='miniosecret'

errors=0
warnings=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

fail() { red   "  FAIL  $*"; errors=$((errors + 1)); }
warn() { yellow "  WARN  $*"; warnings=$((warnings + 1)); }
pass() { green  "  ok    $*"; }

# Reads a variable's effective value: real environment first, then the given
# .env file. Mirrors how Compose itself resolves ${VAR:-default}.
lookup() {
  local var="$1" env_file="${2:-}"
  if [ -n "${!var:-}" ]; then
    printf '%s' "${!var}"
    return
  fi
  if [ -n "$env_file" ] && [ -f "$env_file" ]; then
    # Last assignment wins, matching dotenv semantics. Only strips a trailing
    # newline — an inline `# comment` is part of the value for Compose too,
    # which is exactly the bug that bit observability/.env.example earlier.
    sed -n "s/^${var}=//p" "$env_file" | tail -n 1
  fi
}

check_secret() {
  local label="$1" value="$2" placeholder="$3" min_len="${4:-16}"
  if [ -z "$value" ]; then
    fail "$label is unset — the compose placeholder would be used instead."
    return
  fi
  if [ "$value" = "$placeholder" ]; then
    fail "$label is still the published placeholder value. Anyone reading this repo knows it."
    return
  fi
  if [ "${#value}" -lt "$min_len" ]; then
    fail "$label is only ${#value} characters; expected at least $min_len."
    return
  fi
  pass "$label is set to a non-placeholder value."
}

# A bind host is safe if it is loopback. Anything else publishes the port on
# an interface reachable from outside the machine.
check_bind_host() {
  local label="$1" value="$2" guidance="$3"
  case "${value:-127.0.0.1}" in
    127.0.0.1 | ::1 | localhost)
      pass "$label stays on loopback."
      ;;
    *)
      warn "$label is ${value} — reachable off-host. $guidance"
      ;;
  esac
}

check_base() {
  echo "profile: base (OmniRoute)"
  if [ ! -f omniroute/.env ]; then
    fail "omniroute/.env is missing. Copy omniroute/.env.example and fill it in."
    return
  fi
  local jwt api_key initial
  jwt=$(lookup JWT_SECRET omniroute/.env)
  api_key=$(lookup API_KEY_SECRET omniroute/.env)
  initial=$(lookup INITIAL_PASSWORD omniroute/.env)
  # Compared against omniroute/.env.example so we flag values copied over
  # verbatim, without hardcoding OmniRoute's placeholders here (they belong to
  # the vendored subtree and may change on the next `git subtree pull`).
  check_secret "JWT_SECRET" "$jwt" "$(lookup JWT_SECRET omniroute/.env.example)" 32
  check_secret "API_KEY_SECRET" "$api_key" "$(lookup API_KEY_SECRET omniroute/.env.example)" 32
  check_secret "INITIAL_PASSWORD" "$initial" "$(lookup INITIAL_PASSWORD omniroute/.env.example)" 12
}

check_agent_sidecar() {
  echo "profile: agent-sidecar"
  local executor
  executor=$(lookup AGENT_SIDECAR_EXECUTOR agent-sidecar/.env)
  executor="${executor:-local}"
  case "$executor" in
    local)
      warn "AGENT_SIDECAR_EXECUTOR=local runs model-generated Python inside the sidecar container."
      echo "         Fine while tasks come from an operator on the CLI. Switch to docker/e2b"
      echo "         before exposing this service to input you do not control."
      ;;
    docker | e2b | modal | blaxel)
      pass "AGENT_SIDECAR_EXECUTOR=$executor uses an out-of-process sandbox."
      ;;
    *)
      fail "AGENT_SIDECAR_EXECUTOR=$executor is not a value smolagents accepts."
      ;;
  esac

  local key
  key=$(lookup OMNIROUTE_API_KEY agent-sidecar/.env)
  if [ -z "$key" ]; then
    warn "OMNIROUTE_API_KEY is unset; the sidecar will only reach keyless models."
  else
    pass "OMNIROUTE_API_KEY is set."
  fi
  if [ -n "$(lookup OMNIROUTE_MCP_API_KEY agent-sidecar/.env)" ]; then
    warn "OMNIROUTE_MCP_API_KEY is set — that key carries manage/admin scope. Confirm you meant to."
  fi
}

check_openhands() {
  echo "profile: openhands"
  check_secret "OH_AGENT_CANVAS_SECRET_KEY" \
    "$(lookup OH_AGENT_CANVAS_SECRET_KEY)" "$PLACEHOLDER_OH_SECRET" 32
  check_bind_host "OPENHANDS_CANVAS_BIND_HOST" "$(lookup OPENHANDS_CANVAS_BIND_HOST)" \
    "This panel is not known to authenticate by default — put TLS + auth in front of it."

  if grep -qE '^[[:space:]]*-[[:space:]]*/var/run/docker\.sock' docker-compose.yml; then
    warn "The Docker socket is mounted into openhands-agent-canvas."
    echo "         That is root-equivalent access to this host. Intentional only if you"
    echo "         decided agent sandboxing is worth it — see docs/integrations/vps-hardening.md."
  else
    pass "Docker socket is not mounted (agents run in-container, no host escalation path)."
  fi
}

check_observability() {
  echo "profile: observability (Langfuse)"
  check_secret "NEXTAUTH_SECRET" \
    "$(lookup NEXTAUTH_SECRET observability/.env)" "$PLACEHOLDER_NEXTAUTH" 32
  check_secret "MINIO_ROOT_PASSWORD" \
    "$(lookup MINIO_ROOT_PASSWORD observability/.env)" "$PLACEHOLDER_MINIO_PASSWORD" 16
  check_secret "SALT" "$(lookup SALT observability/.env)" '' 32
  check_secret "ENCRYPTION_KEY" "$(lookup ENCRYPTION_KEY observability/.env)" '' 64
  check_bind_host "LANGFUSE_WEB_BIND_HOST" "$(lookup LANGFUSE_WEB_BIND_HOST observability/.env)" \
    "Langfuse authenticates, but also offers self-service signup."
  check_bind_host "LANGFUSE_MINIO_BIND_HOST" "$(lookup LANGFUSE_MINIO_BIND_HOST observability/.env)" \
    "That is the object store's S3 API, guarded only by MINIO_ROOT_PASSWORD."
}

# Exercises the pure logic above with known inputs, so CI can prove this
# script actually catches what it claims to without needing a Docker daemon
# or any real secrets.
self_test() {
  local failed=0
  assert_eq() {
    if [ "$2" = "$3" ]; then
      green "  ok    $1"
    else
      red "  FAIL  $1 (expected '$3', got '$2')"
      failed=1
    fi
  }

  echo "self-test: check_secret"
  errors=0; check_secret "T" "" "PLACEHOLDER" >/dev/null;             assert_eq "empty value fails" "$errors" 1
  errors=0; check_secret "T" "PLACEHOLDER" "PLACEHOLDER" >/dev/null;  assert_eq "placeholder fails" "$errors" 1
  errors=0; check_secret "T" "short" "PLACEHOLDER" >/dev/null;        assert_eq "too-short fails" "$errors" 1
  errors=0; check_secret "T" "$(printf 'x%.0s' {1..40})" "PLACEHOLDER" >/dev/null
  assert_eq "good value passes" "$errors" 0

  echo "self-test: check_bind_host"
  warnings=0; check_bind_host "B" "127.0.0.1" "" >/dev/null; assert_eq "loopback passes" "$warnings" 0
  warnings=0; check_bind_host "B" "" "" >/dev/null;          assert_eq "unset defaults to loopback" "$warnings" 0
  warnings=0; check_bind_host "B" "0.0.0.0" "" >/dev/null;   assert_eq "0.0.0.0 warns" "$warnings" 1

  echo "self-test: lookup"
  local tmp; tmp=$(mktemp)
  printf 'FOO=first\nFOO=second\nBAR=value # trailing\n' > "$tmp"
  assert_eq "last assignment wins" "$(lookup FOO "$tmp")" "second"
  assert_eq "inline comment kept (matches Compose)" "$(lookup BAR "$tmp")" "value # trailing"
  FOO=from-env assert_eq "environment beats .env file" "$(FOO=from-env lookup FOO "$tmp")" "from-env"
  rm -f "$tmp"

  if [ "$failed" -eq 0 ]; then
    green "self-test passed"
    return 0
  fi
  red "self-test FAILED"
  return 1
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
  fi

  if [ "$#" -eq 0 ]; then
    echo "usage: $0 <profile> [profile...]   (base | agent-sidecar | openhands | observability)" >&2
    echo "       $0 --self-test" >&2
    exit 2
  fi

  # Run from the repo root so the relative paths above resolve regardless of
  # where the operator invoked this from.
  cd "$(dirname "$0")/.."

  echo "STAX preflight — profiles: $*"
  echo
  for profile in "$@"; do
    case "$profile" in
      base)          check_base ;;
      agent-sidecar) check_agent_sidecar ;;
      openhands)     check_openhands ;;
      observability) check_observability ;;
      *) fail "unknown profile '$profile'" ;;
    esac
    echo
  done

  if [ "$errors" -gt 0 ]; then
    red "$errors blocking problem(s), $warnings warning(s). Not safe to deploy as-is."
    exit 1
  fi
  if [ "$warnings" -gt 0 ]; then
    yellow "$warnings warning(s), no blocking problems. Review them, then deploy."
    exit 0
  fi
  green "All checks passed."
}

main "$@"
