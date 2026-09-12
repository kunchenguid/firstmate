---
name: dependency-bump-triage
description: >-
  Agent-only procedure for reviewing Dependabot and Renovate dependency bumps.
  Load before triaging, reviewing, or briefing an automated dependency-version PR.
  Owns lockfile and pin verification, imported-symbol impact analysis, upstream comparison, security and CI-gap checks, risk escalation, and the final bump verdict.
user-invocable: false
metadata:
  internal: true
---

# dependency-bump-triage

This skill is the single owner of the Dependabot and Renovate bump-triage procedure.
A firstmate uses it to scope, brief, and verify the triage, while project-specific inspection and any lockfile regeneration remain delegated under `AGENTS.md` section 1.
The procedure below is written to paste unchanged into a crewmate brief.
Merge authority remains owned by `AGENTS.md` section 7.
Load `pr-review-cycle` with this skill and apply its common exact-head review cycle to every bump.
Only its independent Codex scout may be omitted under the narrow exception below.

## Establish the exact bump

Set the repository and pull request explicitly, then capture the immutable head and complete changed-file list.

```sh
OWNER=<owner>
REPO=<repo>
PR=<number>
gh-axi api "/repos/$OWNER/$REPO/pulls/$PR" --jq '{url:.html_url,author:.user.login,authorType:.user.type,authorAssociation:.author_association,draft,headRef:.head.ref,headSha:.head.sha,baseRef:.base.ref}'
gh-axi api "/repos/$OWNER/$REPO/pulls/$PR/files?per_page=100" --paginate --full --jq '.[] | [.filename,.status,.additions,.deletions] | @tsv'
gh-axi pr diff "$PR" -R "$OWNER/$REPO" --full
```

Confirm from the full diff that the change contains only dependency manifest pins, generated lockfiles, and automation metadata directly required for the version bump.
Generated lockfile transitive changes must be explainable by the selected package version.
Any source, build logic, test logic, workflow behavior, vendored implementation, install script, patch file, or unrelated dependency change makes the PR non-routine and requires the normal `pr-review-cycle`.

In an isolated clean checkout at `REVIEW_HEAD`, run the project's documented lockfile regeneration or frozen-lock validation with the repository's pinned package-manager version.
After regeneration, require no unexplained change in the manifest and lockfile surface.

```sh
<project lockfile regeneration or frozen-lock command>
git diff --exit-code
test -z "$(git status --porcelain=v1)"
```

Require the entire checkout to remain clean, including package-manager metadata and untracked generated outputs, rather than checking only the expected manifest and lockfile paths.
If the project has no deterministic regeneration or frozen-lock validation path, record that evidence gap and do not use the independent-review exception.

Record the package, ecosystem, exact old version, exact new version, and upstream source repository.
Do not infer those values from the PR title when the manifest or lockfile disagrees.
Verify that the author is the repository's configured Dependabot or Renovate bot, that GitHub reports its actor type as `Bot`, and that the head branch matches that automation's configured namespace.
Route a human author, an unrecognized bot, or an identity mismatch through the full `pr-review-cycle` with no shortcut.

## Find the project's actual dependency surface

Read the dependency metadata or lockfile entry for its exported module names, executables, plugin identifiers, and configuration names.
Search the whole project for the package name and each of those literal identifiers before excluding generated dependency files.

```sh
IDENTIFIER=<package-name-export-module-binary-or-plugin-identifier>
rg -n -F --hidden --glob '!.git/**' --glob '!vendor/**' --glob '!node_modules/**' --glob '!dist/**' --glob '!build/**' "$IDENTIFIER" .
```

Read every import, require, include, feature flag, command invocation, configuration key, type reference, and wrapper found by that search.
List every symbol or executable surface the project actually uses from the package.
Run focused searches for each imported symbol so aliases, re-exports, fixtures, and runtime construction sites are included.

```sh
SYMBOL=<imported-symbol-or-command>
rg -n --hidden --glob '!.git/**' --glob '!vendor/**' --glob '!node_modules/**' --glob '!dist/**' --glob '!build/**' "$SYMBOL" .
```

An empty source-usage result is a fact to report, not permission to skip upstream and security checks.

Inventory every old-to-new package delta introduced by the lockfile change, including transitive packages.
For every build-, release-, test-infrastructure-, or runtime-relevant delta, repeat the upstream comparison, locally used-surface search, advisory check, and risk-amplifier classification below.
Record exempt development-only transitive deltas and the evidence that they cannot enter any build, release, test-infrastructure, generated-output, or runtime path.
An unexplained transitive delta makes the bump non-routine.

## Compare upstream changes to local usage

Fetch the authoritative upstream comparison for the exact released versions.

```sh
UPSTREAM_OWNER=<upstream-owner>
UPSTREAM_REPO=<upstream-repo>
OLD_VERSION=<old-tag-or-sha>
NEW_VERSION=<new-tag-or-sha>
gh-axi api "/repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/compare/$OLD_VERSION...$NEW_VERSION" --full --jq '{status,ahead_by,behind_by,total_commits,returned_commits:(.commits|length),returned_files:(.files|length),commits:[.commits[] | {sha:.sha,message:.commit.message}],files:[.files[] | {filename,status,additions,deletions,patch}]}'
```

Verify tag naming in the upstream repository when the package uses prefixes such as `v`, package-scoped tags, or monorepo release tags.
Inspect every changed upstream file that defines, exports, documents, tests, or calls a symbol or executable surface used by the project.
Check signatures, defaults, return types, error behavior, feature gates, platform support, and transitive native or protocol changes rather than relying on release-note labels.
If GitHub truncates a patch or the compare response, fetch the named file or commit diff separately before deciding.
If `returned_commits` is smaller than `total_commits`, or `returned_files` reaches GitHub's 300-file compare cap, the API response is not a complete change inventory.
In that case, use an isolated upstream checkout with both exact tags fetched and inspect the complete local comparison before deciding.

```sh
UPSTREAM_CHECKOUT=<isolated-upstream-checkout>
git -C "$UPSTREAM_CHECKOUT" fetch --tags origin
git -C "$UPSTREAM_CHECKOUT" diff --name-status "$OLD_VERSION" "$NEW_VERSION"
git -C "$UPSTREAM_CHECKOUT" diff "$OLD_VERSION" "$NEW_VERSION" -- <every-file-that-touches-a-locally-used-symbol>
```

## Check advisories and risk amplifiers

Inspect the target repository's Dependabot alerts, the upstream repository's published advisories, and an authoritative ecosystem or cross-ecosystem advisory source for both exact versions when access permits.

```sh
gh-axi api "/repos/$OWNER/$REPO/dependabot/alerts?state=open&per_page=100" --paginate --full
gh-axi api "/repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/security-advisories?per_page=100" --paginate --full
```

Record an authorization failure as an evidence gap rather than claiming there are no advisories.
Record unavailable ecosystem advisory coverage the same way and do not use the independent-review exception.
Read the bump PR body, release notes, changelog, and upstream compare for security fixes or newly disclosed vulnerabilities affecting either version.

Never rubber-stamp any of these cases:

- A TLS, fingerprinting, anti-bot, browser-impersonation, proxy, or transport client.
- An authentication, authorization, session, token, password, cryptography, WebAuthn, TOTP, HOTP, OTP, or recovery-code library.
- A major-version bump or any release with documented breaking behavior.
- A release associated with a security advisory, security fix, withdrawn version, compromised package, or changed trust boundary.
- An upstream change touching a locally imported symbol, its signature, its defaults, or its transitive protocol behavior.

These cases require targeted review and tests appropriate to the affected boundary even when the repository diff itself is lockfile-only.

## Account for CI gaps

Read every check on the exact PR head and inspect workflow conditions that can skip work for bot-authored pull requests.

```sh
gh-axi pr checks "$PR" -R "$OWNER/$REPO"
rg -n --hidden 'dependabot|renovate|github\.actor|pull_request_target|if:' .github/workflows
```

For every skipped or absent job, state what behavior it normally validates and whether another result covers that behavior on this head.
A green subset is not equivalent to a green normal-PR matrix.
Run or request the smallest missing targeted validation when the skipped coverage intersects the package's actual use.

## Apply the review exception narrowly

A hand-verified bump may skip the independent Codex scout only when all of these are true:

- The repository diff is exclusively one dependency-version change represented by its manifest pin, its mechanically generated lockfile, or both, plus any automation metadata.
- Deterministic regeneration or frozen-lock validation succeeds with no unexplained manifest or lockfile diff.
- The bump is not in any risk-amplifier class above.
- Every direct and build-, release-, test-infrastructure-, or runtime-relevant transitive delta has been inventoried, and its upstream compare does not touch any locally used symbol, signature, default, or transitive behavior.
- No relevant security advisory or unresolved evidence gap exists.
- CI covers the affected install, build, test, and runtime surface without an unexplained bot-only skip.

If any condition is false, run `pr-review-cycle` in full, including its independent Codex scout.
If every condition is true, continue the common `pr-review-cycle` while marking only its independent Codex scout not applicable with this evidence.
The exception does not waive thread inspection, CI reading, bot findings, or exact-head verification required by the common cycle.

## Report shape

Report this compact evidence block:

```text
PR: <full URL>
Head: <full SHA>
Bump: <package> <old version> -> <new version> (<ecosystem>)
Repository diff: <exactly which manifest, lockfile, or other files changed>
Lock validation: <exact regeneration or frozen-lock command and clean-diff result>
Dependency deltas: <direct and transitive old-to-new inventory>
Local use: <every package, module, binary, plugin identifier, imported symbol, or executable surface, or none>
Upstream impact: <whether changed upstream files for each relevant delta touch local use and how>
Security: <repository, upstream, and ecosystem advisory evidence or explicit gap>
CI: <all checks and any bot-only skipped coverage>
Review path: <hand-verified exception or full pr-review-cycle>
Verdict: routine | targeted review required | needs fixes
Reason: <one plain sentence naming the decisive fact>
```

Use `routine` only when every exception condition is proven.
Use `targeted review required` when risk or missing coverage needs deeper evidence but no defect is established.
Use `needs fixes` when the proposed version or PR is demonstrably unsafe or incomplete.
Never merge as part of triage; follow `AGENTS.md` section 7 for merge authority.
