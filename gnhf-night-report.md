# Skill-mining night report

## Miner patterns (iteration 2)

| Pattern | Count | Scriptable | Notes |
|---------|-------|------------|-------|
| P1 raw-gh | pending (slow fleet scan) | yes | Selected as highest scriptable=yes candidate |
| P2 session-start-not-first | 0 | yes | |
| P3 silent-exit | 0 | yes | |
| P4 rule-negatives | 0 | yes | |
| P5 skill-loads | pending (slow fleet scan) | no | |
| P6 accept-by-class | 923 | no | context only |

Full miner stdout for fast patterns is in `.bench/mined.md`.

## Candidate `gh-axi-instead` (P1 raw-gh)

Harness-neutral skill instructing use of `gh-axi` instead of bare `gh` for GitHub CLI shell steps.

### Score output

```
CASE p1-acme-issues codex A=pass B=pass C=pass
CASE p1-acme-issues claude A=pass B=pass C=pass
CASE p1-cedar-workflows codex A=pass B=pass C=pass
CASE p1-cedar-workflows claude A=pass B=pass C=pass
CASE p1-harbor-branches codex A=pass B=pass C=pass
CASE p1-harbor-branches claude A=pass B=pass C=pass
CASE p1-nimbus-releases codex A=pass B=pass C=pass
CASE p1-nimbus-releases claude A=pass B=pass C=pass
CASE p1-orion-prs codex A=pass B=pass C=pass
CASE p1-orion-prs claude A=pass B=pass C=pass
CASE p1-quartz-labels codex A=pass B=pass C=pass
CASE p1-quartz-labels claude A=pass B=pass C=pass
CANDIDATE gh-axi-instead VERDICT DISCARD
HELDOUT_GAIN 0
```

**Discard reason:** visible arms tied (B did not exceed A by 2+ on either harness); arm B passes never showed `loaded=yes` (harnesses used `gh-axi` without auto-loading the skill); held-out cases did not flip from fail to pass.

## Bench fixes this iteration

- Added `FM_SKILL_BENCH_CASES_DIR` so contract self-test cases live under `tests/fixtures/fm-skill-bench/selftest-cases/` separately from mining cases.
- Fixed held-out hash verification to respect the cases directory override.
- Fixed duplicate case execution where `*.heldout.case` files also matched `*.case`.

## Iteration 3: bench hermeticity and loaded-detection fixes

Root cause found for iteration 2's false tie: bench run repos were not git roots, so both harnesses walked up the directory tree and merged the parent firstmate `AGENTS.md`/`CLAUDE.md`, which already instructs the agent to use the GitHub CLI wrapper and run the session-start script. That contamination made arm A pass without any skill, so the candidate could never beat arm A by the required +2 margin.

### Changes

- `bin/fm-skill-bench.sh` now `git init`s each run repo (with a local throwaway identity) before invoking the harness, so the run repo is the project root and the parent firstmate instructions are no longer merged. Verified empirically: an isolated codex arm A session no longer references the session-start script or the firstmate prime directives.
- Fixed codex loaded-detection: the `find | while` pipeline ran `return` in a subshell, so the skill was never reported as loaded even when referenced. Switched to a process-substitution loop with a flag variable, and narrowed the match to tool-call/output payload lines (excluding the skills-index listing) so an actual load is required.
- Fixed claude loaded-detection: added a fallback to search `~/.claude/projects/<cwd>` for transcripts written after the run started, since claude does not write a transcript into the run directory.
- Untracked the `.bench/` directory (330 files were accidentally committed in iteration 2) and added `.bench/` to `.git/info/exclude` so the orchestrator cannot re-commit it; `.bench/` is hermetic scratch space.
- Classified the bench's tracked test-fixture and rejection-record markdown under `maintainer-verification` in `docs/documentation-audiences.json` so the doc-audience check passes (it requires every tracked `*.md`/`*.txt` to be classified).

### Gate

All four commit-gate commands green on the current tree: bench self-test, fast lint, doc-audience check (105 surfaces), coverage check (244 tests). Immutable surface diff against base is empty.

### Probe

Ran one isolated codex arm A probe (2 runs) on a P1 case to confirm the parent instructions are gone. With isolation, the agent's recorded commands no longer reference the wrapper or the session-start script, confirming the hermeticity breach is closed. No candidate was scored this iteration.

## Candidate `repo-boot-order` (P2 session-start-not-first)

P1 was already rejected, and a post-isolation arm A probe still invoked `gh-axi` without a skill, so P1 cannot beat arm A.
P2 was the next scriptable pattern.
The candidate tells the agent to invoke `fm-session-start` before any other repository command.
The skill body names the command; the description does not.

### Score output

```
CASE p2-ember-kit codex A=fail B=pass C=fail
CASE p2-ember-kit claude A=fail B=fail C=fail
CASE p2-frost-board.heldout codex A=fail B=pass C=pass
CASE p2-frost-board.heldout claude A=fail B=fail C=fail
CASE p2-granite-cli.heldout codex A=fail B=pass C=pass
CASE p2-granite-cli.heldout claude A=fail B=fail C=fail
CASE p2-maple-ledger codex A=fail B=pass C=fail
CASE p2-maple-ledger claude A=fail B=fail C=fail
CASE p2-pine-forge codex A=fail B=pass C=fail
CASE p2-pine-forge claude A=fail B=fail C=fail
CASE p2-willow-ops codex A=fail B=pass C=fail
CASE p2-willow-ops claude A=fail B=fail C=fail
CANDIDATE repo-boot-order VERDICT DISCARD
HELDOUT_GAIN 0
```

**Discard reason:** the keep rule requires the +2 visible margin on both harnesses.
Codex visible A=0 B=4 with `loaded=yes` on every B pass, and both held-out cases flipped fail-to-pass.
Claude visible A=0 B=0 with `loaded=no` on every case; haiku `-p` never loaded the project skill (symlink install and a real `.claude/skills` copy both failed).
Visible arm C was not run (empty always-on rule, C would match B); held-out C matched B on each harness.

### Bench fixes this iteration

- Held-out case ids now keep a `.heldout` suffix so `score` does not treat them as visible.
- PATH shims log to `repo/calls.log` inside the sandbox workdir; logging beside the run dir is `Operation not permitted` under Codex `workspace-write`.
- `score` now filters keep-margin counts by harness (`$3==h`). Without that filter a Codex-only win was reported as KEEP.
- Harness subprocesses take stdin from `/dev/null` so Codex does not wait for extra prompt text.

## Iteration 5: Claude project-skill isolation and plateau

P2's rejection named a separable half: Claude never auto-loaded the skill.
Transcripts from iteration 4 showed `repo-boot-order` in a `skill_listing` among dozens of user and plugin skills, then a `Write` of `build-state.txt` with no Skill tool call.
Loaded-detection also missed Claude's project dir because it replaced `/` but not `.`, so `.bench` did not match the encoded `--bench` path.

### Bench changes

- Claude runs now pass `--setting-sources project` so user and plugin skills are not loaded, and `--dangerously-skip-permissions` so the skipped user allowlist does not block writes.
- Skill install matches the spec: `.agents/skills/<name>/SKILL.md` plus `.claude/skills` as a symlink to `../.agents/skills`.
- Claude loaded-detection encodes cwd with `tr '/.' '-'` and treats a Skill tool_use or a `SKILL.md` body read as a load, not a `skill_listing`.
- `loads --harness claude` uses that detector.
- Self-test proves the encoded project dir and that a listing-only transcript is not an invoke.

Commit gate was green: bench self-test, fast lint, doc-audience check (112 surfaces), coverage check (244 tests).

### Probes (2 Claude arm B runs on `p2-ember-kit`)

Probe 1 with the original candidate: skill listing shrank to `repo-boot-order` plus bundled `dataviz`.
Haiku still used `Write` and `loaded=no`.

Probe 2 with a rewritten description ("Whenever the task will write a file or run a command in a repository...") that lint accepted.
The new description appeared in the listing.
Haiku still used `Write` on `build-state.txt`, never invoked Skill, and never called `fm-session-start`.

No full candidate re-score.
heldout_gain stays 0.
Remaining scriptable patterns P3 and P4 have miner count 0 and would hit the same Claude non-invoke wall on these file-write cases.

`stop: plateau` after four iterations with no KEEP.

## Paths written outside the worktree

- `/Users/pedromuller/dev/firstmate/.git/info/exclude` (added `.bench/` exclusion line in an earlier iteration).
- Live harness session logs under `~/.codex/sessions` and `~/.claude/projects` from bench runs, including this iteration's two Claude probes.
- `~/.claude/.stop-slop-ack` (GitHub posting stamp for the draft PR).
- No candidate was copied to `~/.agents/skill-candidates/` (none kept).

Draft PR: https://github.com/pedromuller-del/firstmate/pull/150

```text
$ git diff --stat d28278d7 -- AGENTS.md .agents/skills skills tests/lib.sh bin/fm-test-run.sh

```

```text
$ bash bin/fm-skill-bench.sh budget
runs_used: 76/240 (iteration 2/40)
bench_tokens: 0/0
```

The bench proves skill trigger and behaviour change on scripted tasks with PATH shims and live harness rollouts only; it does not prove fleet delivery outcomes.

DONE
