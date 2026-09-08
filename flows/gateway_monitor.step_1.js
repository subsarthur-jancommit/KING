// MIRROR of Activepieces flow `gateway_monitor`, step_1 ("Assess gateway health").
//
// Activepieces is the source of truth; this file exists to make the logic
// diffable, and — via the two `export`s below — testable by
// flows/gateway_monitor.test.mjs. Activepieces only needs `code`; the extra
// named exports are inert there and are present in the live step too, so the
// mirror stays byte-identical to it below this header.
//
// See flows/README.md, including why the step's `input` block — which carries
// the bearer token and the HMAC secret — is not mirrored.
//
// Runs every 15 minutes. Reads the gateway's own call log, decides whether the
// window is a breach, and on a breach POSTs to the `gateway_alerts` webhook,
// which writes a table row and pushes a notification via ntfy.

import crypto from 'node:crypto';

// A 401 does not always mean a credential was rejected.
//
// Added 2026-09-07. `severityFromShape` ranked any 401/403 as CRITICAL on the
// reasoning that a rejected credential never recovers on its own. That
// reasoning is right; the test for it was not. Measured on this deployment,
// `opencode` answers `[401]: Model hy3-free is not supported` — a model
// catalogue problem wearing an auth status code. Four of those rows are what
// made the 2026-09-06 04:56 alert CRITICAL, for a window in which no client
// request failed at all.
//
// One predicate, used by both the severity rule and the cap below, so the two
// cannot drift into disagreeing about what an auth failure is.
//
// It fails safe: an unrecognised or absent message is treated as a genuine
// credential failure, so only a message that positively identifies itself as a
// model-catalogue problem is excused.
export const isCredentialFailure = (r) => {
  if (r.status !== 401 && r.status !== 403) return false;
  return !/\bmodels?\b[^.]{0,60}?\b(is |are )?(not supported|unsupported|not found|unavailable|does not exist)/i
    .test(String(r.error ?? ''));
};

// Severity from the shape of the failures, in code.
//
// This was a local-model call for about a day and is not any more. Measured
// 2026-08-30: a definition-style prompt made both qwen2.5:1.5b and :3b answer
// CRITICAL to every scenario, echoing the CRITICAL definition back verbatim; a
// few-shot single-word prompt on 1.5b scored 2 of 4, and BOTH failures were
// over-escalation — the direction that turns a monitor into alert fatigue.
//
// The stronger reason is not the score. Every clause below was written by hand
// into that prompt BEFORE any model ran, and every one is a predicate over
// byProvider and sample, which this function already has. Handing an already
// decided question to a 1.5b model trades an instant deterministic answer for a
// 12-29 second one that is right half the time.
//
// The rule worth keeping: a model earns its place only where the mapping from
// input to output cannot be written down in advance. See
// docs/integrations/reliability-plan.md.
const severityFromShape = (byProvider, failures) => {
  const codes = failures.map((f) => f.status).filter((s) => typeof s === 'number');
  const text = failures.map((f) => String(f.error ?? '')).join(' ');

  // A rejected credential never recovers on its own, so it outranks everything.
  if (failures.some(isCredentialFailure)) return 'CRITICAL';

  // Nothing is working. Note this reads the ratio-eligible providers only, so a
  // single flaky provider cannot masquerade as "everything".
  const providers = Object.values(byProvider);
  if (providers.length > 0 && providers.every((v) => v.failed === v.total)) return 'CRITICAL';

  // Free tiers answer 503 all the time; CI already tolerates it explicitly.
  const transient = (c) => c === 503 || c === 429;
  if (codes.length > 0 && codes.every(transient) && !/internal|gateway error/i.test(text)) {
    return 'IGNORE';
  }

  return 'WARNING';
};

// How many CLIENT REQUESTS ended badly, as opposed to how many provider
// attempts failed.
//
// Added 2026-09-07 because the gap is not a rounding error. On an empty or
// failed response the gateway falls back to the next model in the family and
// serves that instead (chatCore.ts, EMPTY_CONTENT_FALLBACK), so one client
// request can leave three FAILED rows in the log and still return a normal
// answer. Measured over 168h on this deployment: a 15.8% attempt failure rate
// was a 2.5% caller-visible failure rate.
//
// That mattered here specifically. This monitor's own CRITICAL alert of
// 2026-09-06 04:56 reported "error ratio 56% - 15/27 calls". Replaying that
// exact window: 27 attempts, 15 failed — and 9 client requests, ZERO of which
// reached a caller as an error. The result holds for every window from 10 to 60
// minutes. The highest severity this monitor can emit described an event no
// user experienced, which is precisely how a monitor stops being read.
//
// Rows with no correlationId each count as their own single-attempt request.
// That is the conservative direction on purpose: it can only ever make impact
// look higher, so a missing field can never silently downgrade a real alert.
export const callerImpact = (rows, isFailure) => {
  const groups = new Map();
  for (const r of rows) {
    const key = r.correlationId || `_${r.id ?? Math.random()}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(r);
  }
  let reached = 0;
  let recovered = 0;
  for (const attempts of groups.values()) {
    attempts.sort((a, b) => String(a.timestamp ?? '').localeCompare(String(b.timestamp ?? '')));
    const last = attempts[attempts.length - 1];
    if (isFailure(last)) reached++;
    else if (attempts.some(isFailure)) recovered++;
  }
  return { requests: groups.size, reached, recovered };
};

export const code = async (inputs) => {
  const WINDOW_MIN = 15;
  const RATIO_THRESHOLD = 0.30;
  const MIN_CALLS = 3;

  // The local model is deliberately not counted toward the breach ratio.
  //
  // On 2026-08-30 the flow's first and only breach in its entire production
  // history was caused by testing the local model: run 3dZwOYhKLDEl6tGYNIunp,
  // 17 ollama calls, 9 of them 504, ratio 0.529. Those 504s come from
  // RATE_LIMIT_MAX_WAIT_MS (15 s default) against a cold local model that takes
  // 29 s — a known configuration limit of a self-hosted component, not a sign
  // that the gateway's provider pool is unhealthy, which is what this alert is
  // for. It still appears in byProvider below, so a genuinely broken local model
  // is visible; it just cannot fire the gateway alert on its own.
  const RATIO_EXCLUDE = new Set(['ollama', 'ollama-local']);

  const cutoff = Date.now() - WINDOW_MIN * 60 * 1000;

  const res = await fetch(inputs.logsUrl, {
    headers: { Authorization: `Bearer ${inputs.token}` },
  });
  if (!res.ok) {
    // The monitor failing to read is itself worth surfacing, and must not be
    // mistaken for a healthy window.
    return { ok: false, monitorError: `call-logs HTTP ${res.status}`, breach: false };
  }
  const payload = await res.json();
  const rows = Array.isArray(payload) ? payload : (payload.logs || payload.data || payload.items || []);

  // Rows still in flight are spliced in from memory and BYPASS the SQL filters,
  // carrying active:true and status:0. Counting them would score every
  // in-progress request as a failure.
  const done = rows.filter((r) => r && r.active !== true);

  // The route ignores since/until even though the query layer supports them,
  // so the window is applied here. Rows arrive newest-first.
  const win = done.filter((r) => {
    const t = Date.parse(r.timestamp || '');
    return Number.isFinite(t) && t >= cutoff;
  });

  const isFailure = (r) => (typeof r.status === 'number' && r.status >= 400) || !!r.error;
  const asSample = (r) => ({ model: r.model, provider: r.provider, status: r.status, error: r.error });

  // byProvider covers everything, including the excluded ones, so the alert
  // still shows what the local model is doing.
  const byProvider = {};
  for (const r of win) {
    const p = r.provider || 'unknown';
    byProvider[p] = byProvider[p] || { total: 0, failed: 0 };
    byProvider[p].total++;
    if (isFailure(r)) byProvider[p].failed++;
  }

  const rated = win.filter((r) => !RATIO_EXCLUDE.has(r.provider));
  const failed = rated.filter(isFailure);
  const total = rated.length;
  const ratio = total ? failed.length / total : 0;

  const ratedByProvider = {};
  for (const [p, v] of Object.entries(byProvider)) {
    if (!RATIO_EXCLUDE.has(p)) ratedByProvider[p] = v;
  }

  // Grouped over the SAME population the ratio is computed on, so the two
  // numbers in the alert describe one thing at two altitudes rather than two
  // different things. Local-model failures DO reach callers, but this monitor
  // deliberately does not alert on them, so they are not counted here either.
  const impact = callerImpact(rated, isFailure);

  // No traffic is not a fault. Overnight silence must stay quiet.
  const breach = total >= MIN_CALLS && ratio > RATIO_THRESHOLD;

  const sample = failed.slice(0, 3).map(asSample);
  const excluded = win.filter((r) => RATIO_EXCLUDE.has(r.provider));

  const summary = {
    ok: true,
    breach,
    windowMinutes: WINDOW_MIN,
    total,
    failed: failed.length,
    ratio: Number(ratio.toFixed(3)),
    threshold: RATIO_THRESHOLD,
    byProvider,
    callerImpact: impact,
    sample,
    excludedFromRatio: excluded.length
      ? { calls: excluded.length, failed: excluded.filter(isFailure).length, providers: [...RATIO_EXCLUDE] }
      : undefined,
  };

  if (!breach) return summary;

  let severity = severityFromShape(ratedByProvider, failed.map(asSample));

  // Nothing reached a user, so nothing here is CRITICAL.
  //
  // The cap is deliberately narrow. It never silences the alert — a window full
  // of recovered failures still means providers are degrading, and that is worth
  // seeing before it becomes user-visible — it only refuses to spend the top
  // severity on an event with no victim.
  //
  // Credential failures are exempt because they are the one class that does not
  // self-heal: a rejected key recovered by a fallback today is still a rejected
  // key tomorrow, which is the argument severityFromShape already makes for
  // ranking it first.
  const hasCredentialFailure = failed.some(isCredentialFailure);
  let severityCappedBy;
  if (severity === 'CRITICAL' && impact.reached === 0 && !hasCredentialFailure) {
    severity = 'WARNING';
    severityCappedBy = 'no client request reached a caller as an error';
  }

  // Reuse the alert path that is already proven, rather than opening a second
  // one. Same HMAC scheme the gateway_alerts trigger verifies. Nothing between
  // the breach decision and this send can fail, which is the point: the moment
  // worth alerting about is exactly the moment other things are broken.
  //
  // `reason` stays ASCII. It reaches ntfy's HTTP headers, and headers are
  // ByteStrings: an em dash here returns `status: 0` while the flow step still
  // reports SUCCEEDED. See docs/king-system.md 7.
  const body = JSON.stringify({
    event: 'monitor.error_rate',
    timestamp: new Date().toISOString(),
    data: {
      reason:
        `error ratio ${(ratio * 100).toFixed(0)}% over ${WINDOW_MIN}m` +
        ` - ${impact.reached}/${impact.requests} request(s) reached a caller` +
        (impact.recovered ? `, ${impact.recovered} recovered by fallback` : ''),
      severity,
      total,
      failed: failed.length,
      callerImpact: impact,
      byProvider,
      sample,
    },
  });
  const sig = crypto.createHmac('sha256', inputs.secret).update(body).digest('hex');

  const alert = await fetch(inputs.alertUrl, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-webhook-event': 'monitor.error_rate',
      'x-webhook-signature': `sha256=${sig}`,
    },
    body,
  });
  return { ...summary, severity, severityCappedBy, alertStatus: alert.status };
};
