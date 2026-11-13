# Alternative Forgejo CLIs for the pull request watch and merge

Empirical record for the Forgejo CLIs firstmate can drive besides `tea`, alongside [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md), which owns the REST behaviour every one of them shares.
`tea` remains the documented default and its behaviour is unchanged; this record is about what `forgejo-cli` (`fj`) and `fgj` actually offer, so the resolver can accept them without weakening the merge path's head-binding guarantee.
All evidence below was collected on 2026-11-12.

Unlike the tea record, **nothing here was verified against a live Forgejo instance**: no disposable instance was stood up for this pass.
Every finding below was read from the CLI's own shipped surface and from the exact released source, both named at each finding, and the merge path's REST calls are the same ones the tea record already verified against a real instance.
Where a finding is inferable only from source rather than from the CLI's own output, it says so.

## Versions

All evidence below was collected on 2026-11-12 against a released build of each CLI on the development machine.
This record deliberately embeds no versions, revisions, or installation paths of those builds: they are properties of the machine the evidence was gathered on, not of the interfaces the findings describe, and a reader cannot reproduce them.
Reproducing the record needs only a released build of each tool whose interface matches the generation named at each finding.

Findings are bounded by interface generation rather than by a local version pin:

- The `fj` refusal is bounded by the `forgejo-cli` interface generation this record covers: it has no `api` passthrough, cannot address a repository by slug, renders its pull request views as localized prose with no commit id, and hard-codes `head_commit_id: None` in its merge request. If a later generation changes any of these, the refusal must be re-verified against that generation before it is relaxed.
- The `fgj` acceptance is bounded by the `fgj` interface generation that ships `fgj api`, the `gh api`-style request passthrough the whole acceptance rests on; an earlier generation without it cannot serve this record at all.

## `fj` cannot serve this contract, and why

Firstmate's Forgejo path needs three things from a CLI: a machine-readable record (`state`, `merged`, `head.sha`), the combined commit status, and a merge call that can carry Forgejo's `head_commit_id`. The released `forgejo-cli` interface generation this record covers offers none of them.

**It has no authenticated request passthrough.** `fj --help` lists `repo`, `issue`, `pr`, `milestone`, `wiki`, `actions`, `whoami`, `auth`, `release`, `tag`, `user`, `org`, `version`, and `completion`; there is no `api` command, and the shipped completions agree:

```
$ fj --help
Usage: fj [OPTIONS] <COMMAND>

Commands:
  repo
  issue
  pr
  milestone
  wiki
  actions
  whoami
  auth
  release
  tag
  user
  org
  version
  completion
```

**Its merge subcommand documents no head binding, and its source hard-codes the absence of one.** `fj pr merge --help` offers only `-H/--host`, `-M/--method`, `-C/--cwd`, `-d/--delete`, `-t/--title`, and `-m/--message`.
Reading the released source confirms this is not a help-text omission: `merge_pr` in `src/prs.rs` builds its request as

```
let request = MergePullRequestOption {
    r#do: merge_style,
    merge_commit_id: None,
    merge_message_field: Some(message),
    merge_title_field: title,
    delete_branch_after_merge: Some(delete),
    force_merge: None,
    head_commit_id: None,
    merge_when_checks_succeed: None,
};
```

`head_commit_id` is a literal `None` with no flag, environment variable, or config key that reaches it.
Merging through `fj` would therefore land whatever the head happens to be when the call arrives, which is exactly the un-reviewed window `gh pr merge --match-head-commit`, `glab mr merge --sha`, and the `tea api` call all close.

**Its pull request views are localized prose with no commit id.** `pr view` and `pr status` render Fluent messages (`localization/en-US/messages.ftl` ids `msg-pr-view-header`, `msg-pr-status-merged`, `msg-pr-status-entry`), so their text is neither machine-readable nor stable across the ship's own translations, and no message prints the head commit at all.
There is no `--json`/`-o` flag anywhere in `fj pr`.

**It cannot address a repository by slug.** `fj pr view`, `fj pr status`, and `fj pr merge` accept `-H/--host` and `-C/--cwd` but no `-r/--repo`; `RepoInfo::get_current` in `src/repo.rs` resolves the owner and repository from the git remote of the current directory (or of `-C`), using `--host` only to pick between several remotes.
A merge watch runs from the fleet's state directory with no clone of the target in scope, so this alone rules `fj` out of that read even if the output were parseable.

**What `fj` does offer, and what firstmate therefore uses.** Only its login list: `fj auth list` prints the hostname of every instance the user is logged into, one bare host per line, and nothing on stdout when there is none (the "not logged in" notice goes to stderr).
Its store is a JSON map from host to token (`~/Library/Application Support/forgejo-cli.forgejo-cli/keys.json` on macOS, the platform config directory elsewhere), which firstmate never reads, so the credential stays inside `fj`.

```
$ fj auth list
<redacted, forge A>
<redacted, forge B>
```

Both hosts are instances the captain is logged into and stay out of this record, the same way [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md) withholds its private-instance identifiers; what matters here is the shape, one bare host per line.

The narrowest safe shape for a project whose only Forgejo CLI is `fj` is therefore a refusal, not a fallback: `bin/fm-pr-lib.sh` recognizes `fj` and resolves its host login, and then refuses every operation that needs the pull request record, naming the missing capability and pointing here.
`bin/fm-pr-merge.sh` never merges through it, and `bin/fm-pr-check.sh` refuses to arm a watch on it rather than leaving behind a poll that can never report anything.
Nothing is silently dropped, and nothing about the head-binding guarantee changes.

## `fgj` can serve the contract, through `fgj api`

The `fgj` interface generation this record covers ships `fgj api`, which mirrors `gh api` and reaches any endpoint the CLI has no dedicated command for. It is enough on its own:

```
$ fgj api --help
Usage:
  fgj api <endpoint> [flags]

Flags:
  -F, --field stringArray       Add a typed parameter in key=value format (true/false/null/integers become JSON literals; @file or @- reads a value)
  -H, --header stringArray      Add an HTTP request header in key:value format
  -h, --help                    help for api
  -i, --include                 Include the HTTP response status line and headers in the output
      --input string            The file to use as the request body ("-" to read from standard input)
  -X, --method string           The HTTP method for the request (default GET, or POST when fields or --input are given)
  -p, --paginate                Make additional requests to fetch all pages of results
  -f, --raw-field stringArray   Add a string parameter in key=value format
      --slurp                   Use with --paginate to wrap all pages in a JSON array
```

Two properties of that call matter here.

**The endpoint is a path with the owner and repository written out.** The leading `/api/v1` is added when it is omitted (`resolveAPIURL` in `cmd/api.go`), and the path segments are sent verbatim, so `fgj api repos/<owner>/<repo>/pulls/<n>` reaches `/api/v1/repos/<owner>/<repo>/pulls/<n>`.
`tea api` takes the same REST paths but substitutes `{owner}`/`{repo}` from `--repo`, so the resolver builds the placeholder form for `tea` and the literal form for `fgj`.

**`-f` and `-X POST` send a JSON body**, exactly like `tea api`, so the merge call is the tea record's own verified call with the fields spelled the same way:

```
fgj api repos/<owner>/<repo>/pulls/<n>/merge --hostname <host> -X POST -f Do=merge -f head_commit_id=<sha>
```

That is the whole reason `fgj` is usable where `fj` is not, and why the head-binding guarantee is preserved rather than weakened.

**Exit status differs from `tea`, and neither one is trusted.** `executeAPI` in `cmd/api.go` writes a non-2xx body to stderr and returns an error, so `fgj api` exits non-zero where `tea api` exits 0 with the error body on stdout.
`bin/fm-pr-merge.sh` judges both merges solely by reading the pull request back and requiring `merged: true`, so this difference changes nothing about how a merge is confirmed.

## Host and login resolution

Both CLIs keep one login per instance and select it on the command line, but the stores and their reports differ.

`fgj` keeps `~/.config/fgj/config.yaml` (or `$XDG_CONFIG_HOME/fgj/config.yaml`) with a `hosts:` map keyed by hostname, and picks one with `--hostname`; `FGJ_TOKEN` and `FGJ_HOST` override it. It prints its configured hostnames through `fgj auth status`:

```
$ fgj auth status
Authenticated instances:
  <bullet> <host> (user: <name>)
```

`runAuthStatus` in `cmd/auth.go` writes that line per instance, and prints the "Not authenticated with any Forgejo instances" notice on stdout when the map is empty.
Only that report is read: the config file also holds each instance's token, and firstmate must not need it.

`fj` prints its hostnames through `fj auth list` as bare lines, shown above.

Both are matched to the pull request's parsed host exactly, and a store with zero or several entries for that host fails rather than guesses, mirroring the `tea login list` match [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md) owns.

## What firstmate does with this

`bin/fm-pr-lib.sh` owns the selection in one place.
`fm_pr_forgejo_cli_api_capable` declares which CLIs can make an authenticated request, `fm_pr_forgejo_resolve` picks a CLI and its own host login, and `fm_pr_forgejo_api` turns that into one request, so the merge watch (`bin/fm-pr-poll.sh`, which duplicates the selection because its body sources nothing), the merge path (`bin/fm-pr-merge.sh`), the terminal read (`bin/fm-crew-state.sh`), teardown's merged proof (`bin/fm-teardown.sh`), and arming (`bin/fm-pr-check.sh`) all agree.
The merge watch is handed the project's recorded preference through the registered poll sidecar, whose optional sixth line names it; a project that named none records no line and the watch resolves `auto`, exactly as before.
The watch's manual `--validated`/`--baseline` form keeps the six-argument shape `--validated <provider> <url> <host> <path> <number>` (preference `auto`) recorded for the other forges; the watcher's own invocation passes the recorded preference as an optional seventh argument.

A project names its CLI through the registry forge binding, `forge=forgejo:tea`, `forge=forgejo:fgj`, or `forge=forgejo:fj`, queried with `bin/fm-project-mode.sh --forge-cli`; `--forge` still answers `forgejo` for every spelling, so no existing consumer changes.
`forge=forgejo` alone, the spelling every registered project already has, means `auto`: `tea` first, then `fgj`, then `fj`, taking the first one that is installed and holds exactly one login for the host. A home that has `tea` therefore behaves exactly as it did before, and a home that has only the others stops failing with "tea not found".
