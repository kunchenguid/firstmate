# GitLab delivery retirement verification

GitLab PR checking, polling, and merging are explicitly inactive migration compatibility.
Bounded direct-PR delivery supports GitHub only because its authorization contract requires terminal checks green for the recorded exact GitHub PR head SHA.

## Retained compatibility boundary

`bin/fm-pr-lib.sh` still parses a canonical `https://<host>/<path>/-/merge_requests/<n>` identity so legacy metadata can be recognized and refused deterministically.
The parser does not authorize a new poll, check, or merge.
`fm_pr_poll_prepare` accepts only `provider=github` and publishes no artifact for a recognized GitLab identity.
`bin/fm-pr-poll.sh` stays silent for a GitLab sidecar or validated invocation and never calls `glab`.
`bin/fm-pr-check.sh` and `bin/fm-pr-merge.sh` return non-zero with an inactive-migration-compatibility diagnostic before invoking a forge CLI or publishing active GitLab delivery state.

## Maintainer verification

Run the focused behavioral owners after changing the provider boundary:

```sh
bash tests/fm-pr-check-security.test.sh
bash tests/fm-pr-merge.test.sh
```

The security test proves that canonical GitLab identities remain recognizable while poll preparation refuses, the static poll stays silent, and check and merge entry points call neither `glab` nor `gh-axi`.
The merge test independently proves refusal before PR metadata or forge effects.
The GitHub cases in both files continue to own exact-head checking, static polling, bounded merge authorization, and landed-or-queued outcome handling.
