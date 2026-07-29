# Chrome DevTools AXI worker isolation verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for Firstmate's ordinary-worker and scout browser isolation.
Current operator behavior is documented in [`configuration.md`](../configuration.md#toolchain), while [`bin/fm-chrome-axi-lib.sh`](../../bin/fm-chrome-axi-lib.sh) owns exact naming, root-argument, metadata-validation, and cleanup mechanics.

## Installed source and contract

The active host was checked on 2026-07-29 as uid 0 with `chrome-devtools-axi` 0.1.27, which was also the current published npm version.

```sh
id -u
chrome-devtools-axi --version
npm view chrome-devtools-axi version --json
chrome-devtools-axi --help
```

Bounded output:

```text
0
0.1.27
"0.1.27"
CHROME_DEVTOOLS_AXI_CHROME_ARGS   Whitespace-separated Chrome flags forwarded to the browser
CHROME_DEVTOOLS_AXI_SESSION       Named session for concurrent isolation
```

The installed `dist/src/sessions.js` source was inspected directly.
It accepts 1-64 characters from `[A-Za-z0-9._-]`, rejects all-dot names, derives each named session's state directory and port from that name, and retains `default` only as the unset legacy behavior.
The installed client passes the complete process environment into the named bridge and its `stop` reads only that session's PID record before terminating the bridge's process group.

Shared-memory and host-memory checks did not support adding a Firstmate `--disable-dev-shm-usage` workaround.

```sh
df -h /dev/shm
free -h
```

Bounded output:

```text
tmpfs  7.5G  1.1M  7.5G  1%  /dev/shm
Mem:    14Gi  7.5Gi  3.2Gi  264Mi  5.0Gi  7.5Gi
```

## Concurrent root-safe browser smoke

Two fresh throwaway names were opened with the exact root-required token and no fixed port.
Both bridges and browsers remained live concurrently, each returned its own page snapshot, stopping the first left the second operational, and each exact stop removed only its own PID record.
Pre-existing named and legacy browser sessions were not stopped or restarted.

```sh
s1=fm-smoke-20260729-a
s2=fm-smoke-20260729-b
CHROME_DEVTOOLS_AXI_SESSION="$s1" CHROME_DEVTOOLS_AXI_CHROME_ARGS=--no-sandbox CHROME_DEVTOOLS_AXI_PORT='' \
  chrome-devtools-axi open https://example.com
CHROME_DEVTOOLS_AXI_SESSION="$s2" CHROME_DEVTOOLS_AXI_CHROME_ARGS=--no-sandbox CHROME_DEVTOOLS_AXI_PORT='' \
  chrome-devtools-axi open https://example.org
CHROME_DEVTOOLS_AXI_SESSION="$s1" CHROME_DEVTOOLS_AXI_CHROME_ARGS=--no-sandbox CHROME_DEVTOOLS_AXI_PORT='' \
  chrome-devtools-axi snapshot
CHROME_DEVTOOLS_AXI_SESSION="$s2" CHROME_DEVTOOLS_AXI_CHROME_ARGS=--no-sandbox CHROME_DEVTOOLS_AXI_PORT='' \
  chrome-devtools-axi snapshot
CHROME_DEVTOOLS_AXI_SESSION="$s1" CHROME_DEVTOOLS_AXI_CHROME_ARGS=--no-sandbox CHROME_DEVTOOLS_AXI_PORT='' \
  chrome-devtools-axi stop
CHROME_DEVTOOLS_AXI_SESSION="$s2" CHROME_DEVTOOLS_AXI_CHROME_ARGS=--no-sandbox CHROME_DEVTOOLS_AXI_PORT='' \
  chrome-devtools-axi snapshot
CHROME_DEVTOOLS_AXI_SESSION="$s2" CHROME_DEVTOOLS_AXI_CHROME_ARGS=--no-sandbox CHROME_DEVTOOLS_AXI_PORT='' \
  chrome-devtools-axi stop
```

Bounded output:

```text
page:
  title: Example Domain
  url: "https://example.com"
page:
  title: Example Domain
  url: "https://example.org"
uid=g2:1_0 RootWebArea "Example Domain" url="https://example.com/"
uid=g2:1_0 RootWebArea "Example Domain" url="https://example.org/"
status: stopped
uid=g3:1_0 RootWebArea "Example Domain" url="https://example.org/"
status: stopped
```

Final bounded state:

```text
fm-smoke-20260729-a pidfile=absent
fm-smoke-20260729-b pidfile=absent
```

## Shared-boundary and cleanup regressions

Applicability was reviewed against every verified worker runtime and every spawn-capable session provider.
All seven runtime templates converge on one `LAUNCH` value, and tmux, Herdr, Zellij, Orca, and cmux all submit that value only after the shared browser environment prefix is attached.
No runtime or provider has a separate browser-policy branch.
Secondmate agents do not receive an ordinary-worker browser session, while workers and scouts spawned from their isolated homes derive a distinct home/task identity through that home's own `fm-spawn.sh`.

```sh
bash tests/fm-chrome-axi.test.sh
bash tests/fm-brief.test.sh
bash tests/fm-teardown.test.sh
```

Relevant bounded output:

```text
ok - Chrome DevTools AXI sessions are deterministic, task/home-isolated, safe, and non-default
ok - Chrome arguments preserve other tokens and enforce --no-sandbox exactly once only for root
ok - the shared launch boundary publishes one isolated root-safe browser environment before every worker runtime
ok - browser cleanup metadata accepts only one exact home/task binding and keeps legacy records inert
ok - fm-brief.sh: workers and scouts receive the bounded browser recovery and Playwright handoff contract
ok - fm-teardown stops only the exact recorded Chrome DevTools AXI session
ok - legacy teardown metadata never falls back to a default or global browser stop
ok - unlanded-work refusal happens before any browser stop
ok - scout-report refusal happens before any browser stop
ok - unresolved-decision refusal happens before any browser stop
ok - browser-stop failure is explicit and preserves the task for an exact retry
ok - cleanup refuses another task's valid named browser session without touching it
```

The root/non-root argument matrix uses the tool's JavaScript whitespace class, including CR, VT, FF, and Unicode separators, preserves every other token in order, removes every exact `--no-sandbox` occurrence, appends exactly one for uid 0 and none for non-root, rejects prefix lookalikes, and does not add `--disable-dev-shm-usage`.
The cleanup matrix proves exact-session stop, inert legacy records, another-task refusal, authorization ordering, and retry-safe behavior when the exact stop fails.
