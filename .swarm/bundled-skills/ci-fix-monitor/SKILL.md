---
name: ci-fix-monitor
audience: swarm-plugin
description: >
  Monitor CI on a PR, diagnose failures, fix them, and re-push until green.
  Covers reading CI logs, classifying failure types (check-title, package-check,
  test failures, lint), determining the correct fix, and re-pushing.
---

# CI Fix & Monitor Protocol

Activates when the user asks to monitor CI, fix CI failures, or resolve red
checks on a PR.

## Environment note — tool availability

This skill was originally written for desktop Claude Code (Windows) with `gh`
CLI. In the **remote execution / GitHub MCP** environment, use the equivalent
MCP tools instead:

| Capability needed | `gh` CLI | Example remote-MCP shape (resolve the real names via ToolSearch) |
|---|---|
| `gh pr checks <number>` | `mcp__github__pull_request_read` method `get_check_runs` |
| `gh pr view <number> --json checks` | `mcp__github__pull_request_read` method `get_check_runs` |
| `gh run view <run-id> --job <job-id> --log` | `mcp__github__get_job_logs` with `job_id` and `return_content: true` |
| `gh pr edit --title` | `mcp__github__update_pull_request` with `title` |
| `gh pr view --json mergeable` | `mcp__github__pull_request_read` method `get` |

> MCP tool names are injected by the runtime harness and are NOT stable across
> environments. Treat the right-hand column as an example SHAPE only: resolve
> the actual tools by CAPABILITY (PR read with check-run support, job-log read,
> PR update) via `ToolSearch` before first use in a session — never assume a
> specific `mcp__github__*` name exists (issue #2131 finding 9).

## Step 1 — Fetch current status

Fetch all check runs for the PR head commit. If all green: report success
and stop.

## Step 2 — Classify each failure

| Failure type | Root cause pattern | Fix action |
|---|---|---|
| **check-title** | PR title lacks `<type>(<scope>):` prefix | Update title via PR edit |
| **package-check** | npm tarball validation failed (source/build/package-manifest problem) | Fix source/build/manifest — see section below. Not generated-file drift. |
| **branch behind main** | Branch is behind main; main had a release commit; CI uses merge-commit checkout | Rebase onto main, force-push — see section below |
| **lint/quality: format** | Code style violations (long lines, spacing) | `bunx biome format --write <files>` then commit |
| **lint/quality: lint** | Lint rule violations (noExplicitAny, etc.) | `bunx biome check --write <files>` or fix manually |
| **unit test** | Test failures | Read log, fix code, commit |
| **integration** | Integration failures | Read log, check if pre-existing on main |
| **macOS unit test** | Cross-platform file I/O race (atomic write-then-read returns null on macOS) | See "macOS file I/O fixes" below |
| **security** | SAST/secret findings | Read log, fix or suppress with justification |
| **smoke** | Smoke test failures | Read log, check if environment-specific |

## macOS file I/O fixes (cross-platform atomic write)

macOS/APFS has different filesystem timing than Linux ext4. `fs.renameSync` can
complete before the data is visible to subsequent reads. The most common
manifestation is `unit (macos-latest)` failing on tests that write-then-read
atomic files (e.g., `curator atomic write > writeCuratorSummary > after write,
readCuratorSummary reads file back successfully`), while the same tests pass
on `ubuntu-latest` and `windows-latest`.

**Canonical patterns:** See
`file:.opencode/skills/writing-tests/SKILL.md`
§ Cross-Platform Requirements → "macOS rename-visibility race" for the
full three-layer fix pattern (bunWrite + ENOENT retry + Node FileHandle.sync()
not fsync()). This skill is a triage pointer; the canonical technical
reference lives in `writing-tests` so it survives any regeneration of this
`generated/` file.

**Related security test pattern:** if the CI failure involves a long task ID
or path, the security test `ADVERSARIAL: Command Services Attack Vectors >
Attack Vector 1: Malformed Arguments > EVIDENCE: extremely long task ID
(buffer overflow) - ACCEPTED by regex but no crash` requires a path length
guard BEFORE `validateSwarmPath` in `src/evidence/manager.ts:loadEvidence`.
See `file:.opencode/skills/engineering-conventions/SKILL.md`
for the evidence file flow that this gate check triggers on macOS CI.

## Step 3 — Diagnose with logs

For every failed check, fetch the full log content. Fetch only the tail
(last 80–100 lines) unless the error is near the start.

Read the log carefully before concluding root cause. Distinguish between:
- a failure introduced by this PR,
- a pre-existing failure on `main` (verify by checking main's last CI run for
  the same check), and
- a failure caused by the CI environment or branch drift.

## Step 4 — Fix

### check-title
No commit needed. Update the PR title.

### package-check failure

`package-check` validates the npm tarball (`npm pack` + tarball contents). A
failure is a source/build/package-manifest problem, **not** generated-file
drift. `dist/` is generated and NOT committed — do not stage it. Run
`bun run build` locally only when you need the bundle to verify the failure:

```bash
bun run build
node --input-type=module -e "await import('./dist/index.js'); console.log('dist import OK')"
```

Fix the underlying source/build/`package.json` `files` manifest issue, then
commit the source fix (not `dist/`) and push.

### branch behind main (version drift)

**Identifying this case:** A version string differs (`version: "X.Y.Z"` changed
to a higher version) because main had a release commit after the branch was cut,
and GitHub Actions checks out the merge-commit for CI. Rebase onto main to pick
up the release commit.

**Fix:**

```bash
git fetch origin main
git rebase origin/main       # fast-forward the branch onto the release commit
# If the rebase halts with conflicts, run `git rebase --abort` and escalate
# to the user — do not attempt to resolve a conflicted rebase automatically.
git push --force-with-lease origin <branch>   # force-push is required after rebase
```

> `--force-with-lease` is safe here: it refuses to overwrite commits that
> appeared on the remote after your last fetch. After the rebase, the local
> branch has diverged from remote history — a regular push will be rejected.

- Do NOT stage or commit `dist/` — it is generated and NOT committed; there is no committed-dist drift check
- After a rebase, a force-push is required and expected — do not try a regular push

### lint/quality: format violations

Biome format violations (line too long, spacing, bracket style) — these can
appear when a code change introduces a line that exceeds Biome's print-width.
Auto-fix only the changed files to minimize noise:

```bash
bunx biome format --write src/path/to/changed-file.ts
bun test src/path/to/changed-file.test.ts   # verify tests still pass after format
git add <files>
git commit -m "style: apply Biome formatting"
git push origin <branch>
```

> Do NOT run `bunx biome format --write .` on the entire repo unless instructed
> — this can introduce formatting changes in unrelated files and bloat the diff.

### lint/quality: lint rule violations

```bash
bunx biome check --write <specific-file>
# or fix manually if --write does not handle the rule
```

### integration failures

Check whether the same check failed on `main`'s last CI run before treating
it as PR-introduced. If pre-existing: document the finding and skip. If
introduced by this PR: collect the full failure log, the test name, and the
first error line, then delegate to a coder with that evidence.

### security (SAST/secret findings)

Fetch the full log. If it is a secret/credential finding: confirm the file
and line, remove or rotate the credential, and commit the fix. If it is a
SAST code-quality finding: collect the rule ID, file, and line, then
delegate to a coder. Do NOT suppress findings without an explicit
justification comment approved by the user.

### unit test / smoke failures
Delegate to coder with specific failure details (test name, assertion, first
error line). See execute skill.

## Step 5 — Push and monitor

After pushing, subscribe to PR activity (if in webhook/MCP context) and wait
for the next CI event rather than polling. Do not push a second time until the
CI result from the first push is confirmed.

If no CI event arrives after a reasonable wait (e.g., checks are still queued
and stalled), re-fetch check status manually via `get_check_runs` and report
the stall state to the user rather than waiting indefinitely.

## Step 6 — Verify all green

Do NOT declare victory until ALL required checks pass. A check in `skipped`
state is acceptable only if the same check was skipped on the base branch
(i.e. the workflow gates on a path filter). Confirm this explicitly.

## Standalone retry bound

When this skill is invoked directly (not composed via `swarm-ci-monitor`'s
own 5-iteration counter), cap fix-push cycles at 5 iterations. If the PR is
still not green after 5 fix-push cycles, stop and escalate to the user with
the last failing check and a short log excerpt rather than looping
indefinitely.
