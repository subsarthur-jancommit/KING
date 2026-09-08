// Tests for the two pure decisions in gateway_monitor step_1.
//
// These drive production alert severity. Both were verified once, by hand,
// against real call-log windows on 2026-09-07 — and then that verification was
// thrown away with the scratch file it lived in. This is that verification kept.
//
// Run:  node --test flows/
//
// The fixtures below are not invented. They are the shapes actually observed on
// this deployment, including the exact 401 message that made a no-victim window
// CRITICAL, and the fallback ladder that turns three FAILED rows into one
// normal answer.

import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import { callerImpact, isCredentialFailure } from './gateway_monitor.step_1.js';

const isFailure = (r) =>
  (typeof r.status === 'number' && r.status >= 400) || !!r.error;

// --- isCredentialFailure -------------------------------------------------

test('a 401 that names a model problem is not a credential failure', () => {
  // The real message from opencode. Four of these rows are the whole of the
  // 2026-09-06 04:56 CRITICAL, for a window in which nothing reached a caller.
  assert.equal(
    isCredentialFailure({ status: 401, error: '[401]: Model hy3-free is not supported' }),
    false,
  );
  assert.equal(
    isCredentialFailure({ status: 401, error: '[401]: model gpt-9 not found' }),
    false,
  );
  assert.equal(
    isCredentialFailure({ status: 401, error: '[401]: The model is unavailable' }),
    false,
  );
});

test('a genuine rejected credential still outranks everything', () => {
  for (const error of ['[401]: Invalid API key provided', 'Unauthorized', null]) {
    assert.equal(
      isCredentialFailure({ status: 401, error }),
      true,
      `${JSON.stringify(error)} should count as a credential failure`,
    );
  }
  assert.equal(
    isCredentialFailure({ status: 403, error: 'Forbidden: key lacks scope' }),
    true,
  );
});

test('it fails safe when the message is absent or unrecognised', () => {
  // The dangerous direction is excusing a real rejected key, so anything that
  // does not positively identify itself as a catalogue problem counts.
  assert.equal(isCredentialFailure({ status: 401 }), true);
  assert.equal(isCredentialFailure({ status: 401, error: '' }), true);
  assert.equal(
    isCredentialFailure({ status: 401, error: '[401]: user model quota exceeded' }),
    true,
    'a quota problem is about the credential, not the catalogue',
  );
});

test('it only ever applies to auth status codes', () => {
  assert.equal(isCredentialFailure({ status: 402, error: 'needs credits' }), false);
  assert.equal(isCredentialFailure({ status: 500, error: 'Model is not supported' }), false);
  assert.equal(isCredentialFailure({ status: 200, error: null }), false);
});

// --- callerImpact --------------------------------------------------------

test('a recovered fallback ladder is one request, not four failures', () => {
  // Observed 2026-09-06 13:31: three empty responses, then an answer. The
  // caller saw one normal reply; the log carries three FAILED rows.
  const rows = [
    { id: 'a', correlationId: 'c1', timestamp: '...:40Z', status: 502, error: 'empty' },
    { id: 'b', correlationId: 'c1', timestamp: '...:43Z', status: 502, error: 'empty' },
    { id: 'c', correlationId: 'c1', timestamp: '...:47Z', status: 502, error: 'empty' },
    { id: 'd', correlationId: 'c1', timestamp: '...:51Z', status: 200 },
  ];
  assert.deepEqual(callerImpact(rows, isFailure), {
    requests: 1,
    reached: 0,
    recovered: 1,
  });
});

test('the last attempt decides, and it is found by timestamp not array order', () => {
  // Rows arrive newest-first from the API, so relying on array order would
  // invert the verdict on every recovered request.
  const ok = { id: 'b', correlationId: 'c1', timestamp: '2026-01-01T00:00:02Z', status: 200 };
  const bad = { id: 'a', correlationId: 'c1', timestamp: '2026-01-01T00:00:01Z', status: 502, error: 'x' };
  assert.deepEqual(callerImpact([ok, bad], isFailure), {
    requests: 1,
    reached: 0,
    recovered: 1,
  });
});

test('a request whose last attempt failed reached the caller', () => {
  const rows = [
    { id: 'a', correlationId: 'c1', timestamp: '...:08Z', status: 504, error: 'stalled' },
    { id: 'b', correlationId: 'c1', timestamp: '...:11Z', status: 504, error: 'stalled' },
  ];
  assert.deepEqual(callerImpact(rows, isFailure), {
    requests: 1,
    reached: 1,
    recovered: 0,
  });
});

test('a failure with no correlationId counts as reaching the caller', () => {
  // Conservative on purpose: a missing field must never be able to downgrade a
  // real alert, so it can only ever make impact look higher.
  const rows = [{ id: 'x1', timestamp: '...', status: 500, error: 'boom' }];
  assert.deepEqual(callerImpact(rows, isFailure), {
    requests: 1,
    reached: 1,
    recovered: 0,
  });
});

test('rows with no correlationId are never merged into one request', () => {
  // They share no key, so grouping them would invent a fallback ladder that
  // never happened — and turn two caller-visible failures into one.
  const rows = [
    { id: 'x1', timestamp: '...', status: 500, error: 'boom' },
    { id: 'x2', timestamp: '...', status: 200 },
  ];
  const got = callerImpact(rows, isFailure);
  assert.equal(got.requests, 2);
  assert.equal(got.reached, 1);
});

test('a clean window is neither reached nor recovered', () => {
  const rows = [
    { id: 'a', correlationId: 'c1', timestamp: '...:01Z', status: 200 },
    { id: 'b', correlationId: 'c2', timestamp: '...:02Z', status: 200 },
  ];
  assert.deepEqual(callerImpact(rows, isFailure), {
    requests: 2,
    reached: 0,
    recovered: 0,
  });
});

test('an empty window does not divide by zero or invent a request', () => {
  assert.deepEqual(callerImpact([], isFailure), {
    requests: 0,
    reached: 0,
    recovered: 0,
  });
});

// --- the two together, on the window that motivated all of this ----------

test('the 04:56 window is not CRITICAL once both rules are applied', () => {
  // Reconstructed from the real window: opencode 401s that are catalogue
  // problems, antigravity empties that the fallback recovered. The alert as
  // sent said CRITICAL, 56%, 15/27 calls. Nothing reached a caller.
  const rows = [
    { id: '1', correlationId: 'k1', timestamp: '...:01Z', status: 401, error: '[401]: Model hy3-free is not supported' },
    { id: '2', correlationId: 'k1', timestamp: '...:02Z', status: 200 },
    { id: '3', correlationId: 'k2', timestamp: '...:03Z', status: 502, error: 'Provider returned empty content' },
    { id: '4', correlationId: 'k2', timestamp: '...:04Z', status: 200 },
  ];
  const failures = rows.filter(isFailure);

  assert.equal(
    failures.some(isCredentialFailure),
    false,
    'no genuine credential failure here, so the CRITICAL rule must not fire',
  );
  const impact = callerImpact(rows, isFailure);
  assert.equal(impact.reached, 0, 'nothing reached a caller');
  assert.equal(impact.recovered, 2);

  // Which is the exact condition the severity cap exists for.
  const capApplies = impact.reached === 0 && !failures.some(isCredentialFailure);
  assert.equal(capApplies, true);
});
