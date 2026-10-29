# Away-mode launch

Load this with the `afk` skill at entry step 2, after the `enter` command has written the record.

- **Pi and pi-signed**: nothing to launch; go on to the announcement.
  The away daemon is no longer launched on Pi; the ordinary supervision session (`docs/pi-supervision-branch.md`) keeps running with the record present, and `bin/fm-afk-launch.sh start` refuses on these harnesses.
  With the record present main is parked: the supervision branch takes every safe actionable wake, captain outcomes accumulate for the return brief, and main's standing authority relocates to the branch through the guarded scripts (`docs/pi-supervision-branch.md` "Postures"); only a wake the branch declines (including a broken branch or unsafe scan) or a watcher failure wakes main.
  `/quiet` needs nothing extra on Pi: the attended branch already keeps routine wakes out of this conversation, so quiet-while-present is the attended posture's own shape there.
- **A home that runs the supervision host** (a Claude home unless `config/supervision-host-off` opts it out, or a Cursor, OpenCode, omp, Grok, or Codex home with `config/supervision-host` and no opt-out; `docs/configuration.md` "Supervision host"): nothing to launch for `/afk`; go on to the announcement.
  The supervision host (`docs/supervision-host.md`) is the away session there: it runs the branch's contract on a headless engine under the record while main is parked, and `bin/fm-afk-launch.sh start` and `start-native` refuse the away daemon on that home.
  If `enter` printed a `Supervision host: no engine ...` line, every away wake reaches this conversation instead; say so in the announcement.
  `/quiet` enters nothing there where the attended host runs, and otherwise still launches the daemon below (the quiet skill's `quiet-check` decides).
- **Harness WITH a native in-pane tracked-background tool** (claude's and grok's, on a home that does not run the supervision host): run `bin/fm-afk-launch.sh start-native`, then run `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through that native tool.
  This is a deliberate no-separate-terminal exception because the harness-hosted job creates no terminal or layout mutation, and a shell launcher cannot invoke a harness-native background tool.
  If the native launch fails, run `bin/fm-afk-launch.sh stop` to roll back the prepared lifecycle.
  Do not wrap it in `nohup ... &` (Codex/herdr can reap fire-and-forget shell children after a tool call returns).
- **Every other harness** (codex, opencode, omp, and cursor on a home that does not run the supervision host, and kimi): run `bin/fm-afk-launch.sh start`.
  It is the single owner of the daemon terminal: on pane backends it creates a NON-VISIBLE tracked terminal and passes the captain endpoint as `FM_SUPERVISOR_TARGET` so the daemon injects into the captain, not its own new pane (docs/herdr-backend.md "Away-mode supervisor support").
  On the t3code backend there is no terminal to create, so `start` refuses and only the native path above works; a Codex captain hosted by T3 Code has no away daemon (docs/t3code-backend.md "Active limits").

Both daemon paths require the record `enter` wrote and share `bin/fm-afk-start.sh` as the daemon entry.
The daemon is **presence-gated**: it injects escalations only while `state/.afk` exists, and stays quiet otherwise.
