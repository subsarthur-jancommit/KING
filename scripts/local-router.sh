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
#   ./scripts/local-router.sh --eval        scored run; exit 1 below MIN_ACCURACY
#   ./scripts/local-router.sh --self-test   the trust predicate, no network
#
# ---------------------------------------------------------------------------
# Why this talks to the container and never to the gateway
# ---------------------------------------------------------------------------
# It used to POST to the gateway asking for `ollama/qwen2.5:1.5b-instruct-q4_K_M`
# — and the gateway answered, from `antigravity/gemini-pro-agent`. Recorded
# 2026-09-06 in docs/king-system.md as "the local router is not local", and
# measured again on 2026-09-12 with both paths side by side:
#
#   through the gateway:  15/15 = 100%,  6.90 s mean,  served by antigravity
#   straight to Ollama:   13/15 =  86%,  ~1.0 s,       served by qwen2.5:1.5b
#
# The gateway is ALLOWED to reroute — that is its job, and F-6's comment says
# exactly that. But both premises of a navigator die when it does: it stops
# being free at the margin, and the task description leaves the machine. A 100%
# bought from a paid frontier model is not a measurement of the navigator. It is
# a measurement of the thing the navigator exists to avoid calling.
#
# So there is no gateway on this path and no fallback to one. If the container
# cannot be reached this script fails loudly; it does not quietly buy the answer.
# That also removed the admin login and the probe-key minting this file used to
# do — the direct endpoint needs no credential, so it now reads none.
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
#
# Exit codes: 0 ok · 1 below the accuracy floor · 2 no usable label · 3 the run
# does not belong to the local model, so its score means nothing either way.

set -eu

cd "$(dirname "$0")/.."

MIN_ACCURACY="${MIN_ACCURACY:-80}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }

MODE="classify"
TASK="${1:-}"
case "${1:-}" in
  --eval)      MODE="eval";      TASK="" ;;
  --self-test) MODE="self-test"; TASK="" ;;
esac
if [ "$MODE" = "classify" ] && [ -z "$TASK" ]; then
  red "Usage: $0 \"<task to route>\"   |   $0 --eval   |   $0 --self-test"
  exit 1
fi

# ------------------------------------------------------------- which model
# One source of truth, in the order a reader would check by hand. This file used
# to hardcode the name, `localmodel-register.sh` defaulted to a DIFFERENT one,
# and compose pulled a third — three defaults reconciled only by luck. On
# 2026-09-12 the luck ran out: the gateway advertised a model that had never
# been pulled, every local name answered 404, and nothing noticed for six days.
#
# The name here is the bare Ollama name. The gateway's `ollama/` prefix is a
# gateway concept and appears nowhere on this path — which is also what makes a
# prefixed name, if one ever comes back in a response, proof that we are not
# where we think we are.
MODEL="${ROUTER_MODEL:-}"
[ -n "$MODEL" ] || MODEL=$(sed -n 's/^OLLAMA_MODEL=//p' .env 2>/dev/null | tail -1)
[ -n "$MODEL" ] || MODEL=$(sed -n 's/.*OLLAMA_MODEL:-\([^}]*\)}.*/\1/p' docker-compose.yml 2>/dev/null | head -1)
if [ -z "$MODEL" ] && [ "$MODE" != "self-test" ]; then
  red "No local model name: set ROUTER_MODEL, or OLLAMA_MODEL in .env, or leave"
  red "the OLLAMA_MODEL default in docker-compose.yml where this can read it."
  exit 1
fi

# ------------------------------------------------------------ which endpoint
# F-6 already reaches Ollama this way, and for the same reason: it is the only
# address that cannot be rerouted. It also publishes no port — the container IP
# is reachable from the host without opening anything to the network.
BASE="${ROUTER_BASE_URL:-}"
if [ -z "$BASE" ] && [ "$MODE" != "self-test" ]; then
  cid=$(docker compose --profile localmodel ps -q ollama 2>/dev/null || true)
  if [ -z "$cid" ]; then
    red "The ollama container is not running, and there is deliberately no"
    red "gateway fallback here — see the header. Start it with:"
    red "  docker compose --profile localmodel up -d ollama"
    red "or set ROUTER_BASE_URL if Ollama lives somewhere else."
    exit 1
  fi
  ip=$(docker inspect "$cid" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | awk '{print $1}')
  if [ -z "$ip" ]; then
    red "The ollama container is running but has no network address."
    exit 1
  fi
  BASE="http://$ip:11434"
fi

# `command -v` asks whether the NAME resolves. On Windows it resolves to a
# Microsoft Store stub that prints an advert and exits 49, which is how this
# very line failed its first run. Ask whether the interpreter RUNS instead —
# the same distinction every check in king-audit.sh is built around.
if ! python3 -c "" >/dev/null 2>&1; then
  red "python3 is required, and the python3 on PATH here does not run."
  exit 1
fi

BASE="$BASE" MODEL="$MODEL" MODE="$MODE" TASK="$TASK" \
MIN_ACCURACY="$MIN_ACCURACY" python3 <<'PY'
import json, os, sys, time, urllib.request, urllib.error

BASE  = os.environ["BASE"]
MODEL = os.environ["MODEL"]
MODE  = os.environ["MODE"]
TASK  = os.environ["TASK"]
MIN_ACC = int(os.environ["MIN_ACCURACY"])

# Which model actually answered, taken from the response body. Ollama emits
# `model` only on a 200, and an impossible name gets a 404 with no `model` field
# at all (measured 2026-09-12) — so this reports what served. It is not an echo
# of what was asked.
SERVED = set()

VALID = ("LOCAL", "FREE", "PAID", "WEB")

# Which ladder each label spends on. These are combo names that already exist in
# the gateway; the combo decides provider ORDER, this script only decides which
# combo the task deserves. The LOCAL rung carries the gateway's `ollama/` prefix
# because it is consumed by the gateway — unlike MODEL above, which is not.
LADDER = {
    "LOCAL": "ollama/" + MODEL,
    "FREE":  "free-then-local",
    "PAID":  "paid-first",
    "WEB":   "websearch-tiers",
}


def trust(served, model):
    """Whose score is this? Pure, so --self-test exercises the real predicate.

    'local'   — every answer came from the model we asked for
    'foreign' — something else answered; the score belongs to it, not to us
    'silent'  — nothing answered at all, which is not the same as scoring zero
    """
    names = sorted(n for n in served if n)
    if not names:
        return "silent"
    if [n for n in names if n != model]:
        return "foreign"
    return "local"


if MODE == "self-test":
    # The foreign cases are the positive control. A predicate that can only ever
    # return 'local' would pass every other fixture here and be worth nothing.
    FIXTURES = [
        (set(),                            "m", "silent"),
        ({""},                             "m", "silent"),
        ({"m"},                            "m", "local"),
        ({"m", ""},                        "m", "local"),
        ({"other"},                        "m", "foreign"),
        ({"m", "other"},                   "m", "foreign"),
        # The exact shape of the fault this rewrite closes: a gateway answer,
        # which carries a provider-prefixed name and is never our bare name.
        ({"ollama/m"},                     "m", "foreign"),
        ({"antigravity/gemini-pro-agent"}, "m", "foreign"),
    ]
    bad = 0
    for served, model, want in FIXTURES:
        got = trust(served, model)
        if got != want:
            bad += 1
            print("  FAIL trust(%r, %r) = %s, want %s"
                  % (sorted(served), model, got, want))
    if bad:
        print("%d of %d fixtures failed." % (bad, len(FIXTURES)))
        sys.exit(1)
    print("trust(): %d/%d fixtures pass, including the foreign-provider case."
          % (len(FIXTURES), len(FIXTURES)))
    sys.exit(0)

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
    """Return (label, seconds, note). Label is '' when nothing usable arrived."""
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
        headers={"Content-Type": "application/json"})
    t = time.time()
    try:
        # The first call of a run also loads the weights, so the timeout stays
        # generous even though a warm call answers in about a second.
        resp = urllib.request.urlopen(req, timeout=90)
        d = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        # A 404 here means the model name and the container disagree, which is a
        # different fault from a bad prompt and must not be reported as one.
        return "", time.time() - t, "HTTP %s" % e.code
    except Exception as e:
        return "", time.time() - t, type(e).__name__
    SERVED.add(d.get("model") or "")
    m = (d.get("choices") or [{}])[0].get("message") or {}
    raw = (m.get("content") or m.get("reasoning") or "").strip().upper()
    # The model sometimes answers the task instead of labelling it, so scan for
    # a real label rather than trusting the first token.
    for w in raw.replace("\n", " ").split():
        if w.strip(".,:!") in VALID:
            return w.strip(".,:!"), time.time() - t, ""
    return "", time.time() - t, "no label in reply"


if MODE == "classify":
    label, dt, note = classify(TASK)
    if trust(SERVED, MODEL) == "foreign":
        print("REFUSING — %s answered, not %s."
              % (", ".join(sorted(n for n in SERVED if n)), MODEL))
        print("This path is supposed to be local and free, and something")
        print("rerouted it. See the header of this script.")
        sys.exit(3)
    if not label:
        print("UNCLEAR  — the router returned no usable label (%s)." % (note or "?"))
        print("Falling back to free-then-local, which is the safe default:")
        print("free-then-local")
        sys.exit(2)
    print("%s  %s   (%.1fs)" % (label, LADDER[label], dt))
    sys.exit(0)

# --------------------------------------------------------------------- eval
ok = 0
offlabel = 0
lat = []
print("Scoring %d cases against %s via %s …" % (len(CASES), MODEL, BASE))
for task, want in CASES:
    got, dt, note = classify(task)
    lat.append(dt)
    if not got:
        offlabel += 1
    hit = (got == want)
    ok += hit
    mark = "ok  " if hit else "MISS"
    print("  %s want=%-5s got=%-7s %4.1fs  %s%s"
          % (mark, want, got or "(none)", dt, task[:46],
             (" [%s]" % note) if note else ""))

acc = 100 * ok // len(CASES)
print()
print("  accuracy: %d/%d = %d%%   (floor: %d%%)" % (ok, len(CASES), acc, MIN_ACC))
print("  unusable replies: %d" % offlabel)
print("  latency: mean %.2fs, max %.2fs" % (sum(lat) / len(lat), max(lat)))

# Whose score this is, decided before whether the score is good. A run served by
# anything else is measuring that other model, and a run where nothing answered
# is not a zero, it is an absence. Both are reported ahead of the accuracy,
# because in both cases the accuracy is not evidence about this model.
verdict = trust(SERVED, MODEL)
print("  served by: %s"
      % (", ".join(sorted(n for n in SERVED if n)) or "(nothing answered)"))
print()
if verdict == "foreign":
    print("NOT THIS MODEL'S SCORE — something other than %s answered." % MODEL)
    print("The navigator is only worth having while it is free and on this host,")
    print("so a score bought elsewhere is not a better result. It is a broken one.")
    sys.exit(3)
if verdict == "silent":
    print("NOTHING ANSWERED — this is an absence, not a score of 0%.")
    print("Check that the ollama container is up and holds %s." % MODEL)
    sys.exit(3)
if acc < MIN_ACC:
    print("BELOW FLOOR — do not ship this prompt. Routing at %d%% sends real" % acc)
    print("work to the wrong ladder, which costs more than routing nothing.")
    sys.exit(1)
print("Above floor, and served by the local model.")
sys.exit(0)
PY
