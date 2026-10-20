import { execFile } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

if (process.platform !== "darwin") {
  console.log("Native macOS tests skipped on this platform.");
} else {
  const root = fileURLToPath(new URL("..", import.meta.url));
  const directory = await mkdtemp(join(tmpdir(), "pi-overview-native-test-"));
  const run = promisify(execFile);
  try {
    const model = join(root, "native", "Model.swift");
    const menus = join(root, "native", "ContributionMenus.swift");
    const views = join(root, "native", "MenuViews.swift");
    const composer = join(root, "native", "AgentComposer.swift");
    await run("/usr/bin/swiftc", ["-swift-version", "5", "-framework", "Cocoa", model, views, composer, menus, join(root, "native", "main.swift"), "-o", join(directory, "pi-overview")], { timeout: 120000 });
    const tests = join(directory, "native-tests");
    await run("/usr/bin/swiftc", ["-swift-version", "5", model, join(root, "test", "NativeTests.swift"), "-o", tests], { timeout: 120000 });
    const result = await run(tests, [], { timeout: 10000 });
    process.stdout.write(result.stdout);
    const menuTests = join(directory, "native-menu-tests");
    await run("/usr/bin/swiftc", ["-swift-version", "5", "-framework", "Cocoa", model, views, composer, menus, join(root, "test", "NativeMenuTests.swift"), "-o", menuTests], { timeout: 120000 });
    const menuResult = await run(menuTests, [], { timeout: 10000 });
    process.stdout.write(menuResult.stdout);
    console.log("Native Cocoa companion compiled successfully (GUI not launched by tests).");
  } catch (error) {
    console.error(error.stderr || error.message);
    process.exitCode = 1;
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
