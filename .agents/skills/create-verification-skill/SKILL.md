---
name: create-verification-skill
description: >-
  Agent-only generator for a project-local verification skill that drives an app
  the way a user does: a lightweight control-<project> CLI plus a
  references/features/ Feature Map under the project's standard skills
  directory. Use when a project has no scripted way to prove UI/CLI/service
  behavior, or when told to "make a control skill for this repo".
  Produces zero IDE-specific dependencies.
user-invocable: false
metadata:
  internal: true
---

# Create a verification skill

Every serious project needs a scripted way to drive the real app and prove behavior: launch it, exercise a feature the way a user would, and capture evidence. This skill generates that as a project-local skill (`<project>/.agents/skills/verify-<app>/`) tailored to the repo. You write the generator's output for the next agent, not for a human: it will be read cold, mid-task, by an agent that has never seen the app.

The generated skill has two halves: an executable `control-<app>` CLI that owns every launch/drive/cleanup action, and a `references/features/` Feature Map that owns the user-POV proof recipes. Agents run the CLI; they read the map. Nothing in either half may depend on a specific IDE, editor plugin, or model-gating field: standard `SKILL.md` frontmatter (`name`, `description`) only.

## 1. Interview the repo, not the user

Answer these from the codebase and only ask the user what you cannot observe:

- **Surface:** what does a user actually touch? A web UI, a CLI/TUI, a desktop app, an API, a mobile app, a library? A repo can have several; pick the primary one and note the rest.
- **Run:** how does the app start locally? Prefer the repo's own documented dev command (package scripts, Makefile, README quickstart). Note ports, env vars, seed data, auth.
- **Drive:** how can an agent interact with it programmatically? Existing harnesses first — Playwright/Cypress specs, expect scripts, PTY helpers, curl-able endpoints, a debug port. Only then pick a generic recipe: browser/CDP for web and desktop-web surfaces, a tmux/PTY harness for CLI/TUI, plain HTTP for services.
- **Observe:** what evidence can be captured? Screenshots, terminal transcripts, response bodies, logs, exit codes, DB state.
- **Isolate:** can two instances run side by side (ports, data dirs, profiles)? If not, say so in the generated skill: refusing to double-drive a shared instance beats corrupting the user's session.

If the checkout doesn't build or start as-is, fix that first (or report it precisely) before generating; a skill written against a broken base teaches wrong steps. When an irrelevant missing asset blocks startup (a static dir the API never serves, a sample config), the generated skill may create it, clearly marked as verification scaffolding, and remove it in cleanup.

## 2. Generate the control CLI

Write `<project>/.agents/skills/verify-<app>/control-<app>` (executable, no extension so it runs the same on every shell) with one subcommand per lifecycle action, each grounded in what the interview actually found (no placeholder commands left):

- `launch`: start the app for verification and block until it is ready (a log line, a port answering, a prompt). Print the instance handle (port, session name, PID file) for the other subcommands. For a short-lived CLI or TUI there is no server to keep alive: launch means build the binary (or install deps) once, then each `drive` starts its own isolated PTY or tmux session.
- `doctor`: one read-only check that answers "is this instance worth driving?" — process up, right version/build, port owned by us, auth valid. An agent runs this first whenever anything looks off.
- `drive <feature> [args...]`: exercise one mapped feature the way a user would, using real selectors/commands from this repo, not examples. Prefer stable handles (ARIA labels, data attributes, prompt strings, route paths) over coordinates and tab order.
- `evidence <dir>`: collect the proof for the last drive into the named directory — the action plus the resulting state, not just the final screen; side effects (files written, rows inserted, messages sent) alongside what is visible. State the proof standards in the skill body: exercise the real user path, not internal setters or test-only endpoints; mocks only where a production boundary already isolates the external system. When the safe path is a dry-run or test mode, verify what it actually skips by observing (files, network, git refs) rather than trusting its name: some dry-runs still touch the network or open a browser.
- `cleanup`: tear down instances the run created. Never kill by process name; kill what the run started. Cleanup removes instances and scratch state, never the evidence: proof artifacts survive the teardown, in a location the skill names.

Then write the sibling `SKILL.md` with standard frontmatter (`name: verify-<app>` and a `description` that names the app, the surface, and when to reach for it — without frontmatter the skill never registers) and these sections: **Launch**, **Doctor**, **Drive**, **Evidence**, **Cleanup**, each showing the exact `control-<app>` invocation for that action. A helper the reader has to reverse-engineer is not a helper: every subcommand's usage appears in the skill body.

## 3. Seed the feature map

Create `<project>/.agents/skills/verify-<app>/references/features/README.md` plus one file per user-facing feature you can identify (aim for the top 3-5 to start, from routes, commands, menus, or docs). The README is the index and links every feature file; each file answers, from the user's point of view: what the feature is, how to reach it, how to drive it with `control-<app> drive`, and what observable end state proves it works. The four H2s are `Sub-features`, `How to get to it (user POV)`, `Driving it with control-<app>`, and `Gotchas`. The map is the repo's maintained verification source; a proof that drives one convenient entry point is incomplete when the map lists others.

## 4. Prove the generated skill before handing it over

Run its own instructions end to end once: `launch`, `doctor`, `drive` ONE mapped feature (one is enough; the map exists so later runs can cover the rest), `evidence`, `cleanup`. After cleanup, confirm the evidence still exists at the named location — a cleanup that eats the proof fails this step. Fix what fails, and run the generated cleanup after every failed iteration too, so broken attempts don't strand processes and ports. A generated skill that was never executed is a draft, not a deliverable.

## 5. Offer the maintenance loop

Point the user at the `maintain-verification-skill` procedure for keeping the map honest as the app changes. Suggest a cadence only if they ask.
