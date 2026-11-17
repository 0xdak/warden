---
title: How to stop Claude Code from reading your .env file
description: Deny rules stop Claude Code's file tools, but not a plain cat in the shell. Here is a setup that covers both, with a tested hook script you can copy.
date: 2026-11-08
slug: stop-claude-code-reading-env
tags: claude code, secrets, hooks
---

Ask Claude Code to fix a failing test and one of the first things it may do is look at your project's configuration. In a lot of projects that includes `.env`. The moment it reads that file, your database password and API keys are part of the conversation: they're sent to the model as context, and they're written into the session transcript on your disk.

Usually nothing bad happens next. But "usually" is a weak guarantee for production credentials. This guide sets up three layers, from the quickest to the most thorough.

## Why one setting isn't enough

Claude Code can reach a file in more than one way:

- the **Read** tool, which opens a file by path;
- the **Grep** tool, which searches file contents;
- the **Bash** tool, where `cat .env`, `source .env`, `grep KEY .env` or a one-line Python script all read the same bytes.

Permission rules for `Read(...)` are matched against Claude Code's file tools. A shell command is a different tool (Bash), so a Read deny rule on its own isn't something to rely on for `cat .env`. You need something that looks inside shell commands too. That's what the hook in layer 2 does.

## Layer 1: deny rules in settings

Add deny rules to your user settings at `~/.claude/settings.json`, or to a project's `.claude/settings.json` if you want them shared with your team:

```json
{
  "permissions": {
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(**/.env)",
      "Read(**/.env.*)"
    ]
  }
}
```

Path patterns follow gitignore-style matching, so `**/.env` also covers nested apps in a monorepo. Run `/permissions` inside Claude Code to see which rules are active.

Two things to know:

- Deny rules win over allow rules, so `Read(**/.env.*)` also blocks `.env.example`. If the agent needs to see your template, name it `env.example` (without the leading dot) or accept that it's hidden.
- This is a good baseline that costs nothing, and it keeps working even if a hook script breaks. Keep it even after adding layer 2.

## Layer 2: a PreToolUse hook that also checks shell commands

Hooks are programs Claude Code runs at fixed points. A `PreToolUse` hook runs before every matching tool call, receives the call as JSON on stdin, and can block it. If it exits with code **2**, the call is blocked and whatever it printed to stderr is shown to Claude as the reason.

Save this as `~/.claude/hooks/block-dotenv.sh`. It needs `jq` (`brew install jq`).

```bash
#!/usr/bin/env bash
# Blocks Claude Code from reading .env files through Read, Grep or Bash.
input=$(cat)
tool=$(jq -r '.tool_name' <<<"$input")
target=$(jq -r '.tool_input.file_path // .tool_input.path // .tool_input.command // ""' <<<"$input")

# Templates are fine to read: drop them before checking.
check=$(sed -E 's/\.env\.(example|sample|template)//g' <<<"$target")

# .env, .env.local, .env.production ... anywhere in a path or command
if grep -Eq '(^|[^[:alnum:]_.-])\.env(\.[[:alnum:]_-]+)?($|[^[:alnum:]_.-])' <<<"$check"; then
  echo "Blocked by a local hook: $tool would read a .env file. Ask the user for the specific value you need instead." >&2
  exit 2
fi
exit 0
```

Make it executable:

```bash
chmod +x ~/.claude/hooks/block-dotenv.sh
```

Then register it in `~/.claude/settings.json`, next to your permissions:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Grep|Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/block-dotenv.sh" }
        ]
      }
    ]
  }
}
```

The matcher `Read|Grep|Bash` means the script only runs for those three tools. Check it's loaded with `/hooks`.

### Test it before you trust it

You can feed the script the same kind of JSON Claude Code sends, without starting a session:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"cat .env | grep STRIPE"}}' \
  | ~/.claude/hooks/block-dotenv.sh; echo "exit: $?"
```

That should print the message and `exit: 2`. Try a few more: `cat .env.example` and `npm run build` should exit 0. Note that `cp .env.example .env` is blocked too, because the command mentions `.env`. That's on purpose: it's simpler to approve that one yourself than to write a perfect parser.

### Three mistakes to avoid

- **Don't use exit code 1 to block.** In Claude Code, only exit code 2 blocks. Exit 1 and other codes are treated as a non-blocking error, and the tool call goes ahead.
- **Don't print the secret in the reason.** The stderr text goes to the model. Name the file, never its contents.
- **Say what to do instead.** "Ask the user for the specific value" gives Claude a path forward. Without it, agents tend to try another way to read the same file.

If you'd rather be asked than blocked, print JSON on stdout and exit 0 instead. A `permissionDecision` of `"ask"` makes Claude Code show its normal permission prompt with your reason attached:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "This command reads a .env file."
  }
}
```

### What this hook doesn't cover

Be clear about the gaps so they don't surprise you:

- A search across a whole folder (Grep with a directory path) isn't flagged, because the script only sees the folder name. Whether `.env` shows up in results depends on the search tool's ignore settings.
- Indirect reads slip through: a script the agent wrote earlier that opens `.env`, `python -c` with the filename built from pieces, or a tool that loads `.env` by itself (many frameworks do).
- It covers Claude Code only. Codex, Cursor, Gemini CLI and Windsurf each have their own hook systems and input formats.

## Layer 3: don't keep the secret in the file

The most reliable fix is to have less to protect. Options that work well on a Mac:

- Load secrets at run time from a password manager's command-line tool, so the project folder only holds references.
- Store long-lived keys in the macOS Keychain and read them with `security find-generic-password -w` in your start script.
- Keep only development credentials with tight scopes on your laptop. A leaked test key is a nuisance; a leaked production key is an incident.

## If the agent already read it

Assume the values were exposed. Rotate the keys that were in the file, starting with anything that touches production or billing. Then add the layers above so it doesn't happen again.

## Doing this for every agent at once

The script above is fine for one agent and one kind of file. Covering SSH keys, cloud credentials and keychain lookups, across five agents with five input formats, is where it gets tedious. That's the job {{name}} does: it installs and maintains the hooks for each agent, ships rules for secret files, and shows a popup instead of a hard block when you'd rather decide case by case.
