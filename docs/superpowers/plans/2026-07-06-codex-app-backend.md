# Codex App Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a first-pass `codex-app` runtime backend so Firstmate can spawn, send to, read, supervise, and archive Codex Desktop threads without tmux.

**Architecture:** Firstmate shell scripts route backend operations through `bin/backends/codex-app.sh`.
That adapter calls a stable Node bridge at `bin/fm-codex-bridge`, and the bridge owns the experimental Codex app-server newline JSON protocol.
Ship and scout spawns create an isolated git worktree in the supervising shell before the Codex thread is started.

**Tech Stack:** Bash, Node.js, git worktrees, Codex app-server stdio, existing Firstmate shell tests.

---

### Task 1: Bridge CLI

**Files:**
- Create: `bin/fm-codex-bridge`
- Test: `tests/fm-backend-codex-app.test.sh`

- [x] **Step 1: Write the failing bridge test**

Add a fake `codex` executable that logs app-server requests and returns newline JSON responses for `initialize`, `thread/start`, `turn/start`, `thread/read`, `thread/turns/list`, `thread/list`, and `thread/archive`.
Assert that `bin/fm-codex-bridge start-thread --cwd "$wt" --name fm-task --goal "$goal" --prompt-file "$prompt"` prints JSON containing `thread_id`, `cwd`, and the raw response.

Run: `bash tests/fm-backend-codex-app.test.sh`
Expected: FAIL because `bin/fm-codex-bridge` does not exist.

- [x] **Step 2: Implement the bridge**

Create an executable Node script with verbs `ensure-running`, `start-thread`, `send-turn`, `read-thread`, `thread-status`, `turns-list`, `archive-thread`, and `list-live`.
Use `codex app-server --listen stdio://`, send `initialize` first, then send bare newline JSON request objects with `id`, `method`, and `params`.
For turns, send `input: [{type:"text", text}]`, `cwd`, optional `model`, optional `effort`, `approvalPolicy:"never"`, `approvalsReviewer:"user"`, and `sandboxPolicy:{type:"dangerFullAccess"}`.
For `start-thread`, start an empty thread, set the name and goal when present, then start the first turn with the prompt file.

- [x] **Step 3: Verify the bridge test passes**

Run: `bash tests/fm-backend-codex-app.test.sh`
Expected: PASS for bridge request routing and response normalization.

### Task 2: Backend Adapter

**Files:**
- Create: `bin/backends/codex-app.sh`
- Modify: `bin/fm-backend.sh`
- Test: `tests/fm-backend-codex-app.test.sh`

- [x] **Step 1: Write failing adapter tests**

Assert `fm_backend_validate codex-app` succeeds, `fm_backend_validate_spawn codex-app` succeeds, `fm_backend_capture codex-app thread-1 5` calls bridge `turns-list`, `fm_backend_send_text_submit codex-app thread-1 "hello" ...` calls bridge `send-turn`, `fm_backend_busy_state codex-app thread-1` maps `active` to `busy`, and `fm_backend_target_exists codex-app thread-1` succeeds when bridge `thread-status` returns a known status.

Run: `bash tests/fm-backend-codex-app.test.sh`
Expected: FAIL because `codex-app` is unknown.

- [x] **Step 2: Register and dispatch the adapter**

Add `codex-app` to `FM_BACKEND_KNOWN` and `FM_BACKEND_SPAWN`.
Source `bin/backends/codex-app.sh` in `fm_backend_source`.
Add `codex-app` arms for capture, send text, kill, busy state, composer state, and target existence.

- [x] **Step 3: Implement adapter functions**

Implement adapter functions as thin bridge wrappers.
Keep bridge location configurable with `FM_CODEX_BRIDGE`.
Return `empty` from send when bridge accepts the turn, because there is no terminal composer to verify.
Render bounded capture from bridge `turns-list` summaries.

- [x] **Step 4: Verify adapter tests pass**

Run: `bash tests/fm-backend-codex-app.test.sh`
Expected: PASS for bridge-backed generic backend dispatch.

### Task 3: Spawn Flow

**Files:**
- Modify: `bin/fm-spawn.sh`
- Test: `tests/fm-spawn-codex-app.test.sh`

- [x] **Step 1: Write failing spawn tests**

Build a temporary project repo and a fake bridge.
Assert `fm-spawn.sh codex-task projects/app codex --backend codex-app` creates a git worktree, calls bridge `ensure-running`, calls bridge `start-thread`, writes `backend=codex-app`, `thread_id=`, `codex_cwd=`, `worktree_provider=git-worktree`, and `window=<thread-id>`, and prints a normal spawned summary.
Assert `fm-spawn.sh sm --secondmate --backend codex-app` refuses.
Assert spawn refuses when bridge returns `cwd` equal to the project checkout.
Assert spawn refuses when the status file never receives `working: Codex thread started`.

Run: `bash tests/fm-spawn-codex-app.test.sh`
Expected: FAIL because `fm-spawn.sh` has no `codex-app` branch.

- [x] **Step 2: Add shell-side worktree acquisition**

Add helper functions that create a guarded git worktree under `$PROJECTS/.firstmate-worktrees/<id>` from the project checkout.
Record `WORKTREE_PROVIDER=git-worktree`.
Validate the resulting worktree with the existing `validate_spawn_worktree` guard.

- [x] **Step 3: Add `codex-app` spawn branch**

For ship and scout tasks, acquire the worktree before thread creation, build `TASK_TMP`, `STATE_REAL`, `TURNEND`, and the launch prompt, and call bridge `start-thread`.
Do not send shell text into a terminal endpoint.
Record Codex metadata before waiting for the return-channel status line.

- [x] **Step 4: Add return-channel verification**

Append an instruction to the Codex prompt requiring the worker to write `working: Codex thread started` to the absolute status file before substantive work.
Poll the status file briefly.
If the line is missing, fail with a diagnostic that names the thread id and status path.

- [x] **Step 5: Verify spawn tests pass**

Run: `bash tests/fm-spawn-codex-app.test.sh`
Expected: PASS for successful spawn, secondmate refusal, primary-checkout refusal, and missing-return-channel refusal.

### Task 4: Teardown and Worktree Removal

**Files:**
- Modify: `bin/fm-teardown.sh`
- Test: `tests/fm-spawn-codex-app.test.sh`

- [x] **Step 1: Write failing teardown test**

Create a landed codex-app task meta with `worktree_provider=git-worktree`.
Assert teardown archives the thread through bridge `archive-thread`, removes the git worktree with `git worktree remove --force`, and keeps the existing dirty or unlanded refusal behavior.

Run: `bash tests/fm-spawn-codex-app.test.sh`
Expected: FAIL because teardown still assumes treehouse for non-Orca worktrees.

- [x] **Step 2: Implement provider-aware removal**

Read `worktree_provider=` from meta, defaulting to `treehouse` for old non-Orca tasks.
For `git-worktree`, detach and delete the branch as today, remove hook files, and call `git -C "$PROJ" worktree remove --force "$WT"`.
For `treehouse`, keep the existing `teardown_treehouse_return` path.

- [x] **Step 3: Verify teardown tests pass**

Run: `bash tests/fm-spawn-codex-app.test.sh`
Expected: PASS for Codex archive and git-worktree removal.

### Task 5: Bootstrap and Docs

**Files:**
- Modify: `bin/fm-bootstrap.sh`
- Modify: `docs/codex-app-backend.md`
- Modify: `docs/configuration.md`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Test: `tests/fm-bootstrap.test.sh`

- [x] **Step 1: Write failing bootstrap test**

Add a test case where `config/backend` contains `codex-app`.
Assert bootstrap requires `codex`, `node`, `gh`, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, and `lavish-axi`, and skips `tmux` and Treehouse.

Run: `bash tests/fm-bootstrap.test.sh`
Expected: FAIL because bootstrap does not know the backend.

- [x] **Step 2: Implement bootstrap tool detection**

Teach `install_cmd` about `codex`.
When `backend=codex-app`, set the tool list to Codex-oriented tools.

- [x] **Step 3: Update docs**

Mark `docs/codex-app-backend.md` as implemented first pass.
Update runtime backend docs, README backend lists, and AGENTS short pointers without duplicating the design contract.

- [x] **Step 4: Verify docs and bootstrap tests pass**

Run: `bash tests/fm-bootstrap.test.sh`
Expected: PASS for existing bootstrap cases and the new Codex app case.

### Task 6: Validation and PR Gate

**Files:**
- Modify as required by fixes from validation.

- [x] **Step 1: Run focused tests**

Run:
```sh
bash tests/fm-backend-codex-app.test.sh
bash tests/fm-spawn-codex-app.test.sh
bash tests/fm-backend.test.sh
bash tests/fm-spawn-batch.test.sh
bash tests/fm-teardown.test.sh
bash tests/fm-bootstrap.test.sh
```

Expected: PASS.

- [x] **Step 2: Run syntax checks**

Run:
```sh
node --check bin/fm-codex-bridge
bash -n bin/backends/codex-app.sh
bash -n bin/fm-backend.sh
bash -n bin/fm-spawn.sh
bash -n bin/fm-teardown.sh
bash -n bin/fm-bootstrap.sh
```

Expected: PASS.
If `shellcheck` is available, also run `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh`.
Result: PASS for syntax checks and `git diff --check`; `shellcheck` was not installed in the local environment.

- [ ] **Step 3: Commit and push**

Commit the implementation and push `RA/codex-app-backend-design`.

- [ ] **Step 4: Run no-mistakes**

Run `no-mistakes axi run --intent "<approved Codex Desktop native backend intent>"`.
Drive the gate with Codex-owned fixes or approvals only.
Do not use Claude review or auto-review.
