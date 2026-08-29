# Langfuse — why Cloud, and why the vendored stack stays off

This is the rationale doc. The runbook is
[observability.md](./observability.md) (Bahasa Indonesia).

## Two Langfuse paths exist in this repo, and only one is used

`observability/docker-compose.langfuse.yml` vendors Langfuse v4's official
self-host compose behind the `observability` profile. It is off, and it should
stay off on a small host.

`otel-collector/config.yaml` plus the `tracing` profile forwards OmniRoute's
built-in OTLP exporter to **Langfuse Cloud**. That is the live path.

## Why not self-host

The vendored stack is **six containers**: `langfuse-web`, `langfuse-worker`,
`clickhouse`, `minio`, `langfuse-redis`, and `postgres`. ClickHouse and Postgres
alone are heavier than everything else this repo runs.

More to the point, it is the **only profile in the repo with no `mem_limit` or
`cpus` on any service**. Every STAX-authored service carries a ceiling; the
vendored Langfuse file carries none, because it was copied verbatim from
upstream. On an 8 GB VPS already running the gateway, a reverse proxy, and a
workflow engine, adding six unbounded containers is not a defensible default.

Langfuse Cloud's free tier costs nothing, needs no credit card, and adds zero
load to the VPS. For a deployment whose entire premise is "pay for Claude and
nothing else", that is the better trade.

Keep the vendored file. It is the right answer for someone with a bigger host or
a requirement that trace content never leave their infrastructure — and in that
case, add resource ceilings first.

## Why the gateway exports, not the agents

An earlier plan in this repo proposed instrumenting `agent-sidecar` with a
Langfuse SDK. That would have missed the traffic that actually matters.

Activepieces calls OmniRoute directly over the Docker network
(`http://omniroute-base:20128/v1`). Those calls never pass through
`agent-sidecar`, and never through Caddy either — so neither agent
instrumentation nor reverse-proxy access logs can see them. Instrumenting the
gateway catches everything, because everything goes through the gateway by
design.

That is also why the advice previously given in
[scalability-system.md](./scalability-system.md) — set `agent-sidecar`'s
`LANGFUSE_HOST` — could not have worked: no code in this repo reads that
variable, and even if it did, it would trace the wrong hop.

## Why a collector sits in the middle

OmniRoute ships its own OTLP/HTTP exporter at
`omniroute/open-sse/services/routing/otel.ts`, emitting GenAI semantic
conventions. It is enabled by `OMNIROUTE_OTEL_ENDPOINT` and disabled when that
is empty.

It sends exactly one header: `Content-Type: application/json`. Langfuse requires
HTTP Basic auth. That single missing header is the collector's entire reason to
exist — it receives OTLP unauthenticated over the compose network, attaches the
credentials, and forwards.

The collector's receiver is deliberately **never published to the host**.
Anything that can reach port 4318 can write traces into the Langfuse project.

## Why not the bundled Langfuse plugin

OmniRoute ships a Langfuse plugin at `omniroute/examples/plugins/langfuse/`
with `onRequest` / `onResponse` / `onError` hooks. It cannot work as written.

The plugin marks a request by setting `ctx.metadata.__langfuseSampled` during
`onRequest`, then guards on it during `onResponse`. But
`open-sse/handlers/chatCore/pluginOnRequest.ts:38` and
`pluginOnResponse.ts` each construct a **separate** `metadata: {}` object. The
flag is never visible downstream, so the guard returns early on every request
and no trace is ever emitted.

Patching that made the plugin emit correctly when driven directly — a harness
produced a genuine `omniroute:auto/best-coding` trace in Langfuse. The gateway
still never invoked the hook, and `runOnResponse(...).catch(() => {})` discards
whatever failed. Diagnosing further would mean editing the vendored subtree,
which this repo does not do.

The OTLP path avoids the plugin runtime entirely, which is why it was chosen
even after the plugin bug was understood and fixed.

## Upgrading the vendored stack

Re-diff `observability/docker-compose.langfuse.yml` against upstream before
bumping the pinned `:4` image tags. Two edits were made during vendoring and
must survive: the Langfuse Redis is remapped from 6379 to **16379** so it does
not collide with OmniRoute's own Redis, and every service carries
`profiles: [observability]` so the stack stays opt-in.

## Status

**Proven live on 2026-08-29:** traces from OmniRoute reach Langfuse Cloud
through the collector, including calls originating in Activepieces flows, with
latency recorded. Verified by querying `/api/public/traces` directly.

**Not exercised:** the self-hosted `observability` profile has never been booted
on the VPS. Its validation to date is `docker compose config` only — see
[scalability-system.md](./scalability-system.md).
