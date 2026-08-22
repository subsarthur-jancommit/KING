import { describe, it } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

describe("AddApiKeyModal Enter key submit (#10995)", () => {
  it("AddApiKeyModal attaches onKeyDown Enter handler to the API Key input", () => {
    const modalPath = path.resolve(
      process.cwd(),
      "src/app/(dashboard)/dashboard/providers/[id]/components/modals/AddApiKeyModal.tsx"
    );
    const content = fs.readFileSync(modalPath, "utf8");
    assert.ok(
      content.includes("onKeyDown"),
      "AddApiKeyModal must contain onKeyDown event handler for Enter key validation"
    );
    assert.ok(
      content.includes('e.key === "Enter"'),
      "onKeyDown handler must check for Enter key press"
    );
    assert.ok(
      content.includes("handleValidate()"),
      "Enter key press must invoke handleValidate()"
    );
  });
});
