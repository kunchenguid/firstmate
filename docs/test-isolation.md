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

## The ambient seal, and the cloud seal under it

A behavior test may only see the environment it sets for itself.
`tests/run.sh` drops every name declared in `tests/ambient-seal.tsv` before it admits a single test: `FM_HOME`, `FM_WORKER_PROVIDER_COMMAND`, `FM_SPAWN_CLOUD`, and everything under `FM_AZURE_`, `AZURE_` and `ARM_`.
It prints one `FM_AMBIENT_SEAL dropped=...` line per invocation, so a run in a rich operator shell says what it removed.
Nothing under `FM_TEST_` is sealed: that prefix is the runner's own contract with the test.

The seal exists because ambient environment made this suite provision real infrastructure.
On 2026-08-20 a billable `Standard_D4as_v6` VM (`vm-fm7c799d-wkr-01`) was found running in the pilot resource group, tagged with the task id `cloud-noenv-c7` - a hardcoded fixture id that exists only in `tests/fm-spawn-cloud.test.sh` - and a repository-generation that is not a commit that exists.
No controller queue entry, no worker record, no `state/<task>.meta`; nothing tracked it and nothing would have released it.
That unit deliberately omits `FM_WORKER_PROVIDER_COMMAND` and the `FM_AZURE_*` identity in order to prove the lifecycle REFUSES such a request.
With the operator's `fleet.env` sourced, the ambient identity satisfied the very check the unit asserts is missing, and `bin/fm-worker-lifecycle.py` resolved its default provider, which is the real Azure adapter.
The request was served.
The same ambient reach is what made `tests/fm-worker-lifecycle.test.sh` non-deterministic: `FM_HOME` alone was enough, and which unit failed varied between runs.

Fail closed on the provider, never fall through.
Under the ambient seal sit three more layers, all owned by `tests/run.sh`:

- `FM_WORKER_PROVIDER_COMMAND` is bound to `tests/cloud-provider-refusal.py` for every admitted test, so a test that names no provider gets a loud refusal instead of Azure. A test that genuinely drives a provider names its own fixture on its own command line, which wins.
- `tests/cloud-guard-bin/az` is on every admitted test's PATH, so even a path that reconstructs the real adapter cannot reach the control plane. A test that needs a fake `az` puts one in its own fakebin, which it prepends ahead of the guard.
- Both refusals RECORD to `FM_TEST_CLOUD_REACH_LOG`, and `tests/cloud-reach-check.sh` runs after every admitted test on every lane. Any recorded reach fails the run and names what was reached. Containment is the refusal; this is the alarm, because a guard that only refused could be scrolled past.

`tests/fm-cloud-provider-seal.test.sh` is the structural guard.
It pins the registry at an exact literal set and count, pins that `tests/run.sh` wires all four layers on both admission lanes and checks for a reach after every lane, proves each refusal refuses and records, proves a recorded reach fails the run and does not leak into the next test, and asserts as live facts about its own process that no operator identity is set, that the bound provider is the refusing one, and that `az` resolves to the guard.

## Host capabilities

Herdr is not the only thing a sealed-suite host can lack.
`tests/host-capabilities.tsv` declares every other host capability the suite depends on, the platforms that can provide it, and the exact units bound to it, and `tests/host-capability-gate.sh` is the only door to that set, through `fm_require_host_capability <capability> "<label>" || return 0`.
The four today are a real tmux server, passwordless root escalation with `systemd-run`, a system `openat` binding through `/usr/bin/cpp`, and outbound reach to the origin remote's host (`origin-egress`).
The first three were measured from the retained shard responses of the first live Azure validation cell; the fourth by running the whole teardown suite in a local reproduction of that cell's package closure, with the network off, and instrumenting `run_secondmate_remote_probe` until the cause was named.
`origin-egress` carries the largest skip set, 37 units, so be explicit about it: an environment that declares it absent does NOT verify secondmate teardown or retirement authority at all, and that coverage lives on macOS and CI only.
A capability in this file is a statement about a HOST, not about a platform: the tmux units pass on CI's `ubuntu-latest` and in an ordinary Linux container, and are absent only in the cell, which is why the gate reads a by-name declaration rather than a blanket platform rule.
A blanket platform rule would have silently removed coverage that CI and an ordinary container both provide.
Where an environment could simply provide the capability instead, that is the better fix; the registry is for what an environment genuinely cannot have.
`tests/fm-host-capability-gate.test.sh` pins the registry against the real call sites, pins the set at an exact literal count, and pins the required call shape, so the skip set cannot grow or shrink without a visible diff.

The gate never probes the capability it guards.
A probe of `command -v tmux`, `sudo -n true`, or a Keychain read is false on a BROKEN host too, which turns a real regression into an invisible skip; that is exactly how a unit gated on `command -v pi` lost two mutations of the actuator to a green CI run.
It reads facts about where the test is running instead: the platform (`uname -s`), and an explicit by-name declaration the environment makes about itself in `FM_TEST_HOST_CAPABILITIES_ABSENT`.
Everything not declared runs, so a host that is merely broken goes red.
An unknown capability name, on either side, refuses the run with exit 97 rather than skipping.

The declaration is refused outright on Darwin: macOS is the coverage of record for these units, so there they always run.
CI declares nothing, so its coverage is unchanged.
The Azure validation cell is the one declaring environment (`docs/azure-validation.md`), and its shard command carries the declaration its first live run measured.
Every skip prints one `FM_HOST_CAPABILITY_SKIP` line on stdout and stderr naming the test, the unit, the capability, what the capability is, and why it was unavailable, and `tests/run.sh` prints the whole declaration once per invocation.

Use `tests/run.sh --skip-herdr` for the explicit non-Herdr path.
That option reports each skipped `herdr-lab` test, runs every `hermetic` test normally, and runs only the hermetic assertions in each `herdr-mixed` test.
CI selects the same path explicitly with `FM_TEST_SKIP_HERDR=1` on each sealed shard command because its disposable image does not provide Herdr.
The no-mistakes test command does not skip: it requires every declared real-Herdr test to prove an owned lab or fail closed.
