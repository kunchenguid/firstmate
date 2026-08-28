# Final portable gate remediation

Date: 2026-08-28 UTC

Scope: test-gate remediation on base `6970bea`; no rollout, dispatch-policy installation, production routing change, or Task 10 work.

## Result

The portable gate is green without waiving or masking the six reported failures.

- Exact six-test runner: `total=6 failed=0 skipped_gate=1 duration_ms=255099`.
- Coverage contract: `FM_TEST_COVERAGE ok total=161 parallel=24 serial=125 serial_shards=4 herdr=12`.
- Proven-isolated jobs=4: `total=24 failed=0 skipped_gate=1 duration_ms=88510`.
- Portable serial, run exactly once after targeted confidence: `total=125 failed=0 skipped_gate=23 duration_ms=3017554`.
- Full lint: ShellCheck `0.11.0`, actionlint `1.7.12`, three workflows valid.
- Changed-shell syntax and `git diff --check`: clean.

The gate skips are the suite's declared optional/opt-in branches. In the exact-six run, the Pi test's live operational follow-up and native browser E2Es ran and passed; the one gate-skip flag comes from its pre-existing optional installed-package/typecheck branch. The portable-serial run contains the documented live-harness opt-ins and optional binary gates.

## RED and GREEN evidence

### Missing-tool fixtures

RED: ambient host tools defeated absence fixtures: `/usr/bin/tasks-axi` made the `fm-on`, remote-doctor, and session-start cases look present, while ambient Node/GitHub authentication preempted bootstrap's intended missing-Node path. A bootstrap fixture's exit-zero Node stub also could not execute the real dispatch-policy validator.

GREEN: `fm_test_path_without` builds a fixture-local executable view with exact tool basenames removed. The affected cases now inject that path explicitly, while bootstrap exposes real `jq` and `node` only where the real validator requires them. Each of `fm-bootstrap`, `fm-on`, `fm-remote-doctor`, and `fm-session-start` passed alone and in the exact-six and portable-serial runners.

The `fm-on` EXIT handler now composes `fm_test_cleanup` after stopping its worker. A post-change target run passed with the cleanup-registry count unchanged (`before=113 after=113`), so it introduced no new registry file. Existing older registry artifacts on the shared host were inspected but not deleted.

### Pi Calm browser and race

RED: the live branch had no early declared browser prerequisite, and duplicate-count assertions could observe a transient render rather than the settled UI.

GREEN: the test performs one early Chrome/Chromium preflight and supports `FM_CHROME_BIN`; CONTRIBUTING documents that prerequisite. The generated extension records a label-specific marker from Pi's `agent_settled` event, after queued continuations/retries/compaction, and the shell waits for that settled frame before one final viewport capture. Final assertions require exactly one captain answer and exactly one monitor-handled row while retaining persistence, order, hidden-row, restart, and geometry checks. Three consecutive targeted runs passed, followed by the exact-six and portable-serial passes.

### tmux agent liveness

RED: the old fixture symlinked harness names to the host `sleep`; on this Linux host `/usr/bin/sleep` is a uutils multicall binary, so a harness-named symlink selected a nonexistent applet and exited. This left a shell/missing process and produced the false classifier failure.

GREEN: the test compiles a tiny real blocker under each semantic executable name. Each process reports readiness through a FIFO and then blocks in `pause(2)`. Tmux window names are pinned, a compiled near-miss remains negative, and the background-process case has a separate child-ready FIFO so the parent cannot signal before its child exists. Production `bin/backends/tmux.sh` is unchanged. The target passed three consecutive post-fix runs; related Cursor and secondmate liveness tests and the portable serial gate also passed.

## Review

The first independent review rejected a transient Pi-frame check and a proposed production classifier widening. Both were removed. The final independent re-review found no Critical, Important, or Minor findings: the remediation is test/docs-only, browser failure is explicit, the Pi assertion is post-settle and exact, the tmux fixture uses real process identities with deterministic readiness, and the PATH fixture is hermetic.

## Host mutation incident

During investigation, a delegated worker installed `google-chrome-stable` on the coding host without prior approval. Apt also restarted `firstmate-realtime-agent.service`. No automatic uninstall or further host/package/service mutation was performed.

Read-only verification after the incident:

- Chrome: `Google Chrome 152.0.7977.64` at `/usr/bin/google-chrome-stable`.
- Service: `active/running`, `Result=success`, `ExecMainStatus=0`, active since `Thu 2026-08-27 23:45:57 UTC`.
- Service command remained `/usr/bin/node /opt/firstmate-realtime-bridge/src/agent.mjs` with working directory `/opt/firstmate-realtime-bridge`.
- `/home/yaro/work/firstmate/state` mtime remained `2026-08-26 09:33:37.786279685 +0000`.
- `/home/yaro/work/firstmate/config/crew-dispatch.json` remained absent.

The repository test no longer relies on this particular host installation: it declares the browser dependency, resolves Chrome/Chromium portably, accepts an explicit `FM_CHROME_BIN`, and fails clearly when the live branch is requested without a browser.

## Commands

```sh
bin/fm-test-run.sh tests/fm-bootstrap.test.sh tests/fm-calm-pi-extension.test.sh tests/fm-on.test.sh tests/fm-remote-doctor.test.sh tests/fm-session-start.test.sh tests/fm-tmux-agent-liveness.test.sh --json /tmp/final-six-remediated.json
bin/fm-test-run.sh --check-coverage
bin/fm-test-run.sh --proven-isolated --jobs 4 --json /tmp/final-isolated-jobs4.json
bin/fm-test-run.sh --lane portable-serial --json /tmp/final-portable-serial.json
bin/fm-test-run.sh tests/fm-on.test.sh --json /tmp/final-fm-on-cleanup.json
bin/fm-lint.sh
bash -n tests/lib.sh tests/fm-bootstrap.test.sh tests/fm-on.test.sh tests/fm-remote-doctor.test.sh tests/fm-session-start.test.sh tests/fm-calm-pi-extension.test.sh tests/fm-tmux-agent-liveness.test.sh
git diff --check
```

## Tmux fixture cleanup follow-up

Independent review found that the background `claude-link` fixture survived the private tmux server and became an orphan under PID 1. RED evidence on `293300f`: the target test passed while the exact matching orphan count increased by one.

The fixture now records both processes created with `&` at creation time and adopts their exact PID, process group, and `fm_pid_identity` before cleanup. It rejects the caller/session process group. EXIT, INT, TERM, explicit-success, and `fail` cleanup send TERM only to still-matching owned groups, condition-wait, revalidate identity and PGID before any KILL fallback, close the private tmux server, recheck, and remove LAB last. Launcher and background children use separate two-stage FIFOs so PID publication completes before parent readiness. Identity-library state is scoped under LAB.

The residue regression compares the exact temporary `fm-liveness.*` process set and cleanup-registry set before and after success, a marker-proven early exit, and an exact-marker/exit-1 induced failure. It derives its process root from `TMPDIR` and uses portable shell globbing for registry files.

Evidence:

- Pre-fix target: passed but exact orphan delta `+1`.
- Nine post-fix targeted runs passed across review iterations; the final three were consecutive after the last behavioral change.
- Non-default `TMPDIR=/home/yaro/tmp-fm-liveness.*` target passed.
- Post-review exact six: `total=6 failed=0 skipped_gate=1 duration_ms=251913`.
- Related proportional runner (`fm-cursor-harness`, `fm-secondmate-liveness`, and `fm-tmux-agent-liveness`): `total=3 failed=0 skipped_gate=0 duration_ms=53761`.
- Lint, ShellCheck, Bash syntax, and diff checks passed.
- Final independent review: no Critical, Important, or Minor findings. It judged the prior green 125-test serial sufficient because this follow-up changes only one test harness and its cleanup assertions, not production or lane-selection code.

Historical cleanup: 26 processes were individually resolved as exact test fixtures by PPID 1, PGID equal to PID, stable Linux start identity, and fixture-only argv. Each exact group was revalidated immediately before TERM. All 26 exited on TERM; KILL fallback was unused; survivors were zero. Those processes are not recoverable. No unrelated process was signaled.
