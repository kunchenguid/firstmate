# GitHub and Codebase PR/MR Providers

Firstmate's PR-ready, review, merge, and teardown loop supports GitHub pull requests and ByteDance Codebase merge requests through one shared provider seam in `bin/fm-scm-lib.sh`.
Callers should use `bin/fm-pr-check.sh`, `bin/fm-review-diff.sh`, `bin/fm-pr-merge.sh`, and `bin/fm-teardown.sh`; they should not call `gh-axi pr merge` or `bytedcli codebase mr merge` directly for task work.

Provider detection is URL-first.
`https://github.com/<owner>/<repo>/pull/<number>` selects GitHub.
`https://code.byted.org/<repo-path>/merge_requests/<number>` and `https://code-tx.byted.org/<repo-path>/merge_requests/<number>` select Codebase.
A Codebase `<repo-path>` must have at least two segments, each starting with an alphanumeric or underscore, so a flag-like path such as `-R` or a traversing `..` segment is refused before it reaches `bytedcli`.
When teardown has no recorded `pr=`, it detects the fallback provider from the worktree's `origin` remote host before looking up a merged PR/MR by the task branch.

GitHub behavior stays on the existing tools.
PR state and head reads use `gh`, branch discovery uses `gh-axi pr list`, and merges use `gh-axi pr merge <number> --repo <owner>/<repo>`.
The default merge method remains `--squash`, and explicit GitHub merge-method flags are forwarded unchanged.

Codebase behavior goes only through `bytedcli codebase`.
MR state and head reads use `bytedcli --json codebase mr get <number> -R <repo-path>`.
The head commit is read from the latest MR version's `SourceCommitId`, and teardown fetches that version's `SourceRef` when the commit object is not already available locally.
That fetch only accepts a fully-qualified `refs/` name, passed after a `--` separator, so a provider-supplied ref can never reach `git fetch` as an option such as `--upload-pack=`.
Branch discovery uses `bytedcli --json codebase mr list -R <repo-path> --state merged --head <branch> -L 1`.
Merges use `bytedcli codebase mr merge <number> -R <repo-path>`.

Codebase merge defaults to `--merge-method merge_commit --squash-commits false`: a real merge commit, never a squash, unlike GitHub's `--squash` default above.
For compatibility with existing firstmate commands, `bin/fm-pr-merge.sh` maps `-- --squash` to `merge_commit` with `--squash-commits true`, `-- --merge` to `merge_commit` with `--squash-commits false`, and `-- --rebase` to `rebase_merge` with `--squash-commits false`.
It also accepts explicit Codebase flags such as `--merge-method`, `--squash-commits`, `--remove-source-branch`, `--merge-commit-message`, and `--squash-commit-message`.
Repository and MR override flags are refused because the repo and MR must come from the full URL.

Missing or unauthenticated `bytedcli` is never treated as a successful merged reading.
The helper prints an actionable error naming `bytedcli --json auth status` and Codebase PAT configuration, then returns non-zero.
Teardown may still proceed only if its independent content-in-default-branch proof succeeds; otherwise it refuses and preserves the worktree.

## CI aggregate read

`fm_scm_pr_ci_state` reads a PR/MR's aggregate CI conclusion so `bin/fm-pr-check.sh` can wake firstmate on a red build, not only on a merge.
It echoes one canonical token - `FAILING`, `PENDING`, `PASSING`, or `NONE` - and returns non-zero when the provider read itself fails, so an unreadable status is never mistaken for a red one.
GitHub reads `gh pr view <target> --json statusCheckRollup` and classifies the rollup: any check whose conclusion or status-context state is `FAILURE`, `ERROR`, `TIMED_OUT`, `CANCELLED`, `STARTUP_FAILURE`, or `ACTION_REQUIRED` makes it `FAILING`; an in-flight check (null conclusion) is `PENDING`; an empty rollup is `NONE`.
Codebase reads `bytedcli --json codebase mr status <number> -R <repo-path>` and classifies from `.data.check_runs`: a non-zero `failed_count` is `FAILING`, otherwise a non-zero `running_count` is `PENDING`, a zero `total_count` is `NONE`, and the rest is `PASSING`.
`FAILING` always requires a definitively failed check, so a still-running or absent check never reads as red.
The armed poll wakes once per red episode via a `state/<id>.check.ci` one-shot marker and re-arms when CI leaves the failing state; a CI read that fails counts as a lookup failure on the same fail-closed path as a state read that fails.

The Codebase path is currently stub-tested and CLI-surface verified, not live end-to-end verified in a Codebase-hosted task repo.
The empirical CLI checks were run on 2026-07-10 with `bytedcli codebase mr --help`, `bytedcli codebase mr get --help`, `bytedcli codebase mr merge --help`, `bytedcli codebase mr list --help`, and `bytedcli --json codebase mr get https://code.byted.org/byteapi/bytedcli/merge_requests/1`.
Those commands confirmed the GitLab-flavored MR URL shape, `mr merge` support, merge-method flags, and JSON fields `Status`, `version.SourceCommitId`, and `version.SourceRef`.
The check-run aggregate shape was verified on 2026-07-21 with `bytedcli --json codebase mr status https://code.byted.org/byteapi/bytedcli/merge_requests/1`, which returned `.data.check_runs` carrying `summary`, `total_count`, `passed_count`, `failed_count`, and `running_count` alongside per-run `Status`/`Conclusion` items.
The planned live proof is the first `code.byted.org` project trial.
