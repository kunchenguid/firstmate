# Primary-session project-write guard

This document owns the contract for the primary-session project-write PreToolUse guard.
`bin/fm-project-write-command-policy.mjs` owns classification and reuses `Lexer`, `splitProgram`, and `commandPosition` from `bin/fm-arm-command-policy.mjs`.
`bin/fm-project-write-pretool-check.sh` owns primary-checkout scoping, hook transport, and deny rendering.

## Purpose and scope

The guard enforces hard rule 1 in [`AGENTS.md`](../AGENTS.md) at the moment the primary firstmate attempts to change a project clone or worker copy.
It covers every directory under `FM_HOME/projects/` and `FM_ROOT/projects/`, plus absolute worktree paths read from `worktree=` fields in `state/*.meta`.

The guard runs only in a plain firstmate checkout where git-dir equals git-common-dir and the checkout has `AGENTS.md` and `bin/`.

It is inert in linked crew and scout worktrees, so worker sessions are not affected.
The Pi supervision branch uses the same Pi tool-call hook and policy when it runs tools through that extension.

The guard blocks state-changing Git commands aimed at a protected path, including fetch, pull, commit, checkout, switch, reset, restore, stash, merge, rebase, push, clean, tag creation, branch deletion, am, cherry-pick, clone destinations, init paths, worktree destinations, and submodule additions.
Unknown Git subcommands aimed at a protected path are blocked unless they are explicitly classified as read-only.
Read-only commands including status, log, diff, show, and rev-parse remain allowed, including with `git -C <dir>`.

The guard also blocks shell file changes aimed at protected paths, including rm, mv, cp into a protected path, output redirection (including `&>` and `>|`), tee, combined in-place `sed`/`perl` options, `patch` diffs whose target headers are protected (or cannot be inspected), `dd of=`, and `find` deletion or write-bearing `-exec`/`-execdir` actions.
It resolves simple prior shell assignments when checking file destinations and Git routing.
Git archive, checkout-index, and bundle file destinations are checked as well.
Native file-write and file-edit tools are blocked when their target path is protected.
Guarded Firstmate scripts under `bin/` remain callable because this policy classifies the submitted tool command and never inspects script internals.

A denial says the change was blocked and directs the agent to delegate the change to a worker.
For Git review, the denial directs the agent to read GitHub instead of fetching.

## Known limits

This guard reduces accidental writes; it is not a security boundary.
The following command-text forms are not currently blocked:

- Git destinations not recognized by the policy: `git apply --directory=projects/foo /tmp/change.patch`, `git format-patch -o projects/foo HEAD~1`, `git clean -ffdx -- projects/foo`, and routing through `git -c core.worktree=projects/foo checkout -- file`.
- Other shell writers: `tar -xf /tmp/change.tar -C projects/foo` and `rsync -a /tmp/tree/ projects/foo/`.
- A `PWD` expansion after modeled `cd` can still use its original value, as in `cd projects/foo; printf x > "$PWD/new.txt"`.
- Attached sed scripts such as `sed -e's/old/new/' -i projects/foo/file` are not reliably classified.
- Patch input with `--strip=1` and native patch/apply_patch unified-diff `---`/`+++` headers are not reliably classified.

The original explicit-approval-exception criterion was withdrawn; this guard has no approval bypass for protected writes it recognizes, including shell and native file-tool writes.
Caller-supplied text cannot establish captain approval, so delegate approved project changes it blocks to a worker.

## Harness wiring

The project-write checker is registered beside the cd guard for Claude, Codex, Grok, OpenCode, Pi, omp, and Cursor.
Claude, Codex, Grok, and Cursor register the checker for all PreToolUse tools so native file tools are covered as well as shell commands.
OpenCode, Pi, and omp forward each tool's name and input through their existing primary hook surface.
The checker renders the denial in the format expected by each adapter.

## Validation

`tests/fm-project-write-pretool-check.test.sh` owns the portable acceptance matrix for Git mutations and reads, Git routing through cwd/options/environment/simple assignments, shell writes, recorded worktree paths, native file tools, worker-worktree inertness, and hook wiring parity.

Run:

```sh
bash -n bin/fm-project-write-pretool-check.sh
shellcheck bin/fm-project-write-pretool-check.sh tests/fm-project-write-pretool-check.test.sh
node --check bin/fm-project-write-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-project-write-pretool-check.test.sh
```

The portable test proves policy behavior and executes the configured all-tool commands for Claude, Codex, Cursor, and Grok, alongside OpenCode plugin behavior, without launching vendor harnesses.
The prompt-submitting real-harness guard is opt-in and runs with `FM_PROJECT_WRITE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-project-write-pretool-check.test.sh tests/fm-project-write-live-e2e.test.sh`.
It records disposable-fixture checker inputs and results, then requires the requested operation and an actual checker denial rather than model-written prose.
The dated Claude, Codex, and Pi results, along with adapters not installed during verification, are recorded in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md#primary-project-write-pretooluse-guard).
