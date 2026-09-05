# Test gate attribution: issue 3748

Recorded 2026-09-05T03:54:39+00:00.

## Outcome

Blocked by two pre-existing test fixture/platform failures; no in-scope source fix was found or applied.
The six previously failing suites were retried through the registered runner using explicit suite selection: four passed, two failed, and none skipped.
Both changed suites passed separately.
This is a failed Test result, not approval or a skip; the outer executor retains the gate and CI.

## Scope and environment

- Worktree HEAD: `551165d2bbf195a3ed780938cf186a36c97a4e22`.
- Pristine baseline: `origin/main` at `8f7b79c77c2198a71a01082215227a64500015e3`, also the supplied base commit.
- Baseline material came from `git archive --format=tar origin/main` into `.test-gate-scratch/main` inside this worktree.
  A local Git repository and index were initialized in the export with `git -c init.templateDir= init -q` and `git add .`; no checkout or commit was performed.
  All 499 tracked modes and blob IDs matched `origin/main`, and the export remained unmodified after its tests.
- Bash: `/bin/bash`, GNU Bash `3.2.57(1)-release (arm64-apple-darwin25)`; the only Bash executable found on the command PATH.
  No Bash was present at `/opt/homebrew/bin/bash`, `/opt/homebrew/opt/bash/bin/bash`, or `/usr/local/bin/bash`.
- Python: `/Users/tiago/.pyenv/versions/3.12.14/bin/python3`, version `3.12.14`; `import tomllib` succeeded.
- Muse is absent (`shutil.which('muse')` returned `None`).
- The retry inherited the repaired environment without Git configuration overrides, package installs, daemon restarts, or shared-state repairs.
  The crew-state, Grok, and runner fixture commits now succeeded without GPG errors; Kimi's TOML tests passed.
- Configured baseline command: `bin/fm-test-run.sh --changed --exclude-family real-herdr-gated`.
  It was narrowed to the exact previously failing suites plus the two changed suites, following this phase's targeted-verification rule and prohibition on lint/static analysis.
  The broader changed-family selection includes lint and static-check suites, so it was not rerun or represented as passing.
  No full repository suite was run.

## Remaining failures

| Suite / exact assertion | Target | Pristine main | Cause class |
| --- | --- | --- | --- |
| `tests/fm-composer-lib.test.sh`, `test_matrix_herdr_halfblock_rule_bounds_bare_wrap`: `a half-block rule row must count as a structural edge` | Exit 1 | Identical assertion, exit 1 | Tool capability absent: the existing fixture requires Unicode escape decoding that installed Bash 3.2 does not provide. |
| `tests/fm-muse-harness.test.sh`, `test_detects_versioned_process_ancestor`: `fm-harness.sh under process 'muse-bin-0.1.0-R708.1' reported '', expected muse` | Exit 1 | Identical assertion, exit 1 | Genuine pre-existing fixture/platform failure: the copied Bash executable receives SIGKILL before executing its child command. |

### Composer causal evidence

The suite constructs its rule with Bash's `printf '\u2580\u2580\u2580'` and also uses Unicode escapes in `$'...'` fixtures.
Under `/bin/bash`, `printf '\u2580' | od -An -tx1` produced `5c 75 32 35 38 30`, the literal escape text rather than UTF-8 block-glyph bytes.
Sourcing the same `bin/fm-composer-lib.sh` and calling `fm_composer_row_has_edge " ▀▀▀"` returned 0.
Thus the first failed assertion receives the wrong fixture bytes; the real half-block glyph is recognized without any production change.
The matching test and composer code are unchanged by this contribution.
A compatible installed Bash was not found for a command-local retry; installing one or repairing this unrelated fixture is outside this phase's authorization.

### Muse causal evidence

The failing test supplies its own Muse process by copying `$(command -v bash)` into a file named `muse-bin-0.1.0-R708.1`; it does not require an installed Muse executable to reach this assertion.
A separate probe copied `/bin/bash` inside `.test-gate-scratch` using `cp`, then invoked it with `-c 'printf "child-entered\n"'` through Python `subprocess.run`.
The original `/bin/bash` returned 0 and printed `child-entered`; the copy returned -9 (SIGKILL), with empty stdout and stderr.
A versioned `muse-bin-0.1.0-R708.1` copy also returned -9 before printing a trivial message.
This establishes failure before harness detection runs; the test's command substitution receives empty output and reports the assertion above.
The precise OS mechanism issuing SIGKILL was not established, so this evidence does not assert a signing-policy diagnosis or a product Muse-detection regression.
Muse's absence is a separate machine fact and does not explain this fake-process assertion.
Changing the fixture, installing tools, or changing system execution policy is outside issue 3748's scope.

## Commands and observed results

### Retry of the six reported failures

```sh
bin/fm-test-run.sh tests/fm-composer-lib.test.sh tests/fm-crew-state.test.sh tests/fm-grok-harness.test.sh tests/fm-muse-harness.test.sh tests/fm-kimi-harness.test.sh tests/fm-test-run.test.sh
```

Runner exit: 1.

```text
FM_TEST_BEGIN 2026-09-05T03:50:45Z tests/fm-composer-lib.test.sh family=pure-contract-unit expected_gate_skip=none
FM_TEST_BEGIN 2026-09-05T03:50:45Z tests/fm-crew-state.test.sh family=pure-contract-unit expected_gate_skip=none
FM_TEST_BEGIN 2026-09-05T03:50:45Z tests/fm-grok-harness.test.sh family=pure-contract-unit expected_gate_skip=none
FM_TEST_BEGIN 2026-09-05T03:50:45Z tests/fm-test-run.test.sh family=pure-contract-unit expected_gate_skip=none
not ok - a half-block rule row must count as a structural edge
FM_TEST_END 2026-09-05T03:50:46Z tests/fm-composer-lib.test.sh exit=1 duration_ms=1115 gate_skip=false
FM_TEST_END 2026-09-05T03:50:56Z tests/fm-grok-harness.test.sh exit=0 duration_ms=11389 gate_skip=false
FM_TEST_END 2026-09-05T03:51:14Z tests/fm-crew-state.test.sh exit=0 duration_ms=28968 gate_skip=false
FM_TEST_END 2026-09-05T03:52:45Z tests/fm-test-run.test.sh exit=0 duration_ms=119875 gate_skip=false
FM_TEST_BEGIN 2026-09-05T03:52:45Z tests/fm-muse-harness.test.sh family=pure-contract-unit expected_gate_skip=none
FM_TEST_BEGIN 2026-09-05T03:52:45Z tests/fm-kimi-harness.test.sh family=pure-contract-unit expected_gate_skip=none
not ok - fm-harness.sh under process 'muse-bin-0.1.0-R708.1' reported '', expected muse
FM_TEST_END 2026-09-05T03:52:45Z tests/fm-muse-harness.test.sh exit=1 duration_ms=124 gate_skip=false
FM_TEST_END 2026-09-05T03:53:11Z tests/fm-kimi-harness.test.sh exit=0 duration_ms=26181 gate_skip=false
FM_TEST_SUMMARY total=6 failed=2 skipped_gate=0 duration_ms=146593
```

### Same remaining suites on pristine main

Run with working directory `.test-gate-scratch/main`:

```sh
bin/fm-test-run.sh tests/fm-composer-lib.test.sh tests/fm-muse-harness.test.sh
```

Runner exit: 1.

```text
FM_TEST_BEGIN 2026-09-05T03:51:54Z tests/fm-composer-lib.test.sh family=pure-contract-unit expected_gate_skip=none
not ok - a half-block rule row must count as a structural edge
FM_TEST_END 2026-09-05T03:51:56Z tests/fm-composer-lib.test.sh exit=1 duration_ms=1460 gate_skip=false
FM_TEST_BEGIN 2026-09-05T03:51:56Z tests/fm-muse-harness.test.sh family=pure-contract-unit expected_gate_skip=none
not ok - fm-harness.sh under process 'muse-bin-0.1.0-R708.1' reported '', expected muse
FM_TEST_END 2026-09-05T03:51:56Z tests/fm-muse-harness.test.sh exit=1 duration_ms=359 gate_skip=false
FM_TEST_SUMMARY total=2 failed=2 skipped_gate=0 duration_ms=2109
```

### Contribution acceptance checks

```sh
bin/fm-test-run.sh tests/fm-ensure-agents-md.test.sh tests/fm-brief.test.sh
```

Runner exit: 0.
These exercise the helper's filesystem effects and emitted brief contract: explicit marked guidance is preserved across promotion, pointer, symlink, LF, and CRLF cases; unmarked equivalent prose and incidental marker mentions still receive canonical governance.

```text
FM_TEST_BEGIN 2026-09-05T03:51:42Z tests/fm-brief.test.sh family=pure-contract-unit expected_gate_skip=none
FM_TEST_BEGIN 2026-09-05T03:51:42Z tests/fm-ensure-agents-md.test.sh family=pure-contract-unit expected_gate_skip=none
FM_TEST_END 2026-09-05T03:51:45Z tests/fm-ensure-agents-md.test.sh exit=0 duration_ms=2098 gate_skip=false
FM_TEST_END 2026-09-05T03:51:46Z tests/fm-brief.test.sh exit=0 duration_ms=3780 gate_skip=false
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=4136
```

## Handoff

No source, fixture, runner, or tracked documentation changes were made.
The shared environment repair resolved four of the six previous failures, but the two baseline blockers above still prevent a green Test result.
This intentionally untracked evidence file is the only retained worktree artifact; the scratch export, copied binaries, and transient logs were removed after preserving the results here.
