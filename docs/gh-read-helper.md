# Cursor worker GitHub read helper

Cursor ship and scout workers resolve `gh` through a native router that sends only accepted closed reads to the dedicated native reader, `fm-gh-read`.
Writes, unsupported forms, and URL selectors continue to the generic attended `gh` path.
The helper is a single-file Mach-O whose parser and policy are compiled in.
It accepts only closed read-only argument shapes, then runs the absolute `/usr/local/bin/gh` with a constructed environment.
Any local process can invoke it and receives the same closed API; the helper does not prove that Cursor was the caller.

Writes, credential disclosure, aliases, extensions, downloads, checkouts, logs, artifacts, hostname overrides, request bodies, secrets, variables, and generic REST or GraphQL are denied before the target starts.
Attended GitHub writes stay on the existing non-helper paths.
The general GitHub Gate remains Read Only for other verified launchers; this helper adds one exact Read Only row for its enrolled identity and does not change that default or any write rule.

Pi, Herdr, Firstmate, interactive shells, Cursor secondmates, generic `/usr/local/bin/gh`, and global `gh-axi` resolution are unchanged.
Only a Cursor ship or scout launch prepends the protected PATH directory whose `gh` entry is the native router.

## Closed read surface

Accepted families are repository `view`, pull request `list`/`view`/`checks`, issue `list`/`view`, Actions run `list`/`view`, and workflow `list`/`view`.
Every invocation requires a canonical `owner/name` repository selector so `gh` never derives a repository or host from local Git context.
Numeric `--limit` values are bounded.
Release metadata is omitted until a current Firstmate use is proven.
[`bin/native/fm-gh-read.c`](../bin/native/fm-gh-read.c) is the complete allowlist.

Some `gh-axi` reads issue optional GraphQL totals or REST review augmentation.
The router sends those generic `api` forms to the attended `gh` path, where they gain no automatic authority; the primary closed list or view still succeeds when `gh-axi` treats the extra call as optional.

## Installation and enrollment

[`bin/fm-gh-read.sh`](../bin/fm-gh-read.sh) owns the commands, flags, and checks.
`plan` and `verify` change nothing.
`build` compiles the tracked source.
Launcher Bundle enrollment and the helper-specific Gate row happen only in the Automic Vault App, for one exact generation, with no compatibility exception unless a measured native requirement proves it necessary.
`install-path` is the only mutating command in the script: it creates the protected Cursor PATH directory and native router through `sudo` after the operator types `install` at an interactive terminal, and it refuses a non-interactive run, a test-directory override, and a helper command that is not already a protected executable.

Verify the built payload digest, code signature, entitlements, protected ownership and link, exact `/usr/local/bin/gh` target, and current Gate attribution before trusting a Cursor worker to use the helper.
`verify` never contacts Automic Vault or GitHub and leaves Gate attribution unverified because Authorization History has no published machine-readable schema.
Confirm in the App that the helper was the launcher and its exact Read Only row authorized the request.

## Tests

[`tests/fm-gh-read.test.sh`](../tests/fm-gh-read.test.sh) builds the helper against an absolute fake target.
It covers every allowed argv shape, mutations at every argument position, duplicate and equals forms, malformed repositories and limits, environment scrubbing, parser-before-target ordering, representative denials with proof the target did not start, and Cursor-only PATH construction.
