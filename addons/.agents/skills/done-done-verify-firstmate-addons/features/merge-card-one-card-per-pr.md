# Merge evidence one card per PR

## User outcome

The Evidence board shows one card for each PR, whoever filed it: a re-proof at a new head replaces the card and keeps the newest proof, other filers' cards for that PR are archived (the newest card with a passed-test receipt stays), and a screen-free merge's card is titled with its repo and PR number.

## Drive

Run `bash merge-card/tests/merge-card-e2e.sh` from the repository root. It posts to a fixture board through a stub sign-off-axi and never touches a real board.

## Evidence

The `new head`, `two PRs` and `internal title` assertions print `ok`; the run ends with `all assertions held`.

## The no-screen path and a citation outside the run

Run `bash merge-card/tests/merge-card-e2e.sh` and `bash owner-rules/tests/owner-rules-gate.test.sh`.
A PR whose Checks block declares `screen: none` and whose task folder holds a sealed clean run posts a text-only card with no capture (the `internal` assertions).
The gate's output opens with the one line saying it took that path (the `screen: none: the text-only line is the gate's first line` assertion).
A claim that cites a file the sealed run does not hold is redirected to the run's own capture with one line naming it: `internal: the card cites the run's own capture` and `hand capture: the claim is checked against the run's capture` print `ok`.
A claim no sealed run supports is still refused (`no supporting run`, `run without a capture` and `no run to redirect to`).

## Real sign-off-axi

Run `bash merge-card/tests/real-board.test.sh`. It runs the real `merge-card post` against the real `sign-off-axi` on a seeded temp board (its own `SIGN_OFF_HOME`), posts a PR's card at one head and again at a new head, and prints `all assertions held` when exactly one card is live, the old one is archived with its history kept, and a repeat post adds nothing.

A third post passes head `-` the way the merge hook does for a PR (a stub `gh` answers `headRefOid`): the `hook head dash` assertion prints `ok` when the screen: none card carries the run sealed at the PR head; without the head lookup it prints `no passed-test receipt` and fails.

## Across filers and on a live board

`real-board.test.sh` also posts another filer's card for the PR before the merge (the merge's post archives it) and a newer one without a receipt after it: the `sweep` assertions print `ok` when the dry run names that card and changes nothing, `--apply` archives it while the merge's receipt card stays, and a rerun archives nothing.

For a live board, copy `board.json` and its `board.*.jsonl` files into a temp folder and run `merge-card/one-card-per-pr <copy>/board.json` (then `--apply` on the copy) to see the plan. On the live board, archive only with supported `sign-off-axi dismiss <key> <board>` commands from that plan, and keep the before and after `one-card-per-pr` output as evidence.
