# Leaked browser stack reap verification

Repeatable evidence for the vendor behavior that [`../../bin/fm-browser-reaper.sh`](../../bin/fm-browser-reaper.sh) rests on.
The identification rule, refusal boundary, and reap escalation are owned by that script's header; the ownership binding is owned by [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh), the cleanup call by [`../../bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s header, and the session-start diagnostic by [`../../bin/fm-bootstrap.sh`](../../bin/fm-bootstrap.sh)'s header.
This page records evidence only.

Date: 2026-08-22.
Shell: GNU bash 3.2.57 and 5.x (macOS, arm64-apple-darwin25).
chrome-devtools-axi: installed at `/opt/homebrew/lib/node_modules/chrome-devtools-axi`, driving `chrome-devtools-mcp@latest` 1.7.0 and Google Chrome 151.0.7922.173.

## The vendor behavior the fix rests on

Three facts make a leaked stack unattributable by any process-tree rule, and all three were measured rather than assumed.

**The bridge is detached.**
Started from a worker's shell, the bridge is reparented to init immediately:

```console
$ CHROME_DEVTOOLS_AXI_SESSION=fmtest1 chrome-devtools-axi start
status: ready
port: 9484
$ ps -ww -p 5394 -o pid=,ppid=,command=
 5394     1 node /opt/homebrew/lib/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js
```

**One bridge serves one session name for the whole machine, not one invocation.**
A second call with the same session name from an unrelated directory reuses the same pid and port:

```console
$ cd /tmp && CHROME_DEVTOOLS_AXI_SESSION=fmtest1 chrome-devtools-axi start
status: ready
port: 9484
$ cat ~/.chrome-devtools-axi/sessions/fmtest1/bridge.pid
{"pid":5394,"port":9484}
```

**The bridge's working directory is frozen to whichever directory started it first.**
After that second call from `/tmp`, the bridge's cwd is still the first caller's directory:

```console
$ lsof -a -d cwd -p 5394 | tail -1
node    5394 prajwal  cwd    DIR   1,19  896 113193350 /Users/prajwal/.treehouse/firstmate-8bf1b0/2/firstmate
```

Together these are why [`../../bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s cwd-based leaked-descendant sweep cannot own this cleanup: a cwd match is a coincidence of call order, which is unsafe when a still-live task shares the bridge and useless when the starting directory is already gone.
Ownership is therefore declared at spawn time through `CHROME_DEVTOOLS_AXI_SESSION=fm-<home-tag>-<task-id>` rather than inferred afterwards.

The home tag is load-bearing, not cosmetic.
The session registry is one machine-wide namespace, so a second firstmate home on the same machine reads the same sessions; without a per-installation tag it would find a sibling's task id absent from its own `state/` and report that live browser as leaked.
[`../../bin/fm-backend-hometag-lib.sh`](../../bin/fm-backend-hometag-lib.sh) already owns that tag for the identical shared-namespace hazard in the cmux and zellij adapters, and the reaper reuses it rather than inventing a second scheme:

```console
$ bin/fm-browser-reaper.sh --session-name demo-leak
fm-firstmate-7a82173a-demo-leak
```

A session whose name carries the `fm-<prefix>-<8hex>-<task-id>` shape with a digest that is not this home's is classified `other-home` and skipped in silence at every age.

## The two identification signals

Signal 1 is chrome-devtools-axi's own registry, a file this repo never writes:

```console
$ cat ~/.chrome-devtools-axi/sessions/fm-firstmate-7a82173a-demo-leak/bridge.pid
{"pid":95098,"port":9550}
```

Signal 2 is the live process's own argv, which contains `chrome-devtools-axi-bridge`.
Both are required. The registry alone would trust a recycled pid; the argv alone would be name-pattern matching, which `Google Chrome` would satisfy.

A full stack is ten processes, and every member carries one of three argv markers - the bridge's own, `chrome-devtools-mcp` for the server and its telemetry watchdog, and the isolated `puppeteer_dev_chrome_profile-` user-data-dir that every Chrome process in the stack is launched with, browser and helpers alike:

```console
$ ps -ww -p 5592 -o command= | tr ' ' '\n' | grep -E 'type=|headless|user-data-dir'
--type=gpu-process
--headless=new
--user-data-dir=/tmp/puppeteer_dev_chrome_profile-tU1Qjm
$ ps -ww -p 5772 -o command= | tr ' ' '\n' | grep -E 'type=|user-data-dir'
--type=renderer
--user-data-dir=/tmp/puppeteer_dev_chrome_profile-tU1Qjm
```

The marker set is load-bearing for the escalation path only, which signals a positively identified bridge's subtree.
A reparented `GoogleUpdater --wake-all` was observed inside that subtree during a live reap and was skipped by exactly this rule, so descent alone is not treated as permission to signal.

## The refusal that matters most

Antigravity IDE keeps seven or more `chrome-devtools-mcp` servers of its own alive, parented to the editor:

```console
$ ps -eo pid,ppid,command | grep autoConnect | head -1
14507 14158 npm exec chrome-devtools-mcp@latest --autoConnect --no-usage-statistics --no-performance-crux
$ bin/fm-browser-reaper.sh --identify 14507; echo "exit=$?"
refused: pid 14507 is not a positively identified chrome-devtools-axi bridge (needs both a chrome-devtools-axi session record naming it and 'chrome-devtools-axi-bridge' in its own argv)
exit=1
```

They fail both signals - no chrome-devtools-axi registry entry, and an argv that is `chrome-devtools-mcp` rather than `chrome-devtools-axi-bridge` - so they can never be identified and therefore can never be reaped.
`tests/fm-browser-reaper.test.sh` pins that refusal against a real process, alongside the two half-signal cases (a registry record naming a non-bridge pid, and bridge-looking argv with no registry record) that each prove one signal alone is insufficient.

## Reaping a real stack

Measured against a stack launched for this verification, using the tool's own supported shutdown:

```console
$ bin/fm-browser-reaper.sh --reap demo-leak
browser reap: closing browser stack fm-firstmate-7a82173a-demo-leak (pid 95098, up 122s)
browser reap: fm-firstmate-7a82173a-demo-leak closed
```

Stack processes went from 17 to 7 (the ten-process stack), and the Antigravity server count was 10 before and 10 after.
With the tool's `stop` unavailable, the same reap escalates to the identified bridge's subtree and reports each refused bystander:

```console
browser reap: closing browser stack fm-argv-probe (pid 4237, up 41s)
browser reap: fm-argv-probe did not stop cleanly; signalling its process tree
browser reap: SKIP pid 17299 - in the stack's process tree but carries no stack marker; not ours to signal
browser reap: fm-argv-probe closed
```

## Refreshing this record

Re-run `bin/fm-test-run.sh tests/fm-browser-reaper.test.sh` after any chrome-devtools-axi upgrade.
That suite drives real processes and pins the identification, the refusals, the detect-silence contract, and both reap paths without needing chrome-devtools-axi installed.
Re-measure the vendor facts above by hand only when that suite's assumptions are in question - specifically if chrome-devtools-axi stops writing `sessions/<name>/bridge.pid`, renames the bridge entry point, or stops launching Chrome with an isolated puppeteer profile.
