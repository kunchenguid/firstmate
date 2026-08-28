---
name: upstream-sync
description: >-
  Agent-only checklist for the weekly catch-up of the withally/firstmate fork with kunchenguid/firstmate.
  Use when the captain asks to sync, catch up, snapshot, or rebase onto upstream, or when the weekly upstream sync is due.
  Owns the tier decision (weekly or monthly validation), the fixed worker brief, the PR verdict table and its inputs, the isolated Herdr lab setup, and the optional urgent-upstream tripwire, so the sync is a follow-the-checklist job rather than a re-authored brief.
user-invocable: false
metadata:
  internal: true
---

# upstream-sync

The procedural spine is [`docs/upstream-sync.md`](../../../docs/upstream-sync.md).
That document owns the remotes, the branch-at-upstream rule, the snapshot-commit audit window, the keep rule, and the catch-up log.
This skill does not restate it; it adds only what the standing procedure needs to run without a re-authored brief: the tier decision, the fixed worker brief, the exact commands, the PR verdict table, the Herdr lab setup, and the optional urgent-upstream tripwire.

Standing captain rulings (2026-08-27), each implemented below:

1. The keep-list is decided by the worker under the doc's keep rule and reviewed once, at the PR, with no mid-flight captain gate.
2. Validation is two-tier: weekly runs lint plus the tests colocated with the kept diff, monthly runs the full suite including the Herdr lab.
3. Unrelated breakage found during a sync is filed as follow-up work, never fixed on the sync branch.
4. The instructions are standing: this skill and the doc, never a re-authored brief.
5. The Herdr lab setup is documented once, in [`references/herdr-lab.md`](references/herdr-lab.md).

## Optional urgent-upstream tripwire

The tripwire is an opt-in registered custom check for commits added to `upstream/main` after the latest adopted upstream base in `docs/upstream-sync.md`.
It performs one fetch per check, matches only `security`, `CVE`, `breaking`, `revert`, `data loss`, or `credential` in a commit subject or body, and stays silent otherwise.
On a hit it emits one line naming the matching commit and subject, so the existing watcher delivers one actionable check wake for an out-of-cycle sync decision.
That line is emitted once per matching commit set, because `state/.upstream-urgent` records the set the last report was made from, and a set unchanged since that report stays silent.
An armed but unusable tripwire - no readable base, no `upstream` remote, a non-canonical `upstream` remote, or a recorded base that is not a commit here or not an ancestor of `upstream/main` - reports one diagnostic on stderr for a hand run, but emits no stdout and never wakes firstmate.
None of those clear on a retry, so the tripwire is dead until someone repairs the catch-up log or the remote.
A retryable failure - a failed fetch, a missing ref right after one, an unreadable log - stays off that path entirely and only sets stderr and a non-zero exit, so a flapping link never wakes firstmate.
It does not invoke an LLM, open a review window, or make a captain call by itself.

Arm it from the firstmate code root with `bin/fm-upstream-urgent-check.sh arm`.
Disarm it with `bin/fm-upstream-urgent-check.sh disarm`.
The arm command writes and trust-registers `state/upstream-urgent.check.sh`, and disarm removes that shim, its trust binding, and the `state/.upstream-urgent` report record.
The check is not active unless it is armed, and the normal watcher cadence owns when the registered check runs.

## Firstmate intake (dispatcher)

Firstmate resolves eight values and nothing else: `UPSTREAM_BASE`, `SNAPSHOT`, `SETTLED`, `VERDICT_INPUT_1`, `VERDICT_INPUT_2`, `VERDICT_INPUT_3`, `TIER`, and `DATE`; the brief is fixed text.

1. Fetch and record the base.

   ```sh
   git remote get-url upstream >/dev/null 2>&1 || git remote add upstream git@github.com:kunchenguid/firstmate.git
   case "$(git remote get-url upstream)" in
     git@github.com:kunchenguid/firstmate|git@github.com:kunchenguid/firstmate.git|\
     ssh://git@github.com/kunchenguid/firstmate|ssh://git@github.com/kunchenguid/firstmate.git|\
     https://github.com/kunchenguid/firstmate|https://github.com/kunchenguid/firstmate.git) ;;
     *) echo 'blocked: upstream remote does not point at kunchenguid/firstmate'; exit 1 ;;
   esac
   git remote set-url --push upstream DISABLED
   git fetch upstream --prune && git fetch origin --prune
   UPSTREAM_BASE=$(git rev-parse --short=12 upstream/main)
   SNAPSHOT=$(git log origin/main --first-parent --format='%h%x09%s' | awk -F'\t' '$2 ~ /^chore: snapshot upstream main/ {print $1; exit}')
   LOG=$(git show origin/main:docs/upstream-sync.md 2>/dev/null) || LOG=''
   SETTLED=<window end commit named by the newest catch-up log row in "$LOG", empty when "$LOG" is empty>
   [ -z "$LOG" ] || [ -n "$SETTLED" ] || { echo 'blocked: origin/main has a catch-up log whose newest row names no window end commit'; exit 1; }
   if [ -n "$SETTLED" ] && git merge-base --is-ancestor "$SETTLED" "$SNAPSHOT"; then SNAPSHOT=$SETTLED; fi
   [ -n "$UPSTREAM_BASE" ] && [ -n "$SNAPSHOT" ] || { echo 'blocked: no upstream tip or no snapshot commit'; exit 1; }
   ```

   Run these from the firstmate code root; a fetch updates remote-tracking refs only and touches no checkout, and the worker repeats it in its own worktree.
   Read the log out of `origin/main` rather than the checkout for exactly that reason: the code root may sit on a stale commit or a branch without the spine, and a row read from there would resolve `SETTLED` empty and silently drop the window back to the marker.
   An absent log leaves `SETTLED` empty and the marker as the boundary for this block alone, since step 2 then stops the dispatch outright; a log whose newest row names no window end is instead a misrecorded sync and stops here rather than losing the fork PRs that merged during its review.
   Two boundaries can disagree: the first-parent marker, and the window end commit named by the newest catch-up log row.
   The override only ever moves the boundary earlier, so it can only widen the window, never narrow it.
   The asymmetry is deliberate: an over-wide window merely re-issues a verdict for a PR already settled, while an under-wide one silently drops kept fork behavior that never gets cherry-picked onto the new base.
   That direction is also what makes a row whose catch-up never landed harmless: the worst such a row can do is widen the audit set, never narrow it.
   Record the resolved `SNAPSHOT` and the `SETTLED` it came from in the brief; the worker cannot re-derive them, because it branches at `upstream/main` where `docs/upstream-sync.md` does not exist.
2. Determine the tier from the `Next monthly full run` line in the `$LOG` step 1 read out of `origin/main`, never from the checkout.
   The sync is `monthly` when today's date is on or after that line's date and no catch-up log row in `$LOG` already records a `monthly` tier on or after it; otherwise it is `weekly`.
   A stale code root is why this reads the merged copy: it would still show the pre-advance date with no monthly row after it, and every later weekly dispatch would resolve `monthly` and run the full suite.
   Stop with `blocked: origin/main carries no upstream-sync doc; the tier rule has no source` when `$LOG` is empty, rather than guessing a tier; that is the one disposition of an absent log, and it is why step 1's empty-`SETTLED` fallback never reaches a real sync.
   The captain set the next monthly full run to 2026-10-01 and deliberately skipped September, so a September Saturday is `weekly` even though it falls after the 1st.
   Do not ask; the line plus the log answer the question.
3. Scaffold the brief with the tier-matched flags.
   The delivery mode is `no-mistakes`, the doc's standing PR path; its Test step is intent-targeted, so it does not re-run the full suite and stays inside the weekly tier.

   ```sh
   bin/fm-brief.sh <task-id> firstmate --mode no-mistakes                # weekly, no Herdr expected
   bin/fm-brief.sh <task-id> firstmate --mode no-mistakes --herdr-lab   # weekly known to touch Herdr, or after a blocked: regeneration
   bin/fm-brief.sh <task-id> firstmate --mode no-mistakes --herdr-lab   # monthly, always
   ```

   A monthly tier always needs `--herdr-lab` because the full suite drives Herdr lifecycle behavior through the lab.
   A weekly tier normally does not; if the kept diff later turns out to select the `real-herdr-gated` family, the worker stops with `blocked: sync touches Herdr, brief needs --herdr-lab`, and Firstmate reissues the same brief with `--herdr-lab` rather than letting the worker add lab commands by hand.
   The regenerated weekly brief is what lets the worker run the Herdr family locally in step 10; regenerating it and then skipping that run leaves the lab contract unused.
4. Replace `{TASK}` with [`references/worker-brief.md`](references/worker-brief.md), filling only `UPSTREAM_BASE`, `SNAPSHOT`, `SETTLED`, `VERDICT_INPUT_1`, `VERDICT_INPUT_2`, `VERDICT_INPUT_3`, `TIER`, and `DATE`.
   Read the backlog item `upstream-sync-20260829-verdict-inputs` through the configured backlog backend and copy its three shortlisted behavior entries into `{VERDICT_INPUT_1}`, `{VERDICT_INPUT_2}`, and `{VERDICT_INPUT_3}` exactly as written, one entry per placeholder.
   Stop with `blocked: verdict-input backlog item is missing or does not contain exactly three behavior entries` when that item cannot supply exactly three entries, rather than guessing or dropping an input.
5. Spawn per `AGENTS.md` section 7, record the sync as work under way, and supervise as usual.
6. At the PR, relay the verdict table to the captain with the full PR URL; the captain rules once at merge.
7. After the merge, refresh the clone through the guarded fleet-sync path, then confirm the snapshot marker actually landed on `origin/main`'s first-parent line, and when the tier was `monthly`, confirm the worker advanced the `Next monthly full run` line to the first day of the following month.
   Every window search (intake step 1, worker step 3, the doc's step 3) reads that marker, so a merge that leaves it off first-parent makes the next sync silently reuse the previous snapshot and re-audit everything this sync already reconciled.
   The block needs this sync's PR number at hand and a `gh` authenticated against the fork; it compares that PR's own merge commit with the marker, so no value from intake step 1's shell has to survive.
   The marker search is subject-anchored rather than `--grep`, because `--grep` matches any line of the message and a merge commit carries the PR title in its body — which would make a merge-commit merge look correctly marked while step 5's subject-keyed exclusion still misses it.

   ```sh
   git fetch origin --prune
   MERGED=$(gh pr view <this sync's PR number> --json mergeCommit -q .mergeCommit.oid)
   case "$MERGED" in ''|null) echo 'blocked: this sync PR reports no merge commit; it is unmerged or gh cannot read it'; exit 1 ;; esac
   MARKER=$(git log origin/main --first-parent --format='%H%x09%s' | awk -F'\t' '$2 ~ /^chore: snapshot upstream main/ {print $1; exit}')
   [ -n "$MARKER" ] || { echo 'blocked: origin/main first-parent carries no snapshot marker at all'; exit 1; }
   [ "$MARKER" = "$MERGED" ] || { echo 'blocked: this sync merged without putting the marker on origin/main first-parent; re-land it as a squash merge under the marker title before the next sync'; exit 1; }
   ```

   The test is that this sync's own merge commit *is* the latest first-parent marker, not that the marker is `origin/main`'s tip.
   Unrelated fork PRs land after the sync merge all the time, and each one moves the tip without touching this invariant.
   Comparing against the brief's `SNAPSHOT` instead would pass vacuously whenever the catch-up-log override resolved it to a commit older than the previous marker, which is the steady state; a merge commit or a rebase merge would then go undetected and the next sync would cherry-pick that squash and rewind the base.

## Worker checklist

Each numbered step maps onto the same-numbered step of the doc's weekly procedure where one exists; the doc owns the rule, this list owns the command.

1. Verify isolation per the brief, bind the brief's recorded values into this shell, ensure both remotes, and confirm the recorded base is still reachable from `upstream/main`.
   Every later step consumes `$UPSTREAM_BASE` and `$SNAPSHOT`, so bind them before anything else and keep working in the same shell; an unset `SNAPSHOT` makes step 4's range silently mean `HEAD..origin/main`, which is the over-wide set step 5 forbids.
   `UPSTREAM_BASE` is a deliberate pin, so ordinary upstream movement between intake and this step is fine and next week's sync absorbs it; the check is reachability, not equality.
   Only a base that is no longer an ancestor of `upstream/main` is disqualifying, because that means upstream history was rewritten or the recorded value never came from this parent.
   The `upstream` remote setup is the doc's step 1; a clone that never ran it has `origin` only, and a clone where someone pointed `upstream` at some other fork must fail rather than record that fork's tip as the base.

   ```sh
   UPSTREAM_BASE=<UPSTREAM_BASE from the brief>
   SNAPSHOT=<SNAPSHOT from the brief>
   [ -n "$UPSTREAM_BASE" ] && [ -n "$SNAPSHOT" ] || { echo 'blocked: brief is missing UPSTREAM_BASE or SNAPSHOT'; exit 1; }
   git remote get-url upstream >/dev/null 2>&1 || git remote add upstream git@github.com:kunchenguid/firstmate.git
   case "$(git remote get-url upstream)" in
     git@github.com:kunchenguid/firstmate|git@github.com:kunchenguid/firstmate.git|\
     ssh://git@github.com/kunchenguid/firstmate|ssh://git@github.com/kunchenguid/firstmate.git|\
     https://github.com/kunchenguid/firstmate|https://github.com/kunchenguid/firstmate.git) ;;
     *) echo 'blocked: upstream remote does not point at kunchenguid/firstmate'; exit 1 ;;
   esac
   git remote set-url --push upstream DISABLED
   git fetch upstream --prune && git fetch origin --prune
   git rev-parse --verify --quiet "$SNAPSHOT^{commit}" >/dev/null || { echo 'blocked: SNAPSHOT is not a commit in this clone'; exit 1; }
   git merge-base --is-ancestor "$UPSTREAM_BASE" upstream/main || { echo 'blocked: recorded UPSTREAM_BASE is not an ancestor of upstream/main; upstream history was rewritten or the base is not upstream material'; exit 1; }
   ```

2. Branch directly at the upstream tip.

   ```sh
   git checkout -b fm/<task-id> "$UPSTREAM_BASE"
   ```

3. Confirm the audit window from the recorded snapshot commit.
   Step 1 only proves `SNAPSHOT` is a commit in this clone; this step catches a marker that moved after intake, which would mis-size step 4's range.

   ```sh
   git log origin/main --first-parent --format='%H%x09%cs%x09%s' | awk -F'\t' '$3 ~ /^chore: snapshot upstream main/ {print; exit}'
   MARKER=$(git log origin/main --first-parent --format='%H%x09%s' | awk -F'\t' '$2 ~ /^chore: snapshot upstream main/ {print $1; exit}')
   SETTLED=<SETTLED recorded in this sync's brief, empty when the brief records none>
   [ -n "$SNAPSHOT" ] && [ -n "$MARKER" ] || { echo 'blocked: SNAPSHOT is unbound or origin/main carries no snapshot marker'; exit 1; }
   git merge-base --is-ancestor "$SNAPSHOT" origin/main || { echo 'blocked: SNAPSHOT is not reachable from origin/main; brief needs a fresh SNAPSHOT'; exit 1; }
   EXPECTED=$MARKER
   if [ -n "$SETTLED" ] && git merge-base --is-ancestor "$SETTLED" "$EXPECTED"; then EXPECTED=$SETTLED; fi
   [ "$(git rev-parse "$SNAPSHOT^{commit}")" = "$(git rev-parse "$EXPECTED^{commit}")" ] || { echo 'blocked: the window boundary moved since intake; brief needs a fresh SNAPSHOT'; exit 1; }
   ```

   `SETTLED` comes from the brief, never from the working tree: step 2 branched at `upstream/main`, where `docs/upstream-sync.md` does not exist, so re-deriving it here would resolve to empty and block a sync whose boundary is correct.
   The check is therefore narrow by design: when the brief records a `SETTLED`, that value stays the boundary and a concurrent sync's newer marker cannot trip this guard.
   That is safe rather than complete — the resulting window is over-wide and the concurrent sync's own squash inside it is excluded by step 5 — but do not read this step as proving the boundary is still what intake would resolve today.
   Read the current log with `git show origin/main:docs/upstream-sync.md` when you need the live row for any other reason.

4. List the fork PRs after that snapshot; this is the complete audit set.

   ```sh
   [ -n "$SNAPSHOT" ] || { echo 'blocked: SNAPSHOT unset; an empty range endpoint silently means HEAD'; exit 1; }
   WINDOW_END=$(git rev-parse --verify origin/main)
   [ -n "$WINDOW_END" ] || { echo 'blocked: could not resolve origin/main for the window end'; exit 1; }
   echo "WINDOW_END=$WINDOW_END"
   git log --reverse --first-parent --format='%h%x09%cs%x09%s' "$SNAPSHOT".."$WINDOW_END"
   ```

   Pin `WINDOW_END` here and carry that exact value to step 12; never re-read `origin/main` later.
   The `echo` is what makes it recoverable: an empty window prints no log lines, so without it the pinned value would exist only in a shell that is gone by the time the row is written.
   `--verify` matters too, because plain `git rev-parse` on a missing ref writes the ref name to stdout and exits 128, which would satisfy the non-empty guard with garbage.
   Steps 6 through 12 take hours, and a fork PR that merges in the meantime would otherwise become the recorded boundary — landing in no sync's audit set, getting no verdict, and never being cherry-picked onto the new base.

5. Never widen the set with `origin/main ^upstream/main` or the merge base; the doc explains why.
   A first-parent commit whose subject starts with `chore: snapshot upstream main` is a previous sync's own squash, not a fork PR: never give it a verdict and never cherry-pick it.
   Its diff is that sync's delta against the *old* fork tip, so replaying it onto the new base would rewind everything upstream changed in between.
   When one falls inside the window, read its row with `git show origin/main:docs/upstream-sync.md` — the sync branch has no copy yet, because step 2 branched at `upstream/main` and step 7's restore has not run — then re-audit the fork PRs that row marked `kept` and re-apply those individual commits instead.
   Those recovered PRs also get verdicts in *this* sync's row, alongside the window's own PRs.
   Without that, each row would carry only one generation of keeps: the next sync excludes this sync's squash, reads this row, and finds the older keeps missing — so the accumulated fork delta erodes silently, one generation per sync.
   Every row therefore states the full accumulated keep-list, not just what the window newly adjudicated.
6. Compare each audited PR against current upstream by behavior, using `git show <sha>` and a search of `upstream/main` for the same change.
   Record one verdict per PR: `already-upstream` (with the upstream PR number), `superseded` (with the upstream PR number), `no-longer-needed` (with the reason), or `kept`.
7. Apply the keep rule from the doc without asking: default to upstream, keep only when current upstream lacks the behavior and the fork still has a concrete need for it.
   The sync's own procedural spine never goes through the audit at all: restore it from `origin/main` verbatim, then commit, before any cherry-pick.

   ```sh
   git checkout origin/main -- docs/upstream-sync.md .agents/skills/upstream-sync
   git commit -m 'chore: restore fork sync spine'
   ```

   Only those two paths: they are fork-local and absent from `upstream/main`, so taking them wholesale can lose nothing upstream.
   `AGENTS.md` is not on that list and must never be restored this way — it is a shared upstream document with hundreds of upstream commits, and overwriting it from `origin/main` would silently revert every upstream edit made since the last sync.
   Re-add the fork's one-line `upstream-sync` pointer to upstream's `AGENTS.md` as a targeted edit instead, so the rest of the file stays upstream's.
   Three more upstream-owned files carry companion edits the spine needs, and they get the same targeted treatment — never a wholesale restore:
   the `.agents/skills/*)` arm in `families_for_changed_path` in `bin/fm-test-run.sh`, without which step 10's `--changed` run dies on `no changed-test mapping for source path`;
   the three `.agents/skills/upstream-sync/**` entries plus the `docs/upstream-sync.md` entry in `docs/documentation-audiences.json`, without which `bin/fm-doc-audience-check.sh` fails the restored files as unlisted surfaces;
   and the skill-reference case in `tests/fm-test-run.test.sh`, which is what keeps that arm from silently regressing on the new base.
   Both failures are loud and would otherwise recur on every sync, because the restore puts those paths back in the diff while upstream's copies still lack the entries that cover them.
   Cherry-picking the fork PR that introduced the spine would reinstate its state at *that* PR, losing every catch-up row and `Next monthly full run` advance a later sync appended inside its own excluded squash.
   Give that PR a `kept` verdict in the table but never cherry-pick it: step 9 would hit an add/add conflict against the files just restored, and the upstream-wins rule has no upstream side to choose.
   The same holds for any fork PR whose diff is confined to `docs/upstream-sync.md` and `.agents/skills/upstream-sync/`, not just the one that introduced them: step 7 already restored those paths, so every hunk is a no-op and `git cherry-pick` aborts the whole sequence as an empty commit.
   Spine-only is the general test: a PR that touches any path outside `docs/upstream-sync.md` and `.agents/skills/upstream-sync/` is picked normally, its spine hunks three-way-merging against its own parent.
   The one named exception is the mixed PR that introduced the spine, and it is exempt only because its non-spine hunks are exactly the four companion edits step 7 re-applies; confirm that hunk by hunk with `git show <sha>` before exempting it, and pick it if anything else is in there.
   Touching a companion file is not by itself grounds for exemption: fork PRs carry unrelated work in those files too — `#55` changes `AGENTS.md` and nothing else — and exempting one on path shape alone would drop its behavior while the table still records it `kept`.
   If one is picked by mistake, recover with `git cherry-pick --skip` rather than `--allow-empty`, so the sequence continues without an empty commit.
   Commit the restore immediately, because `git checkout <ref> -- <paths>` also writes the index and `git cherry-pick` refuses to run against a dirty index even for unrelated paths.
   Commit the four targeted edits immediately too, with `git add AGENTS.md bin/fm-test-run.sh docs/documentation-audiences.json tests/fm-test-run.test.sh && git commit -m 'chore: re-apply upstream-sync companion edits'`, for the same reason in its unstaged form: `git cherry-pick` also refuses when a picked commit touches a file carrying uncommitted local changes, and fork PRs do touch `AGENTS.md`.
   The `git add` is not optional here the way it is after the restore: these are plain edits to tracked files, so `git commit -m` alone stages nothing and exits non-zero.
8. Do not present the keep-list for approval; the PR verdict table is the review surface.
9. Cherry-pick each `kept` PR in order, letting upstream win every conflict.

   ```sh
   git cherry-pick -x <sha>
   # on conflict: keep upstream's architecture, wording, tests, and safety contracts; resolve; git cherry-pick --continue
   ```

   If a kept PR no longer applies meaningfully on top of upstream, downgrade its verdict to `superseded` or `no-longer-needed` and say why in the table.
10. Run the tier's validation.

    Weekly:

    ```sh
    FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh
    bin/fm-lint.sh
    bin/fm-test-run.sh --changed --base "$UPSTREAM_BASE" --exclude-family real-herdr-gated
    ```

    The first command is the weekly tool-currency and compatibility check.
    Record one row in the PR body using `| Tool currency | \`FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh\` | pass - no required-tool floor diagnostic |` when it emits no required-tool floor diagnostic, or replace the result cell with the exact `MISSING` or floor diagnostic when it does.
    A required tool below its floor is a blocker that must be reported, while optional-tool or unrelated bootstrap diagnostics remain follow-up evidence and do not create a separate captain call.

    Never hand-roll the selection from `git diff --name-only`.
    The branch starts at `UPSTREAM_BASE`, so `--changed --base "$UPSTREAM_BASE"` resolves the kept diff through `families_for_changed_path` in `bin/fm-test-run.sh`, the repo's maintained changed-file-to-test map, and a diff that maps to nothing logs `no tests selected` instead of failing the tier.
    If the run stops with `no changed-test mapping for source path: <path>`, a kept commit brought in a file the map does not know: give it a family in `families_for_changed_path`, or add it to that function's no-test exemption arm if it is pure documentation, in the same sync commit, then re-run.

    Run the `real-herdr-gated` family too only when the kept diff selects it, which the same map decides:

    ```bash
    [ -n "$UPSTREAM_BASE" ] || { echo 'blocked: UPSTREAM_BASE unset in this shell; re-bind it from the brief'; exit 1; }
    changed=$(bin/fm-test-run.sh --list --changed --base "$UPSTREAM_BASE") || { echo 'blocked: changed-test selection failed'; exit 1; }
    gated=$(bin/fm-test-run.sh --list --family real-herdr-gated) || { echo 'blocked: real-herdr-gated listing failed'; exit 1; }
    overlap=$(comm -12 \
      <(printf '%s\n' "$changed" | grep -v '^$' | sort -u) \
      <(printf '%s\n' "$gated" | grep -v '^$' | sort -u))
    ```

    Capture each list and check its status; never inline the two runs into `comm` through process substitution.
    Process substitution and the pipe into `sort` both discard the exit status, so a failed selection — an unset `UPSTREAM_BASE` in a fresh shell is the usual one — would produce empty output that reads as a clean "not Herdr-affecting" verdict.
    Do not judge this from a hand-written path list: the map also routes `bin/fm-backend.sh`, `bin/fm-afk*`, `bin/fm-supervisor-target-lib.sh`, and several install and CI files to `real-herdr-gated`.

    An empty `$overlap` means the sync is not Herdr-affecting and the weekly tier is done.
    A non-empty `$overlap` means it is, and the next move depends on the brief.
    If this brief was not scaffolded with `--herdr-lab`, stop with `blocked: sync touches Herdr, brief needs --herdr-lab` and wait for the regenerated brief; never add lab commands to a brief that declares `NOT ENABLED`.
    If it was, the lab contract is live, so run the family now:

    ```sh
    for t in herdr jq treehouse python3; do command -v "$t" >/dev/null || { echo "blocked: the Herdr family needs $t on PATH; without it whole suites skip into a green result"; exit 1; }; done
    [ -x "${HERDR_LAB_HELPER:-bin/fm-herdr-lab.sh}" ] || { echo 'blocked: the Herdr lab helper is not executable; lifecycle suites would skip into a green result'; exit 1; }
    bin/fm-test-run.sh --family real-herdr-gated --fail-on-gate-skip 'herdr not found'
    ```

    See [`references/herdr-lab.md`](references/herdr-lab.md) for the preconditions that run needs.
    CI's portable shards and its required Herdr lane on the PR are the weekly full gate; do not run `--all` locally.

    Monthly:

    ```sh
    bin/fm-lint.sh
    for t in herdr jq treehouse python3; do command -v "$t" >/dev/null || { echo "blocked: the Herdr family needs $t on PATH; without it whole suites skip into a green result"; exit 1; }; done
    [ -x "${HERDR_LAB_HELPER:-bin/fm-herdr-lab.sh}" ] || { echo 'blocked: the Herdr lab helper is not executable; lifecycle suites would skip into a green result'; exit 1; }
    bin/fm-test-run.sh --all --fail-on-gate-skip 'herdr not found'
    ```

    The full run includes the `real-herdr-gated` family, which needs a running default Herdr server and the lab contract from `--herdr-lab`; [`references/herdr-lab.md`](references/herdr-lab.md) owns that setup.
    `--fail-on-gate-skip` is not optional here: a gate skip is otherwise a success, so a clone without `herdr` on `PATH` would report the whole monthly suite green having run none of the Herdr lifecycle tests the tier exists to cover.
    It takes a single token, so it cannot cover the family's other gates; the checks above assert every head gate that exits a whole suite, because a missing `jq`, `treehouse`, or `python3`, or a non-executable lab helper, skips suites into the same green result.
11. Treat any failure not caused by a kept commit as unrelated breakage: note it in the PR description under `Follow-ups`, and leave the code untouched on the sync branch.
    Firstmate files each one as separate work after the PR is open.
12. Append the catch-up log row to `docs/upstream-sync.md` on the sync branch, recording the date, adopted base, the window end commit as a bare backticked SHA in its own column, tier, and every verdict, and on a monthly tier advance the `Next monthly full run` line to the first day of the following month.
    Append to the copy step 7 restored from `origin/main`, so the row lands on top of every earlier row rather than on a stale snapshot of the file.
    If the file is missing, or its newest row predates the one `git show origin/main:docs/upstream-sync.md` shows, stop with `blocked: the sync branch lost docs/upstream-sync.md` rather than recreating it from memory.
    The window end commit is the `WINDOW_END` step 4 pinned — the last first-parent commit inside this window, whether or not it was adjudicated, including an excluded snapshot squash.
    Defining it by position rather than by adjudication is what keeps it always present: step 5 forbids adjudicating a snapshot squash, so a window containing only one would otherwise leave this column empty.
    It is not optional: intake's window override reads it, an empty column drops the next sync back to the marker, and from there the accumulated fork delta is lost with no conflict and no warning.
    "Every verdict" means the full accumulated keep-list per step 5 — the window's own PRs plus every PR recovered from an excluded squash's row — because the next sync rebuilds the fork delta from this row alone.
    Commit it before step 13 ships, with `git add docs/upstream-sync.md && git commit -m 'docs: record the <DATE> catch-up'`, so the pipeline validates the row and the merged PR carries it.
    Appending the row is a plain edit to a tracked file, so `git commit -m` without the `git add` stages nothing and exits non-zero, leaving the row in the working tree.
    An uncommitted row is the silent failure: `axi run` validates committed history and ignores the working tree, so CI goes green and the merged commit carries no row at all.
    A row added after the PR is open is either never pushed or lands unvalidated, and intake's window override plus the monthly-tier check both read it from the merged commit.

13. Ship through no-mistakes to the fork's PR path, with `no-mistakes axi run --skip rebase --intent "<TIER> upstream sync of withally/firstmate onto kunchenguid/firstmate at <UPSTREAM_BASE>"`.
    `--intent` is required to start a run, so the bare command fails before the first pipeline step, and the tier belongs in it because the gate treats the intent as the run's authoritative goal rather than inferring one.
    The rebase step is skipped because a cutover branch is cut from `upstream/main` and rebasing it onto the fork's `origin/main` would replay the whole divergent fork history back onto the new base, undoing the adoption the sync exists to perform.
    Title the PR `chore: snapshot upstream main for <DATE>` so the next sync's snapshot-commit search (step 3) finds this merge.
    The PR must be squash-merged with that title, because the fork allows merge and rebase merges too and neither puts the marker on `origin/main`'s first-parent subject; intake step 7 verifies this after the merge.
    The verdict table carries the same full accumulated keep-list step 5 and step 12 require, not just the window's own PRs, because it is the captain's single review surface for everything the branch re-applies.
    The PR description must contain the verdict table:

    ```markdown
    | Fork PR | Verdict | Evidence |
    | --- | --- | --- |
    | #NN | already-upstream | upstream #MMMM |
    | #NN | superseded | upstream #MMMM |
    | #NN | no-longer-needed | <reason> |
    | #NN | kept | <what upstream still lacks and why the fork needs it> |
    ```

    followed by `Tier: weekly|monthly`, the validation commands actually run, and a `Follow-ups` list (possibly empty).
    Never push to `upstream` and never merge.
14. Hand back with `done: PR <url> checks green` per the brief; the captain rules on the keep-list at merge.
