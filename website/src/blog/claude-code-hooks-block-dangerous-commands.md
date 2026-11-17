---
title: "Claude Code hooks explained: block dangerous commands before they run"
description: What hooks are, which events matter for safety, how matchers and exit codes work, and a tested script that stops rm -rf on your home folder, curl-pipe-to-shell and force pushes.
date: 2026-11-10
slug: claude-code-hooks-block-dangerous-commands
tags: claude code, hooks, shell
---

Claude Code's permission prompts ask a broad question: may I run this command? Hooks let you ask a narrower one: is *this particular* command something I ever want to happen? This guide explains how hooks work and builds a small blocker for the shell commands that are hardest to undo.

## What a hook is

A hook is a handler that Claude Code runs automatically at a specific point in a session. Most hooks are shell commands. Claude Code sends them a JSON description of what's happening on stdin, and reads their exit code and output to decide what to do next.

Hooks are configured in settings files, and hooks from every level are merged:

| File | Scope |
| --- | --- |
| `~/.claude/settings.json` | You, in every project |
| `.claude/settings.json` | One project, committed and shared |
| `.claude/settings.local.json` | One project, just you |
| Managed policy settings | Set by an administrator |

Plugins, skills and subagents can bring their own hooks too. Type `/hooks` in Claude Code to see everything that's active.

## The events that matter for safety

Claude Code has many hook events. For security, a handful do most of the work:

- **PreToolUse** runs before any tool call: Bash, Read, Write, Edit, Grep, Glob, WebFetch and MCP tools. It can allow, deny, ask or change the input. This is the main checkpoint.
- **PermissionRequest** runs when Claude Code is about to show you a permission prompt, and can answer it for you.
- **PostToolUse** runs after a tool finished. It can't undo the action, but it can flag the result or replace what Claude sees, which is useful for redacting a secret that showed up in output.
- **UserPromptSubmit** runs when you send a prompt, before Claude sees it. Handy for catching a key you pasted by accident.
- **SessionStart** and **ConfigChange** are good places to check that settings haven't been loosened.

## Matchers: which tools a hook runs for

Each hook entry has a `matcher` that is compared against the tool name:

- `"*"`, an empty string, or no matcher at all means every tool.
- Plain names, optionally separated by `|`, are exact matches: `"Bash"`, `"Edit|Write"`.
- Anything else is treated as a regular expression, for example `"mcp__.*"` for every MCP tool.

## What your hook receives

On stdin, every hook gets common fields such as `session_id`, `cwd`, `hook_event_name` and `permission_mode`. A PreToolUse hook also gets `tool_name` and `tool_input`. For Bash, `tool_input.command` is the full command string. For Read, `tool_input.file_path` is an absolute path. For Edit and Write you get the path and the new content.

## How a hook says no

There are two ways, and one trap.

**Exit code 2.** The call is blocked and whatever you printed on stderr is given to Claude as the reason. Simple and hard to get wrong.

**JSON on stdout, exit code 0.** Gives you more choices:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Force pushes are blocked on this machine."
  }
}
```

`permissionDecision` can be `"deny"`, `"ask"` (show the normal prompt with your reason), or `"allow"` (skip the prompt). When several hooks answer the same call, the most restrictive answer wins, so a deny from one hook can't be overruled by an allow from another.

**The trap: exit code 1 doesn't block.** Any exit code other than 0 and 2 is treated as a non-blocking error, and the tool call goes ahead. A script that crashes, or that uses `exit 1` to mean "no", lets everything through. Test your failure paths.

Hooks have a default timeout of 600 seconds, which you can lower per handler with `timeout`. Hooks that match the same event run in parallel.

## A blocker for commands you can't take back

This script handles three classic disasters. It denies `rm -rf` aimed at `/`, `~` or `$HOME`, and anything downloaded with `curl` or `wget` and piped into a shell. It asks before force pushes and pushes straight to `main` or `master`. Save it as `~/.claude/hooks/guard-bash.sh` (needs `jq`):

```bash
#!/usr/bin/env bash
# PreToolUse hook for Bash: deny a few commands that are hard to undo.
cmd=$(jq -r '.tool_input.command // ""')

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}
ask() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}

# rm with -r or -f aimed at /, ~ or $HOME
if grep -Eq '(^|[;&|[:space:]])rm[[:space:]]+(-[[:alpha:]]*[rRf][[:alpha:]]*[[:space:]]+)+(/|~|\$HOME)(/?[[:space:]]|/?$)' <<<"$cmd"; then
  deny "rm -rf on the root or home folder is blocked. Delete specific paths inside the project instead."
fi
# anything downloaded and piped into a shell
if grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|python3?)([[:space:]]|$)' <<<"$cmd"; then
  deny "Piping a downloaded script into a shell is blocked. Download it to a file so the user can read it first."
fi
# force pushes and pushes to main/master
if grep -Eq 'git[[:space:]]+push.*([[:space:]]--force([[:space:]]|=|$)|[[:space:]]-f([[:space:]]|$)|--force-with-lease)' <<<"$cmd" \
   || grep -Eq 'git[[:space:]]+push[[:space:]]+[^[:space:]]+[[:space:]]+(HEAD:)?(main|master)([[:space:]]|$)' <<<"$cmd"; then
  ask "This push rewrites or updates a protected branch. Confirm it is intended."
fi
exit 0
```

Register it for Bash only:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/guard-bash.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

Run `chmod +x ~/.claude/hooks/guard-bash.sh`, then test it by hand:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf ~/ build/"}}' \
  | ~/.claude/hooks/guard-bash.sh
```

You should get a JSON object with `"permissionDecision": "deny"`. That example matters: `rm -rf ~/ build/` is a one-character typo away from `rm -rf ~/build/`, and it deletes your home folder. `rm -rf ./build` and `rm -rf ~/code/app/build` pass, as they should.

## Where pattern matching runs out

A regular expression reads the command as text. It doesn't run it. So these get through a script like this one:

- `bash cleanup.sh`, where the dangerous line is inside a file the agent wrote a minute ago;
- `python -c "import shutil; shutil.rmtree(...)"`;
- commands put together from variables, `eval`, or base64.

A shell lexer that splits pipelines and resolves paths catches a lot more than a single regex, and that's worth building if you rely on this. But no hook sees inside a program it hasn't read. For work you really don't trust, pair hooks with a container or VM.

## Protect the hooks themselves

Two settings can quietly undo all of this. `disableAllHooks: true` in any settings file switches every hook off, and an agent with Edit access could write it. Consider a second PreToolUse rule that denies Edit and Write on `~/.claude/settings.json` and `.claude/settings*.json`. Also review hooks in shared project settings before you trust a repo: a hook is a command that runs with your permissions.

## The short version

- Use **PreToolUse** with a tight **matcher**.
- Block with **exit 2** or a JSON **deny**. Never rely on exit 1.
- Return a reason that tells the agent what to do instead.
- Test with hand-written JSON before trusting it.
- Treat pattern rules as a seatbelt, not a cage.

If you want this across Claude Code, Codex, Cursor, Gemini CLI and Windsurf without keeping five sets of scripts in sync, that's what {{name}} does: it installs and maintains the hooks, parses commands properly and asks you in one popup.
