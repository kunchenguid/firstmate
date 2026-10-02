# Worker command sandbox verification

Active empirical evidence for the opt-in worker command sandbox ([`config/worker-sandbox`](../configuration.md#worker-command-sandbox-configworker-sandbox)).
The contract is owned by [`docs/configuration.md`](../configuration.md) and the mechanics by [`bin/fm-sandbox.sh`](../../bin/fm-sandbox.sh).

## Pinned runtime

`@anthropic-ai/sandbox-runtime` `0.0.78`, the npm `latest` release at the time of verification and the version `bin/fm-sandbox.sh` pins.
The runtime's interface (`srt --version`, `srt --settings <file> -c <command>`) was read from the published package's `src/cli.ts` and README on 2026-10-02.

## Commands

- Readiness probe: `FM_HOME=<home> bin/fm-sandbox.sh probe`.
- Portable regressions: `bin/fm-test-run.sh tests/fm-sandbox.test.sh tests/fm-sandbox-spawn.test.sh`.
- Launch-boundary relaunch case: `bin/fm-test-run.sh tests/fm-control-relaunch.test.sh`.
- Live guard (real `srt`): `bin/fm-test-run.sh --family live-harness-optin` runs `tests/fm-sandbox-live.test.sh`, which skips with `skip: live: srt absent` unless a real runtime is installed.

## Host results

### optimus0, Linux 6.8.0-142 (Ubuntu) - 2026-10-02

- `command -v srt` and `command -v bwrap` both report nothing.
- `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns` prints `1`, and `unshare -Ur true` fails with `unshare: write failed /proc/self/uid_map: Operation not permitted` (exit 1).
- `FM_HOME=<home> bin/fm-sandbox.sh probe` refuses with `the pinned sandbox runtime 'srt' is not on PATH`.
- The portable regressions in [`tests/fm-sandbox.test.sh`](../../tests/fm-sandbox.test.sh) and [`tests/fm-sandbox-spawn.test.sh`](../../tests/fm-sandbox-spawn.test.sh) passed on this host, driving a canned `srt` CLI.

Consequence: the flag cannot be enabled on this host, and enabling it refuses the launch rather than running unsandboxed.

## Paused: real end-to-end worker proof

A real end-to-end OpenCode worker proof of the allowed and denied boundaries needs both of these on the host, and neither is available on optimus0:

1. The pinned runtime installed, for example `npm install -g @anthropic-ai/sandbox-runtime@0.0.78`, or an existing `srt` for `FM_SANDBOX_SRT_BIN`.
2. Working unprivileged user namespaces: `bwrap` present and `unshare -Ur true` succeeding.
   Ubuntu 24.04+ blocks this by default through the AppArmor `kernel.apparmor_restrict_unprivileged_userns` restriction; unblocking it is a host-wide admin action, for example `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` or an AppArmor profile that permits `bwrap`.

Both are outside this change's safety boundary, so the end-to-end step is paused here rather than weakening host-wide AppArmor or sysctl settings.
The live guard above is the command that produces that proof once a reviewed admin action makes the prerequisites available.
