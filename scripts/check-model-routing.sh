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
# The destination is not fixed either, and it moves with the prompt, not with
# time. Measured 2026-09-05 within five minutes, same key, same asked-for model:
# this script's one-line trigger lands on `oc/big-pickle` (6 of 6) while the
# sidecar's full smolagents prompt lands on `gemini-3.7-flash-high` (3 of 3).
# So do not look for a particular provider in the output — look for the two
# lines disagreeing. That is what this checks, and it is why it still works
# when the destination changes.
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
SIDECAR="${AGENT_SIDECAR_URL:-http://127.0.0.1:8100}"

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

# The two probes above use a one-line trigger, which is a proxy for what the
# sidecar sends. Entry 20 in docs/king-mistakes.md is about exactly that gap:
# the destination moves with the prompt, so a number measured with a probe does
# not describe production. This asks the real path, with the real prompt.
#
# Optional: it needs the sidecar up and its token readable. A missing sidecar
# is not a failure of this check — the two probes above already answered the
# question it exists to answer.
sidecar_served=""
tok=$(sed -n 's/^AGENT_SIDECAR_AUTH_TOKEN=//p' agent-sidecar/.env 2>/dev/null | tail -n 1)
if [ -n "$tok" ]; then
    task='{"task":"What is 2 plus 2? Answer with the number only.","model":"'"$MODEL"'"}'
    body=$(curl -s -m 300 -X POST "$SIDECAR/run" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $tok" \
        -d "$task" 2>/dev/null || true)
    sidecar_served=$(printf '%s' "$body" | sed -n 's/.*"served_by":"\([^"]*\)".*/\1/p')
    if [ -n "$sidecar_served" ]; then
        printf '  %-22s served_by=%s\n' "sidecar /run" "$sidecar_served" >&2
    else
        printf '  %-22s no served_by (sidecar down, or the run failed)\n' "sidecar /run" >&2
    fi
fi

echo
# Substring test rather than equality: served_by carries the bare model name,
# and what matters is only whether it is still the local one.
if [ -n "$sidecar_served" ] && [ "${sidecar_served#*qwen}" = "$sidecar_served" ]; then
    red "The production path left the host."
    red "  asked $MODEL, served by $sidecar_served"
    echo
    echo "This is the measurement that matters — the prompt the sidecar really"
    echo "sends, not a probe's approximation of one. The run itself is flagged"
    echo "degraded with a 'local-only work left the host' step error, which is"
    echo "all this repo can do; the routing is in the vendored subtree."
    echo
fi

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
