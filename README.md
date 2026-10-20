# pi-overview

A native macOS menu bar manager for [Pi](https://pi.dev). Each loaded Pi instance publishes a small private snapshot; a single Swift/Cocoa companion displays them. No Electron, web server, third-party runtime dependencies, or extra agent tools.

## Install

Requires macOS 14 or newer, Node 22.19 or newer, Pi 1.2.0+, and the Xcode Command Line Tools:

```sh
xcode-select --install
pi install git:github.com/OscarCookeAbbott/pi-overview
```

Run `/reload` in each existing Pi instance you want to see. Other instances appear as they start with this package enabled. It cannot discover Pi processes that have not loaded the extension.

The first interactive session compiles the companion asynchronously. Pi remains usable while Swift compiles; subsequent starts reuse a version/source/architecture-hashed `.app` cache. Look for **π** in the macOS menu bar. Missing compiler or build failures warn in Pi rather than failing the session.

For local development, run `pi -e ./pi-overview/src/index.ts` from the parent directory.

## Menu

- The title separates Pi from live state counts with two spaces. It uses the same native status symbols as agent, task and job rows: a plain play triangle (`play.fill`) for running, a plain checkmark for success, a cross for errors and a pause (`pause`, two vertical bars) for Idle/pending. Play and pause have no enclosing circle or box. Count symbols are native monochrome images, not emoji. With no live instances the title is just `π`, with no separator.
- **Idle** means the session is not running an agent turn, typically after opening or reloading. Legacy Ready records display as Idle. **Completed** (checkmark) means its latest run settled without an abort or model error; it does not mean Pi exited, the work was independently verified, or every task/background job finished. A live session in either state can accept another prompt. The pause count retains the existing catch-all bucket for other non-running live sessions, including aborted runs; it does not suspend processes.
- Session rows and counts are deduplicated by Pi session ID, including old registrations left after reload. A live/current-process registration wins; otherwise the newest finished snapshot is shown. Older snapshots recover their ID from the session file header; unknown identities stay separate. Deduplication changes only presentation, not control tokens, cleanup or session history.
- Instance rows and submenus use state symbols and show project/session name, directory, PID and a recent assistant-output preview limited to 60 characters. Extensions can add inline badges such as `[3/6 tasks] [2 jobs]` plus hoverable sections/items. Generic generation/processing is labelled Working, not Thinking; tool-running labels name the tool or count parallel tools independently. An intermediate turn or `agent_end` never marks an agent idle: completion follows `agent_settled`.
- **New agent** is an inline menu composer: type a multiline prompt and click Start or press ⌘Return. The compact, scrollable input fills the menu width, with the directory readout and folder button above it. Inline errors replace the keyboard hint beside Start rather than reserving an empty row. It defaults to `defaultDirectory` (home by default); the optional picker changes only this draft/launch, not your settings. Escape/menu dismissal preserves the draft and folder choice; success resets them. Validation/launch errors stay inline instead of opening a prompt popup. It starts a print-mode Pi process with a unique session file and private log. Prompts go through stdin, not a shell or CLI argument expansion. No `--approve` flag is added: normal saved project trust and permission rules still apply. Headless runs cannot answer interactive login or permission dialogs; configure those beforehand and inspect the log on failure.
- **Abort Run** asks that instance to call Pi's abort API. It leaves the Pi process available for input.
- **Quit Pi Instance…** confirms and requests Pi's orderly shutdown, including its usual background-job cleanup. It does not send SIGTERM to a PID.
- **Open Project in Terminal** opens a new Ghostty window in that directory, or Terminal.app if Ghostty is unavailable. It does not attach to an existing live TUI or guess a session with `--continue`.
- **Resume This Session in Terminal** opens the exact recorded session file, only after the original process has exited and no recorded live instance is using that file. It is not a live-session attach operation. Unresponsive processes must be dealt with separately; they are never silently overwritten or force-killed.
- **Open Run Log**, **Reveal Session File** and **Copy Output Preview** expose only their named artifacts.
- **Clear Finished Entries** removes inactive overview entries, not logs or session history. Old inactive snapshots are pruned after seven days. All distinct sessions are available, with live instances first; long menus scroll.
- **Quit Menu Bar (Keep Pi Running)** closes the companion without stopping agents, including background runs it launched. It stays closed until `/overview start` or a new interactive Pi session starts it.

Ghostty is checked at `/Applications/Ghostty.app`. The Terminal.app fallback may require macOS Automation permission. It receives a fixed AppleScript plus fully shell-quoted path arguments, never interpolated prompt text.

## Commands

- `/overview`: show companion/session status, running version/build and the data directory.
- `/overview start`: build if needed, reuse a matching/newer companion or cooperatively replace an outdated one. A native advisory lock prevents duplicate menu bars even if several Pi processes start simultaneously.
- `/overview stop`: cancel pending startup/replacement and ask the companion to quit. Agents keep running. Allow a couple of seconds for its polling loop to exit before starting it again.
- `/overview folder`: open the data directory in Finder.

With `autoStart: true` (default), `/reload` also checks the running companion's package version and architecture/source build hash. A matching or newer release is reused. An outdated or legacy companion is asked to quit; its replacement starts after the old process exits. Compilation happens first, so a build failure leaves the existing app alone. Replacement waits are bounded to 15 seconds after compilation and never force-kill processes. The companion handoff itself does not stop Pi/agent processes; other extensions' normal reload behavior is unchanged. Unsubmitted menu-composer drafts reset when the app is replaced. With `autoStart: false`, use `/overview start` to perform this check manually. No login item or launchd agent is installed.

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

The three boolean settings default to `true`. `defaultDirectory` defaults to the current user's home, accepts `~`/`~/…`, and resolves relative paths against the Pi session's working directory. `autoStart` launches the GUI only from TUI sessions; print/JSON/RPC sessions still publish state without opening a menu bar. `showOutput: false` omits future assistant previews. Existing snapshots/logs are not retroactively erased. Invalid settings warn and disable this extension for that session. On non-macOS platforms it is inert: `/overview` silently does nothing, settings are not parsed, no contribution API/listeners or resources start, and no unsupported-platform warnings appear.

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

Items support `running`, `complete`, `failed`, `waiting`, `pending`, `cancelled` and `unknown` states. Optional `children` form recursive submenus. `kind` (`task`, `note`, `job`, `group`) selects native icons/typography; `subtitle` and `body` supply a separate status line and selectable, scrollable content card. `detail` retains full metadata for tooltips and Copy details. Submenus build lazily as you hover; long bodies scroll inside the card rather than becoming dozens of disabled text rows. No callbacks, commands or executable actions are serialized; cyclic trees are rejected. Labels are sanitised and shortened for menu rows (eighty-character item titles), but source, section and item counts are not truncated. Long native menus scroll.

`pi-tasks` publishes its progress badge and task hierarchy, with explicit Subtasks and Notes groups under each owner; `pi-async-jobs` publishes only currently running jobs (no inline job-count badge or completion history), using optional titles and command/process detail cards. These integrations do not require an overview dependency and do not affect agent-facing results.

## State and privacy

Data lives at `getAgentDir()/overview` (normally `~/.pi/agent/overview`):

```text
records/       Per-runtime UUID snapshots, including recently closed instances
commands/      Expiring, token-addressed abort/shutdown requests
sessions/      Exact session files for menu-launched background tasks
logs/          stdout/stderr logs for those tasks
bin/           Version/source/architecture-hashed app bundles
launcher.json  Current Node/Pi/extension paths and configured new-agent directory
build.log      Compiler diagnostics on failure
companion.log  Native companion diagnostics
daemon.json    Companion PID, incarnation, version/build and heartbeat
daemon-command.json  Expiring manual or incarnation-targeted quit request
```

`PI_OVERVIEW_DIR` overrides the directory, mainly for isolated testing. Directories are owner-only and atomic JSON snapshots/requests are mode 0600. Credentials and environment values are not written into launch configuration. The companion inherits the environment of the Pi process that launched it; restart it after changing environment-based credentials or PATH.

Snapshots expose directory/session metadata, accepted extension contributions and up to 400 Unicode characters of the latest visible assistant text; the popup displays only the first 60 preview characters. The built-in assistant preview excludes thinking and tool inputs/outputs. Contributions may intentionally include task/note text and job command/process metadata, even when a title is used for the primary job label; `showOutput` controls only the assistant preview, not contributed data. Background logs and normal Pi sessions can still contain sensitive material. Disable previews if necessary, and remove old logs/session files yourself when no longer needed.

Instances heartbeat once per second; the GUI refreshes every two seconds and treats stale/dead instances as disconnected. Control uses a fresh random runtime token and ten-second request expiry, not PID-file signalling. Shutdown cleans up timers/listeners and leaves a closed snapshot; abrupt exits are detected by stale heartbeat/process liveness. No SIGINT/SIGTERM handlers are installed or replaced.

The companion uses `flock`, so stale lock files and PID reuse cannot cause it to signal unrelated processes or start two menu bars. Native startup and Swift compilation happen only after session start or an explicit command, never during extension discovery. There is no network listener.

## Development

```sh
npm ci --ignore-scripts
npm run check
npm test
npm pack --dry-run
```

Node tests cover lifecycle, private atomic files, control validation, preview filtering and package discovery/deduplication. On macOS the test suite also compiles the actual Cocoa companion and runs Swift model and real AppKit menu-structure tests (enabled hover submenus, multiline details, nested notes and long lists); tests do not open menus or call model providers. Native tests are skipped on other platforms. A real menu/dialog/terminal integration still needs a desktop smoke test.
