# Pull request landing-target verification

Empirical record for the one question `bin/fm-pr-landing-lib.sh` asks the forge: whether the viewer can merge into the repository hosting a pull request.
Every command below was run on 2026-08-23 against the live GitHub API, and every output is reproduced exactly.

The guarantee this record supports: the landing verdict comes from the forge's answer about the viewer, not from a repository name, so a second fork or a rename cannot silently turn the guard off.

## Versions

```
$ gh-axi --version
0.1.30

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)

$ git --version
git version 2.43.0
```

## The field that answers the question

GitHub requires push access to merge a pull request, and its repository object carries the viewer's own permissions.
`gh-axi api` prints a bare boolean for a scalar `--jq` expression, which is what the library matches against.

A read-only upstream:

```
$ gh-axi api /repos/kunchenguid/firstmate --jq .permissions.push
false
```

A fork the viewer owns:

```
$ gh-axi api /repos/x45dev/firstmate --jq .permissions.push
true
```

The full permissions object behind those two answers, showing that `push` is the discriminating field rather than a coincidence of one flag:

```
$ gh-axi api /repos/kunchenguid/firstmate --jq '{permissions:.permissions, parent:(.parent.full_name // null), fork:.fork}'
fork: false
parent: null
permissions:
  admin: false
  maintain: false
  pull: true
  push: false
  triage: false

$ gh-axi api /repos/x45dev/firstmate --jq '{permissions:.permissions, parent:(.parent.full_name // null), fork:.fork}'
fork: true
parent: kunchenguid/firstmate
permissions:
  admin: true
  maintain: true
  pull: true
  push: true
  triage: true
```

## What a repository the forge will not answer for looks like

An unresolvable repository exits non-zero, which the library classifies as an answer it did not get rather than as a permission it has:

```
$ gh-axi api /repos/kunchenguid/firstmate-does-not-exist --jq .permissions.push
error: "gh: Not Found (HTTP 404)"
code: NOT_FOUND
$ echo $?
1
```

## Coverage limit

GitLab has no equally direct answer.
A member's numeric access level does not by itself decide whether a merge request can be merged, because a project's merge access is separately configurable per protected branch, so no threshold was assumed and no GitLab evidence is claimed here.
`bin/fm-pr-landing-lib.sh` returns `unchecked` for that provider and callers leave the GitLab path exactly as it was; `bin/fm-pr-check.sh` records that verdict rather than a confirmation.

## Regression pointers

`tests/fm-pr-check-security.test.sh` (`test_landing_target_guard`) pins the arming contract with a stubbed forge, holding the repository name constant across opposite answers so a name-matching rule cannot pass.
`tests/fm-fleet-snapshot-view.test.sh` (`test_pr_landing_verdict_is_reported`) pins the reporting contract, including a pull request scraped from a status log carrying no recorded verdict.
