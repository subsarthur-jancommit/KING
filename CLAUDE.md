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

**Live since 2026-09-04**, and no longer behind an SSH tunnel:

```
claude mcp add --transport http --scope user codegraph https://gateway.arject.co/king-codegraph/mcp --header "Authorization: Bearer ${GRAPHIFY_API_KEY}"
```

**`--scope user` is not optional.** Without it the server lands in `.mcp.json`,
which is tracked, and the key is committed. User scope writes to `~/.claude.json`
instead, outside the repo. The same applies to `king-agent`, registered the same
way against `https://gateway.arject.co/king-agent/mcp` with
`AGENT_SIDECAR_AUTH_TOKEN`.

**Verify rather than believe it:** `claude mcp list` must show both as
`✔ Connected`. This section claimed codegraph was live from 2026-09-04, and it
was — on the gateway. It had never been registered as an MCP server on any
client, so for eight days every structure question in every session was answered
with `grep` while this file said otherwise. A capability that exists and a
capability that is reachable are different claims, and only one of them is
checkable in one command. Registered for real on 2026-09-12.

Ten tools, refreshed daily by a systemd timer. Which one to reach for is
measured, not assumed (2026-09-12, numbers in `docs/king-system.md` §4):

- **`get_neighbors` on a symbol you can name — yes.** Exact `file:line`, callers
  and callees, and every edge typed (`calls`, `imports`, `contains`,
  `references`). A grep returns a flat list where a definition, a call, a test
  and a comment all look alike.
- **It is not automatically cheaper.** On a rare symbol grep wins outright — 171
  characters against 463 for `_McpAuthMiddleware`. On a common one the graph at
  full fidelity is about the same size as grep (5219 against 5503 for
  `load_settings`) and better shaped. The saving comes from `token_budget`: ask
  for 600 tokens and it returns the 17 most relevant of 48 edges **and says it
  cut 31**. Grep has no such mode — all 60 lines, or narrow the pattern and
  silently risk missing the one that mattered.
- **`query_graph` is swamped here — don't reach for it.** A broad question
  ("which file defines the sidecar's HTTP routes?") returned 352 nodes, almost
  all from the vendored `omniroute/` subtree, and the answer was not among the
  top 35. The graph indexes 59,809 nodes and most of them are not ours. Start
  from a symbol with `get_neighbors` or `get_node`.

It can be stale by up to a day, which is normal; weeks behind is not. Check
with `graph_stats`, refresh with `scripts/codegraph-refresh.sh`. A confident
answer about month-old code is worse than no graph at all.


## Delegated work: measure it, and cross-check facts

**`degraded: false` is not "the answer is right".** On 2026-09-12 a `run_agent`
call returned `17.11` for the current PostgreSQL version with `steps: 2`,
`step_errors: []`, `degraded: false` and `tools_used: ["omniroute_web_search"]`
— every health field the sidecar records saying the run went well. The
`search_web` flow, asked the same question, answered **18.6, released
2026-08-13**, with sources. Those fields measure the mechanism: did the loop
terminate, did a tool throw, was a tool reached. None of them is about the
output.

**So before acting on a fact an agent or a model gave you, ask a second path.**
It costs one call and about 8 seconds. `search_web` retrieves and then
synthesises from what it retrieved; `run_agent` answers from the model plus a
tool it chose — genuinely different failure modes, which is why the
disagreement was visible at all. A sourced answer and an unsourced one
disagreeing is not a tie.

This applies to **facts from the world**: versions, prices, dates, whether
something shipped. It does not apply to arithmetic or to the repo in front of
you, where a second opinion adds nothing you cannot check directly.

**What is automated, and what is not.** `./scripts/agent-eval.sh` grades the
agent weekly on 17 tasks whose answers a string comparison can settle, and
`F-11` reports that score — measured baseline 17/17, floor 90%. That set is a
regression guard and it structurally **cannot** catch a wrong current fact,
because a frozen expectation about a moving fact would go red for being out of
date. A cross-path checker was built for that gap and abandoned: extracting the
answer from search-result titles failed its own control, since a search for the
Apollo 11 landing returns titles containing `07`, `11`, `16`, `2024` and no
`1969`. Grounding it properly needs a second model to synthesise, which is the
substitution the eval exists to end. Hence a rule here rather than a timer.

## Skills

Eleven ECC skills are installed in `~/.claude/skills/`, chosen to match what is
actually in this repo: `python-patterns`, `python-testing`, `tdd-workflow`,
`docker-patterns`, `deployment-patterns`, `security-review`,
`verification-loop`, `mcp-server-patterns`, `github-ops`, `error-handling`,
`context-budget`.

**Read the relevant skill before writing code, not after.** It is a guide book,
not a review checklist. Where no skill fits, work from the facts in front of
you and use ECC's universal principles as the anchor.

**The `ecc@ecc` plugin is deliberately NOT enabled**, and `enabledPlugins` was
removed from `.claude/settings.json` to keep it that way. Installing it whole
adds **~40,637 tokens to every session** — measured with
`claude plugin details ecc@ecc` — for 380 skills and 68 agents covering
Android, Flutter, Laravel, Perl, healthcare and DeFi, none of which appear in
this repo. The eleven above cost roughly 1,100 always-on, about 2.7% of that.
Context that is not relevant is a cost, not a bonus, and ECC's own first
principle is to optimize the context window.

**If a task ever needs a skill that is not installed, take that one from the
ECC marketplace** — it is still declared in `.claude/settings.json`, so
`~/.claude/plugins/cache/ecc/ecc/<version>/skills/` holds all 286 to copy from.
Add the single skill you need. Do not enable the plugin to get it.
