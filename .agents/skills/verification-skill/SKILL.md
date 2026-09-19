---
name: verification-skill
description: >-
  Agent-only generator for a project-local verification skill that drives a project's app the way a user would.
  Load when a project's delivery gate lacks scripted behavioral proof, for example CLI tools, MATLAB pipelines, or docker/Nextflow workflows that ship no runnable behavior test.
  Owns the generated skill's required sections, feature-map seed, proof run, and shape validation.
user-invocable: false
metadata:
  internal: true
---

# verification-skill

Generate a project-local verification skill for a repository whose delivery gate has no scripted behavioral proof: no runnable behavior test that drives the real app end to end.
The generated skill lets any future agent launch the app, exercise a feature the way a user would, and capture evidence.
Typical fits are CLI tools, MATLAB pipelines, docker or Nextflow workflows, and other non-web surfaces where unit tests exist but nothing drives the real thing.
This skill writes the generator's output for the next agent, not for a human: it will be read cold, mid-task, by an agent that has never seen the app.

The generated skill is project-local content: the crewmate performing the task writes it inside the project's task worktree through the project's selected delivery path, never firstmate directly, and it lands on the project's own branch like any other project change.

## Interview the repo, not the user

Answer these from the codebase; ask the captain only what the code cannot show:

- **Surface**: what does a user actually touch - a CLI, a TUI, a MATLAB function set, a dockerized service, a Nextflow pipeline? Pick the primary one and note the rest.
- **Run**: how does it start locally? Prefer the repo's own documented command (Makefile, README quickstart, package scripts). Note env vars, input data, credentials, and compute prerequisites.
- **Drive**: how can an agent interact programmatically? Existing harnesses first; otherwise pick the generic recipe the surface needs: a PTY or tmux session for CLI/TUI, `matlab -batch` with exit codes for MATLAB, a dry-run-then-real-run on sample data for docker and Nextflow.
- **Observe**: what evidence can be captured - output files, exit codes, logs, rendered artifacts, database or state changes?
- **Isolate**: can two instances run side by side (ports, scratch dirs, run IDs)? If not, the generated skill must refuse to double-drive a shared instance rather than corrupt the user's data.

If the checkout does not build or run as-is, fix that first within the task's scope or report it precisely before generating; a skill written against a broken base teaches wrong steps.

## Generate the skill

Write `<project>/.agents/skills/verify-<app>/SKILL.md` with YAML frontmatter (`name: verify-<app>`, and a `description` naming the app, the surface, and when to reach for it) and the five required sections below, each grounded in what the interview found - no placeholders left:

- **Launch**: the exact command that starts the app for verification and how to tell it is ready (a log line, a prompt, a file appearing). Include teardown. A short-lived CLI has no server to keep alive: launch means build once, then run each drive in its own isolated session.
- **Doctor**: one read-only check that answers "is this instance worth driving?" - binary or container present, right version, input data valid, credentials loadable. Run it first whenever anything looks off.
- **Drive**: the harness recipe with real commands from this repo, not invented examples. Prefer stable handles: subcommand names, config keys, pipeline parameter names, file paths.
- **Evidence**: what to capture for a proof and where it goes. Exercise the real user path, not internal entry points or test-only shortcuts; capture the action and the resulting state, not just the final output; verify side effects (files written, rows written, artifacts produced) alongside what is visible. When the safe path is a dry-run or test mode, observe what it actually skips rather than trusting its name.
- **Cleanup**: tear down what the run created. Never kill by process name; kill what you started. Cleanup removes instances and scratch state, never the evidence; proof artifacts survive teardown at a location the skill names.
Add a **Helpers** section only when the skill ships helper scripts.
Every helper is executable and its invocation is shown in the skill body; a helper the reader must reverse-engineer is not a helper.

## Seed the feature map

Create `features/README.md` in the skill directory as the index, plus one file per user-facing feature, aiming for the top three to five from the repo's commands, entry points, or docs.
Each feature file answers, from the user's point of view, with four H2 sections: `Sub-features`, `How to get to it (user POV)`, `Driving it with <harness>`, and `Gotchas`.
The map is the project's maintained verification source; a proof that drives one convenient entry point is incomplete while the map lists others.

## Validate the shape

Run `bin/fm-verification-skill-check.sh <skill-directory>` from the firstmate repo root against the generated directory and fix every failure it reports.
It is the single owner of the generated skill's shape contract.

## Prove it before handing it over

Run the generated skill's own instructions end to end once: launch, doctor, drive one mapped feature (one is enough; the map exists so later runs cover the rest), capture evidence, clean up.
After cleanup, confirm the evidence still exists at the named location - a cleanup that eats the proof fails this step.
Run the cleanup after every failed iteration too, so broken attempts do not strand processes, containers, or scratch data.
A generated skill that was never executed is a draft, not a deliverable.

## Keep it honest

Point the project at the feature map as its maintained verification source: when the app changes, update the affected feature file in the same task that changes the behavior.
