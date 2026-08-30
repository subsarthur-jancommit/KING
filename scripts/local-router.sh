#!/bin/sh
# Route a task to the right ladder, using the local model as the decision layer.
#
# The local model is the only capacity here that costs nothing per call, which
# makes it the right place to decide *how much to spend* on everything else. It
# is NOT the right place to decide provider order — the gateway's `priority`
# combos already do that, correctly, and for free.
#
#   ./scripts/local-router.sh "find the deadlock in this Go worker pool"
#     -> PAID  paid-first
#
#   ./scripts/local-router.sh --eval
#     -> runs the labelled set and reports accuracy; exits 1 below MIN_ACCURACY
#
# Why there is an --eval mode at all. "Make the local model decide better" is
# unfalsifiable without a scored set, and the measurements that produced this
# file show why that matters: the first prompt scored 41% (barely above the 25%
# you get by guessing between four labels), a rewrite took it to 91%, and a
# third version — adding <task> delimiters, which seemed obviously better —
# dropped it back to 67% on the same cases. Delimiters made the model MORE
# likely to perform the task instead of labelling it: it answered `こんにちは`
# to a translation task and emitted ```JSON to a reformatting one. Nothing but
# a scored run would have caught that. Re-run --eval after ANY prompt edit.

set -eu

cd "$(dirname "$0")/.."

BASE="${OMNIROUTE_BASE_URL:-http://localhost:20128}"
MODEL="${ROUTER_MODEL:-ollama/qwen2.5:1.5b-instruct-q4_K_M}"
MIN_ACCURACY="${MIN_ACCURACY:-80}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

COOKIES=$(mktemp)
WORK=$(mktemp -d)
TMPKEY_ID=""
cleanup() {
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

if ! curl -sf -b "$COOKIES" -X POST "$BASE/api/keys" \
     -H 'Content-Type: application/json' \
     -d '{"name":"local-router-probe"}' > "$WORK/key.json"; then
  red "Could not mint a probe key."
  exit 1
fi
TMPKEY=$(WORK="$WORK" python3 -c 'import json,os;print(json.load(open(os.environ["WORK"]+"/key.json"))["key"])')
TMPKEY_ID=$(WORK="$WORK" python3 -c 'import json,os;d=json.load(open(os.environ["WORK"]+"/key.json"));print(d.get("id") or d.get("keyId") or "")')

MODE="classify"
TASK="${1:-}"
if [ "${1:-}" = "--eval" ]; then MODE="eval"; TASK=""; fi
if [ "$MODE" = "classify" ] && [ -z "$TASK" ]; then
  red "Usage: $0 \"<task to route>\"   |   $0 --eval"
  exit 1
fi

BASE="$BASE" MODEL="$MODEL" KEY="$TMPKEY" MODE="$MODE" TASK="$TASK" \
MIN_ACCURACY="$MIN_ACCURACY" python3 <<'PY'
import json, os, sys, time, urllib.request, urllib.error

BASE  = os.environ["BASE"]
MODEL = os.environ["MODEL"]
KEY   = os.environ["KEY"]
MODE  = os.environ["MODE"]
TASK  = os.environ["TASK"]
MIN_ACC = int(os.environ["MIN_ACCURACY"])

VALID = ("LOCAL", "FREE", "PAID", "WEB")

# Which ladder each label spends on. These are combo names that already exist in
# the gateway; the combo decides provider ORDER, this script only decides which
# combo the task deserves.
LADDER = {
    "LOCAL": "ollama/qwen2.5:1.5b-instruct-q4_K_M",
    "FREE":  "free-then-local",
    "PAID":  "paid-first",
    "WEB":   "websearch-tiers",
}

# ---------------------------------------------------------------------------
# The prompt. Measured at 91% (11/12). Do not edit without re-running --eval:
# a version of this with <task> delimiters, which read as an improvement, scored
# 67% on the same cases.
# ---------------------------------------------------------------------------
SYSTEM = """Classify the user's task. Reply with ONE word from this exact list:
LOCAL FREE PAID WEB

LOCAL = mechanical text work with an obvious answer (classify, extract, reformat)
FREE  = ordinary language work (summarize, explain, draft, translate)
PAID  = needs real engineering judgement (write or debug code, design a system)
WEB   = needs a fact from after your training (latest version, price, news)

Examples:
Task: Label this review as spam or not spam
LOCAL
Task: Turn this CSV row into JSON
LOCAL
Task: Summarize this long article
FREE
Task: Write a thank-you note to a customer
FREE
Task: Fix the deadlock in this threading code
PAID
Task: Choose between Postgres and DynamoDB for this workload
PAID
Task: What version of Node shipped last week
WEB
Task: Current price of an EC2 m7g.large
WEB

Reply with one word only."""

# The scored set. Add a row every time the router gets something wrong in real
# use — that is what stops the next prompt edit from silently regressing.
CASES = [
    ("Is this sentence positive or negative: 'the build broke again'", "LOCAL"),
    ("Extract all email addresses from this text block",              "LOCAL"),
    ("Convert this list of names into JSON",                          "LOCAL"),
    ("Summarize this 3-page meeting transcript",                      "FREE"),
    ("Explain what a mutex is to a junior developer",                 "FREE"),
    ("Draft a polite follow-up email about an overdue invoice",       "FREE"),
    ("Find the race condition in this 200-line Go worker pool",       "PAID"),
    ("Design a retry strategy for a flaky payment webhook",           "PAID"),
    ("Refactor this React component to remove prop drilling",         "PAID"),
    ("What is the latest stable version of PostgreSQL?",              "WEB"),
    ("How much does the Anthropic API cost per million tokens today?","WEB"),
    ("Any CVEs reported for nginx this month?",                       "WEB"),
    # Added after the router misrouted these in real use. Short imperative
    # coding tasks read as mechanical to a 1.5B model, so it under-classifies
    # them to LOCAL and the work lands on the weakest capacity in the stack.
    ("Write a bash script to rotate nginx logs weekly",               "PAID"),
    ("Add pagination to this REST endpoint",                          "PAID"),
    ("Write a SQL query joining orders and customers by month",       "PAID"),
]


def classify(task):
    """Return (label, seconds). Label is '' when nothing usable came back."""
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 5,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user",   "content": "Task: " + task},
        ],
    }).encode()
    req = urllib.request.Request(
        BASE + "/v1/chat/completions", data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + KEY})
    t = time.time()
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=90).read().decode())
    except Exception:
        return "", time.time() - t
    m = (d.get("choices") or [{}])[0].get("message") or {}
    raw = (m.get("content") or m.get("reasoning") or "").strip().upper()
    # The model sometimes answers the task instead of labelling it, so scan for
    # a real label rather than trusting the first token.
    for w in raw.replace("\n", " ").split():
        if w.strip(".,:!") in VALID:
            return w.strip(".,:!"), time.time() - t
    return "", time.time() - t


if MODE == "classify":
    label, dt = classify(TASK)
    if not label:
        print("UNCLEAR  — the router did not return a usable label.")
        print("Falling back to free-then-local, which is the safe default:")
        print("free-then-local")
        sys.exit(2)
    print(f"{label}  {LADDER[label]}   ({dt:.1f}s)")
    sys.exit(0)

# --------------------------------------------------------------------- eval
ok = 0
offlabel = 0
lat = []
print(f"Scoring {len(CASES)} cases against {MODEL} …")
for task, want in CASES:
    got, dt = classify(task)
    lat.append(dt)
    if not got:
        offlabel += 1
    hit = (got == want)
    ok += hit
    mark = "ok  " if hit else "MISS"
    print(f"  {mark} want={want:5} got={got or '(none)':7} {dt:4.1f}s  {task[:46]}")

acc = 100 * ok // len(CASES)
print()
print(f"  accuracy: {ok}/{len(CASES)} = {acc}%   (floor: {MIN_ACC}%)")
print(f"  unusable replies: {offlabel}")
print(f"  latency: mean {sum(lat)/len(lat):.2f}s, max {max(lat):.2f}s")
print()
if acc < MIN_ACC:
    print(f"BELOW FLOOR — do not ship this prompt. Routing at {acc}% sends real")
    print("work to the wrong ladder, which costs more than routing nothing.")
    sys.exit(1)
print("Above floor.")
sys.exit(0)
PY
