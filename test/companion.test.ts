import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { buildCompanion, readCompanionHeartbeat, writeLauncher } from "../src/companion.ts";

test("heartbeat reads accept live legacy/current companions and ignore stale, malformed or dead records", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "pi-overview-heartbeat-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  t.mock.method(Date, "now", () => 100000);
  assert.equal(await readCompanionHeartbeat(root), undefined);
  for (const identity of [{}, { version: "0.6.0", build: "hash", instanceId: "current", heartbeatAt: 100000.5 }]) {
    const info = { pid: process.pid, heartbeatAt: 100000, ...identity };
    writeFileSync(join(root, "daemon.json"), JSON.stringify(info));
    assert.deepEqual(await readCompanionHeartbeat(root), info);
  }
  for (const info of [null, { pid: -1, heartbeatAt: 100000 }, { pid: process.pid, heartbeatAt: 1 },
    { pid: process.pid, heartbeatAt: 200000 }, { pid: process.pid, heartbeatAt: "100000" },
    { pid: process.pid, heartbeatAt: 100000, instanceId: {} }]) {
    writeFileSync(join(root, "daemon.json"), JSON.stringify(info));
    assert.equal(await readCompanionHeartbeat(root), undefined);
  }
  writeFileSync(join(root, "daemon.json"), "invalid");
  assert.equal(await readCompanionHeartbeat(root), undefined);
});

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
  const plist = readFileSync(join(dirname(dirname(binary)), "Info.plist"), "utf8");
  assert.match(plist, /LSUIElement/);
  const version = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;
  assert.ok(plist.includes(`<key>CFBundleShortVersionString</key><string>${version}</string>`));
  assert.match(plist, /<key>PiOverviewBuild<\/key><string>[a-f0-9]{16}<\/string>/);
  const identity = JSON.parse(execFileSync(binary, ["--version"], { encoding: "utf8", timeout: 5000 }));
  assert.equal(identity.version, version);
  assert.match(identity.build, /^[a-f0-9]{16}$/);
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
