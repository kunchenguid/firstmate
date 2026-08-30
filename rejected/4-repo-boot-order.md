why: claude visible arm B did not beat arm A by 2+ (claude vis A=0 B=0; codex vis A=0 B=4 loaded=yes); claude never auto-loaded the skill (loaded=no on every claude B case); held-out flipped on codex (A=0 B=2) but not claude (A=0 B=0)

```
---
name: repo-boot-order
description: When about to run the first repository command, apply the required session-start ordering before any other command.
---

# Session-start ordering

The first repository command of a session must be the command named fm-session-start.

## Procedure

1. Invoke fm-session-start before any other repository command.
2. After it exits 0, run the commands the task requires.

## Do not

- Skip this command because the task looks small.
- Invent a substitute name.
- Run other repository commands first and then backfill it.
```
