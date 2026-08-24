# Running STAX on a VPS

Everything in STAX was built and validated on a laptop and in GitHub Actions,
where "reachable from the network" means "reachable from my own machine". A
VPS is different: every published port faces the internet, and the blast
radius of a leaked credential is real. This page is the difference between
those two situations — what changed, what is still your call, and what to run
before you deploy.

Short version:

```bash
./scripts/stax-preflight.sh base agent-sidecar        # or whichever profiles
docker compose --profile base --profile agent-sidecar up -d
```

If preflight exits non-zero, do not deploy. It only reports things that are
actually wrong.

## Why the checks live in a script instead of in compose

The obvious way to force an operator to set a secret is compose's own
required-variable syntax:

```yaml
- OH_SECRET_KEY=${OH_AGENT_CANVAS_SECRET_KEY:?set this before deploying}
```

That does not work here, and the reason is worth stating precisely, because
it has now caused three separate bugs in this repo. **Compose interpolates
variables across the entire merged model before it filters services by
profile.** A required variable on the `openhands` service therefore breaks
`docker compose --profile base up` for someone who only wants plain
OmniRoute. Verified directly against Docker Compose v5.1.1:

```yaml
services:
  always-on: { image: alpine }
  gated:
    image: alpine
    environment: [ "SECRET=${MUST_BE_SET:?must be set}" ]
    profiles: [ gated ]
```

```console
$ docker compose config --services      # note: `gated` is NOT selected
error while interpolating services.gated.environment.[]: required variable
MUST_BE_SET is missing a value: must be set
```

The same mechanic is why the `include:`-level `env_file:` entries were
removed earlier, and why `${VAR:?}` cannot be used to force
`OH_AGENT_CANVAS_SECRET_KEY`. Compose gives no way to scope a hard
requirement to a profile, so the requirement lives in
`scripts/stax-preflight.sh`, where scoping is one `case` statement.

The script has a `--self-test` mode that exercises its own logic with known
inputs. It needs no Docker daemon, no secrets and no network, so CI runs it
on every PR — the checks are themselves tested rather than assumed.

## What changed for VPS deployment

| Component | Was | Now |
|---|---|---|
| `openhands-agent-canvas` port | `0.0.0.0:8000` | `127.0.0.1:8000`, override `OPENHANDS_CANVAS_BIND_HOST` |
| Repo mount into OpenHands | all `.env` files readable | `omniroute/.env`, `observability/.env`, `agent-sidecar/.env` masked read-only |
| `langfuse-web` port | `0.0.0.0:3000` | `127.0.0.1:3000`, override `LANGFUSE_WEB_BIND_HOST` |
| MinIO S3 API port | `0.0.0.0:9090` | `127.0.0.1:9090`, override `LANGFUSE_MINIO_BIND_HOST` |
| Resource limits | none | `mem_limit` + `cpus` on both new services, overridable |
| `agent-sidecar` user | root | non-root uid 10001, `no-new-privileges` |
| `agent-sidecar` image build | lockfile ignored | `uv sync --frozen` against the committed `uv.lock` |
| smolagents executor | hardcoded in-process | `AGENT_SIDECAR_EXECUTOR`, validated at load |
| Restart policies | unset | `unless-stopped` for OpenHands, `no` for the one-shot sidecar |

### Loopback by default, and how to reach it

Nothing in STAX needs to be internet-facing to be useful. Reach a
loopback-bound service over an SSH tunnel:

```bash
ssh -L 8000:127.0.0.1:8000 -L 3000:127.0.0.1:3000 you@your-vps
```

Then open `http://localhost:8000` on your own machine. No port is exposed to
anyone else, and there is no login page for the internet to find.

Set a `*_BIND_HOST` to `0.0.0.0` only once that service sits behind a reverse
proxy terminating TLS and enforcing authentication. Preflight warns whenever
one of these is set to a non-loopback value — the warning is not a blocker,
because publishing behind a proxy is legitimate; it exists so the choice is
visible rather than accidental.

Note that this is deliberately stricter than OmniRoute's own dashboard, which
binds wide open. That is defensible for OmniRoute because it authenticates
(`INITIAL_PASSWORD` + JWT). The bar being applied here is "does this service
authenticate by default?", not "is it important?".

### Secret masking in the OpenHands mount

`openhands-agent-canvas` mounts the whole repo at `/projects/king` so agents
can work on this codebase — that is the point of the service. But the repo
working tree also contains gitignored `.env` files holding OmniRoute's
`JWT_SECRET`, `API_KEY_SECRET`, `INITIAL_PASSWORD` and every provider
credential you have configured. Without intervention, any agent run in the
Canvas can read all of it, and an agent that can read a provider credential
can spend your money with it.

Each secret file is shadowed by a read-only `/dev/null` bind mount:

```yaml
- ./:/projects/king
- /dev/null:/projects/king/omniroute/.env:ro
```

Docker applies mounts in order of destination depth, so the deeper mounts
land on top of the repo mount. Inside this one container, reads return empty
and writes are refused; on the host and in every other service the files are
completely unaffected. Confirmed in the resolved model:

```console
$ docker compose --profile base --profile openhands config
  /home/user/KING       -> /projects/king            rw
  /dev/null             -> /projects/king/omniroute/.env        ro
  /dev/null             -> /projects/king/observability/.env    ro
  /dev/null             -> /projects/king/agent-sidecar/.env    ro
```

These paths track the repo layout. If you change the project mount, revisit
the list — the masks do not follow it automatically.

## Two decisions that are still yours

These are genuine trade-offs, not oversights. Both are left at the
conservative setting with the alternative documented, because picking either
one silently would be the wrong call.

### 1. Docker socket, and therefore agent sandboxing

OpenHands' safer runtime spawns a fresh sandbox container per task, which
requires mounting the host's Docker socket. The mount is present but
commented out in `docker-compose.yml`:

```yaml
# - /var/run/docker.sock:/var/run/docker.sock
```

The trade-off is unusually sharp:

- **Socket mounted.** Agent code runs in a disposable container, isolated
  from the Canvas process and from your repo. But a container that can
  create containers can start a privileged one that mounts the host root
  filesystem. Access to the socket is equivalent to root on the VPS. If the
  Canvas is ever compromised, so is the whole machine.
- **Socket not mounted (current default).** No host escalation path exists.
  But agent processes run inside the Canvas container itself, with the
  filesystem access its mounts grant — which is why the secret masking above
  matters more in this configuration, not less.

Neither is strictly safer; they fail in different directions. The default is
"no host escalation path" because that failure is bounded and recoverable,
while host root is not. If you enable it, do so on a VPS dedicated to this
workload, not one sharing anything you care about. Preflight warns when it
sees the mount enabled, so it never becomes an unnoticed default.

### 2. Where smolagents executes generated code

`agent-sidecar` uses smolagents' `CodeAgent`, which works by writing Python
and running it. `AGENT_SIDECAR_EXECUTOR` chooses where:

| Value | Where code runs | Use when |
|---|---|---|
| `local` (default) | in the sidecar container | tasks come from an operator on the CLI |
| `docker` | a separate container | anything else |
| `e2b`, `modal`, `blaxel` | a hosted sandbox | you already use one of these |

`local` is guarded by an empty import allowlist (`additional_authorized_imports=[]`),
so generated code cannot import `os`, `socket` or `requests`. That is an
AST-level restriction, and smolagents' own documentation is explicit that it
is not a security boundary — it raises the cost of an escape, it does not
prevent one.

This is safe today because of *how the service is invoked*, not because of
the allowlist: every task arrives as an argv string from whoever ran
`docker compose run agent-sidecar`. The container is non-root, capped at 1
CPU and 1GB, carries `no-new-privileges`, and publishes no ports.

**The moment that changes — an HTTP endpoint, a webhook, a queue consumer,
anything where task text originates outside your shell — `local` is the wrong
setting.** Prompt injection becomes remote code execution in your container.
Set `AGENT_SIDECAR_EXECUTOR=docker` before that day, not after. An invalid
value fails at settings load with a clear message rather than deep inside
smolagents.

## What preflight does not check

It reads configuration, so it catches misconfiguration. It does not and
cannot verify:

- **Host-level security.** Firewall rules, SSH hardening, unattended
  upgrades, fail2ban. Loopback binding assumes the host itself is not
  already compromised.
- **That your reverse proxy is correct.** If you set a bind host to
  `0.0.0.0`, preflight warns and takes your word for the proxy.
- **Runtime behaviour.** It checks that a secret is not a placeholder, not
  that OpenHands authenticates, and not that an agent is behaving.
- **Credential scope.** It warns that `OMNIROUTE_MCP_API_KEY` carries
  manage/admin scope, but cannot tell whether you meant to grant it.

## Validation status

Verified in this environment (no Docker daemon available, so these are
config-resolution and unit-level checks):

- `docker compose config` resolves cleanly for `base`, `base+agent-sidecar`,
  `observability`, and the full 10-service stack.
- Resolved output confirms `host_ip: 127.0.0.1` on every changed binding,
  the three `/dev/null` masks ordered after the parent mount, and the
  memory/CPU limits.
- `OPENHANDS_CANVAS_BIND_HOST=0.0.0.0` still overrides correctly.
- `scripts/stax-preflight.sh --self-test` passes; its blocking and passing
  paths were both exercised against real inputs.
- `pytest tests/` — 10 passed, 3 skipped (the skips need a live OmniRoute).

Verified in CI on every PR: all of the above, plus a real boot of each
profile with live health checks.

Not verified anywhere yet, because it needs a real VPS: that OpenHands Agent
Canvas behaves correctly under the memory limit during actual agent work,
and the manual `Settings > LLM` wiring in
[openhands-agent-canvas.md](./openhands-agent-canvas.md). Both are
first-deployment steps.
