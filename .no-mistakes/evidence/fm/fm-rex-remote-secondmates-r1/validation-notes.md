# Local Test result: inconclusive

## Real product execution

`linux-contracts.log` records the completed `linux-contracts-driver.sh` run (exit 0) inside a disposable Apple container: Linux aarch64, Rex 0.1.0-preview.12/API 8, Codex 0.166.0. The image root was read-only; source copies, disposable homes, downloaded binaries and npm dependencies were under the run worktree; Unix sockets used the container's ephemeral /tmp. Both containers and downloaded test images were removed, all test-owned processes stopped, and the worktree was restored clean.

The live endpoint was created with the real Rex CLI running the real Codex binary, not with Firstmate spawn. Its parent-route metadata was synthetic and used actual returned session/window/block IDs. Codex reached its sign-in screen; no authentication or model turn was attempted. This proves endpoint liveness/capture, not an authenticated working secondmate.

Observed through the actual Firstmate remote-control CLI:
- Valid endpoint: `alive`, captured Codex's real sign-in screen, and repeated launch returned the same route without creating another endpoint.
- Requested Herdr over recorded Rex: explicit backend-mismatch refusal. Replacing the endpoint with TCP metadata: `unverified`, no migration.
- After stopping Rex, state returned `unreadable`, launch refused duplication, and a non-autostart status read confirmed no server existed. The probes did not start an exit-empty server.
- Real doctor `--backend rex --fix` started the missing persistent server (`exit_empty:false`); restored endpoints read `dead` rather than `alive`.
- Against an answering exit-empty server, doctor reported the human restart requirement; the Rex instance ID and a real sibling sleep process's full process response were identical before/after repair.

Independent oracles: docs/remote-secondmates.md's unix-only placement, no migration, passive-probe and operator-scheduled-restart contracts; published https://www.superlogical.com/rex/docs/linux/server-modes documents personal-server autostart as exit-empty and stop as process-destructive. The assertions reject accidental autostart, cross-backend cutover, and killing/replacing unrelated processes.

## Limits

Fresh launch, key delivery and recovery were attempted but the gate safety refused remote-control child calls. The controller sets FM_HOME to its code root while redirecting state/data/config into the mate's parent-route directories; the stock marked-lab exception does not permit these overrides. Both homes were marked labs. No bypass was used. A sanctioned remote-lab route supporting those confined overrides is needed for these checks. An independently authenticated disposable Linux account is also needed for a model-turn proof; the installed Linux Codex displayed sign-in, and production credentials were neither copied nor changed.

The doctor's overall exit was 1, not a ready-host pass: tasks-axi/treehouse were absent and the worker reported `cannot compute worker code identity` in the mounted fixture. Only the Rex-server subcontracts above are claimed. Full SSH/worker readiness, first remote launch, default-Herdr live operation, key delivery and automatic recovery remain unverified.

## Targeted portable checks

- `TMPDIR="$PWD/.test-live/tmp" bin/fm-test-run.sh tests/fm-remote-doctor.test.sh tests/fm-secondmate-liveness.test.sh tests/fm-backend-rex.test.sh`: doctor passed; the other two failed because nesting fixtures inside the repository violates home-removal/isolation checks. This was a setup problem, not a product regression.
- `bin/fm-test-run.sh tests/fm-secondmate-liveness.test.sh tests/fm-backend-rex.test.sh`: both passed after restoring the normal temporary-root setup. These use fixture backends and are not live Rex evidence.
- `bin/fm-test-run.sh tests/fm-remote-secondmate-lifecycle-e2e.test.sh`: timed out after 600 seconds with partial successful fixture output, before the Rex-specific tail completed. Its remaining test-owned worker/listener process tree was explicitly stopped. No full-suite pass is claimed.

No linters, formatters or static analysis ran. No source/test changes remain. This is a CLI/backend change, not a UI placement change; product evidence is CLI output, not screenshots.
