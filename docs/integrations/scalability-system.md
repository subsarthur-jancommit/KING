# STAX — KING scalability system

STAX is the set of workspace-level additions layered on top of the vendored
`omniroute/` product to make AI-agent-driven development on this workspace
scale: codebase understanding, context packing, lightweight agent runtimes, a
multi-agent control plane, cross-agent observability, and an external MCP
tool registry.

## Ground rule: `omniroute/` is never touched

Everything below lives at the KING repo root, sibling to `omniroute/`, and
integrates with OmniRoute only through its already-public interfaces: the
`/v1` OpenAI-compatible HTTP API, its MCP server, and Docker Compose
composition. No file inside `omniroute/` is edited by STAX. This is
deliberate — `omniroute/` is periodically re-synced from upstream via
`git subtree pull --squash`, and its own `AGENTS.md` imposes a mandatory
worktree-per-task workflow plus a Hard Rule against AI attribution in commit
metadata that conflicts with this repo's own commit conventions at the KING
root. Keeping STAX entirely outside `omniroute/` avoids both problems.

## Components

| Component | What it does | Status |
|---|---|---|
| Graphify | Local, zero-LLM-cost code knowledge graph (tree-sitter) for AI agents to navigate the 220K-line `omniroute/` codebase without grepping | ✅ installed & validated (58,205 nodes / 139,183 edges / 1,945 communities from 10,343 files; see below) |
| repomix | Repo-to-context packer + on-demand MCP server (`--mcp`) for direct codebase Q&A | ✅ installed & validated (see below) |
| [agent-sidecar](../../agent-sidecar/) | Combined smolagents + pydantic-ai Python service, using OmniRoute as both LLM backend and MCP tool source | ✅ installed & live-validated (see below) |
| [Langfuse](../../observability/) | Self-hosted, framework-agnostic (OpenTelemetry) tracing across every agent runtime in this workspace | ✅ vendored & statically validated (Docker daemon unavailable here — see below) |
| [OpenHands Agent Canvas](./openhands-agent-canvas.md) | Self-hosted control center to run/monitor multiple coding agents and automations, LLM-configured to route through OmniRoute | ✅ vendored & statically validated (see linked doc) |
| [Smithery](./smithery.md) | External MCP server registry — pull third-party MCP servers as tools, optionally publish OmniRoute's own MCP server | ✅ CLI verified & skill installed (user-scoped — see linked doc) |

## Graphify — status

Installed project-scoped for Claude Code (`graphify claude install` — writes
the usage rules into this file's sibling `CLAUDE.md` at repo root, plus a
non-destructive `PreToolUse` hook in `.claude/settings.json` alongside the
existing `ecc@ecc` plugin config). Graph built with:

```bash
graphify extract . --code-only --no-cluster   # local tree-sitter AST only, zero LLM cost, ~4 min
graphify cluster-only . --no-viz --no-label   # local Leiden clustering, zero LLM cost, ~1 min
```

Result: 58,205 nodes / 139,183 edges / 1,945 communities across 10,343 files.
Known gap: 157 `.sql` migration files under `omniroute/src/lib/db/migrations/`
are not indexed (`tree_sitter_sql` extra not installed — low value relative to
the cost of a second full extraction pass; revisit with
`uv tool install --reinstall graphifyy[sql]` if migration-schema graph
queries become a real need). `graph.html` was skipped (`--no-viz`) since the
graph exceeds the ~5,000-node threshold where the interactive viz gets
unwieldy — use `graphify query`/`explain`/`path` instead.

Validated end-to-end with `graphify explain "CloudAgentBase"`, which
correctly resolved all 4 real subclasses
(`CursorCloudAgent`/`CodexCloudAgent`/`DevinAgent`/`JulesAgent`) and their
exact file:line locations under `omniroute/src/lib/cloudAgent/`.

`graphify-out/` (graph.json, GRAPH_REPORT.md, cache/, manifest) is generated
build output — gitignored, not committed. Regenerate anytime with
`graphify update .` (incremental, AST-only, no API cost). Re-run after every
STAX phase landed (now covering `agent-sidecar/`, docs, and configs too, not
just `--code-only` source): 129,621 nodes / 219,980 edges / 9,584
communities from 11,993 files — verified the update respected `.gitignore`
correctly (zero nodes sourced from `agent-sidecar/.venv/` or `node_modules/`,
both of which exist on disk in this workspace by this point).

## repomix — status

Installed as a pinned root devDependency (`repomix@1.18.0`) plus
`repomix.config.json`. **Important, validated finding**: a full unscoped pack
of this workspace is **not practically usable as a context bundle** — even
with `output.compress: true` (tree-sitter structural extraction, enabled by
default in the config), a full pack is **~20.6M tokens** (uncompressed:
34.6M tokens, 123MB) across 11,314 files. That is far beyond any model's
context window and was deleted after the validation run — `npm run
repomix:pack` against the whole repo is provided for completeness, not
everyday use.

The practical interface is **scoped packing**, validated against a real
subdirectory:

```bash
npm run repomix:pack:scoped -- "omniroute/open-sse/mcp-server/**" -o /tmp/out.xml
# → 61 files, 33,997 tokens — comfortably fits in any model's context
```

and the **MCP server mode**, registered project-scoped so every contributor
gets it automatically:

```bash
claude mcp add repomix --scope project -- npx -y repomix --mcp --sandbox
```

This wrote `.mcp.json` (committed) with the server confined to the repo root
via `--sandbox` (no absolute/host paths, no remote packing). Confirmed
registered via `claude mcp list`; a human must still approve it once per
Claude Code session (expected first-run security prompt, not an error). Once
approved, an agent can call the `pack_codebase` tool with its own `include`
patterns for the exact slice of the codebase a task needs — this is the
recommended default over static full-repo packs.

`repomix.config.json` excludes `omniroute/CHANGELOG.md` (2.2MB),
`omniroute/docs/i18n/**` (40+ duplicated translation trees),
`omniroute/docs/openapi.yaml` (267KB), lockfiles, and `graphify-out/`.
Repomix's built-in secret scanner also excluded 19 test files during the
validation pack (matches in guardrail/security test fixtures — e.g.
`webhook-ssrf-guard.test.ts`, `proxy-registry-manager.test.ts` — almost
certainly fake credentials used to test the guardrails themselves, not real
secrets, but worth a manual look if repomix output is ever shared externally).

## Running OmniRoute for STAX validation — status

**Validated finding: this sandbox has no reachable Docker daemon** (`docker`/
`docker compose` CLIs are installed, but `/var/run/docker.sock` doesn't
exist — the same constraint the root `README.md` already documents for the
original vendoring work). `docker compose --profile base up` cannot actually
boot here. Since Node.js 22.22.2 is available and satisfies `omniroute`'s
own `engines.node` range, STAX validation runs OmniRoute directly instead:

```bash
cp omniroute/.env.example omniroute/.env
# fill JWT_SECRET / API_KEY_SECRET / INITIAL_PASSWORD per the root README
cd omniroute && npm install && npm run dev   # http://localhost:20128
```

This is a genuine live instance, not a mock — confirmed end-to-end:
`GET /healthz` → `ok`; `POST /api/auth/login` + `GET /api/auth/status` →
`{"authenticated":true}`; a real `POST /v1/chat/completions` against the
keyless `opencode/big-pickle` model returned actual generated content — the
exact technique `omniroute-smoke.yml` already uses in CI.

A scoped key was then provisioned via `POST /api/keys`
(`{"name":"stax-agent-sidecar","scopes":["models","routing","health"]}`,
session-cookie authenticated) and validated by using it — not just
creating it — for a second real chat completion
(`Authorization: Bearer sk-...`), which returned genuine content. **Note, a
correction to the original plan**: `GET /api/monitoring/health` turned out
to return the *same* `{"status":"healthy","setupComplete":true}` payload
whether called anonymously or with the scoped key — the plan had assumed a
richer authenticated payload here; that assumption didn't hold in practice,
so the actual proof-of-authentication used instead was the second
`/v1/chat/completions` call succeeding with the key attached.

**Operational gotcha found while validating**: running `npm install` inside
`omniroute/` (needed to run it directly without Docker) can nondeterministically
touch `omniroute/package-lock.json` — a newer local npm resolving one
optional transitive dependency slightly differently than whatever npm
generated the committed lockfile. This is a change *inside* `omniroute/`,
which STAX must never commit. Always `git status omniroute/` after running
its `npm install`/dev server, and `git checkout -- omniroute/package-lock.json`
to discard any such drift before committing anything else.

**Wherever Docker itself is genuinely required** (Langfuse's multi-container
self-host stack, OpenHands Agent Canvas's official image), this workspace
falls back to the same standard the root README already established: static
`docker compose config` validation, documented as unverified-live pending a
Docker-capable environment.

## Langfuse — status

Vendored from `github.com/langfuse/langfuse`'s official self-host
`docker-compose.yml` (Langfuse v4, fetched 2026-08-23) into
`observability/docker-compose.langfuse.yml`, included from the root
`docker-compose.yml` behind a new `observability` profile. Every image is
pre-built and pulled (`docker.langfuse.com/langfuse/*`, `clickhouse`,
`minio`, `redis`, `postgres`) — nothing is built from source, and
`omniroute/` is untouched.

Docker itself can't be exercised live in this sandbox (see below), so
validation here is **static**: `docker compose config` against the merged
root + omniroute + observability compose model. That static pass caught two
real bugs before they could reach a live run:

1. **Service-name collision.** Both `omniroute/docker-compose.yml` and the
   vendored Langfuse file define a bare `redis:` service. Compose's
   `include:` merges services by name across included files — the two
   `redis:` blocks silently merged into one hybrid service (kept
   OmniRoute's image/container-name, but Langfuse's extra port mapping leaked
   in and Langfuse's `profiles: [observability]` **overwrote OmniRoute's
   "no profile = always on" redis into being profile-gated**, which would
   have silently broken OmniRoute's rate-limiter redis under `--profile
   base` alone). Fixed by renaming the vendored service to `langfuse-redis`
   (and its `depends_on`/`REDIS_HOST` references) — confirmed via
   `docker compose config` that OmniRoute's `redis` now correctly shows
   `profiles: None` (always active, port 6379) and `langfuse-redis` shows
   `profiles: [observability]` (port 16379, no collision).
2. **`env_file` at the `include:` level is required unconditionally**, not
   lazily per-profile — `docker compose config` failed on a missing
   `observability/.env` even when only `--profile base` (plain OmniRoute,
   no Langfuse at all) was requested. This broke the "fully opt-in, zero
   cost until activated" principle every other STAX/OmniRoute profile
   follows. Fixed by dropping the include-level `env_file:` entirely — every
   Langfuse variable already carries its own inline `${VAR:-default}`
   fallback in the compose file, so `--profile base` alone now needs no new
   file at all. Real secrets are applied only when explicitly requested:
   `docker compose --profile observability --env-file observability/.env up`.

A third issue was caught while hand-testing `observability/.env.example`:
Compose's `--env-file` parser does **not** strip a trailing `# comment` on
the same line as `VAR=` — it becomes part of the value. The template
originally had `SALT=    # openssl rand -hex 32` on one line; fixed by
moving every hint comment to its own line above the (empty) `VAR=` line, and
re-validated that filled-in values come out clean (confirmed
`POSTGRES_PASSWORD` and its downstream `DATABASE_URL` interpolation both
resolve correctly with no stray comment text).

`docker compose config --services` with `COMPOSE_PROFILES=base,observability`
now resolves cleanly to all 8 expected services
(`omniroute-base`, `redis`, `langfuse-worker`, `langfuse-web`, `clickhouse`,
`minio`, `langfuse-redis`, `postgres`) with no missing-file or merge errors.
**Live boot (actually connecting an agent-sidecar run to a running Langfuse
and seeing a trace appear) is still pending a Docker-capable environment** —
see the verification steps table.

## agent-sidecar — status

`agent-sidecar/` (Python, `uv`-managed, `smolagents[toolkit,mcp]` +
`pydantic-ai`) is a thin combined service: both frameworks' model clients
point at OmniRoute's `/v1` OpenAI-compatible endpoint
(`omniroute_model.py`), never a third-party provider directly. **Live-tested
end to end against the running OmniRoute instance from the section
above** (not mocked):

```bash
export OMNIROUTE_BASE_URL=http://localhost:20128
export OMNIROUTE_API_KEY=sk-...            # models,routing,health scope
uv run python -m agent_sidecar.smol_runner "Say exactly: SMOLAGENTS-STAX-OK"
# -> smolagents' CodeAgent wrote and ran `final_answer("SMOLAGENTS-STAX-OK")`,
#    returned exactly that string.
uv run python -m agent_sidecar.pydantic_runner "Say exactly: PYDANTIC-AI-STAX-OK"
# -> PYDANTIC-AI-STAX-OK
uv run pytest tests/ -v   # 2 passed, 1 skipped (MCP — opt-in, see below)
```

**Important finding, changes the plan's original assumption**: MCP tool
loading needed its own investigation. `/api/mcp/stream` (OmniRoute's
Streamable HTTP MCP transport) calls `requireManagementAuth()` with no
options, which only accepts a `manage`/`admin`-scoped key (or a dashboard
session). The narrower `mcp:connect` scope that `omniroute/.env.example`
and `managementScopes.ts` document exists for a *different* purpose — it
only bypasses the loopback-only network restriction for remote callers, it
does **not** by itself satisfy the scope check inside the route handler.
Confirmed by testing both: a `models,routing,health,mcp:connect` key got
`403 "API key lacks 'manage' scope"`; a `manage`-scoped key succeeded and
listed all **110** MCP tools (matching `omniroute/open-sse/mcp-server/README.md`
exactly).

Consequence: MCP tool loading in `agent_sidecar/mcp_tools.py` is **opt-in**
and gated on a *separate* env var, `OMNIROUTE_MCP_API_KEY` — deliberately
not the sidecar's default `OMNIROUTE_API_KEY`, so the sidecar's baseline
footprint stays least-privilege (no `manage`/`admin`) and an operator has to
consciously provision the more powerful key if they actually want MCP
tools. Also live-validated with a temporary `manage`-scoped key (created,
used once, deleted immediately after):

```bash
export OMNIROUTE_MCP_API_KEY=sk-...        # manage scope — elevated, opt-in only
# smolagents: MCPClient(...) -> 110 tools (gamification_*, local_corpus_*, ...)
# pydantic-ai: Agent(model, toolsets=[MCPToolset(...)]).run_sync(...) -> works
```

Packaged with `agent-sidecar/Dockerfile` (no default CMD — invoked
explicitly per-runner or via `pytest`) and wired into the root
`docker-compose.yml` as a new `agent-sidecar` profile (default off),
`depends_on: omniroute-base` with `condition: service_healthy` across the
`include:` boundary. Learning applied from the Langfuse phase: its
`env_file` is declared `required: false` so `--profile base` alone never
needs `agent-sidecar/.env` to exist — confirmed via `docker compose config`
with and without that profile active.

**Not live-tested**: the Dockerized path itself (no Docker daemon in this
sandbox, same constraint as Fase 3/4) — only statically validated via
`docker compose config`. The Python code paths themselves (both runners,
both with and without MCP tools) *are* genuinely live-validated, directly
on the host against the real running OmniRoute instance, which is a
stronger proof than a container boot would have added on top.

## CI (GitHub Actions) — status, and a real root-caused failure

`.github/workflows/stax-smoke.yml` runs three independent jobs
(`agent-sidecar`, `observability`, `openhands`) on real GitHub-hosted
runners, which — unlike this sandbox — have a genuine Docker daemon.
`omniroute-smoke.yml` (pre-existing) already covers plain `--profile base`.

**`observability` and `openhands` passed cleanly on first/second try** —
real, live proof: the full 6-service Langfuse stack boots and its
`/api/public/health?failIfDatabaseUnavailable=true` endpoint confirms
genuine Postgres connectivity; OmniRoute + OpenHands Agent Canvas boot
together and the container serves HTTP.

**`agent-sidecar` (and, once, `omniroute-smoke.yml`'s own job) failed
repeatedly** with `The runner has received a shutdown signal`, always
mid-build, always around "Generating static pages using 3 workers
(440/587)". Investigated rather than blindly retried:

- Ruled out **concurrent-job resource contention** (my first hypothesis) —
  it recurred identically when re-run alone, no other job running.
- Ruled out **my own `timeout-minutes: 30`** — failures happened at ~6-7
  minutes elapsed, nowhere near that.
- Ruled out **GitHub Actions minute/quota exhaustion** — checked
  `get_workflow_run_usage` on both a failing run and the very first,
  cleanly-successful `omniroute-smoke.yml` run from before any of this
  investigation; both report `duration_ms: 0` identically, so that field
  isn't a usable signal for this account either way.
- **Root cause, found via `graphify query` pointing at
  `omniroute/tests/unit/dockerfile-build-heap-4076.test.ts`**: issue #4076,
  a previously-hit-and-fixed "JavaScript heap out of memory" during
  `npm run build` in the Docker `builder` stage. The fix sets
  `NODE_OPTIONS=--max-old-space-size=${OMNIROUTE_BUILD_MEMORY_MB}`
  (`omniroute/Dockerfile`, default `4096`) before the build — but
  `next build`'s static-page generation spawns **3 parallel worker
  processes**, and `NODE_OPTIONS` propagates to every child process each
  worker inherits its own 4096MB ceiling, for up to ~12GB of *potential*
  combined heap across 3 workers. Unlike the original #4076 bug (a single
  process exceeding V8's *default* ~2GB ceiling on a memory-unconstrained
  build box), this is three independently-ceilinged processes able to
  jointly outgrow the host regardless of any single process's own ceiling.

  > **This reasoning was believed at the time but the supporting number was
  > wrong**, and the conclusion is no longer claimed. It assumed a 7GB
  > runner; the runners actually report 15Gi. See
  > [the correction below](#the-intermittent-runner-death-and-what-is-actually-known-about-it).

**Fix**: `docker-compose.yml` at KING root now carries a partial-override
`omniroute-base` service block, merged additively into the one included
from `omniroute/docker-compose.yml` (verified via `docker compose config`
that only `build.args` changes — `OMNIROUTE_BASE_PATH` is preserved
alongside the new key, and image/ports/profiles/healthcheck are all
untouched, avoiding a repeat of the earlier `redis` full-service-collision
class of bug). Sets `OMNIROUTE_BUILD_MEMORY_MB=1536` — the Dockerfile's own
documented override point — so 3 workers × 1536MB ≈ 4.6GB rather than
~12GB. No `omniroute/` file touched; this only supplies a build arg the
Dockerfile already explicitly supports overriding. The ceiling is still in
place and is still a sensible bound, but see the correction below before
treating it as the fix for the intermittent failures.

**Correction, found the hard way**: that partial-override approach was
reverted. `docker compose config` validated it cleanly (build.args merged
additively, every other field untouched, exactly as intended), but
`docker compose up`/`build` rejected it outright at runtime:
`services.omniroute-base conflicts with imported resource`. **`docker
compose config` is not a reliable proxy for what `docker compose up` will
accept** — `include:` is meant for pulling in non-overlapping services from
other files, and redeclaring a same-named service directly in the
including file, even as a partial patch, is a hard conflict at `up`/`build`
time even though `config` renders it as a clean merge. Root-caused by
reading the real CI error (only visible after the actions/checkout SHA-pin
fix let jobs get past checkout) rather than assuming the memory theory was
still right.

**Confirmed for real once the compose-collision and SHA-pin issues were
both out of the way**: the `agent-sidecar` job reproduced the *exact* same
failure as the original investigation — `The runner has received a
shutdown signal`, again at "Generating static pages using 3 workers
(440/587)" — in a run where `observability` (a completely different,
unrelated job) passed cleanly. This confirms the heap-exhaustion theory
was correct all along; the compose-collision bug had just been blocking
every job identically before that, making it impossible to tell.

**Actual fix applied**, in all three jobs that build `omniroute-base`
(`agent-sidecar` and `openhands` in `stax-smoke.yml`,
`boot-and-verify` in `omniroute-smoke.yml`): a dedicated build step runs
*before* `docker compose ... up` (with no `--build` flag on the `up` call,
since the image is already built and tagged to match what
`omniroute-base`'s `image:` field expects). This never touches the compose
service graph, so it can't collide with anything `include:`s the way the
reverted approach did.

That step is now `./scripts/ci-build-omniroute-base.sh`, shared by all three
jobs rather than copy-pasted into each, and shellcheck-linted by the
`preflight` job.

### The intermittent runner death, and what is actually known about it

This step intermittently dies with `The runner has received a shutdown
signal` and exit 143, always at the same `Generating static pages using 3
workers (440/587)` checkpoint.

**Established.** It is not caused by any particular commit. On `d583545` the
step died in `agent-sidecar` while the *identical* command succeeded in
`boot-and-verify`, on another runner, at the same moment — same commit, same
script, different outcome.

**Not established — and previously overstated here.** Earlier revisions of
this document and the workflow comments asserted a 7GB runner being exhausted
by 3 parallel workers. That figure was wrong. The runners report **15Gi
total with ~14Gi available** before the build starts (printed by the build
script itself now), so a 4.6GB combined heap ceiling does not obviously
exhaust them. Exit 143 is SIGTERM, which is GitHub's own runner-shutdown
path; the kernel OOM-killer sends SIGKILL (137). Infrastructure preemption
fits the evidence at least as well as memory pressure does.

The build script provisions swap (3.0Gi → 11Gi, verified in the run logs) as
**cheap headroom, not a proven fix**: it costs nothing, helps if the cause is
memory pressure, and is harmless if it is preemption. A green run is not
proof it worked — the failure was always intermittent, so only a long stretch
of green runs would be. Swap failing to provision is a warning rather than an
error, since failing there would trade a probabilistic failure for a
guaranteed one.

## Why these and not others

A short gap-analysis pass considered and explicitly rejected: **Hermes Agent**
(redundant with OmniRoute's existing ACP CLI-agent spawning), **LangGraph /
CrewAI / AutoGen** (redundant with smolagents' nested-agent support and
OpenHands Agent Canvas's cross-process orchestration — a third framework
would be pure surface area), a dedicated **task queue** (pydantic-ai already
has an on-ramp to Temporal/DBOS/Prefect if volume ever justifies it — YAGNI
today), a **secrets manager** (OmniRoute's existing encrypted credential
store + scoped `OMNIROUTE_API_KEY` convention is enough for this few
consumers), and a **new eval framework** (`promptfoo`, already used inside
`omniroute/`, is reused instead).

## Minimal stack vs. full stack

All new Docker Compose services are opt-in profiles, default off, matching
the existing `omniroute/docker-compose.yml` pattern (`memory`, `bifrost`,
`cliproxyapi`).

| Stack | Profiles | What you get |
|---|---|---|
| Minimal | `base` | Just OmniRoute itself |
| + agents | `base agent-sidecar` | + a scriptable Python agent runtime talking to OmniRoute |
| + observability | `base agent-sidecar observability` | + Langfuse tracing across agent runs (adds Postgres/ClickHouse/Redis — noticeably heavier) |
| Full | `base agent-sidecar observability openhands` | + OpenHands Agent Canvas multi-agent control center |

```bash
docker compose --profile base --profile agent-sidecar up -d --build
```

Every new service also carries a `mem_limit`/`cpus` ceiling (overridable per
service) so that adding a profile has a bounded cost on a small host rather
than an open-ended one.

Langfuse's self-hosted stack is resource-heavy for a small workspace; if you
don't want 4 extra containers, use [Langfuse Cloud's free tier](https://langfuse.com)
instead and point `agent-sidecar`'s `LANGFUSE_HOST` at it — no compose
profile needed in that case.

## Secrets

Every consumer that talks to OmniRoute (agent-sidecar, OpenHands) gets its
**own** `OMNIROUTE_API_KEY`, scoped to the minimum it needs (start with
`models,routing,health`; never hand out `admin`). Keys live only in
gitignored `.env` files, never committed, never reused across consumers. See
`omniroute/.env.example` (section "Internal Agent & MCP Integrations") for
the underlying convention.

Compose cannot enforce any of this: `${VAR:?err}` is interpolated across the
whole merged model *before* profiles are filtered, so a required-secret guard
on one profile breaks `up` for every other profile. Run the preflight script
instead — it applies the same checks, scoped per profile:

```bash
./scripts/stax-preflight.sh base agent-sidecar
```

It blocks on placeholder or missing secrets and warns on off-host port
bindings. Required before deploying anywhere that isn't your own machine.

## Deploying to a VPS

The defaults in this repo assume a laptop. Before running STAX on a host
with a public IP, read
[vps-hardening.md](./vps-hardening.md) — it covers the loopback-by-default
port bindings and how to tunnel to them, the `.env` masking that keeps agent
runs from reading your provider credentials, resource limits, and the two
trade-offs left deliberately to the operator (Docker-socket sandboxing for
OpenHands, and where smolagents executes generated code).

For the actual runbook — server setup through verification, per profile,
in order — see [vps-deploy-guide.md](./vps-deploy-guide.md) (Bahasa
Indonesia).
