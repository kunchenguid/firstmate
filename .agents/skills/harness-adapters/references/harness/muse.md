# Muse Code

Verified 2026-08-05 on Muse Code 0.1.0-R708.1, build sha 427a430436.
The router owns Muse's task-kind boundary.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `muse` from `PATH`, refused if absent; launcher `~/.local/bin/muse` execs versioned `muse-bin-<version>`, so live process name changes on update. |
| Launch | Positional instructions, like Grok or Pi. |
| Models | `--model <model>`; only provider `meta`. |
| Busy | Durable session event log folded by `../../../bin/fm-busy-lib.sh`; no hook or plugin writer, arming, or seeded busy record. |
| Exit | `/exit`, one Enter; prints `To continue this session, run muse resume <session-uuid>`. |
| Interrupt | Single Escape records `terminal: cancelled` and restores bright prompt text, so control follows with `Ctrl+U`; the legacy typed key path uses the same clear table. |
| Skill | `/<skill>`, the Claude or Grok form. |
| Resume | `muse resume --last` or `muse resume <session-uuid>`; bare `muse resume` opens a picker. |
| Autonomy | `--yolo` disables approval and sandbox and trusts the workspace. |
| Trust | Dialog `Do you trust this workspace?`, choice `1 Trust and continue` preselected for Enter; `--yolo` suppresses it, which fresh task paths require. |
| Marker | None; identity comes from anchored `muse-bin-*` ancestry, which `../../../bin/fm-harness.sh` keeps a retained foreign marker from overriding, while `MUSE_CURRENT_SESSION_LOG` is a path rather than identity and its export to tools is unverified. |
| Composer | Bordered `⟩`, truecolor `38;2;90;160;255`, luminance about 149.9 and narrowly above ghost threshold 128; typed text is `38;2;204;211;219`, about 209.8, with no observed placeholder or ghost. |
| Effort | `--reasoning-effort`, default `high`, accepts `none\|minimal\|low\|medium\|high\|xhigh\|ultra`; shared values expose low through xhigh, explicit captain `max` maps to `ultra`, and `none` or `minimal` remain unreachable. |

## Credential preflight

Muse reads winning `META_API_KEY` or `${XDG_CONFIG_HOME:-$HOME/.config}/muse/auth.json` written by OIDC device-code `muse login` or `muse auth set --api-key-stdin`.
The spawn accepts the environment key only if the backend worker already has it: caller-only variables do not cross a long-lived daemon, and secrets never enter argv.
Stored credentials are the supported fleet path.
It resolves non-secret `XDG_CONFIG_HOME` and `XDG_DATA_HOME` absolutely before preflight and forwarding, keeping auth and logs aligned.

With neither worker-reachable credential, spawn refuses.
Unauthenticated Muse otherwise waits forever at `Sign in at this page: https://auth.meta.com/oauth/device/?code=XXXX-XXXX` and `Waiting for approval…`, which resembles a wedge.
Escalate the refusal as a needed credential.

## Foreign personal context

Muse sends operator rules from `~/.claude` to Meta-hosted inference on every run.
Its notice names Claude personal rules and `/settings` but appears only once through `tui.foreign_context_notice_shown`, so later silence proves nothing; isolated `XDG_CONFIG_HOME` does not prevent loading.

Interactive Muse rejects exec-only `--no-foreign-personal-context`.
The pane control is `MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on`, set on every spawn and verified to remove foreign `rules_file` while retaining project `AGENTS.md`.

## Session event log

Logs live at `${XDG_DATA_HOME:-$HOME/.local/share}/muse/sessions/YYYY/MM/DD/<session-uuid>/session.jsonl`.
The spawn writes `state/<id>.muse-session` with root, worktree, binding incarnation, and pre-existing matching main logs, then unique resolution pins `state/<id>.muse-session-current`.
It folds that path while the bounded current-day main namespace is unchanged and resolves again if the namespace changes, path disappears, or a newer binding wins.

Turns are bracketed by `{"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"started"` and matching `"event":{"kind":"terminal"`, observed as `completed` or `cancelled`.
Interrupt therefore has a real terminal, unlike Claude Stop.
Never use `--no-session-log`, which removes Muse's only busy source.

The fold must reject nested `"record":{"kind":"terminal"}` cleanup effects and depth-bound away native sub-agent logs under `subagent/<child-session-id>/session.jsonl`.
The recorded resolved `XDG_DATA_HOME` is also forwarded to the worker, preserving daemon alignment.
An open run is trusted busy and settled log trusted idle; missing binding or match, unreadable log, or run-free log is unknown.
`../../../docs/verification/muse.md` owns credentialed idle evidence and refresh.

## Native sub-agents and worktrees

Native children use per-child worktrees only with opt-in `--subagent-worktree-isolation`; capability says default-on while omission stays shared, and verified labs produced no nested copy.
`../../../bin/fm-teardown.sh` excludes no Muse path.
It excludes `.claude/settings.local.json` because Firstmate writes it, but Muse scratch is worker output and must refuse cleanup when uncommitted.
Inspect, never force past, that refusal.

## Maturity and primary limit

Muse 0.1.0 is day-zero beta; its hourly channel poll can replace the binary and process name.
The captain accepted this, so Firstmate does not set `MUSE_NO_AUTO_UPDATE=1`; a fleet may set it without adapter change.
Plugins report unavailable unless `MUSE_EXPERIMENTAL_PLUGINS=on`, so busy state uses logs.
The compatibility dialect explicitly lacks `asyncRewake` and model reawakening; the router owns the resulting primary boundary.
