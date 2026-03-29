# Orbit

[简体中文说明](README.zh-CN.md)

Orbit is a native macOS workspace for managing local LLM accounts on one machine. It keeps Codex, Claude, and provider-backed accounts in one place, lets you inspect status and quota data, and launches Codex CLI or Claude Code with the right account, model, provider, and bridge path automatically.

It targets macOS 14 or later. If you build from Terminal, use a Swift 6 toolchain.

## Core Features

- Manage ChatGPT OAuth accounts, OpenAI-compatible provider API keys, Claude-compatible provider API keys, and switchable local Claude Profile snapshots from one app.
- Launch Codex CLI or Claude Code from the selected account after choosing a working directory, then reopen recent directories from per-account history.
- Switch the active Codex account by updating `~/.codex/auth.json` automatically, or launch non-active Codex accounts in isolated `CODEX_HOME` workspaces without rewriting the current global auth file.
- Save provider-level settings on the account itself: provider rule, display name, Base URL, API key environment variable, and default model.
- Automatically choose direct provider wiring or a local bridge when the upstream provider needs protocol translation.
- Import the current `~/.claude` and `~/.claude.json` as a local Claude Profile, or save an Anthropic API key for Claude-side workflows.
- Review account details such as plan type, Codex usage status, availability, quota limit state, last refresh time, and last used time.
- Archive local Codex quota snapshots from `~/.codex/sessions/*.jsonl` and `~/.codex/state_5.sqlite`, refresh supported online usage data, and recommend switching when the active 5-hour budget is low.
- Detect stale live Codex sessions after a switch and suggest restarting Codex when the running app is still using the old credential.
- Store app metadata under `~/Library/Application Support/Orbit/` without Keychain permission prompts.

## Screenshot Examples

### Unified Account Workspace

![Orbit workspace](https://raw.githubusercontent.com/aikilan/Orbit/refs/heads/main/example/static/workspace.png)

The main workspace keeps account switching, account details, quota snapshots, status logs, recent directories, and CLI target selection in one view. You can review the current account and decide whether the next launch should open Codex CLI or Claude Code.

### Codex CLI With an OpenAI-Compatible Provider

![Codex CLI with a GLM-style provider](https://raw.githubusercontent.com/aikilan/Orbit/refs/heads/main/example/static/codex-use-glm.png)

Orbit can launch Codex CLI with an OpenAI-compatible provider account, including GLM-style setups. The app injects the saved provider, model, and API key environment automatically, and starts a local bridge when the upstream only exposes `chat/completions` instead of the OpenAI Responses API.

### Claude Code With Bridged OpenAI/Codex Credentials

![Claude Code with a bridged OpenAI/Codex model](https://raw.githubusercontent.com/aikilan/Orbit/refs/heads/main/example/static/codex-use-claude.png)

Orbit can also open Claude Code from a Codex or provider-backed account. It prepares the app-managed patched runtime, bridges the saved credentials into the Claude-side environment, and reuses the account's configured model flow without asking for a separate Claude login.

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

## Limitations and Notes

- Claude currently supports local Claude Profile import, Anthropic API key management, and Claude CLI / Claude Code launch. `claude.ai` OAuth switching is not supported.
- A Claude Profile entry is only a local snapshot of `~/.claude` and `~/.claude.json`; it does not represent the official `claude.ai` or Console sign-in state.
- Some providers do not expose the OpenAI Responses API directly. Orbit can still launch supported workflows by starting a local bridge, but this README documents launch behavior rather than provider-specific compatibility guarantees.
- API key accounts support local credential switching. Online quota refresh depends on the provider or account type.
- Manual refresh prefers online usage data when supported, while newer local session events can still replace the snapshot later.
