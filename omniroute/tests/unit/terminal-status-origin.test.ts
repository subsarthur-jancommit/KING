import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs"; import os from "node:os"; import path from "node:path";

const DIR = fs.mkdtempSync(path.join(os.tmpdir(), "omniroute-t11-"));
process.env.DATA_DIR = DIR;
const core = await import("../../src/lib/db/core.ts");
const { createProviderConnection } = await import("../../src/lib/db/providers.ts");
const { runAsProbe } = await import("../../src/shared/utils/probeOrigin.ts");
const { writeTerminalStatus } = await import("../../src/shared/utils/terminalStatus.ts");

test.after(() => { core.resetDbInstance(); fs.rmSync(DIR, {recursive:true, force:true}); });

function row(id: string){ return (core.getDbInstance() as unknown as Record<string, unknown>).prepare("SELECT is_active, test_status FROM provider_connections WHERE id=?").get(id); }

test("probe-origin writeTerminalStatus records error but never deactivates", async () => {
  const conn = await createProviderConnection({ provider:"openai", authType:"apikey", name:"t11", apiKey:"sk-t11", isActive:true, testStatus:"active" } as unknown as Record<string, unknown>);
  const id = String((conn as unknown as Record<string, unknown>).id);
  await runAsProbe(async () => {
    await writeTerminalStatus(id, { testStatus:"banned", isActive:false, lastError:"probe 403", errorCode:"403", lastErrorType:"FORBIDDEN" }, "probe");
  });
  const r = row(id);
  assert.equal(r.is_active, 1); // probe n'a jamais désactivé
  assert.equal(r.test_status, "active"); // terminal non posé
});

test("production writeTerminalStatus deactivates on terminal", async () => {
  const conn = await createProviderConnection({ provider:"openai", authType:"apikey", name:"t11b", apiKey:"sk-t11b", isActive:true, testStatus:"active" } as unknown as Record<string, unknown>);
  const id = String((conn as unknown as Record<string, unknown>).id);
  await writeTerminalStatus(id, { testStatus:"banned", isActive:false, lastError:"real 403", errorCode:"403", lastErrorType:"FORBIDDEN" }, "production");
  const r = row(id);
  assert.equal(r.is_active, 0);
  assert.equal(r.test_status, "banned");
});
