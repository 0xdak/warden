# Warden: developer notes

A menu-bar app that stands between AI coding agents (Claude Code, Codex CLI, Cursor, Gemini CLI, Windsurf, Cline)
and your Mac. It blocks clear threats (secret reads, wipes, download-and-run, data leaving the machine), pauses
judgment calls for your approval, and keeps a searchable, redacted record of every action. Local only: no account,
no telemetry, works offline.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how it works, and the [project README](../README.md) for the overview.

## Build

Requirements: macOS 14+, Swift 6 Command Line Tools (`xcode-select --install`). No Xcode needed.

```sh
scripts/selftest          # 343 checks against a throwaway HOME
scripts/build_app.sh      # → dist/Warden.app (universal, ad-hoc signed unless SIGN_IDENTITY is set)
scripts/make_dmg.sh       # → dist/Warden.dmg (+ .sha256)
```

Release builds (Developer ID signing + notarization, maintainers only):
`SIGN_IDENTITY=… SIGN_KEYCHAIN=… NOTARY_PROFILE=… scripts/release.sh`.

## Install (for a user)

1. Download `Warden.dmg` from [GitHub Releases](https://github.com/0xdak/warden/releases/latest) (optionally compare
   `shasum -a 256 Warden.dmg` with `Warden.dmg.sha256`), drag **Warden** to Applications and open it. Release builds
   are Developer ID signed and notarized. A build you made yourself with `scripts/build_app.sh` is ad-hoc signed, so
   macOS asks you to confirm its first launch (right-click ▸ Open, or System Settings ▸ Privacy & Security ▸ Open Anyway).
2. The setup sheet finds your agents. Pick the ones to protect, choose a preset (Balanced is recommended) and
   whether to start by recording a baseline (observe only).
3. **Install & continue** adds a hook to each agent's own config. A backup of each file is saved first. You can preview
   the exact change from Agents ▸ Install… as well.
4. Codex only: open Codex, run `/hooks` and trust the Warden hook once. Cline only: switch the hook on in Cline's
   Hooks tab. Restart running agent sessions.
5. When the baseline looks right, press **Start enforcing** on Home.

Answering questions: a floating panel appears when an agent wants to do something that needs a decision
(Return = the safe choice on high risk). You can also answer on the Review screen or in a terminal:

```sh
~/Library/Application\ Support/Warden/bin/warden-hook approvals
~/Library/Application\ Support/Warden/bin/warden-hook approvals allow|project|block <id>
```

## Uninstall

1. In Warden ▸ Agents press **Remove** on each protected agent (removes only Warden's entries; **Restore backup**
   puts back the exact file saved before install). Restart the agents.
2. Quit Warden from the menu bar and delete it from Applications.
3. Optionally delete `~/Library/Application Support/Warden` (settings, decisions, activity log, backups, hook copy).

If you delete the app before removing hooks, agents will try to run
`~/Library/Application Support/Warden/bin/warden-hook`. Remove the entries mentioning `warden-hook` from
`~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.cursor/hooks.json`, `~/.gemini/settings.json`,
`~/.codeium/windsurf/hooks.json` and `~/Documents/Cline/Hooks/PreToolUse`.

## Developing safely

Never test against your real agent configs. Point everything at a temporary home:

```sh
export WARDEN_HOME_OVERRIDE="$(mktemp -d)"
dist/Warden.app/Contents/MacOS/Warden --show-window     # app with a fake home
echo '{"hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"cat .env"}}' \
  | .build/debug/Hook --agent claude --explain
```

## Rename

Edit `Sources/GuardCore/Brand.swift` and `scripts/brand.env`. Nothing else contains the product name.
