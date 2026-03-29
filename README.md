# Orbit

[简体中文说明](README.zh-CN.md)

Orbit is a native macOS menu bar app for managing local LLM account workspaces on one machine. This release keeps full Codex support, exposes a Claude placeholder entry, keeps local account metadata in one place, and switches the active Codex identity by atomically updating `~/.codex/auth.json`.

## Features

- Manage local LLM account workspaces from a menu bar utility and a dedicated desktop window.
- Switch between Codex and Claude platform views. Claude is visible as a placeholder in this release.
- Add ChatGPT accounts through browser OAuth.
- Add API key accounts for local credential switching.
- Switch the active account without manually editing `~/.codex/auth.json`.
- Review account details such as plan type, Codex usage status, availability, quota limit state, last refresh time, and last used time.
- Open Codex CLI directly from the selected account in the account detail view.
- Choose a working directory before launching CLI, and reopen previously used directories from the per-account history list.
- Use the current global `~/.codex` for the active account, or launch CLI with an isolated `CODEX_HOME` for other accounts without rewriting the global auth file.
- Archive quota snapshots from local Codex artifacts: `~/.codex/sessions/*.jsonl` and `~/.codex/state_5.sqlite`.
- Refresh online usage data for supported ChatGPT accounts through `/wham/usage`.
- Recommend switching when the active account is running low on the 5-hour budget.
- Detect stale live Codex sessions after a switch and suggest restarting Codex when needed.
- Store app metadata in `~/Library/Application Support/Orbit/accounts.json` and cached credentials in `~/Library/Application Support/Orbit/credentials-cache.json` without Keychain prompts.

## Requirements

- macOS 14 or later
- Swift 6 toolchain if you build from Terminal
- A local Codex environment that uses `~/.codex`

## Commands

### Run the app

```bash
swift run
```

You can also open `Package.swift` in Xcode and run it as a macOS app.

### Run tests

```bash
swift test
```

### Package a distributable app

```bash
./scripts/package_app.sh
```

The packaging script writes these artifacts to `dist/`:

- `Orbit.app`
- `Orbit.zip`
- `assets/AppIcon.icns`
- `assets/AppIcon-master.png`
- `assets/MenuBarIcon-template.png`

## Notes

- Quota values are shown as remaining percentage so they align with the Codex status panel.
- Manual status refresh pulls online usage data first, and later local session events can still replace the snapshot with fresher data.
- API key accounts support local switching, but not online usage refresh.
- Claude is exposed as a platform entry only in this release. Real Claude authentication, switching, CLI launch, and quota sync are not implemented yet.
- The app no longer depends on Keychain, so switching accounts and opening the main window should not trigger credential permission prompts.
