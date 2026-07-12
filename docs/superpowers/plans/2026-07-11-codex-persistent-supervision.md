# Codex Persistent Supervision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace gap-prone normal Codex foreground checkpoints with one persistent, safe, singleton supervision daemon that automatically opens a Codex turn for captain-relevant crew events.

**Architecture:** Reuse `fm-supervise-daemon.sh` for both `normal-codex` and `afk` ownership.
Record normal ownership only after daemon startup validates its target, adopt an identity-verified singleton without restart, and retain foreground checkpoints as recovery diagnostics.

**Tech Stack:** POSIX/Bash shell, Herdr and tmux backend adapters, shell-based unit/E2E tests.

## Global Constraints

- Do not delegate implementation or review work.
- Preserve exactly one daemon and one watcher per Firstmate home.
- Never inject into a busy, pending, unreadable, or bare-shell primary pane.
- Never lose or duplicate a durable wake during normal/AFK ownership transfer.
- A failed normal-daemon startup must leave no false `normal-codex` owner.
- A real Herdr callback smoke must prove a status write opens a Codex turn without captain polling.

---

### Task 1: Make normal ownership transactional

**Files:**
- Modify: `tests/fm-daemon.test.sh`
- Modify: `bin/fm-codex-supervise-start.sh`
- Modify: `bin/fm-supervise-daemon.sh`

**Interfaces:**
- Consumes: `fm_supervision_owner_set`, `fm_supervision_owner_get`, daemon singleton lock, `FM_SUPERVISION_MODE=normal-codex`.
- Produces: normal ownership only after target validation and identity-verified adoption.

- [ ] **Step 1: Add the failing startup regression**

Add a test that launches normal Codex supervision against an intentionally unsupported backend and asserts non-zero exit plus an absent `.supervision-owner`:

```sh
home=$(make_home normal-start-failure)
status=0
FM_HOME="$home" FM_SUPERVISOR_BACKEND=unsupported \
  "$ROOT/bin/fm-codex-supervise-start.sh" >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "normal launcher unexpectedly succeeded"
assert_absent "$home/state/.supervision-owner" \
  "failed normal startup left false supervision ownership"
```

- [ ] **Step 2: Verify the regression fails for the expected reason**

Run:

```sh
bash tests/fm-daemon.test.sh
```

Expected: the new assertion fails because the current launcher writes `normal-codex` before the daemon validates its backend/target.

- [ ] **Step 3: Implement the minimal ownership transaction**

Change the launcher so adoption sets `normal-codex` only after verifying the live daemon identity.
For a new daemon, pass the requested mode without writing the owner.
After the daemon acquires its singleton lock and validates backend/target, set `normal-codex` before entering its watcher loop.
On cleanup, clear `normal-codex` only when that remains the current owner and AFK has not taken ownership.

- [ ] **Step 4: Verify targeted tests pass**

Run:

```sh
bash tests/fm-daemon.test.sh
bash tests/fm-wake-queue.test.sh
bash tests/fm-supervision-instructions.test.sh
```

Expected: every test passes, including the new startup regression.

- [ ] **Step 5: Commit the transactional fix**

```sh
git add bin/fm-codex-supervise-start.sh bin/fm-supervise-daemon.sh tests/fm-daemon.test.sh
git commit -m "fix: make Codex supervision ownership transactional"
```

### Task 2: Prove singleton ownership and mode transfer

**Files:**
- Modify if required by failing behavior: `bin/fm-afk-start.sh`
- Modify if required by failing behavior: `bin/fm-supervise-daemon.sh`
- Test: `tests/fm-afk-inject-e2e.test.sh`

**Interfaces:**
- Consumes: the transactional normal launcher from Task 1 and existing AFK enter/exit functions.
- Produces: one daemon PID across normal -> AFK -> normal and exactly one delivered digest per terminal status.

- [ ] **Step 1: Run the existing ownership-transfer E2E as the acceptance test**

```sh
bash tests/fm-afk-inject-e2e.test.sh
```

Expected: Scenarios D and E pass with one normal-mode injection and one uninterrupted normal/AFK ownership transfer.

- [ ] **Step 2: Fix only a reproduced failure**

If the E2E fails, change only the ownership/cleanup boundary identified by its assertion and rerun the single script until green.
Do not add another daemon, watcher, or restart path.

- [ ] **Step 3: Commit only if Task 2 required code changes**

```sh
git add bin/fm-afk-start.sh bin/fm-supervise-daemon.sh tests/fm-afk-inject-e2e.test.sh
git commit -m "fix: preserve Codex supervision across away mode"
```

### Task 3: Run a real Herdr callback smoke

**Files:**
- Modify: `docs/supervision-protocols/codex.md`
- Use: `bin/fm-herdr-lab.sh`

**Interfaces:**
- Consumes: a disposable Herdr lab session, a scratch Firstmate home, a disposable idle Codex primary, and the normal daemon launcher.
- Produces: empirical proof that a separate status write opens a new Codex turn without polling.

- [ ] **Step 1: Create an isolated Herdr lab and scratch home**

Use `bin/fm-herdr-lab.sh` so every Herdr command targets a never-`default` lab session and cleanup cannot affect the captain's live fleet.

- [ ] **Step 2: Start disposable Codex and the normal daemon**

Launch Codex in the lab pane, record its pane target, then run:

```sh
FM_HOME="$scratch_home" \
FM_SUPERVISOR_BACKEND=herdr \
FM_SUPERVISOR_TARGET="$lab_target" \
bin/fm-codex-supervise-start.sh
```

Keep the daemon in its own tracked lab terminal.

- [ ] **Step 3: Trigger the callback from a separate process**

After the disposable Codex primary is confirmed idle, write:

```sh
printf 'done: real Herdr callback smoke\n' > "$scratch_home/state/smoke.status"
```

Do not poll or type into the Codex pane after the write.

- [ ] **Step 4: Verify autonomous delivery and persistence**

Require evidence that Codex started a new turn containing the smoke message, the daemon PID stayed live, `.last-watcher-beat` remained fresh, and the queue contained no undelivered duplicate.

- [ ] **Step 5: Record exact dated evidence**

Update `docs/supervision-protocols/codex.md` with the Herdr version, Codex version, commands, pane/session isolation, exact injected message, and observed result.

- [ ] **Step 6: Commit the empirical verification**

```sh
git add docs/supervision-protocols/codex.md
git commit -m "docs: verify Codex supervision on Herdr"
```

### Task 4: Run the complete validation and ship

**Files:**
- Verify all changed tracked files on the branch.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: a reviewed PR with no uncommitted tracked changes.

- [ ] **Step 1: Run script and regression validation**

```sh
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh
bash tests/fm-wake-queue.test.sh
bash tests/fm-daemon.test.sh
bash tests/fm-watch-checkpoint.test.sh
bash tests/fm-supervision-instructions.test.sh
bash tests/fm-afk-inject-e2e.test.sh
bash tests/fm-afk-inject-herdr-e2e.test.sh
git diff --check origin/main...HEAD
```

Expected: every command exits zero.

- [ ] **Step 2: Run Firstmate's validation pipeline**

Run the repository's configured no-mistakes pipeline on the branch and address substantive findings without delegating.

- [ ] **Step 3: Push and open the PR**

Push `fm/fix-codex-supervision-loop-d4`, open a PR against `main`, and complete the required Copilot loop up to six rounds.
Do not merge without the captain's explicit instruction.
