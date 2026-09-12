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

Both files were mode **644** until 2026-09-10 — world-readable on a host with
three shell accounts, while `subsa` is uid 1001 and the files are uid 1000, so
read access came entirely from that mode. They are now 600 **inside a 700
directory**, and the directory is the half that lasts: `chmod 600` on
`storage.sqlite` is undone the next time SQLite rewrites its WAL, which happens
minute by minute, while nothing the application does rewrites a directory's
mode. The container is the owner, so it was unaffected; `stax-preflight` only
stats the directory, which needs traverse on the parent.

`C-7` now checks the directory as well as the files. It also stopped counting
the two files the moment they went behind a 700 directory — `[ -e ]` needs
traverse on every parent — and reported a pass over six of eight until the
existence test learned to fall back to `sudo` like the stat beside it already
did.

## Tier 4 — the workflow engine

| Variable | Where | Notes |
|---|---|---|
| `AP_ENCRYPTION_KEY` | `activepieces/.env` | Encrypts stored connections. Same class of hazard as above: rotating it orphans every saved connection. |
| `AP_JWT_SECRET` | `activepieces/.env` | Signs sessions. Rotating logs everyone out, which is harmless. |
| `AP_POSTGRES_URL` | `activepieces/.env` | **Carries the Neon password inline.** Rotating the database password means editing this URL. `king-backup.sh` reads it to run `pg_dump`, and passes it through the environment rather than a command line so `ps` cannot read it. |
| `AP_REDIS_PASSWORD` | **root `.env`** | Set 2026-09-10. Compose passes it to `ap-redis` as `--requirepass` and to `activepieces` as an environment entry, so there is **one** source — the line in `activepieces/.env` is commented out with a pointer, because two files holding one secret is two files that can disagree and the failure looks like a broken Redis. Rotating it means one edit and `docker compose … up -d --force-recreate ap-redis activepieces`, both together: change Redis first and the workflow engine loses its queue until they agree. `omniroute-redis` is still unauthenticated and cannot be fixed from this repo — see `scripts/unauthenticated-datastores.txt`. |
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
| `LANGFUSE_OTLP_AUTH` | `.env` | **Added 2026-09-11.** The Langfuse key pair, base64 in an `Authorization: Basic` header, read by `otel-collector` (`docker-compose.yml:74`). A holder can write traces into your Langfuse project and read the project id from the header. Rotate at Langfuse, then re-encode the pair. |
| `NTFY_ALERT_TOPIC` | `.env` | **Added 2026-09-11.** Not key-shaped, and a credential anyway: `ntfy` topics are unauthenticated by name, so the random topic *is* the access control. `stax-preflight.sh:345` already says it "rides in the URL of every publish; a guessable one" is the whole risk. Rotate it with `NTFY_TOKEN`, and update the Activepieces `gateway_alerts` step that publishes to it. |
| `MACHINE_ID_SALT` | `omniroute/.env` | **Added 2026-09-11.** Upstream `ARCHITECTURE.md` files it under "Security hashing: `API_KEY_SECRET`, `MACHINE_ID_SALT`" — the same sentence as a key already in Tier 2. Rotating it changes every derived machine id, which is harmless here because nothing pins one. |

`AGENTBRIDGE_UPSTREAM_CA_CERT` (`omniroute/.env`) is **empty** and listed so the
slot is known: it would hold a CA certificate, which is public, but the private
key that pairs with one would not be.

The Tavily and OpenRouter keys **passed through chat** and should be treated as
disclosed.

**Correction, 2026-09-11: the OpenRouter key is also in a file here.** This
section previously said both "live in the gateway, not in a file here". That is
true of Tavily and false of OpenRouter:

| Variable | Where | Reads it |
|---|---|---|
| `openrouter` | `providers.env` (gitignored, mode 600, one variable) | `scripts/pool-register.sh`, via `KEYFILE` |

It is lowercase, which is why nothing caught it: C-9 matched `^[A-Z0-9_]+=`, so
every lowercase name in a secret file was invisible to the check that exists to
find exactly this. **Rotating OpenRouter in the gateway UI and stopping there
leaves the old key on disk**, and the next `pool-register.sh` run registers it
again — the literal case `king-mistakes.md` 24 describes: a rotation is done
when everything that read the old credential has been checked, not when the new
one is accepted.

### How these three were missed, which matters more than the three

They were not found by reading the list. They were found by enumerating the
`.env` files and asking which names the list does not contain — and the reason
C-9 had been passing is that its own definition of "secret-shaped" was the
pattern `KEY|TOKEN|SECRET|PASSWORD|DSN|URL`. `AUTH`, `TOPIC` and `SALT` match
none of it, so all three were excluded from the set C-9 checked *and* from the
count it reported. **A check that derives its denominator from the same
heuristic as its test cannot fail on anything the heuristic misses**, and will
keep reporting a complete list for as long as the gap stays in the blind spot.

A value-shape heuristic was tried as a replacement and has a different hole, not
a smaller one: it missed `LANGFUSE_OTLP_AUTH` (whose value contains a space,
because it is a `Basic …` header) and `MACHINE_ID_SALT` (19 characters, under
any sane length floor). Two heuristics, two blind spots, no overlap.

So C-9 no longer uses a heuristic at all. Every variable in every secret-bearing
file must be named **in this document** or acknowledged in
`scripts/not-secrets.txt`. That predicate has no blind spot: a new variable is
either reviewed or the audit is red.

### A fourth shape: the step settings carried the bearer — 2026-09-12

`flow-search` is disclosed. Diagnosing why an MCP tool call returned nothing, I
read a flow step's settings to find which URL it uses. The step is an HTTP
request, and an HTTP request's settings carry its `Authorization` header.

**This repo had already written the hazard down.** `docs/king-system.md` says
the `flows/` mirror excludes each step's `input` block *because it holds the
monitor's bearer token and the webhook HMAC secret*. The danger was documented,
the mitigation was in place for the mirror, and I walked into it from the other
direction — through the API instead of the file.

Fourth shape of one fault, after a `sed` that did not redact, a `SELECT *` on a
table with a token column, and a getter asked a yes/no question. The pattern is
not "be careful with credentials". It is: **any object that CONTAINS a
credential prints it when you ask the object about something else.** A row, an
environment, a config, a step.

Blast radius, measured rather than assumed:

    /v1/search            200   works
    /v1/chat/completions  503   refused — no model access
    /api/keys             403   no manage scope
    /v1/models            200   catalogue only

So a holder can spend Tavily credit at $0.008 a search and read the model list.
Nothing else. That is bounded, and it is not nothing: `king-roadmap.md` lists
Tavily credit as finite with no fallback by design.

Rotating it means updating every flow step that carries it — the search step of
`search_web` and `web_research` at least — so it is a UI pass, not a script
one. `king-rotate.sh` does not own this key; the gateway mints it.

### Rotated at Neon, then disclosed again — 2026-09-12

The password WAS changed in the Neon console at about 00:40, which is what took
Activepieces down: `activepieces/.env` still held the old one, the container
went unhealthy, and `E-2`/`D-2` went red. Diagnosed from the error rather than
guessed — `password authentication failed for user 'neondb_owner'`, with DNS
resolving and 5432 open, which rules out suspend, quota and network.

The new URL was then pasted into chat so the file could be brought in line, and
that is the part worth recording. **Rotating and then pasting the new value
moves the exposure rather than closing it.** The old URL is now dead — verified
by offering it to Neon, which refused it — and the new one is in a transcript.

The rotation record is corrected to `pending` for the second time in one night,
for the same reason both times: `--list` reports whether the VALUE CHANGED, and
what matters is whether the value is SECRET. Ending the rotation by typing the
value at the script's hidden prompt costs the same thirty seconds and leaves
nothing behind.

### Disclosed a second time, and deferred deliberately — 2026-09-12

`AP_POSTGRES_URL` was pasted into chat again, and the operator has chosen to
defer rotating it until after the current round of testing. That is their call
and it is recorded rather than argued.

Two things worth writing down so the same exchange does not repeat:

**It was not needed.** Every query run against that database in that session
read the DSN from `activepieces/.env` on the VPS, which is where it already
lives. Pasting it added exposure without adding capability — and the exposure
is the whole of it: host, database, user, and password inline, on a Neon
instance whose 5432 answers from the public internet.

**Deferring is a real decision with a real shape.** Until it is rotated, anyone
holding either transcript has full read/write on the workflow database from
anywhere. Not the gateway, not the host — the database that holds every flow,
connection and run. `./scripts/king-rotate.sh AP_POSTGRES_URL` after changing
the password in the Neon console; the script handles the rest.

### A rotation that changed the value and not the exposure — 2026-09-12

`.rotation-state` recorded `AP_POSTGRES_URL rotated 2026-09-11T08:07:48Z`, and
`--list` therefore showed it **done**. Both were true and neither was useful:
the value did change that morning, because the operator moved to a fresh Neon
project — and then pasted the NEW URL into chat to get the system running.

So the credential with the largest blast radius on this page was recorded as
handled while its live value sat in a transcript. Verified 2026-09-12: the
active host is `ep-lingering-firefly`, the same project named in the table
below, and Neon's port 5432 answers from the public internet.

The record is corrected to `pending`. **A rotation is done when the new value is
secret, not when the old one stopped being used** — which is `king-mistakes.md`
24 arriving from a direction it had not been read from before.

`AP_REDIS_PASSWORD` is the one genuine `done` on this page. Rotated 2026-09-12
after it was committed to a public repository in a self-test fixture; verified
by pulling the old value back out of that commit and offering it to Redis,
which answered `WRONGPASS`.

### Disclosed, and therefore first in the queue

| Credential | How | Date |
|---|---|---|
| Tavily API key | passed through chat | earlier session |
| OpenRouter API key | passed through chat | earlier session |
| `AP_POSTGRES_URL` (Neon project **ep-lingering-firefly**) | pasted into chat by the operator when moving to a fresh Neon project | 2026-09-11 |
| Activepieces `mcp_server.token` (`xBV1BLizfp5BTECqSItQU`) | **printed in full to a session transcript** while inspecting a backup: the row was dumped to find the MCP tool wiring, and `token` is one of its columns | 2026-09-11 |
| `GRAPHIFY_API_KEY` | **printed in full to a session transcript** by a `docker inspect ... \| grep` whose masking pattern did not match what it printed | 2026-09-10 |

The fourth was a deliberate trade, not an accident: on 2026-09-11 the previous
Neon project's data-transfer quota was exhausted and Activepieces could not
reach its database at all, so the operator moved to a fresh project and pasted
the new URL in chat to get the system running again. It carries the database
password inline, and **the old project's URL is equally disclosed and equally
dead** — the quota that killed it is the reason it was replaced. Both go in the
same rotation pass. Everything else in Activepieces was intentionally left
alone until the system is stable.

The fifth is mine, and it is the second time: the same mistake as
`GRAPHIFY_API_KEY` below, in a different shape. I dumped an `mcp_server` row to
find out how the restored flows were exposed as MCP tools, and `token` is a
column of that table — so a query written to answer a wiring question printed a
credential as a side effect. **A row is not a field. Selecting `*` from a table
that holds a secret prints the secret**, and the intent of the query does not
change what lands in the transcript.

Its blast radius is small and that is luck, not care: the token belongs to the
Activepieces MCP server of the OLD Neon project, which is defunct — its quota
is exhausted and the deployment no longer points at it. It is listed anyway,
because "it was probably already dead" is exactly the reasoning that leaves a
live credential in a log. If that project is ever revived, this token is burnt.

It also settles a design question. The MCP server row was a candidate for
restoration alongside the flows; it will not be restored, because restoring it
would put a now-disclosed token back into service. The operator creates a fresh
MCP server in the Activepieces UI instead, which mints a new token — and has to
reconfigure the Claude MCP connection regardless, since the URL carries it.

The sixth is mine as well, and it is the third time — the same fault wearing a
third face. Checking whether `ap-redis` actually requires a password, I ran
`CONFIG GET requirepass`, and **that command answers the question by returning
the password**. `AP_REDIS_PASSWORD` is therefore disclosed and needs rotating:
the value in the root `.env` and Activepieces' own environment, applied by
recreating both containers in one command so the queue is never pointed at a
Redis whose password it does not know.

The pattern is now unmistakable across all three: `GRAPHIFY_API_KEY` came from
a `sed` meant to redact and matching nothing; the `mcp_server` token came from
selecting a row to read a different column; this came from asking a yes/no
question with a command that replies with the secret. **A question about a
credential is not the same as a request for it, and the tooling does not know
the difference.** The predicate was available and cheaper in each case — here,
`CONFIG GET requirepass | tail -1 | wc -c` answers "is one set" without
printing it, and an unauthenticated `PING` failing proves it from outside.

The third one is mine. The command intended to print variable names and mask
values, and the `sed` that was supposed to redact it matched nothing — so the
key reached the transcript in plaintext. It authenticates the codegraph MCP
server, which serves the code graph read-only, so the blast radius is reading
this repository's own structure. That is the smallest radius on this page and
it still needs rotating, because "small" is not "none" and a credential in a
transcript is a credential in an unknown number of places.

Rotating it means the value in the root `.env`, the sidecar's environment
(which reads it from there through compose), and the `claude mcp add`
registration that carries it as a bearer header.

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
