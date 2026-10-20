# Changelog

## 0.5.1

- Stretch the inline agent composer with the menu width, keeping its editor, directory readout and action buttons aligned.
- Use a shorter multiline input with a subtle rounded border; show inline errors in the footer instead of reserving an empty row.

## 0.5.0

- Unify native running/success symbols across menubar counts and agent/task/job rows: the two-arrow cycle and a plain checkmark, with native template images in the status title.
- Deduplicate menu rows and state counts by Pi session ID across reload registrations, preferring live/current-process records and then the newest finished snapshot.
- Publish stable session IDs and recover IDs from bounded legacy session-header reads; retain raw registrations for safe controls, resume exclusion and cleanup.

## 0.4.0

- Add native typed task/note/job icons, ownership groups and selectable scrollable content cards instead of plain disabled-text menus.
- Embed New agent directly in the menu with a multiline prompt, Start/Command-Return, draft retention and inline errors.
- Add a directory readout and optional folder chooser above the input; overrides apply only to the current draft/launch and never change settings.
- Suppress job badges and finished/stale job rows even from legacy publisher payloads.
- Test actual native cards, folder-button actions, keyboard/focus, per-draft directory behaviour and composer validation without launching a model.

## 0.3.0

- Add recursive contributed items, complete multiline hover details/tooltips and Copy details, with lazily built native submenus.
- Remove source/section/item/instance cutoffs and the snapshot-size ceiling that hid large lists; native menus scroll instead.
- Separate Pi and counts with two spaces, and label generic activity Working rather than Thinking while keeping tool-specific states.
- Stay silent and resource-free on non-macOS, including invalid settings and explicit commands.
- Exercise real AppKit menu structure alongside SDK, lifecycle and native model/build tests.

## 0.2.2

- Rename New Background Task to New agent and launch directly in the configured defaultDirectory, without a folder picker.
- Show the directory in the prompt dialog and reject unavailable/non-directory paths before launch.

## 0.2.1

- Include the updated native renderer for state indicators, short output previews and contributed badges/menus alongside the publisher API.

## 0.2.0

- Default new-agent folder selection to home, with configurable defaultDirectory and tilde/session-relative paths.
- Separate Pi from symbol-labelled running/completed/error/ready counts; rotate running symbols, add popup state symbols and limit visible output previews to 60 characters.
- Expose optional validated display-only global/event contribution APIs with inline badges and hoverable sections/items, bounded payloads and load-order-safe collection.
- Render task/job contributions without linking companion extension packages or executing contributed actions.

## 0.1.0

- Add a native Swift/Cocoa menu bar companion with live Pi states, assistant previews, background launches, exact inactive-session resume, logs and cooperative abort/shutdown controls.
- Use private atomic snapshots and expiring runtime-token mailboxes, native singleton locking, cached asynchronous builds and lifecycle cleanup without signal-handler overrides.
- Add configuration, commands, Node lifecycle/security tests and headless native model/build checks.
