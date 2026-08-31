# KING — what is built, what works, and what does not

**Verified 2026-08-30 against the live VPS (`34.101.62.94`).** Every number here
was measured, not estimated. Where something is unproven, unmeasured, or broken,
it says so — this document is only useful if it can be trusted when it reports
bad news.

---

## 1. What KING is

One 7.9 GB VPS running three useful things and the guards that keep them honest:

- **OmniRoute** (`gateway.arject.co`) — one OpenAI-compatible API in front of
  1,019 routable models across four providers.
- **Activepieces** (`flows.arject.co`) — six workflows, four of which Claude Code
  can call directly as MCP tools.
- **codegraph** — the repository parsed into 59,278 nodes and 163,294 edges,
  served over MCP so an agent can ask about structure instead of reading files.

The division of labour: **the laptop decides, the VPS does the work.** Claude
Code holds the context and the judgement; KING supplies the cheap capacity that
routine work should be spent on instead.

---

## 2. What is actually running

Eight containers, all healthy at time of writing.

| Container | Role | Profile |
|---|---|---|
| `omniroute-base` | Model gateway | `base` |
| `activepieces` | Workflow engine | `workflow` |
| `ap-redis` | Activepieces queue | `workflow` |
| `ollama` | Local model | `localmodel` |
| `codegraph-serve` | Code graph over MCP | `codegraph` |
| `caddy` | TLS and reverse proxy | `proxy` |
| `otel-collector` | Traces to Langfuse | `tracing` |
| `redis` | Gateway cache | `base` |

**Host budget:** 4,415 MB of 7,936 MB used, 3,520 MB free. Disk 30 GB of 48 GB
(62%).

Every added service is opt-in via `profiles:` and default-off, carries equal
`mem_limit`/`memswap_limit` so it OOMs inside its own cgroup rather than
dragging the host into swap, and pins its image to an exact tag.

---

## 3. Providers available today

Four connections. What matters is not the count but how each one bills, because
that is what decides where work should go.

| Provider | Auth | Cost model | What it gives |
|---|---|---|---|
| **`agy`** (Antigravity CLI) | OAuth | Subscription quota — **no marginal cost per call** | 17 frontier models: Claude Opus 4.6 (4 effort levels), Sonnet 4.6 (4 levels), Gemini 3.1/3.6/3.7 (7 variants), gpt-oss-120b |
| **`openrouter`** | API key | Per token, **balance currently low** | 888 models incl. DeepSeek v4, Qwen 3.8, Perplexity Sonar |
| **`tavily-search`** | API key | **$0.008 per search** | Web search returning page text, not just links |
| **`ollama-local`** | none (local) | Free, runs on this host | `qwen2.5:1.5b-instruct-q4_K_M`, resident, ~0.95 s |

Plus `opencode` (`oc/`), which is keyless and needs no connection at all — eight
free models, no signup, no quota.

**Catalog composition:** 1,019 routable ids — `openrouter/` 888, `no-think/` 54
(a *modifier* prefix, not a provider), `auto/` 38, `agy/` 17, `oc/` 8,
`ollama-local/` 4, plus small video and search entries.

### The economics that shape everything else

`agy` inverted the assumption this system was first built on. It arrives through
an OAuth session against a paid subscription, so **the strongest models in the
stack are also the cheapest marginal call.** The original ladder put DeepSeek at
the top because "paid = best"; that was wrong once `agy` existed.

Two things to know about it:

- **The OAuth token refreshes itself.** Measured: it expired at 14:35, OmniRoute
  refreshed it at 14:33 and moved expiry to 15:28, on the same connection. No
  daily re-login is needed.
- **OmniRoute's own catalog flags it `subscriptionRisk: true`.** Routing traffic
  through a personal Antigravity session is a decision the operator took
  knowingly; Antigravity's actual terms have not been read.

---

## 4. Routing

### Why `auto/*` is not the answer

`auto` ranks by **speed**, and the fastest provider is always the free one.
Sixteen consecutive `auto` calls landed on `opencode/big-pickle`; none reached
OpenRouter or `agy`. That is `auto` working correctly, and it is also why buying
keys does not widen what `auto` serves. Paid capacity just sits there.

### Three explicit combos

All use `priority`: the list is walked in order and only moves on when a step
**errors** — not when it is slow, and not to save money.

```
paid-first          quality work you will actually use
  1. agy/claude-opus-4-6-thinking-high
  2. agy/claude-sonnet-4-6
  3. openrouter/deepseek/deepseek-v4-pro-0813
  4. opencode/big-pickle
  5. ollama/qwen2.5:1.5b-instruct-q4_K_M

free-then-local     bulk work, zero cost
  1. opencode/big-pickle
  2. ollama/qwen2.5:1.5b-instruct-q4_K_M

websearch-tiers     synthesis of search results (retrieval is separate)
  1. agy/claude-opus-4-6-thinking-high
  2. agy/gemini-3.7-flash-high
  3. agy/claude-sonnet-4-6
  4. opencode/big-pickle
  5. ollama/qwen2.5:1.5b-instruct-q4_K_M
```

Fallback is measured, not assumed: a combo whose first step was a nonexistent
model still answered from step two in **2.58 s**.

`scripts/combo-paid-first.sh` builds or updates any of these, probes every tier,
and refuses to exit 0 without a real completion through the combo name. It
**keeps** dead tiers rather than dropping them — priority already skips a failing
step at runtime, so excluding one at build time would let a five-minute outage
permanently demote the model you are paying for.

### The local model as the spend decision

A combo fixes the order *within* one ladder. It cannot decide *which* ladder a
task deserves. That is what the local model does — it is the only capacity with
no per-call cost, which makes it the right place to decide how much to spend on
everything else.

```
LOCAL -> ollama/qwen2.5:1.5b   mechanical work: classify, extract, reformat
FREE  -> free-then-local        ordinary language work
PAID  -> paid-first             real engineering judgement
WEB   -> the web_research flow  needs current facts
```

`scripts/local-router.sh "<task>"` returns the label and ladder in ~0.95 s.

**Accuracy: 86% (13/15), and the eval ships with the prompt.** That number is
honest rather than flattering, and the history explains why the eval exists:

| prompt version | accuracy |
|---|---|
| v1, label descriptions only | 41% — barely above guessing between four labels |
| v2, few-shot + repeated label list | 91% |
| v3, added `<task>` delimiters | **67%** — a regression that read like an improvement |
| v4, rewrite proposed by Claude Opus 4.6 | **73%** — fixed the two target failures, broke four others |
| v2 + real-world cases added to the set | **86% over 15 cases** ← shipped |

Three attempts to improve v2 all lost to it. `local-router.sh --eval` exits 1
below `MIN_ACCURACY`, because routing at 41% is worse than not routing: it sends
trivial work to paid models and hard work to a 1.5B.

**Known weakness, unfixed:** short imperative coding tasks ("write a bash script
to rotate nginx logs weekly") classify as `LOCAL`. That exact string sits
verbatim in the prompt as a `PAID` example and the model still gets it wrong —
which is the finding that matters: **at 1.5B the ceiling is the model, not the
wording.** Further gains need a larger decision model or constrained decoding,
not another prompt edit.

---

## 5. Workflows and agentic patterns

Six flows, all enabled and published.

| Flow | Trigger | What it does | Model path |
|---|---|---|---|
| `ask_free_model` | MCP | Routine question to a free model | `free-then-local` |
| `review_code` | MCP | Code review with findings | `paid-first` → Opus 4.6 |
| `search_web` | MCP | One fact, one short sourced answer | Tavily → `websearch-tiers` |
| `web_research` | MCP | Expanded query, several sources weighed | Tavily → `websearch-tiers` |
| `gateway_monitor` | Schedule, 15 min | Reads `call_logs`, computes severity | — |
| `gateway_alerts` | Webhook | Receives monitor findings | — |

### The pattern that works: retrieve, then synthesise

Both web flows are four steps: build an expanded query → **HTTP to
`POST /v1/search`** → a model synthesises from the results → reply.

Measured end to end: `web_research` **11.0 s**, `search_web` **7.8 s**.

The separation is the point. No model in this stack can search the web on its
own — Gemini and Claude through Antigravity both answer version questions from
training data, one confidently returning Caddy "v2.9.1, early 2025". Retrieval
has to come from somewhere else, and then any model can turn results into a
sourced answer, including the ones that cost nothing per call.

### The pattern that does NOT work: multi-turn tool loops on `agy`

OmniRoute has a native web-search tool. Passing `{"type": "web_search"}` — with
**no `function` key**, which is the form `isBuiltInWebSearchTool` accepts — makes
the model emit `omniroute_web_search`, and OmniRoute executes the search
server-side and returns results in `tool_results`. Round one is reliable: 3 of 3
models requested a search and chose a sensible query.

**Round two fails.** Sending the results back for synthesis returned HTTP 502
from Antigravity every time, across Opus, Gemini and gpt-oss. Worse, that 502
pushes the credential into a 429 cooldown — so a failed agentic loop temporarily
disables the best provider in the stack **for everything else too**.

The practical rule: **do not build multi-turn agentic patterns on `agy`.** Use
the two-step flow shape instead, which works.

### What `agy` is good at

Measured across all 17 models on a verifiable multi-step reasoning task:
**17/17 correct**, 1.6 s–6.8 s. Gemini variants answer in 5 tokens; Claude
variants show their reasoning in ~108.

| Capability | Result |
|---|---|
| Multi-step reasoning | 17/17 models correct |
| Code review | Found a check-then-act race, noted `+=` is not atomic in Python, gave deadlock-safe ordered locking |
| Structured JSON output | Valid from both Opus and Gemini |
| Long context | Found the single anomaly in 400 log lines in **3.7 s** |
| Agentic tool loop | **Fails** — see above |

---

## 5a. The agentic layer

Live since 2026-09-01 as the `agent-sidecar-http` profile: a smolagents
`CodeAgent` reachable over HTTP, running on whichever model the caller names.

```bash
curl -s -X POST http://127.0.0.1:8100/run \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -d '{"task":"…","model":"agy/claude-sonnet-4-6","max_steps":4}'
```

```json
{"result": "…", "runner": "smolagents", "model": "agy/claude-sonnet-4-6",
 "steps": 2, "step_errors": [], "degraded": false}
```

**Why it works where two other routes did not.** smolagents drives the loop
itself and issues plain completion calls, so the provider never carries
multi-turn tool state. `agy`'s own `web_search` tool loop returns 502 on round
two and drags the credential into a cooldown that breaks unrelated traffic;
Activepieces' `run_agent` returns 404 because it calls an internal service
absent from a self-hosted install. Neither is usable. This is.

| Measured | Result |
|---|---|
| `agy/claude-sonnet-4-6`, 2-step task | 3 s, correct |
| `agy/gemini-3.7-flash-high` | 2 s, correct |
| `ollama/qwen2.5:1.5b`, `max_steps: 2` | 66 s, correct |
| Test suite in the built image | 61 passed, 3 skipped |

**The local model cannot drive an agent loop.** Unbounded it never converged —
malformed code blobs, rejected and retried, still running after the caller had
disconnected at 300 s. It is a single-call worker, not an agent. That is also
why `max_steps` exists: a caller giving up does not stop an agent, so the
ceiling lives in the service (default 8, a caller may lower it, never raise).

### Read `degraded` before you read `result`

The agent fabricates when the sandbox stops it. Blocked from fetching a URL, it
wrote `print("HTTP Status Code: 200")` and returned that as a real fetch, with
a fabricated `Output:` line and the code it had not been able to run.

`step_errors` comes from the agent's own step records rather than its prose, so
`degraded: true` means at least one step failed and the answer was produced
despite it. **Treat that as "do not trust this answer".**

### What contains it, and what does not

`/run` requires a bearer token and fails closed without one configured — 503,
not open access. That check matters on the Docker bridge, not the loopback
binding: every container shares `king_default`, and from inside `activepieces`
`/healthz` returns 200 while `/run` without a token returns 401.

The container drops every capability and carries equal memory and swap limits.

`executor_type` is still `local`. The AST allowlist held against four distinct
bypass attempts — `open()`, `pathlib`, `builtins` to recover `open`, and
`urllib` — but smolagents documents it as **not a security boundary**, and this
only proves it stops the obvious routes. Egress is unrestricted, and
`read_only: true` is impossible while the command is `uv run`, which syncs the
virtualenv on start.

**So no unattended trigger may reach `/run`.** Activepieces and Claude Code are
deliberately not wired to it. That waits on off-host execution — `e2b`,
`modal`, or `blaxel`, never `docker` — which needs an account this deployment
does not have.

---

## 6. The code graph

`codegraph-serve` holds the repository as a graph and exposes ten tools over MCP:
`query_graph`, `get_node`, `get_neighbors`, `get_community`, `god_nodes`,
`graph_stats`, `shortest_path`, `list_prs`, `get_pr_impact`, `triage_prs`.

Reached over an SSH tunnel, never exposed:

```bash
ssh -i ~/.ssh/king-gcp -L 8130:127.0.0.1:8130 subsa@34.101.62.94
claude mcp add --transport http codegraph http://127.0.0.1:8130/mcp \
  --header "Authorization: Bearer ${GRAPHIFY_API_KEY}"
```

Verified answer: `get_neighbors` on `CloudAgentBase` filtered to `inherits`
returns exactly the four subclasses with file and line numbers.

**It goes stale.** Refreshed daily by a systemd timer, so the graph can lag the
working tree by up to a day — it was 4 commits behind when last checked. That is
normal; weeks behind is not. A confident answer about month-old code is worse
than no graph at all. Check with `graph_stats`, refresh with
`scripts/codegraph-refresh.sh`.

---

## 7. Guards

This deployment has been bitten repeatedly by faults that left every container
reporting healthy. Each guard below exists because of a specific one.

| Guard | Cadence | Catches |
|---|---|---|
| `stax-preflight.sh` | Before every deploy | Missing variables, wrong ports, disk, placeholder secrets |
| `gateway_monitor` | 15 min | Real failure ratios from `call_logs`, with severity computed from shape |
| `monitor-deadman.timer` | 15 min | That the monitor **itself** is still running |
| `codegraph-refresh.timer` | Daily | The graph ageing silently |
| Healthchecks that assert *content* | Continuous | Ollama healthy with zero models; a JSON API returning 403 while HTML works |

The recurring design rule, learned the hard way: **anything that cannot be
measured is treated as a failure, not a pass.** `check_disk_gb` used to `return
0` when it could not read the disk. The dead-man switch exits 1 on every
unmeasurable path.

---

## 8. Access control

The gateway is on the public internet (`401` without a key, verified from
outside). Keys are scoped so that what a robot can reach is narrower than what
the operator can.

| Key | Access | Reason |
|---|---|---|
| `claude-code` | all | The operator's own interactive use |
| `activepieces` | restricted, **includes `agy/*`** | Flows built deliberately |
| `gateway-monitor-triage` | restricted, **excludes `agy/*`** | A 15-minute heartbeat doing triage has no use for frontier models and should not burn subscription quota |
| `flow-search` | restricted to `["search"]` | Can call `/v1/search`; **403 on every real model** |

Two traps found while setting this up, both worth knowing:

- **`POST /api/keys` silently discards `modelAccessMode` and `allowedModels`.**
  It returns a key with full access and no error. Only `PATCH /api/keys/{id}`
  persists them. A "restricted" key reached `agy` directly because of this.
  Always read the key back.
- **`allowedConnections` is not a usable control.** It is enforced on one
  internal route, not the general completion path. `allowedModels` is the one
  that works, and it is checked **per candidate** inside combo routing — so a
  restricted key calling a combo has forbidden tiers skipped, not the whole call
  rejected.
- Do not grant `no-think/*` to a restricted key: the pattern matches
  `no-think/agy/...` and defeats the restriction.

---

## 9. Costs, honestly

| Item | Cost |
|---|---|
| `agy` models | Subscription quota, no marginal cost |
| `opencode`, local Ollama | Free |
| Tavily search | **$0.008 per query** |
| OpenRouter | Per token, **balance is low** |

The OpenRouter balance already caused one live failure: a request reserving
2,600 output tokens was refused with `402 … can only afford 2411`, and that 402
put the credential into cooldown so that even small requests failed. Token
ceilings on the web flows were lowered to 1,200 and 700 as a result.

---

## 10. What was tried and abandoned

**SearXNG**, removed 2026-08-30 after roughly two hours in service.

It was the free retrieval layer: self-hosted metasearch, no API key, no quota.
It worked at first — 5 real results in 1.6 s. Then it failed in the worst
possible way. Asked about Caddy, it returned Chinese pages about typing circled
numbers in Word, because `google cse` had been rate-limited by an afternoon of
testing and `bing` filled the gap with "Deep Learning Tutorial" pages.

That is not an outage. It is **wrong results that look right**, which a model
then synthesises into a confident, sourced, entirely false answer.

Engine survey from this VPS, each queried individually: answered — brave 20,
github 30, stackoverflow 10, bing 10, yahoo 7; CAPTCHA — google (plain),
duckduckgo, startpage, qwant; refused — mojeek. Free engines block a datacentre
IP within tens of queries.

`duckduckgo-free` in OmniRoute's registry was tried first and needs no key at
all. DuckDuckGo answers this VPS with a CAPTCHA: *"select all squares containing
a duck"*, zero results.

**There is deliberately no fallback from Tavily to anything.** If Tavily fails,
the web flows fail loudly. The same principle removed non-web models from
`websearch-tiers` earlier: a search path that quietly answers from training data
is worse than one that stops.

---

## 11. Open, deferred, and risky

| Item | State | Why it matters |
|---|---|---|
| **Credential rotation** | Deferred by the operator | The list now includes the OmniRoute admin password, Neon connection string, Upstash token, two `/v1` keys, both Langfuse pairs, the `oma_` token, webhook HMAC secret, `GRAPHIFY_API_KEY`, the OpenRouter key, and the Tavily key |
| OpenRouter balance | Low | Web flows no longer depend on it, but `paid-first` tier 3 does |
| Tavily credit | Finite | No fallback by design — it will fail loudly |
| `agy` subscription risk | Accepted knowingly | Flagged `subscriptionRisk: true` in OmniRoute's own catalog |
| `agy` agentic loops | **Broken** | Round-two 502 also triggers a cooldown affecting other traffic |
| Router accuracy | 86% | Good enough to save money, not good enough to be unsupervised on important work |
| Code graph freshness | Up to a day | Weeks behind would be dangerous |
| `no-think` in `blockedProviders` | Inert but wrong | It is a modifier, not a provider; the entry blocks nothing |

---

## 12. Use cases this supports today

Each of these is running, not planned.

1. **Code review without spending Claude context.** A ten-file diff goes through
   `review_code` on Opus 4.6; Claude reads only the findings and decides which
   matter. Proven on a real race condition and an `eval()` injection.
2. **"If I change this, what breaks?"** One `get_neighbors` call against the code
   graph, answered with file and line numbers, instead of reading twenty files
   into context that stays there for the rest of the session.
3. **Current-facts research with citations.** `web_research` answered "latest
   stable Caddy and its release date" as v2.11.4 / 3 June 2026 across four
   corroborating sources, and flagged a one-day discrepancy on one of them as a
   likely timezone artefact.
4. **Bulk classification at zero cost.** An Activepieces flow over
   `free-then-local` for hundreds of items, running unattended.
5. **Work that must not leave the machine.** Point at
   `ollama/qwen2.5:1.5b-instruct-q4_K_M` and nothing egresses.
6. **Unattended monitoring that fails loudly.** Gateway checked every 15
   minutes, with a dead-man switch watching the monitor.
7. **Spend triage.** `local-router.sh` labels a task and picks the ladder in
   ~0.95 s for nothing.

---

## 13. Scope for what comes next

Ordered by value against effort, and grounded in what the measurements above
actually showed.

**Near term**

1. **Rotate credentials.** The one deferred item that grows with every session.
2. **Make silent degradation visible.** The flows cannot see which tier served
   them — the AI piece returns text, not a model name. An HTTP step against
   `/v1/chat/completions` would expose the `model` field, so a drop from Opus to
   DeepSeek becomes detectable instead of merely cheaper-looking.
3. **A weekly `pool-register.sh --prove` timer.** The built-in health autopilot
   reported all providers "healthy, 0 issues" while three of them failed 100% of
   real requests.
4. **Remove `no-think` from `blockedProviders`.** Cosmetic, but wrong entries in
   a security-adjacent list age badly.

**Medium term**

5. **A larger decision model for routing.** Prompt design is exhausted at 1.5B —
   measured across four versions. A 3B–7B model, or grammar-constrained decoding
   forcing one of four labels, is the next real gain. `--eval` already exists to
   judge whether it worked.
6. **Web fetch, not just search.** Tavily's `webFetch` capability is registered
   but unused. Snippets answered the Caddy question; a question needing the body
   of a page would not be answered by snippets alone.
7. **Alerting that reaches a human.** `gateway_alerts` receives findings; it has
   no destination yet. A Discord webhook needs only a URL — the piece requires no
   OAuth.

**Longer term, and only if the need is real**

8. **Agentic loops on a provider that supports them.** `agy` cannot do
   multi-turn tool use. A per-token provider can. Worth doing only when a task
   genuinely needs a loop rather than the two-step shape that already works.
9. **Native provider keys instead of resold ones.** A direct DeepSeek or Alibaba
   account is cheaper than the same weights through OpenRouter. Register the
   connection, then insert one line above the openrouter rows in `TIERS`.
10. **Graph-aware review.** `review_code` sees a snippet. `get_pr_impact` sees
    what a change touches. Joining them would let a review know what the code it
    is reading is connected to.

---

## Rules that survived contact with production

Collected because each was learned by being wrong first.

- **Never edit `omniroute/`.** It is a squashed subtree; edits vanish on the next
  `git subtree pull`. And do not reach for a compose override instead — the root
  file must never declare a service `omniroute/` already defines, which once
  turned every CI job red while working fine on both machines a human checked.
- **Prove it with a real completion.** `/api/providers/validate` returns
  `{"valid":true}` for a junk key. Every registration script here refuses to exit
  0 without an actual answer.
- **Give reasoning models room.** A 64-token probe marks them dead: they spend
  the budget thinking and return empty. 400 is the floor. This bug was fixed
  once, then reintroduced in a second script.
- **Measure before believing an improvement.** Two prompt changes that read as
  obvious improvements — delimiters, and a rewrite from Claude Opus 4.6 — both
  made accuracy worse. Only a scored run caught either.
- **A fallback that degrades capability must be visible or removed.** Falling
  from a web-capable model to one answering from memory produces output of
  identical shape and no way to tell.
- **Unmeasurable is a failure, not a pass.**
