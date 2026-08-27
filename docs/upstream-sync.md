# Upstream sync

This repository is the `withally/firstmate` fork of the canonical parent at `kunchenguid/firstmate`.
The fork contributes changes upstream and stays close to the parent by adopting `upstream/main` wholesale, then carrying only the smallest behaviorally necessary local delta.

## Weekly procedure

1. Fetch both remotes and record the exact `upstream/main` commit that will become the new base.
2. Create the sync branch directly at that upstream commit.
   Do not merge `origin/main` into it and do not start from the fork's divergent tip.
3. Locate the most recent full catch-up on `origin/main` by finding the latest first-parent commit whose subject starts with `chore: snapshot upstream main`.

   ```sh
   git log origin/main --first-parent --grep='^chore: snapshot upstream main' -1 --format='%H %cs %s'
   ```

4. Audit only the fork PRs after that catch-up commit.

   ```sh
   git log --reverse --first-parent --format='%h%x09%cs%x09%s' <catch-up-commit>..origin/main
   ```

5. Do not derive the audit set from `origin/main ^upstream/main` or from the merge base.
   Those ranges overcount older fork commits that a prior snapshot already reconciled and that current upstream has since absorbed or superseded.
6. Compare each post-catch-up PR by behavior and current content, not by commit hash alone.
   Classify it as already upstream, superseded, no longer needed, or genuinely still local.
7. Default to upstream.
   Keep a local behavior only when current upstream lacks it and the fork still has a concrete need for it.
8. Present the candidate keep-list for captain approval before applying any local commit.
9. Re-apply only the approved behaviors on top of the recorded upstream base.
   Resolve conflicts in favor of upstream and preserve newer upstream architecture, wording, tests, and safety contracts.
10. Run the full test suite and ship through no-mistakes to the fork's PR path.
    Never push to the canonical upstream remote and never merge without explicit captain approval.
11. Append one row to the catch-up log below.
    Record the date, adopted base, post-catch-up PR audit set, and final verdict for every audited PR.

## Catch-up log

Append one row after every weekly catch-up.
Do not rewrite an older row merely because upstream later absorbs one of its retained changes.

| Catch-up date | Catch-up commit or adopted upstream base | Local PR interval and final verdict |
| --- | --- | --- |
| 2026-08-22 | `9e0374a` (`#65`, `chore: snapshot upstream main for 2026-08-22`) | Established the full-catch-up boundary. The local PRs that followed were #66 through #76, adjudicated in the next row. |
| 2026-08-27 | `d63b0e2` (`upstream/main`) | PRs following `9e0374a`: #66 dropped because upstream #2846 already carries it; #67 kept; #68 kept; #69 kept; #70 kept; #71 kept; #72 kept; #73 kept; #74 superseded by upstream #2953 and #3093; #75 kept; #76 superseded by upstream #2953 and #3093. |
