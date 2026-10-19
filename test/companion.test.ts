import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { buildCompanion, writeLauncher } from "../src/companion.ts";

test("cancelled builds do not start filesystem/compiler resources", async () => {
  const controller = new AbortController();
  controller.abort();
  const parent = mkdtempSync(join(tmpdir(), "pi-overview-abort-"));
  const root = join(parent, "not-created");
  try {
    await assert.rejects(buildCompanion(root, controller.signal), { name: "AbortError" });
    assert.equal(existsSync(root), false);
  } finally { rmSync(parent, { recursive: true, force: true }); }
});

test("concurrent asynchronous builds produce one cached app; launcher contains paths, not environment values", { skip: process.platform !== "darwin", timeout: 120000 }, async (t) => {
  const root = mkdtempSync(join(tmpdir(), "pi-overview-build-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const results = await Promise.allSettled([buildCompanion(root), buildCompanion(root)]);
  for (const result of results) if (result.status === "rejected") throw result.reason;
  const binaries = results.flatMap((result) => result.status === "fulfilled" ? [result.value] : []);
  assert.equal(binaries[0], binaries[1]);
  const binary = binaries[0];
  assert.ok(existsSync(binary));
  assert.match(readFileSync(join(dirname(dirname(binary)), "Info.plist"), "utf8"), /LSUIElement/);
  const modified = statSync(binary).mtimeMs;
  assert.equal(await buildCompanion(root), binary);
  assert.equal(statSync(binary).mtimeMs, modified);
  assert.equal(readdirSync(join(root, "bin")).length, 1);
  await writeLauncher(root, "/tmp/quoted 'project'");
  const launcher = JSON.parse(readFileSync(join(root, "launcher.json"), "utf8"));
  assert.deepEqual(Object.keys(launcher).sort(), ["cli", "cwd", "extensionPath", "node"]);
  assert.equal(launcher.node, process.execPath);
  assert.equal(launcher.cwd, "/tmp/quoted 'project'");
  assert.ok(existsSync(launcher.cli));
  assert.ok(existsSync(launcher.extensionPath));
});
