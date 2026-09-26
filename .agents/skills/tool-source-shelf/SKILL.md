---
name: tool-source-shelf
description: Agent-only pointer to the Kun Cheng (kunchenguid) source shelf. Load before reading, inspecting, or patching the source behind a live axi, no-mistakes, or treehouse tool, before drawing on a capability repo (kun, compact-adviser, grok-ship, gnhf, backpass, vision), or before deciding anything about Pi context compaction.
user-invocable: false
metadata:
  internal: true
---

# tool-source-shelf

A home may keep Firstmate's tooling and several capability repos cloned as source on a local shelf, off the system disk.
Home-local clone paths, where this home has them, are recorded in `data/learnings.md`.

`KUNCHENGUID_REPOS.md` on that shelf is the index for the Kun Cheng (kunchenguid) repos and owns their list, the clone rationale, the Jev ranking that puts `kun` first, and what was deliberately skipped.
Read it for which Kun Cheng repos are on the shelf rather than any list held here; it is not a full inventory of the shelf root, which also holds unrelated clones.

## Invoke the PATH binary, read the clone

Firstmate's live tools - the axi family, `no-mistakes`, `treehouse` - run from their installed binaries on `PATH`.
A shelf clone of one of those is source to read, inspect, or patch, never a second install: do not run one out of its clone, and do not reinstall it from the clone.
The shelf's capability repos are not installed binaries at all; read them as source when the work calls for their capability.

## Context compaction: two facts that must not be confused

`compact-adviser` sources its compact hints from Jev; Grok is hint-only there.
`pi-openai-server-compaction` is OpenAI compaction, not Jev; it targets Pi 0.80.x and must not be pi-installed on this fleet's Pi, which is 0.86 or later.
Neither fact depends on a local clone.
