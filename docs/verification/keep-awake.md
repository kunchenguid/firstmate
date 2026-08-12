# Keep-awake verification

Audience: maintainer verification.

[`../configuration.md`](../configuration.md#keep-awake-keep-awake-macos-only) owns current operator behavior and limits.
`bin/fm-keep-awake.sh` owns the identity record and process lifecycle.

## macOS assertion scope

The assertion choice was verified on 2026-08-11 on macOS 26.6.

```sh
/usr/bin/caffeinate -i &
pid=$!
for _ in $(seq 1 30); do
  /usr/bin/pmset -g assertions | awk -v pid="$pid" '$0 ~ "pid " pid "\\(caffeinate\\)" && /PreventUserIdleSystemSleep/ { print; exit }'
  sleep 0.1
done
kill -TERM "$pid"
wait "$pid" || true
```

The matching assertion line had this bounded shape, with the dynamic PID, assertion id, and elapsed time omitted:

```text
PreventUserIdleSystemSleep named: "caffeinate command-line tool"
```

This is the evidence for selecting `-i` rather than display, disk, AC-only, or one-shot user-activity assertions.
The command neither reads nor writes persistent power preferences.

## Primary harness and runtime applicability

The standalone command was reviewed against every supported primary harness: Claude, Codex, OpenCode, Pi, pi-signed, Grok, and Kimi.
It has no harness-specific branch, background model task, or watcher operation, so each invokes the same external managed process.
It therefore does not alter any harness's existing watcher owner.

The same review covers tmux, Herdr, Zellij, Orca, and cmux runtime backends.
The standalone command does not create, resize, focus, or clean up a runtime terminal surface.
That makes the active Pi plus cmux path supported without adding a second cmux surface or changing Pi extension watcher ownership.
The optional `/afk keep-awake` composition is limited by `/afk`'s existing supervisor transport support, which is tmux and Herdr only.
Zellij, Orca, and cmux retain manual `start`, `status`, and `stop` behavior until away-mode supervision supports those transports.

## Portable process lifecycle

The fake-process regression covers start, status, stop, idempotence, mode-0600 identity publication, stale and reused PIDs, non-macOS and missing-tool refusal, exact-only cleanup, live-lock identity, and return-bound cleanup.

```sh
bin/fm-test-run.sh tests/fm-keep-awake.test.sh tests/fm-afk-return.test.sh
```

The test fakes `caffeinate` and `pmset` and never invokes a real power-setting command.
