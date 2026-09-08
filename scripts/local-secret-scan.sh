#!/bin/sh
# Ask the on-host model whether a file contains credentials, without the file
# leaving the machine.
#
# This is the first thing on this deployment to actually USE the local-only
# path, rather than describe it. §4 of docs/king-system.md spent a lot of words
# proving that path can be held; a capability nothing exercises is a claim.
#
#
# WHY IT DOES NOT GO THROUGH THE GATEWAY
#
# It would be natural to POST to OmniRoute with `model=ollama/...` and check
# `served_by` afterwards. That is exactly wrong for this job. The gateway
# classifies intent from the prompt and can reroute to Google — measured, see
# §4 — and the reroute happens BEFORE anything comes back. By the time
# `served_by` says `gemini`, the secrets are already at a third party.
#
# For work that must not leave the host you cannot route it through a component
# that is allowed to decide otherwise. So this talks to the Ollama container
# directly on the compose network. There is no gateway code path here at all,
# and no configuration that could introduce one.
#
# The container is resolved through compose rather than by a hardcoded address:
# container IPs move, and a stale IP that happens to answer is a worse failure
# than one that does not.
#
#
# WHERE THE MODEL EARNS ITS PLACE, AND WHERE IT DOES NOT
#
# Known credential shapes are found with patterns, not a model — `sk-...`,
# `AKIA...`, a JWT, a connection string with a password in it. Handing those to
# a 1.5B model would be slower and worse, and this repo already has the rule:
# a model earns its place only where the mapping from input to output cannot be
# written down in advance (see the gateway_monitor severity comment).
#
# What cannot be written down in advance is the rest. A regex for `password=`
# misses `postgres://user:pw@host`; a regex for that misses the next shape.
# So the deterministic pass reports what it knows, and the model is asked only
# about the lines it did NOT match — "is this a credential that would matter if
# it leaked?" — which is a judgement across shapes nobody enumerated.
#
#
# IT NEVER PRINTS A SECRET
#
# Every value is masked before it reaches the terminal. A scanner that prints
# what it finds has moved the secret into your scrollback, your terminal
# history, and any CI log that captured it. Finding it is the job; displaying it
# is not.
#
# Usage:
#   ./scripts/local-secret-scan.sh                 # this deployment's usual suspects
#   ./scripts/local-secret-scan.sh path [path...]  # specific files
#   ./scripts/local-secret-scan.sh --self-test     # fixtures, no host secrets, no model
#   ./scripts/local-secret-scan.sh --eval          # score the prompt on labelled lines
#   SCAN_PROMPT=c ./scripts/local-secret-scan.sh --eval    # score a variant
#
# Env:
#   SCAN_MODEL          default qwen2.5:1.5b-instruct-q4_K_M
#   SCAN_MAX_JUDGED     default 40 lines sent to the model (it is ~2 s each)
#   SCAN_NO_MODEL=1     deterministic pass only
set -eu

EVAL_MODE=0
[ "${1:-}" = "--eval" ] && { EVAL_MODE=1; shift; }

MODEL="${SCAN_MODEL:-qwen2.5:1.5b-instruct-q4_K_M}"
MAX_JUDGED="${SCAN_MAX_JUDGED:-40}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

cd "$(dirname "$0")/.."

# Known shapes. Deliberately conservative: each one is a thing that is a
# credential when it appears, not a thing that sometimes is.
KNOWN_PATTERNS='(sk-[A-Za-z0-9_-]{20,}|oma_[A-Za-z0-9_]{16,}|tk_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[a-z0-9+]+://[^:/@[:space:]]+:[^@[:space:]]+@)'

# Values that are meant to be seen. Matching one suppresses a finding, so this
# list is the one place a false negative can be introduced on purpose — keep it
# to strings nobody would ship as a live secret.
PLACEHOLDER='(CHANGEME|changeme|your[-_]|example|EXAMPLE|placeholder|PLACEHOLDER|xxxxx|<[^>]+>|\.\.\.|TODO|dummy|not-a-real|test-token)'

mask() {
    # first 3 and last 2 characters, length in between. Enough to recognise a
    # value you already know, useless to anyone who does not.
    awk '{
        n = length($0)
        if (n <= 8) { print "***(" n " chars)" }
        else { print substr($0,1,3) "***" substr($0,n-1,2) "(" n " chars)" }
    }'
}

# The few-shot prompt, as a named variant so it can be scored rather than
# tweaked.
#
# 2026-09-08, and this is why --eval exists. The first real run called
# ACTIVEPIECES_PUBLIC_DOMAIN a secret, so I added a hostname example — the
# obvious fix. It made the model answer SECRET to ALL EIGHT lines it was given,
# including a bare http:// URL. One observation, one edit, strictly worse, and
# the only reason I know is that I re-ran it.
#
# So the variants stay, and the default is whichever one scores best on the
# labelled set below. "Improving a prompt without a score" is already an entry
# in docs/king-mistakes.md; this is the same mistake caught one step earlier.
#
# Scored 2026-09-08, 12 labelled lines, temperature 0:
#
#     a  10/12   the original
#     b   9/12   the "obvious fix" — worse than what it replaced
#     c  11/12   default
#
# Note what a and b got wrong: PORT= and LOG_LEVEL=, which are examples inside
# their own prompts. Balancing the examples 2 SAFE / 2 SECRET fixed it, so the
# problem was never the missing hostname — it was that a majority-SAFE prompt
# gives a 1.5B model a bias to answer with the majority label. c's one
# remaining error is ALERT_TOPIC, and that one is genuinely arguable: a topic
# name is only a secret because of how this deployment uses it.
build_prompt() {
    _line="$1"
    case "${SCAN_PROMPT:-c}" in
        b)  # 4 examples, 3 of them SAFE. Measured worse: it collapses to
            # answering SECRET for everything.
            printf 'Answer with one word: SECRET or SAFE.\n\nLine: PORT=8080\nAnswer: SAFE\n\nLine: AWS_SECRET=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY\nAnswer: SECRET\n\nLine: PUBLIC_DOMAIN=app.example.com\nAnswer: SAFE\n\nLine: LOG_LEVEL=debug\nAnswer: SAFE\n\nLine: %s\nAnswer:' "$_line" ;;
        c)  # 4 examples, balanced 2/2, with a hostname AND a second secret so
            # the label is not correlated with position or majority.
            printf 'Answer with one word: SECRET or SAFE.\n\nLine: PORT=8080\nAnswer: SAFE\n\nLine: AWS_SECRET=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY\nAnswer: SECRET\n\nLine: PUBLIC_DOMAIN=app.example.com\nAnswer: SAFE\n\nLine: DB_PASSWORD=hunter2correcthorse\nAnswer: SECRET\n\nLine: %s\nAnswer:' "$_line" ;;
        *)  # 3 examples, 2 SAFE 1 SECRET. The original.
            printf 'Answer with one word: SECRET or SAFE.\n\nLine: PORT=8080\nAnswer: SAFE\n\nLine: AWS_SECRET=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY\nAnswer: SECRET\n\nLine: LOG_LEVEL=debug\nAnswer: SAFE\n\nLine: %s\nAnswer:' "$_line" ;;
    esac
}

# One line in, SECRET / SAFE / __UNREADABLE__ out. `temperature 0` so a rerun
# of --eval measures the prompt and not the sampler.
judge_line() {
    _body=$(build_prompt "$1" | python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"prompt":sys.stdin.read(),"stream":False,"options":{"temperature":0,"num_predict":4}}))' "$MODEL")
    printf '%s' "$_body" | curl -s -m 120 -X POST "$OLLAMA/api/generate" \
        -H 'Content-Type: application/json' --data-binary @- 2>/dev/null \
      | python3 -c 'import json,sys
try:
    print((json.load(sys.stdin).get("response") or "").strip().upper())
except Exception:
    print("__UNREADABLE__")' || echo "__UNREADABLE__"
}

# ---------------------------------------------------------------- self-test

if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT INT TERM
    cat > "$tmp/fixture.env" <<'FIXTURE'
OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz012345
ADMIN_PASSWORD=CHANGEME
DATABASE_URL=postgresql://appuser:s3cr3tpw@db.example.net:5432/app
PORT=8080
NOTE=this line has no credential at all
FIXTURE
    fails=0
    check() {
        if printf '%s' "$2" | grep -Eq "$3"; then
            printf '  ok    %s\n' "$1"
        else
            printf '  FAIL  %s\n' "$1"; fails=$((fails + 1))
        fi
    }
    refute() {
        if printf '%s' "$2" | grep -Eq "$3"; then
            printf '  FAIL  %s\n' "$1"; fails=$((fails + 1))
        else
            printf '  ok    %s\n' "$1"
        fi
    }

    echo "self-test (fixtures only; no host files and no model are touched)"

    hits=$(grep -nE "$KNOWN_PATTERNS" "$tmp/fixture.env" || true)
    check "an sk- key is a known shape"            "$hits" 'sk-abcdef'
    check "a URL with an inline password is too"   "$hits" 'postgresql://'
    refute "a plain PORT= line is not"             "$hits" 'PORT=8080'
    refute "prose without a credential is not"     "$hits" 'no credential at all'

    ph=$(printf 'CHANGEME' | grep -E "$PLACEHOLDER" || true)
    check "CHANGEME is recognised as a placeholder" "$ph" 'CHANGEME'
    real=$(printf 's3cr3tpw' | grep -E "$PLACEHOLDER" || true)
    refute "a real-looking value is not"            "$real" 's3cr3tpw'

    m=$(printf 'sk-abcdefghijklmnopqrstuvwxyz012345' | mask)
    check "masking keeps a recognisable prefix"     "$m" '^sk-\*\*\*'
    refute "masking drops the middle"               "$m" 'ghijklmnop'
    short=$(printf 'abc' | mask)
    refute "a short value shows nothing at all"     "$short" 'abc'

    echo
    if [ "$fails" -eq 0 ]; then
        green "self-test passed"
        exit 0
    fi
    red "$fails self-test check(s) failed"
    exit 1
fi

# ------------------------------------------------------- the local model only

# Resolved through compose, never hardcoded. `|| true` because `set -e` would
# end the script on a missing profile, and a missing profile is a case this
# handles rather than crashes on.
cid=$(docker compose --profile localmodel ps -q ollama 2>/dev/null || true)
if [ -z "$cid" ]; then
    red "The localmodel profile is not running."
    echo "This tool has no remote fallback on purpose: the whole point is that"
    echo "the content never leaves this host. Start it and re-run:"
    echo "  docker compose --profile localmodel up -d ollama"
    exit 1
fi
ip=$(docker inspect "$cid" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
[ -n "$ip" ] || { red "Could not resolve the Ollama container's address."; exit 1; }
OLLAMA="http://$ip:11434"

tags=$(curl -s -m 10 "$OLLAMA/api/tags" 2>/dev/null || true)
case "$tags" in
    *"$MODEL"*) : ;;
    "") red "Ollama did not answer at $OLLAMA."; exit 1 ;;
    *) red "Ollama is up but does not have $MODEL loaded."
       echo "  present: $(printf '%s' "$tags" | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/  \1/p' | head -5)"
       exit 1 ;;
esac

# --------------------------------------------------------------- --eval
#
# A labelled set, so a prompt change is a measurement rather than a hunch.
# Every value here is synthetic: this file is committed, and a scanner whose
# own fixtures are real credentials would be a joke.
#
# The SAFE rows are the ones that actually cost precision on this deployment —
# domains, URLs and model ids all look long and assigned, which is most of what
# a naive prompt keys on.
if [ "${EVAL_MODE:-0}" = "1" ]; then
    set -- \
      "SAFE|PORT=8080" \
      "SAFE|LOG_LEVEL=debug" \
      "SAFE|PUBLIC_DOMAIN=gateway.example.co" \
      "SAFE|BASE_URL=http://localhost:20128" \
      "SAFE|OLLAMA_MODEL=qwen2.5:1.5b-instruct-q4_K_M" \
      "SAFE|MEM_LIMIT=2560m" \
      "SAFE|BIND_HOST=127.0.0.1" \
      "SECRET|API_KEY=1d7f3a9c2b8e4d6f0a1c3e5b7d9f2a4c6e8b0d1f3a5c7e9b" \
      "SECRET|HMAC_SECRET=49a2c8e0b6d4f1a3c5e7b9d0f2a4c6e8b1d3f5a7c9e0b2d4" \
      "SECRET|DB_PASSWORD=tr0ub4dor-and-three" \
      "SECRET|ALERT_TOPIC=svc-7de10643c02204f21d3d" \
      "SECRET|ADMIN_PASSWORD=Qv8mLp2xRt6wYz4nKc0e"
    total=0; right=0; unread=0
    # Same default as build_prompt, or the report names a variant it did not
    # run — which is how a scored result becomes a wrong one.
    echo "prompt variant '${SCAN_PROMPT:-c}' against ${#} labelled line(s)"
    for row in "$@"; do
        want=${row%%|*}
        line=${row#*|}
        got=$(judge_line "$line")
        total=$((total + 1))
        case "$got" in
            SECRET*) got=SECRET ;;
            SAFE*)   got=SAFE ;;
            *)       got=UNREADABLE; unread=$((unread + 1)) ;;
        esac
        if [ "$got" = "$want" ]; then
            right=$((right + 1))
        else
            printf '  wrong  want %-6s got %-10s %s\n' "$want" "$got" "${line%%=*}="
        fi
    done
    echo
    printf '  %d of %d correct' "$right" "$total"
    [ "$unread" -eq 0 ] || printf ' (%d unreadable)' "$unread"
    printf '\n'
    exit 0
fi

# --------------------------------------------------------------- the targets

if [ "$#" -gt 0 ]; then
    targets="$*"
else
    # This deployment's usual suspects. Every one is gitignored and every one
    # has held a live credential at some point.
    targets=""
    for f in .env omniroute/.env agent-sidecar/.env providers.env \
             .claude/settings.local.json activepieces/.env; do
        [ -f "$f" ] && targets="$targets $f"
    done
fi
[ -n "${targets# }" ] || { yellow "No readable target files."; exit 0; }

echo "local secret scan"
dim "  model    $MODEL"
dim "  endpoint $OLLAMA  (the container directly; no gateway on this path)"
dim "  files   $targets"
echo

# ------------------------------------------------------- pass 1: known shapes

found=0
for f in $targets; do
    [ -f "$f" ] || continue
    grep -nE "$KNOWN_PATTERNS" "$f" 2>/dev/null | while IFS= read -r line; do
        no=${line%%:*}
        rest=${line#*:}
        val=$(printf '%s' "$rest" | grep -oE "$KNOWN_PATTERNS" | head -1)
        printf '%s' "$rest" | grep -Eq "$PLACEHOLDER" && continue
        printf '  %-34s %-22s %s\n' "$f:$no" "known shape" "$(printf '%s' "$val" | mask)"
    done
done | sort | tee /tmp/.lss.$$ 2>/dev/null || true
if [ -s "/tmp/.lss.$$" ]; then found=$(wc -l < "/tmp/.lss.$$"); fi
rm -f "/tmp/.lss.$$"
[ "$found" -gt 0 ] || dim "  (no known credential shapes)"

# --------------------------------------------- pass 2: the model, on the rest

if [ "${SCAN_NO_MODEL:-0}" = "1" ]; then
    echo
    yellow "SCAN_NO_MODEL=1 — the judgement pass was skipped."
    exit 0
fi

echo
echo "asking the on-host model about lines the patterns did not match"

# Only lines that assign something non-trivial. Sending every line of every
# file to a 1.5B model at ~2 s a line would take longer than anyone will wait,
# and the cap is reported rather than applied silently.
cand=$(mktemp)
trap 'rm -f "$cand"' EXIT INT TERM
for f in $targets; do
    [ -f "$f" ] || continue
    grep -nE '^[^#]*[=:][[:space:]]*[^[:space:]]{12,}' "$f" 2>/dev/null \
      | grep -Ev "$KNOWN_PATTERNS" \
      | grep -Ev "$PLACEHOLDER" \
      | sed "s|^|$f:|" || true
done > "$cand"

total=$(wc -l < "$cand" | tr -d ' ')
judged=0
flagged=0
if [ "$total" -eq 0 ]; then
    dim "  (nothing left to judge)"
else
    [ "$total" -le "$MAX_JUDGED" ] \
      || yellow "  $total candidate line(s); judging the first $MAX_JUDGED (SCAN_MAX_JUDGED)"
    while IFS= read -r entry; do
        [ "$judged" -lt "$MAX_JUDGED" ] || break
        judged=$((judged + 1))
        f=${entry%%:*}
        rest=${entry#*:}
        no=${rest%%:*}
        text=${rest#*:}
        # Few-shot and single-word, which is the shape this model scored 87% on.
        # An open question would get a paragraph back and a parse that guesses.
        ans=$(judge_line "$text")
        case "$ans" in
            SECRET*)
                flagged=$((flagged + 1))
                val=$(printf '%s' "$text" | sed 's/^[^=:]*[=:][[:space:]]*//')
                printf '  %-34s %-22s %s\n' "$f:$no" "model says SECRET" "$(printf '%s' "$val" | mask)"
                ;;
            SAFE*) : ;;
            *)
                # An instrument that cannot read must say so, not answer SAFE.
                yellow "  $f:$no  unreadable answer from the model — treat as unknown"
                ;;
        esac
    done < "$cand"
    dim "  judged $judged of $total candidate line(s)"
fi

echo
green "Nothing left this host. The only endpoint contacted was $OLLAMA."
if [ "$((found + flagged))" -gt 0 ]; then
    echo "$((found + flagged)) finding(s). Values are masked above by design;"
    echo "open the file itself to see one."
    exit 1
fi
green "No credentials found in the scanned files."
exit 0
