# KING — definitive development plan

**Written 2026-08-31.** Every claim about the current system here was measured,
not assumed. The section that matters is **§4 HASIL** — it states exactly what
will exist when this plan is done, in terms you can run and check.

The next session breaks this into tasks. This document decides *what* and
*why*; it does not decide *how*.

---

## 1. Where we actually are

The gateway, the workflows, the local model, the code graph and the guards all
work. What does **not** exist is the thing the project is for: an agent that can
take a task, loop over tools until it is finished, and cost almost nothing.

Three routes to that were tried and measured:

| Route | Result |
|---|---|
| Tool loop inside the provider (`agy` native `web_search`) | **HTTP 502 on round two**, and the 502 drags the credential into a cooldown that breaks unrelated traffic |
| `run_agent` in Activepieces | **HTTP 404** — it calls an Activepieces-internal agent service absent from a self-hosted deployment |
| **`agent-sidecar` (smolagents)** | **Works.** Two steps, 6.4 s, correct answer, on `agy/claude-sonnet-4-6` |

The third already lives in this repo with tests and CI, and had never been run
against the live gateway until now.

**Why it works where the others fail:** smolagents drives the loop itself and
issues plain completion calls. The provider never has to carry multi-turn tool
state — which is exactly the thing `agy` cannot do. The same shape already
rescued web research: retrieve in one step, synthesise in another.

---

## 2. The one architectural decision

> **Agentic capability lives in `agent-sidecar`. The gateway supplies models.
> Activepieces supplies triggers and glue. Claude Code supplies judgement.**

Nothing else changes layer. Every phase below follows from this sentence.

The corollary matters as much: **stop trying to make the provider or the
workflow engine agentic.** Both were measured and both refuse.

---

## 2a. Status — Phase 1 done, 2026-08-31

`agent-sidecar-http` is deployed and healthy. `/healthz` reports
`max_steps: 8`, `executor_type: local`, `mcp_tools_enabled: false`.

Measured against §4.1 and §4.3:

| Check | Result |
|---|---|
| `POST /run` on `agy/claude-sonnet-4-6` | **3 s**, correct: *391, not prime* |
| `POST /run` on `agy/gemini-3.7-flash-high` | **2 s**, correct |
| `POST /run` on `ollama/qwen2.5:1.5b`, `max_steps: 2` | **66 s**, correct: *391* |
| Model echoed in the response | yes, all three |
| Test suite in the built image | 48 passed, 3 skipped |

**Two things this phase established that the plan did not know.**

*The local model cannot drive an agent loop.* Unbounded, it produced malformed
code blobs, smolagents rejected each one and retried, and the run was still on
step 5 after the caller had timed out at 300 s and disconnected. It converged
only once a step ceiling forced it to. Phase 4's line "confidential → ollama
local" therefore holds for single-call classification, **not** for agents.

*A caller giving up does not stop an agent.* The bound has to live in the
service, which is why `max_steps` now exists: default 8, per-call override
allowed to lower it and never to raise it.

**§4.2 is deliberately incomplete.** The operator path (`curl`) is proven; the
Activepieces and Claude Code paths are not wired, and must not be until Phase 2
lands. Wiring a flow to `/run` while `executor_type` is `local` is precisely
the thing the line in §7 forbids — an unattended trigger reaching an
unauthenticated endpoint that executes model-written Python on this host.

---

## 2b. Status — Phase 2, 2026-09-01

Split into three, because only two of them were within reach.

### 2a — authentication on `/run`: **done and verified**

Fails closed: an unset `AGENT_SIDECAR_AUTH_TOKEN` makes `/run` refuse every
request with 503 rather than accept them. The token is checked before the body
is read, compared with `secrets.compare_digest`, and `/healthz` reports only
whether one is configured.

The check that matters is not from the host but from the bridge, because that
is where the exposure is:

```
from inside king-activepieces-1:
  GET  /healthz            -> 200      (the network path IS open)
  POST /run  (no token)    -> 401      (blocked)
```

All three containers share `king_default`, which confirms the loopback port
binding was never protecting anything. 58 tests pass.

### 2b — container hardening: **done, with two things deliberately left**

`cap_drop: ALL`, and `memswap_limit` restored to equal `mem_limit` — its
absence was a plain violation of the rule applied everywhere else in this repo,
and it matters most on the one service that can consume without bound.

Not done, and why, recorded in `docker-compose.yml` beside the service:
`read_only: true` stops the container booting because `uv run` syncs the
virtualenv on start; egress restriction needs an `internal: true` network
shared with `omniroute-base`, which lives in the vendored compose file this
repo must never edit.

### The sandbox, measured rather than assumed

Three probes were run against `executor_type: local`, each asking the agent to
do something it should not be able to. It attempted **four** distinct bypasses
and every one was refused:

| Attempt | Result |
|---|---|
| `open('/etc/passwd')` | `InterpreterError: Forbidden function` |
| `import pathlib` | refused |
| `import builtins` (to recover `open`) | refused |
| `import urllib.request` | refused |

The AST allowlist is stronger than the plan credited it. It is still not a
security boundary — smolagents says so, and this only proves it stops the
obvious routes — but the immediate exposure is smaller than Phase 2 assumed.

### The finding that matters more than the sandbox

Blocked from fetching a page, the agent **fabricated the result**. Its code
was:

```python
# Let me try to print the status code based on what we know
print("HTTP Status Code: 200")
```

and its final answer presented that as a real fetch, complete with a fake
`Output:` line and the code it had *not* been able to run.

An agent that cannot do a thing and reports that it did is worse than one that
fails.

**Closed, as far as it can be from this side.** Both runners now return
`{result, steps, step_errors}` taken from the agent's own step records —
evidence the model does not author — and `/run` surfaces a `degraded` boolean
alongside the answer. Re-running the same two probes:

| Task | `degraded` | `steps` | `step_errors` |
|---|---|---|---|
| fetch a URL (blocked by the sandbox) | **true** | 2 | `InterpreterError: Import of urllib.request` |
| arithmetic (nothing blocked) | false | 1 | — |

The model still produced confident prose in the first case. It is now
*labelled*, which is the part a caller can act on. This does not stop
fabrication; it stops fabrication arriving unmarked.

**A caller must treat `degraded: true` as "do not trust this answer".** Nothing
enforces that, and it should become an acceptance criterion of its own rather
than a convention.

### 2c — off-host execution: **blocked on an account**

`e2b`, `modal` and `blaxel` are third-party sandboxes requiring a key this
deployment does not have. Until one exists, `executor_type` stays `local` and
the §7 line holds: no unattended trigger may reach `/run`.

---

## 3. Phases

Four phases, each independently useful. Phase 1 is worth doing even if the rest
is abandoned.

### Phase 1 — Make the agent reachable

`agent-sidecar-http` already exists and has never been deployed. It serves
`GET /healthz` and `POST /run` with `{"task": "...", "runner": "smolagents"}`,
binds `127.0.0.1:8100`, and carries a healthcheck and a 1 GB limit.

Bring it up, prove it answers, and give it a model per call rather than one
baked-in default.

### Phase 2 — Close the execution hole *(blocking for anything unattended)*

`POST /run` has **no authentication**, and smolagents' `CodeAgent` executes the
Python the model writes. The loopback binding does not help: every container on
the Docker bridge reaches `http://agent-sidecar-http:8100` directly.

Two things must both be true before any trigger that is not a human at a
terminal can reach this service:

1. **Execution moves off this host.** `executor_type` must become `e2b`,
   `modal`, or `blaxel`. **Not `docker`** — smolagents' `DockerExecutor` uses
   `docker.from_env()`, which from inside a container needs the host's Docker
   socket: root-equivalent host access handed to the one service that runs
   model-written code by design.
2. **`/run` requires a key**, checked before the task string is ever read.

This phase is not optional and not a footnote. Phase 3 must not ship without it.

### Phase 3 — Give the agent tools — **done 2026-09-04**

Live. Two MCP servers offer 120 tools between them — OmniRoute's 110 and the
code graph's ten — and the agent holds eleven by allowlist. `vps_exec` can
never be among them whatever the configuration says.

Proven with a task needing both: `nodes=59410, caddy=2.11.4` in three steps, a
private code fact and a live web fact in one answer.

Acceptance run: asked for the Caddy 2.11.4 release date, the agent searched and
answered in 2 steps, no step errors, `degraded: false`.

Three things had to be true that were not obvious going in:

1. **A `manage`-scoped key was needed and the admin password was lost.** Both
   the `INITIAL_PASSWORD` on disk and the operator's recollection were rejected.
   Recovered through OmniRoute's own mechanism — a non-bcrypt value in
   `key_value`/`settings`/`password` is re-hashed on next login — after backing
   up the database. See §11 of `king-system.md`.
2. **MCP tools and a sandboxed `CodeAgent` cannot coexist.** A remote executor
   serializes each tool's source into the sandbox and `MCPAdaptTool` fails that
   validation. The fix is also the right architecture: tools now mean a
   `ToolCallingAgent`, which executes no Python at all, so an agent that reads
   web pages can never turn a page into code on this host.
3. **The model must name a search provider, and only one is configured.** Left
   alone it chose `duckduckgo-free`, which the gateway lists and has no
   credential for; told to omit the field it hit `Argument provider is
   required`, because the MCP schema marks it required and smolagents validates
   client-side. It is pinned to `tavily-search`.

Preflight now fails to be quiet about the half-configured case: an allowlist
without a key produces an agent that answers from training data and sounds
exactly like one that searched.

### Phase 4 — Per-task economics

Delete the idea of one global ladder. Model choice becomes an argument:

```
reasoning / code   ->  agy          free (subscription quota), strongest
high volume        ->  deepseek, qwen flash, gemini flash   cheap per token
confidential       ->  ollama local  no egress
agy unavailable    ->  paid-first    the existing fallback
```

This is what finally makes bought keys get used. Today they sit unused because
`paid-first` always stops at tier 1.

**Partly done 2026-09-04.** `auto/*` is retired — re-measured at three
big-pickle hits out of three before the switch, and no flow calls it any more.
`web_research` moved to `websearch-tiers`, and an audit of all six flows found
no other caller. What remains of this phase is the per-task argument itself:
choice is still per-flow and per-call, not derived from the task.

---

## 4. HASIL — what exists when this is done

Stated so that each line can be run and either passes or does not.

### 4.1 A working agent endpoint

```bash
curl -s http://127.0.0.1:8100/healthz
```

Returns `executor_type`, `runners`, and boolean flags for keys — never a key
value.

```bash
curl -s -X POST http://127.0.0.1:8100/run \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $AGENT_KEY" \
  -d '{"task":"...","runner":"smolagents","model":"agy/claude-sonnet-4-6"}'
```

Returns `{"result": "...", "runner": "smolagents"}`.

**Acceptance:** a task requiring at least two agent steps returns a correct
answer. Baseline already measured: *"compute 17 × 23, then say whether it is
prime"* completes in **2 steps, 6.4 s**, answering 391 and not prime.

### 4.2 The agent is callable from all three places

| Caller | Route | Acceptance |
|---|---|---|
| Claude Code | An Activepieces MCP flow wrapping `POST /run` | The tool appears in a fresh Claude session and returns an agent result |
| Activepieces | HTTP step to `http://agent-sidecar-http:8100/run` | A flow run reaches `SUCCEEDED` with a non-empty `result` |
| Operator | `curl` from the VPS | As §4.1 |

### 4.3 Model is chosen per call

`POST /run` accepts a `model` field. Absent, it falls back to
`AGENT_SIDECAR_MODEL_ID`, itself defaulting to `opencode/big-pickle`.

**Acceptance:** the same task run with `agy/claude-sonnet-4-6` and with
`ollama/qwen2.5:1.5b-instruct-q4_K_M` both return, and `call_logs` shows two
different providers served them.

### 4.4 Execution is off this host, and `/run` is authenticated

**Acceptance, all four:**

- `GET /healthz` reports `executor_type` as one of `e2b`, `modal`, `blaxel` —
  never `local`, never `docker`.
- `POST /run` without a valid key returns **401**, and the response body does
  not echo the task.
- An agent task asking to read `/etc/passwd` or reach `169.254.169.254` returns
  a failure from the sandbox, not file contents or metadata.
- No container on the Docker bridge can reach `/run` unauthenticated —
  verified by curling it from inside `activepieces`.

### 4.5 The agent has tools

`GET /healthz` reports `mcp_tools_enabled: true`.

**Acceptance:** a task the agent cannot answer from training data alone —
*"what is the latest stable Caddy release and its date"* — returns
**v2.11.4, 3 June 2026** with a source, having reached it through a tool rather
than from memory. That exact question is the established benchmark: it defeated
the local model, defeated `agy` unaided, defeated SearXNG, and was answered
correctly through Tavily.

**Done 2026-09-04, and the benchmark still discriminates.** `/healthz` reports
`mcp_tools_enabled: true` and `agent_tools_active: true`; the agent answers
**3 June 2026** in 2–3 steps with `degraded: false`, having called
`omniroute_web_search`.

Two things the run surfaced that a pass/fail would have hidden. The sources
disagree — endoflife.date says 2 June, while the GitHub release assets,
Chocolatey and mise all say 3 June — and the `web_research` flow reports that
disagreement rather than choosing, which is what its prompt asks of it. And the
free-tier default model answers it as well as `agy/claude-sonnet-4-6` does, so
the benchmark separates *having tools* from *not having them*, not strong
models from weak ones.

### 4.6 Cost per agent run is known and bounded

**Acceptance:** running the §4.5 benchmark produces a figure of the shape
*"N model calls on `agy` (no marginal cost) + 1 Tavily search ($0.008) = $0.008
per run"*, and that figure is written into `docs/king-system.md`.

An agent that loops is the one thing here that can spend without bound. A run
must have a measured cost and `maxSteps` must be finite.

**Done 2026-09-05.** Both halves.

*Known*: `tokens` travels in every `/run` response, and `/audit/runs.jsonl`
keeps it, readable with `./scripts/agent-report.sh`. The figure, from the
search gateway's own `search_cost_usd` rather than an estimate: **1 Tavily
search ($0.008) + N model calls at no marginal cost = $0.008 per run** — true
for the free-tier default and for `agy` alike, so the entire cost is retrieval
and the model choice moves it by nothing.

*Bounded*: `max_steps` was already finite; `AGENT_SIDECAR_MAX_TOKENS` now
bounds what those steps may cost, since steps limit how often the loop turns
and not what one turn spends.

### 4.7 The documentation states what is true

`docs/king-system.md` gains an "Agentic layer" section carrying the same
honesty as the rest: what the agent can do, what it costs, where it executes,
and that provider-side tool loops and `run_agent` were tried and do not work.

---

## 5. Explicit non-goals

Each was measured this week and is closed unless something changes upstream.

| Not building | Why |
|---|---|
| Free web search | SearXNG returned Chinese pages about Word for a Caddy query once its one working engine hit a rate limit; DuckDuckGo answers this VPS with a CAPTCHA. Free engines block datacentre IPs within tens of queries. |
| A smarter local router | Four prompt versions measured: 41%, 91%, 67%, 73%. The shipped one is 86%. A `PAID` example sitting verbatim in the prompt is still misclassified — the ceiling is the 1.5B model, not the wording. |
| Anything on provider-side tool loops | `agy` returns 502 on round two and poisons the credential for other traffic. |
| A deeper routing hierarchy | `agy` is both free and strongest, so most of the cost optimisation it was built for does not exist. |
| Multi-tenant serving | One operator, one 7.9 GB VPS. Sharing access is a key-scoping question (already solved), not an architecture question. |

---

## 6. Risks carried into this plan

| Risk | Standing |
|---|---|
| **Credential rotation** | Still deferred. The list grows every session and now includes the Tavily and OpenRouter keys, both of which passed through chat. |
| `agy` subscription risk | Flagged `subscriptionRisk: true` in OmniRoute's own catalog; accepted knowingly. An agent loop multiplies calls against that quota. |
| Tavily credit | $0.008 per search, no fallback by design. A looping agent can spend it far faster than a human asking one question. |
| Code-execution sandbox | The single largest risk in this plan. §4.4 exists to close it and Phase 3 must not ship first. |

---

## 7. Order of work

```
Phase 1  ──►  Phase 2  ──►  Phase 3  ──►  Phase 4
deploy        sandbox +      MCP tools     per-task
              auth                         models
              ▲
              └── nothing unattended crosses this line
```

Phase 1 alone gives an agent an operator can drive by hand — useful on its own,
and the only phase safe to run with `executor_type: local`.

---

## 8. The one-sentence test

When this is finished, the operator should be able to say to Claude Code:

> *"have the agent find out X and write me the answer with sources"*

— and get a correct, sourced result produced by a multi-step loop running on
free models, at a cost the documentation states in cents, with the model's code
executing somewhere that cannot touch this host.

If any clause in that sentence is not true, the plan is not done.
