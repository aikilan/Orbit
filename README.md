# Codex Account Switcher

[简体中文说明](README.zh-CN.md)

Codex Account Switcher is a native macOS menu bar app for managing multiple Codex identities on one machine. It supports both ChatGPT browser sign-in and API key accounts, keeps local account metadata in one place, and switches the active identity by atomically updating `~/.codex/auth.json`.

## Features

- Manage multiple Codex accounts from a menu bar utility and a dedicated desktop window.
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
- Store app metadata in `~/Library/Application Support/CodexAccountSwitcher/accounts.json` and cached credentials in `~/Library/Application Support/CodexAccountSwitcher/credentials-cache.json` without Keychain prompts.

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

- `CodexAccountSwitcher.app`
- `CodexAccountSwitcher.zip`
- `assets/AppIcon.icns`
- `assets/AppIcon-master.png`
- `assets/MenuBarIcon-template.png`

## Notes

- Quota values are shown as remaining percentage so they align with the Codex status panel.
- Manual status refresh pulls online usage data first, and later local session events can still replace the snapshot with fresher data.
- API key accounts support local switching, but not online usage refresh.
- The app no longer depends on Keychain, so switching accounts and opening the main window should not trigger credential permission prompts.
