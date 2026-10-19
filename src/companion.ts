import { createHash, randomUUID } from "node:crypto";
import { execFile, spawn } from "node:child_process";
import { closeSync, existsSync, openSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { getPackageDir } from "@earendil-works/pi-coding-agent";
import { atomicJSON, ensureDirectories } from "./state.ts";

const nativeDir = fileURLToPath(new URL("../native/", import.meta.url));
const extensionPath = fileURLToPath(new URL("./index.ts", import.meta.url));

export async function writeLauncher(root: string, cwd: string): Promise<void> {
  const packageDir = getPackageDir();
  let manifest: { bin?: string | Record<string, string> };
  try {
    manifest = JSON.parse(await readFile(join(packageDir, "package.json"), "utf8"));
  } catch {
    throw new Error("Cannot read the current Pi package manifest.");
  }
  const bin = typeof manifest.bin === "string" ? manifest.bin : manifest.bin?.pi;
  if (!bin || !existsSync(resolve(packageDir, bin))) throw new Error("Cannot find the current Pi CLI entry point.");
  atomicJSON(join(root, "launcher.json"), { node: process.execPath, cli: resolve(packageDir, bin), extensionPath, cwd });
}

export async function buildCompanion(root: string, signal?: AbortSignal): Promise<string> {
  signal?.throwIfAborted();
  ensureDirectories(root);
  const names = ["Model.swift", "ContributionMenus.swift", "main.swift"];
  const sources = await Promise.all(names.map((name) => readFile(join(nativeDir, name))));
  signal?.throwIfAborted();
  const digest = createHash("sha256").update(process.arch);
  sources.forEach((source, index) => digest.update(names[index]).update("\0").update(source));
  const hash = digest.digest("hex").slice(0, 16);
  const app = join(root, "bin", `Pi Overview-${hash}.app`);
  const executable = join(app, "Contents", "MacOS", "pi-overview");
  if (existsSync(executable)) return executable;
  const staging = join(root, "bin", `.build-${randomUUID()}.app`);
  await mkdir(join(staging, "Contents", "MacOS"), { recursive: true, mode: 0o700 });
  try {
    // Compile the exact hashed bytes even if another Pi updates the package during this build.
    await Promise.all(sources.map((source, index) => writeFile(join(staging, names[index]), source, { mode: 0o600 })));
    await writeFile(join(staging, "Contents", "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>pi-overview</string>
<key>CFBundleIdentifier</key><string>dev.pi.overview</string>
<key>CFBundleName</key><string>Pi Overview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>`, { mode: 0o600 });
    await new Promise<void>((resolveBuild, reject) => {
      execFile("/usr/bin/swiftc", ["-O", "-swift-version", "5", "-framework", "Cocoa", ...names.map((name) => join(staging, name)), "-o", join(staging, "Contents", "MacOS", "pi-overview")], { timeout: 120000, maxBuffer: 524288, signal }, (error, _stdout, stderr) => {
        if (error) {
          const failure = new Error(`Swift compilation failed. Install Xcode Command Line Tools (xcode-select --install); details: ${join(root, "build.log")}`);
          void writeFile(join(root, "build.log"), stderr || error.message, { mode: 0o600 }).then(() => reject(failure), () => reject(failure));
        } else resolveBuild();
      });
    });
    signal?.throwIfAborted();
    await Promise.all(names.map((name) => rm(join(staging, name))));
    try {
      await rename(staging, app);
    } catch (error) {
      // Concurrent Pi processes may finish the same source-hashed build first.
      if (!existsSync(executable)) throw error;
    }
    return executable;
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

export async function startCompanion(root: string, signal?: AbortSignal): Promise<void> {
  const executable = await buildCompanion(root, signal);
  signal?.throwIfAborted();
  const log = openSync(join(root, "companion.log"), "a", 0o600);
  try {
    await new Promise<void>((resolveStart, reject) => {
      const child = spawn(executable, [root], { detached: true, stdio: ["ignore", log, log], env: process.env });
      child.once("error", reject);
      child.once("spawn", () => { child.unref(); resolveStart(); });
    });
  } finally {
    closeSync(log);
  }
}
