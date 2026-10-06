# Memory protection

A runaway worker or test can allocate tens of gigabytes, drive the host into swap, and freeze every other lane on the machine.
This document owns the operator setup and safety boundaries for the four protections; each script's header and help own its exact interface, and the installer generates host configuration.

The four protections are independent:

1. **Memory boxes.** Every worker launch and every test script on a protected home runs inside its own cgroup v2 memory scope with a hard cap and zero swap growth.
2. **Host OOM policy.** earlyoom selects a victim by adjusted `oom_score` once available memory falls below 5 percent, preferring test-shaped work and excluding the fleet's own infrastructure.
3. **Heavy-suite routing.** Acceptance, end-to-end, and full-regression runs are refused on a workstation whose config routes them off-host, and the campaign runner is named instead.
4. **One-minute alert.** A systemd user timer queues one firstmate note naming the top memory consumer whenever memory passes the alert threshold.

`bin/fm-mem-protection-install.sh` installs parts 2, 3, and 4.
Part 1 is enforced by `bin/fm-spawn.sh` and `bin/fm-test-run.sh`.

## Memory boxes

`bin/fm-mem-box.sh` is the single owner of the box.
Execution requires Linux with cgroup v2 memory control and a working systemd user manager able to create memory-limited scopes; worker spawning refuses on hosts without these capabilities.
The spawn path probes this capability before creating a worker endpoint, the wrapper checks again before executing its payload, and spawn confirms the pane scope is active before sending launch commands.

`bin/fm-spawn.sh` re-execs each worker's pane shell through the box before any launch work, so the agent and everything it spawns - builds, tests, a project's acceptance suite - share one bounded, swap-free scope.
`bin/fm-test-run.sh` boxes each behavior-test script on protected homes the same way, so scripts selected directly through the runner are bounded too.

- `fm-mem-box.sh exec <lane> -- <command>` runs the command inside `systemd-run --user --scope -p MemoryMax=<cap> -p MemorySwapMax=0`.
- `fm-mem-box.sh check` reports cgroup v2 delegation, systemd-run availability, and every effective lane cap.
- `fm-mem-box.sh cap <lane>` prints one lane's effective cap in bytes.

The default cap is 8 GiB.
`MemorySwapMax=0` keeps a boxed process out of swap, so an over-limit allocation is killed at the box boundary instead of thrashing the host.

Per-lane caps are configured in the home's gitignored `config/memory-box`; [`fm-mem-box.sh`'s header](../bin/fm-mem-box.sh) owns the format and size syntax.
A malformed value is a hard error, never an inferred default.
`FM_MEM_BOX_CAP` overrides the configured cap for one invocation and is removed from the payload's environment so descendants resolve their own lane caps.
Worker panes receive the spawning home's resolved home, configuration directory, and worker cap explicitly rather than inheriting policy from the pane daemon.
The test runner resolves its test cap before parallel-worker environment cleanup and passes it to each box, so serial and concurrent runs use the same cap.

Lane names in use are `worker` (agent panes) and `test` (behavior-test scripts).
A `heavy` lane is the declared entry point for a project's acceptance or E2E suite; it consults the heavy-suite guard before running.

The test runner refuses when scopes are unavailable and this home has `config/memory-box`, `config/memory-box-required`, or an explicit `FM_MEM_BOX_CAP`.
On unconfigured hosts without scopes, including GitHub-hosted runners, it runs tests unboxed with a one-line notice naming the missing capability.

Boxes are per-process-tree, not hierarchical per-lane: a boxed test runner that launches a worker gets a sibling scope for that worker, each with its own cap.
The aggregate is therefore not bounded by any single box, which is why the alert and the host OOM policy exist alongside the boxes.

## Host OOM policy

`bin/fm-mem-protection-install.sh install` writes `/etc/default/earlyoom` and enables the userspace `earlyoom` service.

The installer requires an installed earlyoom version supporting `--ignore` and refuses incompatible versions before changing host configuration or services.

Available RAM below 5 percent alone triggers action: the generated `-s 100` setting effectively ignores swap usage.
Victim selection prefers node, pytest, acceptance, and vitest work, with absolute `--ignore` exclusions for omp, sshd, dockerd, herdr, clickhouse-server, the system daemons, and tmux.
The installer's `print` command is the authoritative preview of generated defaults, including the exact preference and exclusion expressions; its [source comments](../bin/fm-mem-protection-install.sh) explain process-name matching constraints.

`fm-mem-protection-install.sh status` reports the installed version, the enabled and active state, and the effective `EARLYOOM_ARGS`.

## Heavy-suite routing

`bin/fm-heavy-guard.sh` owns the decision.

`config/heavy-suites` holds the posture:

- `local` (the default, and what an unconfigured host gets): heavy suites may run here.
- `remote-only`: heavy suites are refused here and the caller is pointed at the campaign runner.

`config/campaign-runner` names that runner; when it is absent, an existing runner directory is reported if one is found.
`bin/fm-mem-protection-install.sh install` writes both files for a home that routes heavy work off-host.

Heavy classes are:
- the `--all` full-regression selection, the `live-harness-optin` and `real-herdr-gated` families, and any lane named `heavy`, `acceptance`, `e2e`, `end-to-end`, or `full-ci`;
- a suite whose filename carries an acceptance, `e2e`, end-to-end, full-CI, playwright, or cypress token, or whose path has a directory named for one of those heavy suites.

`bin/fm-test-run.sh` consults the guard after selection and before execution, so `--list` and the other inspection modes stay available for planning.
A project's own acceptance or E2E suite is refused when it is launched through the `heavy` lane:

```sh
bin/fm-mem-box.sh exec heavy -- node path/to/acceptance.cjs
```

Arbitrary commands issued inside a worker shell remain bounded by its mandatory memory box.
A refusal exits 3 and names the configured campaign runner.
`bin/fm-heavy-guard.sh check --selection all` and `--path acceptance.cjs` show the decision without running anything; `bin/fm-heavy-guard.sh status` prints the posture and rules.

The campaign runner is a separate controller that packages one exact source revision, runs the suite on a remote VM, and returns status and logs; its own README owns the invocation and its limits.
The required promotion-acceptance re-run is performed as a separate campaign task on the GCP VM, with its result recorded by that task.

## One-minute alert

`bin/fm-mem-alert.sh` samples `/proc/meminfo` once a minute.
When used memory reaches the threshold it queues one firstmate note naming the top process by resident set size.

The alert threshold is fixed at 85 percent.
The check fires once per upward crossing and re-arms when memory drops below 85 percent.
Used memory is the integer percentage computed from `MemTotal` minus `MemAvailable`.
Alert emission and armed/fired state persistence failures return an error rather than reporting a successful crossing or re-arm.
`fm-mem-alert.sh check --print` shows the alert body for the current host without emitting or changing state; `fm-mem-alert.sh status` reports the threshold, current sample, and armed/fired state.

`bin/fm-mem-protection-install.sh install` writes `fm-mem-alert.service` and `fm-mem-alert.timer` into the systemd user unit directory and enables the timer with `OnUnitActiveSec=1min`.
The service runs `<home>/bin/fm-mem-alert.sh check`; installation requires that executable before making host changes or enabling the timer.

## Install, inspect, revert

```sh
bin/fm-mem-protection-install.sh print      # every generated file and command
bin/fm-mem-protection-install.sh install    # apply parts 2, 3, and 4 (sudo for earlyoom)
bin/fm-mem-protection-install.sh status     # current state of every part
```

`install` is idempotent and reports configuration or unit-write failures before announcing success for that part; it does not roll back parts already applied.
It backs up an existing `/etc/default/earlyoom` to `/etc/default/earlyoom.fm-backup` before replacing it.
The installer emits a host-change record with the prior earlyoom enabled/active state and exact manual reversal commands; save that output with the host-change evidence.
To reverse manually, restore the defaults if a backup exists and disable the alert timer:

```sh
[ ! -f /etc/default/earlyoom.fm-backup ] || sudo cp -p /etc/default/earlyoom.fm-backup /etc/default/earlyoom
systemctl --user disable --now fm-mem-alert.timer
```

Restore earlyoom's prior service state from that record:

- Previously enabled: `sudo systemctl enable earlyoom`; previously disabled: `sudo systemctl disable earlyoom`.
- Previously active: `sudo systemctl restart earlyoom`; previously inactive: `sudo systemctl stop earlyoom`.

Leave the package installed and preserve operator-edited `config/heavy-suites` and `config/campaign-runner` files.

## Verification

```sh
bin/fm-mem-box.sh check
bin/fm-mem-box.sh exec test -- bash -c 'echo "max=$(cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max)"'
bin/fm-heavy-guard.sh status
bin/fm-mem-alert.sh status
bin/fm-mem-protection-install.sh status
```

A quick end-to-end proof of the box is an allocation above the cap that dies inside the box while the host stays responsive: `bin/fm-mem-box.sh exec test -- node -e 'const a=[];while(1)a.push(Buffer.alloc(1<<20,1))'` with `FM_MEM_BOX_CAP` set below the host's free memory.
The nonzero fill touches every allocated page so the proof exercises resident memory rather than untouched virtual allocations.
