# Activepieces flow sources, mirrored

Activepieces is the source of truth. These files are **mirrors**, kept so the
logic is diffable, reviewable, and recoverable — none of which it was before
2026-09-07, when `gateway_monitor`'s severity rules existed in exactly one
place, behind a web UI, with no history.

That mattered the same day. The monitor had been ranking any `401` as CRITICAL
on the reasoning that a rejected credential never self-heals. The reasoning was
right and the test for it was not: `opencode` answers
`[401]: Model hy3-free is not supported` — a model-catalogue problem wearing an
auth status code — and four of those rows are what made the 2026-09-06 04:56
alert CRITICAL for a window in which no client request failed at all. A rule
worth that much scrutiny should be reviewable in a diff.

## What is here

| File | Flow | Step |
|---|---|---|
| `gateway_monitor.step_1.js` | `gateway_monitor` | `step_1` — *Assess gateway health* |

## What is deliberately NOT here

**The step's `input` block.** It holds the monitor's bearer token and the
webhook HMAC secret. Every `.env` in this repo is gitignored for the same
reason, and a mirror is not a reason to make an exception.

**The trigger and the `gateway_alerts` flow.** The trigger is a bare 15-minute
cron with nothing worth reviewing, and `gateway_alerts` is four piece steps
rather than code — a diff of its JSON would be noise. Add them here the moment
either grows logic worth arguing about.

## Keeping them in sync

Nothing enforces this, which is the honest state of it. A mirror that has
silently drifted is worse than no mirror, because it invites you to review code
that is not running — the same failure shape as an instrument wired to the wrong
question, catalogued repeatedly in `docs/king-mistakes.md`.

So: **edit Activepieces, then paste the result here in the same commit.** To
read the live version back out:

```
ap_list_flows(name: "gateway")      -> the flowId
ap_read_step_code(flowId, "step_1") -> { code, packageJson, input }
```

Look the id up rather than pasting it here. `scripts/monitor-deadman.sh` already
carries the monitor's flow id as its `MONITOR_FLOW_ID` default, and one
authoritative copy is better than two that can disagree. The `gateway_alerts`
webhook id is deliberately in neither: it is the URL an unauthenticated POST
would target, and HMAC verification is a reason not to worry about it, not a
reason to publish it.

Copy only the `code` field. `ap_read_step_code` also returns `input`, which
carries the secrets above.
