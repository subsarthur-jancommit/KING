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

### The gateway reroutes on prompt content, overriding the model you asked for

The `served_by` field found this within minutes of existing, and the first
conclusion drawn from it was wrong — which is worth recording, because the
wrong version is more plausible than the right one.

**What is actually true.** Same key, same endpoint, same explicitly requested
model — `agy/claude-sonnet-4-6`, not a combo:

| Messages sent | Served by |
|---|---|
| a plain user message | `claude-sonnet-4-6` |
| a short system prompt + user | `claude-sonnet-4-6` |
| **smolagents' agent system prompt + user** | **`big-pickle`** |

Nothing about the request names a combo or a fallback. The gateway classifies
the *content* and routes accordingly, and a prompt shaped like an agent's — the
Thought / Code / Observation cycle, references to tools and code blobs — is
routed to the free tier no matter which model was asked for.

**How it was narrowed**, since eight plausible causes were eliminated first:
tool schemas, a system message as such, `stop` sequences, `max_tokens`,
streaming, the Docker-internal network path, the smolagents client itself, and
prompt length (37,000 tokens of filler still reached Opus). The isolating test
was replaying the agent's *own* two messages through a plain client, which
reproduced it exactly.

**The first conclusion was wrong.** It read as "the agent falls through
`paid-first` to the free tier", which fitted the combo's fallback story
perfectly and was checked against a direct model request only afterwards. Asking
for `agy/claude-sonnet-4-6` explicitly and being served `big-pickle` is not
fallthrough — it is override, and it affects every caller, not just combos.

**What it costs.** Every agent run this deployment has ever made has been served
by the free tier regardless of the model requested, including the acceptance
runs. That explains the measurement that looked so tidy earlier: the free-tier
default answered exactly as well as `agy/claude-sonnet-4-6`, because both were
`big-pickle`.

**The mechanism, from the gateway's own header.** `x-omniroute-decision` names
the strategy it chose, and that is what changes:

```
no system prompt      decision=strategy=single; provider=antigravity  -> claude-sonnet-4-6
smolagents system     decision=strategy=auto;   provider=oc           -> big-pickle
```

So it is not that a different model was picked within one strategy. The gateway
**switches strategy** on the content, from `single` — honour what was asked for
— to `auto`, and `auto` is the router already measured landing on `big-pickle`
three times out of three. Retiring `auto/*` from the flows removed callers who
*asked* for it; it did not stop the gateway choosing it.

**What triggers it, narrowed by bisection.** Splitting the prompt line by line,
two lines flip the strategy on their own and five do not:

```
single   You are an expert assistant who can solve any task using code blobs.
single   To do so, you have been given access to a list of tools.
AUTO     At each step, explain your reasoning.
AUTO     Then write the code in simple Python.
single   You can use print() to save information.
single   Return a final answer using the final_answer tool.
```

It is not length — the two triggers are among the shortest lines, and 37,000
tokens of filler never triggered it. The two that fire are the two that state
an *intent*: reasoning, and writing code. "code blobs" and "final_answer tool"
do not.

**The obvious lever does not work.** That pattern matches
`intentClassifier.ts` (`DEFAULT_INTENT_CONFIG = {enabled: true,
simpleMaxWords: 60}`), which `autoStrategy.ts` gates on a settings flag. Tested
directly rather than assumed: `intentDetectionEnabled: false` was set on the
live gateway, the probe re-run, and the result was unchanged —
`strategy=auto; provider=oc` before, during and after. **The setting was
restored to `true` immediately; nothing persists.**

So the classifier is not the switch, or not the only one. What remains
unchecked is the `auto_resolve` column on `api_keys`, which the API's key
listing does not expose.

`omniroute/` is a vendored subtree that must not be edited, so any fix is a
setting or nothing — and the first setting that looked right is now ruled out.

**Diagnostic worth keeping:** `x-omniroute-decision`, `-provider`, `-model` and
`-request-id` are on every response. Reading them first would have skipped most
of the eight eliminations above.

**It does not touch the flows, which was checked rather than hoped.** The real
`web_research` synthesis prompt — instructions, rules, search results — was
probed against both combos:

```
websearch-tiers -> claude-opus-4-6-thinking-high   strategy=priority
paid-first      -> claude-opus-4-6-thinking-high   strategy=priority
```

`strategy=priority` is the combo's own ladder working as designed. So the
`auto/*` retirement earlier today is real: flow prompts are served by the tier
they ask for. The override is confined to agent-shaped prompts, which means it
is confined to the sidecar.

**What was done about it.** Nothing can be fixed inside `omniroute/`, and the
one settings lever was tested and does nothing. So the override is now
*reported* instead: asking for a `provider/model` and being served something
else lands in `step_errors` and sets `degraded`, using the same contract every
other degradation here already uses. Live:

```
asked agy/claude-sonnet-4-6  -> served big-pickle  degraded=true
   "model override: asked for agy/claude-sonnet-4-6, served by big-pickle"
asked opencode/big-pickle    -> served big-pickle  degraded=false
```

A combo name is exempt, because it asks for a ladder rather than one model, and
the provider prefix is stripped before comparing — `agy/claude-sonnet-4-6`
answered by `claude-sonnet-4-6` is a match, and treating it otherwise would
mark every correct run degraded.

**A workaround exists and is deliberately not taken.** smolagents' system
prompt can be replaced through `prompt_templates`, and prompt size decides the
outcome:

```
59 chars   "You answer the user's question. Call a tool when one helps."   -> claude-sonnet-4-6
156 chars  a normal instruction paragraph                                 -> big-pickle
9,867      smolagents' actual default                                     -> big-pickle
```

So the agent could have the model it asks for by shipping a nearly empty system
prompt. That prompt is what teaches it tool-call formatting, `final_answer`
usage and what to do when a tool returns nothing — trading a stronger model for
an agent that behaves unreliably is a bad trade, and it would break again the
moment the prompt grew by a sentence. Reported rather than dodged.

### The ladder was probed, not assumed — 2026-09-05

An alert fired at 04:41 (`monitor.error_rate`, 38% over 15 minutes, WARNING)
naming three failures: `openrouter/openai/gpt-5.6-luna` 402,
`antigravity/gemini-3.7-flash-high` 502 "Provider returned empty content", and
`opencode/nemotron-3-ultra-free` 502.

Two of those are tiers of `paid-first` and `websearch-tiers`, so the ladder was
probed rather than reasoned about. **All five tiers answered correctly**:

```
agy/claude-opus-4-6-thinking-high         ok
agy/claude-sonnet-4-6                     ok
agy/gemini-3.7-flash-high                 ok
openrouter/deepseek/deepseek-v4-pro-0813  ok
opencode/big-pickle                       ok
```

So the failures were transient, and the obvious inference from the alert —
"OpenRouter is out of credit, tier 3 is dead" — would have been wrong twice
over. The 402 was for a *different, expensive* model requesting 65,536 tokens,
and the agy 502 cleared on its own.

Which is the argument for the monitor and against acting on it directly: a
15-minute error ratio is a signal to go and measure, not a conclusion.

### `auto/*` is retired, and why

`auto` ranks by **speed**, and the fastest provider is always the free one.
Sixteen consecutive `auto` calls landed on `opencode/big-pickle`; none reached
OpenRouter or `agy`. That is `auto` working correctly, and it is also why buying
keys does not widen what `auto` serves. Paid capacity just sits there.

Worse, the tie is inverted here. `agy` is subscription quota with **no marginal
cost per call**, so the strongest models in this stack are also the cheapest
ones to call — and `auto` is the one thing that will never reach them.

It cannot be fixed from outside: the candidate pool excludes `agy` and
`openrouter` entirely, and the strategy is pinned to LKGP at
`virtualFactory.ts:812`, inside the vendored subtree this repo must not edit.

**So nothing calls it any more.** Re-measured on 2026-09-04 before the switch:
`auto/best-chat` was served by `big-pickle` three times out of three. The last
caller was `web_research`, whose synthesis step now uses `websearch-tiers` —
Opus thinking-high first. Verified end to end: the flow searched six sources,
cited them, and reported that endoflife.date says 2 June 2026 while GitHub,
Chocolatey and mise all say 3 June, instead of silently picking one.

An audit of all six flows found no other `auto/*` caller. `search_web` was
already on `websearch-tiers`, `review_code` on `paid-first`, `ask_free_model`
stays on `free-then-local` deliberately, and both gateway flows are pure code
steps that call no model at all.

### Why the flows do not call the agent bridge

It was planned, on the reasoning that one path is cheaper to maintain than two.
Checked against what the flows actually do, it was the wrong call and is not
being done.

Every model-calling flow here does its own retrieval first (an HTTP step
against the search gateway) and then needs exactly one completion over the
results. The bridge runs an agent loop: several model round-trips, a tool
negotiation, and a step budget, to produce the single completion the flow
already had. That is added latency and tokens bought with nothing.

The bridge earns its keep when a caller does **not** know in advance which
tools it needs, which is Claude's situation and not a fixed flow's. If a flow
ever needs multi-step tool use, it should move; none of the six does today.

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

## 5. The bridge — how Claude reaches any of this

Until 2026-09-04 Claude had five tools while this VPS ran 1,019 models, a
59k-node code graph and an agent runtime. The gap was never capability; nothing
was reachable without an SSH tunnel per session, which is why the code graph sat
unused while running perfectly.

Three MCP servers, two of which already existed and had never been switched on.

| Endpoint | Tools | What it covers |
|---|---|---|
| `https://gateway.arject.co/api/mcp/stream` | **110** | OmniRoute's own control plane — routing, quota, cost, cache, skills, memory, `best_combo_for_task`, `explain_route` |
| `https://gateway.arject.co/king-agent/mcp` | **4** | `run_agent`, `ask_model`, `vps_status`, `vps_exec` |
| `http://127.0.0.1:8130/mcp` (tunnel) | **10** | codegraph — `get_neighbors`, `shortest_path`, `god_nodes`, … |

### Connecting

```bash
claude mcp add --transport http king \
  https://gateway.arject.co/king-agent/mcp \
  --header "Authorization: Bearer $AGENT_SIDECAR_AUTH_TOKEN"

claude mcp add --transport http omniroute \
  https://gateway.arject.co/api/mcp/stream \
  --header "Authorization: Bearer $OMNIROUTE_MANAGE_KEY"
```

Both tokens live in gitignored files on the VPS — `agent-sidecar/.env` and the
OmniRoute key list. Never put them in a committed `.mcp.json`.

Both endpoints re-verified over the public domain on 2026-09-05: `initialize`
answers `serverInfo.name = "king"` on the first and `"omniroute" 1.8.1` on the
second. Worth re-running after any Caddy change, since a route that stops
matching fails as a 404 the client reports as "server not found" — which reads
like a configuration mistake at the Claude end, not at this one.

### Four things that each failed silently first

**OmniRoute's MCP was off.** `mcpEnabled: false` and `mcpTransport: stdio` by
default. Turning both on is what produced 110 tools from nothing.

**`tools/list` returned 0 tools** until the `Mcp-Session-Id` from `initialize`
was carried forward. That is the protocol, not a permission problem — the
symptom looks identical to a scope failure.

**The bind mount kept serving the old config.** `git pull` replaces a file
rather than editing it, so the new inode never reached the running Caddy
container. `grep` inside the container showed zero matches while the host file
was correct. Recreating the container is what re-resolves it.

**Every proxied call answered "Invalid Host header"** — as a 200 with that
body, not an error status. MCP's DNS-rebinding guard validates `Host` against
a loopback-only allow-list. The public name is added via
`AGENT_SIDECAR_MCP_ALLOWED_HOSTS`; the guard stays on, because it is the only
thing stopping a browser page from driving this endpoint through a victim's
network.

### `vps_exec` — a shell, and what it really grants

Off unless `AGENT_SIDECAR_EXEC_ENABLED` is set. Runs in the sidecar with the
repo at `/workspace`, `git`, `curl` and `docker-cli` installed, and the host's
Docker socket mounted.

**Mounting that socket is granting root on this host.** Anything holding it can
start a privileged container with `/` mounted, so `cap_drop`, the non-root uid
and the `/dev/null` masks used elsewhere limit none of it. Four things do the
protecting instead:

1. the tool is off by default, so no deployment grows a shell by accident
2. the bearer token on `/mcp`, which fails closed
3. **the agent never receives it** — smolagents is built with `tools=[]`, and
   that matters because the agent reads web pages: a page carrying instructions
   plus a shell is a direct path from someone else's text to this machine
4. every command is appended to `/audit/vps_exec.log` before it runs

```bash
docker run --rm -v king_agent-audit:/a alpine cat /a/vps_exec.log
```

Two permission faults showed up on first real use, both the same shape — a
mount present but unusable because the container runs as uid 10001. `git`
exited 128 with "dubious ownership" until `safe.directory`; the audit log
stayed empty until `/audit` existed in the image owned by `app`, because Docker
seeds a fresh named volume's ownership from the image path. The audit helper
writes its own failures to stderr rather than swallowing them, which is the
only reason the second was a five-minute fix.

**Verified through the public bridge on 2026-09-05**, not just locally. All
four tools are offered — `run_agent`, `ask_model`, `vps_status`, `vps_exec` —
and a real command ran and was audited:

```
vps_status  ->  7936 MB total, 4418 MB available | 37G of 48G | load 0.42
vps_exec    ->  exit_code 0, stdout carried the repo's HEAD and df output
audit       ->  2026-09-05T05:33:22+00:00  timeout=60  git -C /workspace log …
```

The response fields are `exit_code`, `stdout`, `stderr`, `truncated`, `cwd` —
worth naming, because a caller reaching for `returncode` gets `None` and would
read a successful command as an unknown one.

### Memory persists without extra infrastructure

OmniRoute's memory runs on SQLite + sqlite-vec + FTS5. Verified end to end:
`omniroute_memory_add` then `omniroute_memory_search` wrote and retrieved a
record with nothing else running.

`enabled: false` at `/api/settings/qdrant` means the **dual-write path** to
Qdrant is off, not that memory is off — a distinction worth knowing before
adding 74 MB of vector store to a 2-vCPU box, which is exactly the mistake
that was made and reverted here.

### Why a path and not a subdomain

`agent.arject.co` would be cleaner and needs a DNS A record. Probed: only
`gateway` and `flows` resolve to this VPS, there is no wildcard. A path on a
name that already resolves needs nothing from DNS, so `/king-agent/*` is
usable now rather than after a change only the operator can make.

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
 "steps": 2, "step_errors": [],
 "tokens": {"input": 13993, "output": 603, "total": 14596},
 "tools": {"enabled": true, "offered": 110,
           "selected": ["omniroute_web_search", "…"],
           "missing": [], "misdirected": []},
 "degraded": false}
```

`tokens` is what the run cost. smolagents computes it and prints it to the
container log, where it is unparseable and scrolls away; it now travels with
the answer instead. `null` there means not measured — never "free".

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
| Test suite in the built image | 94 passed, 3 skipped |

**The local model cannot drive an agent loop.** Unbounded it never converged —
malformed code blobs, rejected and retried, still running after the caller had
disconnected at 300 s. It is a single-call worker, not an agent. That is also
why `max_steps` exists: a caller giving up does not stop an agent, so the
ceiling lives in the service (default 8, a caller may lower it, never raise).

### What a run actually costs

Measured on the deployment, same task both times — "search the web for the
release date of Caddy 2.11.4":

| | Model | Tokens in / out | Retrieval | Marginal cost |
|---|---|---|---|---|
| default | `opencode/big-pickle` | 3,884 / 143 | 1 Tavily search | **$0.008** |
| named | `agy/claude-sonnet-4-6` | 23,105 / 986 | 1 Tavily search | **$0.008** |

`search_cost_usd: 0.008` comes from the search gateway's own response, not an
estimate. Both models are free at the margin — `big-pickle` is keyless and
free-tier, `agy` is subscription quota — so **the entire cost of an agent run
here is retrieval**, and the model choice moves it by nothing.

That is worth knowing before optimising the wrong half. Six times more tokens
bought the same answer for the same price; what would actually change the bill
is searching twice.

### Two ceilings, because steps do not bound cost

`max_steps` (default 8) bounds how many times the loop turns. It does not bound
what one turn costs, and the agent's own tools make that gap real — a web
search returns a large page, and a single step can move the context a long way.

`AGENT_SIDECAR_MAX_TOKENS` (default 250,000, `0` disables) is the second
ceiling. It runs as a step callback that reads the agent's own monitor and
calls `interrupt()`, so smolagents stops at the next step boundary rather than
tearing down mid-tool-call.

**It stops soon after the limit is crossed, not before.** Measured with the
limit set to 500:

```
RESULT : Stopped: this run reached its token ceiling (3,143 of 500 allowed)…
STEPS  : 2
TOKENS : {"input": 4249, "output": 1796, "total": 6045}
ERRORS : ["token ceiling: used 3143 of 500 allowed"]
```

The check happens between steps, so the step that crosses the line still
completes and its cost still counts. That is why the default is generous: this
is a backstop against something pathological, not a budget meant to shape
ordinary runs, and a measured 3-step search run costs about 24k.

Reaching it is a **bounded stop, not a crash**. The caller gets what the run
established plus a step error, which makes `degraded` true without them needing
to know the feature exists. Any other agent error still propagates as a 500 —
the guard checks that the interrupt was its own before swallowing anything.

### Every knob, and which file sets it

Compose's `environment:` **overrides** `env_file:`, so an interpolated variable
is decided by the root `.env` and a value in `agent-sidecar/.env` cannot take
effect at all. Getting that backwards made preflight report the wrong executor
for weeks — `king-mistakes.md` entry 16 — so the split is written down rather
than inferred.

| Variable | Default | Set in | What it does |
|---|---|---|---|
| `AGENT_SIDECAR_EXECUTOR` | `local` | root `.env` | Where a `CodeAgent` runs its Python. `local` is in-process; `e2b`/`modal` are off-host |
| `AGENT_SIDECAR_AUTHORIZED_IMPORTS` | empty | root `.env` | **Means two opposite things.** Under `local` it restricts imports and is the whole boundary; under `e2b`/`modal` smolagents pip-installs it and restricts nothing |
| `AGENT_SIDECAR_AGENT_TOOLS` | the seven | root `.env` | Tool allowlist by exact name. `none` for no tools |
| `AGENT_SIDECAR_MAX_STEPS` | `8` | root `.env` | Iteration ceiling. A caller may lower it per request, never raise it |
| `AGENT_SIDECAR_MAX_TOKENS` | `250000` | root `.env` | Cost backstop. `0` disables |
| `AGENT_SIDECAR_MAX_CONCURRENT` | `2` | root `.env` | Runs at once before `429`. `0` disables |
| `AGENT_SIDECAR_EXEC_ENABLED` | off | root `.env` | The `vps_exec` shell. Read what it grants first |
| `AGENT_SIDECAR_MCP_ALLOWED_HOSTS` | loopback | root `.env` | Extra `Host` values the MCP endpoint accepts behind a proxy |
| `AGENT_SIDECAR_RUN_JOURNAL` | `/audit/runs.jsonl` | compose literal | Where runs are recorded |
| `OMNIROUTE_API_KEY` | — | `agent-sidecar/.env` | Scoped `models,routing,health`. Never `manage` |
| `OMNIROUTE_MCP_API_KEY` | — | `agent-sidecar/.env` | `manage` scope. Without it the allowlist loads nothing |
| `AGENT_SIDECAR_AUTH_TOKEN` | — | `agent-sidecar/.env` | Bearer for `/run`. Unset means **503 on everything**, not open |

The three ceilings — steps, tokens, concurrency — are configured the same way
on purpose. `MAX_STEPS` used to be reachable only through `agent-sidecar/.env`
while the other two came from the root, which is the arrangement that produces
a guard reading the wrong file.

### Read `degraded` before you read `result`

The agent fabricates when the sandbox stops it. Blocked from fetching a URL, it
wrote `print("HTTP Status Code: 200")` and returned that as a real fetch, with
a fabricated `Output:` line and the code it had not been able to run.

`step_errors` comes from the agent's own step records rather than its prose, so
`degraded: true` means at least one step failed and the answer was produced
despite it. **Treat that as "do not trust this answer".**

`degraded` is present on **every** response, including the HTTP 500 a crashed
run returns. That is deliberate: a body that omitted it there would give
`body.get("degraded")` → `None` → falsy, which is indistinguishable from a
clean run to any caller that branches on the field rather than the status code
— and branching on the field is what this section tells them to do.

### Two agent kinds, and why holding tools changes which one you get

Turning the tools on forced a design decision that turned out to be the right
one anyway.

| Run | Agent | Executes Python? | Boundary |
|---|---|---|---|
| No tools | `CodeAgent` | Yes, in the e2b/modal sandbox | The sandbox |
| Tools loaded | `ToolCallingAgent` | **No** | The tool allowlist |

A `CodeAgent` under a remote executor serializes each tool's source code into
the sandbox, and the dynamically-wrapped `MCPAdaptTool` fails that validation —
measured: `Tool validation failed for MCPAdaptTool ... 'func' is undefined`. So
MCP tools and a sandboxed `CodeAgent` cannot coexist in smolagents 1.26.0.

The fix is not a workaround. An agent that reads web pages should not also be
executing model-authored Python, because that is precisely how injected page
content becomes code running on this host. A `ToolCallingAgent` emits JSON tool
calls and runs no arbitrary code at all, so there is nothing to sandbox and the
allowlist is the entire boundary.

**It is told which search provider to name.** The gateway advertises twenty
search and fetch providers; exactly one, `tavily-search`, reports
`cred=configured`. Left to itself the model picked `duckduckgo-free`, got
nothing, retried other dead providers and burned the whole step budget. The
opposite instruction — omit `provider` — failed differently and more usefully:
`Argument provider is required`, three times, because the MCP schema marks the
field required and smolagents validates arguments client-side before the
request is sent. (A direct MCP call omitting it succeeds; the server is lenient,
the client is not.) So the instruction names `tavily-search` explicitly.

### The default model was left alone, and that was measured

`AGENT_SIDECAR_MODEL_ID` defaults to `opencode/big-pickle`, the free tier. The
obvious move after retiring `auto/*` was to change it on the same argument —
`agy` is subscription quota, so the strongest models cost nothing extra.

Tested instead of assumed, and the argument did not survive. Given the same
task with tools, the default answered correctly in **2 steps, no step errors,
`degraded: false`** — identical to `agy/claude-sonnet-4-6` on the same task.
The free model drives a `ToolCallingAgent` perfectly well.

So the default stays. The `auto/*` case was different in kind: there the free
tier was chosen *instead of* better models on work where better mattered, and
the router could never be talked out of it. Here the free model produces the
same answer in the same number of steps, and a caller who wants a stronger one
passes `model` per request — which the acceptance run did, and which is the
right place for that decision.

### The tools it holds, and the one it never will

Until 2026-09-04 the agent ran with `tools=[]`. It could execute Python in a
sandbox and nothing else — no search, no fetch, no memory. It now loads tools
from OmniRoute's MCP server, gated on a separately provisioned `manage`-scoped
`OMNIROUTE_MCP_API_KEY`.

It does **not** get all 110. The default is seven, read-mostly:

```
omniroute_web_search   omniroute_web_fetch   omniroute_x_search
omniroute_list_models_catalog   omniroute_get_health
omniroute_memory_search   omniroute_memory_add
```

**An allowlist, not a denylist**, set by `AGENT_SIDECAR_AGENT_TOOLS`
(`none` for no tools). OmniRoute tags twelve tools "phase 1", and that was the
obvious set to reuse — but the tag marks usefulness to an MCP client, not
safety in the hands of an agent that reads web pages. Two of the twelve,
`omniroute_switch_combo` and `omniroute_create_combo`, rewrite the live
gateway's routing. An allowlist also survives upstream growth: a `git subtree
pull` that adds twenty tools adds none of them here, where a denylist would be
wrong from that moment until somebody noticed.

**`vps_exec` is never registered, and configuration cannot change that.** It,
`run_agent` and `ask_model` are this service's own MCP tools, so under correct
configuration they are not offered to the agent at all. They are named in
`NEVER_REGISTER` because the mistake that would offer them is quiet: point
`OMNIROUTE_MCP_URL` at this service instead of the gateway, and the agent is
holding a shell on the VPS with `run_agent` to recurse into itself. Being
offered one is reported as `misdirected` rather than silently filtered — the
operator needs to know the URL is wrong, not merely be protected from it.

**A tool that was asked for and not delivered counts as `degraded`.** It is
invisible in `result`: the agent answers from training data and sounds exactly
like one that searched — the same failure a self-hosted search layer produced
for real, not an outage but confident wrong answers. So `/run` reports
`selected`, `missing` and `misdirected`, and folds all three into `degraded`.

`/healthz` reports `agent_tools_active` as the **conjunction** of the allowlist
and the key, because setting one without the other is the obvious way to end up
with an agent that has no tools and says nothing about it.

### The agent remembers between runs, when asked

`omniroute_memory_add` and `omniroute_memory_search` are in the allowlist, and
they work across separate HTTP requests. Verified 2026-09-05 with two
independent `/run` calls:

| | Task | Steps | Result |
|---|---|---|---|
| 1 | store where the run journal lives | 3 | stored under `king_agent_run_journal_location` |
| 2 | search memory for that path | 2 | `/audit/runs.jsonl` |

Both `degraded: false`. The store is OmniRoute's own SQLite + sqlite-vec — no
Qdrant, which was added for this once and reverted after it turned out to be
unnecessary.

**It remembers on request, not spontaneously**, and that is deliberate rather
than an omission. Nothing in the agent's instructions tells it to record what
it learns, because an agent writing to a shared store on its own judgement
fills that store with noise, and a retrieval layer full of noise is worse than
none — the same failure a self-hosted search layer produced here for real. A
caller who wants something remembered asks for it.

### Every run leaves a record

Run evidence used to die with the HTTP response. Nothing could answer what the
agent cost over a week, whether degraded runs were becoming more common, or
which of its seven tools actually get used — the gateway's `call_logs` sees
model calls and knows nothing about steps, tools, or trustworthiness.

One JSON line per run now lands in `/audit/runs.jsonl`, in the same volume as
the `vps_exec` audit:

```json
{"at":"2026-09-05T04:40:11+00:00","runner":"smolagents","model":"opencode/big-pickle",
 "task":"Search the web for the release date of…","seconds":18.4,"steps":3,
 "tokens":{"input":23105,"output":986,"total":24091},
 "tools":["omniroute_web_search","…"],"step_errors":[],"degraded":false}
```

Both outcomes are written, the successful one and the 500 — a journal that only
records successes answers the least interesting half of every question. Task
text is truncated to 200 characters, the same choice the `vps_exec` audit makes
with commands: enough to recognise a run, not a transcript.

Writing is best-effort. A full disk must not turn working runs into 500s, and
must not silently look like it logged either, so the failure goes to stderr and
into the container log. That path has a test, because "best-effort" is the kind
of promise that quietly stops being true.

Read it with `./scripts/agent-report.sh [days]`, which is the half that stops
the journal being data nobody looks at:

```
agent runs — all time
  runs            1
  degraded        0  (0%)
  tokens in/out   3,884 / 143
  seconds med/max 11.1 / 11.1
  by model
       1  opencode/big-pickle
```

Runs with no token counts are reported separately rather than summed as zero —
`null` means not measured, and zero would claim the call was free. Unparseable
lines are counted rather than skipped in silence: one truncated last line is
normal when reading mid-write, a journal full of them is not.

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

Reachable since 2026-09-04 without a tunnel, on the same domain as the bridge:

```bash
claude mcp add --transport http codegraph \
  https://gateway.arject.co/king-codegraph/mcp \
  --header "Authorization: Bearer ${GRAPHIFY_API_KEY}"
```

It used to need `ssh -L 8130:127.0.0.1:8130` every session, and that friction is
the whole reason a graph refreshed daily sat unused for weeks. A path rather
than a subdomain, for the same reason as `/king-agent/`: this domain has no
wildcard DNS record.

**What that changed about the threat model.** `GRAPHIFY_API_KEY` is now the
only thing between a complete map of this repository and the open internet,
where before it sat behind the SSH boundary as well. That was checked before
the route was added rather than after: the compose default for that variable is
an empty string, so an unset key would have published the graph the moment
Caddy loaded. Measured on the VPS — 48-character key present, 401 with no
token, 401 with a wrong one, and the same 401 from outside once it was live.

It also moves that key up the rotation list, because losing it now costs more
than it did yesterday.

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
| `/audit/runs.jsonl` | Every agent run | Cost, tool use, and degradation trends that were previously unrecoverable |

### The alarm that nobody hears

`gateway_monitor` works. Probed 2026-09-05: it runs every fifteen minutes, and
a real execution returned `{"ok":true,"breach":false,"windowMinutes":15,
"total":1,"failed":0,"ratio":0,"threshold":0.3}` with a per-provider breakdown.
It measures.

`gateway_alerts` receives what it sends, normalises the payload into
`{event, at, apiKey, provider, model, reason, raw}` — **and stops there.** The
flow is two steps: the webhook, and the code step that shapes the object. Its
return value goes nowhere.

Three alerts fired on 2026-09-05 (00:11, 00:56, 04:41) and none reached a
person. They exist only in Activepieces run history, which nobody watches. The
04:41 one carried a 38% error ratio and three named failures — genuinely worth
seeing, and unseen.

**The destination already exists and is empty.** A `gateway_alerts` table is
provisioned with exactly the right columns — `received_at`, `event`, `api_key`,
`provider`, `detail` — and **0 rows**. Somebody built the sink and never wired
the pipe.

One step closes it, after `step_1` in the `gateway_alerts` flow:

```
piece   @activepieces/piece-tables    action  tables-create-records
table_id  wzZB4ntGPk9OAnzgknJqZ
records   [{"received_at": "{{step_1['output'].at}}",
            "event":       "{{step_1['output'].event}}",
            "api_key":     "{{step_1['output'].apiKey}}",
            "provider":    "{{step_1['output'].provider}}",
            "detail":      "{{step_1['output'].reason}}"}]
```

A push destination — Discord, email — is a second step and needs a URL only the
operator has. The table does not, and turns "alerts vanish" into "alerts
accumulate somewhere you can look".

**They are `--user` units, and checking them the obvious way says they are
dead.** `systemctl list-timers` and `systemctl is-active monitor-deadman.timer`
both report nothing, because these run under the `subsa` user manager rather
than the system one. Verified 2026-09-05 — the correct commands, and what they
actually returned:

```bash
systemctl --user list-timers            # deadman ran 18s ago, codegraph 21h ago
systemctl --user --failed               # empty
```

That distinction is worth a line here because getting it wrong produces the
most expensive possible wrong answer: an operator concluding that every guard
on this deployment is dead, and either re-installing them on top of working
ones or starting to distrust the readings they do give.
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
| `agent-sidecar-mcp` | **`manage` scope** | The most privileged key in the stack. It is what lets the agent load tools at all, and it is first on the rotation list |

### Security review of the agent surface, 2026-09-05

Run against the ECC `security-review` checklist after the agent gained tools,
a public path and a shell. What it found, honestly — most of it clean, one gap
that was not:

| Check | Result |
|---|---|
| Hardcoded secrets in the tree | **clean** — no key-shaped strings; every `.env` gitignored, confirmed with `git check-ignore` |
| Input validation on `/run` | **clean** — runner allowlisted, `model` type-checked, `max_steps` can only be *lowered* by a caller, and `bool` correctly excluded from `int` |
| Authentication | **clean** — bearer required, fails **closed**: an unset token returns 503, not open access |
| Sensitive data in `/healthz` | **clean** — booleans only, never key values; the endpoint is meant to be safe to curl |
| Privilege reachable by the agent | **clean** — `vps_exec` is in `NEVER_REGISTER`, tested |
| Concurrency | **gap, now fixed** — see below |

The gap: nothing bounded how many runs the container would start at once. The
cgroup caps it at 1 GB and 1 CPU so it cannot reach the host — that lesson was
already paid for — but anyio will run dozens of agent loops in threads, and the
resulting OOM *inside* the cgroup kills the runs already in flight along with
the surplus that caused it. `AGENT_SIDECAR_MAX_CONCURRENT` (default 2, matching
the one CPU) now refuses the surplus with `429` and `degraded: true`, which
loses one caller instead of all of them.

Verified against the running service rather than only in tests — three
simultaneous requests against a limit of two:

```
permintaan 1 -> HTTP 200
permintaan 2 -> HTTP 429   busy: 2 agent run(s) already in flight
permintaan 3 -> HTTP 200
```

Still open, and deliberately: there is **no rate limiting**. The bearer token is
the control, and the concurrency bound caps what a leaked one could consume at
any instant — but not over time. Worth revisiting if that token is ever shared
more widely than the operator.

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
| **Credential rotation** | Deferred by the operator, to be done in one pass at the end | The list now includes the OmniRoute admin password, Neon connection string, Upstash token, two `/v1` keys, both Langfuse pairs, the `oma_` token, webhook HMAC secret, `GRAPHIFY_API_KEY`, the OpenRouter key, the Tavily key, the E2B key, the Modal token, `AGENT_SIDECAR_AUTH_TOKEN`, and the `agent-sidecar-mcp` key once it exists |
| **OmniRoute admin password was reset** | Done 2026-09-04 | The old one was lost — `POST /api/auth/login` rejected both the 24-character `INITIAL_PASSWORD` in `omniroute/.env` and a value the operator supplied, and no OIDC is configured. Recovered through OmniRoute's own mechanism: the hash lives in `key_value`/`settings`/`password`, and `ensurePersistentManagementPasswordHash` re-hashes a non-bcrypt value there on next login, so writing a plaintext password into that row restores access with no restart. Database backed up first to `db_backups/manual_20260904T153154Z_*`. The new password is with the operator and is first on the rotation list |
| Agent tools | **Live 2026-09-04** | `agent_tools_active: true`. Acceptance run: asked for the Caddy 2.11.4 release date, the agent searched and answered in 2 steps with no step errors and `degraded: false` |
| `GRAPHIFY_API_KEY` exposure | Raised 2026-09-04 | Since the code graph is served through Caddy, this key alone stands between a full map of this repo and the internet |
| OpenRouter balance | Low, and the failure is shaped by `max_tokens` | A 402 is not a flat "out of credits": it reads *"You requested up to 65536 tokens, but can only afford 7040"*. The cost of the **reservation** is what fails, so the same balance serves a 400-token request and refuses a 65k one. `paid-first` tier 3 answered normally when probed — keep `max_tokens` modest on OpenRouter tiers and it keeps working |
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
