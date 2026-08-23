import assert from "node:assert/strict";
import test from "node:test";

import { OPENCODE_ZEN_GO_SHARED_MODELS } from "../../open-sse/config/opencodeZenGoSharedModels.ts";
import { opencode_zenProvider } from "../../open-sse/config/providers/registry/opencode/zen/index.ts";
import { opencode_goProvider } from "../../open-sse/config/providers/registry/opencode/go/index.ts";

test("every OPENCODE_ZEN_GO_SHARED_MODELS entry is present, unmodified, exactly once in opencode-zen", () => {
  for (const shared of OPENCODE_ZEN_GO_SHARED_MODELS) {
    const matches = opencode_zenProvider.models.filter((m) => m.id === shared.id);
    assert.equal(matches.length, 1, `${shared.id} must appear exactly once in opencode-zen`);
    assert.deepEqual(matches[0], shared, `${shared.id} must match the shared definition exactly`);
  }
});

test("every OPENCODE_ZEN_GO_SHARED_MODELS entry is present, unmodified, exactly once in opencode-go", () => {
  for (const shared of OPENCODE_ZEN_GO_SHARED_MODELS) {
    const matches = opencode_goProvider.models.filter((m) => m.id === shared.id);
    assert.equal(matches.length, 1, `${shared.id} must appear exactly once in opencode-go`);
    assert.deepEqual(matches[0], shared, `${shared.id} must match the shared definition exactly`);
  }
});

test("OPENCODE_ZEN_GO_SHARED_MODELS is frozen (no accidental cross-registry mutation)", () => {
  assert.ok(Object.isFrozen(OPENCODE_ZEN_GO_SHARED_MODELS));
});
