# Sunday review audit — 2026-09-27

Outcome: diagnosis complete; operational recovery remains BLOCKED by five deterministic coverage failures. No project source, home links, launchd jobs, production cursors, or external services were changed.

## Current findings

The scheduled Sunday coordinator did run at 00:00 KST (run_id 20260926T150000Z), failing coverage at about 00:00:50. The latest separate report records another attempt at 07:36:49 KST, also failing coverage; its trigger is not established by this audit. Both stop before docs_ssot, organize, doctrine_review, and skill_review. The timestamped failure ledger and quota-status record independently agree with the midnight failure.

Seven production coverage commands were run again in this audit with their output redirected into this evidence directory. Five fail: artifact, manifest, runtime, mirrors, drift. Pointers and instruction-surface pass. Exact invocations are recorded in coverage-invocations.json, exit codes and artifact paths in fresh-report.json.

- artifact: journal/retro/2026-09-26-upstream-merge-and-quota-fallback-retro.md lacks YAML frontmatter.
- manifest: runtime:get-linked-context is an orphan view entry.
- runtime: one Codex home link is missing; user-owned orphan entries are explicitly preserved by the checker.
- mirrors: ~/AGENTS.md points to IMAC-runtime/skill-store/global-AGENTS-codex.md; expected canonical Claude entry differs. Mirror configuration also expects missing skill-store/global-CLAUDE.md, and ~/.claude/CLAUDE.md is absent. Do not recreate a removed legacy source without reconciling current loader policy.
- drift: Claude points to the old runtime Codex entry; Gemini hooks still point to IMAC-runtime. Runtime commit 549c016d differs from canonical ec538f1a. Codex and AGY CLI checks pass.

These failures occur before provider calls. The midnight env guard allowed the coordinator to run, so missing required credentials did not cause this event. No new quota probe was needed to establish that cause. Current provider availability for a future recovery run remains unverified.

launchctl reports runs=1, not running, last exit code=0. The runner executes the guarded command then `cd -`; without `set -e` or explicit saved exit handling, that successful final cd masks the child failure. This is a source-level finding, not a live failure injection.

Sunday document governance and code-review-weekly have separate schedules: the former is Sunday 00:00; the latter plist says Wednesday 19:00. Do not conflate their expected outputs.

## Delivery evidence

No same-run docs/doctrine report POST or final GET evidence exists in the inspected Sunday run artifacts. They stop before those phases. The existing doctrine Discord receipt has a filesystem timestamp of 2026-09-21 and cannot establish today's delivery. A cron failure notification may have been sent by the wrapper; its target-system final GET was not performed, so delivery is unverified. This audit made no external writes.

## Recovery

Do not rerun the full batch unchanged: fresh checks reproduce all five failures. Repair the single retro metadata defect and reconcile manifest/home-loader/mirror contracts with the canonical loader policy in a scoped change. Preserve unrelated dirty files listed in git-status.txt. Fix runner exit propagation in its own minimal change. After the seven coverage checks pass, run the existing Sunday coordinator once and capture phase artifacts plus required POST/final GET delivery evidence. This audit does not claim that recovery or external delivery is complete.

## Evidence mapping

| Criterion | Exact scenario / invocation | Binary observable | Artifact |
|---|---|---|---|
| Scheduled job ran | Parse complete JSON records from production sunday-document-governance.log and read failure ledger | midnight run_id exists; status=failed; failed_phase=coverage | historical-runs.json; failure-events.jsonl; state-sunday-document-governance.json |
| Current schedule and launchd state | launchctl print gui/501/com.irene.cron.sunday-weekly-batch | loaded; Weekday=0; Hour=0; Minute=0; runs=1 | launchd.txt |
| Failure still reproducible | Python import sunday_document_governance; _run_coverage(ROOT, evidence/fresh) | five returncode=1; two returncode=0 | fresh-report.json; coverage-invocations.json; fresh/coverage-*.log |
| Phase abort prevents review | inspect coordinator PHASES and run_pipeline failure return; current and historical reports | only snapshot and coverage in phases | coordinator-source.txt; prior-report.json; historical-runs.json |
| False successful launchd status | inspect final runner command and launchctl | failed report alongside launchd exit 0 | runner-source.txt; launchd.txt; historical-runs.json |
| Today delivery not established | inspect phase artifact dates and stored Discord receipt | no later phases; prior receipt dated 09-21 | phase-artifact-times.json; state-discord-review-sunday-document-governance-doctrine.json |

Historical files are used only as timestamped execution records, cross-checked against current code and freshly executed coverage checks. No old report is treated as proof of present success.
