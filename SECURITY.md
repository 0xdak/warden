# Security policy

## Reporting a bypass or vulnerability

**Please report privately** through GitHub Security Advisories:
[github.com/0xdak/warden/security/advisories/new](https://github.com/0xdak/warden/security/advisories/new)
("Report a vulnerability" on the Security tab). Don't open a public issue for a working bypass.

**Bypass reports are welcome and are the most valuable contribution you can make.** A bypass is any way for an
agent to do something a Warden rule should catch, without Warden blocking or asking, for example:

- reading a secret file (`.env`, `~/.ssh/*`, `~/.aws/credentials`, …) through a path, alias, symlink, glob,
  variable, encoding or interpreter trick that the rules miss;
- deleting home, system or `.git` folders, or files outside the project, without being blocked or asked;
- download-and-run, decode-and-run or exfiltration that slips through;
- disabling or editing Warden's own hooks or settings from inside an agent;
- making the hook crash, hang past the agent's timeout, or return "allow" on input it should reject;
- anything in the app or the hook↔app socket that lets another local process approve actions.

Please include:

1. The agent and version (e.g. Claude Code 2.x, Codex CLI 0.x) and Warden version.
2. The exact command or tool call, or the hook JSON. The output of `warden-hook --agent <agent> --explain` with that
   JSON is ideal.
3. What you expected (block / ask) and what happened.
4. Preset (Strict / Balanced / Permissive) and mode (observe / enforce).

Please use dummy secrets in reports.

## What to expect

- Acknowledgement within a few days.
- Fixes ship as a self-test case plus a rule change, credited to you in the release notes unless you prefer otherwise.
- We'll coordinate disclosure with you; most bypass fixes are small and ship quickly.

## Out of scope

These are documented limitations rather than vulnerabilities (see the README's "Limitations"):

- Actions an agent performs without calling its hooks (hooks disabled, untrusted Codex hook, Cline hook switched off,
  vendor-hosted tools, agent bugs that skip hooks). Reports showing a *specific* agent path that skips hooks are still
  useful; we'll document them and tell the vendor.
- What a script does after an allowed command starts it (`python build.py`).
- Deletes inside the project or under temp folders, which are allowed by design.
- Anything that requires the attacker to already run arbitrary code as your user outside an agent.

## Supported versions

Only the latest release receives fixes.
