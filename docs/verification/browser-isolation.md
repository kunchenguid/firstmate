# Browser isolation verification

Audience: maintainer verification.

This record supports the browser-isolation environment that `bin/fm-spawn.sh` prefixes onto every launch command.
It records only facts that must be re-established when chrome-devtools-axi or a harness changes.
Task chronology and incident transcripts stay in private reports or PR evidence.

`bin/fm-spawn.sh`'s `browser_isolation_env` comment owns which variables are pinned and why.
The facts below are what that choice rests on, and every one is re-derived by `tests/fm-browser-isolation-live-e2e.test.sh`:

```
FM_BROWSER_ISOLATION_LIVE=1 bin/fm-test-run.sh tests/fm-browser-isolation-live-e2e.test.sh
```

The portable counterpart, `tests/fm-spawn-browser-isolation.test.sh`, pins the launch-command half in CI, where no browser tool or harness exists.

## Connection mode the pin depends on

Verified 2026-08-11 against chrome-devtools-axi 0.1.26 and Chrome 151.0.7922.108.

With no `CHROME_DEVTOOLS_AXI_*` value set, the tool launches its own throwaway browser rather than reaching an existing one.
`buildTransportArgs` returns:

```
-y chrome-devtools-mcp@latest --isolated --headless
```

and the Chrome that starts carries a fresh temporary profile, distinct from the operator's:

```
$ ps -p <pid> -o args= | tr ' ' '\n' | grep -- '--user-data-dir='
--user-data-dir=/tmp/puppeteer_dev_chrome_profile-g8GQG9
```

So an isolated profile is the tool's default, not something firstmate has to construct.
What firstmate must supply is the guarantee, because four inherited values each reach a real browser on their own:

| Inherited value | Transport arguments it selects |
| --- | --- |
| `CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1` | `--autoConnect` (attaches to the operator's running Chrome) |
| `CHROME_DEVTOOLS_AXI_USER_DATA_DIR=<profile>` | `--userDataDir=<profile>` |
| `CHROME_DEVTOOLS_AXI_BROWSER_URL=<url>` | `--browserUrl=<url>` |
| `CHROME_DEVTOOLS_AXI_CHROME_ARGS=--user-data-dir=<profile>` | `--isolated --chrome-arg=--user-data-dir=<profile>` |

The last row is the non-obvious one and is why `CHROME_ARGS` is pinned rather than left alone.
`--isolated` is still passed, yet the forwarded flag wins in the launched browser: with only `CHROME_ARGS` set, Chrome received the forwarded directory, not a `puppeteer_dev_chrome_profile-*` one.
Neutralising `USER_DATA_DIR` alone would leave that override open.

All four are read as falsy-when-empty, so an empty assignment is sufficient to neutralise an inherited value; `AUTO_CONNECT` is compared against the exact string `1`.
With the full pin applied over all four hostile values at once, `buildTransportArgs` returns `--isolated --headless` again.

## Session sharing the pin depends on

Verified 2026-08-11 against chrome-devtools-axi 0.1.26.

An unset `CHROME_DEVTOOLS_AXI_SESSION` resolves to the session named `default`, which is one bridge on port 9224 with state under `~/.chrome-devtools-axi/`.
Every agent left on that default therefore shares one live browser with each other and with the operator's own use of the tool, so a page one of them authenticated is readable by the next.
A named session gets its own bridge, its own port derived from the name, and its own state directory under `~/.chrome-devtools-axi/sessions/<name>/`.

A bridge's own health check carries the expected session name, so a session cannot silently attach to another session's bridge even when both resolve to the same port.
Session names are restricted to 1-64 characters of `[A-Za-z0-9._-]`, and an out-of-range name throws rather than degrading, which would break every browser command for the agent that inherited it.
`fm_task_id_creation_valid` (`bin/fm-pr-lib.sh`) already restricts a task id to that same charset, no leading dot, and at most 64 characters, so length is the only axis `fm-spawn` has to correct.

## Process lifetime the pin depends on

Verified 2026-08-11 against chrome-devtools-axi 0.1.26.

The bridge has no idle timeout; it lives until stopped.
A per-task session therefore leaves a bridge, an MCP server, and a headless Chrome running after the agent finishes.
All of them inherit the invoking agent's working directory:

```
$ lsof -a -d cwd -p <bridge|mcp|chrome pid> -Fn
n<task worktree>
```

That is the same signal `bin/fm-teardown.sh`'s leaked-descendant reap uses (`lsof -a -d cwd`, matched against the task's own worktree and tasktmp root), so an ordinary teardown already reclaims all three whenever the agent browsed from its own worktree.
Chrome runs in its own process group rather than the bridge's, so the bridge's exit-time process-group kill does not reach it; the cwd-matched reap is what covers it.

The reap is incidental rather than deterministic, though: an agent that browsed from any other directory would leak a whole browser past teardown.
`bin/fm-teardown.sh`'s `stop_task_browser_bridge` closes that gap by naming the session directly before the reap runs.
`chrome-devtools-axi stop` against a session with no bridge reports `status: stopped (no-op)`, exits 0 in about 0.14s, and creates no state, so the call is safe to make on every teardown.

A stopped session leaves its own small state directory at `~/.chrome-devtools-axi/sessions/fm-<task-id>/` holding a snapshot-generation counter.
That directory belongs to the tool rather than to firstmate, and teardown deliberately does not reach outside firstmate's state to delete it.

## Inheritance into a real agent's shell

Verified 2026-08-11.

| Harness | Version | Result |
| --- | --- | --- |
| claude | 2.1.227 | pin inherited; `https://mail.google.com` resolved to `accounts.google.com/v3/signin/identifier` |

The launch command is an environment prefix, so this depends on each harness passing its own environment to the shell it gives the agent.
It is a vendor behaviour and is re-checked per installed harness by the live guard; a harness absent from the table above has not been measured.

The probe runs with a hostile environment already exported in the pane, including `AUTO_CONNECT=1`, `SESSION=default`, `PORT=9224`, and the operator's real Chrome profile path.
The agent's shell nonetheless reported:

```
CHROME_DEVTOOLS_AXI_AUTO_CONNECT=0
CHROME_DEVTOOLS_AXI_BROWSER_URL=
CHROME_DEVTOOLS_AXI_CHROME_ARGS=
CHROME_DEVTOOLS_AXI_PORT=
CHROME_DEVTOOLS_AXI_SESSION=fm-browserisolive-claude
CHROME_DEVTOOLS_AXI_USER_DATA_DIR=
```

Its bridge came up on its own derived port with `--isolated --headless` and a `/tmp/puppeteer_dev_chrome_profile-*` directory, and the operator's own Chrome process was untouched.
Legitimate browsing is unaffected: the same agent loaded `https://example.com` and read its title.

A page title is not evidence of authentication state here.
An isolated profile loading `https://mail.google.com` still renders a page titled `Gmail`; only the resolved URL distinguishes the sign-in form from a mailbox, so the live guard asserts on the URL.

## Scope of the guarantee

This removes ambient reach, not capability.
An agent holds a shell and can export different values itself, and per the 2026-08-10 instrument scout no allowlist contains a tool that already reads and writes arbitrary files.
The verified guarantee is that a firstmate-launched agent does not start inside the operator's authenticated browser, and does not share one with the operator or another task.
