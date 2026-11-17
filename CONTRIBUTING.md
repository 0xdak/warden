# Contributing to Warden

Thanks for helping. The most valuable contributions, in order:

1. **Bypass reports**: a command or tool call that should have been blocked or asked about but went through.
   Report these privately (see [SECURITY.md](SECURITY.md)), not as public issues.
2. **New rules or detections**, each with self-test cases.
3. **Agent adapter fixes** when an agent changes its hook format.
4. False positives: a harmless, common command that Warden blocks or asks about. Open a normal issue.

## Ground rule: never test against your real agent configs

Warden edits `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.cursor/hooks.json` and friends. While developing,
**always** point it at a throwaway home:

```sh
export WARDEN_HOME_OVERRIDE="$(mktemp -d)"     # every path derives from this
# optional: export WARDEN_SOCKET_OVERRIDE=/tmp/warden-dev.sock
```

`scripts/selftest` does this for you and the SelfTest binary refuses to run if the override is missing or points at
your real home. If you run the app or the hook by hand, set the override first.

## Build and test

Requirements: macOS 14+, Swift 6 Command Line Tools (`xcode-select --install`). Xcode is not needed; `swift test`
isn't used because XCTest isn't available without Xcode.

```sh
cd app
swift build                  # debug build of everything
scripts/selftest             # builds Hook + SelfTest, runs all checks against a temp HOME
swift build -c release       # what CI also runs
scripts/build_app.sh         # dist/Warden.app (ad-hoc signed), to try the UI
WARDEN_HOME_OVERRIDE="$(mktemp -d)" dist/Warden.app/Contents/MacOS/Warden --show-window
```

Dry-run one decision (prints the matches and the event, writes nothing):

```sh
echo '{"hook_event_name":"PreToolUse","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"cat .env"}}' \
  | WARDEN_HOME_OVERRIDE="$(mktemp -d)" .build/debug/Hook --agent claude --explain
```

`--agent` takes `claude`, `codex`, `cursor`, `gemini`, `windsurf` or `cline`; the JSON must be in that agent's
hook format (see `Sources/GuardCore/Adapters.swift`).

## Where things live

See [app/ARCHITECTURE.md](app/ARCHITECTURE.md). Short version:

| File | What |
|---|---|
| `Sources/GuardCore/Rules.swift` | Rule catalog: id, name, category, severity, summary, default action per preset (strict, balanced, permissive) |
| `Sources/GuardCore/RuleEngine.swift` | Detection: emits `Hit(ruleId:reason:)` for paths, shell commands, git, exfiltration |
| `Sources/GuardCore/ShellRules.swift` | Shell helpers: variables, `cd`, globs, deletion targets, interpreter one-liners |
| `Sources/GuardCore/ShellLexer.swift` | Quote-aware tokenizer, pipelines, `$( )`, `bash -c`, wrapper stripping |
| `Sources/GuardCore/SecretPaths.swift` | Which paths count as secrets or guard config |
| `Sources/GuardCore/Adapters.swift` | Per-agent input parsing and output dialect |
| `Sources/SelfTest/main.swift` | All checks |

## Adding a rule

1. **Catalog entry** in `Rules.swift`. Pick a stable id (`category.thing`), a plain-language summary and defaults
   `(strict, balanced, permissive)`. Prefer `ask` over `block` on Balanced unless the action is almost never
   legitimate. If an existing rule fits, add detection to it instead of creating a new id.
2. **Detection** in `RuleEngine.swift` (or `ShellRules.swift` for shell parsing helpers). Append
   `Hit(ruleId: "your.id", reason: "…")`. The reason is shown to the user and the agent: say what the action does,
   with the resolved path when there is one ("deletes /Users/me/code/other, outside the project").
3. **Self-test cases** in `Sources/SelfTest/main.swift`, in the matching section. Every detection needs at least one
   positive case **and one benign look-alike** that must stay allowed:

   ```swift
   expectClaude("terraform destroy", "terraform destroy -auto-approve", "ask")
   expectClaude("terraform plan is fine", "terraform plan", "none")
   ```

   `expectClaude(name, command, want)` runs the real hook binary with a Claude Code `Bash` payload on the Balanced
   preset; `want` is `deny`, `ask`, `allow` or `none` (no opinion). For other tools use
   `runHook("claude", claudeTool("Read", ["file_path": …]))` and check `claudeDecision(r)`.
4. Run `scripts/selftest` until it ends with `N passed, 0 failed`.
5. If the rule is user-visible, update the table in the root [README.md](README.md).

Fixing a bypass follows the same pattern: add the bypass as a failing check first (see the `H1`…`H9` "bypass
hardening" sections), then fix it.

## Constraints

- **Determinism.** No network calls, no models, no randomness in the decision path.
- **Speed.** The hook runs before every agent action. Keep work linear in the input and avoid filesystem walks
  beyond what's needed (glob expansion is capped).
- **Never break the agent.** Unreadable input → allow with exit 0; the hook never exits 1.
- **Unknown → ask, not allow**, where that doesn't make everyday commands noisy.
- **Brand strings** live only in `Sources/GuardCore/Brand.swift` and `scripts/brand.env`. On the website, never type
  the product name in `website/src/`; use `{{name}}` and run `python3 build.py --check`.

## Pull requests

- One topic per PR. Include the self-test cases and paste the final `passed/failed` line.
- Describe the user-visible change (new prompts, blocks, or things that are now allowed).
- By contributing you agree your work is released under the [MIT License](LICENSE).
