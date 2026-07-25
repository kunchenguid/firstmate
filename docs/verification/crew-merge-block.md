# Crewmate merge-block verification

Audience: maintainer verification.

This record supports the current guarantee that a claude crewmate's generated `.claude/settings.local.json` loads without a settings dialog and actually blocks the merge verbs.
The rules themselves and the reasoning behind them live in `bin/fm-crew-settings-lib.sh`; the enforced invariants live in `tests/fm-crew-settings.test.sh`.
Those tests are hermetic and never invoke `claude`, so this record holds the live-binary evidence they cannot carry.

## Conditions

Verified on 2026-07-25 with Claude Code 2.1.220 (native, commit `4073f59596e2`, darwin-arm64) and `gh` authenticated.
The two `claude doctor` sections below were re-run on 2026-08-13 with Claude Code 2.1.231 (native, commit `bbff368ec698`, darwin-arm64) after the settings document grew the semantic busy-state hooks, so the loads-clean evidence matches the document the library emits today.
The endpoint-matching table was not re-run; it exercises the rule patterns, which are unchanged.

## Rule syntax is validated, and an invalid rule is skipped

Claude Code treats `:*` as prefix-match syntax that is legal only at the end of a pattern.
A malformed rule is not a warning that degrades gracefully; it is dropped.

Running `claude doctor` in a directory whose `.claude/settings.local.json` carried `Bash(gh api:*/merge*)` and `Bash(gh api:*/merges*)`:

```
Invalid settings
- .../settings.local.json › permissions.ask: Invalid permission rule "Bash(gh api:*/merge*)" was skipped: The :* pattern must be at the end. Move :* to the end for prefix matching, or use * for wildcard matching
- .../settings.local.json › permissions.ask: Invalid permission rule "Bash(gh api:*/merges*)" was skipped: The :* pattern must be at the end. Move :* to the end for prefix matching, or use * for wildcard matching
```

`was skipped` is the load-bearing detail: such a rule blocks nothing while a fresh spawn also stops on a blocking settings dialog.

## The generated file loads with zero warnings

Generating the real file from the library and running `claude doctor` beside it:

```sh
( . bin/fm-crew-settings-lib.sh
  fm_crew_settings_local_json /tmp/fmtest/state/demo.turn-ended \
    /opt/firstmate/bin/fm-busy-event.sh /tmp/fmtest/state demo 7-1 ) > .claude/settings.local.json
claude doctor
```

`claude doctor` printed no `Invalid settings` section, and the file retained every busy-state hook and the turn-end touch alongside `permissions.ask` (line-wrapped here for reading; the real file is one line):

```json
{"hooks":{
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"'/opt/firstmate/bin/fm-busy-event.sh' apply '/tmp/fmtest/state' 'demo' busy --gen '7-1' --source claude-hook --event user-prompt-submit 2>/dev/null || true"}]}],
  "Stop":[{"hooks":[{"type":"command","command":"touch '/tmp/fmtest/state/demo.turn-ended'; '/opt/firstmate/bin/fm-busy-event.sh' apply '/tmp/fmtest/state' 'demo' idle --gen '7-1' --source claude-hook --event stop 2>/dev/null || true"}]}],
  "StopFailure":[{"hooks":[{"type":"command","command":"'/opt/firstmate/bin/fm-busy-event.sh' apply '/tmp/fmtest/state' 'demo' idle --gen '7-1' --source claude-hook --event stop-failure 2>/dev/null || true"}]}],
  "SessionEnd":[{"hooks":[{"type":"command","command":"'/opt/firstmate/bin/fm-busy-event.sh' apply '/tmp/fmtest/state' 'demo' idle --gen '7-1' --source claude-hook --event session-end 2>/dev/null || true"}]}]},
  "permissions":{"ask":["Bash(gh pr merge:*)","Bash(gh api *pulls/*/merge*)","Bash(gh api *repos/*/merges*)","Bash(tk-feature land:*)","Bash(tk-feature-land:*)"]}}
```

The negative control was re-run in the same session: a directory carrying the malformed `Bash(gh api:*/merge*)` rules still produced the `Invalid settings` block quoted above, so the clean result here is a real pass rather than a version that stopped reporting.

## The rules match the merge endpoints and nothing else

Matching was exercised against the live permission engine with the same patterns placed under `permissions.deny`, so a non-match would execute and return an HTTP error instead of being refused.
Commands targeted a nonexistent repository, so a permitted call could only reach a 404.

| Command | Result |
|---|---|
| `gh api --method PUT repos/<none>/nope/pulls/1/merge` | refused by the permission engine |
| `gh api --method POST repos/<none>/nope/merges` | refused by the permission engine |
| `gh api repos/<none>/nope/pulls/1/files` | permitted, reached the API and returned 404 |

The refusal surfaced as `Permission to use Bash with command gh api --method PUT repos/<none>/nope/pulls/1/merge has been denied.`

This is the intended shape: both merge endpoints are covered, while the ordinary `gh api` reads a crewmate needs remain ungated.
`permissions.ask` is used in production rather than `deny` because a crewmate launches with `--dangerously-skip-permissions` and has no approver behind it, so an unanswerable ask is the stop.
