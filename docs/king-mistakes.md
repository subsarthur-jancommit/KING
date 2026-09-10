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
