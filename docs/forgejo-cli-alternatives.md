# Alternative Forgejo CLIs for the pull request watch and merge

Empirical record for the Forgejo CLIs firstmate can drive besides `tea`, alongside [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md), which owns the REST behaviour every one of them shares.
`tea` remains the documented default and its behaviour is unchanged; this record is about what `forgejo-cli` (`fj`) and `fgj` actually offer, so the resolver can accept them without weakening the merge path's head-binding guarantee.
All evidence below was collected on 2026-11-12.

The findings below were first read from each CLI's own shipped surface and from the exact released source, both named at each finding, and the merge path's REST calls are the same ones the tea record already verified against a real instance.
Where a finding is inferable only from source rather than from the CLI's own output, it says so.

The `fgj` path has since been verified **live**, end to end, against a real Forgejo instance (a released `fgj` build against Forgejo 17.0.1 on a self-hosted instance), by resolving the CLI, reading the pull request record, reading the repository's default merge style, attempting a deliberately wrong-head merge, landing a head-bound merge, and then polling the merged state back:

```sh
# the resolved CLI's own host login, then the live record read
fm_pr_forgejo_resolve <host> fgj          # cli=fgj login=<host>
fm_pr_forgejo_read_record <host> <owner>/<repo> <n> fgj
#   state=open merged=false head=660f9a765f92ebbc462fb1cd8c0499bbb3077aa0

# a merge bound to the WRONG head is refused, and the pull request stays open
fgj api repos/<owner>/<repo>/pulls/<n>/merge --hostname <host>   -X POST -f Do=squash -f head_commit_id=1111111111111111111111111111111111111111
#   {"message":"head out of date",...}  HTTP 409

# the merge bound to the verified head lands
fgj api repos/<owner>/<repo>/pulls/<n>/merge --hostname <host>   -X POST -f Do=squash -f head_commit_id=660f9a765f92ebbc462fb1cd8c0499bbb3077aa0

# the merged-state poll through the same resolved CLI
fm_pr_forgejo_read_record <host> <owner>/<repo> <n> fgj
#   state=closed merged=true head=660f9a765f92ebbc462fb1cd8c0499bbb3077aa0
```

The wrong-head refusal is the live proof of the head-binding guarantee this record is about: Forgejo rejects the merge with "head out of date" and leaves the pull request open, exactly as the `tea` and `gh`/`glab` counterparts do.
Two live observations were added by that pass: `Do=squash` was accepted for a repository whose `default_merge_style` reads `squash`, and a first merge attempt was answered with a transient `HTTP 405` ("Please try again later") that a retry carried through — which is why every merge in `bin/fm-pr-merge.sh` is judged by reading the pull request back rather than by the call's own exit status.
The `fj` refusal and the `tea` path were **not** re-verified live in that pass: `tea` was not installed on the machine used, and the `fj` refusal is a negative claim about a capability `fj` still does not ship.

## Versions

All evidence below was collected on 2026-11-12 against a released build of each CLI on the development machine.
This record deliberately embeds no versions, revisions, or installation paths of those builds: they are properties of the machine the evidence was gathered on, not of the interfaces the findings describe, and a reader cannot reproduce them.
Reproducing the record needs only a released build of each tool whose interface matches the generation named at each finding.

Findings are bounded by interface generation rather than by a local version pin:

- The `fj` refusal is bounded by the `forgejo-cli` interface generation this record covers: it has no `api` passthrough, cannot address a repository by slug, renders its pull request views as localized prose with no commit id, and hard-codes `head_commit_id: None` in its merge request. The login read is bounded the same way: it rests on `fj whoami --host <host>` exiting 0 exactly when that host is logged in. If a later generation changes any of these, the refusal must be re-verified against that generation before it is relaxed.
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

**What `fj` does offer, and what firstmate therefore uses.** Only a per-host login predicate: `fj whoami --host <host>` exits 0 exactly when the user holds a login for `<host>` and nonzero otherwise, so firstmate reads the login from that exit status alone and parses no display line at all.
The `whoami` command is listed by the `fj --help` output above; its `--host` flag and this exit-status meaning were taken from that shipped surface and the released source, and were **not** exercised live against a real `forgejo-cli` build in this record's verification pass, unlike the `fgj` path.
That is why the reader is fail-closed: a generation whose `whoami` does not distinguish a logged-out host from a logged-in one makes the resolver treat the host as unconfigured and refuse, rather than reaching for another CLI or guessing.
Its store is a JSON map from host to token (`~/Library/Application Support/forgejo-cli.forgejo-cli/keys.json` on macOS, the platform config directory elsewhere), which firstmate never reads, so the credential stays inside `fj`.

```
$ fj whoami --host <configured-host>;  echo $?   # 0
$ fj whoami --host <other-host>;       echo $?   # nonzero
```

Which hosts those are stays out of this record, the same way [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md) withholds its private-instance identifiers; what matters here is only that the answer is a status asked about one host at a time.

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

Both CLIs keep one login per instance and select it on the command line, but the stores and the way each answers for a host differ.

`fgj` keeps `~/.config/fgj/config.yaml` (or `$XDG_CONFIG_HOME/fgj/config.yaml`) with a `hosts:` map keyed by hostname, and picks one with `--hostname`; `FGJ_TOKEN` and `FGJ_HOST` override it. `fgj auth status` prints a human report of the configured instances:

```
$ fgj auth status
Authenticated instances:
  <bullet> <host> (user: <name>)
```

`runAuthStatus` in `cmd/auth.go` writes that line per instance, and prints the "Not authenticated with any Forgejo instances" notice on stdout when the map is empty.
That report is **not** what firstmate reads: `fgj` offers no `--json`/`-o` listing of its hosts, so matching the configured hostname against the report would mean parsing a rendered, human-facing line.
Instead firstmate reads `<host>`'s login presence from the exit status of `fgj auth token --hostname <host>`, which is 0 exactly when the instance is configured and nonzero when it is not:

```
$ fgj auth token --hostname <configured-host>;    echo $?   # 0
$ fgj auth token --hostname <unknown-host>;       echo $?   # 1
```

`runAuthToken` in `cmd/auth.go` reads the token for a configured instance and errors out when the host is absent, so the status is a documented, machine-checkable signal rather than a rendered surface — the property [`VISION.md`](https://github.com/kunchenguid/firstmate/blob/main/VISION.md) requires of an adapter over another tool's output.
The config file is still never read: it also holds each instance's token, and firstmate must not need it.

`fj` answers the same question per host: `fj whoami --host <host>` reports in its exit status whether that one host is logged in, as shown above, so no report is rendered, listed, or matched.

Both are handed the pull request's parsed host and fail rather than guess when it is not a host they hold a login for, mirroring the `tea login list` match [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md) owns.

## What firstmate does with this

`bin/fm-pr-lib.sh` owns the selection in one place.
`fm_pr_forgejo_cli_api_capable` declares which CLIs can make an authenticated request, `fm_pr_forgejo_resolve` picks a CLI and its own host login, and `fm_pr_forgejo_api` turns that into one request, so the merge watch (`bin/fm-pr-poll.sh`, which duplicates the selection because its body sources nothing), the merge path (`bin/fm-pr-merge.sh`), the terminal read (`bin/fm-crew-state.sh`), teardown's merged proof (`bin/fm-teardown.sh`), arming (`bin/fm-pr-check.sh`), and the ship brief and promotion that render the Definition of done (`bin/fm-brief.sh` and `bin/fm-promote.sh`) all agree. Those last two need no resolution of their own: they read the project's registered CLI, and `auto` is tea and only tea, which is exactly what `fm_pr_forgejo_resolve` produces for it.
The merge watch is handed the project's recorded preference through the registered poll sidecar, whose optional sixth line names it; a project that named none records no line and the watch resolves `auto`, exactly as before.
The watch's manual `--validated`/`--baseline` form keeps the six-argument shape `--validated <provider> <url> <host> <path> <number>` (preference `auto`) recorded for the other forges; the watcher's own invocation passes the recorded preference as an optional seventh argument.

A project names its CLI through the registry forge binding, `forge=forgejo:tea`, `forge=forgejo:fgj`, or `forge=forgejo:fj`, queried with `bin/fm-project-mode.sh --forge-cli`; `--forge` still answers `forgejo` for every spelling, so no existing consumer changes.
`forge=forgejo` alone, the spelling every registered project already has, means `auto`, and `auto` is `tea` and only `tea`.
`fgj` and `fj` are **opt-in**: a project reaches one only by naming it, `forge=forgejo:fgj` or `forge=forgejo:fj`.
The reason is that auto-detection would otherwise let a CLI's *stored login for some other host* silently change what firstmate ships with: on a home where `tea` holds no login for a project's host but `fgj` does, walking past `tea` would adopt `fgj` for a captain who never chose it, and the ship brief would start telling the worker to open the pull request with a different tool.
Keeping `auto` on `tea` alone makes an unmodified home's behaviour exactly what it was before, and makes the choice of CLI an explicit, reviewable act.
A project that needs `fgj` names it and is served; a project that names nothing and whose host has no `tea` login is refused with a message naming the binding to add, rather than silently switching tools.
