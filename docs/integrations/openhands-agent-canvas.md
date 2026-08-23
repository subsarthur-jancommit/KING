# OpenHands Agent Canvas

"The self-hosted developer control center for coding agents and
automations" — runs OpenHands itself, Claude Code, Codex, Gemini, or any
ACP-compatible agent across local/remote/cloud infrastructure, with an
Automation Server for Slack/GitHub-triggered workflows. Pulled as an
official pre-built image, nothing built from source, `omniroute/` untouched.

## Why not wired to OmniRoute's own ACP registry

OmniRoute already has an ACP subsystem (`omniroute/src/lib/acp/manager.ts`)
— but it's a **spawner/client**, not a server: it launches local CLI agents
(Cursor, Cline, Codex CLI, Claude Code, Aider) directly via
`child_process.spawn`. OpenHands Agent Canvas plays the exact same
spawner/client role for the same kind of agents. These are two peers
competing for the same job, not a client/server pair that plugs together.
The only real integration surface between them is what this doc sets up:
OpenHands Agent Canvas's agents call OmniRoute's `/v1` gateway as their LLM
backend, the same way `agent-sidecar` does.

## Image pinning

The upstream `ghcr.io/openhands/agent-canvas` image has **no semver
releases** — verified directly against the GHCR registry API (only
`latest`, `main`, and sha-/PR-based tags exist; there is no `1.x.x`-style
tag despite that being a very natural first guess). The compose service
pins by digest instead of `:latest`, resolved from the `main` tag as of
2026-08-23:

```bash
TOKEN=$(curl -sf "https://ghcr.io/token?scope=repository:openhands/agent-canvas:pull&service=ghcr.io" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
curl -sfI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  "https://ghcr.io/v2/openhands/agent-canvas/manifests/main" | grep -i docker-content-digest
```

Re-run this periodically and bump the `@sha256:...` in the root
`docker-compose.yml` when you want to pick up upstream changes — there is
no gentler "just bump a version number" upgrade path here since upstream
hasn't published one.

## Running it

```bash
docker compose --profile base --profile openhands up -d --build
```

`openhands-agent-canvas` `depends_on: omniroute-base` (`condition:
service_healthy`), so `--profile base` must be included too — Compose
enforces this itself (it errors with "depends on undefined service" if you
try `--profile openhands` alone, which is correct: this service exists to
route through OmniRoute, not to run standalone).

Before running for real, set a real secret (the compose file's inline
fallback, `CHANGEME-openssl-rand-base64-32`, is a placeholder, not a
secret — deliberately a soft default rather than a hard-required
`${VAR:?err}` so `--profile base` alone never breaks for people who never
asked for this service):

```bash
export OH_AGENT_CANVAS_SECRET_KEY=$(openssl rand -base64 32)
```

The whole KING repo root is mounted read-write at `/projects/king` (matching
how `omniroute/docker-compose.yml`'s own `host` profile already mounts `.`
read-write for CLI tooling — not a new pattern). **If you point an agent
run through this Canvas at `omniroute/` specifically**, you are responsible
for following `omniroute/AGENTS.md`'s own worktree-per-task workflow
yourself, exactly as if you'd opened a terminal in `omniroute/` directly —
this tool has no way to enforce that policy on your behalf, the same way a
plain shell doesn't.

## Configuring the LLM backend (manual, UI-only)

**Validated finding**: unlike `agent-sidecar` (pure env vars) or classic
pre-Canvas OpenHands (which had `LLM_MODEL`/`LLM_API_KEY`/`LLM_BASE_URL` env
vars), **Agent Canvas's official docs document no LLM env vars at all** —
only `LOCAL_BACKEND_API_KEY` (server access, `--public` mode only),
`OH_SECRET_KEY` (settings encryption), and `OH_AGENT_SERVER_VERSION`
(pins the agent-server sub-component, unrelated to the LLM). The LLM
backend is configured **exclusively through the web UI** after boot:

1. Open `http://localhost:8000` (or `$OPENHANDS_CANVAS_PORT`).
2. `Settings > LLM`.
3. Base URL: `http://omniroute-base:20128/v1` (compose network hostname) or
   `http://host.docker.internal:20128/v1` if OpenHands isn't itself in the
   compose network for some reason.
4. API key: a scoped `OMNIROUTE_API_KEY` provisioned the same way as
   `agent-sidecar`'s (`models,routing,health` — see the main
   [scalability-system.md](./scalability-system.md) doc's "Fase 3"; never
   hand this a `manage`/`admin`-scoped key).
5. Model: start with `opencode/big-pickle` (keyless free provider) to prove
   the wiring works with zero cost, exactly as `agent-sidecar`'s own smoke
   test does, before pointing it at a real paid model.

There is no way to script step 1–5 today (no documented settings API) — the
first-run LLM wiring is a one-time manual step per deployment.

## Status

Statically validated only: `docker compose config` resolves the merged
`base + openhands` (and full `base + observability + agent-sidecar +
openhands`, 10 services) model cleanly, with no missing-file or collision
errors. This sandbox has no reachable Docker daemon (same constraint noted
throughout this doc set), so the actual container boot and the manual
LLM-wiring runbook above are unverified pending a Docker-capable
environment — see the verification steps table in
[scalability-system.md](./scalability-system.md).
