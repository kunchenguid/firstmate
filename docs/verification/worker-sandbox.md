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
- Token-free runtime guard: `bin/fm-test-run.sh tests/fm-sandbox-live.test.sh` runs real shell commands under `srt`; it skips with `skip: live: srt absent` unless a real runtime is installed.
- Real OpenCode worker guard: [`tests/fm-sandbox-opencode-live-e2e.test.sh`](../../tests/fm-sandbox-opencode-live-e2e.test.sh), invoked below, is opt-in and submits model prompts.

## Host results

### optimus0, Linux 6.8.0-142 (Ubuntu) - 2026-10-02

- `command -v srt` and `command -v bwrap` both report nothing.
- `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns` prints `1`, and `unshare -Ur true` fails with `unshare: write failed /proc/self/uid_map: Operation not permitted` (exit 1).
- `FM_HOME=<home> bin/fm-sandbox.sh probe` refuses with `the pinned sandbox runtime 'srt' is not on PATH`.
- The portable regressions in [`tests/fm-sandbox.test.sh`](../../tests/fm-sandbox.test.sh) and [`tests/fm-sandbox-spawn.test.sh`](../../tests/fm-sandbox-spawn.test.sh) passed on this host, driving a canned `srt` CLI.

Consequence: the flag cannot be enabled on this host, and enabling it refuses the launch rather than running unsandboxed.

## Paused: real end-to-end worker proof

A real end-to-end OpenCode worker proof has not run on optimus0.
The shell guard does not supply that proof.
The worker guard runs `opencode run --pure --format json --model <exact catalog identifier>` through `fm-sandbox.sh exec` in a disposable Git fixture under the current worktree.
It uses an empty HOME, empty XDG directories, a cleared environment, synthetic secrets, and an unauthenticated loopback model endpoint; it never loads real provider credentials.
Before launching, it refreshes the actual OpenCode catalog and requires the supplied provider identifier to contain `glm-5.3`, without adding a model definition or substituting another model.
It checks completed bash tool events and exit statuses as well as the allowed file contents, absence of the denied file, and absence of the synthetic secret in the transcript.
An agent declining to attempt a denied operation fails the guard rather than counting as enforcement evidence.

Prerequisites are the pinned `srt` 0.0.78, a working bubblewrap executable, OpenCode, and an operator-provided unauthenticated OpenAI-compatible endpoint serving real GLM 5.3 at `http://127.0.0.1:<port>/v1`.
The endpoint's `/models` response must advertise `glm-5.3`; a canned server does not qualify as real model evidence.
Provider base URL overrides follow the [OpenCode provider interface](https://opencode.ai/docs/providers/#base-url).
The operator must verify the endpoint serves those actual weights; advertising a model identifier alone does not establish model identity.
Provisioning a model server is outside the guard, which neither starts nor changes services.

### Scoped prerequisite proposal, not applied

Stage the pinned runtime and a non-setuid bubblewrap binary inside the worktree, with the latter at `.sandbox-e2e-tools/bwrap`, and prepend that directory to PATH for the guards only.
For example, `npm install --prefix "$PWD/.sandbox-e2e-tools" @anthropic-ai/sandbox-runtime@0.0.78` installs the runtime locally rather than changing global packages.
Obtain bubblewrap from a reviewed distribution package extracted locally; do not install a system package or reuse a setuid binary.
The proposed admin change is loading exactly one AppArmor profile attached only to that staged executable, using Ubuntu's scoped `userns` permission:

```bash
mkdir -p .sandbox-e2e-tools
cat > .sandbox-e2e-tools/apparmor.profile <<EOF
abi <abi/4.0>,
include <tunables/global>
profile "$PWD/.sandbox-e2e-tools/bwrap" flags=(unconfined) {
  userns,
}
EOF
cat .sandbox-e2e-tools/apparmor.profile
```

Review the rendered absolute attachment path and the staged binary before authorizing the admin command `sudo apparmor_parser -r "$PWD/.sandbox-e2e-tools/apparmor.profile"`.
This profile permits user namespaces only for the fixture executable; it leaves the system bubblewrap profile, host-wide AppArmor restriction, sysctls, Docker data, and other services unchanged.
The [Ubuntu scoped profile guidance](https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces) describes this mechanism.
The profile has not been loaded or empirically verified on this host.
After authorized loading, use the real runtime probe as the capability test; a direct `unshare -Ur true` may still fail because it has no such profile.
If that probe fails, leave the E2E step paused and report its diagnostic without broadening the permission.
After the proof, unload only this profile with `sudo apparmor_parser -R "$PWD/.sandbox-e2e-tools/apparmor.profile"` before removing the staged executable.

### Resume command

Run from the worktree root once these prerequisites are supplied:

```bash
PATH="$PWD/.sandbox-e2e-tools:$PWD/.sandbox-e2e-tools/node_modules/.bin:$PATH" \
FM_LIVE_SANDBOX_OPENCODE=1 \
FM_SANDBOX_OPENCODE_MODEL='<catalog provider>/glm-5.3' \
FM_SANDBOX_OPENCODE_URL='http://127.0.0.1:<port>/v1' \
bash bin/fm-test-run.sh tests/fm-sandbox-opencode-live-e2e.test.sh
```

Replace both placeholders with the confirmed catalog provider and the reviewed model endpoint port.
Record the date, OpenCode version, exact model identifier, runtime version, and the guard result when executed; no worker E2E pass is claimed here.
Only this affected live proof remains paused for the scoped prerequisite and credential-free model availability.
