---
name: firstmate-desktop
description: >-
  Automatically run non-trivial repository implementation, continuation, debugging, review, and autonomous multi-step work through the user's Firstmate fleet inside Codex Desktop.
  Use when the user names Firstmate, asks to continue or work autonomously on a codebase, requests delegated or parallel engineering work, or expects Codex Desktop to manage project discovery, isolated workers, supervision, validation, and safe result retention without manual Firstmate setup.
  Do not use for trivial questions or one-line edits that need no orchestration.
metadata:
  internal: true
---

# Firstmate Desktop

Resolve `FIRSTMATE_CODE` from the active selected skill before any project operation.
Use the Git top level containing this `SKILL.md`, or the installation-owned `FM_ROOT_OVERRIDE` only when it resolves to that same tracked Firstmate repository and contains `bin/fm-desktop-entry.sh`.
Refuse when no tracked Firstmate code root can be proven from those installation-owned inputs.
The captain states the outcome; the Desktop primary owns orchestration mechanics.

1. Read the full Firstmate `AGENTS.md` and obey it.
2. Read the full internal skills required by the request, always including:
   - `.agents/skills/firstmate-codexapp/SKILL.md` for Desktop lifecycle;
   - `.agents/skills/firstmate-development-loop/SKILL.md` for implementation.
3. Before starting a session, run the installed read-only entry router:

   ```sh
   "$FIRSTMATE_CODE/bin/fm-desktop-entry.sh"
   ```

   When it prints `mode=coordinator`, do not run `fm-session-start.sh` in the
   current repository task and do not substitute built-in subagents.
   Follow `firstmate-codexapp`'s cross-project entry procedure to create one
   visible Firstmate coordinator in a Desktop-owned Firstmate worktree, pass it
   the complete request and exact source project, then wait for and relay its
   result.
   When it prints `mode=direct`, use the reported `firstmate_code` and
   `session_home` for this operation.
4. In the direct Firstmate coordinator, start `bin/fm-session-start.sh` exactly once in a tracked PTY with `FM_HOME` set to the reported session home and keep its Desktop thread-bound lease live.
   If another live session owns that home, remain read-only and report that exact conflict.
5. Use Codex Desktop host tools automatically for visible ship/scout tasks.
   The primary lists projects, opens a known exact local checkout in Codex when it is not yet registered, creates isolated worktrees, registers exact task identity with `bin/fm-codex-app-task.sh`, supervises through wait/read, and reconciles Firstmate state.
   Never ask the captain to perform these routine mechanics.
6. Keep one writer for ship work.
   Use scouts only when the task genuinely benefits from independent bounded evidence.
   Preserve project instructions, dirty state, delivery authority, credential boundaries, and external-side-effect restrictions.
7. Before archive, run `bin/fm-codex-app-task.sh archive-preflight`.
   Archive a completed scout only after its report is retained outside its Desktop worktree.
   Retain ship tasks until their result is independently landed or the captain explicitly authorizes discard; Desktop archive deletes the app-owned worktree.
8. Translate mechanics into concise outcome/status language.
   Ask the captain only for a real login/permission, destructive or external action, or a product decision that cannot be inferred safely.

Do not install Firstmate into the target product.
Firstmate orchestrates work on repositories; it is not an application dependency of Hermes or any other project.
