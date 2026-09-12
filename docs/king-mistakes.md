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

**And once more, on 2026-09-06, in a fix rather than a test.** The smoke test
was failing on a free model's malformed output, so I filtered out the parse
error I had seen. The next CI run went green and I read that as the fix working.
It was not: smolagents has *two* code-parsing messages, from two modules, and I
had matched one. The run after that failed on the other. Green meant the model
had happened to format correctly, exactly as `big-pickle` answering a
`big-pickle`-restricted key had meant nothing.

Two greps of the installed package listed both messages and no others. The
filter matches their shared substring now, and both forms are pinned by tests —
one of which was checked against the old filter first, to confirm it would have
failed.

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

## 22. A test harness that substitutes stored data, and a failure that looked like a bug

**What happened.** Wiring the `gateway_alerts` table step, I tested it with
`ap_test_step` and got a row with every column `null`. The piece's own
documentation warns that "any value whose key does not match a real column is
silently dropped", so the reading was obvious: the field keys are wrong.

They were not. `ap_test_step` does not re-run prior CODE steps — it references
their stored sample output, and `step_1` had none. Every
`{{step_1['output'].x}}` resolved to nothing. The step was correct the whole
time.

**What separated the two.** One literal value. Replacing a single column's
template with the constant `LITERAL-PROBE` and re-running produced a row with
`event: "LITERAL-PROBE"` and the rest still null — which proves the key mapping
works and moves the fault to the reference. `ap_test_flow`, which actually
executes every step, then wrote the correct row on the first try.

**Why it nearly cost more than it did.** The obvious next move was to rewrite
the step to use the piece's raw `records` form, keyed by column *name* instead
of externalId. That would have "fixed" nothing, produced the same nulls, and
made the real cause harder to see — a rewrite that changes the wrong variable
leaves you with two unknowns instead of one.

**Rule.** When a check fails and a documented failure mode explains it, that is
a hypothesis, not a diagnosis — a plausible story available in advance is
exactly what entries 20 and 21 are about. Before changing anything, find the
cheapest observation that separates the candidates. A single constant in one
field cost one call and ruled out half the possibilities; the rewrite would have
cost more and ruled out nothing.

And know what your harness actually executes. "Test this step" and "run the
flow" are different operations, and only one of them proves the thing you are
about to publish.

---

## 23. Asserting that a mechanism does not exist, without looking for it

**What happened.** Having measured that `gemini-3.7-flash-high` fails 21% of
attempts, I wrote that the sidecar's exposure is the worst case because it
"names a model directly, so there is no ladder underneath it to absorb a
failure". I committed that, and built an open-items row on top of it.

There are two ladders.

The gateway falls back inside the model family: on an empty-content response
`chatCore.ts` logs `FAILED 502` and immediately calls `getNextFamilyFallback`,
trying the next family member before answering. And the OpenAI SDK retries —
`client.max_retries` is 2 on the live container and `_should_retry` returns true
for every status `>= 500`.

The evidence was already in front of me. The alert I had just read lists its
three samples as `gemini-3.7-flash-high`, `-medium`, `-low` — I described that
as three failures when it is one request walking down a family. And I had
written, in the same commit, that eight sidecar runs succeeding against a 21%
model was "equally consistent with an invisible retry". It was. I logged the
alternative and then wrote the conclusion as though I had not.

**The shape of the error.** "There is no X" is a claim about everything, and it
cannot be reached by not having seen X. Two greps of a source tree I already had
checked out settled it. The measurement was fine; the sentence I hung off it was
a guess wearing a measurement's clothes.

**What it would have cost.** The next step from that conclusion is to add a
retry layer to the sidecar — real work, shipping a third redundant mechanism on
top of two that already work, and a plausible way to turn one 502 into nine
upstream calls.

**Rule.** An absence claim needs a search, and the search is usually cheap —
read the dependency, grep the vendored source, inspect the live object. Say
"I did not find a fallback in X" rather than "there is no fallback", unless you
went and looked. And when you have already written down a competing explanation
for your own evidence, resolve it before publishing the conclusion; a hypothesis
you have named and then ignored is worse than one you never thought of.

---

## 24. Changing a credential without asking what reads it

**What happened.** On 2026-09-04 I reset the OmniRoute admin password, verified
I could log in, and moved on. On 2026-09-06, installing an unrelated timer, the
first thing it ran printed `Login ke http://localhost:20128 gagal`.

Four scripts authenticate to the gateway — `pool-register.sh`,
`combo-paid-first.sh`, `local-router.sh`, `localmodel-register.sh` — and all
four read `INITIAL_PASSWORD` from `omniroute/.env`. That is a bootstrap value:
OmniRoute seeds the stored hash from it on first boot and never consults it
again. Every one of them had been broken for two days.

```
login with the 2026-09-04 password         -> HTTP 200
login with omniroute/.env INITIAL_PASSWORD -> HTTP 401
```

**Why nothing caught it.** The variable was still present and still non-empty,
so every check that looked at it passed. Only its *truth* had expired, and
nothing here made a real login. `verify-credentials.sh` — a script written
specifically because "a revoked key does not announce itself" — checked five
credentials and not this one, the only one that had actually changed.

**Two separate faults, and the second is the interesting one.** The first is
that scripts read a bootstrap variable as a live credential; that is fixed with
`OMNIROUTE_ADMIN_PASSWORD`, with `INITIAL_PASSWORD` kept as the fallback because
it is correct wherever the password has never been changed, which is CI. The
second is that I performed the rotation and verified only the thing I had just
touched. "I can log in" was true and told me nothing about the four consumers.

**Rule.** Changing a credential is a change to every consumer of it, and the
consumers are findable — one grep for the variable name. Verify from the far
side: not "the new value works" but "everything that used the old value still
works". A rotation is not done when the new credential is accepted; it is done
when nothing is still holding the old one. This is on the list for the real
rotation ahead, which touches a dozen more keys than this did.

---

## 25. Opt-in isolation, and a test suite pointed at production

**What happened.** To get faster feedback than CI, I ran `pytest tests/` inside
the deployed sidecar container. It passed. It also wrote **105 test entries**
into `/audit/runs.jsonl`, the production run journal — 87 of the 137 lines it
then held. Tasks named `t` and `do the thing`, `RuntimeError: boom` in the
degraded list, and every number `agent-report.sh` reported computed over them.

**Why it was invisible.** Journal writes are best-effort by design: an
unwritable path must not fail a run. So nothing errored, nothing warned, and
the suite reported 180 passed. I only saw it because I had just added a report
section and read its output — `RuntimeError: boom` in a production report is
hard to misread, and without that I would not have looked.

**The design fault underneath.** Several tests already redirected
`AGENT_SIDECAR_RUN_JOURNAL` to a `tmp_path`. That looks like the problem being
handled and is actually the problem in miniature: **opt-in isolation isolates
only the cases somebody thought of.** Every other test in the suite wrote to
the default `/audit/...`, which is a real, mounted, shared volume in the one
environment where the code actually runs. The protection was strongest exactly
where it was least needed — in CI, where those paths do not exist — and absent
where it mattered.

**The fix, and its shape.** A session-scoped `autouse` conftest fixture
redirects both audit paths before any test runs. `autouse` is the point: a
fixture you have to request is one that will be forgotten, and forgetting it is
silent. Verified with a before-and-after count on the real file — 32 lines, run
the suite, 32 lines — rather than by rereading the fixture.

**Rule.** Before running a suite anywhere other than CI, ask what it writes to
that is not a temporary directory. A test that touches a real path is a test
that will eventually be run against a real deployment. And when isolation is
opt-in, treat it as absent: the question is not whether the tests you are
looking at are isolated, it is whether the ones you are not looking at can be.

**Corollary.** Cleaning up needs the same evidence as the fix. The synthetic
entries were removable only because they were separable — 100 tasks named `t`,
5 named `do the thing`, and 3 genuine runs sharing the window — so the filter
required both a timestamp inside the pytest window and one of those two exact
strings, and the file was copied first. Had the fixtures used realistic task
text, there would have been no honest way to tell them apart, and the journal
would have been permanently untrustworthy.

---

## 26. A boundary taken from memory, and a probe pointed at the wrong hop

**What happened.** Two failures in one investigation, in opposite directions.

The day after raising `RATE_LIMIT_MAX_WAIT_MS`, I re-read the call log to check
the fix had held, splitting it into "before" and "after" at **09:00 UTC** —
roughly when I remembered doing the work. The split said the failure rate had
gone from 15% to **24%**: the fix had made things worse. That was alarming
enough that I nearly published a correction to a document and an artifact I had
written hours earlier.

The gateway had actually restarted at **14:06:07 UTC**, five hours later —
`docker inspect omniroute --format '{{.State.StartedAt}}'`, one command. With
the real boundary the same rows say the opposite:

```
guessed 09:00   before 15% -> after 24%     "the fix made it worse"
actual  14:06   before 44% -> after 23%     rate-limit 504s: 27 -> 0
```

Nothing about the data changed. The five-hour error had put most of the *broken*
period into the "after" bucket.

**Then a second error, in the same investigation, not caught until later.** The
failures remaining after the fix carried `Direct response did not start within
30000ms`. Reading the source found `OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS` —
default 30 s, read from `process.env`, therefore settable with no subtree edit.
The same shape as the win the day before.

I probed it: send a novel 2,050-token prompt through the gateway and time
headers separately from body, since the bound measures time-to-headers.

```
headers after  83.2s      status 200
```

I read that as proof the bound never fired — 83 seconds is far past 30, and the
call succeeded — and wrote "the bound is not applied on the path ollama takes"
into a document and a published artifact.

The probe measured the wrong hop. `OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS` bounds
the **gateway-to-provider** connection. I had timed **client-to-gateway**, which
is the sum of everything the gateway does internally and cannot show a bound
firing inside it. Grouping the same request by `correlationId` showed it plainly:

```
504  dur=60111ms  in=0      <- the bound firing, twice, zero tokens processed
200  dur=28102ms  in=2050   <- the attempt that answered
                               60.1 + 28.1 = 88s ~= the 90.6s I had measured
```

The number I collected was real, and it was consistent with both stories. I only
checked that it was consistent with mine.

**The shape of both errors.** A comparison is only as good as its boundary, and
a boundary from memory is not a measurement — it is the one input to a
before/after study that nobody thinks to verify, because it feels like
bookkeeping rather than data.

The second is worse, because it wore the costume of the fix. I did run a probe.
It returned a real number. But a measurement only tests a claim if it is taken
at the layer the claim is about, and an end-to-end timing cannot observe a bound
*inside* the thing being timed — both stories predict 83 seconds. Asking "what
else would produce this same number?" costs one sentence and would have caught
it; instead the number that agreed with me ended the investigation. Entry 19's
control passed by coincidence too, and this is the same failure wearing
better clothes.

**What to do instead.** Take the boundary from the system, not from recall —
container start time, file mtime, deploy log. And when a probe appears to settle
a question, name the layer it was taken at and check that the claim lives at the
same layer. Here `correlationId` grouping was the right instrument all along and
was already in the data.

The lever is still not raised, but the reasoning that survives is different from
the reasoning that was published: it is global, its benefit is latency on a path
nothing waits on, and its cost is slower dead-socket detection for every
provider.

---

## 27. Fixing a prompt from one observation, and making it worse

**What happened.** The local secret scanner's first real run produced one false
positive: it called `ACTIVEPIECES_PUBLIC_DOMAIN` a secret. The cause looked
obvious — the few-shot prompt had no example of a hostname — so I added one:

```
Line: PUBLIC_DOMAIN=app.example.com
Answer: SAFE
```

Re-running the same eight lines, the model now answered **SECRET to all eight**,
including a bare `http://` URL. One observation, one edit, strictly worse. The
only reason I know is that I re-ran it; the change reads like an improvement and
would have shipped as one.

**What was actually wrong.** Scoring three variants against twelve labelled
lines afterwards:

```
a  10/12   the original: 2 SAFE examples, 1 SECRET
b   9/12   the "fix": 3 SAFE, 1 SECRET
c  11/12   balanced: 2 SAFE, 2 SECRET   <- now the default
```

The tell is *which* lines a and b got wrong: `PORT=` and `LOG_LEVEL=` — examples
sitting inside their own prompts. A 1.5B model given a majority-SAFE prompt
drifts toward answering with the majority label, and adding a third SAFE example
made that worse rather than teaching it about hostnames. The missing hostname was
never the problem. The remedy was balance, which the original diagnosis did not
even consider.

**The shape of the error.** A single failing case suggests a cause, and the
suggestion is persuasive precisely because it explains that case perfectly. It
does not explain the cases that were already passing, and nothing checked
whether they still did. This is `docs/king-mistakes.md` entry 8's *"improving a
prompt without a score"* met one step earlier — not shipped, but only because
the re-run happened to be cheap.

**What to do instead.** A prompt change is a measurement or it is a hunch. The
scanner now carries `--eval`: twelve labelled lines, all synthetic, temperature
0, and the variants kept side by side so the default is the one that scored
best rather than the one written last. It cost about ten minutes to build and it
caught the regression on its first use.

---

## The pattern underneath most of these

Seven shapes account for nearly every entry:

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
5. **A conclusion that outruns its evidence by one sentence** — the measurement
   is sound, and then a claim about mechanism, absence, or cause is appended to
   it that no measurement was made for. Entries 20, 21 and 23 are all this, and
   in each the check that would have caught it cost one command.
6. **An input to the measurement that was never itself measured** — the boundary
   of a before/after split taken from memory, the fix time recalled rather than
   read off the container. Entry 26 inverted a conclusion on this alone, and the
   correcting command was `docker inspect`.
7. **A cause that explains the failing case and nothing else** — the one false
   positive suggested a missing example, and the fix made every other case
   worse. A diagnosis drawn from a single failure is untested against the
   successes it must not break. Entry 27, caught only by re-running.

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

### Resolved 2026-09-07 — and not by any of the three routes listed above

Re-checked from the release API on 2026-09-10, because a build that was
supposed to fail at `omniroute/Dockerfile:111` walked straight past it:

```
ASET                                      DIUNGGAH               UNDUHAN
tls-client-xgo-1.16.0-linux-amd64.so      2026-09-02T15:05:19Z    1 473
tls-client-linux-ubuntu-amd64-1.16.0.so   2026-09-07T22:42:23Z   16 087
tls-client-linux-alpine-amd64-1.16.0.so   2026-09-07T22:42:25Z        3
```

v1.16.0 shipped on 2026-09-02 with the `xgo` names only — the analysis above was
correct on the day it was written. On **2026-09-07T22:42Z**, five days later,
upstream re-uploaded the legacy `ubuntu`/`alpine`/`arm64` names into the same
release. `tls-client-node@0.2.0` asks for exactly the first of those, so the
break ended without a single line changing in this repo or in that package.
The 16 087 downloads against `xgo`'s 1 473 are the size of the population that
was blocked for those five days.

**The lesson is not "it fixed itself". It is that the entry above enumerated
how it could clear and treated the list as complete.** It named two routes —
`tls-client-node` publishes a fix, or an omniroute release carrying one arrives
via `git subtree pull` — and concluded *"Neither has happened … Those jobs stay
red, and that is the correct state."* It cleared by a third route the list did
not contain: the third party un-did its own rename. A release's asset list is
mutable, and nothing in the earlier reasoning treated it as such.

That is the same shape as the rest of this document. The sentence was not
wrong about the facts; it was wrong to be *final* about a fact it had sampled
once. Both the enumeration and its conclusion were carried forward for five
days without being re-read against the system they describe, and the check that
quoted them, `J-2`, would have gone on excusing a red workflow indefinitely.
`J-2` now queries the release API for the asset name before it accepts the
excuse, and reports **FAIL** — not UNKNOWN — when the workflow is red and the
asset is present, because at that point whatever is red is something else.
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

## 28. Reporting a limit instead of trying, three times in one instrument

`king-audit.sh` carried two checks that reported `UNKNOWN` with the words
*"needs root"*. D-4 could not read `dmesg`; D-5 could not read the container
log files. Both had said so for a day, and the previous session's summary
recorded them as an honest limitation of running as `subsa`.

The same script was already calling `sudo -n` two dimensions away, for
`iptables` and `sshd_config`. Passwordless sudo works on this host. With it,
both checks answer immediately: zero OOM kills, nine megabytes of container
logs.

**"I cannot read this" and "I did not try the way I try elsewhere" are
different claims, and only one of them was true.** The first is a finding. The
second is a gap wearing a finding's clothes, and it is more dangerous than a
plain failure because it closes the question. Nobody re-opens a limitation.

Three variants of the same move appeared in a single sitting once the habit was
being looked for:

**Cost.** Recorded as unmeasurable after `/api/usage/costs`, `/api/usage/tokens`
and `/api/stats` all returned 404. Three guesses at a path is not an
enumeration. `/api/usage/call-logs` answers 200 and carries a `tokens` object on
every row. The endpoint was never the problem; the guessing was. What the
endpoint reports is a real finding — 146 of 500 calls carry token counts, and
the paid providers report zeroes — but it took asking properly to find it.

**Queue state.** Listed as an unaudited aspect under the name "Upstash Redis".
Grepping the tree for `upstash` returns nothing. Both instances are local
containers, and a `sed` of two files had produced *"no redis url found"*, which
was recorded as the answer. A note about state that names the wrong system is
worse than no note: it makes the gap look surveyed.

**`|| true` inventory.** G-6 counted eighty silenced failures and reported
`UNKNOWN`, *"each needs a human"*. The distinction that separates a harmless
`|| true` from a dangerous `|| echo 0` was already written down in this
document. It is mechanical. Classifying it took twenty lines and found four
sites in `king-audit.sh` itself, three of them real.

### The instrument's own failures during the fix

Worth recording separately, because they are the same shape one layer up.

`D-7` was added to check that container logs are bounded. Its first version
passed when *one service out of eleven* set `max-size` — the same "partial
accounting reads as a total" error it sits four lines away from calling out in
E-8. It now asks the containers, not the compose file.

`F-8` read a tool-list cache that no part of the script could produce, with no
freshness rule; the copy on the host was a day old, so a guarantee about
today's `NEVER_REGISTER` was being derived from yesterday's surface. Making it
fetch its own fixed the staleness and *silently narrowed the surface from 120
tools to 110*, because the gateway endpoint does not carry codegraph's ten.
The check reported PASS throughout. Trading a stale-but-complete input for a
fresh-but-partial one is not an improvement, and the union now refuses to be
partial.

`L-6` passed on a coincidence twice. It grepped `docs/` for "retention" and
matched `CALL_LOG_RETENTION_DAYS` and `AP_EXECUTION_DATA_RETENTION_DAYS` — two
real settings, for two other stores. Tightened to require the same *file* to
contain both `runs.jsonl` and a retention word, it matched this document, where
the word is "rotated key" four hundred lines from any mention of the journal.
File-level co-occurrence cannot establish that a sentence is about a subject.

`D-6` printed the reclaimable-cache figure and passed unconditionally. A check
with no failing branch is a log line wearing a green badge — exactly what G-1
exists to catch in other people's guards.

`D-2` greps `docker ps` for "unhealthy". A container that declares **no**
healthcheck never produces that word, so the grep is silent and D-2 read that
silence as health. `king-caddy-1`, the only container binding `0.0.0.0` and the
single public entrypoint, has no healthcheck at all. D-2 had been passing over
it since it was written: the failure the dimension is named for, committed by
the check named after it.

### What to do about it

Before writing `UNKNOWN`, ask what the rest of this script does when it needs
the same thing. If any other check reaches further — a different privilege, a
different endpoint, a different parse — the honest report is not "unknown", it
is "not attempted", and the fix is to attempt it.

## 29. "Reloaded configuration" is not the same as "applied your configuration"

`/etc/docker/daemon.json` did not exist, so every container ran on the
json-file driver's default: no size cap, no rotation. The fix is four lines of
JSON, and `docker.service` declares `ExecReload=/bin/kill -s HUP $MAINPID` —
so a reload looked like the way to apply it without stopping anything.

It reported success at every layer:

```
sudo systemctl reload docker     # exit 0
systemctl is-active docker       # active
docker ps -q | wc -l             # 10, nothing restarted
```

The journal agreed: `Got signal to reload configuration`, then
`Reloaded configuration`. Nothing anywhere said no.

**`log-opts` is not in the set dockerd reloads on SIGHUP.** The proof is in
the daemon's own log line, which prints back the configuration it accepted:

```
"log-driver":"json-file", ... "mtu":1500, ...
```

`log-driver` is there. `log-opts` is not in that object at all. The daemon took
the half it reloads and dropped the half it does not, and called the whole
thing reloaded.

The empirical test settled it in one container: after the successful reload, a
deliberately chatty container wrote **58.6 MB into a single log file** under a
policy that says 10 MB. Had that test not been run, this would have been
reported as fixed, and the next audit would have read the file, seen the
policy, and agreed.

### The shape

This is the same fault as `king-audit.sh` F-8 reading `mcp_tools.py` from the
working tree while the container ran a different copy, and A-8 trusting
BuildKit's `.Created` — all three are **a check that asks the artefact instead
of the system**. A config file says what someone wanted. Only the running
daemon says what is true, and it will tell you if asked precisely: here, by
comparing its own start time against the file's mtime, which is what D-7 now
does rather than passing on the file's existence.

The fix needs `systemctl restart docker`, which stops every container. That is
a different decision from writing a file, and it is left to the operator rather
than folded into a batch — but D-7 fails loudly until it happens, instead of
passing on a policy nothing is enforcing.

## 30. "If the build fails, nothing breaks" — the build was not the risk

The gateway ran a CVE-affected `tls-client` binary. The fix is a rebuild, and
the risk assessment written into the plan was:

> Kalau OOM, tidak ada yang rusak — image lama tetap berjalan.

Every clause of that is true. It is also the wrong risk. The build was started
to a separate tag, the running `omniroute:base` was never touched, and when the
build died nothing was corrupted — exactly as predicted.

**The site was down for forty-five minutes anyway.**

`OMNIROUTE_BUILD_MEMORY_MB` is 4096. The host has 2 vCPU and reported 4633 MB
available with ten containers running. A Next.js production build took both
cores and pushed the host into swap; Caddy — capped at 0.5 CPU and 192 MB by
the very rule this audit had just applied — stopped answering. So did every
other container. So did **sshd**, which meant the build could not be stopped by
the person who started it. Recovery took a console reboot by the operator.

### What the assessment actually missed

It reasoned about the **artefact** and not the **host**. "Does the build
produce a broken image" and "can this host survive the build" are different
questions, and only the first was asked. The same shape as every instrument
fault catalogued this week — F-8 asking a file instead of a process, D-7
asking a config instead of a daemon — arriving one level up, in the risk
analysis rather than in a check.

`scripts/codegraph-refresh.sh` had the answer written down the whole time. It
unloads Ollama, then re-reads MemAvailable **immediately before** building, and
refuses below a measured floor. It ran three times during the same session
without incident, including once while the public surface was watched
throughout. The omniroute build had none of that, and nobody noticed the
asymmetry because the codegraph one had never failed.

### What would have made it survivable

- **Measure the floor for THIS build**, as codegraph-refresh does for its own,
  and refuse below it rather than hoping 4633 > 4096 leaves enough for ten
  containers.
- **Stop what can be stopped first.** Ollama alone is 1.5 GB and a full CPU.
- **Watch the thing that matters during the operation**, not after. The public
  surface was checked once the build had already been running for fifteen
  minutes, from outside the host — which was the only channel left.
- **Never start an unbounded operation you cannot stop.** SSH going down was
  the fault that turned a slow build into an outage, and it was foreseeable
  from the CPU budget alone.

### The two things it proved by accident

`king-firewall.service` is `PartOf=docker.service`, and a real reboot re-applied
its rules with no intervention. That design was argued for on paper an hour
earlier; the reboot tested it for real.

And the reboot restarted dockerd, which **applied** the `log-opts` that
`systemctl reload` had silently dropped — closing D-7, which had been deferred
precisely because it needed a daemon restart nobody wanted to schedule.

Neither is a defence of what happened. A fix that arrives through an outage is
not a fix that was delivered.

---

## 31. Five builds and an outage to replace a binary nothing had ever loaded

The gateway carried `tls-client-linux-ubuntu-amd64-1.15.1.so` with
CVE-2025-68121 in it. The plan said rebuild. So I rebuilt: one unbounded
attempt that took the host down for 45 minutes (entry 30), then four bounded
ones, all of which failed on memory.

Only after the fifth failure did I ask the question that should have been
first: **does anything load it?**

```
provider_connections    ->  agy, ollama-local, openrouter, tavily-search
/proc/1/maps            ->  no tls-client .so mapped, 3h into the process
find /app -name '*.so'  ->  exactly one copy, never opened
```

`omniroute/Dockerfile:101` names the five providers that pull that library in —
chatgpt-web, claude-web, grok-web, lmarena, perplexity-web — and not one of
them is configured. The vulnerable code does not execute in this deployment.
The advisory is medium, CVSS 4.8, attack complexity HIGH.

**Reachability is not a detail you confirm after choosing the fix. It is what
tells you which fix is proportionate.** Had I measured it first:

- the 45-minute outage would not have been risked for it,
- the four bounded attempts would have been scheduled for a maintenance
  window rather than run against a live host,
- and the patch layer I prepared — COPY the verified 1.16.0 `.so` in, delete
  1.15.1 — would have been recognised for what it is: a change to a production
  image, carrying real recreate risk, buying nothing against code that never
  runs.

The severity number was already checked carefully — entry in the "not ours"
section above catches PR #12612 calling a 4.8 flaw "CVSS 9.8". So the *rating*
was verified against the advisory and the *reachability* was never measured at
all. Half the risk assessment was done rigorously and the half that would have
changed the decision was assumed. A CVSS score describes the vulnerability; it
does not describe your deployment.

The same shape as everything else here. `daemon.json` was correct and not
loaded. `ufw` was active and did not cover Docker. This binary was vulnerable
and not reachable. Three times the artefact was read and the system was not.

What it left behind: `J-4` compares the digest in the running container against
`scripts/tls-client-pin.txt` and is red on purpose, because the deployment is
not running what is recorded. `J-5` asserts the condition that makes that red
tolerable, and goes red itself the moment one of those five providers is
configured. "Safe because nothing uses it" is a condition, and an unwatched
condition is what every entry in this document turns out to be.

---

## 32. The manifest guarded one direction, and I broke it from the other

The manifest at the top of `king-audit.sh` exists because the first version of
that script shipped 43 of the 62 checks its own plan defined and reported the
result as "the audit". Its comment is unambiguous: *"an unimplemented check is
invisible, and invisible is indistinguishable from passing."*

It compares `MANIFEST` against `implemented()`. A check that is **declared and
never runs** is a TODO, counted, and it stops the run going green.

Nothing compared the other way. On 2026-09-10 I added three checks — `D-7b`,
`J-4`, `J-5` — and registered none of them:

```
D-7b  implemented()=0  MANIFEST=0
J-4   implemented()=0  MANIFEST=0
J-5   implemented()=0  MANIFEST=0
```

They ran. They printed verdicts. One of them was red and I quoted it in a
commit message. And the same run printed **"every planned check in the selected
dimension(s) ran"**, which was true, because they were not planned. The file
that is supposed to be the single list of what this audit does had quietly
stopped being that list, and every signal on screen said the audit was healthy.

That is the identical failure the manifest was written to remove, arriving from
the side it did not guard. A guard tests a predicate, not a subject: "declared
implies runs" and "runs implies declared" are two claims, and enforcing the
first tells you nothing about the second.

**How it was found, which is the part worth keeping.** Not by noticing. By
being told not to trust my own account of what I had covered, and answering the
question with a script instead:

```sh
grep -oE 'chk [A-L]-[0-9]+[a-z]?' scripts/king-audit.sh | awk '{print $2}' | sort -u
awk '/^implemented\(\)/,/^IMPL$/' scripts/king-audit.sh | grep -cx "$id"
```

The first of those was *also* wrong — it misses `chk "E-3"` and the five checks
emitted through a loop variable, which the manifest's own comment already
records as a trap someone fell into before. So the enumeration had to be
checked before its answer could be used. An inventory you take by hand is a
claim; an inventory you take with a script is a measurement, and a script you
have not validated is back to being a claim.

**Closed at runtime, not by grep**, for exactly that reason: `chk()` already
records every id it emits, so the check compares what actually ran against the
manifest and exits 3 — the same exit a TODO gets — on anything undeclared.
Proven in both directions on the host: dimension I exits 0 normally, and exits
3 printing `UNDEC … I-2` when that entry is removed.

---

## 33. I undid C-7 with the backup I took to make C-7 safe to fix

Before recreating the gateway I copied its data directory somewhere safe first,
which is the right instinct and was done with the wrong command:

```
-rw-r--r-- 1 root root 11319182 Sep 10 16:09 /tmp/omniroute-data-prerecreate.tgz
  data/server.env
  data/storage.sqlite
```

`644`. World-readable, on a host with three shell accounts, containing the
encryption key and all seven provider API keys — for about twenty minutes.

Earlier the same day I had set `omniroute/data` to `700` **because** those files
were readable by uid 1001 and 1002, and wrote a check to keep it that way. Then
I copied the entire contents past that boundary with a default umask. The
control was still in force on the directory it names, and the data was outside
it.

`scripts/king-backup.sh` does not have this bug: it `chmod 700`s the destination
and `chmod 600`s every file it writes, deliberately. I did not use it. **A
safety step improvised around the tool that already implements it is not a
safety step** — the tool encodes the requirements you are about to forget, and
the reason it exists is that somebody already forgot them once.

Deleted with `shred -u` rather than `rm`, and recorded here rather than quietly
cleaned up, because a twenty-minute exposure that nobody writes down is
indistinguishable from one that never happened — which is the same reasoning
that put `GRAPHIFY_API_KEY` in `docs/king-rotation.md` when I printed it to a
transcript.

---

## 34. Six attempts at one wall that I rebuilt each time

The gateway rebuild OOMed at every cage size I tried. The kernel recorded why,
and I did not read the two records side by side until the sixth:

```
cage 3584 MB -> next-build killed at anon-rss 3.11 GB   (87% of the cage)
cage 4608 MB -> next-build killed at anon-rss 3.99 GB   (87% of the cage)
```

Raising the cage 29% raised its appetite 28%. **Turbopack sizes itself to the
limit it finds and then exceeds it**, so those were not six tries at one wall.
They were six walls, each built where I had just moved it, and every
"try a bigger cage" — including the one my own script printed as advice — was
wrong before it was typed.

`omniroute/Dockerfile:131` says this outright: `OMNIROUTE_BUILD_MEMORY_MB` caps
only the V8 heap, and turbopack compiles in native Rust memory outside it. I
read that three times across two days and treated it as a caveat about tuning.
It is not a caveat. **A bound the bounded thing gets to choose is not a bound**,
and the sentence saying so was in the file the whole time.

What broke the loop was not a new idea. It was putting two kernel logs next to
each other and dividing.

### The same day, in the script written to prevent this

```sh
if docker buildx build ... 2>&1 | tail -20 | sed 's/^/  /'; then
```

A pipeline's exit status is its last command's. That tested `sed`. A failed
build read as a success, fell through to the verification step, found no image,
and told the operator:

> the TLS binary is not the one on record — Rebuilding is not the fix if this
> differs.

Every word wrong, and confidently so. The real cause — a transient npm network
error — was in the part `tail -20` had thrown away.

The identical bug was in `king-rotate.sh`, guarding something worse:

```sh
if ./scripts/verify-credentials.sh 2>&1 | sed 's/^/    /'; then
```

That is the check that decides whether a credential rotation is recorded as
verified. It would have recorded every rotation as verified, whatever the
verification said. **The safety net was decorative**, and it was written in the
same afternoon as the rule it was meant to enforce.

Both were found by running the scripts, not by reading them. `shellcheck` does
not flag this shape, the code reads correctly in English, and the failure is
invisible until the guarded thing actually fails — which is the one moment
nobody is watching closely.

---

## 35. Four ways to report a cutover that did not happen

Closing the CVE needed one container replaced. It took four runs, and each
failure had already been dressed as a success by the time I read it.

**Run 1 — the wrong service name.**

```
== 5. Cut over
  gateway before: HTTP 200
    no such service: omniroute
  gateway healthy after 0s
```

`omniroute` is the container_name; `omniroute-base` is the service. The compose
call failed, and the health loop then passed in *zero seconds* — because the
old gateway was still up and answering. **Health was never evidence of a
cutover.** It was evidence that something was serving, which had been true all
along. The script printed "done".

**Run 2 — the rollback that could not roll back.** Run 1 had already retagged
`omniroute:base` to the patched image before failing. Step 4 tagged the
rollback point *from that tag*, so the rollback would have restored the thing
being rolled back from. A rollback point must come from what the running
container actually uses, not from a mutable tag that something else already
moved.

**Run 3 — `--force-recreate` cannot work here.** The service pins
`container_name: omniroute`, and force-recreate builds the replacement before
discarding the original, so the fixed name collides. The error names the
container, which sent me looking at container_name — and that was the wrong
lead, because:

**Run 4 — I was driving the wrong project all along.**

```
No stopped containers
Conflict. The container name "/omniroute" is already in use
```

The container carries `com.docker.compose.project=king` and
`config_files=/home/subsa/KING/docker-compose.yml`. I was passing
`-f omniroute/docker-compose.yml`, so Compose derived the project name from
*that file's directory*: `omniroute`. Every command ran against an empty
project. `stop` found nothing, `rm` said "No stopped containers", and `up` then
tried to create a container whose name project `king` still owned. Three runs
of symptoms from one wrong flag.

### What actually failed

Not the typo, and not the flag. **The verification was measuring the wrong
thing, and it was measuring the wrong thing in the direction that produces a
pass.** "The gateway answers 200" is true before a cutover and after a failed
one. The property that matters is that the container was *replaced* — capture
the id first, require a different one after — and then that the running
container holds the expected binary, as an assertion rather than a printout.

The one check that did work was the one that asked the running container rather
than the image. It is the only reason run 1 was caught at all, and even then it
printed the answer and carried on instead of failing.

Both are now assertions. And the rollback hint the script printed was
hand-written compose that named the container instead of the service — so the
single command someone would copy while panicking was the one that could not
work. It prints `--rollback <tag>` now, which is tested code.

---

## 36. I found the trigger, wrote it down as the cause, and moved on

Activepieces lost its database on 2026-09-11: Neon refused every connection
with *"Your project has exceeded the data transfer quota."* I traced it to my
own `--rebuild` retries — step 0 took a full restore point each time, six of
them in ninety minutes, ~515 MB of dumps. I fixed that, wrote entry 34's
companion commit, and considered it explained.

It was not explained. It was **attributed**.

The new project had been live for about an hour when its backup came out at
**83 MB**. An hour-old database with six flows and one user does not hold
83 MB. Measuring it:

```
197 MB  piece_metadata      12,216 rows
136 kB  project
104 kB  migrations
 96 kB  flow_run
        total database: 210 MB
```

`piece_metadata` is Activepieces' cache of every integration in its registry.
**94% of the database, and every single `pg_dump` pulled all of it, every day,
across a metered link.** ~2.5 GB a month before anyone runs anything unusual.

So the six retries were the trigger. The cause was a daily backup of a cache,
and it had been running since the backup script was written. The retries did
not create the waste; they made a standing one arrive faster.

**Regenerable was provable and I did not think to prove it until now.** The
move to a fresh project started from zero tables, nothing restored that table,
and Activepieces had refilled all 12,216 rows within the hour — the strongest
possible evidence, produced by an accident and sitting unread.

`--exclude-table-data=piece_metadata`: **83 MB → 220 KB**, a 99.7% cut, schema
retained so a restore still creates the table and the application refills it.

### The habit this is about

The script's header already had a section called **WHAT IS DELIBERATELY NOT**,
excluding `king_ollama-models` (941 MB, `ollama pull` reproduces it) and
`king_codegraph-out` (87 MB, rebuilt from the repo). The reasoning was correct
and the list was written carefully. `piece_metadata` belongs in it and was
missed for one reason: **it is a table inside a database, and the question had
been asked about volumes.**

The category that catches most things has an edge, and the thing sitting just
past the edge is invisible precisely because the category is doing its job
everywhere else.

And when the outage came, an explanation that fit — my own retries, freshly
committed, with numbers — arrived before the harder question did. A cause you
can name and fix in one sitting is the most comfortable place to stop looking,
which is exactly why it should not be.

## 37. Three probes in one hour, each one agreeing with itself

**1. A credential read that truncated at a space.** Checking whether the
tracing pipeline was alive, I sourced the environment file in `sh`:

```sh
set -a; . ./.env; set +a
curl -H "Authorization: $LANGFUSE_OTLP_AUTH" ...   # 401
```

`.env` holds `LANGFUSE_OTLP_AUTH=Basic <base64>`. Sourcing that in a shell
stops at the space: the variable becomes the five-character string `Basic`,
which Langfuse correctly refuses. I had a 401 and a plausible story — the
collector has been shipping spans to a backend that rejects them, silently,
for who knows how long — and the story was about my own probe.

What stopped it was asking the shape of the value before trusting the verdict:
length 5, no `Basic ` prefix, no colon after base64 decoding. Five characters
is not a credential. Read from the running container instead, the same request
returned 200 and 1,984 traces.

Compose reads that file verbatim and was never wrong about it. Only `sh` was.

**2. Counting carriage returns with a pattern that matched every line.**

```sh
grep -c $'\r' scripts/king-audit.sh   # 4708
wc -l         scripts/king-audit.sh   # 4708
```

Those two numbers being equal is the whole story: `$'\r'` did not expand, the
pattern was empty, and an empty pattern matches everything. I was one command
away from concluding the file had CRLF endings throughout and "fixing" a file
that was already correct.

**3. Counting them again with a pattern that matched the letter `r`.**

```sh
od -c file | grep -o '\r' | wc -l    # 8391
```

`'\r'` reaches grep as `\r`, which in a basic regular expression is an escaped
`r` — a literal `r`. 8,391 is how many times the letter r appears in the file.

Only on the third attempt did I write the control first: a two-line fixture
containing exactly one CR, and a second containing none.

```sh
n() { tr -dc '\r' < "$1" | wc -c; }
n with_one_cr   # 1
n with_none     # 0
n the_real_file # 0
```

`tr -dc` has no escaping ambiguity and the fixture has a known answer, so the
zero means something. The file was clean all along, in the working copy, in the
index, and in `HEAD`.

**The pattern.** Every one of these produced a confident number. Two of them
produced a number that could only ever have been that number, regardless of the
file. A measurement with no known-answer case beside it is a guess wearing a
number, and I ran three of them before writing one down.

This is entry 17 and entry 19 again, in a single afternoon, which is the reason
to record it rather than a reason not to: the failure is not exotic and it does
not announce itself. It looks exactly like a result.

## 38. A flag the parser accepted and nothing implemented

`king-audit.sh` documents five modes in its usage block. One of them:

```
#   ./scripts/king-audit.sh --positive-control
```

and the parser honours it:

```sh
--positive-control) MODE="poscontrol" ;;
```

`MODE` is read in exactly one place in 4,700 lines — `[ "$MODE" = "selftest" ]`.
Nothing has ever read `poscontrol`. Typing the flag ran an ordinary full audit
and exited 0, and the exit code was honest about the audit while saying nothing
about the mode.

I proved it by behaviour rather than by reading, because reading is how it
survived:

```
--positive-control -d I   →  1 pass, 2 fail, 0 unknown, 1 skipped
-d I                      →  1 pass, 2 fail, 0 unknown, 1 skipped
```

Byte-identical.

**Where it was sitting matters.** This audit was built to find controls that
are written down and do not apply — `daemon.json` the daemon never loaded, a
`ufw` that did not cover Docker, a `restart: on-failure` that a clean shutdown
walks straight past. The same fault was in its own argument parser the entire
time, advertised in its own `--help`.

It now asks each live instrument to demonstrate a **miss** against the real
system — the graph must fail to find a label that cannot exist, the trace query
must return zero for a window in 2099 — and modifies nothing: no file mode, no
firewall rule, no container. Live perturbations are real positive controls too,
but they belong in a hand-run procedure with its rollback written beside it,
not behind a flag someone might type on a production host.

It also prints how many checks carry no canary at all. Two greens and a stop
would read as *the instruments are proven* when two of them are.

**And it caught an omission in the same change.** E-9 passed live while the
coverage line reported `TODO E-9`, because `implemented()` is a hand-kept list
and I had added the check without adding the id. The fix that mattered was not
adding the id. It was asserting the general direction in `--self-test`: every
implemented check must be declared in the manifest. The hand-kept list is
precisely the thing that went stale, so a hand-kept list of exceptions to it
would have gone stale next.

## 39. Three ways to print a secret while asking whether one exists

Three credentials reached a transcript in one session. Not one of the three
commands was asking for a credential.

| What I wanted to know | What I ran | What it printed |
|---|---|---|
| which variables are set | a listing with a `sed` to mask values | `GRAPHIFY_API_KEY`, because the `sed` matched nothing |
| how the restored flows were exposed as MCP tools | `SELECT *` on `mcp_server` | the `token` column, which is one of the columns |
| whether `ap-redis` requires a password | `CONFIG GET requirepass` | the password |

The third is the clearest, because the question was a **yes/no** and the answer
came back as the secret itself. Redis has no "is a password set" command; the
getter is the only door, and it hands you the value. The intent of the question
had no bearing on what landed in the log.

**A question about a credential is not a request for one, and no tool knows the
difference.** Every one of these had a predicate available that answers without
printing:

```sh
redis-cli CONFIG GET requirepass | tail -1 | wc -c   # is one set: a number
redis-cli PING                                       # unauthenticated: fails if set
psql -c "SELECT token IS NOT NULL FROM mcp_server"    # a boolean, not a column
env | sed -n 's/^\([A-Z_]*\)=.*/\1/p'                 # names only, by construction
```

The last one matters most: it is safe *by construction* rather than by a
redaction step that has to work. A mask that fails still prints; a query that
never selects the column cannot. **Prefer the predicate that cannot return the
secret over the command whose output you intend to filter** — the filter is
another thing that can be wrong, and in the first of these three it was.

All three are recorded in `docs/king-rotation.md`. The habit this should have
built after the first one took three.

## 40. Two checks whose categories did not match the world's

### A 502 is not an open door

The audit ran a minute after `codegraph-refresh.sh` recreated
`codegraph-serve`. Caddy answered 502 while the upstream came back, and the
security check said:

```
FAIL  C-5  data endpoint(s) answered without a token
           /king-codegraph/mcp=502
```

Nothing had answered. `B-8` made the same claim about the same 502.

Both were written with **two buckets** — the acceptable status codes, and
everything else — for a world that has **three** states: locked, open, and not
there. The third fell into the bucket labelled *open*.

This is the worst shape a check can take, and it is worth being precise about
why rather than calling it a false positive:

- it is wrong about the single thing it is most trusted on;
- it is red for a cause that recurs on **every** restart, so it is not rare;
- and those two together train the reader to scroll past the one check that
  would matter if it were ever right.

One shared predicate now answers with three values. A 5xx or a connection
failure is `unreachable`: the lock could not be tested, which by this script's
own header is UNKNOWN and never a pass.

**And the fix nearly introduced something worse.** Rewriting C-5's branches I
put the unreachable case ahead of the open one and left a placeholder behind
it:

```sh
elif [ -n "$_open" ]; then
    :   # handled below
elif [ -n "$_c5down" ]; then
    ...
```

The open-door finding was now silently dropped — the check could no longer
report the thing it exists for. `sh -n` was perfectly happy; it is valid shell.
It was caught by re-reading the resulting structure, which is the only thing
that would have caught it. Branch ORDER is a claim about priority, and it needs
stating: an open door outranks an unreachable one, whatever else was down at
the same moment.

### A check stricter than the rule it enforces

`E-4` compared the graph's commit to `origin/main` for equality. `CLAUDE.md`
says, in as many words: *"It can be stale by up to a day, which is normal;
weeks behind is not."*

So the check went red on every commit and stayed red until the 03:12 timer, and
**three consecutive baselines recorded a red for no fault at all**. A check that
is red during normal operation is indistinguishable from one that is broken,
and gets treated the same way.

The obvious relaxation — allow it if `built_at` is under a day — would have
revived the exact bug the check's own comment describes from 2026-09-08:
BUILD_INFO said today while the commit was eighteen behind, because graphify
had built from a stale checkout. An age test passes that with full marks.

Neither equality nor age was the question. The question is:

> **Did the refresh index the newest commit that existed when it ran?**

`git rev-list -1 --before="$built_at" origin/main` answers it exactly, and three
different failures fall out cleanly instead of one:

| what happened | old verdict | now |
|---|---|---|
| commits landed after the refresh | FAIL | PASS, with the count as a metric |
| the refresh ran and indexed something older | FAIL, same words | FAIL, naming the stale checkout |
| the refresh has not run at all | FAIL, same words | FAIL, naming the schedule |

**The pattern under both.** Neither check was measuring the wrong thing. Each
was measuring the right thing into the wrong set of boxes, and a box that does
not exist has to send its contents somewhere — into `open` for C-5, into
`stale` for E-4. Ask how many outcomes the world actually has before deciding
how many the check reports.

## 41. The fixtures I invented did not contain the string production has

The credential scanner was too narrow — measured, not guessed: against the
seven shapes on the rotation list, `L-3`'s pattern caught **one**. The newest
OpenAI format, `sk-proj-…`, was invisible to it, because the hyphen after
`proj` breaks `sk-[A-Za-z0-9]{20,}`. So the key style most likely to be in use
was the one style it could not see.

Widening it was straightforward, and I did it carefully: twenty fixtures, both
directions, eleven shapes that must be caught and nine benign lines that must
not — sha256 digests, commit hashes, correlation ids, token counts, prose about
a password. All twenty green.

Its first run against real logs produced **175 findings, every one of them
false**. All 175 were `apiKeyId":"0554…` in the gateway's own output: an API
key *identifier*, not a key. The keyword `apiKey` followed by a wildcard
`[A-Za-z_]*` had swallowed the `Id`.

Nothing in my nine benign fixtures looked like that, because I wrote them from
imagination. I thought about what a *credential* looks like and what a *hash*
looks like, and never about what an *identifier with a credential-shaped name*
looks like — which is a thing this gateway logs on every single request.

**A fixture set written from imagination tests the shapes you already thought
of.** That is worth something, but it is not coverage. The twenty cases proved
the pattern did what I intended; only production could say whether what I
intended was right. The fix took one live run, and the two `apiKeyId` shapes
are now fixtures — taken verbatim from the logs that raised the false alarm,
which is the only way they would ever have got there.

There is a second lesson folded into the first. A scanner that reports 175
non-events every run stops being read, and this deployment has already lost one
alerting rule that way — the only CRITICAL it has ever emitted described an
event no user experienced. **Widening a detector is not free**: precision
bought at the cost of noise spends the same credibility the detector exists to
protect.

And the diagnosis itself had a trap worth naming. Finding out *which* strings
matched meant looking at 175 lines of log that the check had just declared
credential-shaped. Printing them to find out whether they were credentials
would have made them credentials in a transcript — entry 39, for the fourth
time in one day. What answered it instead: a count per pattern alternative,
then a count per keyword, then the matched substrings with everything after the
first four characters replaced. Three questions, no values.

## 42. Four inventories written by hand, all of them right on the day they were written

In one afternoon, four checks turned out to be measuring a population someone
had typed out rather than one the system could be asked for. None of them was
wrong when it was written. All four had quietly stopped being right.

| Check | The population it claimed | What it actually looked at |
|---|---|---|
| `G-1` — guards that pass their own self-test | every guard with a `--self-test` | three script names; **five** carry the flag, and `king-backup.sh`'s had never once been run by it |
| `J-1` — pinned versions vs latest | "pinned third-party image(s)", plural | one hardcoded image; **five** are pinned, and three of the four it ignored were behind |
| `G-2` — every report produces the section it claims | reports | two of the **three** `*-report.sh` scripts; the unexamined one reads the agent journal |
| `A-9` — installed artefacts vs their repo copy | artefacts outside the repo | two paths, correct today, and structurally unable to notice a third |

The shape is identical each time, and it is not carelessness. A list written by
hand is a **measurement of the moment it was written**. It stays green by
construction, because the thing it is missing is, by definition, not in it.
Nothing makes it wrong out loud. `G-1` had been reporting "every guard with a
self-test passes it" while two guards with self-tests were never invoked — the
sentence was false and the check had no way to discover that.

The fix in every case was the same, and it is cheap: **let the filesystem or
the registry decide the population**, and keep the hand-written part only for
what genuinely cannot be derived.

- `G-1`: `for _g in scripts/*.sh`, filtered on the flag being present.
- `J-1`: every `image:` in the compose file, with the ones it cannot reach
  counted and named.
- `G-2`: `scripts/*-report.sh` decides who is asked; the *headline* each must
  print stays declared, because that cannot be guessed from a filename — and a
  report with no declared headline is now named in an UNKNOWN rather than
  silently absent.
- `A-9`: `ls king-*` on the host, which upgrades the question from "do the two
  I know about still match?" to "is anything installed that the repo does not
  account for?"

Two second-order lessons came out of it.

**Deriving the population sometimes finds a better question.** `A-9` compared
pairs; deriving the list made "installed with no repo copy at all" expressible,
and that is the more serious finding — a file nobody can read in a diff cannot
drift from the repo, it is already adrift.

**A derived population needs its own honesty about coverage.** `J-1` cannot
reach ghcr.io anonymously and `G-2` cannot invent a headline, so both now print
what they could not cover. Replacing a hand-kept list with a glob that silently
drops what it cannot handle just moves the same lie one level down.

The sweep that found the last one is worth keeping: `grep -nE '^\s*for _[a-z]+
in .*(scripts/|\.sh|\.txt)' | grep -v '\*'` — loops over literal paths, in a
script whose whole job is to enumerate. It returns nothing now.

## 43. The canary broke the thing it was measuring, and then blamed it

Three checks in this audit carry a canary, and the reasoning behind them is
sound enough that it has its own entry: **an instrument that cannot say no
cannot be believed when it says yes.** `E-5` asks the code graph for a label
that cannot exist. `E-9` asks Langfuse for a window in the year 2099. `L-3`
pushes a line built to match through the same grep before believing a zero.

So when `F-6b` needed to prove that a 404 from the gateway meant something, the
pattern was obvious: ask for a model that cannot exist first.

It worked, in the sense that the impossible model was refused. It also did
this:

```
Asking qwen2.5:1.5b-instruct-q4_K_M through the gateway …
{"error":{"message":"[ollama/qwen2.5:1.5b-instruct-q4_K_M] [404]:
 model 'king-audit-canary-no-such-model-9f3a1' not found (reset after 1m)"}}
```

Read the two names in that one message. The **request** was for the real model.
The **error** is the canary's. The canary had tripped the gateway's per-provider
failure tracking, `ollama-local` went into a one-minute backoff, and the next
real request inherited the cached failure.

So the instrument broke its subject, and then reported the breakage as the
subject's fault. If I had not recognised the canary's own name in that error, I
would have concluded the registration had failed and gone looking for a bug that
was not there.

**The distinction the other three canaries hide.** E-5 reads a graph, E-9 reads
a trace store, L-3 greps a file — all of them *read*. `F-6b`'s canary was an
inference request, and an inference request is not a read. It is an attempt that
can fail, and a gateway that tracks failures is doing its job when it records
one. The pattern was never "ask for something impossible"; it was "ask a
question that cannot change the answer."

`F-6b` now reads the **catalogue**. `/v1/models` is free, has no side effect,
and still discriminates: an impossible name must be ABSENT from it, or the list
is not a list. Only after that does one real request go out, and only ever for
the model actually configured.

And the split improved the diagnosis, which is the part worth keeping. "Not in
the catalogue" means the gateway was never told. "In the catalogue but not
answering" means the catalogue and the connection disagree. The version that
sent a doomed request reported both as 404, which is how the original fault hid
for as long as it did.

**This repo had the shape written down already.** `docs/king-system.md` records
that a failed round two on `agy` triggers a cooldown affecting other traffic.
The same mechanism, on a different provider, reached by a check built to be
careful. Knowing that a system has failure-tracking is not the same as
remembering it while writing the thing that will trip it.

---

## 44. A dependency check that asked whether the name resolved, not whether it ran

Found 2026-09-12, in code I had written minutes earlier, by running it.

The rewritten `local-router.sh` guards its Python block:

    command -v python3 >/dev/null 2>&1 || { red "python3 is required."; exit 1; }

On the Windows machine this session runs from, `command -v python3` succeeds. It
resolves to `…/WindowsApps/python3`, a Microsoft Store stub that prints an advert
about installing Python and exits **49**. So the guard passed, the heredoc was
fed to a program that is not an interpreter, and the script exited 49 having
printed nothing at all. Not an error message, not a wrong answer — silence and a
number nobody would recognise.

**The whole point of `--self-test` is to run with no network and no Docker**, so
it can be run anywhere. The first place I ran it was the one place the guard was
wrong, which is luck, not method.

**The same mistake this file is mostly about.** `command -v` asks the artefact —
does this NAME resolve on PATH. What was needed was the system question: does
this interpreter RUN. They differ exactly when something occupies the name
without doing the job, which is not an exotic case; it is the default on Windows
and it is every broken symlink, every shim, every wrapper that needs a licence
server. The fix is a line shorter to read and strictly stronger:

    if ! python3 -c "" >/dev/null 2>&1; then
      red "python3 is required, and the python3 on PATH here does not run."
      exit 1
    fi

**And then I made the twin of it in the same hour.** Checking whether the VPS
had `shellcheck`:

    command -v shellcheck >/dev/null && shellcheck /tmp/lr.sh; echo "rc=$?"

`command -v` failed, `&&` short-circuited, `shellcheck` never ran, and `$?` was
the *failed lookup's* status — `rc=1`. I had asked "did the linter pass" and been
handed "the linter is missing", wearing the same clothes as a real lint failure.
One character of luck away from reading it as a clean run. `if …; then … else
echo "NO shellcheck"; fi` said it plainly. This is entry 5's exit-status trap
again, and knowing it is written down four entries above did not stop me.

The linter is now installed on the VPS, so `shellcheck scripts/*.sh` — the exact
command CI runs, no flags — can be answered before a push instead of after one.

---

## 45. The gateway advertised three models that could not exist, and that was upstream's design

Found 2026-09-12, while closing the plan item that said to remove them.

The gateway lists `ollama-local/embeddinggemma`, `ollama-local/nomic-embed-text`
and `ollama-local/bge-m3`. The container holds one model, `qwen2.5:1.5b-instruct-q4_K_M`,
and has never held any of those three. Two reads settle it with no request sent:
Ollama's own tag list has one entry, the gateway's catalogue has four
`ollama-local/*` entries.

They are not a registration mistake. They are declared statically in
`omniroute/open-sse/config/embeddingRegistry.ts`, and upstream's comment states
the design plainly: Ollama exposes its own catalog, but these common embedding
models are *useful defaults for model selection and validation*. A default is
not a reading of the container, and once it is served through `/v1/models` a
caller cannot tell the difference.

**So it cannot be fixed from here**, and that is the entry. `omniroute/` is a
vendored subtree; CLAUDE.md forbids editing it because the next `git subtree
pull` reverts the edit silently, and forbids reaching for a compose override
because the root compose must not redeclare what the subtree defines. The
gateway exposes no per-model disable. Same class as the content-based reroute:
real, understood, out of reach.

**What was done instead, and why it is not the same as ignoring it.** The three
names are written down in `scripts/gateway-phantom-models.txt` with the reason
and the measurement, and `F-6c` reports any local model the gateway advertises
that the container does not hold and that is not on that list. Bounded: across
the last 1000 call-log rows, 539 mentioned ollama and **0** mentioned an
embedding model, so nothing has ever asked for one. Their `baseUrl` is
`http://localhost:11434` resolved inside the *gateway* container, where nothing
listens — so a request would fail to connect rather than reach a wrong model.

**The check is the real output here.** `F-6b` asks whether the one model named
in `.env` is registered and answers. The fault that actually happened was wider:
for six days the gateway advertised `qwen2.5:3b`, which had never been pulled,
and nothing noticed. Change `OLLAMA_MODEL`, re-register, and `F-6b` goes green
on the new name while the old one keeps being advertised — only comparing the
two POPULATIONS sees that. Both sides are derived on the spot. The
acknowledgement file is the one hand-kept list, and it is deliberately the short
side: it holds what cannot be fixed, never what is currently true.

Proven red against the live system, not only against fixtures: emptying the
acknowledgement file made `F-6c` name all three, and restoring it made it green
again.

---

## 46. Letting a report exit non-zero killed the audit at the line before the check that reads it

Found 2026-09-12, by running the red path instead of reasoning about it.

`trace-report.sh` exits 1 when it finds local work that left the host. That is
the point of it — the plan asked for one number that can go red. `G-2`, which
asks whether each report actually reports, treated any non-zero exit as "this
report is mute", so its single most valuable outcome would have been recorded as
the report failing. The louder the finding, the redder the wrong check.

So `G-2` gained a fourth field per report: the exit codes that mean the report
WORKED. `0 1` for this one, and deliberately not `2`, which is what it exits
when the backend cannot be read. G-2's question is whether a report reports,
never whether the news is good.

**That fix introduced the actual mistake.** `set -eu` is on, and

    _rout=$(timeout 300 "$_sc" "$_ar" 2>/dev/null)
    _rrc=$?

is not "run it and keep the status". Under `set -e` an assignment whose command
substitution exits non-zero is *itself* a failing command, so the shell dies on
that line and `$?` is never read. Harmless for as long as every report exited 0.
The moment one was allowed to exit 1 on a finding, the whole audit aborted — at
`G-4`, one check before `G-2`, and `G-2` simply never printed.

**A check that vanishes is worse than one that fails.** Nothing was red. The run
ended with exit 1 and a plausible-looking wall of PASS lines, and the check that
would have described the problem was not in the output at all. `sh -n` was
happy, shellcheck was happy, and the normal path — no findings, exit 0 — passed
exactly as before. Only running it with a deliberately impossible threshold,
`TRACE_MAX_ERROR_PCT=-1`, made the report exit 1 and exposed it.

The fix keeps `set -e` and does not reach for `|| true`, which would set the
status to 0 and is the exact construct `G-6` exists to find:

    if _rout=$(timeout 300 "$_sc" "$_ar" 2>/dev/null); then _rrc=0; else _rrc=$?; fi

`if` suspends `set -e` for its condition, so a non-zero status becomes data
instead of a fatality.

**The general shape, which is entry 5 wearing a new coat.** Every time exit
status has bitten this repo it has been the same error: assuming a status
belongs to the command I was thinking about. In a pipeline it belongs to the
last stage. Behind `&&` it belongs to whichever side ran. Here, under `set -e`,
there is no status to belong to anyone, because the shell is already gone.

---

## 47. Fifteen fixtures, a canary, a doctored live payload — and the check could not fire

Found 2026-09-12, by a real fault happening while the instrument watched.

`trace-report.sh` was built to catch the 2026-09-06 fault: a caller asking for
the local model and a paid provider answering. The traces looked like they held
both halves on one row:

    name  = "chat ollama/qwen2.5:1.5b-instruct-q4_K_M"   what was asked for
    model = "qwen2.5:1.5b-instruct-q4_K_M"               what served it

It passed fifteen fixtures. It had a canary — a predicate that could only ever
return "no escape" would have failed it. It was proven red against a **real**
payload of 247 rows with one row doctored. That is more verification than
anything else built this week.

Then a genuine reroute happened. An agent run asked for
`ollama/qwen2.5:1.5b-instruct-q4_K_M` and `claude-sonnet-4-6` served it,
`degraded: true`. `F-4` caught it out of the agent journal. `trace-report.sh`,
run minutes later over a window containing that very call, printed:

    local work that left the host: 0

**The span is written after the gateway has decided.** Both fields describe the
destination; neither describes the request. `gen_ai.request.model` — the
attribute whose NAME says "request" — also carries the post-reroute model. A
rerouted call arrives as a perfectly consistent
`chat antigravity/claude-sonnet-4-6` -> `claude-sonnet-4-6`. The two fields
cannot disagree for the one case the check existed to catch.

**So the canary was sound and the fixtures were fiction.** I wrote rows where
name and model disagreed, and the gateway does not emit that shape. Even the
"real payload" test was me editing a real row INTO the invented shape and
confirming the code noticed. Every one of those tests measured the predicate.
None asked whether the world can produce its input.

That is the sharpest version of this file's whole subject. A canary proves the
instrument can say no. It says nothing about whether the thing you are
measuring can ever present the case that makes it say no. Both questions have
to be asked, and only the second one requires looking at the system.

**What the traces actually support**, measured over 487 generations rather than
assumed. `gen_ai.system` takes three values: `direct` (served as addressed),
`auto` (the gateway's router chose), and `priority` (a combo ladder — the caller
naming a route). The report now counts those, because they are true, and states
plainly in its own output that it is NOT a list of diverted calls and that F-4
is the detector for that.

**And `priority` is the same lesson twice in one hour.** It does not appear in a
300-row sample; it showed up only when the window widened to 487. Fixtures
written from the first sample would have been invented again, one sample later.
The fixtures now carry the distribution the gateway emits, and the header
records the sample size so the next reader knows what they are trusting.

---

## 48. A fixture that needed the repository's history, in the one place there is none

Found 2026-09-12, nineteen hours after it broke CI, by finally looking at CI.

The C-2 fix of 2026-09-12 came with a fixture pinning the rule it restored —
that two spellings of one commit compare equal once both go through
`git rev-parse`:

    _c2a=$(git rev-parse da98876c 2>/dev/null || true)
    _c2b=$(git rev-parse da98876  2>/dev/null || true)

`da98876c` is a real commit from the day before. It passed everywhere I ran it:
this machine, and the VPS. Both have the full history.

**`actions/checkout` clones at depth 1.** That object does not exist in CI, so
both `rev-parse` calls returned nothing, the comparison of two empty strings…
was true, actually — and the `[ -n "$_c2a" ]` guard then failed it, which is the
guard working correctly. `1 self-test check(s) failed`, exit 1, red preflight.

**A fixture that depends on repository history is an integration test wearing a
fixture's clothes.** It tests the checkout, not the predicate, and it passes or
fails on where it happens to run. `HEAD` is the one commit every clone has,
shallow included, so the rule is now pinned against that.

**The part that is mine and not the fixture's.** I ran `--self-test` perhaps a
dozen times today and reported it passing every time. Every one of those runs
was on a machine with the full history — the two environments where the bug is
invisible. CI is a third environment and I did not look at it once until the
work was finished, so a red X sat on fourteen consecutive commits while I wrote
"shellcheck clean, self-test passed" under each of them.

Reproducing it took one command:

    git clone --depth 1 file://$PWD /tmp/shallow && cd /tmp/shallow \
      && ./scripts/king-audit.sh --self-test

Old version: FAIL. New version: pass. The same positive-control discipline the
checks themselves are built around, applied to the fix — and available the whole
time.

**The general rule, which this file keeps re-learning in new costumes.**
Verifying in the environment where something works is not verification. Entry 44
was `command -v` succeeding on a Windows stub. Entry 47 was fixtures built from
a row shape the gateway never emits. This is the same error in the third place:
the test environment was chosen, unconsciously, to be one where the answer was
already yes.
