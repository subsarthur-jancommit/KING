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
| [Graphify](../../.claude/skills/graphify/) | Local, zero-LLM-cost code knowledge graph (tree-sitter) for AI agents to navigate the 220K-line `omniroute/` codebase without grepping | ✅ installed |
| repomix | Repo-to-context packer + on-demand MCP server (`--mcp`) for direct codebase Q&A | ✅ installed |
| [agent-sidecar](../../agent-sidecar/) | Combined smolagents + pydantic-ai Python service, using OmniRoute as both LLM backend and MCP tool source | pending |
| [Langfuse](../../observability/) | Self-hosted, framework-agnostic (OpenTelemetry) tracing across every agent runtime in this workspace | pending |
| OpenHands Agent Canvas | Self-hosted control center to run/monitor multiple coding agents and automations, LLM-configured to route through OmniRoute | pending |
| [Smithery](./smithery.md) | External MCP server registry — pull third-party MCP servers as tools, optionally publish OmniRoute's own MCP server | pending |

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
