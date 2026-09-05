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

## 18. Assumed a library handled a list item-by-item, and shipped a new SPOF

**What happened.** Adding the code graph as a second MCP server for the agent,
I passed both servers to `smolagents.MCPClient` as a list — which its signature
accepts and which reads better than managing two clients. Then I wrote in the
docs that "a graph outage costs it four tools, not eleven".

Testing that sentence broke it. With the graph pointed at a dead port the
client raised `TimeoutError` and the agent loaded **zero** tools. The list is
all-or-nothing.

**What that actually did.** It took an optional capability and made it a single
point of failure for a required one. Before the change, web search worked
whenever the gateway was up. After it, web search also required the code graph
— a service in a different profile that a `docker compose down` on one profile
would take out.

**Why the shape is worth recording.** Accepting a list looks like a promise
about independence. It is only a promise about the argument type. The failure
mode of a collection API — partial success, or none — is a separate question
from whether it takes a collection, and it is not usually in the signature.

**What caught it.** Writing the resilience claim down, then testing the claim
rather than the feature. The feature worked perfectly in every test I had run:
both servers up, eleven tools, correct answers.

**Rule.** When a change adds a dependency, test the new dependency *failing*,
not just working. And treat "this API accepts a list" as saying nothing about
what happens when one element is bad — find out, because the tidy version and
the resilient version look identical until something breaks.

---

## 19. A control that passed its test by coincidence

**What happened.** Testing whether the gateway's content-based reroute respects
per-key model restrictions, I created a key allowing only
`opencode/big-pickle` and sent both a plain and an agent-shaped prompt. Both
came back served by `big-pickle`. That reads as enforcement, and I was one
sentence from writing "restrictions are respected".

**Why it was meaningless.** `big-pickle` is where the reroute lands. The key
permitted exactly the model the bypass would have chosen anyway, so a passing
result and a failing one were indistinguishable — the test could not have
detected the thing it was for.

**The test that worked.** A key allowing only
`ollama/qwen2.5:1.5b-instruct-q4_K_M` — a model the reroute never lands on.
Plain prompt: served by ollama. Agent-shaped prompt: served by `oc/big-pickle`,
a model that key is explicitly forbidden from using, with no 403.

**And the same day, again.** Having written that scopes were "not shown to be
bypassable", I tested that too. A key with `scopes: ["search"]` and no model
list completed a `/v1/chat/completions` call. Scopes gate the management API,
not inference — so a documented claim that a search-scoped key gets "403 on
every real model" cannot be true for the stated reason.

**And the coincidence was narrower than it looked.** `big-pickle` is where the
reroute lands *for that probe's prompt*. Under the prompt the sidecar actually
sends, it lands on `gemini-3.7-flash-high` — see entry 20. So the bad control
was not just uninformative; it was uninformative in a way that would flip to
the opposite verdict on a different prompt, with nothing changed.
`scripts/check-model-routing.sh` therefore reports whether two prompts
*disagree* rather than looking for a particular provider name.

**Rule.** When testing whether a control holds, choose a case where the control
and the bypass predict *different* outcomes. If the allowed value is also the
value the bypass produces, a pass proves nothing. And "not shown to be
bypassable" is a statement about what you tested, not about the system — say so
in those words, or go and test it.

---

## 20. Generalising a measurement across the one variable I had proved it depends on

**What happened.** I had already established, by bisecting the system prompt
line by line, that OmniRoute's routing is decided by prompt *content*. Then I
measured where a rerouted request lands using a one-line probe, got
`oc/big-pickle` three times out of three, and wrote "every agent run is served
by the free tier" — a claim about the sidecar, whose prompt is the 9,867-character
smolagents system prompt, not my one line.

**What it actually does.** Measured within five minutes of each other, same key,
same requested model, both perfectly deterministic:

```
one-line trigger, via /v1        -> oc/big-pickle             6 of 6
smolagents system prompt, /run   -> gemini-3.7-flash-high     3 of 3
```

Content decides the strategy *and* the destination. I knew the first half and
assumed the second half away.

**How I nearly shipped it.** I saw the two results disagree, and my first
explanation was that the destination had drifted overnight — which fit both
observations and was wrong. I committed that. What killed it was the cheap
control: re-run the old probe *now*. Six out of six `oc`, at the same moment the
sidecar was getting `gemini`. Time was not the variable; the prompt was, and
nothing about "it changed since yesterday" would have survived one repetition of
yesterday's test.

**Why it matters beyond tidiness.** The reroute sends work to a third party. Which
third party is a confidentiality question, and the honest answer for the sidecar
is Google, not the free tier I had recorded. A reader deciding whether local-only
work is safe would have been reading a figure measured on a prompt nobody sends.

**Rule.** When a system has been shown to depend on some variable, every later
measurement of that system is scoped to the value you used — write the value
down beside the number, and re-measure before generalising. And when two results
disagree, re-run the *old* one before inventing a story that explains the
difference; "it changed since yesterday" is the explanation that fits everything
and predicts nothing.

---

## 21. Blaming a commit for a break whose cause was not a commit

**What happened.** `omniroute-smoke` was green at `49fd3bd` and red at
`f6d0ec9`, so I wrote "red since `f6d0ec9`" into two documents. That sentence
reads as a cause, and I meant it as one.

**Why it is wrong.** The build downloads a native binary from a third party's
GitHub releases at build time, resolving the version *then* rather than from a
pin. The timeline:

```
49fd3bd            2026-08-31 17:08 UTC   last green
tls-client v1.16.0 2026-09-02 15:06 UTC   upstream drops the old asset names
f6d0ec9            2026-09-04 04:34 UTC   first red
```

The break entered between the two runs, from outside the repository. And
`f6d0ec9` touches `agent-sidecar/` and `docker-compose.yml` — none of which are
inputs to `omniroute/Dockerfile`'s npm install. It could not have caused this
even in principle.

**The shape of the error.** A bisect answers "which commit did it first show up
at", and I read the answer to "what changed". Those coincide only when commits
are the sole input, which is exactly what a build that fetches an unpinned
artifact at build time is not. There were no CI runs for three days — because
`stax-smoke` did not run on push to main, entry 14 — so the green-to-red edge
had three days of external history folded into it.

**What it cost.** Not much here, because the log named the real cause on the
next line. But the recorded sentence would have sent the next reader to
`git revert f6d0ec9`, and reverting an innocent commit does not fix the build —
it just loses the work and appears to confirm that the revert was needed when
the build stays red.

**Rule.** Before attributing a break to a commit, ask what else could have
changed between the last pass and the first failure — the clock, an upstream
release, a rate limit, a rotated key. If the build fetches anything unpinned,
commits are not the only input and a bisect cannot answer the question you are
asking. And write "first observed at", not "since", unless you have shown the
commit is capable of causing it.

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
4. **Attributing a change to the variable that was being watched** — the
   destination "moved overnight" when it moved with the prompt, the build broke
   "at a commit" when it broke at an upstream release. Both times the real
   variable was one nobody was holding still, and both times the story that fit
   the two observations was available before the cheap control that killed it.

The standing rule that comes out of all three, and the one most worth keeping:
**anything that cannot be measured is treated as a failure, not a pass.**


---

## Not ours — recorded so it is not diagnosed a second time

`omniroute-smoke` is red, and since 2026-09-05 so are the three `stax-smoke`
jobs that build the gateway image. Nothing in this repo causes it, and — see
entry 21 — no commit in this repo causes it either.

`tls-client-node@0.2.0` downloads a native binary from `bogdanfinn/tls-client`
releases at image-build time. It resolves the version then, not from a pin, and
constructs the filename from a naming scheme upstream has since abandoned:

```
v1.15.1  2026-06-08   tls-client-linux-ubuntu-amd64-1.15.1.so   <- both schemes
                      tls-client-xgo-1.15.1-linux-amd64.so
v1.16.0  2026-09-02   tls-client-xgo-1.16.0-linux-amd64.so      <- xgo only
```

v1.15.1 published both names, so the package worked. v1.16.0 dropped the
`ubuntu` and `alpine` names, the package kept asking for
`tls-client-linux-ubuntu-amd64-1.16.0.so`, the download is skipped, and the
deliberate guard at `omniroute/Dockerfile:111` exits 1. That guard is behaving
correctly: the alternative is shipping an image whose TLS client is absent.

**The underlying defect is that the build is not reproducible.** Nothing here
pins the binary, so the same commit builds green one day and red the next
because a third party published a release. Even once `tls-client-node` fixes
the name, the next rename breaks it again — a fix upstream restores the build,
it does not make it deterministic.

Three checks close the obvious escape routes:

- **Not rate limiting.** A GitHub token changes nothing; the asset is genuinely
  named something else. Confirmed against the release API on 2026-09-05: v1.16.0
  lists exactly one linux-amd64 asset, and it is the `xgo` name.
- **Nothing to upgrade to.** `0.2.0` is the `latest` dist-tag and the newest
  release in omniroute's `^0.2.0` range. (npm also carries a `1.0.4` published
  2026-04-19, before `0.2.0` — outside the range, and not a fix to reach for.)
- **A lever exists, it cannot be reached from outside, and it is not free.**
  This is the one worth stating precisely, because "nothing to inject" was
  recorded here first and it is wrong. Reading the published postinstall of
  `tls-client-node@0.2.0`:

  ```js
  const requestedVersion = process.env.TLS_CLIENT_VERSION || process.env.TLS_CLIENT_API_VERSION;
  const metadata = await fetchJson(
      requestedVersion ? `${base}/tags/v${normalizeVersion(requestedVersion)}` : `${base}/latest`);
  ```

  With no variable set it resolves `/releases/latest` — which is why a third
  party's release broke a build nothing here had touched.

  `TLS_CLIENT_VERSION=1.15.1` would pin it to a release that still publishes
  `tls-client-linux-ubuntu-amd64-1.15.1.so`, and the build would pass. **But
  1.15.1 is not a clean answer.** Upstream's own attempt at this, OmniRoute PR
  #12612, pinned to *1.16.0* precisely to get off 1.15.1's Go runtime, citing
  CVE-2025-68121. So the two candidates trade against each other:

  ```
  1.15.1   has the asset name the package builds   carries CVE-2025-68121
  1.16.0   fixes the CVE                           has no linux-ubuntu asset
  ```

  There is no version of `tls-client` that both satisfies
  `tls-client-node@0.2.0`'s linux/x64 naming and is free of that CVE. That bind
  is why OmniRoute #12747 — the same failure, reported against Docker — is still
  open, and why #12612 was closed without merging.

  **Check the severity yourself; the PR's number is wrong.** #12612 describes
  CVE-2025-68121 as "Trivy CRITICAL, CVSS 9.8 … out-of-bounds slice read in
  net/http". The GitHub advisory (GHSA-h355-32pf-p2xm) records it as **medium,
  CVSS 4.8**, `AV:N/AC:H/PR:N/UI:N/S:U/C:L/I:L/A:N`, and describes something
  else entirely: during `crypto/tls` session resumption, a `Config` whose
  `ClientCAs`/`RootCAs` were mutated between handshakes may resume a session it
  should have rejected. Attack complexity high, confidentiality and integrity
  impact low. Real, worth fixing, not an emergency — and not what the PR says.

  Either way it cannot be done from outside. The failing `RUN` is at
  `omniroute/Dockerfile:111`, and every `ARG` in that file is declared at 135,
  140, 152 and 169 — all *after* it. A `--build-arg` has nothing to bind to, and
  `env_file:` is runtime, not build time. #12612's diff confirms the shape:
  it inserts `ARG TLS_CLIENT_VERSION` / `ENV` immediately above that `RUN`,
  inside a squashed subtree the next `git subtree pull` silently reverts.

  Do **not** reach for `TLS_CLIENT_SKIP_DOWNLOAD=1`. It makes the postinstall
  return early with an empty `bin/`, so the guard on the next line fails anyway
  — and if the guard were ever removed it would ship exactly the image the guard
  exists to prevent.

  And do not synthesise a patched Dockerfile in the CI step. It would turn the
  jobs green while testing an image the deployment does not build, which is the
  first pattern in this document.

The real fix belongs upstream — `tls-client-node` should construct the asset
name from the scheme the release actually uses. Until then, it clears when that
package publishes a fix or when an omniroute release carrying one arrives via
`git subtree pull`. **Neither has happened:** v3.8.50 (2026-08-26) is still the
newest upstream release, and #12747 is open. Those jobs stay red, and that is
the correct state.

**What still gets tested.** `omniroute-smoke` is the workflow whose job is this
build, so it stays red and should. `stax-smoke` no longer does: as of
2026-09-05 its gateway-dependent jobs pull the published image for the version
`omniroute/package.json` vendors, pinned by index digest, because they exist to
test our compose graph, Caddy's routes, Activepieces' reach and the sidecar
against a live `/v1` — none of which depends on the image being built here.
`agent-sidecar-unit` needs no gateway at all and was green throughout.

The split is load-bearing and must not be tidied into one path. If both
workflows pulled, nothing would exercise `omniroute/Dockerfile` and
`omniroute-smoke` would go green while the build stayed broken — the first
pattern in this document, applied to the very break it was documenting.

Restoring that coverage paid for itself inside one run. With a gateway
reachable, the sidecar's suite ran against a live `/v1` for the first time in
weeks, and the end-to-end step failed on
`AGENT_SIDECAR_AUTH_TOKEN is not configured; /run is refusing all requests`.
The wrapper had required a bearer for weeks while CI posted without one. It was
invisible because the job died at the build long before reaching that step —
a second fault hiding behind the first, which is the usual arrangement.
