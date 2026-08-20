# First Mate Lite verification

This page records the repeatable maintainer verification for First Mate Lite's standalone clean-environment workflow.
The behavior regression is `tests/fm-lite.test.sh`, and `bin/fm-test-run.sh tests/fm-lite.test.sh` is the current refresh command.

## Clean-environment walkthrough

Verified on 2026-08-20 with Git 2.39.5 and Bash 5.2.15 on Linux.
The walkthrough provides an empty `HOME`, an empty `XDG_DATA_HOME`, and a sentinel `FM_HOME` that must remain untouched.
It installs only the standalone CLI, registers a repository, creates a native Git worktree and brief, commits an implementation with its context, proves cleanup preserves dirty, ignored, and unmerged work, merges it into the registered clone, and safely cleans the worktree and feature branch.

Run:

```sh
tests/fm-lite.test.sh
```

Expected pass lines:

```text
ok - fm-lite installs as one standalone executable
ok - fm-lite registers existing and URL-cloned repositories in XDG data
ok - fm-lite creates an isolated worktree and complete task context
ok - fm-lite cleanup refuses dirty, ignored, and unmerged task work
ok - fm-lite carries context through the feature merge and cleans safely
ok - fm-lite validates its intentionally small command surface
# all fm-lite tests passed
```

The same test asserts that the sentinel `FM_HOME` is byte-for-byte unchanged throughout the workflow.
That is the active regression for Lite's zero runtime coupling to full Firstmate.
