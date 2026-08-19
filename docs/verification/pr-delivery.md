# PR delivery loop verification

Audience: maintainer verification.

This record holds reusable evidence for the bounded main-home PR delivery adjunct.
`bin/fm-pr-delivery.sh` header and `--help` own scan mechanics; `.agents/skills/pr-delivery/SKILL.md` owns wake handling.

Verified on 2026-08-19 on macOS with bash 5.x and jq installed.

## Behavior tests

```sh
$ bin/fm-test-run.sh tests/fm-pr-delivery.test.sh
all pr-delivery tests passed
```

The suite covers registry discovery without a secondmate signal, complete green-check evidence, review and comment holds with later clearance, migration and authority holds with re-evaluation, base-branch changes, optional-review silence, inventory pagination, bounded-scan queue preservation, and retry-safe wake publication.

## Lint

```sh
$ bin/fm-lint.sh bin/fm-pr-delivery.sh
# shellcheck clean for changed delivery scripts
```
