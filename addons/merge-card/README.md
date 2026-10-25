# merge-card

`merge-card` remains the gate/check/post executable documented in the [add-on reference](../docs/addons-reference.md#merge-card).

Homes with `config/owner-rules` use the [owner-rules publication check](../owner-rules/README.md#lavish-refusal-secondmate-notes-and-merge-card-posts) before posting or restoring a card.
Its existing config shims are unchanged.

## Naming the claim

`merge-card post --board <board.json> --claim-id <id> <task-id> <worktree|-> <head|-> <pr-url|->` passes `--claim-id <id>` to the `done-done check` it runs, for a PR whose evidence is bound to a claim other than done-done's default (the PR branch name). The check re-runs even when the gate left a record. Without the flag nothing changes. `merge-card check` takes the same flag.

## Naming the judge for one call

`merge-card gate|check|post [--judge <route>]` passes `--judge <route>` to the `done-done check` it runs, so a lane whose configured judge route is rate limited can name another one for that merge instead of waiting on done-done's fallback. Without the flag nothing changes: done-done checks the proof with its own configured judge.

## The judge's account

The judge is a claude caller. In a home with a worker account pool (`config/account-pool`), the check runs it on the account the pool picks: the pool's pick answer carries the account's profile folder and the login variables the pool sheds, so the check's env carries `CLAUDE_CONFIG_DIR=<that folder>` and those variables unset, and the judge never answers on the default login. The pick is a read: it never rests an account and never mutates the pool. One line names the account that ran.

A failed pool read uses the last good pick with its age. Without a usable pick the judge is not started, and the real failure is reported. The cache contains only the account id, folder, variable names to unset, and timestamp. Sign-off and receipt adapters also apply this helper when their home has a configured pool.

## A merge never dirties the project clone

`merge-card` names the board for every card it files, and names it for the `done-done signoff` it runs in the work copy (`--board`: the post's board, or a file in the task's data folder for `check` and `gate`), so done-done's post opt-in cannot file into a `.sign-off/` board inside the project clone. A `.sign-off/` already in the work copy is reported on each post and left in place; remove it by hand.
