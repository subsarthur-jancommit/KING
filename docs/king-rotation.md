# Credential rotation

Every secret this deployment holds, what a holder of it can do, and what else
has to change when it moves. Names and locations only — no values, ever.

This document exists because `king-audit.sh` C-9 found fifteen secret-shaped
variables that appeared in no document at all. A rotation list that does not
name everything leaves credentials live while feeling complete, which is
`king-mistakes.md` 24 in advance rather than in hindsight.

Read `king-mistakes.md` 24 first if you are about to rotate anything. Its
lesson in one line: **a rotation is not done when the new credential is
accepted; it is done when everything that read the old one has been checked.**

---

## Before you start

```bash
./scripts/verify-credentials.sh        # baseline: what works right now
./scripts/local-secret-scan.sh         # what is sitting in local files
./scripts/king-backup.sh               # a restore point that predates the change
```

Rotate one credential at a time and re-run `verify-credentials.sh` after each.
It makes seven real calls, two of which assert that a *wrong* token is
rejected — the check whose absence let four scripts fail silently for two days.

---

## Tier 1 — host root equivalence

| Variable | Where | What the holder gets |
|---|---|---|
| `AGENT_SIDECAR_AUTH_TOKEN` | `agent-sidecar/.env` | **Root on this host.** The sidecar mounts `docker.sock` read-write with `EXEC_ENABLED=true`, so `vps_exec` can start a `--privileged` container with `/` bind-mounted. This is not a service token and must not be labelled as one. |

Rotating it means updating the Claude MCP registration that points at
`/king-agent/mcp` as well as the file. Nothing else reads it.

## Tier 2 — the gateway's own keys

These are the seven rows in `api_keys`, stored as literal `sk-` strings in
`omniroute/data/storage.sqlite` — the gateway compares them as bearer tokens,
so they are not hashed. Anyone who can read that file has all of them.

| Variable | Where | Reads it |
|---|---|---|
| `OMNIROUTE_API_KEY` | `agent-sidecar/.env` | The sidecar's `/v1` calls |
| `OMNIROUTE_MCP_API_KEY` | `agent-sidecar/.env` | `manage`-scoped; reaches `/api/mcp/stream` and the usage API |
| `GRAPHIFY_API_KEY` | `.env` | The codegraph MCP, and Claude's own registration |
| `API_KEY_SECRET` | `omniroute/.env` | Signs issued keys. Rotating it invalidates every issued key at once. |
| `JWT_SECRET` | `omniroute/.env` | Session tokens for the gateway UI |

Revoke and reissue from the gateway UI, then update every file above. Two keys
carry `manage` scope (`claude-mcp-bridge`, `agent-sidecar-mcp`); check the
scope before assuming a key is read-only.

## Tier 3 — the encryption key, which is not where you would look

| Variable | Where | Hazard |
|---|---|---|
| `STORAGE_ENCRYPTION_KEY` | **`omniroute/data/server.env`**, not `omniroute/.env` | Decrypts every provider credential in `storage.sqlite`. |
| `STORAGE_ENCRYPTION_KEY_VERSION` | `omniroute/.env` | Currently `v1`; stored ciphertext carries an `enc:v1` prefix. |

Three things about this one.

**It is empty in `omniroute/.env`.** The gateway generated its own and wrote it
to `omniroute/data/server.env`. Reading only the `.env` files makes it look
unset, and `omniroute/SECURITY.md` says an unset key means passthrough
plaintext — so the natural conclusion is wrong in both directions.

**It sits in the same directory as the database it encrypts.** The encryption
defends against a stolen `storage.sqlite` alone. It does nothing against read
access to `omniroute/data/`, and nothing in a backup that archives both.

**Losing it is not recoverable by rotation.** `omniroute/skills/cli-serve`
documents the only path: `reset-encrypted-columns --force`, which wipes every
stored provider credential so they can be re-entered by hand. Back up
`omniroute/data/server.env` before touching anything in that directory.

Both files there are mode **644** — world-readable, on a host with three shell
accounts, while `subsa` is uid 1001 and the files are uid 1000. That is
`king-audit.sh` C-7, and the fix is `chmod 600` with the container (uid 1000,
the owner) unaffected. It is left for a moment when someone is watching,
because permissions in this directory are what silently destroyed every API key
once already.

## Tier 4 — the workflow engine

| Variable | Where | Notes |
|---|---|---|
| `AP_ENCRYPTION_KEY` | `activepieces/.env` | Encrypts stored connections. Same class of hazard as above: rotating it orphans every saved connection. |
| `AP_JWT_SECRET` | `activepieces/.env` | Signs sessions. Rotating logs everyone out, which is harmless. |
| `AP_POSTGRES_URL` | `activepieces/.env` | **Carries the Neon password inline.** Rotating the database password means editing this URL. `king-backup.sh` reads it to run `pg_dump`, and passes it through the environment rather than a command line so `ps` cannot read it. |
| `AP_REDIS_PASSWORD` | `activepieces/.env` | **Empty.** This is `king-audit.sh` C-10 seen from the other side: both Redis instances answer `CONFIG GET requirepass` with nothing, on one flat network shared with ten containers including the sidecar that runs model-authored code. Setting it means setting it in Redis and here, in the same change. |
| `AP_FRONTEND_URL` | `activepieces/.env` | Not a secret; listed so the file's inventory is complete. |

## Tier 5 — provider and third-party credentials

Stored in `storage.sqlite` as `enc:v1` ciphertext, not in any `.env`. Rotate at
the provider, then update through the gateway UI.

| Variable | Where | Notes |
|---|---|---|
| `E2B_API_KEY` | `agent-sidecar/.env` | The code-execution sandbox. A holder can run arbitrary code in E2B on this account. |
| `MODAL_TOKEN_ID`, `MODAL_TOKEN_SECRET` | `agent-sidecar/.env` | Alternative sandbox backend. |
| `NTFY_TOKEN` | `.env` | Publishes to the alert topic. A holder can send you notifications, not read them. |
| `SEARXNG_SECRET` | `.env` | Instance secret for the search service. |
| `POOL_ALERT_SECRET`, `POOL_ALERT_URL` | `.pool-prove.env` | HMAC secret and webhook for the pool-prove timer. Read via `EnvironmentFile` so the secret never appears in a systemd unit. |

The Tavily and OpenRouter keys **passed through chat** and should be treated as
disclosed. They live in the gateway, not in a file here.

## Tier 6 — admin access

| Variable | Where | Notes |
|---|---|---|
| `OMNIROUTE_ADMIN_PASSWORD`, `INITIAL_PASSWORD` | `omniroute/.env` | The gateway's admin login. Changing it needs the UI as well as the file; `verify-credentials.sh` performs a real admin login as one of its seven checks. |

## Flags that are not secrets but decide whether secrets leak

Checked, and currently set correctly. They are here so a future `.env` edit
that flips one is visible as a change to this list.

| Variable | Value | Meaning |
|---|---|---|
| `ALLOW_API_KEY_REVEAL` | `false` | The gateway will not display stored keys. **Do not enable.** |
| `INSPECTOR_MASK_SECRETS` | `true` | The request inspector redacts credential-shaped values. |
| `REQUIRE_API_KEY` | set | Anonymous `/v1` access is refused; C-5 verifies this from outside. |
| `INSPECTOR_INTERNAL_INGEST_TOKEN` | empty | Inspector ingest is not exposed. |
| `CLOUD_URL`, `NEXT_PUBLIC_CLOUD_URL` | empty | No cloud control plane is configured. |
| `BASE_URL`, `NEXT_PUBLIC_BASE_URL` | the public host | Not secrets; listed for completeness. |

---

## After every rotation

```bash
./scripts/verify-credentials.sh     # seven real calls, including two negatives
./scripts/king-audit.sh -d C        # ignore rules, permissions, blast radius
./scripts/king-audit.sh -d F        # the MCP servers still answer
./scripts/king-audit.sh -d L        # the gateway still has its keys
```

`C-2` scans git history for token-shaped strings, because rotation does not
help if the old value is still in the log. `C-9` compares what exists against
what this document names — if it fails, a secret was added and this file was
not updated, which is exactly the gap it was written to close.
