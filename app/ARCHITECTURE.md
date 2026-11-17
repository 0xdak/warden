# Architecture

A native macOS (14+) menu-bar guard for AI coding agents. Agents call a small hook CLI before each action. The CLI
decides allow / ask / block locally, asks the menu-bar app when a person has to choose, writes a redacted record, and
answers in the agent's own dialect. Built with SwiftPM and the Command Line Tools only (no Xcode project).

**Warden** (bundle id `com.dakcyber.warden`, hook file name `warden-hook`). Every brand string lives in
**`Sources/GuardCore/Brand.swift`** and **`scripts/brand.env`**. Targets and modules have generic names
(`GuardCore`, `App`, `Hook`, `SelfTest`), so renaming the product only touches those two files.

## Build & test

| Task | Command |
|---|---|
| Debug build | `swift build` |
| All checks (hook, rules, adapters, IPC, installer) | `scripts/selftest` |
| Release `.app` (universal) | `scripts/build_app.sh` → `dist/Warden.app` |
| arm64 only | `ARCHS=arm64 scripts/build_app.sh` |
| Real signing | `SIGN_IDENTITY="Developer ID Application: …" scripts/build_app.sh` |
| DMG + SHA-256 | `scripts/make_dmg.sh` → `dist/Warden.dmg`, `dist/Warden.dmg.sha256` |
| Dry-run one decision | `echo '<hook json>' \| warden-hook --agent claude --explain` (writes nothing) |
| Placeholder icon | `swift scripts/make_icon.swift Resources/AppIcon.icns` (build_app.sh does this when missing) |

`swift test` isn't used: without Xcode, XCTest is missing. `scripts/selftest` builds the `Hook` and `SelfTest`
products, copies the hook to a temporary folder under its real file name, and runs every check against a
**throwaway HOME** (`WARDEN_HOME_OVERRIDE`). The self-test refuses to run when that override is missing or points to
the real home folder.

## Layout

```
Package.swift
Sources/
  GuardCore/            Foundation only. Shared by the hook, the app and the tests.
    Brand.swift         names, bundle id, hook file name, env prefix
    Paths.swift         every path, from `home` (WARDEN_HOME_OVERRIDE) → support folder, socket, files; ~ / $HOME expansion
    Models.swift        Agent, RuleAction, Severity, Preset, ActionEvent, RuleMatch, GuardSettings,
                        RememberedDecision, GuardException, DecisionBook, JSONFile
    ShellLexer.swift    quote-aware tokenizer: pipelines, ; && || &, redirects, $( ), backticks, <( ), bash -c, eval;
                        strips sudo/env/nohup/xargs/timeout/… wrappers
    SecretPaths.swift   secret-path classifier + guard-config paths (self-protection)
    Rules.swift         built-in rule catalog with per-preset actions (strict / balanced / permissive)
    RuleEngine.swift    detection: paths, shell commands, git, exfiltration, disk, env dumps, custom rules (glob/contains/regex)
    ShellRules.swift    shell helpers: size limits, $VAR / cd tracking, disk globs, deletion targets (rm, find -delete,
                        rsync --delete, xargs rm), chmod modes, interpreter one-liners, grep -r for secrets
    Adapters.swift      per-agent stdin → ActionEvent, Verdict → stdout / stderr / exit code
    HookRunner.swift    the pipeline: parse → rules → remembered decisions/exceptions/pause → ask app → log → render
    Redactor.swift      masks keys/tokens/passwords before anything is stored
    EventLog.swift      events/YYYY-MM-DD.jsonl (O_APPEND), tail reading, retention, CSV/JSONL export
    IPC.swift           Unix-socket client (hook) and server (app); newline-delimited JSON
    ProcessInspector.swift  sysctl KERN_PROCARGS2: bypass/YOLO flags in ancestor and running agent processes
    Installer.swift     per-agent JSON merge, backups, uninstall, restore, state detection
  Hook/main.swift       `warden-hook --agent <a>`, `--explain`, `--ping`, `approvals [allow|project|block <id>]`
  App/                  SwiftUI menu-bar app
    AppEntry.swift      MenuBarExtra + AppDelegate (accessory app) + MainWindow (AppKit window hosting SwiftUI)
    Model/AppModel.swift  @Observable state: settings, decisions, install states, events, pending approvals,
                        socket server, timers (log tail 1 s, config watch 5 s, unsafe-process scan 15 s)
    Panel/ApprovalPanel.swift  floating NSPanel + ApprovalCard (shared with the Review screen)
    Views/              Home, Review, Protect, Agents (+ install preview), Evidence, Decisions, Settings,
                        Onboarding, MenuBarPanel, Theme (our palette + small components)
  SelfTest/main.swift   ~340 checks, run by scripts/selftest
scripts/                brand.env, build_app.sh, make_dmg.sh, make_icon.swift, release.sh, selftest
Resources/AppIcon.icns  generated placeholder icon
```

## Decision flow

```
agent ──stdin JSON──► warden-hook --agent X
                        1. Adapters.parse → ActionEvent {kind, command|paths|url, cwd, project, session, permission mode}
                        2. unsafe-mode flags: permission_mode=bypassPermissions + ancestor argv (--dangerously-skip-permissions, --yolo…)
                        3. RuleEngine.evaluate(settings) → matches with the effective action (override > preset)
                           input > 1 MB, command > 100 KB or > 20,000 words → only guard.oversize (ask, never allow)
                        4. remembered decision (allow/block) > exception > pause > rules     (guard.tamper ignores exceptions & pause)
                        5. highest action wins: block > ask > observe > allow;  observe mode → allow + "would have …"
                        6. ask → socket to the app → popup → allow/block (+ remember)      app not running → see below
                        7. EventLog.append(redacted record)
                        8. Adapters.render → stdout / stderr / exit code
```

**App not running (ask):** Claude Code and Cursor (shell/MCP) get the agent's own prompt (`ask`). Other agents use
Settings ▸ "If Warden isn't running" (default **block**, with a message telling the agent to ask the user to open
the app). Hard blocks never need the app.

**Timeouts:** the app answers with Settings ▸ "If nobody answers" (default block) after "Wait for an answer"
(default 60 s). The hook itself stops waiting 5 s later and applies the same default. Agent hook timeouts are set to
120 s on install.

**Approval tiers:** the agent's own prompt (`preferNativeAsk`, or the fallback) → the
app's floating popup and Review screen → the terminal: `warden-hook approvals` lists pending items and
`warden-hook approvals allow|project|block <id>` answers one.

### How rules read a command

* **Paths.** Every path-like word (operands, `--flag=value`, `@file`, redirects) is expanded and normalised against
  the folder the command will run in. `cd X` / `pushd X` earlier in the same line moves that folder (`cd ~/.aws &&
  cat credentials`). `$HOME`, `$PWD`, `$(pwd)`, `$TMPDIR` and same-line assignments (`f=.env; cat $f`, `export`)
  are substituted; `$'\x2e…'` is decoded by the lexer; `d=$(mktemp …)` counts as a temp folder.
* **Symlinks.** Secret and guard-config checks run on the literal path and on its `realpath` (reads, writes, Read /
  Edit / Write / Grep / Glob / MCP paths). Dangling links are followed for writes. `rm link` judges the link itself.
* **Globs.** `cat .e*`, `.[e]nv`, `cat .*` are expanded on disk like the shell would (at most 64 globs per line); when
  the folder doesn't exist the pattern is matched against typical secret names instead (`secret.indirect`, ask).
* **Unknown parts.** A reader whose path still contains an unresolved `$x` / `$(…)` asks only when the known parts
  could spell a secret file (`cat ${x}nv`). A word that is *only* a variable (`cat "$f"`) is allowed: asking for
  every `cat $f` would be noise. Interpreter one-liners (`python -c`, `node -e`, `ruby -e`, `perl -e`, `php -r`) are
  scanned for path-looking strings (`'.env'`, `'~/.aws/credentials'`, `'/.ssh/id_rsa'`); dotted names such as
  `process.env` don't count. String building (`'.e'+'nv'`) is out of reach for a static check.
* **Names only.** `ls`, `tree`, `du`, `stat`, `echo`, `test`, `find` without `-exec`/`-delete` and the LS tools don't
  trigger secret rules on their operands (listing `~/.ssh` isn't reading a key); redirects still count.
* **Deletions** (`rm`, `unlink`, `trash`, `find … -delete` / `-exec rm`, `rsync --delete DST`, `… | xargs rm`): each
  target is resolved (vars, `cd`, symlinked parent folders) and the reason shows the absolute path.
  `/`, home, system folders, top-level home folders, `/tmp` itself, a parent of the current folder or project, or a
  `.git` folder → `cmd.rm-critical` (block). The project root itself (`rm -rf .`, `rm -rf *` at the root,
  `find . -delete`) → `cmd.rm-project` (ask). Inside the project or the agent's start folder → allowed; under a temp
  folder → allowed; anything else → `cmd.rm-outside` (ask, also for single files). A recursive delete of a path with
  an unknown variable or after an unknown `cd` → ask. `find` with a name/path/time filter only asks outside the
  project. `git clean -fd/-x` → `git.clean` (ask).
* **Download / decode and run.** `curl|wget … | sh`, `base64 -d | sh`, `eval "$(… base64 …)"`, `sh -c "$(curl …)"`,
  `curl -o x … && sh x` / `./x` → `cmd.pipe-shell`.
* **Limits.** A word is looked at once per program (repetitive input is cheap); the shell lexer and wrapper stripping
  are linear. Normal calls take a few ms; the largest command under the limits takes well under a second.

### Agent dialects

| Agent | Allow | Block | Ask |
|---|---|---|---|
| Claude Code | no output (agent's own permissions still apply); explicit `allow` JSON after you approved | exit 0 + `permissionDecision:"deny"` + reason | `permissionDecision:"ask"` or our popup |
| Codex CLI | exit 0, no output | exit 2 + reason on stderr | our popup (Codex has no ask) |
| Cursor | `{"permission":"allow"}` | `{"permission":"deny","user_message","agent_message"}` | `"ask"` for shell/MCP, popup for reads |
| Gemini CLI | `{}` | exit 2 + stderr + `{"decision":"deny","reason"}` | popup |
| Windsurf | exit 0 | exit 2 + stderr | popup |
| Cline | `{"cancel":false}` | `{"cancel":true,"errorMessage"}` | popup |

Unreadable input → allow (exit 0). The hook never exits 1.

## Storage (`~/Library/Application Support/Warden`, mode 0700)

| File | Writer | Reader | Content |
|---|---|---|---|
| `settings.json` | app | hook, app | preset, mode, timeouts, fallbacks, pause, rule overrides, custom rules, retention |
| `decisions.json` | app | hook, app | remembered decisions (project / everywhere, optional expiry) + expiring exceptions |
| `installs.json` | installer | app | per agent: config path, backup paths, created-file flag |
| `events/YYYY-MM-DD.jsonl` | hook (append) | app (tail) | one redacted record per hook call; day files older than retention are deleted |
| `backups/<agent>/…` | installer | installer | copy of the agent config before each install |
| `bin/warden-hook` | installer | agents | stable hook path (Codex trust is tied to the hook definition, so the command never changes) |
| `guard.sock` | app | hook | Unix socket, 0600, peers checked with `getpeereid` |

JSONL instead of SQLite: append-only from many short-lived hook processes needs no locking, and day files make
retention a file delete. The app keeps up to ~20k recent records in memory for search.

## Installer

Per agent (`Installer.configPath` / `events`):

| Agent | File | Events |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | PreToolUse (`*`), UserPromptSubmit, SessionStart |
| Codex CLI | `~/.codex/hooks.json` | PreToolUse (`.*`), UserPromptSubmit, SessionStart — then trust it once via `/hooks` |
| Cursor | `~/.cursor/hooks.json` | beforeShellExecution, beforeReadFile, beforeMCPExecution (`failClosed: true`), beforeSubmitPrompt, afterFileEdit |
| Gemini CLI | `~/.gemini/settings.json` | BeforeTool (`.*`, timeout in ms), SessionStart |
| Windsurf | `~/.codeium/windsurf/hooks.json` | pre_run_command, pre_read_code, pre_write_code, pre_mcp_tool_use |
| Cline | `~/Documents/Cline/Hooks/PreToolUse` (script) | PreToolUse — user switches it on in Cline's Hooks tab |

* Our entries are recognised by `warden-hook … --agent`, so install is idempotent and uninstall removes only ours.
* A backup is taken before every write; "Restore backup" puts back that exact file.
* Files that aren't plain JSON (JSONC with comments) are refused and left untouched.
* A config file we created is deleted on uninstall only if nothing else is left in it.
* The app re-checks every 5 s: hooks gone → re-install (Settings toggle, on by default) and notify;
  `disableAllHooks` / Codex `hooks = false` → shown as "Hooks turned off".

## Self-protection

`guard.tamper` (always on; pauses and exceptions don't cover it): writes to agent hook/settings files (user and
project level), the support folder, `disableAllHooks` anywhere in a command or edit, and killing the app or hook.
Reading those files is allowed.

## Safety for development

Everything derives from `Paths.home`. Set `WARDEN_HOME_OVERRIDE=<temp dir>` (and optionally
`WARDEN_SOCKET_OVERRIDE`) when running the app or the hook during development; the self-test does this always.
