# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues.
Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh-axi issue create --title "..." --body "..."`.
  Use a heredoc for multi-line bodies.
- **Read an issue**: `gh-axi issue view <number> --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh-axi issue list --state open` with appropriate `--label` and `--state` filters; use `gh-axi issue view <number> --full --comments` when the complete body is needed.
- **Comment on an issue**: `gh-axi issue comment <number> --body "..."`
- **Apply / remove labels**: `gh-axi issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh-axi issue close <number> --comment "..."`

Infer the repo from `git remote -v` - `gh` does this automatically when run inside a clone.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh-axi pr` equivalents:

- **Read a PR**: `gh-axi pr view <number> --comments` and `gh-axi pr diff <number>` for the diff.
- **List external PRs for triage**: `gh-axi api '/repos/<owner>/<repo>/pulls?state=open' --paginate --jq '[.[] | {number, title, author: .user.login, authorAssociation: .author_association}]'`, then keep only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` (drop `OWNER`/`MEMBER`/`COLLABORATOR`); use `gh-axi pr view <number> --full --comments --reviews` for the complete record.
- **Comment / label / close**: `gh-axi pr comment`, `gh-axi pr edit --add-label`/`--remove-label`, `gh-axi pr close`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either - resolve with `gh-axi pr view 42` and fall back to `gh-axi issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh-axi issue view <number> --comments`.

## Wayfinding operations

Used by `/wayfinder`.
The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
  `gh-axi issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh-axi issue subissue add <map> <child>`).
  Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body.
  Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
  Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies** - the canonical, UI-visible representation.
  Add an edge with `gh-axi api POST /repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by --field issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh-axi api /repos/<owner>/<repo>/issues/<n> --jq .id`, _not_ the `#number` or `node_id`).
  GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only - the live gate).
  Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body.
  A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh-axi issue list --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh-axi issue edit <n> --add-assignee @me` - the session's first write.
- **Resolve**: `gh-axi issue comment <n> --body "<answer>"`, then `gh-axi issue close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
