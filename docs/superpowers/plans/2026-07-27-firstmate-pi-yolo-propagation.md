# FirstMate Pi Yolo Propagation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pass the Pi permission-system launcher override only to delegated Pi ship and scout tasks whose project metadata resolves to `yolo=on`.

**Architecture:** `fm-spawn.sh` remains the single owner of launch construction. After project mode resolution and placeholder substitution, it prefixes the final Pi launch command with `PI_PERMISSION_SYSTEM_YOLO=1` only for non-secondmate Pi tasks whose resolved yolo value is on; every other launch remains byte-for-byte unchanged.

**Tech Stack:** Bash, FirstMate's shell behavior-test harness, `@gotgenes/pi-permission-system`.

## Global Constraints

- The affected `rt-ebook` project already resolves to `yolo=on`.
- Only delegated Pi `ship` and `scout` launches receive `PI_PERMISSION_SYSTEM_YOLO=1`.
- Pi tasks with yolo off, non-Pi harnesses, secondmates, and independently launched Pi sessions retain normal permission handling.
- The launcher must not edit global or project Pi permission configuration.
- The permission-system package must preserve explicit deny rules when the override is active.
- An older or absent permission-system package ignores the environment variable and retains normal prompts.

---

### Task 1: Pin conditional launch propagation with regression tests

**Files:**

- Modify: `tests/fm-spawn-dispatch-profile.test.sh`

**Interfaces:**

- Consumes: the existing `make_spawn_case`, `run_spawn`, and launch-log test helpers.
- Produces: behavior coverage for ship, scout, off, non-Pi, and secondmate launch contexts.

- [ ] **Step 1: Add a project-registry helper**

```bash
enable_yolo_project() {
  local home=$1 project=$2
  printf -- '- %s [no-mistakes +yolo] - test project (added 2026-07-27)\n' \
    "$(basename "$project")" > "$home/data/projects.md"
}
```

- [ ] **Step 2: Add the yolo-on Pi ship and scout cases**

For a Pi ship case and a Pi scout case, call `enable_yolo_project "$HOME_DIR" "$PROJ_DIR"` before `run_spawn`.
Assert that the captured launch begins with or contains:

```text
PI_PERMISSION_SYSTEM_YOLO=1 pi
```

Assert that each generated meta file contains `yolo=on`.

- [ ] **Step 3: Add unchanged-context cases**

Extend the existing yolo-off Pi test to assert the override is absent.
Add a yolo-on Codex case and assert the override is absent.
Add a Pi secondmate case and assert both `yolo=off` in metadata and absence of the override.

- [ ] **Step 4: Run the focused test and verify the yolo-on cases fail**

Run:

```bash
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
```

Expected: the new yolo-on Pi assertions FAIL because the launcher does not yet propagate the flag; the unchanged-context assertions pass.

- [ ] **Step 5: Commit the red regression tests**

Do not commit a failing branch.
Keep the red diff uncommitted and continue directly to Task 2.

### Task 2: Prefix only eligible Pi launch commands

**Files:**

- Modify: `bin/fm-spawn.sh`
- Test: `tests/fm-spawn-dispatch-profile.test.sh`

**Interfaces:**

- Consumes: `HARNESS`, `KIND`, and the resolved `YOLO` value already owned by `fm-spawn.sh`.
- Produces: a process-scoped `PI_PERMISSION_SYSTEM_YOLO=1` prefix on the final eligible Pi launch command.

- [ ] **Step 1: Add the minimal conditional after placeholder substitution**

Add this block after the `__OPINPUT__` replacement and before the existing secondmate environment prefix:

```bash
if [ "$HARNESS" = pi ] && [ "$KIND" != secondmate ] && [ "$YOLO" = on ]; then
  LAUNCH="PI_PERMISSION_SYSTEM_YOLO=1 $LAUNCH"
fi
```

The position ensures project mode has already been resolved and keeps the override scoped to the child process.

- [ ] **Step 2: Run the focused regression test**

Run:

```bash
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
```

Expected: all ship, scout, off, non-Pi, and secondmate cases PASS.

- [ ] **Step 3: Run shell syntax and lint checks**

Run:

```bash
bash -n bin/fm-spawn.sh tests/fm-spawn-dispatch-profile.test.sh
bin/fm-lint.sh
```

Expected: both commands PASS.

- [ ] **Step 4: Commit the tested launcher behavior**

```bash
git add bin/fm-spawn.sh tests/fm-spawn-dispatch-profile.test.sh
git commit -m "fix(pi): propagate project yolo to permission system"
```

### Task 3: Document the optional permission-system integration

**Files:**

- Modify: `docs/configuration.md`
- Modify: `docs/documentation-audiences.json`
- Modify: `docs/superpowers/specs/2026-07-27-pi-yolo-permission-propagation-design.md`
- Modify: `docs/superpowers/plans/2026-07-27-firstmate-pi-yolo-propagation.md`

**Interfaces:**

- Consumes: the launcher contract from Task 2 and the package API from the linked `gotgenes/pi-packages` change.
- Produces: an operator explanation of scope, dependency behavior, and safety.

- [ ] **Step 1: Add the Harness support documentation**

Keep the plan and design entries classified as `maintainer-architecture` in `docs/documentation-audiences.json`.
State that a delegated Pi ship or scout on a `+yolo` project receives `PI_PERMISSION_SYSTEM_YOLO=1`.
State that compatible `@gotgenes/pi-permission-system` releases interpret it as a process-only yolo override while preserving explicit deny rules.
State that yolo-off, secondmate, and independently launched Pi sessions are unchanged, and older or absent package versions simply retain their normal prompt behavior.

- [ ] **Step 2: Mark the confirmed design status**

Change the design status from `Approved in conversation; written review pending` to `Confirmed by Gavin on 2026-07-27`.

- [ ] **Step 3: Run documentation and changed-file checks**

Run:

```bash
bin/fm-doc-audience-check.sh
git diff --check
bin/fm-test-run.sh --changed
```

Expected: documentation ownership passes, the diff is clean, and the changed-file-informed test selection passes.

- [ ] **Step 4: Commit the documentation**

```bash
git add docs/configuration.md docs/documentation-audiences.json docs/superpowers/specs/2026-07-27-pi-yolo-permission-propagation-design.md docs/superpowers/plans/2026-07-27-firstmate-pi-yolo-propagation.md
git commit -m "docs(pi): explain scoped yolo permission handling"
```

### Task 4: Verify the integrated behavior and prepare review

**Files:**

- Verify only; no expected source changes.

**Interfaces:**

- Consumes: a reviewable `pi-packages` commit containing `PI_PERMISSION_SYSTEM_YOLO`.
- Produces: local evidence that exact `1` auto-approves asks, explicit denies survive, and FirstMate scopes the environment correctly.

- [ ] **Step 1: Run the complete relevant FirstMate checks**

```bash
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done
bin/fm-lint.sh
bin/fm-test-run.sh --changed
```

Expected: every command PASS.

- [ ] **Step 2: Run the permission-package integration proof**

From the permission-package branch, run its focused composition-root test and full package suite.
The composition-root test must prove the exact environment value rewrites an ask to yolo allow and preserves an explicit deny.

- [ ] **Step 3: Inspect both branch diffs**

```bash
git status --short
git log --oneline origin/main..HEAD
git diff --stat origin/main...HEAD
```

Expected: each branch is clean, contains only its planned commits, and has no unrelated user files.

- [ ] **Step 4: Push and open linked pull requests**

Push each branch without merging.
Open the permission-package pull request first.
Open the FirstMate pull request second and link it to the package pull request, explaining that older package versions retain prompts and normal permission handling.
