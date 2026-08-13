# Crewmate merge-block verification

Audience: maintainer verification.

This record supports the current guarantee that a claude crewmate's generated `.claude/settings.local.json` loads without a settings dialog and actually blocks the merge verbs.
The rules themselves and the reasoning behind them live in `bin/fm-crew-settings-lib.sh`; the enforced invariants live in `tests/fm-crew-settings.test.sh`.
Those tests are hermetic and never invoke `claude`, so this record holds the live-binary evidence they cannot carry.

## Conditions

First verified on 2026-07-25 with Claude Code 2.1.220 (native, commit `4073f59596e2`, darwin-arm64) and `gh` authenticated.
The evidence below was not all captured in that one session, so each section names the run it came from and no claim here rests on a run other than the one printed beside it.

The two `claude doctor` sections were re-run on 2026-08-13 with Claude Code 2.1.231 (native, commit `bbff368ec698`, darwin-arm64) after the settings document grew the semantic busy-state hooks, so the loads-clean evidence matches the document the library emits today.
The `--dangerously-skip-permissions` session table was itself re-run later on 2026-07-25, when `Bash(gh-axi pr merge:*)` and `Bash(gh api graphql*mergePullRequest*)` were added to the rule list, because neither rule existed earlier that day; its commands and its refusal wording therefore differ from the `permissions.deny` matching run that preceded it, and both runs are kept because neither covers the other's patterns.
That later run is the one section here whose Claude Code build is not pinned - the reason is recorded with the table itself rather than summarized away here.

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

Captured on 2026-07-25, after `Bash(gh-axi pr merge:*)` and `Bash(gh api graphql*mergePullRequest*)` joined the rule list, against the seven-rule document quoted above.
The Claude Code build for this run was not captured when it was taken, and nothing in the repository records it, so it is left unstated rather than guessed.
The date is the only pin this table has: it is the same day as the 2.1.220 session named in Conditions, which makes 2.1.220 the likeliest build, but that is read off the date rather than observed.
Since the `was skipped` behavior above shows this engine's rule handling is version-sensitive, treat this table as evidence for the mechanism and not for any particular release, and re-run it if a specific build ever has to be established.

This is the load-bearing premise of the whole guard, so it was exercised against the live permission engine rather than argued from documentation.
A session was launched with exactly the flag `bin/fm-spawn.sh` uses, in a directory holding the generated file above, and asked to run each command and report whether the tool call executed:

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

### What this transcript does and does not prove

The flag matches production; the mode does not.
`bin/fm-spawn.sh` launches a crewmate interactively (`claude --dangerously-skip-permissions "$(... launch-brief ...)"`, no `-p`), while the run above used `-p`.
What carries across is the part that matters here: the rule is evaluated, and the merge verb does not execute, under `--dangerously-skip-permissions`.
What does not carry across is the *shape of the stop*.
With no TTY, `-p` returns the unanswerable ask to the model as an immediate tool-call refusal, which is why the transcript shows the session continuing to the next command.
In the interactive TUI a crewmate actually runs in, the same rule can instead surface as a pane-blocking prompt: the merge is stopped just as effectively, but the turn never ends, so the Stop hook never fires and the watcher sees a wedged crewmate rather than a refused one.
Either outcome satisfies the guard - the crewmate does not land its own work - but they reach the watcher differently, so do not read this transcript as evidence about the interactive surface.

## The rules match the merge verbs and nothing else

The same run is the negative evidence too: `gh --version` and `gh api repos/cli/cli/pulls/1/files` both executed without a prompt.
Ordinary `gh api` reads a crewmate needs stay ungated, while `gh pr merge`, `gh-axi pr merge`, and the inline GraphQL merge mutation are blocked.
That table carries no `gh api ... /merge` row, so it is not evidence for `Bash(gh api *pulls/*/merge*)` or `Bash(gh api *repos/*/merges*)`; those two patterns are covered by the separate matching run below.

Per-executable rules are required, not redundant: a rule is a prefix match on the literal `argv[0]` token, so `Bash(gh pr merge:*)` does not match `gh-axi pr merge` - the command the briefs hand a crewmate and the one `bin/fm-pr-merge.sh` lands PRs with.
The separate blocks for `gh pr merge --help` and `gh-axi pr merge --help` in the table above are what demonstrate that.

### The two REST merge endpoint patterns match

Captured in the first 2026-07-25 session, before the `gh-axi` and GraphQL rules existed; the two `gh api` patterns it exercises are byte-for-byte the ones the library emits today.

Matching was exercised against the live permission engine with the same patterns placed under `permissions.deny`, so a non-match would execute and return an HTTP error instead of being refused.
Commands targeted a nonexistent repository, so a permitted call could only reach a 404.

| Command | Result |
|---|---|
| `gh api --method PUT repos/<none>/nope/pulls/1/merge` | refused by the permission engine |
| `gh api --method POST repos/<none>/nope/merges` | refused by the permission engine |
| `gh api repos/<none>/nope/pulls/1/files` | permitted, reached the API and returned 404 |

The refusal surfaced as `Permission to use Bash with command gh api --method PUT repos/<none>/nope/pulls/1/merge has been denied.`

`deny` is what this run measured; production ships `ask`. What transfers is the pattern match, which is the same rule engine either way - the section above is what establishes that an unanswerable `ask` is a stop under `--dangerously-skip-permissions`, and the wording difference between the two refusal messages is exactly that difference in mode, not a disagreement between the runs.

### Known residual

A GraphQL merge whose query text never appears on the command line - read from a file or piped in on stdin - matches no pattern here, because command-line rules cannot see it.
That path is out of scope by construction; the captain-only landing boundary in AGENTS.md section 1 is what covers it.
