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
| [Langfuse](../../observability/) | Self-hosted, framework-agnostic (OpenTelemetry) tracing across every agent runtime in this workspace | pending |
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
