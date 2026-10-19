# pi-overview

A native macOS menu bar manager for [Pi](https://pi.dev). Each loaded Pi instance publishes a small private snapshot; a single Swift/Cocoa companion displays them. No Electron, web server, third-party runtime dependencies, or extra agent tools.

## Install

Requires macOS 14 or newer, Node 22.19 or newer, Pi 1.2.0+, and the Xcode Command Line Tools:

```sh
xcode-select --install
pi install git:github.com/OscarCookeAbbott/pi-overview
```

Run `/reload` in each existing Pi instance you want to see. Other instances appear as they start with this package enabled. It cannot discover Pi processes that have not loaded the extension.

The first interactive session compiles the companion asynchronously. Pi remains usable while Swift compiles; subsequent starts reuse a source/architecture-hashed `.app` cache. Look for **π** in the macOS menu bar. Missing compiler or build failures warn in Pi rather than failing the session.

For local development, run `pi -e ./pi-overview/src/index.ts` from the parent directory.

## Menu

- The title separates Pi from live state counts, e.g. `π · ◐ 2 ✓ 1`: a rotating circle indicates running agents, a tick indicates completed agents, a cross indicates errors, and an open circle indicates ready/waiting agents. With no live instances it is just `π`, with no separator.
- Instance rows and submenus use state symbols and show project/session name, directory, PID and a recent assistant-output preview limited to 60 characters. Extensions can add inline badges such as `[3/6 tasks] [2 jobs]` plus hoverable sections/items. Parallel tools are counted independently. An intermediate turn or `agent_end` never marks an agent idle: completion follows `agent_settled`.
- **New Background Task…** asks for a project (starting in the configured `defaultDirectory`, home by default) and prompt, then starts a print-mode Pi process with a unique session file and private log. Prompts go through stdin, not a shell or CLI argument expansion. No `--approve` flag is added: normal saved project trust and permission rules still apply. Headless runs cannot answer interactive login or permission dialogs; configure those beforehand and inspect the log on failure.
- **Abort Run** asks that instance to call Pi's abort API. It leaves the Pi process available for input.
- **Quit Pi Instance…** confirms and requests Pi's orderly shutdown, including its usual background-job cleanup. It does not send SIGTERM to a PID.
- **Open Project in Terminal** opens a new Ghostty window in that directory, or Terminal.app if Ghostty is unavailable. It does not attach to an existing live TUI or guess a session with `--continue`.
- **Resume This Session in Terminal** opens the exact recorded session file, only after the original process has exited and no recorded live instance is using that file. It is not a live-session attach operation. Unresponsive processes must be dealt with separately; they are never silently overwritten or force-killed.
- **Open Run Log**, **Reveal Session File** and **Copy Output Preview** expose only their named artifacts.
- **Clear Finished Entries** removes inactive overview entries, not logs or session history. Old inactive snapshots are pruned after seven days. At most 30 entries are shown, with live instances first.
- **Quit Menu Bar (Keep Pi Running)** closes the companion without stopping agents, including background runs it launched. It stays closed until `/overview start` or a new interactive Pi session starts it.

Ghostty is checked at `/Applications/Ghostty.app`. The Terminal.app fallback may require macOS Automation permission. It receives a fixed AppleScript plus fully shell-quoted path arguments, never interpolated prompt text.

## Commands

- `/overview`: show companion/session status and the data directory.
- `/overview start`: build if needed and request the companion. A native advisory lock prevents duplicate menu bars even if several Pi processes start simultaneously.
- `/overview stop`: cancel a pending build and ask the companion to quit. Agents keep running. Allow a couple of seconds for its polling loop to exit before starting it again.
- `/overview folder`: open the data directory in Finder.

After upgrading native companion code, quit the existing menu bar first, then run `/overview start`; a running older companion keeps its singleton lock until it exits. `/reload` updates the TypeScript publisher. No login item or launchd agent is installed.

## Configuration

Merge into `~/.pi/agent/settings.json` or trusted project `.pi/settings.json`, then `/reload`:

```json
{
  "overview": {
    "enabled": true,
    "autoStart": true,
    "showOutput": true,
    "defaultDirectory": "~"
  }
}
```

The three boolean settings default to `true`. `defaultDirectory` defaults to the current user's home, accepts `~`/`~/…`, and resolves relative paths against the Pi session's working directory. `autoStart` launches the GUI only from TUI sessions; print/JSON/RPC sessions still publish state without opening a menu bar. `showOutput: false` omits future assistant previews. Existing snapshots/logs are not retroactively erased. Invalid settings warn and disable this extension for that session. On non-macOS platforms it registers only the command's unsupported-platform explanation and starts no resources.

## Optional overview API

Other extensions can publish **read-only display data** without importing/linking this package:

```ts
const contribution = {
  id: "example",
  badge: "3/6 tasks", // Do not include surrounding brackets.
  sections: [{ title: "Tasks", items: [
    { title: "[ab] Build", state: "running", detail: "Run the build and tests" },
    { title: "[cd] Review", state: "complete" },
  ] }],
};
pi.events.emit("overview:publish", contribution);
// Republish current data whenever overview starts, regardless of extension load order:
const off = pi.events.on("overview:collect", () => pi.events.emit("overview:publish", contribution));
pi.on("session_shutdown", off);
// Remove a source when it no longer has display data:
pi.events.emit("overview:remove", "example");
```

Also publish on your own session start and data changes. With no overview listener these events are harmless. Each source replaces only its own contribution; data belongs to that Pi instance, not every agent in the menu.

For callers wanting validation results, `globalThis[Symbol.for("pi.overview")]` exposes `publish(contribution): { success, error? }` and `remove(id): void`. Resolve it when needed. The key, service and payload types are exported from `src/index.ts`. Acceptance is not a promise that a GUI is running; disabled/non-macOS sessions do not publish snapshots.

Items support `running`, `complete`, `failed`, `waiting`, `pending`, `cancelled` and `unknown` states. Their optional detail appears on hover. No callbacks, commands or executable actions are serialized. Payloads are sanitised/bounded: four sources per instance, three sections per source, up to twenty items per section (with a truncation row), eighty-character item titles and 120-character details.

`pi-tasks` publishes its progress badge, task states and visible notes; `pi-async-jobs` publishes running/awaiting-delivery job counts and sections using optional job titles. These integrations do not require an overview dependency and do not affect agent-facing results.

## State and privacy

Data lives at `getAgentDir()/overview` (normally `~/.pi/agent/overview`):

```text
records/       Per-runtime UUID snapshots, including recently closed instances
commands/      Expiring, token-addressed abort/shutdown requests
sessions/      Exact session files for menu-launched background tasks
logs/          stdout/stderr logs for those tasks
bin/           Source-hashed, locally compiled app bundles
launcher.json  Current Node/Pi/extension paths and configured new-agent directory
build.log      Compiler diagnostics on failure
companion.log  Native companion diagnostics
```

`PI_OVERVIEW_DIR` overrides the directory, mainly for isolated testing. Directories are owner-only and atomic JSON snapshots/requests are mode 0600. Credentials and environment values are not written into launch configuration. The companion inherits the environment of the Pi process that launched it; restart it after changing environment-based credentials or PATH.

Snapshots expose directory/session metadata, accepted extension contributions and up to 400 Unicode characters of the latest visible assistant text; the popup displays only the first 60 preview characters. The built-in assistant preview excludes thinking and tool inputs/outputs. Contributions may intentionally include task/note text and untitled job command labels; `showOutput` controls only the assistant preview, not contributed data. Background logs and normal Pi sessions can still contain sensitive material. Disable previews if necessary, and remove old logs/session files yourself when no longer needed.

Instances heartbeat once per second; the GUI refreshes every two seconds and treats stale/dead instances as disconnected. Control uses a fresh random runtime token and ten-second request expiry, not PID-file signalling. Shutdown cleans up timers/listeners and leaves a closed snapshot; abrupt exits are detected by stale heartbeat/process liveness. No SIGINT/SIGTERM handlers are installed or replaced.

The companion uses `flock`, so stale lock files and PID reuse cannot cause it to signal unrelated processes or start two menu bars. Native startup and Swift compilation happen only after session start or an explicit command, never during extension discovery. There is no network listener.

## Development

```sh
npm ci --ignore-scripts
npm run check
npm test
npm pack --dry-run
```

Node tests cover lifecycle, private atomic files, control validation, preview filtering and package discovery/deduplication. On macOS the test suite also compiles the actual Cocoa companion and runs headless Swift model tests; tests do not show a GUI or call model providers. Native tests are skipped on other platforms. A real menu/dialog/terminal integration still needs a desktop smoke test.
