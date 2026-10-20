# Contributing

Use Node 22.19 or newer and Pi 1.2.0. macOS 14+ and Xcode Command Line Tools are needed to build/test the Swift companion.

```sh
npm ci --ignore-scripts
npm run check
npm test
npm pack --dry-run
```

Keep Pi host-provided and avoid third-party notification/UI SDKs. Node tests must use isolated state directories and must not launch the desktop companion or model providers. Native tests compile the actual Cocoa app and exercise Foundation models headlessly.

Preserve the safety contracts: no startup resources in the extension factory, no shell evaluation of prompts, no automatic project trust, no PID-file signalling, fresh/expiring control tokens, private atomic state, exact inactive-session resume, and orderly lifecycle cleanup. Treat output and filesystem paths as untrusted text. Background logs and normal Pi session history must never be deleted by overview-entry cleanup.

For a release, update package and lockfile versions, add a changelog entry, run the checks, and tag `v<version>`. Version/native source changes create a new cached app bundle. Reload/start cooperatively replaces outdated companions; keep targeted quit checks, cancellation/deadlines and the close-on-exec singleton lock covered. Tests may execute the bundle's `--version` path, never its GUI entry point.
