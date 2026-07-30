# Lean Validation and Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make direct PR delivery with focused local checks and repository CI the ordinary path, while retaining no-mistakes as an explicit high-risk escalation.

**Architecture:** `bin/fm-project-mode.sh` owns the project default, `bin/fm-brief.sh` owns task instructions and the only escalation flag, and `bin/fm-spawn.sh` consumes the resulting task-scoped mode record. GitHub merges gain a deterministic CI preflight in `bin/fm-pr-merge.sh`; GitLab merge requests remain human-merged because Firstmate has no GitLab merge helper. Policy, contribution guidance, and the private project registry are cut over only after the transition PR passes the currently mandatory no-mistakes path.

**Tech Stack:** macOS-compatible Bash 3.2, Markdown, GitHub Actions, `gh`, `gh-axi`, existing shell test harness in `tests/lib.sh`.

## Global Constraints

- Ordinary work uses the smallest focused local check that proves the changed behavior, then relies on repository CI.
- No LLM review, LLM test, documentation, housekeeping, transcript-intent, or repeated auto-fix stage runs for ordinary work.
- Use no-mistakes only when explicitly requested or when a change affects authentication or authorization, tenant isolation or PII or secrets, money or pricing or settlement, database schema or irreversible data migration, production infrastructure or deployment, or destructive or irreversible operations.
- Never merge a red or pending PR.
- If a repository has no CI checks, the merge authority must explicitly attest that the focused local checks were verified.
- Preserve worktree isolation, merge authority, unlanded-work protection, local-only behavior, and destructive-action approval.
- Keep no-mistakes installed and operational; do not remove `.no-mistakes.yaml`, daemon safeguards, or the `no-mistakes` delivery mode.
- Do not add a dependency, daemon, delivery mode, validation framework, compatibility alias, or deprecated path.
- The transition PR itself uses the current no-mistakes path once because the base branch still contains the mandatory `Require no-mistakes` workflow.

## File Map

| File | Responsibility |
| --- | --- |
| `bin/fm-project-mode.sh` | Resolve the registered delivery mode and the ordinary fallback. |
| `bin/fm-brief.sh` | Accept `--no-mistakes`, write the task-scoped escalation record, and generate focused direct-PR instructions. |
| `bin/fm-spawn.sh` | Validate and consume the task-scoped escalation before creating a worker endpoint; record the effective mode. |
| `bin/fm-pr-merge.sh` | Refuse GitHub merges with failed, cancelled, pending, or unknown CI; require explicit no-CI attestation. |
| `tests/fm-project-mode.test.sh` | Cover direct-PR defaults and all explicit registered modes. |
| `tests/fm-brief.test.sh` | Cover the escalation flag and focused direct-PR instructions. |
| `tests/fm-backend-orca.test.sh` | Exercise effective mode propagation through a real spawn path without creating a live terminal. |
| `tests/fm-secondmate-safety.test.sh` | Update the home-isolation expectation for an unregistered project's new direct-PR default. |
| `tests/fm-pr-merge.test.sh` | Cover green, red, pending, unknown, unavailable, and absent CI outcomes. |
| `AGENTS.md` | Own always-loaded task risk selection, evidence floor, and merge rule. |
| `.agents/skills/project-management/SKILL.md` | Own direct-PR as the default for newly added or created projects. |
| `CONTRIBUTING.md` | Describe direct PR contribution flow and optional high-risk no-mistakes use. |
| `.github/workflows/no-mistakes-required.yml` | Remove the obsolete mandatory signature check. |
| `tests/fm-instruction-owners.test.sh` | Pin the new project default and task-risk owner wording. |
| `data/projects.md` | Private post-merge cutover of registered projects; never committed. |

---

### Task 1: Direct-PR Default and Explicit No-Mistakes Escalation

**Files:**
- Create: `tests/fm-project-mode.test.sh`
- Modify: `bin/fm-project-mode.sh:1-66`
- Modify: `bin/fm-brief.sh:1-100,272-379`
- Modify: `bin/fm-spawn.sh:1-81,213-238,597-667,973-1029`
- Modify: `tests/fm-brief.test.sh:39-117,342-355`
- Modify: `tests/fm-backend-orca.test.sh:472-509`
- Modify: `tests/fm-secondmate-safety.test.sh:24-38`

**Interfaces:**
- Produces: `bin/fm-brief.sh <id> <repo> --no-mistakes` for ship tasks only.
- Produces: private record `data/<id>/delivery-mode` containing exactly one line, `no-mistakes`.
- Consumes: `bin/fm-spawn.sh` reads that record before any backend endpoint or worktree is created.
- Preserves: explicit registry values `no-mistakes`, `direct-PR`, and `local-only`, plus orthogonal `+yolo`.
- Rejects: `--no-mistakes` combined with `--scout` or `--secondmate`, a symlinked/non-regular escalation record, extra lines, or any value other than `no-mistakes`.

- [ ] **Step 1: Add failing project-mode behavior tests**

Create `tests/fm-project-mode.test.sh` with the existing `tests/lib.sh` harness and these cases:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"

cat > "$HOME_DIR/data/projects.md" <<'EOF'
- guarded [no-mistakes] - explicit guarded project (added 2026-07-30)
- ordinary [direct-PR] - explicit ordinary project (added 2026-07-30)
- local [local-only +yolo] - local project (added 2026-07-30)
- legacy - unannotated project (added 2026-07-30)
EOF

[ "$(FM_HOME="$HOME_DIR" "$MODE" guarded)" = "no-mistakes off" ] || fail "explicit no-mistakes changed"
[ "$(FM_HOME="$HOME_DIR" "$MODE" ordinary)" = "direct-PR off" ] || fail "explicit direct-PR changed"
[ "$(FM_HOME="$HOME_DIR" "$MODE" local)" = "local-only on" ] || fail "local-only +yolo changed"
[ "$(FM_HOME="$HOME_DIR" "$MODE" legacy)" = "direct-PR off" ] || fail "unannotated project did not default to direct-PR"
[ "$(FM_HOME="$HOME_DIR" "$MODE" missing 2>/dev/null)" = "direct-PR off" ] || fail "missing project did not default to direct-PR"

rm "$HOME_DIR/data/projects.md"
[ "$(FM_HOME="$HOME_DIR" "$MODE" missing 2>/dev/null)" = "direct-PR off" ] || fail "missing registry did not default to direct-PR"
pass "project delivery modes retain explicit values and default ordinary work to direct-PR"
```

- [ ] **Step 2: Add failing brief escalation tests**

Extend `tests/fm-brief.test.sh` with a `no-mistakes` fixture and these assertions:

```bash
cat >> "$home/data/projects.md" <<'EOF'
- guarded-proj [no-mistakes] - fixture for no-mistakes mode (added 2026-07-30)
EOF

FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-default ordinary-missing >/dev/null
assert_grep "ships **direct-PR**" "$home/data/brief-default/brief.md" "missing project did not use direct-PR"

FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-escalated direct-proj --no-mistakes >/dev/null
assert_grep "^no-mistakes$" "$home/data/brief-escalated/delivery-mode" "escalation record is wrong"
assert_grep "no-mistakes itself provides" "$home/data/brief-escalated/brief.md" "escalated brief did not use no-mistakes"

for forbidden in "--scout" "--secondmate --no-projects"; do
  set +e
  # shellcheck disable=SC2086
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x "$ROOT/bin/fm-brief.sh" "brief-reject-${forbidden%% *}" direct-proj --no-mistakes $forbidden >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "--no-mistakes must be ship-only"
done
```

Update the existing no-mistakes wording test to use `guarded-proj` or `--no-mistakes`; it must no longer rely on an absent project selecting no-mistakes.

- [ ] **Step 3: Add failing spawn propagation coverage**

Extend `test_spawn_writes_orca_metadata_and_launches_harness` in `tests/fm-backend-orca.test.sh` to expect `mode=direct-PR` when no registry entry or escalation exists. Add a sibling fake-Orca case that writes `data/<id>/delivery-mode` with `no-mistakes`, spawns the same way, and asserts both stdout and `state/<id>.meta` contain `mode=no-mistakes`.

Add invalid-record cases that stop before the first Orca call:

```bash
printf 'local-only\n' > "$data/$id/delivery-mode"
# Expect non-zero, an "invalid task delivery-mode override" error, and an empty Orca request log.

rm "$data/$id/delivery-mode"
ln -s "$TMP_ROOT/elsewhere" "$data/$id/delivery-mode"
# Expect the same refusal before backend mutation.
```

Update `tests/fm-secondmate-safety.test.sh` so a project absent from one home's registry expects `direct-PR off`, while the explicitly registered `local-only on` case remains unchanged.

- [ ] **Step 4: Run the focused tests and confirm they fail**

Run:

```bash
bash tests/fm-project-mode.test.sh
bash tests/fm-brief.test.sh
bash tests/fm-backend-orca.test.sh
bash tests/fm-secondmate-safety.test.sh
```

Expected: failures identify the old `no-mistakes` fallback, missing `--no-mistakes` parser, missing escalation record, and old spawn metadata.

- [ ] **Step 5: Implement the direct-PR fallback**

In `bin/fm-project-mode.sh`, change only the ordinary defaults:

```bash
# Registry parse default for an unannotated line.
mode="direct-PR"; yolo="off";

# Missing registry or absent project.
echo "direct-PR off"

# Unknown explicit mode remains visible but falls back to the ordinary path.
echo "warn: unknown mode \"$mode\" for $NAME; defaulting to direct-PR off" >&2
mode=direct-PR
yolo=off
```

Update the header to describe `direct-PR` as the default and `no-mistakes` as an explicit project posture.

- [ ] **Step 6: Implement the task-scoped escalation in brief generation**

In `bin/fm-brief.sh`, add parser state and strict misuse checks:

```bash
NO_MISTAKES=0

# parser case
--no-mistakes) NO_MISTAKES=1 ;;

if [ "$NO_MISTAKES" -eq 1 ] && [ "$KIND" != ship ]; then
  echo "error: --no-mistakes applies only to ship briefs" >&2
  exit 1
fi

MODE_OVERRIDE="$DATA/$ID/delivery-mode"
if [ -e "$MODE_OVERRIDE" ] || [ -L "$MODE_OVERRIDE" ]; then
  echo "error: task delivery-mode override already exists: $MODE_OVERRIDE" >&2
  exit 1
fi
```

After the brief overwrite check and task directory creation, record only the one allowed escalation:

```bash
if [ "$NO_MISTAKES" -eq 1 ]; then
  old_umask=$(umask)
  umask 077
  printf '%s\n' no-mistakes > "$MODE_OVERRIDE"
  umask "$old_umask"
fi
```

Resolve the effective ship mode as:

```bash
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF
[ "$NO_MISTAKES" -eq 0 ] || MODE=no-mistakes
```

Do not add `--direct-PR`, `--mode`, or an environment override.

- [ ] **Step 7: Consume the escalation before spawn mutation**

Move effective mode resolution in `bin/fm-spawn.sh` to immediately after project and brief resolution, before `W=` and backend creation. Validate the record without following symlinks:

```bash
if [ "$KIND" = secondmate ]; then
  MODE=secondmate
  YOLO=off
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$PROJ_NAME")
EOF

  MODE_OVERRIDE="$DATA/$ID/delivery-mode"
  if [ -e "$MODE_OVERRIDE" ] || [ -L "$MODE_OVERRIDE" ]; then
    [ "$KIND" = ship ] && [ -f "$MODE_OVERRIDE" ] && [ ! -L "$MODE_OVERRIDE" ] || {
      echo "error: invalid task delivery-mode override" >&2
      exit 1
    }
    override=$(cat "$MODE_OVERRIDE") || exit 1
    [ "$override" = no-mistakes ] && [ "$(wc -l < "$MODE_OVERRIDE" | tr -d ' ')" -eq 1 ] || {
      echo "error: invalid task delivery-mode override" >&2
      exit 1
    }
    MODE=no-mistakes
  fi
fi
```

Remove the later duplicate mode resolution. Change the Orca abort-cleanup metadata fallback from `${MODE:-no-mistakes}` to `${MODE:-direct-PR}`.

- [ ] **Step 8: Run focused tests and syntax checks**

Run:

```bash
bash -n bin/fm-project-mode.sh bin/fm-brief.sh bin/fm-spawn.sh
bash tests/fm-project-mode.test.sh
bash tests/fm-brief.test.sh
bash tests/fm-backend-orca.test.sh
bash tests/fm-secondmate-safety.test.sh
```

Expected: all pass; no real worker endpoint or project worktree is created.

- [ ] **Step 9: Commit the mode-selection change**

```bash
git add bin/fm-project-mode.sh bin/fm-brief.sh bin/fm-spawn.sh \
  tests/fm-project-mode.test.sh tests/fm-brief.test.sh \
  tests/fm-backend-orca.test.sh tests/fm-secondmate-safety.test.sh
git commit -m "feat: make direct PR the default delivery path"
```

---

### Task 2: Focused Evidence in Direct-PR Briefs

**Files:**
- Modify: `bin/fm-brief.sh:278-289,329-377`
- Modify: `tests/fm-brief.test.sh:74-117,342-355`

**Interfaces:**
- Produces: a `# Focused validation` section only in direct-PR ship briefs.
- Produces: provider-aware PR/MR creation instructions for GitHub and GitLab remotes.
- Preserves: no-mistakes and local-only brief bodies unchanged.
- Requires: exact validation commands and outcomes in the PR/MR body under `## Validation`.

- [ ] **Step 1: Add failing direct-PR evidence assertions**

Add a test that scaffolds a direct-PR brief and checks for all five selection rules, provider handling, and absence of LLM stages:

```bash
assert_grep "Bug fix.*reproduce" "$brief" "bug-fix proof rule missing"
assert_grep "Feature.*nearest existing tests" "$brief" "feature proof rule missing"
assert_grep "Refactor.*preserved behavior" "$brief" "refactor proof rule missing"
assert_grep "Documentation.*render" "$brief" "documentation proof rule missing"
assert_grep "Configuration.*parse or load" "$brief" "configuration proof rule missing"
assert_grep "## Validation" "$brief" "PR evidence section missing"
assert_grep "github.com" "$brief" "GitHub PR route missing"
assert_grep "gitlab" "$brief" "GitLab MR route missing"
assert_no_grep "LLM review" "$brief" "direct-PR brief added an LLM review"
assert_grep "Do not run a whole-repository local suite for a narrow change" "$brief" "direct-PR brief did not prohibit a broad local suite"
```

Also assert the no-mistakes and local-only fixtures do not receive the direct-PR section.

- [ ] **Step 2: Run the focused brief test and confirm failure**

Run:

```bash
bash tests/fm-brief.test.sh
```

Expected: the new focused-validation assertions fail against the current three-line direct-PR definition of done.

- [ ] **Step 3: Add the focused validation matrix**

Generate this direct-PR-only section in `bin/fm-brief.sh`:

```markdown
# Focused validation
Before committing, choose the smallest check that proves the changed behavior:
- Bug fix - reproduce the affected user path, apply the fix, and rerun the same reproduction.
- Feature - run the nearest existing tests and exercise the changed UI, command, or API path.
- Refactor - run the nearest existing tests that cover the preserved behavior.
- Documentation - render, generate, or open the affected artifact when applicable; otherwise inspect the exact changed document.
- Configuration - parse or load the configuration and exercise the affected command.
Add or update a test only when the change introduces an observable contract not already covered or fixes a regression that needs permanent coverage.
Run lint only when an existing lint command covers the changed files.
Do not run a whole-repository local suite for a narrow change; repository CI owns the broad final result.
Record the exact commands and outcomes in the PR or MR body under `## Validation`.
```

- [ ] **Step 4: Make PR creation provider-aware**

Replace the unconditional `gh-axi` instruction in the direct-PR definition of done with:

```markdown
Inspect `git remote get-url origin` before publishing.
- For a GitHub origin, push the generated `fm/$ID` branch and open the PR with `gh-axi`.
- For a GitLab origin, resolve the target from `refs/remotes/origin/HEAD`, push the generated branch with GitLab's `merge_request.create` and `merge_request.target=$target` push options, and capture the MR URL printed by GitLab.
- For any other host, or when the default target cannot be resolved, append `blocked: authenticated PR creation path is not configured for this remote` and stop.
Never invent credentials, guess a target branch, or merge the PR/MR.
```

The unquoted direct-PR heredoc in `fm-brief.sh` must interpolate `$ID` and `$STATUS_FILE` at scaffold time while escaping the worker-time `target` substitutions:

```bash
target=\$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
target=\${target#origin/}
[ -n "\$target" ] || { echo "blocked: cannot resolve origin default branch" >> $STATUS_FILE; exit 1; }
git push -u origin "fm/$ID" -o merge_request.create -o "merge_request.target=\$target"
```

Keep the global rule recommending `gh-axi` for GitHub operations; the direct-PR definition owns the GitLab exception.

- [ ] **Step 5: Run the brief behavior test**

Run:

```bash
bash -n bin/fm-brief.sh
bash tests/fm-brief.test.sh
```

Expected: all brief modes render cleanly; only direct-PR includes focused validation and provider-aware publishing.

- [ ] **Step 6: Commit the direct-PR evidence contract**

```bash
git add bin/fm-brief.sh tests/fm-brief.test.sh
git commit -m "feat: require focused evidence for direct PRs"
```

---

### Task 3: GitHub CI Merge Preflight

**Files:**
- Modify: `bin/fm-pr-merge.sh:1-80`
- Modify: `tests/fm-pr-merge.test.sh:1-314`

**Interfaces:**
- Produces: `fm-pr-merge.sh <id> <url> [--no-ci-verified] [-- <gh-axi merge args>]`.
- Consumes: `gh pr view <url> --json statusCheckRollup --jq <normalizer>`.
- Passes: every reported check is `SUCCESS`, `SKIPPED`, or `NEUTRAL`.
- Refuses: `FAILURE`, `ERROR`, `CANCELLED`, `TIMED_OUT`, `ACTION_REQUIRED`, `STALE`, `STARTUP_FAILURE`, pending states, unknown states, or an unavailable CI lookup.
- No-CI behavior: zero reported checks requires the explicit `--no-ci-verified` attestation.
- Preserves: URL validation, metadata recording, merge method defaults, repository override refusal, and `gh-axi` merge execution.

- [ ] **Step 1: Extend the merge test matrix**

Change the fake `gh` helper so `pr view` returns the head SHA for `headRefOid` requests and a configurable normalized state list for `statusCheckRollup` requests:

```bash
case " $* " in
  *headRefOid*) printf '%s\n' "$FM_TEST_HEAD" ;;
  *statusCheckRollup*) printf '%s\n' "${FM_TEST_CHECK_STATES:-SUCCESS}" ;;
esac
```

Add tests that prove:

```text
SUCCESS + SKIPPED + NEUTRAL -> merge invoked
FAILURE -> exit 1, merge not invoked
IN_PROGRESS -> exit 1, merge not invoked
CANCELLED -> exit 1, merge not invoked
unrecognized state -> exit 1, merge not invoked
CI lookup command failure -> exit 1, merge not invoked
empty state list without --no-ci-verified -> exit 1, merge not invoked
empty state list with --no-ci-verified -> merge invoked
```

Each refusal must assert the specific stderr reason and that `gh-axi.log` contains no `pr merge` line.

- [ ] **Step 2: Run the merge test and confirm failure**

Run:

```bash
bash tests/fm-pr-merge.test.sh
```

Expected: red, pending, and no-CI tests show that the current script reaches `gh-axi pr merge` without a CI preflight.

- [ ] **Step 3: Parse the no-CI attestation flag**

Before forwarding extra merge arguments:

```bash
NO_CI_VERIFIED=0
if [ "${1:-}" = --no-ci-verified ]; then
  NO_CI_VERIFIED=1
  shift
fi
[ "${1:-}" = -- ] && shift
```

Reject `--no-ci-verified` if it appears inside the forwarded argument list so it can never leak into `gh-axi`.

- [ ] **Step 4: Add the CI state normalizer and refusal**

After `fm-pr-check.sh` records the PR identity and before building merge args:

```bash
if ! check_states=$(gh pr view "$URL" --json statusCheckRollup --jq '
  .statusCheckRollup[] |
  if .__typename == "CheckRun" then (.conclusion // .status // "")
  else (.state // "") end
'); then
  echo "error: cannot verify PR CI status" >&2
  exit 1
fi

if [ -z "$check_states" ]; then
  [ "$NO_CI_VERIFIED" -eq 1 ] || {
    echo "error: PR reports no CI checks; verify focused local checks and rerun with --no-ci-verified" >&2
    exit 1
  }
else
  while IFS= read -r check_state; do
    case "$check_state" in
      SUCCESS|SKIPPED|NEUTRAL) ;;
      '') echo "error: PR CI returned an empty state" >&2; exit 1 ;;
      *) echo "error: PR CI is not green: $check_state" >&2; exit 1 ;;
    esac
  done <<EOF
$check_states
EOF
fi
```

Do not add watch mode or polling. This check is a single pre-merge snapshot; the provider remains the source of truth.

- [ ] **Step 5: Run merge tests and syntax checks**

Run:

```bash
bash -n bin/fm-pr-merge.sh
bash tests/fm-pr-merge.test.sh
```

Expected: all existing argument and metadata cases still pass, green CI merges, and every unsafe CI outcome refuses before `gh-axi pr merge`.

- [ ] **Step 6: Commit the CI preflight**

```bash
git add bin/fm-pr-merge.sh tests/fm-pr-merge.test.sh
git commit -m "feat: refuse merges without green CI"
```

---

### Task 4: Policy and Contribution Cutover

**Files:**
- Modify: `AGENTS.md:43,61-64,290-305,310-328`
- Modify: `.agents/skills/project-management/SKILL.md:25-60`
- Modify: `CONTRIBUTING.md:1-31,57-73`
- Remove: `.github/workflows/no-mistakes-required.yml`
- Modify: `tests/fm-instruction-owners.test.sh:62-77`

**Interfaces:**
- Produces: one always-loaded risk selection rule in `AGENTS.md`.
- Produces: direct-PR as the new-project default in `project-management`.
- Preserves: no-mistakes as an available mode, its initialization procedure, and its internal gate ownership when selected.
- Removes: only the mandatory PR-body signature workflow, not repository CI.

- [ ] **Step 1: Add failing instruction-owner assertions**

Update `tests/fm-instruction-owners.test.sh` to require the owner skill to say:

```bash
assert_grep '`direct-PR` is the default' "$PROJECT" "new projects do not default to direct-PR"
assert_grep 'explicit project posture' "$PROJECT" "no-mistakes is not documented as opt-in"
```

Add assertions that `AGENTS.md` contains the exact high-risk categories and the `--no-mistakes` task override, and no longer contains:

```text
Ship shared tracked changes through this repo's no-mistakes pipeline
```

- [ ] **Step 2: Run the instruction test and confirm failure**

Run:

```bash
bash tests/fm-instruction-owners.test.sh
```

Expected: the direct-PR default and risk-tier ownership assertions fail against the current policy.

- [ ] **Step 3: Update the always-loaded task policy**

In `AGENTS.md`:

1. Replace the shared-tracked mandatory no-mistakes sentence with direct PR plus the same risk-tier exception used for project work.
2. Replace “Add or update automated tests for every functional change” with the approved focused rule: use existing coverage first, add or update a test when a new observable contract is not covered or a bug needs permanent regression coverage.
3. In “Selected delivery path and approval authority,” state that direct-PR is ordinary, `fm-brief.sh --no-mistakes` is the only per-task escalation, and list all six high-risk categories verbatim from Global Constraints.
4. Preserve the rule that no-mistakes owns review, fixes, tests, documentation, push, PR, and CI once selected.
5. State that direct-PR readiness includes the PR URL and exact focused validation evidence; repository CI is checked at merge time.
6. State that GitLab MRs are surfaced for captain merge because the guarded Firstmate merge helper currently accepts canonical GitHub PR URLs only.
7. Preserve explicit merge authority, `+yolo`, no-red-PR, and full-URL reporting rules.

Keep each sentence on its own line and use plain hyphens.

- [ ] **Step 4: Update the project-management owner**

Change only project defaults and initialization triggers:

```markdown
- `direct-PR` pushes and opens a PR without the no-mistakes pipeline and is the default when the captain does not specify a mode.
- `no-mistakes` runs the full validation pipeline before a PR and is an explicit project posture; a direct-PR project can still escalate one high-risk task through `fm-brief.sh --no-mistakes`.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.
```

For remote creation, default visibility to private and delivery mode to `direct-PR`. Keep `no-mistakes init && no-mistakes doctor` only for projects explicitly registered as `no-mistakes`.

- [ ] **Step 5: Rewrite contribution guidance and remove the obsolete workflow**

Make `CONTRIBUTING.md` describe this ordinary path:

```markdown
1. Create a feature branch.
2. Make the smallest complete change.
3. Run the focused check that proves the changed behavior.
4. Record the command and outcome under `## Validation` in the PR body.
5. Push the branch and open the PR.
6. Wait for repository CI and do not merge red or pending checks.
```

Keep a concise optional no-mistakes section for explicit high-risk work, linked to its current quick start. Keep the existing repository lint and test commands as available checks, but do not instruct every narrow change to run the whole local behavior suite.

Remove `.github/workflows/no-mistakes-required.yml`. Do not alter `.github/workflows/ci.yml`. The active GitHub ruleset inspected on 2026-07-30 requires pull requests and squash/linear history but does not name the no-mistakes status check, so no repository-setting migration is required.

- [ ] **Step 6: Run focused policy checks**

Run:

```bash
bash tests/fm-instruction-owners.test.sh
! grep -R "PR must be raised via no-mistakes" AGENTS.md CONTRIBUTING.md .github/workflows
! grep -R "Ship shared tracked changes through this repo's no-mistakes pipeline" AGENTS.md
[ ! -e .github/workflows/no-mistakes-required.yml ]
[ -e .github/workflows/ci.yml ]
```

Expected: the instruction test passes, mandatory wording is absent, the signature workflow is gone, and ordinary CI remains.

- [ ] **Step 7: Run the repository lint owner**

Run:

```bash
bin/fm-lint.sh
```

Expected: PASS using the repository-pinned ShellCheck version.

- [ ] **Step 8: Commit the policy cutover**

```bash
git add AGENTS.md .agents/skills/project-management/SKILL.md CONTRIBUTING.md \
  tests/fm-instruction-owners.test.sh .github/workflows/no-mistakes-required.yml
git commit -m "docs: make focused direct PR delivery standard"
```

- [ ] **Step 9: Ship the transition through the current gate once**

Use the current no-mistakes workflow because the base branch still mandates its signature. Run the installed version's guidance and live `axi` commands through CI-ready completion. Do not bypass the existing check or merge a red transition PR.

Expected PR evidence:

```text
- fm-project-mode, fm-brief, spawn-mode, and PR-merge focused tests pass
- bin/fm-lint.sh passes
- GitHub CI is green
- The PR removes Require no-mistakes and retains CI
```

Stop at the configured merge authority. Do not perform Task 5 before the transition PR is merged.

---

### Task 5: Private Fleet Cutover and End-to-End Smoke

**Files:**
- Modify after merge, never commit: `data/projects.md`
- Temporary smoke artifacts only: a directory created by `mktemp -d` and removed after the check.

**Interfaces:**
- Consumes: merged `bin/fm-project-mode.sh`, `bin/fm-brief.sh`, and `bin/fm-spawn.sh` behavior from Tasks 1-4.
- Produces: all currently registered PR projects resolve to `direct-PR`; `teklab-website-redesign` remains `local-only`.
- Preserves: project descriptions, dates, `+yolo`, registry order, and every non-mode field.

- [ ] **Step 1: Confirm the transition PR is merged and refresh the local copy**

Use the guarded Firstmate merge and sync paths. Confirm the local default branch contains the commits from Tasks 1-4 before editing private state.

- [ ] **Step 2: Update only delivery-mode brackets in `data/projects.md`**

Apply these exact mode changes while preserving every description and date:

```text
salestrack     no-mistakes -> direct-PR
synapses       no-mistakes -> direct-PR
pitakotuwa     no-mistakes -> direct-PR
ndsrc          no-mistakes -> direct-PR
wholesale-hub  no-mistakes -> direct-PR
```

Leave:

```text
teklab-website-redesign [local-only]
```

Do not commit `data/projects.md`; it is captain-private and gitignored.

- [ ] **Step 3: Verify registry resolution**

Run:

```bash
for project in salestrack synapses pitakotuwa ndsrc wholesale-hub; do
  result=$(bin/fm-project-mode.sh "$project")
  [ "$result" = "direct-PR off" ] || { echo "$project: $result"; exit 1; }
done
[ "$(bin/fm-project-mode.sh teklab-website-redesign)" = "local-only off" ]
```

Expected: five `direct-PR off` results and one `local-only off` result.

- [ ] **Step 4: Smoke-test ordinary and escalated brief generation**

Run in a disposable home:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/data" "$tmp/state"
cat > "$tmp/data/projects.md" <<'EOF'
- ordinary [direct-PR] - smoke fixture (added 2026-07-30)
EOF

FM_HOME="$tmp" bin/fm-brief.sh smoke-ordinary ordinary >/dev/null
FM_HOME="$tmp" bin/fm-brief.sh smoke-guarded ordinary --no-mistakes >/dev/null

grep -F "ships **direct-PR**" "$tmp/data/smoke-ordinary/brief.md"
grep -F "# Focused validation" "$tmp/data/smoke-ordinary/brief.md"
[ ! -e "$tmp/data/smoke-ordinary/delivery-mode" ]
grep -qxF "no-mistakes" "$tmp/data/smoke-guarded/delivery-mode"
grep -F "no-mistakes itself provides" "$tmp/data/smoke-guarded/brief.md"
```

Expected: ordinary work has focused direct-PR instructions and no override record; escalated work has one validated no-mistakes record and the unchanged no-mistakes instructions.

- [ ] **Step 5: Verify the changed contracts together**

Run only the focused local suite:

```bash
bash tests/fm-project-mode.test.sh
bash tests/fm-brief.test.sh
bash tests/fm-backend-orca.test.sh
bash tests/fm-secondmate-safety.test.sh
bash tests/fm-pr-merge.test.sh
bash tests/fm-instruction-owners.test.sh
bin/fm-lint.sh
```

Expected: all pass. The merged GitHub CI result remains the broad final suite.

- [ ] **Step 6: Record the operational outcome**

Record that the five registered PR projects now use focused direct-PR delivery, high-risk tasks use `fm-brief.sh --no-mistakes`, GitHub merges refuse unsafe CI, GitLab MRs remain captain-merged, and the old mandatory signature workflow is removed. No commit is created for this private-state step.
