# Context Atlas experiment

Context Atlas is an optional Pi prototype for finding allowed repository files and configured tools through one compact catalog.
It is not a replacement for Firstmate's existing tools or an automatic optimization.
Nothing loads it during ordinary primary, worker, or secondmate startup.

## Trying it

Use the explicit-load instructions in [`bin/context-atlas.ts`](../bin/context-atlas.ts), then its `/atlas-help` command for the operation contract, flags, and limits.
No package installation or persistent settings change is needed.
Use a selected Git repository root, not a subdirectory or a filesystem-wide root.
Additional exclusions can narrow that selection.

The initial catalog contains metadata, not file contents.
After acquiring a snapshot, reading a uniquely matching file query can avoid a separate discovery call without silently selecting newly added files.
Reading eligible text requires separate explicit authorization for Atlas's local reader.
If your environment has restrictions attached specifically to the original `read` tool, do not enable Atlas reads until those restrictions also authorize the new tool.
Hidden, ignored, private, credential, dependency, and build paths are excluded conservatively, but this is not a secret scanner or an operating-system sandbox.
Secrets disguised as ordinary source files and hostile concurrent filesystem writers are outside its protection.

Tool resolution does not invoke arbitrary tools.
Optional deferral only hides originally active Pi built-in read-only tools; selecting one makes the original tool available for the model's next call, with its original schema and execution checks.
Mutation, publication, credential, lifecycle, and merge operations remain with their existing owners.
The prototype does not alter those tools or grant authority through a handle.
The restore command and normal shutdown restore unchanged deferred definitions without removing other active tools.
Do not combine deferral with another extension that independently manages the same active-tool selection.

## What the exploration establishes

The [measurement record](verification/context-atlas.md) compares broad discovery, focused discovery, already-known tools, and Pi's default tool set.
The experiment reduces initial schema bytes when several read-only tools can be deferred, with a smaller measured saving for the default four-tool set.
A two-file flow also avoids one separate discovery call by reusing its snapshot, but a focused native file lookup still returns fewer bytes than Atlas's structured results.
No token-billing, provider-cache, model-reasoning, or production latency improvement is claimed.
Keep it optional unless measurements on your actual workflow justify it.

The [design owner](context-atlas-design.md) records the public API boundary, identity and freshness model, and verification entry points.
