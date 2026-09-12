#!/usr/bin/env bash
# Register the local Ollama model with OmniRoute — and prove it answers.
#
# This exists because the equivalent dashboard flow has a trap in it. For
# self-hosted providers OmniRoute resolves the URL as
#
#   credentials?.providerSpecificData?.baseUrl || localDefault
#   (omniroute/open-sse/executors/default.ts:319-322)
#
# and `ollama-local`'s localDefault is http://localhost:11434/v1
# (omniroute/src/shared/constants/providers/local.ts:41). Inside the gateway
# container, localhost IS the gateway. So an operator who clicks through the
# dashboard without typing a Base URL gets a connection that saves cleanly,
# looks connected, and refuses every request with something indistinguishable
# from "Ollama is down". Scripting it removes the chance to get that wrong.
#
#   ./scripts/localmodel-register.sh          # register, then prove
#   ./scripts/localmodel-register.sh --verify # prove only, change nothing
#
# Exit codes: 0 = the gateway really answered from the local model, 1 = it did not.

set -euo pipefail

cd "$(dirname "$0")/.."

BASE="${OMNIROUTE_BASE_URL:-http://localhost:20128}"
MODEL="${OLLAMA_MODEL:-$(sed -n 's/^OLLAMA_MODEL=//p' .env 2>/dev/null | tail -1)}"
# No second default here, and the reason is not style.
#
# This line read `qwen2.5:3b-instruct-q4_K_M` while docker-compose.yml pulled
# `qwen2.5:1.5b-instruct-q4_K_M`. Two defaults, in two files, that nothing
# compared. The register script therefore told the gateway about a model Ollama
# did not have, and the model Ollama DID have was never registered — so the
# gateway answered 404 for `ollama/qwen2.5:3b-...` (not pulled) AND for
# `ollama/qwen2.5:1.5b-...` (not registered). Measured 2026-09-12: zero ollama
# rows in the last 1000 gateway call-log entries, and F-6 green throughout
# because it deliberately tests the container directly and never the gateway.
#
# compose is what actually PULLS the model, so compose decides which one exists.
# Reading its default here means the two cannot disagree again.
MODEL="${MODEL:-$(sed -n 's/.*OLLAMA_MODEL:-\([^}]*\)}.*/\1/p' docker-compose.yml | head -1)}"
if [ -z "$MODEL" ]; then
  red "No OLLAMA_MODEL in .env and none derivable from docker-compose.yml."
  red "Registering a guessed name is how the gateway came to advertise a model"
  red "that does not exist. Set OLLAMA_MODEL and re-run."
  exit 1
fi
OLLAMA_URL="${OLLAMA_INTERNAL_URL:-http://ollama:11434/v1}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

COOKIES=$(mktemp)
TMPKEY_ID=""
cleanup() {
  # Always remove the throwaway key, including on failure — otherwise a failed
  # run leaves a live /v1 credential behind, which is a worse outcome than the
  # failure it was diagnosing.
  if [ -n "$TMPKEY_ID" ]; then
    curl -sf -b "$COOKIES" -X DELETE "$BASE/api/keys/$TMPKEY_ID" >/dev/null 2>&1 || true
  fi
  rm -f "$COOKIES"
}
trap cleanup EXIT

# The admin password, preferring the variable that tracks the CURRENT one.
#
# INITIAL_PASSWORD is a bootstrap value: OmniRoute seeds the stored hash from it
# on first boot and never reads it again. Every script here treated it as the
# live credential, so when the admin password was reset on 2026-09-04 all four
# of them started failing with "Login gagal" and nothing said why — the variable
# they read was still present, still non-empty, and no longer true.
#
# OMNIROUTE_ADMIN_PASSWORD is the current one. INITIAL_PASSWORD stays as the
# fallback because it is correct whenever the password has never been changed,
# which is the case in CI, where the workflow writes it before first boot.
password=$(sed -n 's/^OMNIROUTE_ADMIN_PASSWORD=//p' omniroute/.env 2>/dev/null | tail -1)
[ -n "$password" ] || password=$(sed -n 's/^INITIAL_PASSWORD=//p' omniroute/.env 2>/dev/null | tail -1)
if [ -z "$password" ]; then
  red "No admin password in omniroute/.env — set OMNIROUTE_ADMIN_PASSWORD (or"
  red "INITIAL_PASSWORD if the password has never been changed)."
  exit 1
fi

curl -sf -c "$COOKIES" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d "$(printf '{"password":%s}' "$(printf '%s' "$password" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")" \
  >/dev/null || { red "Login failed against $BASE."; exit 1; }

if [ "${1:-}" != "--verify" ]; then
  echo "Registering ollama-local with baseUrl=$OLLAMA_URL …"
  # `ollama-local` is category "local", which is in
  # MANAGED_PROVIDER_CONNECTION_CATEGORIES (src/lib/providers/catalog.ts:180),
  # so POST /api/providers accepts it. No apiKey: providerAllowsOptionalApiKey
  # returns true for self-hosted chat providers.
  body=$(printf '{"provider":"ollama-local","name":"ollama-local","providerSpecificData":{"baseUrl":"%s"}}' "$OLLAMA_URL")
  resp=$(curl -s -b "$COOKIES" -X POST "$BASE/api/providers" \
    -H 'Content-Type: application/json' -d "$body")
  if printf '%s' "$resp" | grep -q '"error"'; then
    # A duplicate is fine — this script is meant to be safe to re-run.
    if printf '%s' "$resp" | grep -qi 'exist\|duplicate'; then
      yellow "A connection already exists; leaving it alone and verifying instead."
    else
      red "Registration failed: $resp"
      exit 1
    fi
  else
    green "Registered."
  fi
fi

# Everything above can succeed against a misconfigured base URL. Only a real
# completion through the gateway proves the chain, so the script does not exit
# 0 without one.
echo "Minting a throwaway /v1 key to prove the route …"
key_json=$(curl -sf -b "$COOKIES" -X POST "$BASE/api/keys" \
  -H 'Content-Type: application/json' \
  -d '{"name":"localmodel-verify","scopes":["models","routing","health"]}')
TMPKEY=$(printf '%s' "$key_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])')
TMPKEY_ID=$(printf '%s' "$key_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id") or d.get("apiKey",{}).get("id",""))')

echo "Asking $MODEL through the gateway …"
start=$(date +%s)
out=$(curl -s -m 180 -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TMPKEY" \
  -d "$(printf '{"model":"ollama/%s","messages":[{"role":"user","content":"Reply with exactly one word: OK"}],"max_tokens":16}' "$MODEL")")
elapsed=$(( $(date +%s) - start ))

content=$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
c = (d.get("choices") or [{}])[0].get("message", {}).get("content")
print(c or "")
' 2>/dev/null)

if [ -z "$content" ]; then
  red "The gateway did not return content in ${elapsed}s."
  printf '%s\n' "$out" | head -c 600
  echo
  red "Most likely the connection's Base URL is still localDefault"
  red "(http://localhost:11434/v1), which from inside the gateway container is"
  red "the gateway itself. Check the connection in /dashboard/providers."
  exit 1
fi

green "The local model answered through OmniRoute in ${elapsed}s: $(printf '%s' "$content" | head -c 80)"
