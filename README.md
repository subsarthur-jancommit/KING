# KING

## ECC integration

This repository is wired up for [ECC](https://github.com/affaan-m/ECC) (Agent
Harness Performance Optimization System) — an MIT-licensed plugin for Claude
Code that adds structured agents, skills, hooks, and review workflows.

### Install validation

Before installing anything, the ECC repository and its documented install
paths were reviewed (without cloning) to confirm the safe, official route.
ECC's own README states:

> Install ECC only from verified channels: the GitHub repository, the npm
> packages (`ecc-universal` and `ecc-agentshield`), the GitHub App, and the
> project website. Third-party re-uploads and unofficial mirrors are not
> maintained or reviewed and may contain malware.

The recommended path for Claude Code is the native plugin marketplace
mechanism (not a manual `git clone` + script run), so the marketplace is added
that way:

```
claude plugin marketplace add https://github.com/affaan-m/ECC.git
```

### The plugin is deliberately NOT installed

`claude plugin details ecc@ecc` prices the whole plugin at **~40,637 tokens
added to every session** — 380 skills and 68 agents covering Android, Flutter,
Laravel, Perl, healthcare, DeFi and Cisco networking, none of which appear in
this repository. Loading all of it would contradict ECC's own first principle,
*"Optimize the context window."*

So `enabledPlugins` was **removed** from `.claude/settings.json`. Only the
marketplace declaration remains, and that is on purpose: it is what makes
adding one more skill a single directory copy instead of a re-clone.

### What is installed

Eleven skills, copied into `~/.claude/skills/`, chosen against what this
repository actually contains:

| Skill | Why it is here |
|---|---|
| `python-patterns`, `python-testing`, `tdd-workflow` | `agent-sidecar/` is Python with 100+ tests |
| `docker-patterns`, `deployment-patterns` | Compose plus two Dockerfiles, deployed to a VPS |
| `security-review` | `vps_exec`, the tool allowlist, secrets, bearer auth |
| `mcp-server-patterns` | this repo builds and runs an MCP server |
| `github-ops` | CI, and the `gh` workflows around it |
| `error-handling` | the `degraded` / `step_errors` contract |
| `verification-loop` | already this project's standing rule |
| `context-budget` | the discipline that produced this section |

Measured cost: roughly 1,100 tokens always-on — about **2.7%** of installing
the plugin whole.

### Adding a twelfth

Take the single skill you need from the marketplace cache; do not enable the
plugin to get it:

```
cp -r ~/.claude/plugins/cache/ecc/ecc/<version>/skills/<name> ~/.claude/skills/
```

All 286 are there to choose from. Skills load on the **next** session.

### Notes for contributors

- Do not layer the manual `./install.sh` or the `ecc-universal` npm package on
  top of this — ECC's docs warn that stacking install methods duplicates
  skills, commands and hooks.
- Do not re-add `enabledPlugins` to `.claude/settings.json` without re-reading
  the token measurement above. Adding the marketplace while that key is present
  silently switches all 380 on.
- `CLAUDE.md` carries the working rule: read the relevant skill *before*
  writing code, not as a review checklist afterwards.

## OmniRoute integration

This repository vendors [OmniRoute](https://github.com/diegosouzapw/OmniRoute)
(MIT-licensed) at [`omniroute/`](omniroute/) — a local-first, self-hosted
AI/LLM gateway that presents one OpenAI-compatible endpoint in front of 300+
upstream providers, with automatic multi-tier fallback, prompt compression,
an MCP/A2A server, a management dashboard, and a CLI. See
[`omniroute/README.md`](omniroute/README.md) for the full feature set,
[`omniroute/LICENSE`](omniroute/LICENSE) for licensing, and
[`omniroute/THIRD_PARTY_NOTICES.md`](omniroute/THIRD_PARTY_NOTICES.md) for
third-party attributions.

### How it was vendored

The `omniroute/` subfolder was brought in via `git subtree` (squashed) from
`https://github.com/diegosouzapw/omniroute`, branch `release/v3.8.50`. To
pull future upstream updates:

```bash
git fetch omniroute-upstream release/v3.8.50   # re-verify the default branch first — it may have moved:
                                                # git ls-remote --symref https://github.com/diegosouzapw/omniroute HEAD
git subtree pull --prefix=omniroute omniroute-upstream release/v3.8.50 --squash
```

Because `--squash` is used, each pull lands as a single commit in this repo —
OmniRoute's own granular commit history is not browsable here, only upstream.

### Quick start

```bash
cp omniroute/.env.example omniroute/.env
# Fill in the three required secrets in omniroute/.env:
#   JWT_SECRET       -> openssl rand -base64 48
#   API_KEY_SECRET   -> openssl rand -hex 32
#   INITIAL_PASSWORD -> any non-default value (do not leave as CHANGEME)

docker compose --profile base up -d --build   # from the repo root, using the wrapper below
# or: cd omniroute && docker compose --profile base up -d --build
```

The dashboard/API listens on `http://localhost:20128` by default. Health
check: `GET /api/monitoring/health`. See `omniroute/docker-compose.yml` for
all available profiles (`base`, `web`, `cli`, `host`, `cliproxyapi`, `memory`,
`bifrost`).

A thin `docker-compose.yml` wrapper at the repo root (`include:`-based) lets
`docker compose` be run from here without `cd`-ing into `omniroute/`.
`omniroute/.env` and `omniroute/data/` are gitignored — secrets and runtime
data must never be committed.

### Environment note

This integration was assembled in a sandboxed environment without a reachable
Docker daemon. The compose configuration was statically validated
(`docker compose config`), but the image has not actually been built or run.
Treat the first `docker compose --profile base up -d --build` in a
Docker-capable environment as the real end-to-end verification step.

### Public HTTPS deployment

For a VPS deployment reachable at your own domain rather than `http://IP:20128`,
the `proxy` profile adds Caddy in front of OmniRoute with automatic Let's
Encrypt certificates:

```bash
echo "OMNIROUTE_PUBLIC_DOMAIN=your.domain.com" >> .env
./scripts/stax-preflight.sh base proxy
docker compose --profile base --profile proxy up -d
```

Caddy reaches OmniRoute over the compose network, so only 80/443 need to be
open at the cloud firewall — `DASHBOARD_PORT` stays closed. This also makes the
gateway usable as a Claude Code backend via `ANTHROPIC_BASE_URL`, since
OmniRoute serves a native Anthropic Messages API at `/v1/messages`. See
[`docs/integrations/reverse-proxy-tls.md`](docs/integrations/reverse-proxy-tls.md).

### Workflow orchestration

OmniRoute routes model calls; it does not schedule anything or react to
outside events. The `workflow` profile adds [Activepieces](https://www.activepieces.com)
(MIT) for that — triggers, branching, retries and run history — with OmniRoute
still the only path out to a model. Postgres points at Neon's free tier and
Redis runs locally, so it costs two containers rather than four:

```bash
cp activepieces/.env.example activepieces/.env   # fill in Neon
./scripts/stax-preflight.sh base workflow
docker compose --profile base --profile workflow up -d
```

Redis is local for a reason worth borrowing: **offload what is billed by size,
not what is billed by call.** Redis originally pointed at Upstash's free tier,
which caps total requests at 500k/month — about 11.5 commands a minute — while
a BullMQ worker polls its queue continuously whether or not a flow is running.
It ran out, every flow stopped for 14 hours, and the container reported
`healthy` throughout because its healthcheck answers from the API and the API
does not need the queue. Neon stays because its limit is storage, which a
workflow engine consumes slowly.

The `agent-sidecar-http` profile completes the loop: it serves the existing
smolagents and pydantic-ai runners over HTTP (`POST /run`) so a workflow step
can invoke a real agent, not just a chat completion. It has no authentication
and runs model-generated code, so it stays loopback-only and is never proxied.

See [`docs/integrations/activepieces-workflow.md`](docs/integrations/activepieces-workflow.md).

### Agent sidecar

A [smolagents](https://github.com/huggingface/smolagents) agent behind an HTTP
endpoint, running on whichever OmniRoute model the caller names. This is what
turns the gateway from a router into something that can be given a task.

```bash
curl -s -X POST http://127.0.0.1:8100/run   -H 'Content-Type: application/json'   -H "Authorization: Bearer $AGENT_SIDECAR_AUTH_TOKEN"   -d '{"task":"…","model":"agy/claude-sonnet-4-6","max_steps":6}'
```

**Two agent kinds, chosen by whether the run has tools.** Without tools it is a
`CodeAgent` writing Python into an e2b/modal sandbox. With tools it is a
`ToolCallingAgent` that executes no arbitrary code at all — which is both the
only shape MCP tools work in, and the right one for something that reads web
pages, since an injected page can never become code on the host.

**The tool list is an allowlist — eleven, from two MCP servers.** Seven come
from OmniRoute's 110 and four from the code graph's ten, so "what calls this
function" costs the agent a tool call instead of costing Claude twenty files of
context. OmniRoute tags twelve of its tools "phase 1", but that marks usefulness
to an MCP client, and two of the twelve rewrite live routing. On top of the allowlist, `vps_exec`,
`run_agent` and `ask_model` are in a `NEVER_REGISTER` set that no configuration
can override — being *offered* one is reported as `misdirected`, because it
means `OMNIROUTE_MCP_URL` is pointed at this service instead of the gateway.

**Every response says how much to trust it.** `degraded` is true when any step
errored, a configured tool failed to load, or the gateway served a different
model than the one asked for — which it does, in both directions, based on
prompt content. `tokens` says what the run cost, `served_by` which model
actually answered, and `tools` which ones it held.

**Every run is journalled** to `/audit/runs.jsonl`; read it with
`./scripts/agent-report.sh [days]` for cost, degradation rate and tool use over
time.

It is reachable from Claude through Caddy at
`https://gateway.arject.co/king-agent/mcp`, which also exposes `vps_exec` — an
audited shell on the VPS, off unless `AGENT_SIDECAR_EXEC_ENABLED` is set, and
never reachable by the agent itself.

### Observability

OmniRoute already records every call it routes to a `call_logs` table, with
provider, model, status, tokens and the API key's name — no configuration
needed. Give each consumer its own `/v1` key and `/dashboard/usage` separates
their traffic for free. The `tracing` profile adds prompt-level traces on top,
sending OmniRoute's built-in OTLP exporter to Langfuse Cloud's free tier
through a small collector whose only job is attaching the auth header the
exporter cannot send:

```bash
# .env: LANGFUSE_OTLP_AUTH="Basic $(printf '%s:%s' pk-lf-... sk-lf-... | base64 -w0)"
./scripts/stax-preflight.sh base tracing
docker compose --profile base --profile tracing up -d
```

The collector catches the calls Caddy structurally cannot see — Activepieces
reaches OmniRoute over the Docker network, never through the proxy. The
self-hosted Langfuse stack under `observability/` stays off: six containers,
none of them carrying a resource ceiling.

See [`docs/integrations/observability.md`](docs/integrations/observability.md).

### Code knowledge graph

Answering "where is this function used" across 220K vendored lines by grepping
spends model tokens on work that is deterministic.
[graphify](https://github.com/Graphify-Labs/graphify) answers it from a local
tree-sitter AST — no model call, no API key, no vector store. The `codegraph`
profile builds that graph on the server and serves it over MCP, so one graph is
shared by Claude Code on your laptop and by workflow steps on the VPS, instead
of a per-machine build that nobody actually has:

```bash
echo "GRAPHIFY_API_KEY=$(openssl rand -hex 24)" >> .env
./scripts/stax-preflight.sh codegraph
docker compose --profile codegraph run --rm codegraph-build
docker compose --profile codegraph up -d codegraph-serve
```

No wrapper was written: graphify ships its own MCP streamable-HTTP server. The
build is a one-shot costing ~4.5 minutes and 4 GB, refreshed by a systemd timer
calling `scripts/codegraph-refresh.sh`, which also refuses to run while a local
model holds memory. The server itself holds 392 MB. Activepieces reaches it over the Docker
network, and since 2026-09-04 a laptop reaches it through Caddy rather than an
SSH tunnel:

```bash
claude mcp add --transport http codegraph   https://gateway.arject.co/king-codegraph/mcp   --header "Authorization: Bearer ${GRAPHIFY_API_KEY}"
```

The tunnel is what kept a daily-refreshed graph unused, so removing it was the
point. Note what that key now protects: `GRAPHIFY_API_KEY` defaults to an empty
string in compose, so an unset key would publish a complete map of the
repository. Authentication was verified before the route was added — 401 with
no token, 401 with a wrong one.

See [`docs/integrations/codegraph.md`](docs/integrations/codegraph.md).

### Local model

Free tiers go down — CI here has watched `opencode/big-pickle` return
`service_unavailable`, and tolerates it explicitly. The `localmodel` profile
closes that last gap with an Ollama container behind the same gateway. It is not
smarter than any free model; it is simply always there and has no quota:

```bash
./scripts/stax-preflight.sh localmodel
docker compose --profile localmodel up -d ollama
docker compose --profile localmodel run --rm -T ollama-pull
./scripts/localmodel-register.sh
```

OmniRoute already ships the `ollama-local` provider, so nothing here teaches the
gateway anything. Measured on a 2 vCPU host with no GPU: a real triage prompt
answers in 12 seconds, the model holds 2.1 GB while loaded and 178 MB when idle.
That is the size of work it is for — triage, classification, branch decisions.
Code review is not on the list and will not be.

**It does not unconditionally keep work on the box, and that matters.**
Measured 2026-09-05: a request naming `ollama/qwen2.5:1.5b-instruct-q4_K_M` is
served by ollama for a plain prompt, and by `gemini-3.7-flash-high` — Google,
through agy — when the prompt trips the gateway's content-based reroute. No
error, no warning, a normal-looking answer. The routing lives in the vendored
subtree and cannot be changed here, so the sidecar reports it instead: a local
model answered elsewhere sets `degraded` with `local-only work left the host`.
A caller using `/v1` directly should read the `x-omniroute-provider` header.
See `docs/king-system.md` §5b.

`localmodel-register.sh` exists because the dashboard equivalent has a trap:
a connection saved without an explicit Base URL keeps `localhost:11434`, which
inside the gateway container is the gateway. The script sets it and then refuses
to succeed without a real completion coming back.

See [`docs/integrations/localmodel.md`](docs/integrations/localmodel.md).

### CI smoke test

[`.github/workflows/omniroute-smoke.yml`](.github/workflows/omniroute-smoke.yml)
builds and boots OmniRoute via the root `docker-compose.yml` on GitHub-hosted
runners (which have a real Docker daemon, unlike the sandbox this integration
was assembled in) and proves it works end-to-end with **zero external API
keys**:

1. Generates CI-only secrets and starts the `base` profile.
2. Polls `/healthz` until the container reports ready.
3. Logs in as the initial admin (`POST /api/auth/login`) and confirms the
   session via `/api/auth/status`.
4. Sends a real chat completion to `POST /v1/chat/completions` using the
   `opencode/big-pickle` model — a no-auth, keyless free-tier provider that
   OmniRoute routes to directly with no key or "enable" step required — and
   asserts a genuine response comes back.

This runs on every push/PR touching `omniroute/**` or the compose files, and
via manual `workflow_dispatch`.

**It is currently red, for a reason outside this repository.** `tls-client-node`
resolves its native binary from `bogdanfinn/tls-client` releases at build time,
with no pin, and builds the filename from a naming scheme upstream abandoned:
v1.15.1 published both `tls-client-linux-ubuntu-amd64-1.15.1.so` and
`tls-client-xgo-1.15.1-linux-amd64.so`, and v1.16.0 (2026-09-02) kept only the
`xgo` name. The download is skipped and a deliberate guard in
`omniroute/Dockerfile` fails the build rather than shipping an image with no TLS
client.

So the same commit builds green one day and red the next: the build is not
reproducible, which is the defect underneath the symptom. It is not rate
limiting, and `0.2.0` is the newest release in the range omniroute pins.

There *is* a lever, and it is a trade rather than a fix. The postinstall honours
`TLS_CLIENT_VERSION`; `1.15.1` pins it to a release that still ships the name it
looks for, but 1.15.1 is the binary upstream pinned *away from* over
CVE-2025-68121, while 1.16.0 fixes that and has no linux-ubuntu asset. No
version satisfies both. It cannot be reached from outside anyway: the failing
`RUN` is at `omniroute/Dockerfile:111` and every `ARG` in that file is declared
after it, so a `--build-arg` has nothing to bind to. Passing it means editing a
vendored subtree that must not be edited.

The full reasoning — the CVE's real severity, which is not the one the upstream
PR states, and two workarounds that look like fixes and are not — is in
[`docs/king-mistakes.md`](docs/king-mistakes.md) so nobody re-diagnoses it.

This workflow stays red while it stands, which is the correct state — it is the
one whose job is to build the vendored app. The STAX workflow below no longer
is: its jobs pull a published image of the vendored version instead, because
they test our wiring against a running gateway and were failing on a build none
of them depend on. No commit in this repository caused this, and reverting one
will not clear it.

### STAX smoke test

[`.github/workflows/stax-smoke.yml`](.github/workflows/stax-smoke.yml) is the
one that covers the code in this repository rather than the vendored app:
preflight self-tests and shellcheck, the agent sidecar, codegraph,
observability, OpenHands, and the workflow profile.

Three things about it are worth knowing:

- It runs on **push to `main`** as well as on pull requests. For months it did
  not, and roughly fifteen commits of agent-sidecar work merged with no CI
  evidence at all. See entry 14 in `docs/king-mistakes.md`.
- The `agent-sidecar-unit` job deliberately has **no dependency on
  `omniroute:base`**. It builds only `./agent-sidecar` and runs the full suite —
  100+ tests in about 30 seconds — so a broken vendored build cannot take our
  own tests down with it, which is how a real regression once survived for
  three days.
- The jobs that need a running gateway **pull** `omniroute:base` rather than
  building it, pinned to the published image's index digest for the exact
  version `omniroute/package.json` vendors. `omniroute-smoke` above still
  builds from source, so the build question keeps being asked — just not by
  six jobs that do not depend on the answer.

  `scripts/ci-build-omniroute-base.sh` refuses to run if the pinned version and
  the vendored version disagree, and checks the pulled image's own
  `/app/package.json` rather than the tag it just applied. After a
  `git subtree pull` it fails loudly and names the two lines to update. Set
  `CI_OMNIROUTE_BUILD=1` to build here instead, once upstream is fixed.

  This was worth doing for what it found within one run. With the gateway
  reachable again, the sidecar's suite ran against a live `/v1` for the first
  time in weeks and the end-to-end step failed with
  `AGENT_SIDECAR_AUTH_TOKEN is not configured` — the wrapper had required a
  bearer for weeks while CI posted without one, invisible because the job died
  at the build first.
