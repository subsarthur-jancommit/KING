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

## 14. Shipped fifteen commits past a CI job that was never going to run

**What happened.** Over one session the agent sidecar gained an MCP server, an
audited `vps_exec` shell, a move of code execution to E2B/Modal, and a
volume-ownership fix — roughly fifteen commits, all pushed straight to main.
`.github/workflows/stax-smoke.yml` lists `agent-sidecar/**`,
`docker-compose.yml`, `caddy/**` and `scripts/**` in its path filter, and every
one of them was touched. **It never ran once.** Its only triggers were
`pull_request` and `workflow_dispatch`, and nothing opened a pull request.

**Why it was not caught.** A workflow existed, with the right name and the
right paths, so the question "but does it fire on push?" was never asked. What
stood in for CI was 81 tests passing in a container built and run by hand on
the VPS — entry 2's failure with the stale cache removed and the independent
reviewer still missing.

**What made it visible.** Installing `gh` to diagnose a *different* red build.
That one turned out not to be ours at all; the one that mattered was the job
silently not running. A run that never happens produces no notification, no red
mark, no row in any list — it is indistinguishable from a repo with nothing to
test.

**Rule.** A path filter says what a workflow *covers*; the event list says
whether it ever *fires*. Read both. When CI is being trusted as the guard,
confirm a run exists for that commit — **absence of red is not green.**

---

## 15. Fixed a tool failure by guessing, and the guess made it worse

**What happened.** The newly tool-enabled agent could not search. Its run
records showed it calling `omniroute_web_search` with
`provider: "duckduckgo-free"` — a provider the gateway advertises and holds no
credential for — then retrying other dead ones until the step budget ran out.

The fix looked obvious. A direct MCP `tools/call` omitting `provider` had just
been verified working, served by Tavily. So: instruct the agent not to set the
field and let the gateway auto-select. That shipped, was rebuilt, redeployed
and re-tested.

The next run failed differently and more informatively: **`Argument provider is
required`**, three times in one run.

**Why the obvious fix was wrong.** The direct probe and the agent's call do not
travel the same path. smolagents validates tool arguments **client-side**
against the MCP tool's declared input schema before a request is ever sent, and
that schema marks `provider` required. The server is lenient and accepts the
call without it — which is precisely why the probe succeeded and produced a
confident, wrong conclusion.

The real fix was the opposite instruction: name `tavily-search`, the one
provider of twenty reporting `cred=configured`.

**What would have caught it.** Reading the tool's input schema — one call away
— instead of generalising from a probe that exercised a different code path.

**Rule.** A successful probe proves the path *the probe took* works. It does not
prove another caller takes that path. Where a client and a server disagree
about a contract, the strict one decides, and the client is usually the strict
one.

---

## 16. A guard that read the wrong file, and agreed by luck

**What happened.** `stax-preflight.sh` reported
`AGENT_SIDECAR_EXECUTOR=local` and warned that model-generated Python was
running inside the sidecar container. The container was running `e2b`.
Confirmed both ways: `docker exec printenv` says `e2b`, and the value is in the
root `.env`.

**Why.** Compose delivers that variable through `environment:` as
`${AGENT_SIDECAR_EXECUTOR:-local}`, interpolated from the host environment or
the root `.env`. **`environment:` overrides `env_file:`**, so a value written in
`agent-sidecar/.env` — the file preflight was reading — can never take effect at
all. The lookup returned empty every time, and empty falls through to `local`.

**The part that makes it worth an entry.** It warned, and the warning looked
right. On a host genuinely set to `local` it would also have said `local`, for
the same wrong reason. The check could not distinguish the two states it
existed to distinguish, so every correct reading it had ever given was luck.

I then repeated it the same day, in a new check, for two more variables.

**What it hid alongside.** Chasing why a new build-cache warning never fired
turned up that `check_disk_gb` is only called by the `codegraph` and
`localmodel` profiles. `base` — which builds a 3.15 GB image over nine minutes,
the largest build here — checked disk not at all.

**Rule.** Read a setting from wherever the runtime actually takes it, and say
which file that is in a comment. For Compose specifically: `environment:` beats
`env_file:`, so an interpolated variable is decided by the root `.env` and a
service `.env` cannot influence it. And when a guard agrees with reality, that
is not evidence it is measuring reality.

---

## 17. Published a conclusion, then ran the control that broke it

**What happened.** A new `served_by` field showed that an agent run requesting
`paid-first` was answered by `big-pickle`. I wrote that up and committed it as
"the agent falls through `paid-first` to the free tier" — a combo falling back
is what combos are *for*, so the story needed no work to believe.

The control case took one command and I ran it afterwards: request
`agy/claude-sonnet-4-6`, a direct model with no ladder to fall through. Same
result. It was never fallthrough. The gateway switches routing strategy on the
prompt's content and overrides the model named in the request, which affects
every caller rather than only combos.

**Then I did it again.** Bisection showed the two trigger lines were the two
mentioning reasoning and code, which matches `intentClassifier.ts` exactly, and
`autoStrategy.ts` gates that on `intentDetectionEnabled`. I nearly wrote "the
fix is to disable intent detection". Setting it to `false` on the live gateway
changed nothing — `strategy=auto` before, during and after.

**Why the first version was more believable than the truth.** It fitted a
mechanism that exists and is documented. Fallthrough is real, combos do it, and
the observation was consistent with it. Consistent is not the same as caused,
and the difference is one control case.

**What it cost.** Two commits of wrong documentation in a file whose whole
value is being trustworthy, and an hour eliminating eight hypotheses that
`x-omniroute-decision` — a header present on every response the whole time —
would have answered in one request.

**Rule.** Before publishing a cause, run the case that the cause predicts will
behave *differently*. If the explanation is "the combo fell through", the
control is a request with no combo. And read the diagnostic headers the service
already returns before eliminating anything by hand.

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


---

## Not ours — recorded so it is not diagnosed a second time

`omniroute-smoke` has been red since `f6d0ec9` (2026-09-04); `49fd3bd` was the
last green. Nothing in this repo causes it.

`tls-client-node@0.2.0` downloads a native binary from `bogdanfinn/tls-client`
releases, looking for `tls-client-linux-ubuntu-amd64-1.16.0.so`. Upstream
renamed its release assets — v1.16.0 ships `tls-client-xgo-1.16.0-linux-amd64.so`.
The name the package wants no longer exists, the download is skipped, and the
deliberate guard at `omniroute/Dockerfile:111` exits 1. That guard is behaving
correctly: the alternative is shipping an image whose TLS client is absent.

Three checks close the obvious escape routes, so none of them is worth retrying:

- **Not rate limiting.** A GitHub token changes nothing; the asset is genuinely
  named something else.
- **Nothing to upgrade to.** `0.2.0` is already the newest release on npm.
- **Nothing to inject.** `omniroute/Dockerfile` declares no ARG for a token or
  a binary path, and `omniroute/` is a squashed subtree that must not be edited.

It clears when `tls-client-node` publishes a fix, or when a newer omniroute
release arrives via `git subtree pull`. Until then this job stays red, and that
is the correct state.
