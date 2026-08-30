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

### Phase 3 — Give the agent tools

`mcp_tools.py` exists (48 lines) and can load OmniRoute's MCP tools, gated
behind a separate, more-privileged key. Turning it on is what makes the agent
worth having: it gains web research, the code graph, and whatever else the
gateway exposes.

Note the existing design constraint, already documented in `config.py`: the
MCP key needs `manage`/`admin` scope, and the sidecar's ordinary key
deliberately does not carry it.

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

### 4.6 Cost per agent run is known and bounded

**Acceptance:** running the §4.5 benchmark produces a figure of the shape
*"N model calls on `agy` (no marginal cost) + 1 Tavily search ($0.008) = $0.008
per run"*, and that figure is written into `docs/king-system.md`.

An agent that loops is the one thing here that can spend without bound. A run
must have a measured cost and `maxSteps` must be finite.

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
