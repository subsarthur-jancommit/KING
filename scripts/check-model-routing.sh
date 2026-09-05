#!/bin/sh
# Is the gateway still overriding the model you asked for?
#
# Measured 2026-09-05: OmniRoute switches routing strategy on prompt *content*.
# A request naming a model directly is honoured for a plain prompt and
# rerouted for one that states an intent to reason or write code — the shape
# every agent system prompt has. Two consequences:
#
#   - a request naming `ollama/...` can be served by a third-party provider, so
#     "this work stays on the host" is conditional
#   - a key's `allowed_models` is not enforced on the rerouted path: a key
#     permitted only the local model was served `oc/big-pickle`
#
# The destination is not fixed. On 2026-09-04 every rerouted request landed on
# `oc/big-pickle`; on 2026-09-05, with nothing changed here, both landed on
# `gemini-3.7-flash-high`. So do not look for a particular provider in the
# output — look for the two lines disagreeing.
#
# It lives in `omniroute/`, a vendored subtree this repo must not edit, so
# there is nothing to fix here — only something to watch. Run this after any
# `git subtree pull`, or whenever you want to know whether it still happens.
#
# Usage:
#   ./scripts/check-model-routing.sh                 # from the repo root on the VPS
#   OMNIROUTE_BASE_URL=... ./scripts/check-model-routing.sh
set -eu

BASE="${OMNIROUTE_BASE_URL:-http://localhost:20128}"
MODEL="${CHECK_MODEL:-ollama/qwen2.5:1.5b-instruct-q4_K_M}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

key=$(sed -n 's/^OMNIROUTE_API_KEY=//p' agent-sidecar/.env 2>/dev/null | tail -n 1)
[ -n "$key" ] || { echo "OMNIROUTE_API_KEY not found in agent-sidecar/.env" >&2; exit 1; }

# The local model is the probe on purpose: it is the one destination the
# reroute never selects, so "served by something else" is unambiguous. Probing
# with a model the reroute happens to land on cannot tell enforcement from
# coincidence — that mistake is entry 19 in docs/king-mistakes.md.
probe() {
    label="$1"
    system="$2"
    if [ -n "$system" ]; then
        payload=$(printf '{"model":"%s","max_tokens":60,"messages":[{"role":"system","content":"%s"},{"role":"user","content":"Reply with exactly: OK"}]}' "$MODEL" "$system")
    else
        payload=$(printf '{"model":"%s","max_tokens":60,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}' "$MODEL")
    fi
    provider=$(curl -s -m 240 -D - -o /dev/null -X POST "$BASE/v1/chat/completions" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer $key" \
        -d "$payload" 2>/dev/null \
        | awk 'tolower($1) == "x-omniroute-provider:" { gsub(/\r/, "", $2); print $2 }')
    [ -n "$provider" ] || provider="(no header — request failed?)"
    # To stderr on purpose. The caller captures this function's stdout, so a
    # readable line printed there lands inside the command substitution, where
    # `tail -n 1` discarded it and the operator saw the verdict with no working.
    printf '  %-22s provider=%s\n' "$label" "$provider" >&2
    echo "$provider"
}

echo "model routing check — asking for $MODEL"
echo

plain=$(probe "plain prompt" "")
agent=$(probe "agent-shaped prompt" "At each step, explain your reasoning.")

echo
if [ "$plain" = "$agent" ]; then
    green "Both prompts were served by '$plain'."
    green "The content-based override is NOT reproducing. Re-read docs/king-system.md 5b"
    green "and the open-items rows before deciding it is fixed — one probe is not a proof."
    exit 0
fi

red "The override is still present."
red "  plain prompt        -> $plain"
red "  agent-shaped prompt -> $agent"
echo
echo "The second request named a model on this host and was served elsewhere."
echo "Treat per-key model restrictions as cost control, not as a boundary, and"
echo "check 'served_by' (sidecar) or 'x-omniroute-provider' (/v1) on anything"
echo "that must not leave the machine."
exit 1
