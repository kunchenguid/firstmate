# Captain decision alert

`bin/fm-decision-alert.sh` is the mechanism owner for audible and visible alerts when Firstmate needs a captain decision.
Its header and `--help` output own exact commands, environment variables, identity grammar, and marker paths.
This document records the integration boundaries, safety properties, supported-surface review, and verification evidence.

## Trigger boundaries

Worker-originated decisions alert automatically at the shared watcher surface boundary.
After `bin/fm-watch.sh` durably enqueues an actionable status wake, it passes the status file to `fm-decision-alert.sh status` before recording that status as surfaced.
The alert script folds the whole append-only stream through `status_open_decisions` from `bin/fm-classify-lib.sh` and selects only still-open `needs-decision` records.
It does not alert for `working`, `blocked`, `paused`, `done`, `failed`, `captain-held`, or `resolved` events.
The heartbeat backstop also scans open decisions after enqueue, so a missed per-signal path does not leave an unattempted alert.
The same watcher path runs while away mode is active, before the daemon performs its separate escalation classification.

Investigation and visual-review decisions alert automatically at the durable hold boundary.
`bin/fm-decision-hold.sh hold` first creates or updates the captain hold and verifies it active, then makes a best-effort alert attempt with the same origin and decision key used by a matching worker status.
A notifier failure therefore cannot prevent, weaken, or reverse the durable decision record.

Direct Firstmate approval prompts use the explicit `prompt` helper immediately before the captain-facing question.
`AGENTS.md` section 9 carries the always-loaded reminder, while the script help owns the invocation syntax.
This is the one non-automatic path because the supported primary harnesses expose lifecycle hooks, not one common semantic boundary for an outgoing assistant message that asks for approval.
Parsing rendered terminal output or model prose would be nondeterministic, would couple the alert to UI wording, and could expose decision text to notification channels.

## Stable identity and deduplication

Every alert uses a stable pair of privacy-safe slugs: the originating work identity and decision key.
The script hashes that pair and atomically claims an empty `state/.decision-alerted-<digest>` marker before notifier execution.
No decision summary, prompt text, project path, or other private content enters the marker name or body.
Worker status, durable hold, heartbeat recovery, and direct prompt delivery deduplicate when they use the same pair.
An `off` configuration does not consume the identity, so enabling alerts later can still notify for an open decision.
Once an enabled channel set claims the identity, notifier failure remains at most once and does not create a retry loop.
A genuinely new decision must use a new key, matching the existing decision-hold lifecycle rule.

## Channels and macOS behavior

Local gitignored `config/decision-alert` accepts one non-empty, non-comment channel directive per line.
`FM_DECISION_ALERT_CHANNEL` replaces the file with one directive for an invocation.
The supported directives are `off`, `auto` or `default`, `osascript`, `herdr`, and `command:<cmd>`.
An `off` directive disables the whole alert regardless of its position.
An absent file means `auto`.
On macOS, `auto` resolves to an OS-level Notification Center banner titled `Firstmate needs your decision` with the `Basso` system sound.
The notification body is deliberately generic, so a lock-screen banner or external channel never exposes the decision.
Other platforms have no built-in `auto` channel and can opt into `herdr` or a `command:` channel.
See [`examples/decision-alert`](examples/decision-alert) for a copyable file.

Every channel is bounded by `FM_DECISION_ALERT_TIMEOUT_SECS`, which defaults to 10 seconds.
The complete command is bounded by `FM_DECISION_ALERT_TOTAL_TIMEOUT_SECS`, which also defaults to 10 seconds and is shared across every open decision and configured channel in that invocation.
Heartbeat fleet scans use one `scan-state` invocation, so the total bound also covers every status file in the scan.
All enabled channel attempts for every open decision run concurrently within that shared deadline, so a hung notifier cannot starve a healthy fallback or a later decision.
All execution routes through `bin/fm-notify-lib.sh`, extracted from the existing wedge-alarm seam.
AppleScript receives title, body, and sound as argv items rather than source interpolation.
A configured command receives the generic body in `$1` and on stdin, never as shell source.
The library terminates the notifier process group on timeout so a background descendant cannot outlive the bound.

`FM_DECISION_ALERT_EXEC` replaces every real notifier with a test executable invoked with the resolved channel and generic body.
The special value `discard` executes nothing.
Sourcing `fm-decision-alert.sh` defaults the seam to `discard`, and `tests/lib.sh` exports `discard` for the complete behavior suite so tests that reach a real watcher or decision hold cannot post a notification or play a sound.

## Supported primary harness review

The supported primary harness review was performed on 2026-07-19 against the tracked integration files.

- Claude uses the `Stop` hook in `.claude/settings.json`, whose payload supports stop-loop control but does not identify the semantic content of the assistant message.
- Codex uses the `Stop` hook in `.codex/hooks.json`, with the same lifecycle-only boundary.
- OpenCode uses `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, which reports session lifecycle after output rather than classifying the output.
- Pi uses `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, which likewise has no shared approval-prompt semantic.
- Grok uses the passive `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json`, whose adapter receives session lifecycle data rather than a normalized outgoing-message decision event.

No harness-specific alert hook was added because none can provide complete equivalent semantics across all five supported primaries.
The automatic worker and hold boundaries are harness-independent, and the explicit direct-prompt helper is the smallest equivalent reminder available to every primary.

## Supported runtime backend review

The supported runtime backend review was performed on 2026-07-19 against `bin/fm-backend.sh`, `bin/backends/*.sh`, and the watcher integration.

- tmux, zellij, Orca, and cmux use the watcher's backend-neutral pull loop to synthesize status signals, then converge on the same post-enqueue surface function.
- Herdr adds a native `pane.agent_status_changed` fast path for `blocked`, but `blocked` is not sufficient evidence of a captain-owned decision and intentionally does not alert.
- Herdr status-file writes still use the same watcher signal path as every other backend, so a real `needs-decision` event receives automatic coverage.
- Away-mode injection supports only its separately verified supervisor backends, but decision alerting happens in the watcher before away-mode classification and therefore does not depend on the injection backend.

No runtime backend adapter changed because the authoritative input is the shared durable status stream, not terminal rendering, native pane status, or composer behavior.

## Verification record

Verification date: 2026-07-19.

```text
$ bash tests/fm-decision-alert.test.sh
ok - only open needs-decision events alert, and status/direct delivery deduplicates by origin and key
ok - off, environment override, and multi-channel config behave deterministically
ok - macOS uses an audible argv-safe notification and command data never becomes shell source
ok - notifier failure never blocks the decision path and repeated delivery stays at most once
ok - the watcher invokes the automatic boundary and library-mode tests default to discard

$ failures=0; count=0; for test_script in tests/*.test.sh; do count=$((count + 1)); output=$(bash "$test_script" 2>&1); rc=$?; if [ "$rc" -ne 0 ]; then failures=$((failures + 1)); fi; done; printf 'SUMMARY scripts=%s failures=%s\n' "$count" "$failures"; [ "$failures" -eq 0 ]
SUMMARY scripts=79 failures=0

$ nix-shell -p shellcheck --run 'bin/fm-lint.sh'
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)
```
