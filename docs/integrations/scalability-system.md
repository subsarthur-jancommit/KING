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
| [agent-sidecar](../../agent-sidecar/) | Combined smolagents + pydantic-ai Python service, using OmniRoute as both LLM backend and MCP tool source | pending |
| [Langfuse](../../observability/) | Self-hosted, framework-agnostic (OpenTelemetry) tracing across every agent runtime in this workspace | ✅ vendored & statically validated (Docker daemon unavailable here — see below) |
| OpenHands Agent Canvas | Self-hosted control center to run/monitor multiple coding agents and automations, LLM-configured to route through OmniRoute | pending |
| [Smithery](./smithery.md) | External MCP server registry — pull third-party MCP servers as tools, optionally publish OmniRoute's own MCP server | pending |

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
`graphify update .` (incremental, AST-only, no API cost).

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
