# Behavior test isolation

`tests/run.sh` is the authoritative entry point for every `tests/*.test.sh` behavior test.
The no-mistakes test command, CI, documented local commands, focused test execution, and direct `bash tests/<subject>.test.sh` execution all cross that runner.
Every test sources `tests/test-entry.sh` in its header, so direct execution re-enters the runner before the test body.

`tests/test-capabilities.tsv` declares exactly one lifecycle capability for every behavior test.
`hermetic` means the test cannot reach a real Herdr lifecycle.
`herdr-lab` means the runner must establish an owned, named, never-default Herdr lab before the test starts.
`herdr-mixed` means the complete test requires that same lab, while the explicit non-Herdr path still runs its hermetic assertions.
An added, removed, undeclared, duplicate, or incorrectly wired test makes admission fail with exit 97.

Before provisioning any lab, the runner verifies the complete registry and statically refuses raw Herdr server or session lifecycle commands.
For each admitted `herdr-lab` or `herdr-mixed` test on the complete path, it creates a unique session through `bin/fm-herdr-lab.sh`, installs cleanup before preparation, provisions through that helper, and binds the test to the exact session.
`tests/herdr-guard-bin/herdr` then routes non-lifecycle Herdr calls through the same helper and rejects raw server/session lifecycle or any foreign/default session selector at command execution.
The only permitted lifecycle helpers inside a real-Herdr test are the wrappers in `tests/herdr-test-safety.sh`.

Each test runs in an owned process group.
After the test exits, the runner reaps only processes still carrying that exact group identity.
After a real-Herdr test exits, the runner tears down only its exact named lab through `bin/fm-herdr-lab.sh`, whose default-session metadata, workspace/tab/pane topology, and agent identities must remain identical.
No cleanup path enumerates and kills fleet panes, adopts an existing session, or targets the default session.

The tripwire detects default server/session changes, removed or replaced fleet panes, and removed or replaced agent identities, including losses while the default server remains running.
It intentionally ignores volatile agent status and focus/activity fields, so normal work can continue during a lab test; it cannot prove preservation of pane contents or process internals that Herdr's read APIs do not expose.

Use `tests/run.sh --skip-herdr` for the explicit non-Herdr path.
That option reports each skipped `herdr-lab` test, runs every `hermetic` test normally, and runs only the hermetic assertions in each `herdr-mixed` test.
CI selects the same path explicitly with `FM_TEST_SKIP_HERDR=1` on each sealed shard command because its disposable image does not provide Herdr.
The no-mistakes test command does not skip: it requires every declared real-Herdr test to prove an owned lab or fail closed.
