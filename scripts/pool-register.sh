#!/usr/bin/env bash
# Register free-tier providers with OmniRoute, and prove each one answers.
#
# The gateway was built to pool many free APIs and, as of 2026-08-30, pooled one:
# zero of the 60 API-key providers in its catalog were connected, and the working
# set was `opencode` plus the local model. This is the tool for closing that gap.
#
# Keys are read from providers.env, which is gitignored and lives only
# on the host. They are never printed, never passed on a command line where `ps`
# could see them, and never leave this machine except to the provider they belong
# to.
#
#   cp providers.env.example providers.env
#   # fill in the keys you have
#   ./scripts/pool-register.sh            # validate, register, prove
#   ./scripts/pool-register.sh --dry-run  # validate only, change nothing
#   ./scripts/pool-register.sh --prove    # skip registration, re-prove what exists
#
# Exit codes: 0 = every provider in the file answered, 1 = at least one did not.
#
# A connection that saves cleanly and then cannot answer is the failure mode this
# deployment keeps producing, so "registered" is never reported as success on its
# own — every provider has to return real content through /v1/chat/completions
# before this script counts it.

set -euo pipefail

cd "$(dirname "$0")/.."

BASE="${OMNIROUTE_BASE_URL:-http://localhost:20128}"
KEYFILE="${POOL_KEYFILE:-providers.env}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

mode="full"
case "${1:-}" in
  --dry-run) mode="dry" ;;
  --prove)   mode="prove" ;;
  "")        ;;
  *) red "Unknown argument: $1"; exit 1 ;;
esac

[ -f "$KEYFILE" ] || {
  red "$KEYFILE not found."
  echo "  cp providers.env.example $KEYFILE   # then fill in the keys you have"
  exit 1
}

COOKIES=$(mktemp)
PROBE_KEY_ID=""
cleanup() {
  # The throwaway /v1 key goes even on failure — a failed run must not leave a
  # live credential behind.
  if [ -n "$PROBE_KEY_ID" ]; then
    curl -sf -b "$COOKIES" -X DELETE "$BASE/api/keys/$PROBE_KEY_ID" >/dev/null 2>&1 || true
  fi
  rm -f "$COOKIES"
}
trap cleanup EXIT

password=$(sed -n 's/^INITIAL_PASSWORD=//p' omniroute/.env 2>/dev/null | tail -1)
[ -n "$password" ] || { red "INITIAL_PASSWORD not found in omniroute/.env."; exit 1; }

json_str() { python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().rstrip("\n")))'; }

# Body goes through a file rather than -d, so neither the password nor any key
# below ever appears in the process list.
login=$(mktemp)
printf '{"password":%s}' "$(printf '%s' "$password" | json_str)" > "$login"
curl -sf -c "$COOKIES" -X POST "$BASE/api/auth/login" \
  -H 'Content-Type: application/json' --data-binary "@$login" >/dev/null || {
    rm -f "$login"; red "Login ke $BASE gagal."; exit 1; }
rm -f "$login"

# One throwaway key, scoped to the minimum needed to send a completion, used for
# every proof below and deleted on exit.
if [ "$mode" != "dry" ]; then
  key_json=$(curl -sf -b "$COOKIES" -X POST "$BASE/api/keys" -H 'Content-Type: application/json' \
    -d '{"name":"pool-register-probe","scopes":["models","routing","health"]}') || {
      red "Could not mint a probe key."; exit 1; }
  PROBE_KEY=$(printf '%s' "$key_json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])')
  PROBE_KEY_ID=$(printf '%s' "$key_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id") or d.get("apiKey",{}).get("id",""))')
fi

printf '%-22s %-12s %-12s %s\n' "PROVIDER" "PRA-CEK" "DAFTAR" "BUKTI"
printf '%-22s %-12s %-12s %s\n' "----------------------" "------------" "------------" "----------------------------"

proved=0
count=0

while IFS='=' read -r provider key; do
  case "$provider" in ''|\#*) continue ;; esac
  key=$(printf '%s' "$key" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  provider=$(printf '%s' "$provider" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$key" ] || continue
  count=$((count + 1))

  valid="-"; registered="-"; proof="-"

  # 1. Catch a mistyped provider id, and nothing more.
  #
  #    /api/providers/validate looked like a key check and is not one. Measured
  #    2026-08-30: a deliberately invalid OpenRouter key came back HTTP 200 with
  #    {"valid":true,"method":null} - `method: null` being the tell that no
  #    validation ran, after which it defaults to true. Reading only the HTTP
  #    status made this script report a junk key as ok: the exact false pass
  #    this repo keeps finding.
  #
  #    What it DOES do reliably is reject an unknown provider id with HTTP 400
  #    and "unsupported": true. Worth keeping, because a typo here would
  #    otherwise surface much later as a routing mystery. Everything else is
  #    settled by the completion in step 3.
  if [ "$mode" != "prove" ]; then
    body=$(mktemp)
    printf '{"provider":"%s","apiKey":%s}' "$provider" "$(printf '%s' "$key" | json_str)" > "$body"
    vr=$(curl -s -b "$COOKIES" -X POST "$BASE/api/providers/validate"       -H 'Content-Type: application/json' --data-binary "@$body" 2>/dev/null || true)
    rm -f "$body"
    valid=$(printf '%s' "$vr" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('tak terbaca'); raise SystemExit
if d.get('unsupported'):
    print('ID SALAH')
elif d.get('valid') is False:
    print('DITOLAK')
elif d.get('method'):
    print('diuji')
else:
    print('tak diuji')
" 2>/dev/null) || valid="tak terbaca"
  fi
  # 2. Register, unless this is a dry run or the key was rejected outright.
  if [ "$mode" = "full" ] && [ "$valid" != "DITOLAK" ] && [ "$valid" != "ID SALAH" ]; then
    body=$(mktemp)
    printf '{"provider":"%s","apiKey":%s,"name":"%s"}' \
      "$provider" "$(printf '%s' "$key" | json_str)" "$provider" > "$body"
    resp=$(curl -s -b "$COOKIES" -X POST "$BASE/api/providers" \
      -H 'Content-Type: application/json' --data-binary "@$body" 2>/dev/null || true)
    rm -f "$body"
    if printf '%s' "$resp" | grep -qi '"error"'; then
      case "$resp" in
        *exist*|*duplicate*|*Duplicate*) registered="sudah ada" ;;
        *) registered="GAGAL" ;;
      esac
    else
      registered="dibuat"
    fi
  fi

  # 3. The only step that counts. Find a model this provider actually serves,
  #    then send a real completion through the gateway and require content back.
  if [ "$mode" != "dry" ] && [ "$registered" != "GAGAL" ] && [ "$valid" != "DITOLAK" ] && [ "$valid" != "ID SALAH" ]; then
    # /v1/models, not /api/models. The latter is a curated management list and
    # returned exactly one openrouter entry while the gateway could actually
    # route 888 of them. Needs the probe key rather than the session cookie.
    model=$(curl -sf -H "Authorization: Bearer $PROBE_KEY" "$BASE/v1/models" 2>/dev/null | python3 -c "
import sys, json
prov = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ms = d.get('data', d.get('models', d if isinstance(d, list) else []))
cand = []
for m in ms:
    mid = m.get('id') or m.get('model') or '' if isinstance(m, dict) else str(m)
    if mid.startswith(prov + '/'):
        cand.append(mid)
# OpenRouter meters free models with a :free suffix; prefer those so a proof
# never spends credit.
free = [c for c in cand if c.endswith(':free')]
print((free or cand or [''])[0])
" "$provider" 2>/dev/null || true)

    if [ -z "$model" ]; then
      proof="tak ada model"
    else
      body=$(mktemp)
      # 400 tokens, not 8. Most free models on OpenRouter are reasoning models:
      # with a small budget they spend all of it thinking, return content null
      # with finish_reason "length", and a probe that only reads content calls a
      # working model dead.
      printf '{"model":"%s","max_tokens":400,"temperature":0,"messages":[{"role":"user","content":"What is 2+2? Answer with just the number."}]}' "$model" > "$body"
      out=$(curl -s -m 120 -X POST "$BASE/v1/chat/completions" \
        -H 'Content-Type: application/json' -H "Authorization: Bearer $PROBE_KEY" \
        --data-binary "@$body" 2>/dev/null || true)
      rm -f "$body"
      content=$(printf '%s' "$out" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ch = (d.get('choices') or [{}])[0]
msg = ch.get('message') or {}
c = (msg.get('content') or '').strip()
# A reasoning model that ran out of budget produced text, just not under
# the content key. Count it: it proves the route works, which is the job
# of this step. Note: no backticks anywhere inside these python3 -c blocks --
# they sit in a double-quoted bash string, so bash runs them as command
# substitution. That printed 'content: command not found' for a while.
if not c and (msg.get('reasoning') or '').strip():
    c = '[reasoning]'
print(c.replace(chr(10), ' ')[:18])
" 2>/dev/null || true)
      if [ -n "$content" ]; then
        proof="MENJAWAB (${model##*/})"
        proved=$((proved + 1))
      else
        proof="DIAM"
      fi
    fi
  fi

  # if, not `A && B`: under set -e a false test in a && list can end the run
  # without a word. Same shape shellcheck flagged as SC2015 elsewhere here.
  printf '%-22s %-12s %-12s %s\n' "$provider" "$valid" "$registered" "$proof"
done < "$KEYFILE"

echo
if [ "$count" -eq 0 ]; then
  yellow "Tidak ada kunci di $KEYFILE. Isi dulu, lalu jalankan lagi."
  exit 1
fi
if [ "$mode" = "dry" ]; then
  dim "Pra-cek saja; tidak ada yang didaftarkan dan tidak ada yang dibuktikan."
  dim "Kolom PRA-CEK tidak memvouch kuncinya — hanya jalankan penuh yang bisa."
  exit 0
fi

# Success is counted, never inferred. An earlier version tallied failure modes
# by name and let "tak ada model" slip through as a pass, announcing that every
# provider had answered when none had.
if [ "$proved" -eq "$count" ]; then
  green "$proved dari $count provider menjawab lewat gerbang. Kolam bertambah."
  exit 0
fi
red "Hanya $proved dari $count provider yang benar-benar menjawab."
echo "  Baris yang tidak bertanda MENJAWAB tidak berguna, termasuk yang berhasil"
echo "  didaftarkan. Koneksi yang tersimpan tapi diam persis bentuk kegagalan yang"
echo "  sudah tiga kali menggigit deployment ini — hapus atau perbaiki, jangan"
echo "  dibiarkan menumpuk di gerbang."
exit 1
