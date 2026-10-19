import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { DefaultResourceLoader, SettingsManager } from "@earendil-works/pi-coding-agent";

const packageRoot = fileURLToPath(new URL("..", import.meta.url));

test("Pi loads one extension even when also explicitly requested, without starting the companion at discovery", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "pi-overview-package-"));
  const oldRoot = process.env.PI_OVERVIEW_DIR;
  process.env.PI_OVERVIEW_DIR = join(directory, "overview");
  const listeners = process.listenerCount("exit");
  t.after(async () => {
    if (oldRoot === undefined) delete process.env.PI_OVERVIEW_DIR;
    else process.env.PI_OVERVIEW_DIR = oldRoot;
    await rm(directory, { recursive: true, force: true });
  });
  const loader = new DefaultResourceLoader({
    cwd: directory, agentDir: join(directory, "agent"),
    settingsManager: SettingsManager.inMemory({ packages: [packageRoot] }),
    additionalExtensionPaths: [join(packageRoot, "src", "index.ts")],
    disabledBuiltinExtensions: ["mcp"], noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  });
  await loader.reload();
  const result = loader.getExtensions();
  assert.deepEqual(result.errors, []);
  assert.equal(result.extensions.length, 1);
  assert.deepEqual([...result.extensions[0].tools.keys()], []);
  assert.deepEqual([...result.extensions[0].commands.keys()], ["overview"]);
  assert.equal(existsSync(process.env.PI_OVERVIEW_DIR), false);
  assert.equal(process.listenerCount("exit"), listeners);
});
