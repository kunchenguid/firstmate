# Gitea pull request watch

Empirical record for the merge watch on Gitea, alongside the existing GitHub and GitLab ones.
Every command below was run on 2026-09-08 and every output is reproduced exactly, with the credential's password redacted and nothing else changed.

## Versions

```
$ git --version
git version 2.55.0

$ curl --version | head -1
curl 8.7.1 (x86_64-apple-darwin25.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.68.1

$ jq --version
jq-1.8.2

$ bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)

$ sw_vers -productVersion
26.5.2
```

## The evidence instance

All live evidence here reads `Firefly/Zuri2` on a private Gitea instance at `code.fedgroup.co.za:7990`.
That instance is not public, so a reader outside its network cannot rerun these commands; the hermetic equivalents in `tests/fm-pr-check-security.test.sh` are what CI enforces everywhere.
The instance is used anyway because two of its properties are the whole point of this work and no public fixture has them: it serves a non-default port, and it is reachable only with a credential the operator already holds.
Pull request 188 is merged and pull request 149 is open, so both outcomes are shown against real data.

Every run below used a throwaway `FM_HOME` under the scratchpad, so no live task record was touched.

## Why the path segment identifies Gitea, not the hostname

A self-hosted forge can live on any hostname and any port, so a hostname test would recognise this instance and no other.
The three forges' pull request paths are disjoint instead: GitHub uses `/pull/<n>` under `github.com`, GitLab uses `/-/merge_requests/<n>`, and Gitea uses `/pulls/<n>`, plural.
`fm_pr_url_parse` in `bin/fm-pr-lib.sh` therefore matches Gitea on that segment alone, and the GitHub and GitLab branches keep matching exactly as they did.

Gitea has no nested namespaces, so a project is addressed by exactly one owner and one repository, unlike GitLab where a project sits under at least one group at no fixed depth.
The stored record carries `provider`, `url`, `host`, `path`, and `number` as before, with the host holding `host:port` when the instance uses one, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.

## Why the credential comes from git's own helper chain

Gitea has no CLI in the set firstmate already requires, so the merge state is read from the instance's REST API rather than through a tool like `gh` or `glab`.
That read needs a credential, and the operator already holds one for the host they clone and push to.
`git credential fill` returns it from whatever helper chain is configured, so no firstmate-specific token, token file, or environment variable is introduced:

```
$ printf 'protocol=https\nhost=code.fedgroup.co.za:7990\n\n' \
    | GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false git credential fill
protocol=https
host=code.fedgroup.co.za:7990
username=MarcoCerutti
password=<redacted>
```

The prompt and askpass paths are pinned off because an unattended poll cannot answer either, so a missing credential fails rather than hanging.
The credential is handed to curl as a config file on stdin, never on the command line, so it never appears in the poll process's arguments; `tests/fm-pr-check-security.test.sh` asserts both halves of that against a fake curl that records its argv and its stdin.

## What the API returns

The base URL is derived from the parsed pull request URL, so the host, the port, and the project all come from the record rather than from any configured default:

```
$ curl -sS --fail --max-time 20 -K - \
    "https://code.fedgroup.co.za:7990/api/v1/repos/Firefly/Zuri2/pulls/188" \
    | jq '{number, state, merged, merge_commit_sha}'
{
  "number": 188,
  "state": "closed",
  "merged": true,
  "merge_commit_sha": "fbda0283584299cebd1363e5fdeafe3c47560f4a"
}
```

Only an exact JSON `"merged": true` wakes firstmate.
`state` is `closed` on a merged pull request and on a declined one alike, so it is not the field the poll decides on.

## End to end: arming and polling a real pull request

Two tasks were armed against the instance, one on the merged pull request and one on the open one:

```
$ fm-pr-check.sh g1 https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
armed: state/g1.check.sh
$ fm-pr-check.sh g2 https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/149
armed: state/g2.check.sh
```

The stored record, showing the port as part of the host and the owner and repository as the whole path:

```
$ cat state/g1.pr-poll
gitea
https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
code.fedgroup.co.za:7990
Firefly/Zuri2
188
```

The provenance record, on the same version tag the other providers use:

```
$ cat state/g1.pr-poll-registration
fm-pr-poll-registration-v2
g1
gitea
https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
code.fedgroup.co.za:7990
Firefly/Zuri2
188
960bbbee3e03a14ca33854f603fdff171d6176ad1a0b80da8cec1d7d0e9bb729
44c2a922497ce8a7f8e0ec5892090e52fb0d486881139da3bb8617b3e7743f2d
16777233:458805547
16777233:458805548
```

The task metadata now holds the URL the captain can quote:

```
$ grep '^pr' state/g1.meta
pr=https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
```

The published poll is the shared program byte for byte, with no task or PR data compiled into it:

```
$ cmp bin/fm-pr-poll.sh state/g1.check.sh && echo identical
identical
```

Running each poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/g1.pr-poll)
merged
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/g2.pr-poll)
```

The merged pull request produces exactly one `merged` line and the open one produces nothing.

## A missing tool or credential produces no wake, never a false merge

The poll is silent on every error by design, so a missing `curl` would otherwise be indistinguishable from a pull request that is never merged.
With `curl` removed from `PATH`, the poll stays silent even for the pull request that is genuinely merged:

```
$ PATH="$nocurl" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/g1.pr-poll)
$ echo $?
0
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire:

```
$ PATH="$nocurl" fm-pr-check.sh g3 https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
error: watching a Gitea pull request requires curl on PATH
$ echo $?
1
```

An unresolvable credential is reported the same way, and names the command that stores one:

```
$ HOME="$nohome" fm-pr-check.sh g3 https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
error: watching a Gitea pull request on code.fedgroup.co.za:7990 requires a git credential for that host; store one with: printf 'protocol=https\nhost=code.fedgroup.co.za:7990\nusername=<user>\npassword=<token>\n\n' | git credential approve
$ echo $?
1
```

Neither refusal armed a poll or recorded a `pr=`, so a missing requirement leaves no half-prepared watch behind:

```
$ ls state/ | grep g3
g3.meta
```

A GitHub task is unaffected by a missing `curl`:

```
$ PATH="$nocurl" fm-pr-check.sh g4 https://github.com/kunchenguid/firstmate/pull/3904
armed: state/g4.check.sh
```

## Merging is refused, and refused before anything is recorded

A Gitea pull request parses and can be watched, but `bin/fm-pr-merge.sh` implements no Gitea merge path.
The refusal comes before the shared recording helper runs, because that helper arms the merge poll: a later refusal would leave a watch armed for a merge the script then declined to perform.

```
$ fm-pr-merge.sh g3 https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
error: merging a Gitea pull request is not supported; merge https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188 on the forge itself
$ echo $?
1
$ ls state/ | grep g3
g3.meta
```

Merge a Gitea pull request on the forge itself.
The watch then reports the merge exactly as it does for a merge performed anywhere else.

## How the task backlog records a Gitea URL

`tasks-axi` ships from a separate repository, `github.com/kunchenguid/tasks-axi`, so its validator is not firstmate's to widen from this checkout.
At version 0.2.5 its `--pr` flag accepts only an http(s) URL whose path ends in `/pull/<number>`, singular, so a Gitea URL is rejected there:

```
$ tasks-axi update gitea-probe --pr https://code.fedgroup.co.za:7990/Firefly/Zuri2/pulls/188
error: "--pr must be an http(s) pull request URL ending in /pull/<number>"
code: VALIDATION_ERROR

$ tasks-axi update gitea-probe --pr https://github.com/kunchenguid/firstmate/pull/3904
  body: ""
help[1]:
  - Run `tasks-axi show gitea-probe --full` to see the result
```

The GitHub URL is accepted on the same command and the same throwaway backlog, so the rejection is the path segment and nothing else.

The backlog does hold the link, in the note rather than the pr field.
`fm_backlog_completion_link_args` in `bin/fm-backlog-transition-lib.sh` is the single rule every close path uses, and it decides from the URL rather than from the forge.
A URL whose path ends in `/pull/<number>` is recorded through `--pr` exactly as before.
Any other URL is recorded through `--note`, which places it on its own body line under the closed row, still a link a reader can click.
One rule therefore covers Gitea's `/pulls/<number>` and GitLab's `/-/merge_requests/<number>` alike, and nothing about a closed GitHub task changes.

A URL that is not a well-formed https URL at all is still refused by the pending-close record validator, so an unrecordable close fails visibly rather than closing the row with a broken link.
Widening the `--pr` validator to accept `/pulls/<number>` belongs to the `tasks-axi` repository and is filed there, not here.

The URL firstmate itself watches is unaffected either way: `bin/fm-pr-check.sh` records it as `pr=` in the task's own metadata, shown above.

## Hermetic regression coverage

`tests/fm-pr-check-security.test.sh` covers the parser, the poll, the arming refusals, and the merge refusal without reaching any instance.
It pins the proven URL and a default-port Gitea URL as gitea, keeps a GitHub `/pull/<n>` URL and a GitLab `/-/merge_requests/<n>` URL parsing as before, rejects twenty-three near-miss Gitea URLs, and drives the poll against a fake curl and a fake `git credential fill` to assert the API address, the redacted argv, the escaped stdin config, and silence on every failure and every tampered sidecar.

`tests/fm-teardown.test.sh` covers the close itself against the real `tasks-axi`.
It tears a shipped task down three times, once per forge, and reads the closed row back through `tasks-axi show --full`: the GitHub URL lands in the row's `pr` link, the Gitea and GitLab URLs land in the row's body, and no pending-close record is left behind in any of the three.
