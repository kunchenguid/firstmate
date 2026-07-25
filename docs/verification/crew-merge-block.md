# Crewmate merge-block verification

Audience: maintainer verification.

This record supports the current guarantee that a claude crewmate's generated `.claude/settings.local.json` loads without a settings dialog and actually blocks the merge verbs.
The rules themselves and the reasoning behind them live in `bin/fm-crew-settings-lib.sh`; the enforced invariants live in `tests/fm-crew-settings.test.sh`.
Those tests are hermetic and never invoke `claude`, so this record holds the live-binary evidence they cannot carry.

## Conditions

Verified on 2026-07-25 with Claude Code 2.1.220 (native, commit `4073f59596e2`, darwin-arm64) and `gh` authenticated.
The two `claude doctor` sections below were re-run on 2026-08-13 with Claude Code 2.1.231 (native, commit `bbff368ec698`, darwin-arm64) after the settings document grew the semantic busy-state hooks, so the loads-clean evidence matches the document the library emits today.
The `--dangerously-skip-permissions` session table was not re-run: it exercises the rule patterns, and those are byte-for-byte unchanged by the hook addition.

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
  "permissions":{"ask":["Bash(gh pr merge:*)","Bash(gh-axi pr merge:*)","Bash(gh api *pulls/*/merge*)","Bash(gh api *repos/*/merges*)","Bash(gh api graphql*mergePullRequest*)","Bash(tk-feature land:*)","Bash(tk-feature-land:*)"]}}
```

The negative control was re-run in the same session: a directory carrying the malformed `Bash(gh api:*/merge*)` rules still produced the `Invalid settings` block quoted above, so the clean result here is a real pass rather than a version that stopped reporting.

## `permissions.ask` stops a crewmate that runs under `--dangerously-skip-permissions`

This is the load-bearing premise of the whole guard, so it was exercised in the crewmate's own shape rather than argued from documentation.
A session was launched non-interactively with exactly the flag `bin/fm-spawn.sh` uses, in a directory holding the generated file above, and asked to run each command and report whether the tool call executed:

```sh
claude -p --dangerously-skip-permissions '...run each command and report whether it executed...'
```

| Command | Result under `--dangerously-skip-permissions` |
|---|---|
| `gh --version` | executed, returned `gh version 2.95.0 (2026-06-17)` |
| `gh pr merge --help` | blocked, the tool call never reached the shell |
| `gh-axi pr merge --help` | blocked, the tool call never reached the shell |
| `gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:"PR_kwINVALID"}) { clientMutationId } }'` | blocked, nothing was sent to GitHub |
| `gh api repos/cli/cli/pulls/1/files` | executed, returned the file list from the API |

Each block surfaced as `Claude requested permissions to use Bash, but you haven't granted it yet.`

That message is the mechanism in one line: bypass mode skips the *prompt*, not the *rule*, and an unattended crewmate has no approver, so an ask it cannot answer is a stop.
`ask` rather than `deny` is therefore a proven control here, not an assumption.
The gated commands were chosen to be inert - `--help`, and a GraphQL mutation carrying a deliberately invalid node id - so a hypothetical non-match could only have printed help text or returned a GraphQL error, never landed a PR.

## The rules match the merge verbs and nothing else

The same run is the negative evidence too: `gh --version` and `gh api repos/cli/cli/pulls/1/files` both executed without a prompt.
Ordinary `gh api` reads a crewmate needs stay ungated, while `gh`, `gh-axi`, the two REST merge endpoints, and the inline GraphQL merge mutation are all covered.

Per-executable rules are required, not redundant: a rule is a prefix match on the literal `argv[0]` token, so `Bash(gh pr merge:*)` does not match `gh-axi pr merge` - the command the briefs hand a crewmate and the one `bin/fm-pr-merge.sh` lands PRs with.
The separate blocks for `gh pr merge --help` and `gh-axi pr merge --help` in the table above are what demonstrate that.

### Known residual

A GraphQL merge whose query text never appears on the command line - read from a file or piped in on stdin - matches no pattern here, because command-line rules cannot see it.
That path is out of scope by construction; the captain-only landing boundary in AGENTS.md section 1 is what covers it.
