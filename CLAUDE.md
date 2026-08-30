# KING — working rules

## Never edit `omniroute/`

It is a squashed `git subtree` of upstream OmniRoute at `release/v3.8.50`. Any
edit there is silently reverted by the next `git subtree pull`. If the gateway
needs different behaviour, do it from the outside — a compose override, an
environment variable, or a plugin — and write down why.

**And do not reach for a compose override instead.** The root
`docker-compose.yml` must never declare a service that `omniroute/` already
defines. The Compose spec forbids an including file from overriding an included
resource, and a partial `omniroute-base:` override — added to mount a plugins
directory and pass two OTel variables — turned every Docker CI job red with
`services.omniroute-base conflicts with imported resource`. It survived because
Compose v5.3+ accepts it and the VPS runs v5.5, so it worked in both places a
human looked. Configuration the gateway needs goes in `omniroute/.env`, which
the vendored file already reads via `env_file: .env`.

## Compose

- **Never use `${VAR:?err}`.** It is interpolated across the whole merged model
  *before* profile filtering, so a required variable for one profile breaks
  every unrelated profile. Required-variable checks live in
  `scripts/stax-preflight.sh` instead. Use `${VAR:-default}`.
- Every added service is **opt-in** via `profiles:` and default-off.
- Published ports bind `${X_BIND_HOST:-127.0.0.1}:` — never a bare `"p:p"`.
  Only Caddy binds `0.0.0.0`, deliberately.
- Pin images to an exact tag or digest. Never `latest`.
- Carry `mem_limit` **and** `memswap_limit` (equal) plus `cpus` on anything new.
  Equal limits make a container OOM loudly inside its own cgroup instead of
  dragging the whole 7.8 GB host into swap thrash.

## Before deploying

Run `./scripts/stax-preflight.sh <profiles…>` and fix everything it reports.
It exists because this deployment has been bitten three times by faults that
left every container reporting *healthy*: a workflow worker pointed at the
wrong port, a data directory owned by the wrong uid that lost every API key on
restart with zero errors logged, and an open gateway. Preflight runs before
`up`, so it can only assert files and variables; anything that is only knowable
once containers are running belongs in a post-deploy check, not there.

## Secrets

Every `.env` in this repo is gitignored, and so is `.claude/settings.local.json`
— Claude Code appends `permissions.allow` entries to it verbatim, which is how a
live database connection string once ended up in it in plaintext. The OpenHands
profile mounts the whole repo, so anything secret must also be shadowed with
`/dev/null` in that service's volume list.

## Code knowledge graph

Not available yet. `graphify-out/` does not exist, and the `graphify` CLI is not
installed on any machine this project runs on — use ordinary search tools.
The graph is being moved to a shared MCP server on the VPS; these rules get
rewritten to point at it once that endpoint is live.
