# KING — mistakes, and what each one cost

A record of things that went wrong while building this, kept because the
failures were more instructive than the successes and several of them were
repeats. Written from the sessions of 2026-08-29 to 2026-09-01.

Each entry states what happened, why it was not caught sooner, and the rule it
produced. Nothing here is softened; an entry that reads well is an entry that
will be repeated.

---

## 1. Took the VPS down with an unconstrained build

**What happened.** `docker compose build agent-sidecar` was run on a 2 vCPU
host with 3.5 GB free and eight containers running. The box went into memory
thrashing: `gateway.arject.co` and `flows.arject.co` stopped answering, port 22
accepted TCP but never sent an SSH banner. Ten reconnection attempts over
twenty minutes all failed. The operator had to reset the instance from the GCP
console.

**Why it was not caught.** Every service in this repo carries `mem_limit` and
`memswap_limit` set equal, precisely so a container OOMs inside its own cgroup
instead of dragging the host down. **Those limits do not apply to `docker
build`.** The build runs in the daemon, outside any service cgroup. The care
taken over runtime limits produced false confidence about build time.

It is worse than an oversight: `codegraph-build` had already been measured
needing 4 GB and being OOM-killed at 3 GB. That number was known and not
applied.

**Rule.** Constrain the build explicitly — `docker build --memory 2g
--memory-swap 2g` — and never combine building with starting (`up -d --build`)
on a loaded host. Free memory first if the headroom is thin.

**Footnote.** When the build was later re-run correctly it finished in **20
seconds**, because the dependency layer was already cached. The thing that took
the host down was not heavy work; it was unbounded work next to eight running
containers.

---

## 2. Reported a passing test suite that never contained the change

**What happened.** After editing `server.py` and copying it to the VPS,
`docker compose run agent-sidecar` reported **24 passed**. That was about to be
presented as proof the change was safe.

**Why it was wrong.** The service declares `build: ./agent-sidecar`, and
compose reused the already-built `king-agent-sidecar:local` image. The copied
file never entered it. The tests that ran were the old ones against the old
code.

**How it was caught.** By reading the tests rather than trusting the number.
Two assertions compare the response to an exact dict, and the change adds a
`model` key — they *could not* have passed against the new code. The green run
was the proof it had not run.

**Rule.** Rebuild before believing a test result in a service with a `build:`
stanza. And when a result is surprisingly convenient, look for the reason it
might be measuring nothing.

---

## 3. Built an entire routing hierarchy on a premise that was about to be false

**What happened.** Combos, a local-model router, and a scoring harness were
built to minimise spend, on the assumption that the best models cost the most.
Then `agy` (Antigravity CLI) was connected: frontier models on subscription
quota, at **no marginal cost per call**. The strongest model in the stack became
the cheapest one to call, and most of the optimisation lost its purpose.

**Why it was not caught.** The provider inventory was never finished before the
optimisation started. The order was backwards.

**Rule.** Establish what things actually cost before building machinery to
economise on them.

---

## 4. Two prompt "improvements" that both made accuracy worse

**What happened.** The task router scored 41% on its first prompt and 91% after
a rewrite. Two further changes were then tried:

| Change | Score | Author |
|---|---|---|
| Wrap the task in `<task>` delimiters | **67%** | mine |
| A rewrite proposed by Claude Opus 4.6 | **73%** | a frontier model |

Both read as obvious improvements. The delimiters made the model *more* likely
to perform the task than label it — it answered `こんにちは` to a translation
task. Opus's version fixed the two failures it was shown and broke four others.

**Rule.** A scored set ships with the prompt, not beside it. Neither intuition
nor a frontier model's advice substitutes for running it. `local-router.sh`
exits non-zero below its accuracy floor for this reason.

---

## 5. Reintroduced a bug that had already been fixed once

**What happened.** `pool-register.sh` probed models with `max_tokens: 8`,
which marks reasoning models dead — they spend the budget thinking and return
empty content. That was found and raised to 400. Then `combo-paid-first.sh` was
written fresh with `max_tokens: 64`, and marked `perplexity/sonar-reasoning-pro`
DEAD when it was healthy.

**Why it was not caught.** The lesson lived in one script's history, not in
anything a second script would inherit.

**Rule.** When a fix encodes a fact about the world rather than about one
script, the fact belongs somewhere both scripts read — or at minimum in the
comment of every script that could repeat it.

---

## 6. Blocked a modifier as if it were a provider

**What happened.** Eleven dead providers were added to `blockedProviders`. One
of them, `no-think`, is not a provider at all — it is a prefix modifier applied
over another provider's model. It had been probed as `no-think/dva/…`, and
`dva` was the dead one.

**Consequence.** The entry is inert, since it matches no provider. It is still
wrong, and a wrong entry in a security-adjacent list ages badly.

**Rule.** Probe a suspect prefix against a *known-healthy* provider before
concluding the prefix is the problem. A positive control would have shown
`no-think/oc/big-pickle` answering in 1.3 s.

---

## 7. Left a credential-bearing file where two defences could not see it

**What happened.** Migrating Activepieces from Upstash to a local Redis left
`activepieces/.env.bak-upstash-20260830` in the working tree, carrying three
live secrets. It was **not** gitignored, so it was fully committable, and it was
**not** in the `/dev/null` mask list, so the OpenHands container — the one that
runs model-authored code — could read it.

**Why both defences missed it.** `.gitignore` listed exact paths
(`/activepieces/.env`) and the masks shadow exact filenames. One differing
suffix defeated both.

**Rule.** Defences that match exact filenames must be paired with a pattern.
`**/.env.*` with a negation for `.env.example` now covers the class.

---

## 8. Stated a live failure rate from a historical log window

**What happened.** `auto/*` was reported as failing 100% of the time, and a
plan was drawn up around fixing it. Measured directly, all four variants
answered **4/4**. The failure figure came from an old window in `call_logs` and
was treated as the present.

**Rule.** A log describes the past. If a claim is about now, measure now.

---

## 9. Shipped an agent with no iteration ceiling

**What happened.** A task handed to the local 1.5B model never converged: it
emitted malformed code blobs, smolagents rejected each and retried. `curl` gave
up at 300 s; the container log showed the run still on **step 5** afterwards.

**Two lessons, not one.** The local model cannot drive an agent loop at all —
it is a single-call worker. And **a caller giving up does not stop an agent**,
so a request timeout is not a bound. The ceiling had to move into the service.

**Rule.** An agent loop is the only thing in this stack that can spend without
bound. It gets a finite `max_steps`, which a caller may lower and never raise.

---

## 10. Two hours on a free web-search layer that failed dangerously

**What happened.** SearXNG was self-hosted as a free retrieval layer. It worked
at first — 5 results in 1.6 s. Then, asked about the Caddy web server, it
returned Chinese pages about typing circled numbers in Word: its one working
engine had been rate-limited by an afternoon of testing, and Bing filled the
gap with "Deep Learning Tutorial" pages.

**Why that is the worst kind of failure.** Not an outage — *wrong results that
look right*, which a model then synthesises into a confident, sourced, entirely
false answer.

**Rule.** "Free" is not the same as "no cost". The cost here was wrong answers.
And a fallback that silently degrades capability must be visible or removed —
which is why there is deliberately no fallback from Tavily to anything.

---

## 11. Raised a false alarm from a restricted key

**What happened.** After the VPS reset, `paid-first` was served by DeepSeek
rather than `agy`, and this was reported as `agy` being down and silently
costing money.

**What was actually true.** The probe key in use was
`gateway-monitor-triage`, which had been deliberately restricted from `agy/*`
hours earlier. Priority skipped the agy tiers exactly as designed. `agy` was
healthy the whole time.

**Rule.** Before calling a component broken, check whether the caller is the
thing that is limited. Own access controls are the first suspect for an
unexpected 403 or an unexpected fallback.

---

## 12. Repeated a documented mistake, six days after documenting it

**What happened.** Added a `qdrant` service to the root `docker-compose.yml`.
`omniroute/docker-compose.yml:221` already defines one.

That is precisely what entry 1 of this file and the comment at the top of the
compose file both forbid, citing the `omniroute-base` override that turned
every Docker CI job red with `conflicts with imported resource`.

**Why it was not caught.** For the same reason as last time: it worked.
Compose v5.5 accepts the override, so the container came up healthy — carrying
*my* image `v1.19.1` under *their* `container_name: omniroute-qdrant`. The
mismatch in that one line was the only visible tell, and it appeared in the
`up` output as `Container omniroute-qdrant Starting`, which reads as normal.

**The second mistake inside the first.** It was never needed. The comment
above their service says SQLite + sqlite-vec + FTS5 is the primary vector
store and Qdrant is for cross-instance sharing or >1M points. `enabled: false`
in `/api/settings/qdrant` means the dual-write path is off, **not** that memory
is off. Verified after reverting: `omniroute_memory_add` then
`omniroute_memory_search` wrote and retrieved a record with no Qdrant running.

**Rule.** Before adding any service, grep `omniroute/docker-compose.yml` for
its name. And before adding infrastructure to enable a feature, check whether
the feature already works — `enabled: false` on one backend does not mean the
capability is unavailable.

---

## 13. Smaller ones, kept for the pattern

- **Executable bit lost on Windows.** Two scripts were committed `100644` while
  every other script in `scripts/` is `100755`. After `git pull` on the VPS they
  would not run, and `chmod` then left the tree permanently dirty against the
  index — which is how the next pull becomes a conflict.
- **`ollama-pull` fetched a model the server would never serve.** The puller
  defaulted to `3b` and the server to `1.5b`, with `OLLAMA_MODEL` unset. A clean
  deploy would download 2 GB and then fail a healthcheck forever. The running
  host hid it because the right model had been pulled by hand during bring-up.
- **Chained a merge and a branch delete with `&&`.** The merge failed on an
  em-dash in the commit title, the delete ran anyway, and an unmerged branch was
  deleted. Recovered from reflog. Verify `merged == true` before deleting.
- **Waited on CI that could never run.** A docs-only PR, and both workflows
  were path-filtered without `docs/**`. The operator noticed before the wait
  did.
- **A test wrapper reproduced the `|| echo 0` bug** an hour after the same bug
  was removed from production code.

---

## The pattern underneath most of these

Three shapes account for nearly every entry:

1. **A guard that does not cover the case it appears to cover** — runtime memory
   limits that do not bind builds, gitignore paths that do not match variants,
   masks that match exact filenames.
2. **A measurement that measures nothing** — a cached image, a historical log
   window, an HTTP status instead of a response body.
3. **Confidence ahead of evidence** — optimising costs before knowing them,
   improving a prompt without a score, calling a component dead without a
   positive control.

The standing rule that comes out of all three, and the one most worth keeping:
**anything that cannot be measured is treated as a failure, not a pass.**
