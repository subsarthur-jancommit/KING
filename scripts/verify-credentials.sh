#!/bin/sh
# Prove every credential this deployment holds still works. Run it after any
# rotation, before deciding the rotation is done.
#
# Why this exists. A revoked key does not announce itself. Measured 2026-09-05:
# an invalid OMNIROUTE_MCP_API_KEY produces `TimeoutError` after 30 seconds,
# not `403 invalid key` — so the natural reading is "the gateway is down" and
# the first ten minutes go to debugging the wrong component. Worse, the sidecar
# stays healthy through it: with OmniRoute's MCP key dead it keeps the code
# graph's four tools, answers /healthz, and serves runs. "Nothing looks broken"
# is not evidence a rotation worked.
#
# Every check makes a real call. Nothing here reads a key and reports that it
# is non-empty, which is the check that always passes.
#
# Usage:
#   ./scripts/verify-credentials.sh          # from the repo root on the VPS
set -eu

BASE="${OMNIROUTE_BASE_URL:-http://localhost:20128}"
SIDECAR="${AGENT_SIDECAR_URL:-http://127.0.0.1:8100}"
CODEGRAPH="${CODEGRAPH_URL:-http://localhost:8130}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

failures=0
fail() { red   "  FAIL  $*"; failures=$((failures + 1)); }
pass() { green "  ok    $*"; }
skip() { yellow "  skip  $*"; }

# Values are read from the gitignored .env files and never printed. A key that
# leaks into a terminal during the very operation meant to secure it would be
# an unusually bad outcome.
lookup() {
  var="$1" file="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${var}=//p" "$file" | tail -n 1
}

echo "credential check — every line below is a real call, not a presence test"
echo

# ---------------------------------------------------------------- inference key
key=$(lookup OMNIROUTE_API_KEY agent-sidecar/.env)
if [ -z "$key" ]; then
  skip "OMNIROUTE_API_KEY not set in agent-sidecar/.env"
else
  code=$(curl -s -o /dev/null -m 60 -w '%{http_code}' -X POST "$BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $key" \
    -d '{"model":"opencode/big-pickle","max_tokens":400,"messages":[{"role":"user","content":"OK"}]}' \
    || echo 000)
  case "$code" in
    200) pass "OMNIROUTE_API_KEY answers on /v1/chat/completions." ;;
    401|403) fail "OMNIROUTE_API_KEY rejected ($code) — rotated but not updated here." ;;
    *) fail "OMNIROUTE_API_KEY: unexpected $code from $BASE/v1/chat/completions." ;;
  esac
fi

# ------------------------------------------------------------------- MCP key
# `initialize` rather than a plain GET: the MCP surface answers nothing useful
# to an unauthenticated GET, so only a real handshake distinguishes a live key
# from a dead one.
mcp_probe() {
  url="$1" bearer="$2"
  curl -s -o /dev/null -m 45 -w '%{http_code}' -X POST "$url" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $bearer" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
    || echo 000
}

key=$(lookup OMNIROUTE_MCP_API_KEY agent-sidecar/.env)
if [ -z "$key" ]; then
  skip "OMNIROUTE_MCP_API_KEY not set — the agent will hold no OmniRoute tools."
else
  code=$(mcp_probe "$BASE/api/mcp/stream" "$key")
  case "$code" in
    200) pass "OMNIROUTE_MCP_API_KEY completes an MCP initialize (manage scope intact)." ;;
    401|403) fail "OMNIROUTE_MCP_API_KEY rejected ($code) — the agent will lose its OmniRoute tools." ;;
    000) fail "OMNIROUTE_MCP_API_KEY: no response. A revoked key times out rather than 403-ing." ;;
    *) fail "OMNIROUTE_MCP_API_KEY: unexpected $code." ;;
  esac
fi

# ------------------------------------------------------------------ code graph
key=$(lookup GRAPHIFY_API_KEY .env)
if [ -z "$key" ]; then
  skip "GRAPHIFY_API_KEY not set in the root .env — the agent will hold no graph tools."
else
  code=$(mcp_probe "$CODEGRAPH/mcp" "$key")
  case "$code" in
    200) pass "GRAPHIFY_API_KEY completes an MCP initialize against the code graph." ;;
    401|403) fail "GRAPHIFY_API_KEY rejected ($code)." ;;
    *) fail "GRAPHIFY_API_KEY: unexpected $code from $CODEGRAPH/mcp." ;;
  esac
  # This key is now the only thing between a full map of the repository and the
  # public internet, since the graph is served through Caddy.
  code=$(mcp_probe "$CODEGRAPH/mcp" "definitely-not-the-key")
  case "$code" in
    401|403) pass "The code graph rejects a wrong token ($code)." ;;
    200) fail "The code graph ACCEPTED a wrong token — it is effectively public." ;;
    *) fail "The code graph returned $code to a wrong token; could not confirm it rejects." ;;
  esac
fi

# --------------------------------------------------------------- sidecar bearer
key=$(lookup AGENT_SIDECAR_AUTH_TOKEN agent-sidecar/.env)
if [ -z "$key" ]; then
  fail "AGENT_SIDECAR_AUTH_TOKEN is unset — /run answers 503 to everything."
else
  code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' -X POST "$SIDECAR/run" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $key" \
    -d '{"task":""}' || echo 000)
  # An empty task is rejected at validation, which is the point: it proves the
  # bearer was accepted without spending a model call to find out.
  case "$code" in
    400) pass "AGENT_SIDECAR_AUTH_TOKEN accepted (rejected on the empty task, as designed)." ;;
    401) fail "AGENT_SIDECAR_AUTH_TOKEN rejected — Claude's bridge is locked out." ;;
    503) fail "The sidecar reports no token configured; it is refusing every request." ;;
    *) fail "AGENT_SIDECAR_AUTH_TOKEN: unexpected $code from $SIDECAR/run." ;;
  esac

  code=$(curl -s -o /dev/null -m 30 -w '%{http_code}' -X POST "$SIDECAR/run" \
    -H 'Content-Type: application/json' -H 'Authorization: Bearer wrong' \
    -d '{"task":"x"}' || echo 000)
  case "$code" in
    401) pass "A wrong bearer is rejected (401)." ;;
    *) fail "A wrong bearer returned $code instead of 401." ;;
  esac
fi

echo
if [ "$failures" -eq 0 ]; then
  green "all credentials answered."
else
  red "$failures credential check(s) failed."
  exit 1
fi
