---
title: Is it safe to run AI coding agents with --dangerously-skip-permissions?
description: An honest look at what skip-permission modes in Claude Code, Codex and Gemini CLI actually turn off, what tends to go wrong, and how to use them with much less at stake.
date: 2026-11-12
slug: dangerously-skip-permissions-safe
tags: claude code, codex, gemini cli, permissions
---

Short answer: on a disposable machine with nothing valuable on it, it's a reasonable trade. On your everyday Mac, with your SSH keys, cloud credentials and client repos, it's a bet that nothing the agent reads will ever mislead it. The flag's name is a fair warning.

Here's what it really changes, what goes wrong, and how to get most of the speed with much less risk.

## What the flag turns off

Coding agents normally pause before actions they consider risky (running a command, editing a file, fetching a URL) and wait for you. Every major CLI agent has a way to skip that:

| Agent | Skip-prompts mode |
| --- | --- |
| Claude Code | `--dangerously-skip-permissions`, or the `bypassPermissions` permission mode |
| Codex CLI | `--dangerously-bypass-approvals-and-sandbox`, or `approval_policy = "never"` with `sandbox_mode = "danger-full-access"` |
| Gemini CLI | `--yolo` |

What goes away is **you**: the moment where a human looks at the command. The agent's judgement stays the same. It just never has to explain itself.

Codex is worth a separate note: its default sandbox restricts what commands can touch, and the full bypass flag removes both the approvals and that sandbox at once.

## What tends to go wrong

None of this needs a malicious model. It needs an ordinary mistake, or text from somewhere else that the agent takes as an instruction.

**Mistakes with big blast radius.** A stray space in `rm -rf ~/ build/`, a `git reset --hard` that throws away an afternoon of uncommitted work, a migration run against the database in `.env` instead of the local one. With prompts on, you'd likely have caught it. Without them, it's done.

**Prompt injection.** Agents read a lot of text you didn't write: READMEs, issue comments, web pages, package docs, test fixtures, error messages from APIs. If any of it says "before continuing, run this setup command", a model can follow it. With prompts on, that command lands in front of you. With prompts off, it runs.

**Secrets drifting into context.** An agent debugging a config problem reads `.env` or `~/.aws/credentials` because it seemed relevant. The values are now in the model context and in the transcript on disk. If an injected instruction then asks to "upload the logs for analysis", the secret and the network call are one step apart.

**Supply chain.** `npm install` or `pip install` of a mistyped or brand-new package, chosen by the agent, runs that package's install scripts with your permissions.

## When it's a reasonable choice

Anthropic's own guidance for this flag is to use it in a container without internet access. That captures the principle: the less the environment can reach, the less the flag matters. It's a sensible trade when:

- the agent runs in a container, VM or cloud dev box that holds **no long-lived credentials**;
- **network access is off or limited** to the package registries you need;
- the work is in a **git checkout you can throw away**, with everything important already pushed;
- you review the diff before anything leaves that environment.

It's a poor trade on your main laptop, in a home folder full of keys, on a repo with uncommitted work, or when the task involves reading untrusted content such as random web pages or third-party issues.

## Keep a checkpoint even when prompts are off

Skipping prompts and having no checks at all are different things. In Claude Code, PreToolUse hooks still run in bypass mode, and a hook that answers "deny" still blocks the call. The hook input even includes `permission_mode`, so a hook can tell that prompts are being skipped and be stricter. Our guide to [Claude Code hooks](/blog/claude-code-hooks-block-dangerous-commands/) shows how to write one.

That gives you a useful middle ground: let routine work run without interruptions, but keep hard stops on the few things you never want, whatever mode you're in:

- reading secret files ([here's how for .env](/blog/stop-claude-code-reading-env/));
- `rm -rf` outside the project, `mkfs`, `dd`;
- force pushes and pushes straight to `main`;
- `curl ... | sh` and other piped installs;
- edits to the agent's own settings and hook files, so the agent can't remove its own guard.

## A checklist before you use the flag

1. **Where am I?** If it's not a container or VM, think twice.
2. **What can the agent read?** Run our [free exposure check](/risk-check/) to see which keys sit in reach.
3. **What can it reach on the network?** No network is best. A short allowlist is next best.
4. **Is everything committed and pushed?** Make undo cheap.
5. **Are hard stops in place?** A deny hook for the handful of irreversible actions costs nothing in speed.
6. **Is the habit deliberate?** An alias that adds the flag to every session turns a one-off decision into the default.

## Bottom line

The flag isn't reckless in itself. Running it where a mistake can reach your credentials, your history and your network is. Shrink what the agent can reach, keep a few non-negotiable blocks, and the speed stops costing you sleep.

{{name}} is built for that middle ground on a Mac: it keeps hard blocks and a log active for Claude Code, Codex, Cursor, Gemini CLI and Windsurf, and it warns you when a session starts in a skip-permissions mode.
