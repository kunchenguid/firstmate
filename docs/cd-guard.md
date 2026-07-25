# cd-guard PreToolUse seatbelt

This page is the concise human contract for the shell `cd` guard.
`bin/fm-cd-command-policy.mjs` owns command classification.
`bin/fm-cd-pretool-check.sh` owns hook transport, scope checks, JSON shaping, and fail-open handling.
The watcher-arm seatbelt is the sibling guard for watcher commands, and `docs/turnend-guard.md` owns the no-blind-turn backstop.

## Purpose and boundary

The guard stops a primary firstmate session from leaving the primary checkout with a shell `cd` and then accidentally operating as if it were still in the home that owns the fleet.
It is a seatbelt for interactive primary shells, not a general filesystem sandbox.
It does not stop scripts that intentionally self-locate after launch, and it does not police crewmate task worktrees.

The guarded scope is a plain firstmate checkout only.
Linked worktrees are out of scope so crewmates can change directories inside their disposable task copies.
Marked secondmate homes have their own primary session and use the same primary-scope predicate through the scripts that need it.
If the checker cannot prove the primary-home shape, it fails open rather than denying unrelated work.

## Block vs allow

The policy denies a command when its command-position `cd` would move the primary shell outside the current firstmate checkout.
It allows `cd` within the checkout, `cd .`, `cd ./subdir`, `pushd`-free commands that do not change the shell directory, and commands where `cd` appears only as text.
It preserves deliberate repo-local workflows while catching the hazardous shape that makes later relative commands operate against projects, task worktrees, or parent directories by accident.

The stable reason code is `cd-outside-primary`.
The exact operator-facing deny message is owned by the script so it can stay aligned with the current safe alternative.

## Transport

The checker accepts harness stdin payloads and command-line probes and exits with each harness's expected hook semantics.
Allow returns exit 0 with no denial object.
Deny returns the harness-shaped denial object with a cd-guard system message.
Malformed input, missing command fields, unsupported payloads, and missing optional transport dependencies fail open so a broken hook never blocks unrelated work.

The Grok hook command must use inline default expansions such as `${GROK_WORKSPACE_ROOT:-}` because Grok expands the raw hook command before `bash -lc` runs it.
This is the same hook-string constraint as the watcher-arm seatbelt.

## Shared classifier ownership

`bin/fm-arm-command-policy.mjs` exports the shell tokenizer and command-position walker used here.
`bin/fm-cd-command-policy.mjs` owns only the cd-specific decision logic.
Do not fork shell parsing into this page, the hook files, or tests.

## Validation

Automated coverage lives in `tests/fm-cd-pretool-check.test.sh` and the shared classifier tests.
The focused validation command is:

```sh
tests/fm-cd-pretool-check.test.sh
```

Run `bin/fm-lint.sh` after changing the scripts or hook files.
Historical live-run transcripts and payment-limit notes are not part of the maintained contract; retain only current harness quirks that change implementation behavior.
