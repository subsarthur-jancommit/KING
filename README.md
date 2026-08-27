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
mechanism (not a manual `git clone` + script run), so that's what was used:

```
claude plugin marketplace add https://github.com/affaan-m/ECC
claude plugin install ecc@ecc
```

This avoids stacking installation methods (plugin + manual `install.sh` +
npm), which ECC's docs warn causes duplicated skills, commands, and hooks.

### What's installed

- Plugin: `ecc@ecc` v2.2.0 — 380 skills, 68 agents, 7 lifecycle hooks
  (`PreToolUse`, `PostToolUse`, `SessionStart`, etc.), 1 MCP server
  (`chrome-devtools`).
- Config: `hooks_enabled: true`, `hook_profile: standard`.
- Manifest validated with `claude plugin validate`.

### Project-level integration

[`.claude/settings.json`](.claude/settings.json) declares the `ecc`
marketplace and enables the `ecc@ecc` plugin at **project scope**. Anyone who
clones this repository and opens it in Claude Code gets the ECC marketplace
and plugin automatically — no manual per-user setup required.

### Notes for contributors

- Do not layer the manual `./install.sh` or `ecc-universal` npm install on
  top of this project-scope plugin install — pick one method only.
- Plugin changes take effect after restarting the Claude Code session.
- Run `claude plugin list` to confirm `ecc@ecc` is enabled, and
  `claude plugin details ecc@ecc` to see the current component inventory and
  projected token cost.

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
via manual `workflow_dispatch`. It is the authoritative proof that the
vendored app actually runs; the static `docker compose config` checks done
during initial vendoring only validated the wiring, not a live boot.
