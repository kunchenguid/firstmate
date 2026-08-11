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

The portable counterpart, `tests/fm-spawn-browser-isolation.test.sh`, pins the launch-command half in CI, where no real browser tool or harness exists, using fake ones for the capability outcomes below.

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
It corrects it without losing the id: `fm_task_browser_session` passes ids of 60 characters or fewer through as `fm-<id>`, and folds a longer one into a fixed 64-character `fm-<first 44 characters>-<16 hex of sha256(id)>`, so no two task ids the validator accepts can land on one session name and share a bridge.

Named sessions are a tool capability rather than a firstmate one, so this is the only part of the pin that a different install can silently withdraw: a `chrome-devtools-axi` without them ignores `CHROME_DEVTOOLS_AXI_SESSION` and leaves the agent on the shared `default` bridge while the launch string still reads as isolated.
The observable signal for the capability is the tool's own `--help`, which lists `CHROME_DEVTOOLS_AXI_SESSION` under `environment:` in 0.1.26; `--help` exits 0 in about 0.1s and starts no bridge and no browser, so it is safe to run on every spawn and every teardown.
`fm_browser_tool_supports_named_sessions` (`bin/fm-pr-lib.sh`) therefore probes that help rather than asserting a version floor, and treats an unreadable one as unconfirmed rather than capable; `browser_isolation_env`'s comment owns what `fm-spawn` does with each outcome.
The probe is bounded by `bin/fm-timeout-lib.sh` and runs with stdin closed, because an installed third-party build that hangs or waits on the caller's terminal would otherwise wedge a dispatch instead of resolving to the unconfirmed outcome that already fits it.
It lives beside `fm_task_browser_session` rather than in either script because both ends of a task's browser lifecycle gate on it and must not be able to disagree.
`tests/fm-spawn-browser-isolation.test.sh` covers all four outcomes - capable, too old, unconfirmed, and not installed - against fake tools, plus a tool that reads stdin and one whose help never returns, and asserts that the refusal stops the tool rather than only printing at it.

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
`chrome-devtools-axi stop` against a session with no bridge reports `status: stopped (no-op)`, exits 0 in about 0.14s, and creates no state, so the call is safe to make on every teardown of a task that HAS a named session.
It is gated on the same capability probe above for the case where it does not: a tool without named sessions resolves any `CHROME_DEVTOOLS_AXI_SESSION` to the shared `default` session, so an ungated stop would terminate the operator's own bridge, MCP server, and Chrome - the opposite of this pin's purpose, and against a tool that never gave the agent a private bridge to reclaim.
Teardown therefore issues no stop at all there, which is exactly the set of tasks `fm-spawn` refused the tool for.

That stop carries the same environment pins the launch does, from the same `fm_browser_isolation_pins` owner, because the tool derives a named session's port from the name only while `CHROME_DEVTOOLS_AXI_PORT` is unset: an inherited one would aim the stop at a port that is not the task's, leaving the leak intact and firing at the shared port instead.
It is also bounded by `FM_BROWSER_TOOL_PROBE_TIMEOUT_SECS` with its stdin from `/dev/null`, on the same grounds as the capability probe, since forced secondmate cleanup issues one stop per retired child and a single hung build would otherwise wedge the whole retirement.

A stopped session leaves its own small state directory at `~/.chrome-devtools-axi/sessions/<session-name>/` holding a snapshot-generation counter.
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

The pin covers only the values above.
`CHROME_DEVTOOLS_AXI_CHANNEL`, `_HEADED`, `_MCP_PATH`, `_WS_HEADERS`, and `_BRIDGE_TIMEOUT_MS` are inherited from the operator's environment unchanged; none of them selects a profile or a session, so none reaches an authenticated page on its own.
`browser_isolation_env` records why each is left alone, and `docs/configuration.md` states the same boundary for operators.
