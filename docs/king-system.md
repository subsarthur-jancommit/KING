# KING — what is built, what works, and what does not

**Verified against the live VPS (`34.101.62.94`) — most recently 2026-09-05.**
was measured, not estimated. Where something is unproven, unmeasured, or broken,
it says so — this document is only useful if it can be trusted when it reports
bad news.

---

## Contents

- [1. What KING is](#1-what-king-is)
- [2. What is actually running](#2-what-is-actually-running)
- [3. Providers available today](#3-providers-available-today)
- [4. Routing](#4-routing)
- [5. Workflows and agentic patterns](#5-workflows-and-agentic-patterns)
- [5a. The bridge — how Claude reaches any of this](#5a-the-bridge-how-claude-reaches-any-of-this)
- [5b. The agentic layer](#5b-the-agentic-layer)
- [6. The code graph](#6-the-code-graph)
- [7. Guards](#7-guards)
- [8. Access control](#8-access-control)
- [9. Costs, honestly](#9-costs-honestly)
- [10. What was tried and abandoned](#10-what-was-tried-and-abandoned)
- [11. Open, deferred, and risky](#11-open-deferred-and-risky)
- [12. Use cases this supports today](#12-use-cases-this-supports-today)
- [13. Scope for what comes next](#13-scope-for-what-comes-next)
- [Rules that survived contact with production](#rules-that-survived-contact-with-production)

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

Nine containers, all healthy at time of writing.

| Container | Role | Profile |
|---|---|---|
| `omniroute-base` | Model gateway | `base` |
| `activepieces` | Workflow engine | `workflow` |
| `ap-redis` | Activepieces queue | `workflow` |
| `ollama` | Local model | `localmodel` |
| `codegraph-serve` | Code graph over MCP | `codegraph` |
| `agent-sidecar-http` | The agent, over HTTP and MCP | `agent-sidecar-http` |
| `caddy` | TLS and reverse proxy | `proxy` |
| `otel-collector` | Traces to Langfuse | `tracing` |
| `redis` | Gateway cache | `base` |

**Host budget (2026-09-05):** 3,496 MB of 7,936 MB used, 4,439 MB available.
Disk 35 GB of 48 GB (73%) — that climbed to 77% during a day of repeated
image builds, and `docker builder prune -f --filter until=24h` gave 3.3 GB
back. Preflight now names reclaimable build cache on a pass, not only when
the disk check fails.

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
by something other than the model requested, including the acceptance runs.
That explains the measurement that looked so tidy earlier: the free-tier
default answered exactly as well as `agy/claude-sonnet-4-6`, because under that
probe's prompt both were `big-pickle`. Under the prompt the sidecar really
sends, both are `gemini-3.7-flash-high` — see the destination note further
down; which model answers is not a fixed property of this fault.

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

So the classifier is not the switch, or not the only one.

**Every lever that looked like the switch has now been checked, and none is.**
Recorded together so nobody spends the afternoon on it a second time:

| Candidate | Verdict |
|---|---|
| `intentDetectionEnabled: false` | Set live on the gateway, probe re-run, `strategy=auto` before, during and after. Restored immediately |
| A key's `allowed_models` | Not consulted on the rerouted path — a key permitted only `ollama/…` was served `oc/big-pickle`, no 403 |
| `settings.blockedProviders` | Filters the `auto/*` candidate pool, which is exactly where the reroute lands — but only over `NOAUTH_PROVIDERS`, via `getNoAuthCandidates` in `virtualFactory.ts`. `antigravity` is OAuth-registered, so it cannot be excluded, and there is no equivalent filter for authenticated providers |
| `api_keys.auto_resolve` | The last unchecked one, and the most promising by name. It is stored, settable through `PATCH /api/keys/{id}`, shown in the dashboard, carried in the sync bundle and declared in `apiKeyPolicy.ts` — and **never read by the routing layer**. The identifier does not occur anywhere in `open-sse/`, and in `apiKeyPolicy.ts` it is a type field with no logic behind it |

The pattern across all four is worth naming: each is a control that *exists* —
a settings flag, a per-key list, a blocklist, a column — and none of them is
wired to the decision they appear to govern. A control you can set and that
changes nothing is worse than an absent one, because setting it feels like
having acted.

`omniroute/` is a vendored subtree that must not be edited, so any fix is a
setting or nothing — and every setting is now ruled out by inspection rather
than by assumption.

**Diagnostic worth keeping:** `x-omniroute-decision`, `-provider`, `-model` and
`-request-id` are on every response. Reading them first would have skipped most
of the eight eliminations above.


### There is one mitigation, and it is a trade

Every *setting* is ruled out above. The prompt is not a setting, and the sidecar
owns its own.

Bisecting the real 135-line ToolCallingAgent prompt against
`x-omniroute-decision`, one block at a time, exactly two regions flip the
strategy on their own:

```
lines   1-33   single      lines  59-67   single
lines  34-50   single      lines  68-90   single
lines  51-58   AUTO   <--  lines 111-135  AUTO   <--
```

`51-58` is smolagents' worked example, a call to `python_interpreter` — a tool
this agent does not have. `111-135` is the **code-graph tool descriptions**:
`graphify-out/graph.json`, nodes, edges, BFS/DFS.

Removing either alone still routes `auto`. Removing both returns `single`,
3 of 3. So the capability and the trigger are partly the same text, and the fix
is a trade rather than a repair.

**Measured end to end**, with the example retargeted in `smol_runner.py` and the
four graph tools left out of `AGENT_SIDECAR_AGENT_TOOLS`:

```
asked for   ollama/qwen2.5:1.5b-instruct-q4_K_M
served_by   qwen2.5:1.5b-instruct-q4_K_M
step_errors []            <- no "local-only work left the host"
tools       7 selected
```

That is the first tool-bearing agent run on this deployment to be served the
model it asked for. **The local-only guarantee can be made real** — it costs the
code graph, and, on this host, 241 s against ~10 s, because the answer is
genuinely coming from a 1.5B model on two vCPUs instead of Gemini.

Not applied by default. Dropping four tools and multiplying latency by twenty is
the operator's call, not a default, and the honest position is that both
configurations are defensible: keep the graph and accept the reroute, or hold
the guarantee and lose the graph. What changed is that it is now a choice.

### What the reroute lands on is less reliable than what it leaves

Measured 2026-09-05 from `/api/usage/call-logs`, 500 completed calls spanning
2026-08-30 to 2026-09-05, grouped by provider and model:

```
provider       model                            calls  failed   rate
opencode       big-pickle                         102       0     0%
antigravity    claude-opus-4-6-thinking-high       75      15    20%
antigravity    claude-sonnet-4-6                   68       5     7%
antigravity    gemini-3.7-flash-high               56      12    21%
ollama         qwen2.5:1.5b-instruct-q4_K_M        55      18    33%

top failure signature:  502 "Provider returned empty content"  x36
```

Every 502 in the window is antigravity's. The free tier that the routing design
treats as the fallback of last resort did not fail once in 102 calls.

That inverts an assumption worth stating plainly, because `paid-first` is built
on it: `agy` is the strongest and cheapest-per-call tier, and it is also the
least reliable one here. Its leading model — the first rung of `paid-first` —
fails one attempt in five.

**Two caveats, or this reads as worse than it is.** These are *per-attempt*
rates, not per-request. A `priority` combo whose first rung 502s falls through
and logs both the failure and the eventual success, so a share of the 20% on
`claude-opus-4-6-thinking-high` is the ladder doing exactly its job — the caller
still got an answer. And `ollama`'s 33% is the documented
`RATE_LIMIT_MAX_WAIT_MS` 504 against a cold local model, which is why the
monitor excludes it from the breach ratio.

**A third caveat, and it retires the alarming reading of this table.** I first
wrote that the sidecar's case survives both caveats, because it names a model
directly and so "has no ladder underneath it to absorb a failure". That was an
assertion about the absence of a mechanism, made without looking for one. There
are two.

The gateway falls back inside the model family. On an empty-content response
`chatCore.ts` logs `FAILED 502` to the call log **and then calls
`getNextFamilyFallback`**, retrying the next member of the same family before
answering the client. That is visible in the 07:56 alert itself, whose three
samples are `gemini-3.7-flash-high`, `-medium` and `-low` in sequence — not
three independent failures, one request walking down a family.

Underneath that, the OpenAI SDK retries. `client.max_retries` is 2 on the live
container (the SDK default, never overridden), and its `_should_retry` returns
true for any status `>= 500`, so a 502 that survives the family fallback is
still attempted twice more.

The call-log clustering fits: 502s arrive as `{1: 10, 2: 2, 3: 1, 5: 4}`. A
lone 502 is what a *recovered* request looks like — one attempt logged, then a
success. The 5-clusters are all from 2026-08-30 and are combo tiers, a
different mechanism again.

**So these are attempt rates, and the layers below them are why eight sidecar
runs in a row succeeded against a "21% failure" model.** The number is real; it
is not the number a caller experiences.

**Which matters most for the alert wired in §7.** `gateway_monitor` computes its
ratio from `call_logs`, and those rows are *attempts* — including every one the
gateway itself recovered from a moment later. A 44% error ratio can therefore
describe a window in which no caller saw a single failure. Read a WARNING as
"the providers are working harder than usual", not as "requests are failing",
and confirm user-visible impact from `served_by` and `degraded` in the run
journal before treating it as an outage.

Still true, and unchanged by any of this: the reroute moves agent traffic from
`big-pickle`, which has not failed once in 102 calls, onto a family that needs
its fallback regularly. That is a real quality and latency cost even when every
request eventually succeeds.

That question — "does anything retry after a 502" — was left open here for
about an hour, with the note that eight successful runs were "equally consistent
with an invisible retry absorbing failures". They were. Reading the gateway's
own source answered it in two greps, which is where that should have started.

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
one settings lever was tested and does nothing. So the override is *reported*
instead — `summarise()` in `outcome.py` compares the model asked for against
`served_by` and carries the answer in `model_overridden`.

It was folded into `degraded` first, which is the obvious design and the wrong
one. The gateway does this on essentially every agent run, so `degraded` went
true every time and stopped distinguishing anything; a flag that is always on
trains the reader to ignore the one signal that means the answer itself may be
wrong. `degraded` keeps its narrow meaning — a step failed, or a configured
tool did not load — and the routing fact rides in its own field:

```
2026-09-05, both through POST /run:
asked agy/claude-sonnet-4-6  -> served gemini-3.7-flash-high
   model_overridden=true   degraded=false   step_errors=[]
asked opencode/big-pickle    -> served gemini-3.7-flash-high
   model_overridden=true   degraded=false   step_errors=[]
```

**The destination depends on the prompt too, which is the part worth carrying
forward.** The bisection above established that prompt content decides the
*strategy*. It does not stop there: content also decides where `auto` then
lands. Measured within the same five minutes on 2026-09-05, both deterministic:

```
one-line trigger, via /v1        -> oc/big-pickle             6 of 6
smolagents system prompt, /run   -> gemini-3.7-flash-high     3 of 3
```

Same key, same requested model, same gateway, same minute. The only difference
is the prompt. So every `oc/big-pickle` figure recorded on 2026-09-04 was a
measurement of the *probe's* prompt, and generalising it to what the sidecar
actually sends was not warranted — see mistakes entry 20.

Two consequences. The second line of the block above is not a control any more:
`opencode/big-pickle` was chosen on 2026-09-04 as "the model `auto` picks
anyway", which held for the probe's prompt and does not hold for the sidecar's.
And any check that looks for a particular provider name is testing the prompt
it happens to send, not the fault. `scripts/check-model-routing.sh` reports
whether two prompts *disagree*, which is why it survives this.

**One override is treated differently.** Naming `ollama/...` is how a caller
says the work must not leave this host, so that override alone is appended to
`step_errors` and does set `degraded`:

```
local-only work left the host: asked for ollama/qwen2.5:1.5b-instruct-q4_K_M,
served by big-pickle
```

It cannot prevent the egress — by the time a response exists the request has
already been served elsewhere. It can refuse to be quiet about it, and it
should not be filed under the flag someone has learned to ignore.

**And it can be re-tested.** `./scripts/check-model-routing.sh` asks for the
local model twice — once plain, once with an agent-shaped system line — and
prints the provider that answered each. It probes with the local model on
purpose: that is the one destination the reroute never selects, so "served by
something else" is unambiguous. It exits non-zero while the override
reproduces. Run it after any `git subtree pull`, which is the only way this
can change.

**And it escapes the API key's model restrictions.** This is the more serious
half, because those restrictions are what §8 uses as access control.

A temporary key was created allowing exactly one model —
`allowed_models: ["ollama/qwen2.5:1.5b-instruct-q4_K_M"]`, nothing else — and
then deleted. With it:

```
plain prompt         provider=ollama  ->  qwen2.5:1.5b-instruct-q4_K_M   allowed
agent-shaped prompt  provider=oc      ->  big-pickle                     NOT allowed
```

The second request was served by a model the key is explicitly forbidden from
using. No 403, no warning.

A first probe looked like the restriction held — a key allowing only
`opencode/big-pickle` was served `big-pickle` under both prompts. That was
coincidence, not enforcement: the reroute happened to land on the one model
that was permitted. Testing with a key whose allowed model is the *local* one,
which the reroute never lands on, is what separated the two readings.

**What this means for §8.** Keys there are scoped so that "what a robot can
reach is narrower than what the operator can" — `gateway-monitor-triage`
excluded from `agy/*`, `flow-search` restricted to search. Those restrictions
hold for ordinary prompts and are not a boundary against a prompt that trips
the content switch. Treat them as cost control, not as a security boundary,
until this is fixed upstream.

**It can send private work off the machine.** This is the consequence that
matters most, and it is not about cost. Requesting the *local* model:

```
plain prompt        provider=ollama  ->  qwen2.5:1.5b-instruct-q4_K_M   (stays here)
agent-shaped prompt provider=oc      ->  big-pickle                     (leaves)
```

So "point at ollama and nothing egresses" holds for a plain prompt and **not**
unconditionally. A prompt that trips the content switch — one stating an intent
to reason or to write code — can be forwarded to a third-party provider with no
error, no warning, and a normal-looking answer. Anything routed to the local
model *because* it must not leave the host should have `served_by` checked, and
the sidecar's `model_overridden` flag exists partly for this.

A caller going direct to `/v1/chat/completions` gets no such flag. The
`x-omniroute-provider` response header is the equivalent there, and it is on
every response.

Demonstrated on the deployment, and it is not a small hop:

```
asked      ollama/qwen2.5:1.5b-instruct-q4_K_M     (on this host)
served_by  gemini-3.7-flash-high                   (Google, via agy)
degraded   true
           "local-only work left the host: asked for ollama/…, served by gemini-…"
```

A request explicitly addressed to the on-host model was answered by a
third-party cloud model. That case, and only that case, sets `degraded` —
being served `gemini` instead of `big-pickle` is a cost question, being served
anything instead of `ollama` is a confidentiality one, and filing them together
would put the second under a flag that is true too often to read.

**It goes both ways**, which the flag caught within the hour. A later run asking
for `opencode/big-pickle` — the free tier — was served by
`gemini-3.7-flash-high`, spending subscription quota nobody requested:

```
"model override: asked for opencode/big-pickle, served by gemini-3.7-flash-high"
```

So this is not "the gateway prefers the cheap model". It is content-dependent
routing that can land anywhere — three runs of the same task were served by
`big-pickle`, `gemini-3.7-flash-high` and `gemini-3.1-flash-lite` — and the
only reason any of it is visible is that the response says which model answered.

**It has its own flag, not `degraded`.** Folding it in was the first attempt and
watching real traffic killed it: the reroute happens on essentially every agent
run, so `degraded` went true every single time, including on runs that answered
correctly with no errors. A flag that is always on is worse than no flag —
it teaches the caller to ignore the one signal meaning the answer itself may be
wrong. Live, after the split:

```
result           59410
served_by        gemini-3.1-flash-lite
model_overridden true
degraded         false
step_errors      []
```

`degraded` keeps its narrow meaning: a step failed, or a configured tool did not
load.

`./scripts/agent-report.sh` counts the rate against runs that actually recorded
the field, and the first honest reading was **2 of 2 — every run that measured
it**. That is the number that justifies the split: a flag true 100% of the time
carries no information, and folding it into `degraded` would have destroyed a
signal that does.

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

## 5a. The bridge — how Claude reaches any of this

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

## 5b. The agentic layer

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
 "served_by": "claude-sonnet-4-6",
 "tools": {"enabled": true, "offered": 120,
           "selected": ["omniroute_web_search", "get_neighbors", "…"],
           "missing": [], "misdirected": []},
 "tools_used": ["graph_stats"],
 "model_overridden": false, "degraded": false}
```

`tools` is what the agent was **handed**; `tools_used` is what it actually
reached for. Those are different questions and only the second says whether
eleven tool descriptions earn the context they cost on every single call.
Measured live: a code-graph question returns `["graph_stats"]`, and "what is 6
times 7" returns `[]` — an empty list is a real answer, not a missing one.

`final_answer` is deliberately excluded. It is smolagents' terminator, called on
essentially every successful run, and a constant in a field whose job is showing
what varies is how `degraded` stopped being worth reading.

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

**And which project path to name, for the same reason.** Measured 2026-09-06:
a graph query took five steps and returned `degraded`, failing at
`step 1: Argument project_path is required`. The MCP schema does **not** list
that argument as required — smolagents requires every declared input regardless,
so a tool whose own spec calls an argument optional still rejects a call that
omits it. That is the same mechanism as `provider`, found a second time because
the first finding was recorded as being about `provider` rather than about
smolagents' validation.

The value is `/out`, the directory holding `graphify-out/graph.json` inside the
graph server, verified with a direct `graph_stats` call returning 59,582 nodes
and 163,809 edges. Pinning it in the instructions, same run, same task:

```
before   steps=5   degraded=true    step 1: Argument project_path is required
after    steps=3   degraded=false   step_errors=[]
```

The answer improved as well as the step count — it came back with file paths and
line numbers rather than a bare list of names. A test asserts both pins are
present, because the instructions read like prose and prose invites tidying.

**How far that generalises, audited rather than guessed.** Asking smolagents
itself which inputs it will demand, for all eleven tools it holds:

```
omniroute_web_search    query, max_results, search_type, provider
omniroute_web_fetch     url, provider, format, include_metadata, depth, wait_for_selector
omniroute_memory_search apiKeyId, query, type, maxTokens, limit
omniroute_memory_add    apiKeyId, sessionId, type, key, content, metadata
get_neighbors           label, relation_filter, token_budget, project_path
graph_stats             project_path
omniroute_get_health    (none)
```

Nearly every declared input, including plainly optional ones like `depth` and
`format`. The natural conclusion — that the memory tools are unusable, since an
agent cannot know its own `apiKeyId` — is wrong, and was checked before being
written down. Measured 2026-09-06, two separate runs:

```
run 1   "store: the disk was at 74 percent"   tools_used=[omniroute_memory_add]     2 steps, degraded=false
run 2   "search memory for that percentage"   tools_used=[omniroute_memory_search]  2 steps, degraded=false
        answer: 74 percent
```

So the agent supplies something acceptable for those fields and the server takes
it. The tools work, and the round trip across separate runs — the claim in §12
that it remembers what you tell it — is re-verified rather than inherited.

What actually needs pinning is narrower than "everything required": it is
arguments whose **value cannot be guessed from the task**. There are two on this
deployment, `provider` and `project_path`, and both are now in the instructions.
The rest the model fills in sensibly on its first attempt.

### The local model: what the hardware actually allows — measured 2026-09-06

Asked to install "the best local model that fits in the remaining space", the
survey found the premise does not bind. Disk had 12 GB free and now has 18;
a 7B model fits it easily. **The ceiling is one physical core.**

```
$ lscpu
CPU(s):                 2
Thread(s) per core:     2
Core(s) per socket:     1     <-- one physical core, SMT gives the second thread
```

For AVX2 matrix work that already saturates the vector unit, an SMT sibling adds
almost nothing. Measured rather than assumed: raising `OLLAMA_CPUS` from `1.0`
to `2.0` moved prefill from **26.3 to 25.9 tok/s** — no gain, because there is
no second core to allocate. The setting is kept at `2.0` anyway, since it costs
nothing and becomes real the day the host grows.

**The bake-off.** Every candidate pulled and measured on this host, same
2,050-token prompt, unique text each run so the KV prefix cache could not answer:

| model | prefill | generate | 15-case eval | verdict |
|---|---|---|---|---|
| `qwen2.5:1.5b-instruct-q4_K_M` | 25.9 t/s | 16.1 t/s | **13/15 = 87%**, 1.3 s/case | **kept** |
| `qwen3:1.7b` | 23.8 t/s | 6.9 t/s | unusable — see below | removed |
| `qwen3:4b` | 9.2 t/s | 3.0 t/s | not reached | removed |

`qwen3:4b` failed on three counts, not one. It is 2.8× slower on prefill and
5.4× on generation — 244 s for a prompt the incumbent answers in 87 s. It loads
at **3.2 GB against a 3.25 GB cap**, leaving nothing for KV growth at longer
contexts. And it degraded the host while resident: `king-ollama-1` sat at
**100.38% of its limit** and swap rose from 302 MB to 861 MB, at which point a
36-token prompt took 258 s. Removing it returned the host to 2.5 GB used.

`qwen3:1.7b` is not slow — it never answers. It enters thinking mode on every
request and `/no_think` is not honoured by this Ollama build's OpenAI-compatible
endpoint: 256 completion tokens spent reasoning, `finish_reason: length`,
`content: ''`. A classification the incumbent returns in 1.3 s costs 28.5 s and
produces nothing.

So the incumbent stays, which the plan anticipated: *"if nothing beats the 1.5B
meaningfully, we stop at the 1.5B and that is a legitimate result."* Its two
misses are the two already on record — an unlabelled sentiment case, and
`"write a bash script to rotate nginx logs weekly"` classified LOCAL instead of
PAID.

**What did improve is the ceiling, and it is the larger of the two wins.**
`RATE_LIMIT_MAX_WAIT_MS` defaults to 15000 and is read from `process.env`
(`resilience/settings.ts:44`), so it belongs in `omniroute/.env`. That 15-second
cap is not an upstream timeout — it bounds how long a request may wait for a
local rate-limit slot, and a local model needs longer than that for any
realistic prompt. It was rejecting **28 of 66 ollama calls (42%)**, 27 of them
`504 Request exceeded OmniRoute's local rate-limit`. It is also the real reason
the 3B model was rejected weeks ago and recorded in `docker-compose.yml` as
*"returned 504 through the gateway twice"* — read ever since as a fact about the
model.

Raised to 180000, with `RATE_LIMIT_MAX_QUEUE_DEPTH=8` alongside it because the
wait is **global** — there is no per-provider override, so lifting it alone
would let a slow remote provider queue for three minutes instead of failing
fast. Proven: a 12,088-character local request that takes **80.9 s now returns
200**, where it previously died at 15.

One measurement trap worth repeating, because it produced a false pass first:
a repeat of the same filler prompt returned in 1.0 s. That was Ollama's KV
prefix cache, not the fix. Every number above uses text unique to its run.


### Local as the default: tried, measured, reverted the same hour

The plan approved on 2026-09-06 made the local model the sidecar's default. It
was set, measured, and turned off again, because two configurations exist and
neither works:

```
7 tools, local model     served_by qwen2.5:1.5b   <- LOCAL, not overridden
                         degraded=true, 9 step errors, 1m47s
                         "Error while parsing tool call: no JSON blob" x7

no tools, local model    1 step, 0 errors, 10-21s
                         served_by gemini-3.7-flash-low   <- NOT local at all
```

With tools the request stays on the host and the 1.5B model cannot drive the
protocol: it spent all eight steps failing to emit tool-call JSON and reached
the right answer only by exhausting `max_steps`. Without tools the model copes
fine — because `uses_tool_calling([])` selects **CodeAgent**, whose system
prompt is *about writing Python*, which is trigger B of the content reroute and
the one no rewording avoided. The work left the machine.

So the local model can stay on the host, or it can be useful as an agent, but
not both. Making it the default meant `degraded=true` on every call, which
destroys the flag's meaning — the exact mistake this repo already corrected once
by splitting `model_overridden` out of `degraded`.

**What survives, and it is the part worth having.** Ask for an `ollama/` model
explicitly and the guarantee holds, verified after the revert:

```
model      ollama/qwen2.5:1.5b-instruct-q4_K_M
served_by  qwen2.5:1.5b-instruct-q4_K_M     <- honoured
tools      7 (code graph dropped automatically)
egress     no "left the host" step error
```

For work that must not leave the machine, that is the only configuration that
keeps the promise, and it is now one request field away. Direct `/v1` calls to
the local model — what `local-router.sh` does — were never affected; only the
agent path fails.

The honest summary is that the ceiling fix was the real win here and the model
swap was not. A 1.5B model is a classifier, not an agent, and no amount of
memory or CPU budget on one physical core changes that.


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

### The code graph is one of its tools, since 2026-09-05

The agent loads from **two** MCP servers now: OmniRoute's 110 and codegraph's
ten, 120 offered in total. Four of the graph's are allowlisted, all read-only —
`get_neighbors`, `get_node`, `query_graph`, `graph_stats`.

That inverts a waste. "What calls this function" answered by the agent costs a
tool call; answered by Claude it costs reading twenty files into a context that
stays full for the rest of the session, which is the thing this service exists
to avoid.

Verified end to end: asked for graph statistics, the agent called `graph_stats`
and returned **59,410 nodes and 163,526 edges** in two steps, with `missing: []`.

And verified working *together*, which is the part that matters — one task
needing both servers:

```
task    "graph_stats for the node count, then web search for Caddy's stable version"
result  nodes=59410, caddy=2.11.4
        3 steps, 15,889 tokens, degraded=false
```

A private code fact and a live web fact in one answer, from two independent
services, neither of which cost Claude any context.

The two servers stay independent — separate service, separate key, separate
failure. Without `GRAPHIFY_API_KEY` the second one is simply absent and the
agent keeps its web search; a graph outage costs it four tools, not eleven.

**That took a second attempt.** smolagents' `MCPClient` accepts a *list* of
servers, and passing one reads better. It is all-or-nothing: pointed at a dead
port, the client raised `TimeoutError` and the agent loaded **zero** tools —
so the first version made web search depend on the code graph being up, exactly
inverting the point. One client per server, connected independently, and each
failure reported in `tools.error` rather than swallowed.

The claim in the paragraph above was written before it was tested, and testing
it is what found the regression. Measured in **both** directions after the fix.

With an invalid `OMNIROUTE_MCP_API_KEY` — which is what a rotation looks like
before the new key is in place:

```
tools loaded  4          the code graph's, unaffected
offered       10         codegraph only
missing       7          the OmniRoute ones
error         http://omniroute-base:20128/api/mcp/stream: TimeoutError after 30s
```

**A revoked key presents as a timeout, not an auth error.** Worth knowing
before rotating anything: the symptom is a 30-second pause and
`TimeoutError`, not `403 invalid key`, so the obvious reading is "the gateway
is down" rather than "I have not updated this key yet".

And with the code graph pointed at a dead port:

```
tools loaded  7          (was 0)
offered       110        OmniRoute only
missing       get_neighbors, get_node, query_graph, graph_stats
error         http://codegraph-serve:9999/mcp: TimeoutError: Couldn't connect…
```

The PR tools (`list_prs`, `get_pr_impact`, `triage_prs`) are deliberately left
out. An agent that reads web pages should not be reaching into pull requests.

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
 "tools":["omniroute_web_search","…"],"tools_used":["omniroute_web_search"],
 "step_errors":[],"degraded":false}
```

Both outcomes are written, the successful one and the 500 — a journal that only
records successes answers the least interesting half of every question. Task
text is truncated to 200 characters, the same choice the `vps_exec` audit makes
with commands: enough to recognise a run, not a transcript.

Writing is best-effort. A full disk must not turn working runs into 500s, and
must not silently look like it logged either, so the failure goes to stderr and
into the container log. That path has a test, because "best-effort" is the kind
of promise that quietly stops being true.

**It is bounded.** An append-only file that nothing rotates is a slow leak, and
a full disk takes down every container on this host rather than only the one
that filled it. Capped at 5 MB; measured at 496 bytes an entry, that holds
about 10,500 runs. Past the cap the newest half is kept rather than the file
emptied — history that vanishes periodically and without warning is worse than
a bounded window — and a line is written into the journal saying a trim
happened, so a reader never mistakes what survived for the whole story.

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
| `gateway-report.sh` | When you want to know | How each caller's traffic was routed. Measured 2026-09-06: the sidecar had 141 of 204 calls rerouted through `auto/*`, and `local-router-probe` 4 of 4 — the gateway recording its own override |
| `alerts-report.sh` | When you want to know | What the gateway has been complaining about. Reads Postgres directly, like `monitor-deadman.sh`, so it still answers when the Activepieces engine is wedged — one of the states you would most want to ask about |
| `pool-prove.timer` | Weekly, Sun 04:17 | A registered provider that has gone silent. OmniRoute's own autopilot reported every provider "healthy, 0 issues" while three failed 100% of real requests; this sends a real completion to each and counts only answers |
| `verify-credentials.sh` | After any rotation | A key that was rotated and not updated here. Seven real calls, not presence tests; two of them assert that a *wrong* token is rejected, and one is a real admin login — the check whose absence let four scripts fail silently for two days |
| `check-model-routing.sh` | After any `git subtree pull` | Whether the gateway still overrides the model you asked for. Exits non-zero while it does |

### The alarm that now reaches somewhere — wired 2026-09-06

`gateway_monitor` works, and always did. It runs every fifteen minutes, reads
`/api/usage/call-logs`, computes a breach from a 15-minute window with a 0.30
ratio threshold and a `MIN_CALLS` floor of 3, derives a severity from the shape
of the failures, and HMAC-POSTs the result to the `gateway_alerts` webhook.

`gateway_alerts` received every one of those and threw them away. Fourteen
deliveries between 2026-08-29 and 2026-09-05, five on the last day, all
`SUCCEEDED`, and the `gateway_alerts` table still held **0 rows**. The flow was
two steps: the webhook, and a code step that shaped the payload and returned it
into nothing. Somebody built the sink and never wired the pipe.

**It is wired now.** Two changes, because the obvious one-step version would
have half-worked:

1. **`step_1` handles both payload shapes.** It read `d.provider`, `d.model` and
   `d.apiKeyName` — the shape of OmniRoute's own key/provider webhooks. A
   `monitor.error_rate` payload carries none of those: its providers are in
   `data.byProvider` and its models in `data.sample`. So on the alert type that
   actually fires, all three were `null`. Wiring the table without fixing this
   would have produced rows with an empty `provider` column for every monitor
   alert — a sink that looks connected and loses the most useful field in it.

   It now derives `provider` from the providers in `byProvider` that actually
   failed — not all of them, because `byProvider` deliberately includes the
   healthy ones and the local model, and listing every key would put
   "ollama, tavily-search" on an alert about antigravity. `detail` carries
   severity, the ratio sentence, the counts, and one real failure rather than a
   count of them.

2. **`step_2`, `@activepieces/piece-tables` / `tables-create-records`**, writing
   the five columns. `continueOnFailure` is deliberately off: a failed write
   should show as a failed run, which is louder than the silent drop being
   fixed.

**How it was verified, and what is still unobserved.** The shaping was run
against five payloads — the real 07:56 delivery, an OmniRoute key-cap webhook
(which must keep working unchanged), a breach with the local model present but
healthy (which must not name it), an empty body, and a monitor read failure.
Then the whole flow was run end to end on the real payload, producing:

```
event       monitor.error_rate
provider    antigravity
received_at 2026-09-05T07:56:21.923Z
detail      [WARNING] — error ratio 44% over 15m — 4/9 calls —
            e.g. antigravity/gemini-3.7-flash-high 502 Provider returned empty content
api_key     (null — monitor events carry no key, correctly)
```

That row and three diagnostic ones were then deleted. Fabricated rows in an
alert log are worse than an empty log: later nobody can tell them from real
ones.

Running `gateway_monitor` live immediately afterwards wrote no row, and that is
the correct outcome rather than a failure — the window held 0 ratio-eligible
calls, below the `MIN_CALLS` floor of 3, so there was no breach to report. It
was checked rather than assumed.

**Still unobserved: a real production breach writing a real row.** The trigger
path itself has fourteen prior successes, and the flow is proven end to end on
the exact payload that path delivers — but those are two facts about parts, and
this document is emphatic elsewhere about not treating that as a fact about the
whole. The next genuine breach is the proof, and the table is where to look for
it.

**Read the ratio as attempts, not outcomes.** `gateway_monitor` computes its
breach from `call_logs` rows, and those are individual provider *attempts* —
including every one the gateway recovered from a moment later via its
family fallback, and every one the OpenAI SDK retried successfully. A 44% error
ratio can describe a window in which no caller saw a single failure. §4 has the
mechanism. Treat a WARNING as "the providers are working harder than usual" and
confirm user-visible impact from `served_by` and `degraded` in the run journal
before calling it an outage.

**Reading them.** `./scripts/alerts-report.sh [days]` prints the table from the
command line, grouped by event and provider, with the same attempts-not-outcomes
caveat attached — because that is exactly where someone reads a 44% error ratio
and concludes there was an outage.

Verified with a positive control rather than by an empty run: an empty report
and a broken query look identical, so a row was inserted, confirmed to appear,
and deleted again. That control found two defects — it was printing the row's
insert time instead of the alert's own `received_at`, and its timestamp cast
would have failed the whole report on one malformed cell rather than degrading
a single line.

`ap_list_connections` returns nothing on this deployment, so there is no Slack,
Discord or email connection to push through — which is why the table is the
destination and not a stepping stone to one.

**A push destination — Discord, email — is still not wired**, and needs a URL
only the operator has. The table turns "alerts vanish" into "alerts accumulate
somewhere you can look", which is the part that did not need anyone's
permission.

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

> **The model scoping below is not a security boundary.** Measured 2026-09-05:
> a key allowing only `ollama/qwen2.5:1.5b-instruct-q4_K_M` was served
> `oc/big-pickle` — a model it is forbidden from using — when the prompt tripped
> the gateway's content-based reroute. No 403, no warning. The scopes hold for
> ordinary prompts and are cost control, not access control, against a prompt
> that trips the switch. Details and the measurement in §5b.
>
> **And scopes do not gate inference at all.** A temporary key with
> `scopes: ["search"]` — no `models`, no `routing` — completed a call to
> `/v1/chat/completions` on both a plain and an agent-shaped prompt. This is
> not the content reroute; the plain prompt passed too. Scopes gate the
> *management* API — `/api/mcp/stream` genuinely requires `manage`, verified
> separately — and do not restrict `/v1`.
>
> So whatever stops `flow-search` reaching a real model, it is the per-key
> model list rather than its scope. The two mechanisms are separate, and only
> one of them is a boundary on inference — the one the reroute escapes.

| Key | Access | Reason |
|---|---|---|
| `claude-code` | all | The operator's own interactive use |
| `activepieces` | restricted, **includes `agy/*`** | Flows built deliberately |
| `gateway-monitor-triage` | restricted, **excludes `agy/*`** | A 15-minute heartbeat doing triage has no use for frontier models and should not burn subscription quota |
| `flow-search` | restricted to `["search"]` | Intended to call `/v1/search` only. **Re-check what enforces this**: a key created with `scopes: ["search"]` and no model list completed a `/v1/chat/completions` call in testing, so the scope is not what stops it |
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
| **Credential rotation** | Deferred by the operator, to be done in one pass at the end. `./scripts/verify-credentials.sh` proves each key afterwards with real calls — seven checks, two of which assert a *rejection*, all passing as of 2026-09-05 | The list now includes the OmniRoute admin password, Neon connection string, Upstash token, two `/v1` keys, both Langfuse pairs, the `oma_` token, webhook HMAC secret, `GRAPHIFY_API_KEY`, the OpenRouter key, the Tavily key, the E2B key, the Modal token, `AGENT_SIDECAR_AUTH_TOKEN`, and the `agent-sidecar-mcp` key once it exists |
| **OmniRoute admin password was reset** | Done 2026-09-04 | The old one was lost — `POST /api/auth/login` rejected both the 24-character `INITIAL_PASSWORD` in `omniroute/.env` and a value the operator supplied, and no OIDC is configured. Recovered through OmniRoute's own mechanism: the hash lives in `key_value`/`settings`/`password`, and `ensurePersistentManagementPasswordHash` re-hashes a non-bcrypt value there on next login, so writing a plaintext password into that row restores access with no restart. Database backed up first to `db_backups/manual_20260904T153154Z_*`. The new password is with the operator and is first on the rotation list |
| Agent tools | **Live 2026-09-04** | `agent_tools_active: true`. Acceptance run: asked for the Caddy 2.11.4 release date, the agent searched and answered in 2 steps with no step errors and `degraded: false` |
| **Key model restrictions are not a boundary** | Found 2026-09-05 | A key allowing only `ollama/…` was served `oc/big-pickle` when the prompt tripped the content reroute — a model it is explicitly forbidden from using, with no 403. The scoping in §8 is cost control, not a security boundary. Not fixable here — the routing lives in the vendored subtree. `./scripts/check-model-routing.sh` on the VPS says whether it still reproduces, and exits non-zero while it does; run it after any `git subtree pull` |
| **Local-only work can leave the host — now avoidable** | Found 2026-09-05, mitigated 2026-09-06 | A request naming `ollama/...` is served elsewhere when the prompt trips the gateway's content-based reroute — for the sidecar's own prompt that destination is `gemini-3.7-flash-high`, i.e. Google, measured 3 of 3 on 2026-09-05. **A configuration exists that holds the guarantee**: retarget the prompt's `python_interpreter` example (done in `smol_runner.py`) and drop the four code-graph tools from `AGENT_SIDECAR_AGENT_TOOLS`. Measured: asked `ollama/…`, served `qwen2.5:1.5b-instruct-q4_K_M`, no egress step error. It costs the graph tools and 241 s against ~10 s. Not the default — see §4. Without it the confidentiality use case is conditional, not guaranteed — check `served_by` or `x-omniroute-provider`. Not fixable here: the routing lives in the vendored subtree. `./scripts/check-model-routing.sh` is the detector — it asks for the local model twice, once with an agent-shaped prompt, and prints which provider answered each. Still reproducing as of 2026-09-05 |
| **`agy` needs its fallbacks most often** | Measured 2026-09-05, qualified 2026-09-06 | Over 500 calls since 2026-08-30 every 502 belongs to antigravity — `claude-opus-4-6-thinking-high` 20% of *attempts*, `gemini-3.7-flash-high` 21%, against `opencode/big-pickle` at 0 of 102. These are attempts, not outcomes: the gateway falls back within the model family on empty content, and the OpenAI SDK retries any 5xx twice on top, which is why eight consecutive sidecar runs succeeded against the 21% model. The cost is quality and latency, not visible failure. §4 has the table and all three caveats |
| **`blockedProviders` cannot shape the reroute** | Checked 2026-09-06 | Worth writing down because it looks like it should. The reroute lands wherever `auto/*` chooses, and `blockedProviders` filters that candidate pool — so blocking `antigravity` looks like a way to stop rerouted work reaching Google. It is not: the list is consumed only by `getNoAuthCandidates`, which iterates `NOAUTH_PROVIDERS`, and `antigravity` is OAuth-registered rather than no-auth. There is no equivalent filter for authenticated providers. The reroute remains unfixable from here, and this is the third plausible mitigation to fail on inspection |
| **The local router is not local** | Found 2026-09-06 | `local-router.sh` asks for `ollama/qwen2.5:1.5b-instruct-q4_K_M` and is served by `antigravity/gemini-pro-agent` — four runs, four matching call-log rows. Both premises of the design are gone: it is not free at the margin, and the task description leaves the machine. Latency went from ~0.95 s to 7.3–10.2 s. It still labels correctly, which is why it went unnoticed. Retired from the live path already, so nothing depends on it — but the same fault reaches anything that assumes naming a local model keeps work local |
| **Alerts now land in a table** | Wired 2026-09-06 | `gateway_monitor` had been delivering breaches to `gateway_alerts` since 2026-08-29 — fourteen of them, all `SUCCEEDED` — and the flow shaped each one and returned it into nothing, leaving the destination table at 0 rows. Two steps now close it: the shaping handles the `monitor.error_rate` payload shape (whose provider lives in `byProvider`, not `data.provider`, so the one-step version would have written a null provider for every alert), and a Tables step records five columns. Verified end to end on the real 07:56 payload; §7 has the row it produced. **Still unobserved: a real breach writing a real row** — that is the proof, and the table is where to look |
| **The gateway runs a TLS binary with a known CVE** | Found 2026-09-05 | `omniroute:base` was built 2026-08-27 and carries `tls-client-linux-ubuntu-amd64-1.15.1.so`, the binary OmniRoute PR #12612 pinned *away from* over CVE-2025-68121. Verified against the advisory rather than that PR: GHSA-h355-32pf-p2xm is **medium, CVSS 4.8** — a `crypto/tls` session-resumption flaw where a mutated `ClientCAs`/`RootCAs` pool may resume a session it should reject — not the "CVSS 9.8 out-of-bounds read" the PR claims. Rebuilding is what would replace it, and rebuilding is exactly what the upstream break prevents, so the two open items are one problem: the image is frozen at 2026-08-27 until `tls-client-node` is fixed |
| `GRAPHIFY_API_KEY` exposure | Raised 2026-09-04 | Since the code graph is served through Caddy, this key alone stands between a full map of this repo and the internet |
| OpenRouter balance | Low, and the failure is shaped by `max_tokens` | A 402 is not a flat "out of credits": it reads *"You requested up to 65536 tokens, but can only afford 7040"*. The cost of the **reservation** is what fails, so the same balance serves a 400-token request and refuses a 65k one. `paid-first` tier 3 answered normally when probed — keep `max_tokens` modest on OpenRouter tiers and it keeps working |
| Tavily credit | Finite | No fallback by design — it will fail loudly |
| `agy` subscription risk | Accepted knowingly | Flagged `subscriptionRisk: true` in OmniRoute's own catalog |
| `agy` agentic loops | **Broken** | Round-two 502 also triggers a cooldown affecting other traffic |
| Router accuracy | 86% | Good enough to save money, not good enough to be unsupervised on important work |
| Code graph freshness | Up to a day | Weeks behind would be dangerous |
| ~~`no-think` in `blockedProviders`~~ | **Removed 2026-09-06** | Checked against the vendored registry 2026-09-06: 15 of the 16 entries are real provider ids or aliases and `no-think` is not one — it is a model-id prefix (`NO_THINKING_PREFIX = "no-think/"`). The list is read in exactly one place, `getNoAuthCandidates` in `virtualFactory.ts`, and compared against `providerDef.id` and `.alias`, so the entry can never match. Harmless to remove, and it changes nothing |

---

## 12. Use cases this supports today

Each of these is running, not planned.

1. **Code review without spending Claude context.** A ten-file diff goes through
   `review_code` on Opus 4.6; Claude reads only the findings and decides which
   matter. Proven on a real race condition and an `eval()` injection.
   Re-checked 2026-09-05 against two planted bugs and it caught both in 11.3 s,
   including the subtle one — `items[len(items) - n:]` wrapping to the end of
   the list when `n` exceeds the length, explained with a worked example rather
   than a rule.
2. **"If I change this, what breaks?"** One `get_neighbors` call against the code
   graph, answered with file and line numbers, instead of reading twenty files
   into context that stays there for the rest of the session.
3. **Current-facts research with citations.** Both retrieval flows re-verified
   2026-09-05: `search_web` answered in 10.9 s over five sources, `web_research`
   in 23 s over six, each at $0.008. `web_research` answered "latest
   stable Caddy and its release date" as v2.11.4 / 3 June 2026 across four
   corroborating sources, and flagged a one-day discrepancy on one of them as a
   likely timezone artefact.
4. **Bulk classification at zero cost.** An Activepieces flow over
   `free-then-local` for hundreds of items, running unattended.
5. **Work that must not leave the machine — with a caveat that matters.**
   `ollama/qwen2.5:1.5b-instruct-q4_K_M` answers in 9.8 s and nothing egresses
   **for a plain prompt**. It is not an unconditional guarantee: see the
   confidentiality note in §5b. Check `served_by` before trusting it.
6. **Unattended monitoring, and the alerts now land somewhere.** The gateway is
   checked every 15 minutes, a dead-man switch watches the monitor, and a weekly
   `pool-prove` timer proves every provider still answers. All three verified
   running. Since 2026-09-06 a breach is recorded in the `gateway_alerts` table
   instead of being shaped and dropped — read it with
   `./scripts/alerts-report.sh`. Nobody is *told*, which is the remaining half:
   a push destination needs a URL only the operator has, and this project has no
   Slack, Discord or email connection configured.
7. **Spend triage — but not the way it was designed, and not for free.**
   `local-router.sh` still labels correctly: PAID for a refactor, FREE for a
   translation, measured again 2026-09-06. Two things underneath it are no
   longer true.

   It asks for `ollama/qwen2.5:1.5b-instruct-q4_K_M` and is **served by
   `antigravity/gemini-pro-agent`** — four consecutive runs, four matching
   call-log rows. The content reroute in §4 catches the classification prompt
   like everything else agent-shaped. So the two premises the design rested on
   are both gone: it is not free at the margin, it spends `agy` subscription
   quota; and **the task description leaves this machine**, which is precisely
   what putting the decision layer on a local model was for.

   Latency moved with it: ~0.95 s when measured on 2026-08-30, 7.3–10.2 s over
   four runs now. Nothing about the script changed. It kept returning correct
   labels the whole time, which is why nobody looked — a component can be
   *right* and still not be doing what you think it is doing.

   The script is already retired from the live decision path, so nothing depends
   on this today. It matters because the same fault reaches the same way into
   anything that assumes naming a local model keeps work local.
8. **Hand a task to an agent instead of doing it yourself.** `POST /run`, or
   `run_agent` over the bridge: it searches the live web, fetches pages, and
   remembers what you tell it to across separate calls. Every reply carries what
   it cost, which tools it held, and whether to trust it. Measured at $0.008 per
   run — one Tavily search; the model is free at the margin either way.

---

## 13. Scope for what comes next

Ordered by value against effort, and grounded in what the measurements above
actually showed.

**Near term**

1. **Rotate credentials.** The one deferred item that grows with every session.
2. **Make silent degradation visible — done, and without touching the flows.**
   The agent reports `served_by` and `model_overridden` on every run. The flows
   still cannot report on themselves — the AI piece returns text, not a model
   name — and the plan here was to rewrite them onto HTTP steps so they could.

   They did not need rewriting. `./scripts/gateway-report.sh` reads what the
   gateway already records, grouped by API key, and classifies every call as
   rerouted through `auto/*`, sent through a ladder the caller chose, or left
   alone. Rewriting working flows so they could observe themselves would have
   risked the thing being measured in order to measure it.

   One honest limit, in the script and worth repeating: `requestedModel` in
   `call_logs` is written *after* routing chooses, so it always equals the
   served model and cannot recover what the caller originally asked for. The
   first version of the report compared those two fields and confidently
   reported zero overrides while the sidecar reported one on nearly every run.
   `comboName` is the field that survives the substitution.
3. ~~**A weekly `pool-register.sh --prove` timer.**~~ **Done 2026-09-06.**
   `pool-prove.timer` runs it Sunday 04:17 with a randomized delay, off the
   quarter-hour the other timers use so a burst of probe traffic never lands
   inside `gateway_monitor`'s window and moves the ratio it is judging. A silent
   provider fails the unit and posts to `gateway_alerts`, so it lands in the
   table rather than only in `journalctl`.

   Installing it found two things worth more than the timer. Four operator
   scripts had been unable to log in since 2026-09-04 — see the note below —
   and `providers.env` contained a search-provider env-var name, which scores
   "tak ada model" forever, so the timer would have failed every week for a
   structural reason on the day it was installed.
4. ~~**Remove `no-think` from `blockedProviders`.**~~ **Done 2026-09-06.**
   Removed via `PATCH /api/settings` after proving it inert rather than assuming
   it: 15 of the 16 entries are real provider ids or aliases and `no-think` is a
   model-id prefix, and the list is read in exactly one place, compared against
   `providerDef.id` and `.alias`. The write was diffed against a captured
   before-state — only `blockedProviders` and `settingsRevision` changed, all 84
   keys intact — and the gateway answered `/healthz` and a real completion
   afterwards.

**Medium term**

5. ~~**A larger decision model for routing.**~~ **Already happening, and it
   works — measured 2026-09-06.** The premise here was that prompt design is
   exhausted at 1.5B and a bigger model is the next real gain. Both halves have
   been overtaken: the router has not been reaching the 1.5B model at all. The
   content reroute serves it from `antigravity/gemini-pro-agent`, 4 of 4 calls
   in `gateway-report.sh`.

   So the experiment ran itself. `--eval` now scores **15/15 = 100%**, against
   86% when it was last measured on the local model — including
   `"write a bash script to rotate nginx logs weekly"`, recorded as a known
   failure that answered LOCAL and now answers PAID.

   Twice, on two different destinations. The first run was served by
   `antigravity/gemini-pro-agent` and the second by `oc`, both 100%. That is a
   stronger result than one run: the gain belongs to *not being a 1.5B model*
   rather than to any particular provider, so it survives the reroute moving —
   which it does, per the destination note in §4.

   That is a decision to make rather than a win to bank. The bigger model costs
   what the reroute costs everywhere else: **8.04 s mean against ~0.95 s**, `agy`
   subscription quota instead of free local compute, and the task description
   leaving the machine. If the routing layer is wanted back on-host, the
   accuracy question is settled and the remaining work is prompt-shaping the
   classifier so it stops tripping the reroute — not finding a larger model.

   Note the eval prints the model it *asks* for, which is not the one answering.
   Read `gateway-report.sh` alongside it.
6. **Web fetch for the flows — tested, and not justified yet.**
   `omniroute_web_fetch` is in the agent's allowlist and reaches Tavily. The
   flows work from snippets only, and the claim here was that this would fail on
   anything needing a page body. Probed twice on 2026-09-06 before building it:

   - *"list the exact bug-fix entries in the Caddy v2.11.4 release notes"* — the
     flow declined and gave the reason with a source: those notes are not
     published, "Life got in the way of us publishing the release notes." A
     fetch would not have helped, because there is no body to fetch. It also
     shows the honesty guard in the synthesis prompt doing its job rather than
     inventing entries.
   - *"what line-length limit does PEP 8 set for docstrings and comments, as
     distinct from code"* — answered correctly, 72 against 79, with four cited
     sources, from snippets alone.

   So the limitation is real in principle and not binding in practice, and
   adding a fetch step costs latency and Tavily credit on every research call.
   Left undone deliberately. What would justify it is a question whose answer
   sits in a page body that snippets truncate — when one turns up, the step is
   small and the flow already has the provider configured.
7. **Alerting that reaches a human.** Half done. As of 2026-09-06 alerts are
   recorded in the `gateway_alerts` table instead of being dropped — see §7 for
   what changed and how it was verified. That makes them findable, not
   noticeable: nobody is told, they accumulate somewhere you have to think to
   look. A push destination closes the rest and needs only a URL — a Discord
   webhook takes no OAuth — which is why it is still here rather than done.

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
