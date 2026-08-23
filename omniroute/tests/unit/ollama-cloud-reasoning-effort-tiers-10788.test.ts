import { test } from "node:test";
import assert from "node:assert/strict";
import { ollama_cloudProvider } from "../../open-sse/config/providers/registry/ollama-cloud/index.ts";

// #10788: ollama-cloud declared supportsReasoning:true on several models
// (glm-5.1/5.2, deepseek-v4-pro/flash) but never declared
// supportedThinkingEfforts. appendSyncedEffortVariants() (open-sse/utils/
// syncedEffortVariants.ts) only synthesizes catalog `<model>-<tier>` ids from
// an already-populated capabilities.effort_tiers, and for static registry
// models that population only happens from a non-empty
// supportedThinkingEfforts — so these models never got a selectable
// -low/-high/-max catalog id. gpt-oss:20b/120b already declared it as the
// control case.
test("#10788: ollama-cloud reasoning-capable models declare supportedThinkingEfforts", () => {
  const byId = new Map(ollama_cloudProvider.models.map((m) => [m.id, m]));

  const control = byId.get("gpt-oss:20b");
  assert.ok(
    Array.isArray(control?.supportedThinkingEfforts) && control.supportedThinkingEfforts.length > 0,
    "control: gpt-oss:20b should already declare supportedThinkingEfforts"
  );

  const reasoningModelIds = ["glm-5.1", "glm-5.2", "deepseek-v4-pro", "deepseek-v4-flash"];
  for (const id of reasoningModelIds) {
    const model = byId.get(id);
    assert.ok(model?.supportsReasoning, `${id} should be flagged as a reasoning model`);
    assert.ok(
      Array.isArray(model?.supportedThinkingEfforts) && model.supportedThinkingEfforts.length > 0,
      `${id} supports reasoning but declares no supportedThinkingEfforts`
    );
    // Ollama Cloud's documented vocabulary (see supportsMaxEffortForProvider's
    // isOllamaCloud comment in open-sse/executors/base/reasoningEffort.ts):
    // low|medium|high|max|none — xhigh is rejected and mapped to max.
    assert.deepEqual(
      [...(model?.supportedThinkingEfforts ?? [])],
      ["low", "medium", "high", "max"],
      `${id} should declare Ollama Cloud's documented low/medium/high/max vocabulary`
    );
  }
});
