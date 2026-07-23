# Gitea forge verification

## Scope and current evidence

The Gitea foundation is verified only with deterministic mocked HTTP and git fixtures as of 2026-07-23.
No live Gitea server, repository, account, credential, or captain-private token was accessed while producing this evidence.
`bin/fm-forge-lib.sh` owns provider dispatch and all Gitea configuration, token custody, HTTP, and response validation.
`bin/fm-pr-lib.sh` owns canonical pull-request identity and poll provenance across GitHub, GitLab, and Gitea.
The private configuration schema and operator commands live in [`configuration.md`](configuration.md) and `bin/fm-forge.sh --help`.

The mocked suite covers canonical HTTP and HTTPS identities, explicit web ports, SSH aliases and ports, token-file permissions, token absence from argv and diagnostics, authentication failures, malformed and cross-host responses, PR creation, head/state/review/check queries, poll binding, guarded merge confirmation, and landed-work cleanup evidence.
It also runs the existing GitHub and GitLab PR regressions unchanged.

The implementation run used the repository-pinned ShellCheck 0.11.0 and produced the following exact command summaries.

```text
$ PATH="<worktree-local-shellcheck-0.11.0>:$PATH" bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-test-run.sh tests/fm-forge-gitea.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=6770
FM_TEST_SUMMARY_FAMILY family=pr-forge count=1 duration_ms=6720 failed=0

$ bin/fm-test-run.sh tests/fm-pr-merge.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=5629
FM_TEST_SUMMARY_FAMILY family=pr-forge count=1 duration_ms=5564 failed=0

$ bin/fm-test-run.sh tests/fm-brief.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1216
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=1148 failed=0

$ bin/fm-test-run.sh tests/fm-instruction-owners.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=331
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=250 failed=0

$ bin/fm-test-run.sh tests/fm-review-diff.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1169
FM_TEST_SUMMARY_FAMILY family=pr-forge count=1 duration_ms=1103 failed=0

$ bin/fm-test-run.sh tests/fm-teardown.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=32908
FM_TEST_SUMMARY_FAMILY family=pr-forge count=1 duration_ms=32838 failed=0

$ bin/fm-test-run.sh tests/fm-pr-check-security.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=373514
FM_TEST_SUMMARY_FAMILY family=pr-forge count=1 duration_ms=373460 failed=0

$ PATH="<worktree-local-shellcheck-0.11.0>:$PATH" bin/fm-test-run.sh --changed --base HEAD
FM_TEST_SUMMARY total=36 failed=1 skipped_gate=1 duration_ms=734058
FM_TEST_SUMMARY_FAMILY family=pr-forge count=6 duration_ms=484975 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=30 duration_ms=247770 failed=1
```

The changed-file suite's complete PR/forge family passed.
Its unrelated `fm-calm-pi-extension.test.sh` failed because the installed Node 22 runtime rejected a direct `.ts` import with `ERR_UNKNOWN_FILE_EXTENSION`, and the optional Pi typecheck reported its normal missing-`tsc` skip.
No Gitea or PR/forge test failed in that run.

## Live verification boundary

Live behavior remains unverified and must not be inferred from mocked evidence.
A later separately authorized verification task may exercise only the captain-approved `Brad/Test-Repo` repository and must record the server version, exact commands, redacted outputs, and cleanup outcome here.
Until that evidence exists, do not describe Gitea support as empirically verified against a production server.

The reusable authenticated request function is the extension point for later issue and milestone operations.
This slice deliberately exposes no raw arbitrary-API command and no repository-creation command, so future operations must add typed validation rather than bypass token custody through ad hoc curl calls.
