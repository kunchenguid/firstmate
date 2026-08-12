---
name: keep-awake
description: >-
  Manage an explicit macOS idle-system-sleep assertion when the captain invokes
  /keep-awake, optionally binding it to the next genuine return through /afk keep-awake.
user-invocable: true
metadata:
  internal: true
---

# keep-awake

Use this skill only for an explicit `/keep-awake` request or an explicit `/afk keep-awake` request.
Do not infer consent to change power behavior from ordinary work, a locked screen, or a general away-mode request.

`bin/fm-keep-awake.sh --help` owns the command interface and process-record mechanics.
The user-facing operations are `start`, `status`, and `stop`.
Report an unavailable platform or missing `caffeinate` as a concrete blocker rather than retrying with another power tool or changing a system setting.

## Default assertion scope

`start` uses macOS `caffeinate -i` only.
It prevents idle system sleep while preserving display sleep and ordinary lock-screen behavior.
Never add `-d` unless the captain explicitly asks to keep the display awake.
Never use `pmset`, a daemon, a login item, a LaunchAgent, or a persistent power preference.
Lid-close sleep can still occur, and battery policies may still constrain a laptop.

The script starts one reversible process for this Firstmate home.
Its private identity record makes repeated starts idempotent, and `stop` signals only the exact still-owned process.
Do not run `killall caffeinate`, kill by a broad process search, or reuse a previous terminal surface.
A crashed `caffeinate` process releases its assertion, while a stale record is removed safely on the next command.
If Firstmate itself exits first, the process can remain until an explicit stop or its return-bound lifecycle completes after Firstmate resumes.

## `/afk keep-awake`

This is the only automatic-return composition.
Before entering away mode, run `bin/fm-keep-awake.sh start --until-return`.
If that fails, stop and report the reason instead of entering a supposedly sleep-protected away mode.
Then follow the ordinary `/afk` lifecycle without creating another watcher or terminal surface.
`bin/fm-afk-return.sh` stops only this return-bound assertion before it handles the first genuine captain return.
A manually started assertion remains active when the captain returns and requires `/keep-awake stop`.

Away-mode supervision currently has its own supported supervisor-backend limits.
The standalone keep-awake operation is independent of that transport, so it works in the active Pi plus cmux path without creating or controlling a cmux surface or changing watcher ownership.
When cmux cannot enter `/afk`, use explicit `start`, `status`, and `stop` rather than claiming automatic return cleanup is available.

## Captain-facing result

On success, say whether idle-system-sleep prevention is active or stopped and state that display sleep remains allowed.
Mention the lid-close limitation when starting it.
On `/afk keep-awake`, say it will stop on the captain's first genuine return.
