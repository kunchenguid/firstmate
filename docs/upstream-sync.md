# Upstream sync

This repository is the `withally/firstmate` fork of the canonical parent at `kunchenguid/firstmate`.
The fork contributes changes upstream and stays close to the parent by adopting `upstream/main` wholesale, then carrying only the smallest behaviorally necessary local delta.

## Weekly procedure

1. Fetch both remotes and record the exact `upstream/main` commit that will become the new base.
   `origin` is `withally/firstmate` and `upstream` is the canonical parent `kunchenguid/firstmate`; a fresh clone carries only `origin`, so every sync starts by ensuring `upstream` exists.
   The push URL is disabled on purpose, because the fork never pushes to the canonical parent.
   An existing `upstream` that names any other repository is a hard stop, since every recorded base and every audit range would otherwise be measured against the wrong parent.

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
   ```

2. Create the sync branch directly at that upstream commit.
   Do not merge `origin/main` into it and do not start from the fork's divergent tip.
3. Locate the most recent full catch-up on `origin/main` by finding the latest first-parent commit whose subject starts with `chore: snapshot upstream main`.

   ```sh
   git log origin/main --first-parent --format='%H%x09%cs%x09%s' | awk -F'\t' '$3 ~ /^chore: snapshot upstream main/ {print; exit}'
   ```

4. Audit only the fork PRs after that catch-up commit.
   The newest catch-up log row below names its window end commit; when that commit is older than the marker, start the window there instead.
   Take the earlier of the two boundaries, because re-auditing a settled PR only repeats a verdict while skipping one silently drops kept fork behavior.
   The rule only ever moves the boundary earlier, so a row recording work that has not landed can widen the window but never narrow it.
   A `chore: snapshot upstream main` commit inside the window is a previous sync's own squash: it is never adjudicated and never cherry-picked.

   ```sh
   git log --reverse --first-parent --format='%h%x09%cs%x09%s' <catch-up-commit>..origin/main
   ```

5. Do not derive the audit set from `origin/main ^upstream/main` or from the merge base.
   Those ranges overcount older fork commits that a prior snapshot already reconciled and that current upstream has since absorbed or superseded.
6. Compare each post-catch-up PR by behavior and current content, not by commit hash alone.
   Classify it as already upstream, superseded, no longer needed, or genuinely still local.
7. Default to upstream.
   Keep a local behavior only when current upstream lacks it and the fork still has a concrete need for it.
8. Decide the keep-list by that rule without a mid-flight captain gate.
   Every audited PR and its verdict (already-upstream, superseded, no-longer-needed, or kept) goes in a table in the PR description, and the captain rules once at merge.
9. Re-apply only the kept behaviors on top of the recorded upstream base.
   Resolve conflicts in favor of upstream and preserve newer upstream architecture, wording, tests, and safety contracts.
   The fork-local sync spine — `docs/upstream-sync.md` and `.agents/skills/upstream-sync/` — is restored from `origin/main` rather than re-applied through the audit, so its accumulated catch-up rows survive.
   Its companion edits in upstream-owned files — the `AGENTS.md` pointer, the skill's arm in `bin/fm-test-run.sh`'s changed-file map, its entries in `docs/documentation-audiences.json`, and the case covering that arm in `tests/fm-test-run.test.sh` — are re-applied as targeted edits onto upstream's copies, never restored wholesale.
10. Validate by tier.
    A weekly sync first runs the detect-only bootstrap tool-currency and compatibility check, then runs `bin/fm-lint.sh` plus only the tests the repo's maintained changed-file-to-test map selects for the diff of the kept commits against the upstream base, via `bin/fm-test-run.sh --changed --base <upstream-base>`; the worker records the tool-currency result as one PR-body row, Herdr lifecycle tests run locally only when that same selection includes the `real-herdr-gated` family, and then only from a brief carrying the lab contract; CI's portable shards and its required Herdr lane on the PR are the full gate.
    A monthly sync, the first sync on or after the 1st of a month named by the `Next monthly full run` line below, runs the full `bin/fm-test-run.sh` suite locally with the Herdr gate skip made fatal, so the Herdr lab is genuinely exercised rather than skipped into a green result.
    The `upstream-sync` skill owns the exact commands, the tier decision, the worker brief and its verdict-table inputs, the Herdr lab setup, and the optional urgent-upstream tripwire.
11. Treat any failure not caused by a kept commit as unrelated breakage.
    Unrelated breakage found during either tier is noted in the PR and filed as separate follow-up work, never fixed on the sync branch.
12. Append one row to the catch-up log below, and commit it.
    Record the date, adopted base, the window end commit as a bare backticked SHA in its own column, tier, post-catch-up PR audit set, and final verdict for every audited PR.
    The verdict list is cumulative: it carries the PRs recovered from a previous sync's excluded snapshot squash as well as the ones this window newly adjudicated, because the next sync rebuilds the fork delta from this row alone.
    The window end commit is the `origin/main` tip pinned when the audit set was listed, whether or not that commit was adjudicated, so the column is always fillable even when the window held nothing but an excluded snapshot squash.
    It is what step 4's boundary rule reads, so a row without it leaves the next sync on the stale marker and silently loses the accumulated fork delta.
    After a monthly sync, advance the `Next monthly full run` line to the first day of the following month.
    Stage the file before committing it, since appending the row is a plain edit to a tracked file and `git commit -m` alone would stage nothing.
    Both the append and its commit come before the ship in step 13, because the gate validates committed history only; a row left in the working tree or added after the PR is open never reaches `origin/main`.
13. Ship through no-mistakes to the fork's PR path.
    Match the marker on the subject line, not with `git log --grep`, which matches any line of the message and so would find the title inside a merge commit's body.
    Squash-merge the approved sync PR under its `chore: snapshot upstream main for <DATE>` title, because a merge commit or a rebase merge leaves that marker off `origin/main`'s first-parent subject and the next sync's step 3 search would then reuse the previous snapshot and widen its audit window.
    Never push to the canonical upstream remote and never merge without explicit captain approval.

## Upstream follow-up (PR-body draft)

Ask the `kunchenguid/no-mistakes` CI step to ignore its own `PR must be raised via no-mistakes` attestation check while the no-mistakes pipeline converges after its own auto-fix pushes, without weakening final failure for a PR that lacks a valid matching attestation.

Next monthly full run: 2026-10-01 (set by the captain on 2026-08-27; September is deliberately skipped).

## Catch-up log

Append one row after every weekly catch-up.
Do not rewrite an older row merely because upstream later absorbs one of its retained changes.
The `Window end commit` column holds a bare backticked SHA and nothing else, because intake parses it to resolve the next window's start.
A row that leaves it out drops the next sync back to the marker, which in steady state is later than the true boundary and silently skips the fork PRs that merged during this sync's review.
The 2026-08-27 row names `b0638f6` because that was `origin/main`'s tip when its audit listed the set, which is what the positional rule above asks for.

| Catch-up date | Catch-up commit or adopted upstream base | Window end commit | Tier | Local PR interval and final verdict |
| --- | --- | --- | --- | --- |
| 2026-08-22 | `9e0374a` (`#65`, `chore: snapshot upstream main for 2026-08-22`) | `9e0374a` | full | Established the full-catch-up boundary. The local PRs that followed were #66 through #76, adjudicated in the next row. |
| 2026-08-27 | `d63b0e2` (`upstream/main`), landed on `origin/main` as `34d9081` (`#78`) | `b0638f6` | full (predates the two-tier rule) | PRs following `9e0374a`: #66 dropped because upstream #2846 already carries it; #67 kept; #68 kept; #69 kept; #70 kept; #71 kept; #72 kept; #73 kept; #74 superseded by upstream #2953 and #3093; #75 kept; #76 superseded by upstream #2953 and #3093. The kept PRs were re-applied onto `d63b0e2` and landed with that cutover, so the next sync starts after this interval rather than re-auditing it. |
