#!/bin/sh
# Build (or update) the `paid-first` combo: spend the paid keys you bought, and
# degrade to free and then local capacity instead of failing.
#
# Why this exists. `auto/*` already works, but it picks one healthy provider and
# stays there — sixteen consecutive `auto` calls all landed on opencode's
# big-pickle and none on OpenRouter. That is correct behaviour for `auto`, and it
# also means buying a DeepSeek or Qwen key does NOT widen what `auto` uses day to
# day: the paid capacity just sits there as unused depth. An explicit combo is
# the only way to say "use the thing I paid for, and fall back if it breaks".
#
# `priority` walks the list in order and moves to the next step only when a step
# ERRORS — not when it is slow, and not to save money. So the order below is a
# preference list, not a budget: step 1 serves essentially every request, and the
# free and local steps exist for the day OpenRouter returns 402 or 5xx.
#
# Exit codes: 0 = the combo exists AND a real completion came back through it,
#             1 = it did not. Never exits 0 on an unproven combo.

set -eu

cd "$(dirname "$0")/.."

BASE="${OMNIROUTE_BASE_URL:-http://localhost:20128}"
COMBO="${COMBO_NAME:-paid-first}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# The ladder, best-first. Edit this list when you buy a key.
#
# A native provider key (a real DeepSeek or Alibaba account, rather than
# OpenRouter reselling them) is addressed WITHOUT the `openrouter/` prefix —
# `deepseek/deepseek-chat` — and needs its own connection registered first.
# Put it above the openrouter rows: it is the cheaper path to the same weights.
TIERS="${COMBO_TIERS:-
openrouter/deepseek/deepseek-v4-pro-0813
openrouter/qwen/qwen3.8-flash
openrouter/inclusionai/ling-3.0-flash-fin:free
opencode/big-pickle
ollama/qwen2.5:1.5b-instruct-q4_K_M
}"

COOKIES=$(mktemp)
WORK=$(mktemp -d)
TMPKEY_ID=""
cleanup() {
  # A failed run must not leave a live /v1 credential behind — that is a worse
  # outcome than the failure being diagnosed.
  if [ -n "$TMPKEY_ID" ]; then
    curl -sf -b "$COOKIES" -X DELETE "$BASE/api/keys/$TMPKEY_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$COOKIES" "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- authenticate
password=$(sed -n 's/^INITIAL_PASSWORD=//p' omniroute/.env 2>/dev/null | tail -1)
if [ -z "$password" ]; then
  red "INITIAL_PASSWORD not found in omniroute/.env — cannot authenticate."
  exit 1
fi
# Through a file, never as an argv element: an argument is world-readable in
# `ps` for as long as curl runs.
printf '%s' "$password" \
  | python3 -c 'import json,sys; print(json.dumps({"password": sys.stdin.read()}))' \
  > "$WORK/login.json"
unset password
if ! curl -sf -c "$COOKIES" -X POST "$BASE/api/auth/login" \
     -H 'Content-Type: application/json' --data @"$WORK/login.json" >/dev/null; then
  red "Login failed against $BASE."
  exit 1
fi
rm -f "$WORK/login.json"

# ------------------------------------------------------- check each tier first
# A combo whose steps were never individually verified hides its own breakage:
# priority routing reports a dead step as a slightly slower success. So probe
# every tier and SAY which are dead — but keep them in the combo anyway.
#
# Dropping a dead tier here was the first version of this script, and it was
# wrong: `priority` already skips a failing step at runtime (measured — a combo
# whose first step was a nonexistent model still answered from step two in
# 2.58s). Excluding it at build time only means a five-minute DeepSeek outage
# silently demotes the model you are paying for, permanently, until someone
# notices and re-runs this. The probe is here to inform you, not to edit the
# ladder behind your back.
if ! curl -sf -b "$COOKIES" -X POST "$BASE/api/keys" \
     -H 'Content-Type: application/json' \
     -d '{"name":"combo-paid-first-probe"}' > "$WORK/key.json"; then
  red "Could not mint a probe key."
  exit 1
fi
TMPKEY=$(WORK="$WORK" python3 -c 'import json,os;print(json.load(open(os.environ["WORK"]+"/key.json"))["key"])')
TMPKEY_ID=$(WORK="$WORK" python3 -c 'import json,os;d=json.load(open(os.environ["WORK"]+"/key.json"));print(d.get("id") or d.get("keyId") or "")')

echo "Checking each tier can actually answer …"
alive=0
total=0
steps=""
for model in $TIERS; do
  total=$((total + 1))
  printf '{"model":"%s","max_tokens":400,"temperature":0,"messages":[{"role":"user","content":"Reply with one word: OK."}]}' \
    "$model" > "$WORK/probe.json"
  if out=$(curl -s -m 120 -X POST "$BASE/v1/chat/completions" \
             -H 'Content-Type: application/json' -H "Authorization: Bearer $TMPKEY" \
             --data @"$WORK/probe.json" 2>/dev/null) \
     && printf '%s' "$out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
m = (d.get("choices") or [{}])[0].get("message") or {}
# Reasoning models return content=None and put the text under `reasoning`;
# scoring that as a failure once cost an afternoon.
sys.exit(0 if (m.get("content") or m.get("reasoning") or "").strip() else 1)
' 2>/dev/null; then
    green "  ok    $model"
    alive=$((alive + 1))
  else
    yellow "  DEAD  $model — kept in the combo; priority will skip it at runtime"
  fi
  steps="$steps$model
"
done

if [ "$alive" -eq 0 ]; then
  red "No tier answered. Refusing to build a combo that cannot serve a request."
  exit 1
fi
echo "  $alive of $total tiers answered."

# ------------------------------------------------------------- create / update
printf '%s' "$steps" | COMBO="$COMBO" python3 -c '
import json, os, sys
models = [l for l in sys.stdin.read().split("\n") if l.strip()]
print(json.dumps({
    "name": os.environ["COMBO"],
    "strategy": "priority",
    "description": "Paid capacity first, then free, then local. Built by scripts/combo-paid-first.sh.",
    "models": models,
}))' > "$WORK/body.json"

existing=$(curl -sf -b "$COOKIES" "$BASE/api/combos" | COMBO="$COMBO" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
cs = d if isinstance(d, list) else d.get("combos", d.get("data", []))
print(next((c.get("id", "") for c in cs if c.get("name") == os.environ["COMBO"]), ""))
' 2>/dev/null || true)

if [ -n "$existing" ]; then
  echo "Updating existing combo $COMBO …"
  resp=$(curl -s -b "$COOKIES" -X PUT "$BASE/api/combos/$existing" \
    -H 'Content-Type: application/json' --data @"$WORK/body.json")
else
  echo "Creating combo $COMBO …"
  resp=$(curl -s -b "$COOKIES" -X POST "$BASE/api/combos" \
    -H 'Content-Type: application/json' --data @"$WORK/body.json")
fi
if printf '%s' "$resp" | grep -q '"error"'; then
  red "Combo write rejected: $(printf '%s' "$resp" | head -c 300)"
  exit 1
fi

# -------------------------------------------------------------------- prove it
# The only check that means anything: route a real request at the combo name and
# require text back. Everything above this line can pass on a broken combo.
echo "Proving $COMBO with a real completion …"
printf '{"model":"%s","max_tokens":400,"temperature":0,"messages":[{"role":"user","content":"What is 2+2? Answer with just the number."}]}' \
  "$COMBO" > "$WORK/prove.json"
out=$(curl -s -m 180 -X POST "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TMPKEY" \
  --data @"$WORK/prove.json" 2>/dev/null)

if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = (d.get("choices") or [{}])[0].get("message") or {}
t = (m.get("content") or m.get("reasoning") or "").strip()
if not t:
    sys.exit(1)
print("  served by:", d.get("model"))
print("  answer   :", t[:60].replace("\n", " "))
' 2>/dev/null; then
  green "$COMBO is live and answered a real request."
  exit 0
fi
red "$COMBO exists but did not answer. Not calling that a success."
printf '  %s\n' "$(printf '%s' "$out" | head -c 300)"
exit 1
