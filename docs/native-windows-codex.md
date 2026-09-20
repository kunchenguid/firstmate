# Experimental native Windows Codex launcher

This explicit opt-in launcher is a restricted experimental candidate, not an installed runtime backend or a production-ready integration.
Ordinary startup never selects it, and it does not install hooks, alter saved or global Codex settings, pull images, or select a default backend.

## Setup

The launcher requires Windows PowerShell 5.1, native Node and Codex, Git Bash, and Docker at their standard installation paths.
It also requires an existing local Docker image containing jq and GNU timeout; the launcher does not install or pull it.
The PowerShell help for `bin/fm-native-codex.ps1` owns the exact flag mechanics.

Build without launching, then verify an empty temporary operational home:

```powershell
.\bin\fm-native-codex.ps1 -BuildOnly
.\bin\fm-native-codex.ps1 -Experimental -VerifyOnly `
  -OperationalHome "$env:LOCALAPPDATA\Temp\firstmate-native-example" -JqImage <existing-local-image>
```

Omit `-VerifyOnly` for an interactive model session.
Rebuild the native provider after its source stamp changes and after all native sessions have stopped.
Use `/interrupt` to interrupt the current model turn and `/quit` to end the session.

## Verification entry points

Run the portable request-policy regression with:

```sh
bin/fm-test-run.sh tests/fm-native-owner-tool-gate.test.sh
```

Run native receipt persistence and operation-lifetime checks with:

```sh
bin/fm-test-run.sh tests/fm-native-owner-receipt-live-e2e.test.sh
```

Run effective app and MCP isolation without a model turn with:

```sh
FM_LIVE_NATIVE_APP_POLICY=1 bin/fm-test-run.sh tests/fm-native-owner-app-server-policy-live-e2e.test.sh
```

Run the actual Windows integration with the explicit two-model-turn guard with:

```sh
FM_NATIVE_TEST_JQ_IMAGE=<existing-local-image> FM_LIVE_NATIVE_CODEX=1 \
  bin/fm-test-run.sh tests/fm-native-owner-codex-live-e2e.test.sh
```

Run the explicit launcher without model turns, then optionally exercise two notification turns and active-turn cancellation with:

```sh
FM_NATIVE_TEST_JQ_IMAGE=<existing-local-image> FM_LIVE_NATIVE_LAUNCHER=1 \
  bin/fm-test-run.sh tests/fm-native-owner-launcher-live-e2e.test.sh
FM_NATIVE_TEST_JQ_IMAGE=<existing-local-image> FM_LIVE_NATIVE_LAUNCHER=1 FM_LIVE_NATIVE_CODEX=1 \
  bin/fm-test-run.sh tests/fm-native-owner-launcher-live-e2e.test.sh
```

## Safety boundary and limits

Only empty-fleet homes beneath the current user's Windows temporary directory are accepted.
Existing fleet metadata, registrations, Relay configuration, process-event sources, non-temporary homes, and existing reparse-point ancestors are refused.
The `projects` path may be absent or an ordinary empty directory; populated, non-directory, and reparse-point forms are refused unchanged.
The app-server thread is ephemeral, read-only, network-disabled, and approval-never; Apps, plugins, and configured MCP servers are disabled for this host and their effective catalogs are checked before readiness.
Only controller-selected startup, notification check, and acknowledgement scripts receive registered native operation authority.
The two notification tools are the model-facing path to those registered host operations, not the complete Codex tool catalog; ordinary tools cannot acquire native authority from the inherited endpoint, claims, callback identity, or session job.
Those operations and their descendants are owned by the native session: deferred startup may outlive the digest shell but `/quit` cancels it without terminating independently owned workers, and unfinished startup may run again after restart.
Interrupted or ambiguous acknowledgements remain preserved for evidence-based reconciliation and are never replayed or rolled back automatically.

Production use remains disabled.
Populated-fleet shutdown, forced app-server descendant cleanup, adversarial Windows path and process races, remaining numeric identity readers, other harnesses, installation, and packaging are not supported or claimed.
Ordinary unelevated Codex shell execution of Git Bash remains a known limitation; the narrow authenticated host operations are not a general sandbox fix.
