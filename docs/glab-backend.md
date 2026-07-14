# GitLab (`glab`) ship-delivery support (verification record)

This is a backend-verification doc: the empirical evidence behind adding GitLab support to firstmate's ship-delivery machinery, which is GitHub-only today.
It records exact tools, commands, and output captured against a real merge request, so the later increments have verified field names rather than guesses.
It is a verification record, not a contract restatement: the delivery-mode, `pr=`/`pr_head=` meta, and landed-work rules stay owned by `AGENTS.md` and the relevant `bin/` script headers, cross-referenced below.

## Increment map

GitLab support lands in three separate increments.

1. **Foundation (landed).** `bin/fm-git-host-lib.sh` centralizes git-host classification and PR/MR URL parsing, with `tests/fm-git-host-lib.test.sh` and this doc.
   A pure addition with zero behavior change when it first landed; increments #2 and #3 (now also landed) are its in-repo callers.
   It landed first so increments #2 and #3 each consume ONE verified parser instead of re-spelling host detection and URL-shape logic.
2. **Merge/check (landed).** `bin/fm-pr-merge.sh` and `bin/fm-pr-check.sh` route a GitLab MR URL through `glab` (merge, `pr_head=` recording, merged-state poll) instead of `gh`/`gh-axi`.
3. **Teardown (landed).** `bin/fm-teardown.sh`'s landed-work fallback verifies a GitLab MR the way it verifies a GitHub PR, using `refs/merge-requests/<iid>/head`.
   `bin/fm-review-diff.sh` was updated in the same increment to fetch the GitLab head ref, and `bin/fm-brief.sh` now infers the crewmate's git-host tool instruction from the clone's origin.

## Design decisions this evidence supports

- **Host inferred from the `origin` remote, not a registry field.** A project's host is derived by classifying `git remote get-url origin` (`fm_git_host_classify` in `bin/fm-git-host-lib.sh`), so no new `data/projects.md` field is added and GitLab support needs no per-project configuration.
- **The `pr=`/`pr_head=` meta contract stays host-agnostic and is NOT renamed.** A GitLab MR URL is a valid `pr=` value; the MR head SHA is a valid `pr_head=` value. The `state/<id>.meta` schema owned by `AGENTS.md` section 2 is unchanged.
- **`glab` is called directly.** No wrapper is added: increment #2 calls raw `glab` the same way `bin/fm-pr-check.sh` already calls raw `gh` directly (as opposed to `gh-axi`).
- **The URL carries the host.** Even though the captain is on gitlab.com (no self-hosted/ambient-host complexity in their case), the parser and classifier keep host detection driven by the URL/remote so self-hosted `gitlab.*` instances work unchanged.

## Environment

- Date: 2026-07-13.
- Tool: `glab` v1.86.0 (Homebrew, `/opt/homebrew/bin/glab`).
- Auth: logged in to gitlab.com; API calls over https, git operations over ssh.
- MR probed read-only and left completely untouched (no merge, comment, approve, or edit): `https://gitlab.com/goosehead-insurance/custom-dev/goosehead-apps/-/merge_requests/5924`.
  Host `gitlab.com`, namespace `goosehead-insurance/custom-dev/goosehead-apps` (three segments), iid `5924`.

## MR JSON field mapping (`glab mr view <iid> -R <namespace> -F json`)

Verified live against MR 5924. The GitHub equivalents are the fields the GitHub-only path uses today.

| GitLab field | Value observed (open MR 5924) | GitHub equivalent | Use |
| --- | --- | --- | --- |
| `.sha` | `73d3dc700a717a8f0f60266348ece41a30f1758d` | `headRefOid` | head SHA; the `pr_head=` meta value. Equal to `.diff_refs.head_sha`; use `.sha`. |
| `.diff_refs.head_sha` | `73d3dc700a717a8f0f60266348ece41a30f1758d` | - | Confirmed equal to `.sha`. |
| `.state` | `opened` | `MERGED` etc. | MR state, **lowercase** one of `opened`/`closed`/`locked`/`merged`. GitHub uses UPPERCASE. Do NOT blindly case-fold: the eventual merge-poll must compare against lowercase `merged`. |
| `.merge_commit_sha` | `""` (empty until merged) | - | Populated on a plain merge. |
| `.squash_commit_sha` | `""` (empty until merged) | - | Populated on a squash merge. Both are `""` while the MR is open. |
| `.iid` | `5924` | PR number | The MR identifier used with `-R <namespace>`. |
| `.head_pipeline.status` | `success` | check-suite status | CI/pipeline status (e.g. `running`/`success`/`failed`). |
| `.references.full` | `goosehead-insurance/custom-dev/goosehead-apps!5924` | `owner/repo#n` | Full namespace reference. |

Exact command shape used:

```sh
glab mr view 5924 -R goosehead-insurance/custom-dev/goosehead-apps -F json
```

## Merge-request refs (`git ls-remote`)

Confirmed present on gitlab.com:

```sh
git ls-remote git@gitlab.com:goosehead-insurance/custom-dev/goosehead-apps.git \
  refs/merge-requests/5924/head refs/merge-requests/5924/merge
```

Output:

```
73d3dc700a717a8f0f60266348ece41a30f1758d	refs/merge-requests/5924/head
279e3c087385233e9e731181833473c8ea46a0ad	refs/merge-requests/5924/merge
```

`refs/merge-requests/<iid>/head` is the source-branch head (equal to `.sha`) and is the GitLab equivalent of GitHub's `refs/pull/<n>/head` used by teardown's landed-work fallback.
Use `/head`, not `/merge` (the latter is GitLab's synthesized merge preview, not the branch head).

## CI status

Either read `.head_pipeline.status` from the single `glab mr view ... -F json` call above, or:

```sh
glab ci status -R <namespace> --branch <source-branch>
```

which prints per-job lines plus a final `Pipeline state: <status>`.
The one-call JSON read is preferred for the merge-poll since it also yields state and head SHA at once.

## URL shapes (parsed by `bin/fm-git-host-lib.sh`)

- GitHub PR: `https://github.com/<owner>/<repo>/pull/<n>` - path is exactly `<owner>/<repo>`.
- GitLab MR: `https://<host>/<namespace>/-/merge_requests/<iid>` - `<namespace>` is one or more path segments (three for MR 5924), captured greedily up to the `/-/merge_requests/` marker; `<host>` may be self-hosted.

The parser's stdout contract (`<kind>\t<host>\t<path>\t<number>`) and the classifier's `github`/`gitlab`/`unknown` tokens are documented in `bin/fm-git-host-lib.sh`'s header; increments #2/#3 parse that contract.

## Command-flag verification (2026-07-13)

Captured from `glab` v1.86.0 to record the exact flags increments #2/#3 rely on, so the merge and teardown surfaces are not re-derived from guesses.

`glab mr merge --help` (flags firstmate uses):

```
-R --repo             Select another repository. Can use either `OWNER/REPO` or `GROUP/NAMESPACE/REPO` format. Also accepts full URL or Git URL.
-s --squash           Squash commits on merge.
   --squash-message   Custom squash commit message.
-y --yes              Skip submission confirmation prompt.
```

`bin/fm-pr-merge.sh` passes `-R <host-explicit URL>`, `--yes`, and the default `--squash`.
The `--yes` flag is required because firstmate merges from a non-TTY supervising shell where the submission-confirmation prompt would otherwise block.
`--squash-message` is not passed, so `glab` uses its own default squash commit message non-interactively.

`glab mr list --help` (flags firstmate uses):

```
-M --merged         Get only merged merge requests.
-F --output         Format output as: text, json. (text)
-s --source-branch  Filter by source branch <name>.
```

`bin/fm-teardown.sh`'s `mr_iid_from_branch` calls `glab mr list -R <repo> --source-branch=<branch> --merged -F json` and reads `.[0].iid` from the JSON array output (the `-F json` list shape is an array, unlike `mr view`'s single object).
