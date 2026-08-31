# Quarterdeck (Structural Verifier Stage) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Superseded in part (2026-08-31).** Task 4's verifier prompt below still carries
> "run: bash gates/verify.sh - every gate must be green; red or unproven gates are an
> automatic reject", which is unsatisfiable in any repo holding a declared red and is
> no longer what ships. Gate adjudication left the prompt entirely: it is now a
> structural stage in `bin/fm-verify.sh` that runs ahead of both models against
> `fm_gates_classify` (`bin/fm-gates-lib.sh`), and the shipped prompt states no gate
> rule at all. See the *Gate adjudication* amendment in
> `docs/specs/2026-07-01-agent-os-council.md`. The rest of this plan is as built.

**Goal:** Make `done:` a claim, not an acceptance — an independent default-REJECT verifier (with a Fugu→codex→none foreign lens) must approve before firstmate can merge or arm a PR poll.

**Architecture:** A new `bin/fm-verify.sh` runs on a ship task's `done:`; it records evidence in `data/<id>/` and appends decisions to an append-only `state/<id>.verdict` file via a shared `bin/fm-verdict-lib.sh`. `fm-merge-local.sh` and `fm-pr-check.sh` gain a hard gate: refuse unless the last decision line is `approve:`. Rejects round-trip to the crewmate with an attempt cap of 3, then escalate. All external calls (verifier, lens, relay) sit behind env seams so every test runs offline.

**Tech Stack:** bash (`set -eu`), the existing `tests/lib.sh` harness, the global `ledger` CLI (Frozen Gate Ledger), python3 stdlib + curl for the Fugu lens only.

**Spec:** `docs/specs/2026-07-01-agent-os-council.md` (Phase 1 section). Repo: `/Users/stoneevenson/firstmate` (work there, not in a project checkout).

## Global Constraints

- Every script: `#!/usr/bin/env bash` + `set -eu`, header comment explaining the contract, `FM_ROOT_OVERRIDE`/`FM_STATE_OVERRIDE`/`FM_DATA_OVERRIDE` honored exactly as in `bin/fm-merge-local.sh:15-18`.
- Verdict file grammar (only these four line forms, append-only): `approve: <text>`, `reject: <text>`, `escalate: <text>`, `lens: <text>`.
- Seams: `FM_VERIFY_CMD` (verifier; prompt as `$1`, cwd = crewmate worktree, stdout = report ending in a `VERDICT:` line), `FM_LENS_CMD` (lens; diff on stdin, review on stdout), `FM_RELAY_CMD` (reject relay; default `bin/fm-send.sh`), `FM_VERIFY_MAX_ATTEMPTS` (default 3), `FM_VERIFY_OVERRIDE=1` (captain bypass, loud banner).
- Fail closed: infra failure (verifier won't run, no `VERDICT:` line) → `escalate:`, never `approve:`.
- `fm-verify.sh` exit codes: 0 approve (or non-ship skip), 2 reject, 3 escalate, 1 usage error.
- Tests never call real `claude`/`codex`/Fugu; every test honors `LEDGER_MUTATE=1` with a mutation that makes a CORRECT implementation fail (proving non-vacuous), like `tests/fm-ctxwatch-g1.test.sh:23-24`.
- Ledger discipline: register each gate as `"status": "unproven"` BEFORE its test exists, observe it red via `bash gates/verify.sh` (exits 1 while WIP — expected), then implement to green. NEVER hand-edit a status to green.
- Commit in `/Users/stoneevenson/firstmate` after every task, message style `feat(quarterdeck): ...`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

- Create: `bin/fm-verdict-lib.sh` — verdict grammar, sourced by fm-verify + both merge gates
- Create: `bin/fm-verify.sh` — the Quarterdeck runner (lens chain → verifier → verdict → relay/cap)
- Modify: `bin/fm-merge-local.sh` — require approve before fast-forward
- Modify: `bin/fm-pr-check.sh` — require approve before arming the merge poll
- Modify: `bin/fm-brief.sh` — ship-brief DoD gains the verification clause
- Modify: `AGENTS.md` — document the stage
- Modify: `gates/ledger.json` — 7 new gates (q1–q7)
- Create: `tests/fm-quarterdeck-q1.test.sh` … `tests/fm-quarterdeck-q7.test.sh`

---

### Task 1: Verdict library + gate-q1 (grammar)

**Files:**
- Create: `bin/fm-verdict-lib.sh`
- Modify: `gates/ledger.json` (append gate-q1 entry)
- Test: `tests/fm-quarterdeck-q1.test.sh`

**Interfaces:**
- Produces (later tasks source these exact names):
  - `fm_verdict_file <state-dir> <id>` → prints `<state-dir>/<id>.verdict`
  - `fm_verdict_append <state-dir> <id> <kind> <text>` → appends `<kind>: <text>`; kind must be `approve|reject|escalate|lens`, else prints error and returns 1
  - `fm_verdict_last <state-dir> <id>` → prints kind of last DECISION line (`approve|reject|escalate`; `lens:` lines are evidence, ignored); returns 1 if no file/decision
  - `fm_verdict_reject_count <state-dir> <id>` → prints integer (0 if no file)
  - `fm_verdict_require_approve <state-dir> <id> <label>` → returns 0 iff last decision is approve OR `FM_VERIFY_OVERRIDE=1` (bordered banner either way on refusal/override)

- [ ] **Step 1: Register gate-q1 as unproven**

Append to the `"gates"` array in `gates/ledger.json` (before the closing `]`):

```json
    {
      "id": "gate-q1-verdict-grammar",
      "title": "Verdict grammar: only approve/reject/escalate/lens lines; last-decision and reject-count read correctly",
      "observable": "fm_verdict_append refuses an invalid kind; fm_verdict_last ignores lens lines; fm_verdict_reject_count counts only reject lines",
      "origin_mode": "build",
      "spec_ref": "docs/specs/2026-07-01-agent-os-council.md",
      "blocked_by": [],
      "test_ref": "bash tests/fm-quarterdeck-q1.test.sh",
      "baseline_ref": null,
      "first_observed_red": null,
      "mutation_verified": null,
      "status": "unproven",
      "vacuous": false,
      "regression": false,
      "created": "2026-07-01T00:00:00Z",
      "last_verified": null
    }
```

- [ ] **Step 2: Write the failing test**

Create `tests/fm-quarterdeck-q1.test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Q1: verdict-file grammar. Only approve/reject/escalate/lens append; last
# decision ignores lens lines; reject count counts only rejects.
# Mutation (LEDGER_MUTATE=1): append with kind "approved" (invalid) and expect
# it to SUCCEED — a correct validator refuses, so the assertion fails, proving
# the test is keyed to real validation.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q1)
S="$TMP/state"; mkdir -p "$S"

# valid kinds append, in order
fm_verdict_append "$S" t1 lens "none stub" || fail "lens append must succeed"
fm_verdict_append "$S" t1 reject "first miss" || fail "reject append must succeed"
fm_verdict_append "$S" t1 lens "codex stub" || fail "second lens append must succeed"
fm_verdict_append "$S" t1 approve "verified" || fail "approve append must succeed"

f=$(fm_verdict_file "$S" t1)
assert_present "$f" "verdict file exists"
assert_grep "reject: first miss" "$f" "reject line recorded verbatim"

# invalid kind refused (mutation: an invalid kind is expected to succeed)
BAD=working
[ "${LEDGER_MUTATE:-}" = 1 ] && BAD=approved
if fm_verdict_append "$S" t1 "$BAD" nope 2>/dev/null; then
  fail "invalid kind '$BAD' must be refused"
fi
assert_no_grep "nope" "$f" "invalid kind must not reach the file"

# last decision ignores lens lines
last=$(fm_verdict_last "$S" t1) || fail "last decision must resolve"
[ "$last" = approve ] || fail "last decision must be approve (got: $last)"
fm_verdict_append "$S" t1 lens "trailing lens evidence"
last=$(fm_verdict_last "$S" t1) || fail "last decision must still resolve"
[ "$last" = approve ] || fail "trailing lens line must not change the decision (got: $last)"

# reject count counts only rejects; missing file counts 0
[ "$(fm_verdict_reject_count "$S" t1)" = 1 ] || fail "reject count must be 1"
[ "$(fm_verdict_reject_count "$S" ghost)" = 0 ] || fail "missing file must count 0"
fm_verdict_last "$S" ghost >/dev/null 2>&1 && fail "no file must mean no decision"

# require_approve: approve passes, reject-last refuses with banner, override passes
fm_verdict_require_approve "$S" t1 test-label || fail "approve-last must pass require_approve"
fm_verdict_append "$S" t2 reject "not yet"
out=$(fm_verdict_require_approve "$S" t2 test-label 2>&1) && fail "reject-last must refuse"
assert_contains "$out" "QUARTERDECK" "refusal prints the Quarterdeck banner"
FM_VERIFY_OVERRIDE=1 fm_verdict_require_approve "$S" t2 test-label >/dev/null 2>&1 \
  || fail "FM_VERIFY_OVERRIDE=1 must bypass"

pass "Q1 verdict grammar"
```

- [ ] **Step 3: Observe red**

Run: `cd /Users/stoneevenson/firstmate && bash gates/verify.sh; echo "exit=$?"`
Expected: `gate-q1-verdict-grammar` reported red (test fails: `bin/fm-verdict-lib.sh` doesn't exist), `exit=1`. The 5 ctxwatch gates stay green.

- [ ] **Step 4: Implement the library**

Create `bin/fm-verdict-lib.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# fm-verdict-lib.sh - the Quarterdeck's append-only verdict channel.
# Spec: docs/specs/2026-07-01-agent-os-council.md (Phase 1).
#
# state/<id>.verdict holds one line per event, same grammar family as
# state/<id>.status: `<kind>: <text>` with kind in approve|reject|escalate|lens.
# approve/reject/escalate are DECISIONS (fm-verify's outcome); lens lines are
# evidence (which foreign lens ran). The gate consumed by fm-merge-local and
# fm-pr-check is fm_verdict_require_approve: the LAST decision line must be
# approve. FM_VERIFY_OVERRIDE=1 is the captain's explicit bypass and prints a
# loud banner so it never happens silently.
#
# Source this; do not execute it.

fm_verdict_file() {  # <state-dir> <id>
  printf '%s/%s.verdict\n' "$1" "$2"
}

fm_verdict_append() {  # <state-dir> <id> <kind> <text>
  local kind=$3
  case "$kind" in
    approve|reject|escalate|lens) : ;;
    *) echo "error: invalid verdict kind '$kind' (approve|reject|escalate|lens)" >&2; return 1 ;;
  esac
  printf '%s: %s\n' "$kind" "$4" >> "$(fm_verdict_file "$1" "$2")"
}

fm_verdict_last() {  # <state-dir> <id> -> kind of last decision line
  local f line
  f=$(fm_verdict_file "$1" "$2")
  [ -f "$f" ] || return 1
  line=$(grep -E '^(approve|reject|escalate):' "$f" | tail -1) || return 1
  printf '%s\n' "${line%%:*}"
}

fm_verdict_reject_count() {  # <state-dir> <id>
  local f
  f=$(fm_verdict_file "$1" "$2")
  [ -f "$f" ] || { echo 0; return 0; }
  grep -c '^reject:' "$f" || true
}

fm_verdict_require_approve() {  # <state-dir> <id> <label>
  local last
  if [ "${FM_VERIFY_OVERRIDE:-}" = 1 ]; then
    {
      echo "==================== QUARTERDECK OVERRIDE ===================="
      echo "WARNING: $3 proceeding for task $2 WITHOUT a verifier approve"
      echo "(FM_VERIFY_OVERRIDE=1 - captain authority; this is logged, not silent)"
      echo "=============================================================="
    } >&2
    return 0
  fi
  last=$(fm_verdict_last "$1" "$2" 2>/dev/null) || last=none
  if [ "$last" != approve ]; then
    {
      echo "======================== QUARTERDECK ========================="
      echo "REFUSED: $3 for task $2 - no verifier approve (last verdict: $last)"
      echo "Run: bin/fm-verify.sh $2"
      echo "Captain bypass (loud, logged): FM_VERIFY_OVERRIDE=1"
      echo "=============================================================="
    } >&2
    return 1
  fi
  return 0
}
```

- [ ] **Step 5: Verify green, then commit**

Run: `bash tests/fm-quarterdeck-q1.test.sh` → `ok - Q1 verdict grammar`
Run: `LEDGER_MUTATE=1 bash tests/fm-quarterdeck-q1.test.sh; echo "exit=$?"` → `not ok`, `exit=1` (mutation bites)
Run: `bash gates/verify.sh; echo "exit=$?"` → gate-q1 green, `exit=1` only because q2–q7 don't exist yet (they aren't registered yet, so expected here: `exit=0` with 6 green gates — if other WIP exists, read the drain list, only q-gates matter).

```bash
git add bin/fm-verdict-lib.sh tests/fm-quarterdeck-q1.test.sh gates/ledger.json gates/LEDGER.md
git commit -m "feat(quarterdeck): verdict grammar lib + gate-q1

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Merge hard gate + gate-q2

**Files:**
- Modify: `bin/fm-merge-local.sh:26` (insert after the mode check)
- Modify: `gates/ledger.json` (append gate-q2)
- Test: `tests/fm-quarterdeck-q2.test.sh`

**Interfaces:**
- Consumes: `fm_verdict_append`, `fm_verdict_require_approve` from Task 1.

- [ ] **Step 1: Register gate-q2 as unproven**

Append to `gates/ledger.json` (same shape as q1; only the changed fields shown — fill the rest identically):

```json
    {
      "id": "gate-q2-merge-refuses-unverified",
      "title": "fm-merge-local refuses without a trailing approve verdict; approve merges; override is loud",
      "observable": "fm-merge-local exits 1 with the QUARTERDECK banner when state/<id>.verdict is missing or ends in reject, fast-forwards on approve, and honors FM_VERIFY_OVERRIDE=1 with a warning banner",
      "blocked_by": ["gate-q1-verdict-grammar"],
      "test_ref": "bash tests/fm-quarterdeck-q2.test.sh"
    }
```

(`origin_mode` "build", `spec_ref` "docs/specs/2026-07-01-agent-os-council.md", nulls, `"status": "unproven"`, `created` "2026-07-01T00:00:00Z" — exactly as in Task 1 Step 1.)

- [ ] **Step 2: Write the failing test**

Create `tests/fm-quarterdeck-q2.test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Q2: the merge hard gate. fm-merge-local must refuse a task whose verdict file
# is missing or whose last decision is not approve, must merge on approve, and
# must honor the loud FM_VERIFY_OVERRIDE=1 captain bypass.
# Mutation (LEDGER_MUTATE=1): with the last verdict a reject, the test asserts
# the merge SUCCEEDS - a correct gate refuses, failing the test.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q2)
S="$TMP/state"; mkdir -p "$S"
export FM_STATE_OVERRIDE="$S"
fm_git_identity

REPO="$TMP/proj"
fm_git_init_commit "$REPO"
DEF=$(git -C "$REPO" symbolic-ref --short HEAD)
git -C "$REPO" checkout -q -b fm/q2task
printf 'x\n' > "$REPO/x.txt"
git -C "$REPO" add x.txt
git -C "$REPO" commit -qm change
git -C "$REPO" checkout -q "$DEF"

fm_write_meta "$S/q2task.meta" \
  "window=firstmate:fm-q2task" "worktree=$TMP/wt" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"

# 1. no verdict file -> refuse with banner
out=$("$ROOT/bin/fm-merge-local.sh" q2task 2>&1); code=$?
expect_code 1 "$code" "merge without any verdict must refuse"
assert_contains "$out" "QUARTERDECK" "refusal shows the Quarterdeck banner"

# 2. trailing reject -> refuse (mutation expects success here)
fm_verdict_append "$S" q2task lens "none stub"
fm_verdict_append "$S" q2task reject "not proven"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  "$ROOT/bin/fm-merge-local.sh" q2task >/dev/null 2>&1 \
    || fail "MUTATION: merge over trailing reject expected to succeed"
else
  out=$("$ROOT/bin/fm-merge-local.sh" q2task 2>&1); code=$?
  expect_code 1 "$code" "merge with trailing reject must refuse"
fi

# 3. override bypasses loudly even over a reject
out=$(FM_VERIFY_OVERRIDE=1 "$ROOT/bin/fm-merge-local.sh" q2task 2>&1) \
  || fail "override merge must succeed: $out"
assert_contains "$out" "OVERRIDE" "override prints the warning banner"
assert_contains "$out" "merged fm/q2task" "override actually merged"

# 4. approve merges cleanly (fresh branch so there is something to merge)
git -C "$REPO" checkout -q -b fm/q2b
printf 'y\n' > "$REPO/y.txt"
git -C "$REPO" add y.txt
git -C "$REPO" commit -qm change2
git -C "$REPO" checkout -q "$DEF"
fm_write_meta "$S/q2b.meta" \
  "window=firstmate:fm-q2b" "worktree=$TMP/wt" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
fm_verdict_append "$S" q2b approve "verified"
out=$("$ROOT/bin/fm-merge-local.sh" q2b 2>&1) || fail "merge with approve must succeed: $out"
assert_contains "$out" "merged fm/q2b" "approve merge output"

pass "Q2 merge hard gate"
```

- [ ] **Step 3: Observe red**

Run: `bash tests/fm-quarterdeck-q2.test.sh; echo "exit=$?"`
Expected: FAIL — step 1's merge succeeds today (no gate exists), `exit=1`. Then `bash gates/verify.sh` → gate-q2 red.

- [ ] **Step 4: Implement**

In `bin/fm-merge-local.sh`, insert after line 26 (`[ "$MODE" = local-only ] || …`):

```bash
# Quarterdeck: merging is gated on an independent verifier approve — the last
# decision line of state/<id>.verdict must be `approve:` (bin/fm-verify.sh
# writes it). FM_VERIFY_OVERRIDE=1 is the captain's loud, logged bypass.
# Spec: docs/specs/2026-07-01-agent-os-council.md.
# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"
fm_verdict_require_approve "$STATE" "$ID" fm-merge-local
```

(`set -eu` makes a refusal exit 1 automatically.)

- [ ] **Step 5: Verify green, then commit**

Run: `bash tests/fm-quarterdeck-q2.test.sh` → `ok`; `LEDGER_MUTATE=1 bash tests/fm-quarterdeck-q2.test.sh` → `not ok`; `bash tests/fm-teardown.test.sh` (regression check on a neighboring suite that exercises merge paths — must still pass); `bash gates/verify.sh` → q1, q2 green.

```bash
git add bin/fm-merge-local.sh tests/fm-quarterdeck-q2.test.sh gates/ledger.json gates/LEDGER.md
git commit -m "feat(quarterdeck): merge hard gate + gate-q2

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: PR-check hard gate + gate-q3

**Files:**
- Modify: `bin/fm-pr-check.sh:15` (insert after `URL=$2`)
- Modify: `gates/ledger.json` (append gate-q3)
- Test: `tests/fm-quarterdeck-q3.test.sh`

**Interfaces:**
- Consumes: `fm_verdict_append`, `fm_verdict_require_approve` from Task 1.

- [ ] **Step 1: Register gate-q3 as unproven** — same shape as q2 with:

```json
    {
      "id": "gate-q3-prcheck-refuses-unverified",
      "title": "fm-pr-check refuses to arm the merge poll without a trailing approve verdict",
      "observable": "fm-pr-check exits 1 with the QUARTERDECK banner and writes no state/<id>.check.sh when the verdict is missing/reject; arms it on approve",
      "blocked_by": ["gate-q1-verdict-grammar"],
      "test_ref": "bash tests/fm-quarterdeck-q3.test.sh"
    }
```

- [ ] **Step 2: Write the failing test**

Create `tests/fm-quarterdeck-q3.test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Q3: the PR-poll hard gate. fm-pr-check must refuse to arm state/<id>.check.sh
# (the watcher's merge poll) without a trailing approve verdict.
# Mutation (LEDGER_MUTATE=1): with a trailing reject the test asserts arming
# SUCCEEDS - a correct gate refuses, failing the test.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q3)
S="$TMP/state"; mkdir -p "$S"
export FM_STATE_OVERRIDE="$S"
URL="https://github.com/example/repo/pull/1"

fm_write_meta "$S/q3task.meta" \
  "window=firstmate:fm-q3task" "worktree=$TMP/wt" "project=$TMP/proj" \
  "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"

# 1. no verdict -> refuse, nothing armed, no pr= recorded
out=$("$ROOT/bin/fm-pr-check.sh" q3task "$URL" 2>&1); code=$?
expect_code 1 "$code" "arming without a verdict must refuse"
assert_contains "$out" "QUARTERDECK" "refusal shows the banner"
assert_absent "$S/q3task.check.sh" "check script must not be armed"
assert_no_grep "pr=$URL" "$S/q3task.meta" "pr url must not be recorded on refusal"

# 2. trailing reject -> refuse (mutation expects success)
fm_verdict_append "$S" q3task reject "not proven"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  "$ROOT/bin/fm-pr-check.sh" q3task "$URL" >/dev/null 2>&1 \
    || fail "MUTATION: arming over reject expected to succeed"
else
  out=$("$ROOT/bin/fm-pr-check.sh" q3task "$URL" 2>&1); code=$?
  expect_code 1 "$code" "arming with trailing reject must refuse"
  assert_absent "$S/q3task.check.sh" "check script still must not exist"
fi

# 3. approve -> arms
fm_verdict_append "$S" q3task approve "verified"
out=$("$ROOT/bin/fm-pr-check.sh" q3task "$URL" 2>&1) || fail "arming with approve must succeed: $out"
assert_present "$S/q3task.check.sh" "check script armed"
assert_grep "pr=$URL" "$S/q3task.meta" "pr url recorded"

pass "Q3 pr-check hard gate"
```

- [ ] **Step 3: Observe red** — `bash tests/fm-quarterdeck-q3.test.sh` FAILS (arming succeeds today); `bash gates/verify.sh` → gate-q3 red.

- [ ] **Step 4: Implement**

In `bin/fm-pr-check.sh`, insert after line 15 (`URL=$2`):

```bash
# Quarterdeck: arming the merge poll implies the work is accepted — gated on an
# independent verifier approve exactly like fm-merge-local. Spec:
# docs/specs/2026-07-01-agent-os-council.md. FM_VERIFY_OVERRIDE=1 bypasses loudly.
# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"
fm_verdict_require_approve "$STATE" "$ID" fm-pr-check
```

- [ ] **Step 5: Verify green, commit** — q-test ok, mutation not-ok, `bash gates/verify.sh` → q1–q3 green.

```bash
git add bin/fm-pr-check.sh tests/fm-quarterdeck-q3.test.sh gates/ledger.json gates/LEDGER.md
git commit -m "feat(quarterdeck): pr-check hard gate + gate-q3

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: fm-verify.sh core — verifier seam, approve path, reject round-trip + gate-q4

**Files:**
- Create: `bin/fm-verify.sh`
- Modify: `gates/ledger.json` (append gate-q4)
- Test: `tests/fm-quarterdeck-q4.test.sh`

**Interfaces:**
- Consumes: all `fm_verdict_*` functions from Task 1.
- Produces: `bin/fm-verify.sh <task-id>` — exit 0 approve/skip, 2 reject, 3 escalate, 1 usage. Writes `data/<id>/lens-diff.patch`, `data/<id>/lens-review.md`, `data/<id>/verify-report.md`, appends to `state/<id>.verdict`. Verifier contract: the command in `FM_VERIFY_CMD` gets the full prompt as `$1`, runs with cwd = crewmate worktree, and its stdout must end with `VERDICT: approve|reject|escalate - <reason>`.

- [ ] **Step 1: Register gate-q4 as unproven** — same shape, with:

```json
    {
      "id": "gate-q4-reject-roundtrip",
      "title": "fm-verify: approve path records approve; reject relays findings to the crewmate and exits 2; non-ship tasks skip",
      "observable": "with a stubbed verifier and relay, a reject verdict appends 'reject: (attempt 1 of 3)', the relay receives the QUARTERDECK REJECTED message, exit is 2; an approve verdict appends approve and exits 0; kind=scout skips with exit 0",
      "blocked_by": ["gate-q1-verdict-grammar"],
      "test_ref": "bash tests/fm-quarterdeck-q4.test.sh"
    }
```

- [ ] **Step 2: Write the failing test**

Create `tests/fm-quarterdeck-q4.test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Q4: fm-verify core round-trip with stubbed seams. Reject -> verdict line
# "(attempt 1 of 3)" + relay message + exit 2. Approve -> approve line + exit 0.
# Non-ship kinds skip (exit 0, no verdict decision).
# Mutation (LEDGER_MUTATE=1): the "rejecting" stub emits approve - every
# reject-path assertion then fails on a correct implementation.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q4)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

# crewmate fixture: repo + worktree on branch fm/q4task with one commit
REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q4task
printf 'change\n' > "$WT/work.txt"
git -C "$WT" add work.txt
git -C "$WT" commit -qm "crewmate change"

fm_write_meta "$S/q4task.meta" \
  "window=firstmate:fm-q4task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
mkdir -p "$D/q4task"
printf '# Task\nDo the thing.\n# Definition of done\nwork.txt exists.\n' > "$D/q4task/brief.md"

# stub seams
REJECT_WORD=reject
[ "${LEDGER_MUTATE:-}" = 1 ] && REJECT_WORD=approve
cat > "$TMP/verify-reject.sh" <<SH
#!/usr/bin/env bash
echo "I checked everything."
echo "VERDICT: $REJECT_WORD - tests do not actually pass"
SH
cat > "$TMP/verify-approve.sh" <<'SH'
#!/usr/bin/env bash
echo "Re-ran gates and DoD myself."
echo "VERDICT: approve - all claims reproduced"
SH
cat > "$TMP/relay.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/relay.log"
SH
chmod +x "$TMP"/verify-reject.sh "$TMP"/verify-approve.sh "$TMP"/relay.sh
export FM_LENS_CMD="echo stub-lens-review"

# 1. reject round-trip
out=$(FM_VERIFY_CMD="$TMP/verify-reject.sh" FM_RELAY_CMD="$TMP/relay.sh" \
      "$ROOT/bin/fm-verify.sh" q4task 2>&1); code=$?
expect_code 2 "$code" "reject must exit 2"
V=$(fm_verdict_file "$S" q4task)
assert_grep "lens: custom" "$V" "custom lens recorded"
assert_grep "reject: (attempt 1 of 3)" "$V" "reject recorded with attempt count"
assert_present "$TMP/relay.log" "relay invoked"
assert_grep "QUARTERDECK REJECTED" "$TMP/relay.log" "relay message names the reject"
assert_grep "fm-q4task" "$TMP/relay.log" "relay targets the crewmate window"
assert_present "$D/q4task/verify-report.md" "verifier report persisted"
assert_present "$D/q4task/lens-review.md" "lens review persisted"

# 2. approve after a fix
out=$(FM_VERIFY_CMD="$TMP/verify-approve.sh" FM_RELAY_CMD="$TMP/relay.sh" \
      "$ROOT/bin/fm-verify.sh" q4task 2>&1); code=$?
expect_code 0 "$code" "approve must exit 0"
last=$(fm_verdict_last "$S" q4task)
[ "$last" = approve ] || fail "last decision must be approve (got: $last)"

# 3. non-ship kinds skip
fm_write_meta "$S/q4scout.meta" \
  "window=firstmate:fm-q4scout" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=scout" "mode=local-only" "yolo=off"
out=$(FM_VERIFY_CMD="$TMP/verify-reject.sh" "$ROOT/bin/fm-verify.sh" q4scout 2>&1); code=$?
expect_code 0 "$code" "scout must skip with exit 0"
assert_contains "$out" "skip" "scout skip is announced"
fm_verdict_last "$S" q4scout >/dev/null 2>&1 && fail "scout must record no decision"

pass "Q4 fm-verify reject round-trip"
```

- [ ] **Step 3: Observe red** — `bash tests/fm-quarterdeck-q4.test.sh` FAILS (`bin/fm-verify.sh` doesn't exist); `bash gates/verify.sh` → gate-q4 red.

- [ ] **Step 4: Implement fm-verify.sh**

Create `bin/fm-verify.sh` (chmod +x) — complete file:

```bash
#!/usr/bin/env bash
# Quarterdeck: the structural verifier stage between a crewmate's `done:` claim
# and firstmate's acceptance. Spec: docs/specs/2026-07-01-agent-os-council.md.
#
# `done:` is a claim, not an acceptance. fm-verify.sh, run by firstmate when a
# ship task reports done:
#   1. snapshots the crewmate's diff        -> data/<id>/lens-diff.patch
#   2. runs the foreign lens on it          -> data/<id>/lens-review.md
#      (chain: FM_LENS_CMD > Fugu > codex > none - degrades loudly, never silently)
#   3. spawns an independent fresh-context verifier (default-REJECT) in the
#      crewmate's worktree                  -> data/<id>/verify-report.md
#   4. appends the decision to state/<id>.verdict (fm-verdict-lib grammar);
#      fm-merge-local/fm-pr-check refuse without a trailing approve.
#   5. on reject: relays findings to the crewmate (FM_RELAY_CMD, default
#      fm-send.sh); after FM_VERIFY_MAX_ATTEMPTS (default 3) rejects, escalates.
#
# Fail closed: verifier won't run / emits no VERDICT line -> escalate, never
# approve. Non-ship tasks (scout/secondmate) skip in Phase 1.
#
# Seams: FM_VERIFY_CMD  verifier command; gets the prompt as $1, cwd=worktree,
#                       stdout must end with "VERDICT: approve|reject|escalate - reason"
#                       (default: claude -p --permission-mode bypassPermissions)
#        FM_LENS_CMD    lens command; diff on stdin, review on stdout
#        FM_RELAY_CMD   reject relay; default bin/fm-send.sh (word-split)
# Exit: 0 approve or skip, 2 reject, 3 escalate, 1 usage error.
# Usage: fm-verify.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

ID=${1:?usage: fm-verify.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "${KIND:-ship}" != ship ]; then
  echo "skip: task $ID kind=${KIND:-?} (Quarterdeck verifies ship tasks only in Phase 1)"
  exit 0
fi

WORKTREE=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2-)
[ -d "$WORKTREE" ] || { echo "error: worktree $WORKTREE missing for task $ID" >&2; exit 1; }
BRIEF="$DATA/$ID/brief.md"
mkdir -p "$DATA/$ID"

MAX=${FM_VERIFY_MAX_ATTEMPTS:-3}

# Already at the cap before this run? Straight to the captain, no more spins.
if [ "$(fm_verdict_reject_count "$STATE" "$ID")" -ge "$MAX" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($MAX rejects); captain decision required"
  echo "escalate: task $ID at attempt cap ($MAX rejects)" >&2
  exit 3
fi

# --- 1. diff payload ---------------------------------------------------------
default_branch() {
  local ref branch
  ref=$(git -C "$WORKTREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then echo "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$WORKTREE" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"; return 0
    fi
  done
  return 1
}

DIFF_FILE="$DATA/$ID/lens-diff.patch"
{
  DEFAULT=$(default_branch || true)
  if [ -n "${DEFAULT:-}" ] && base=$(git -C "$WORKTREE" merge-base HEAD "$DEFAULT" 2>/dev/null); then
    git -C "$WORKTREE" log --oneline "$base..HEAD"
    git -C "$WORKTREE" diff "$base..HEAD"
  else
    echo "(no default branch resolvable; showing HEAD commit only)"
    git -C "$WORKTREE" show HEAD
  fi
} | head -c 200000 > "$DIFF_FILE"

# --- 2. foreign lens: FM_LENS_CMD > Fugu > codex > none ------------------------
LENS_REVIEW="$DATA/$ID/lens-review.md"
LENS_PROMPT="You are a hostile senior reviewer. Roast this diff before it ships: correctness bugs, untested claims, security holes, scope drift. Be specific (file:line). End with the findings that most deserve a reject, or 'no blocking findings'."

lens_fugu() {
  [ -n "${FUGU_API_KEY:-}" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$DIFF_FILE" "$LENS_PROMPT" <<'PY' > "$LENS_REVIEW" && [ -s "$LENS_REVIEW" ]
import json, os, sys, urllib.request
diff = open(sys.argv[1], errors="replace").read()
body = json.dumps({"model": "fugu", "messages": [
    {"role": "system", "content": sys.argv[2]},
    {"role": "user", "content": diff}]}).encode()
req = urllib.request.Request(
    "https://api.sakana.ai/v1/chat/completions", data=body,
    headers={"Authorization": "Bearer " + os.environ["FUGU_API_KEY"],
             "Content-Type": "application/json"})
resp = json.load(urllib.request.urlopen(req, timeout=180))
content = resp["choices"][0]["message"]["content"]
if not content.strip():
    raise SystemExit("empty lens review")
print(content)
PY
}

lens_codex() {
  command -v codex >/dev/null 2>&1 || return 1
  codex exec --cd "$WORKTREE" \
    "$LENS_PROMPT Review the diff at $DIFF_FILE against the worktree around you." \
    > "$LENS_REVIEW" 2>/dev/null && [ -s "$LENS_REVIEW" ]
}

LENS=none
if [ -n "${FM_LENS_CMD:-}" ]; then
  if sh -c "$FM_LENS_CMD" < "$DIFF_FILE" > "$LENS_REVIEW" 2>/dev/null && [ -s "$LENS_REVIEW" ]; then
    LENS=custom
  fi
elif lens_fugu 2>/dev/null; then
  LENS=fugu
elif lens_codex; then
  LENS=codex
fi
if [ "$LENS" = none ]; then
  printf 'no foreign lens available (FUGU_API_KEY unset or failed; codex not on PATH)\n' > "$LENS_REVIEW"
  echo "warning: foreign lens degraded to none for task $ID" >&2
fi
fm_verdict_append "$STATE" "$ID" lens "$LENS $(head -c 120 "$LENS_REVIEW" | tr '\n' ' ')"

# --- 3. independent verifier (fail closed) -------------------------------------
REPORT="$DATA/$ID/verify-report.md"
VERIFY_CMD=${FM_VERIFY_CMD:-claude -p --permission-mode bypassPermissions}

BRIEF_TEXT="(no brief found at $BRIEF)"
[ -f "$BRIEF" ] && BRIEF_TEXT=$(cat "$BRIEF")
PROMPT=$(cat <<EOF
You are the Quarterdeck verifier: a fresh-context independent checker. The
crewmate for task $ID claims done. Default stance: REJECT until proven.
Never trust the crewmate's words - re-run everything yourself from this
worktree ($WORKTREE, branch fm/$ID).

Checklist:
1. If a gates/ dir exists here, run: bash gates/verify.sh - every gate must be
   green; red or unproven gates are an automatic reject.
2. Re-prove each claim in the definition of done below by EXECUTING it (run the
   tests, run the command, read the diff), not by reading the crewmate's report.
3. Weigh the foreign-lens review below; confirm or dismiss each finding.
4. No cheating: confirm tests were not weakened, skipped, or deleted, and the
   diff stays inside the task's scope.

# The task brief
$BRIEF_TEXT

# Foreign-lens review (lens=$LENS)
$(cat "$LENS_REVIEW")

Your reply MUST end with exactly one line, nothing after it:
VERDICT: approve - <one-line reason>
VERDICT: reject - <the concrete failure a fix must address>
VERDICT: escalate - <why a human must decide>
EOF
)

verdict_kind=""
verdict_reason=""
if (cd "$WORKTREE" && sh -c "$VERIFY_CMD \"\$1\"" _ "$PROMPT") > "$REPORT" 2>&1; then
  line=$(grep -E '^VERDICT: (approve|reject|escalate)' "$REPORT" | tail -1 || true)
  if [ -n "$line" ]; then
    verdict_kind=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate).*$/\1/')
    verdict_reason=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate)[^A-Za-z0-9]*//')
  fi
fi
if [ -z "$verdict_kind" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "verifier infrastructure failure (no VERDICT line; see data/$ID/verify-report.md) - fail closed"
  echo "escalate: verifier produced no verdict for $ID (see $REPORT)" >&2
  exit 3
fi

# --- 4. record + route ----------------------------------------------------------
case "$verdict_kind" in
  approve)
    fm_verdict_append "$STATE" "$ID" approve "${verdict_reason:-verifier approve} (lens=$LENS)"
    echo "approve: task $ID verified (lens=$LENS)"
    exit 0
    ;;
  escalate)
    fm_verdict_append "$STATE" "$ID" escalate "${verdict_reason:-verifier escalate}"
    echo "escalate: task $ID needs the captain (see $REPORT)" >&2
    exit 3
    ;;
  reject)
    n=$(( $(fm_verdict_reject_count "$STATE" "$ID") + 1 ))
    fm_verdict_append "$STATE" "$ID" reject "(attempt $n of $MAX) ${verdict_reason:-verifier reject}"
    # shellcheck disable=SC2086 # FM_RELAY_CMD is deliberately word-split
    ${FM_RELAY_CMD:-"$SCRIPT_DIR/fm-send.sh"} "fm-$ID" \
      "QUARTERDECK REJECTED (attempt $n of $MAX): ${verdict_reason:-see report}. Findings: data/$ID/verify-report.md and data/$ID/lens-review.md. Fix and append a fresh done: line." \
      || echo "warning: could not relay reject to fm-$ID (window gone?)" >&2
    if [ "$n" -ge "$MAX" ]; then
      fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($n rejects); captain decision required"
      echo "escalate: task $ID hit the attempt cap ($n of $MAX)" >&2
      exit 3
    fi
    echo "reject: task $ID (attempt $n of $MAX); findings relayed" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 5: Verify green, commit** — q4 test ok, mutation not-ok, `bash gates/verify.sh` → q1–q4 green.

```bash
git add bin/fm-verify.sh tests/fm-quarterdeck-q4.test.sh gates/ledger.json gates/LEDGER.md
git commit -m "feat(quarterdeck): fm-verify core - verifier seam, reject round-trip + gate-q4

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Attempt cap + gate-q5

**Files:**
- Modify: `gates/ledger.json` (append gate-q5) — the cap logic already landed in Task 4; this gate proves it independently and pins it
- Test: `tests/fm-quarterdeck-q5.test.sh`

**Interfaces:**
- Consumes: `bin/fm-verify.sh` exit codes and verdict grammar from Task 4.

- [ ] **Step 1: Register gate-q5 as unproven** — same shape, with:

```json
    {
      "id": "gate-q5-attempt-cap",
      "title": "Third reject escalates instead of spinning; at-cap tasks escalate without re-running the verifier",
      "observable": "with two prior rejects a rejecting stub yields reject #3 AND an escalate line with exit 3; with three prior rejects fm-verify escalates immediately and the verifier stub is never invoked",
      "blocked_by": ["gate-q4-reject-roundtrip"],
      "test_ref": "bash tests/fm-quarterdeck-q5.test.sh"
    }
```

- [ ] **Step 2: Write the test**

Create `tests/fm-quarterdeck-q5.test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Q5: the attempt cap. Reject #3 escalates (no infinite fix loop); a task
# already at the cap escalates without even invoking the verifier.
# Mutation (LEDGER_MUTATE=1): seed only ONE prior reject - a correct cap then
# does NOT escalate on the next reject, failing the escalate assertions.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q5)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q5task
fm_write_meta "$S/q5task.meta" \
  "window=firstmate:fm-q5task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
mkdir -p "$D/q5task"

cat > "$TMP/verify-reject.sh" <<SH
#!/usr/bin/env bash
touch "$TMP/verifier-ran"
echo "VERDICT: reject - still broken"
SH
cat > "$TMP/relay.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/relay.log"
SH
chmod +x "$TMP/verify-reject.sh" "$TMP/relay.sh"
export FM_LENS_CMD="echo stub-lens" FM_VERIFY_CMD="$TMP/verify-reject.sh" FM_RELAY_CMD="$TMP/relay.sh"

# seed prior rejects (mutation seeds fewer so the cap correctly does not fire)
fm_verdict_append "$S" q5task reject "(attempt 1 of 3) seeded"
[ "${LEDGER_MUTATE:-}" = 1 ] || fm_verdict_append "$S" q5task reject "(attempt 2 of 3) seeded"

# next reject is the third -> reject AND escalate, exit 3
out=$("$ROOT/bin/fm-verify.sh" q5task 2>&1); code=$?
V=$(fm_verdict_file "$S" q5task)
expect_code 3 "$code" "third reject must exit 3 (escalate)"
assert_grep "escalate: attempt cap reached" "$V" "escalate line recorded at the cap"
[ "$(fm_verdict_last "$S" q5task)" = escalate ] || fail "last decision must be escalate"

# already at the cap -> immediate escalate, verifier never invoked
rm -f "$TMP/verifier-ran"
fm_write_meta "$S/q5b.meta" \
  "window=firstmate:fm-q5b" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
fm_verdict_append "$S" q5b reject "1"; fm_verdict_append "$S" q5b reject "2"; fm_verdict_append "$S" q5b reject "3"
out=$("$ROOT/bin/fm-verify.sh" q5b 2>&1); code=$?
expect_code 3 "$code" "at-cap task must escalate immediately"
assert_absent "$TMP/verifier-ran" "verifier must not run for an at-cap task"
assert_grep "escalate: attempt cap reached" "$(fm_verdict_file "$S" q5b)" "at-cap escalate recorded"

pass "Q5 attempt cap"
```

- [ ] **Step 3: Observe red / confirm gate registration bites** — Run `bash tests/fm-quarterdeck-q5.test.sh`. If Task 4's cap logic is correct this passes immediately; the RED observation then comes from the ledger: temporarily run `bash gates/verify.sh` BEFORE creating the test file (test_ref missing = red run recorded). Sequence strictly: register gate (Step 1) → `bash gates/verify.sh` (gate-q5 red: test file absent) → create test (Step 2) → `bash gates/verify.sh` (green).

- [ ] **Step 4: Commit**

```bash
git add tests/fm-quarterdeck-q5.test.sh gates/ledger.json gates/LEDGER.md
git commit -m "feat(quarterdeck): attempt-cap gate-q5

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Lens degrade + gate-q6

**Files:**
- Modify: `gates/ledger.json` (append gate-q6) — lens chain landed in Task 4; this gate pins the degrade behavior
- Test: `tests/fm-quarterdeck-q6.test.sh`

- [ ] **Step 1: Register gate-q6 as unproven** — same shape, with:

```json
    {
      "id": "gate-q6-lens-degrade",
      "title": "No Fugu key + no codex -> lens degrades to none loudly; verify still completes",
      "observable": "with FUGU_API_KEY unset, no FM_LENS_CMD, and codex absent from PATH, fm-verify logs a degradation warning, records 'lens: none', and still reaches an approve verdict",
      "blocked_by": ["gate-q4-reject-roundtrip"],
      "test_ref": "bash tests/fm-quarterdeck-q6.test.sh"
    }
```

- [ ] **Step 2: Write the test**

Create `tests/fm-quarterdeck-q6.test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Q6: lens degrade chain. With no custom lens, no Fugu key, and codex absent
# from PATH, the lens degrades to none LOUDLY (warning on stderr + 'lens: none'
# in the verdict file) and verification still completes.
# Mutation (LEDGER_MUTATE=1): a fake codex is planted on PATH - a correct chain
# then records 'lens: codex', failing the 'lens: none' assertions.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q6)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q6task
fm_write_meta "$S/q6task.meta" \
  "window=firstmate:fm-q6task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
mkdir -p "$D/q6task"

cat > "$TMP/verify-approve.sh" <<'SH'
#!/usr/bin/env bash
echo "VERDICT: approve - fine"
SH
chmod +x "$TMP/verify-approve.sh"

# a bare PATH that keeps core tools but has no codex (mutation plants one)
FB=$(fm_fakebin "$TMP")
for t in git grep sed head tail cut mktemp cat tr sh dirname basename; do
  p=$(command -v "$t") && ln -sf "$p" "$FB/$t"
done
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  cat > "$FB/codex" <<'SH'
#!/usr/bin/env bash
echo "fake codex lens review"
SH
  chmod +x "$FB/codex"
fi

out=$(env -i HOME="$HOME" PATH="$FB:/usr/bin:/bin" \
      FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D" \
      FM_VERIFY_CMD="$TMP/verify-approve.sh" \
      "$ROOT/bin/fm-verify.sh" q6task 2>&1); code=$?
expect_code 0 "$code" "verify must complete despite lens degrade"
assert_contains "$out" "degraded to none" "degradation is announced, never silent"
V=$(fm_verdict_file "$S" q6task)
assert_grep "lens: none" "$V" "lens: none recorded"
[ "$(fm_verdict_last "$S" q6task)" = approve ] || fail "verifier verdict still recorded"

pass "Q6 lens degrade"
```

Note: `env -i` guarantees `FUGU_API_KEY` (sourced into every shell by ~/.zshrc) cannot leak in — same trap as jarvis-talk's "missing key" tests. `/usr/bin:/bin` stays on PATH for anything the fakebin missed; codex lives in `/opt/homebrew/bin`, which is excluded.

- [ ] **Step 3: Observe red then green** — register gate (Step 1) → `bash gates/verify.sh` (q6 red: test absent) → create test → `bash tests/fm-quarterdeck-q6.test.sh` ok, `LEDGER_MUTATE=1 bash tests/fm-quarterdeck-q6.test.sh` not-ok → `bash gates/verify.sh` (q6 green).

- [ ] **Step 4: Commit**

```bash
git add tests/fm-quarterdeck-q6.test.sh gates/ledger.json gates/LEDGER.md
git commit -m "feat(quarterdeck): lens-degrade gate-q6

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Fail-closed + gate-q7

**Files:**
- Modify: `gates/ledger.json` (append gate-q7)
- Test: `tests/fm-quarterdeck-q7.test.sh`

- [ ] **Step 1: Register gate-q7 as unproven** — same shape, with:

```json
    {
      "id": "gate-q7-fail-closed",
      "title": "Verifier infrastructure failure escalates - never approves",
      "observable": "a verifier command that exits non-zero, or exits 0 with no VERDICT line, yields an escalate verdict and exit 3; the verdict file never gains an approve",
      "blocked_by": ["gate-q4-reject-roundtrip"],
      "test_ref": "bash tests/fm-quarterdeck-q7.test.sh"
    }
```

- [ ] **Step 2: Write the test**

Create `tests/fm-quarterdeck-q7.test.sh` (chmod +x):

```bash
#!/usr/bin/env bash
# Q7: fail closed. A verifier that crashes (non-zero exit) or produces no
# VERDICT line must yield escalate + exit 3 - never an approve.
# Mutation (LEDGER_MUTATE=1): the "crashing" stub instead prints a valid
# approve and exits 0 - a correct implementation then approves, failing the
# escalate assertions.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q7)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

REPO="$TMP/proj"; WT="$TMP/wt"
fm_git_worktree "$REPO" "$WT" fm/q7task
mkdir -p "$D/q7task"
export FM_LENS_CMD="echo stub-lens"

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  cat > "$TMP/verify-crash.sh" <<'SH'
#!/usr/bin/env bash
echo "VERDICT: approve - mutation"
SH
else
  cat > "$TMP/verify-crash.sh" <<'SH'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
SH
fi
cat > "$TMP/verify-mute.sh" <<'SH'
#!/usr/bin/env bash
echo "I have thoughts but no verdict."
SH
chmod +x "$TMP/verify-crash.sh" "$TMP/verify-mute.sh"

# 1. crashing verifier -> escalate
fm_write_meta "$S/q7task.meta" \
  "window=firstmate:fm-q7task" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
out=$(FM_VERIFY_CMD="$TMP/verify-crash.sh" "$ROOT/bin/fm-verify.sh" q7task 2>&1); code=$?
expect_code 3 "$code" "crashing verifier must exit 3"
V=$(fm_verdict_file "$S" q7task)
assert_grep "escalate: verifier infrastructure failure" "$V" "infra failure recorded as escalate"
assert_no_grep "approve:" "$V" "no approve may appear on infra failure"

# 2. verdict-less verifier -> escalate
fm_write_meta "$S/q7b.meta" \
  "window=firstmate:fm-q7b" "worktree=$WT" "project=$REPO" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
out=$(FM_VERIFY_CMD="$TMP/verify-mute.sh" "$ROOT/bin/fm-verify.sh" q7b 2>&1); code=$?
expect_code 3 "$code" "verdict-less verifier must exit 3"
assert_grep "escalate: verifier infrastructure failure" "$(fm_verdict_file "$S" q7b)" "mute verifier escalates"

pass "Q7 fail closed"
```

- [ ] **Step 3: Observe red then green** — register gate → `bash gates/verify.sh` (q7 red: test absent) → create test → test ok / mutation not-ok → `bash gates/verify.sh` (q7 green).

- [ ] **Step 4: Commit**

```bash
git add tests/fm-quarterdeck-q7.test.sh gates/ledger.json gates/LEDGER.md
git commit -m "feat(quarterdeck): fail-closed gate-q7

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Brief clause, AGENTS.md, full-suite pass

**Files:**
- Modify: `bin/fm-brief.sh:169` (after the `GATE_CHECK=` definition) and `bin/fm-brief.sh:262` (the `$GATE_CHECK` heredoc line)
- Modify: `AGENTS.md` (task-lifecycle + supervision sections)

**Interfaces:**
- Consumes: nothing new; documents Tasks 1–7.

- [ ] **Step 1: Add the verify clause to ship briefs**

In `bin/fm-brief.sh`, directly below the `GATE_CHECK=` assignment (line 169), add:

```bash
# Quarterdeck clause: ship-mode independent verification (spec:
# docs/specs/2026-07-01-agent-os-council.md). Like GATE_CHECK it is
# mode-independent, so defined once and appended to the definition of done.
VERIFY_CHECK="Independent verification (the Quarterdeck): \`done:\` is a claim, not an acceptance. An independent verifier will re-prove your claims against your worktree - re-running gates, tests, and the definition of done above. If it rejects, firstmate relays the findings; fix them and append a fresh \`done:\` line. After 3 rejects the task escalates to the captain. Make the work reproducible; do not argue with the verifier through the status file."
```

And change the final heredoc (line 261-262) from:

```
$DOD
$GATE_CHECK
```

to:

```
$DOD
$GATE_CHECK
$VERIFY_CHECK
```

- [ ] **Step 2: Verify the clause lands in all three ship modes (and NOT in scouts)**

```bash
T=$(mktemp -d); export FM_DATA_OVERRIDE="$T/data" FM_STATE_OVERRIDE="$T/state"; mkdir -p "$T/data" "$T/state"
bin/fm-brief.sh smoke1 jarvis-talk
grep -c "Quarterdeck" "$T/data/smoke1/brief.md"       # expected: 1
bin/fm-brief.sh smoke2 jarvis-talk --scout
grep -c "Quarterdeck" "$T/data/smoke2/brief.md" || true  # expected: 0
rm -rf "$T"; unset FM_DATA_OVERRIDE FM_STATE_OVERRIDE
```

- [ ] **Step 3: Document the stage in AGENTS.md**

Locate the task-lifecycle done-handling prose: `grep -n "self-reported\|done:" AGENTS.md | head -20`. In the supervision section (§8), immediately after the paragraph describing how firstmate reacts to a crewmate's `done:` line, insert:

```markdown
### Quarterdeck: done is a claim, not an acceptance

A ship task's `done:` line triggers verification, never direct acceptance. Run
`bin/fm-verify.sh <id>`: it runs a foreign-lens review of the diff (Fugu ->
codex -> none, degrading loudly), then an independent fresh-context verifier
(default-REJECT) that re-proves the brief's definition of done from the
crewmate's worktree. The decision lands in `state/<id>.verdict` (append-only:
`approve:` / `reject:` / `escalate:` / `lens:` evidence lines).

- `approve:` - proceed with the normal delivery path. `fm-merge-local.sh` and
  `fm-pr-check.sh` structurally refuse to run without a trailing approve
  (captain bypass: `FM_VERIFY_OVERRIDE=1`, loud and logged).
- `reject:` - fm-verify already relayed the findings to the crewmate; expect a
  fresh `done:`. Three rejects auto-escalate.
- `escalate:` - the captain decides. Infrastructure failures (verifier would
  not run) land here too: the stage fails closed, never open.

Scout and secondmate tasks skip the Quarterdeck (Phase 1 scope). Spec:
`docs/specs/2026-07-01-agent-os-council.md`.
```

- [ ] **Step 4: Full suite + ledger**

Run: `for t in tests/fm-quarterdeck-q*.test.sh; do bash "$t" || echo "FAILED: $t"; done` → 7× ok.
Run: `for t in tests/fm-teardown.test.sh tests/fm-spawn-batch.test.sh tests/fm-send-settle.test.sh; do bash "$t" || echo "FAILED: $t"; done` → no regressions in neighboring suites.
Run: `bash gates/verify.sh; echo "exit=$?"` → all 12 gates green (5 ctxwatch + 7 quarterdeck), `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-brief.sh AGENTS.md
git commit -m "feat(quarterdeck): brief verify clause + AGENTS.md operating docs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Live-shakedown checklist (not machine-gated — flag to the captain)

No code. Report these as the remaining human verifications, mirroring the README "machine-verified vs live shakedown" convention:

1. **Real verifier run:** on the next real ship task's `done:`, run `bin/fm-verify.sh <id>` with the default `claude -p --permission-mode bypassPermissions` and confirm a sane verdict + report quality.
2. **Fugu lens live:** after credits are added at console.sakana.ai/billing, confirm `lens: fugu` appears and the review is useful; until then the chain correctly logs `lens: codex`.
3. **codex lens live:** confirm `codex exec --cd <worktree>` produces a non-empty review under subscription auth (v0.142.1 verified installed).
4. **fm-send relay:** confirm a real reject lands in the crewmate's tmux composer and the crewmate acts on it.

---

## Self-Review Notes

- Spec coverage: flow steps 1–6 → Tasks 4/5; hard gates → Tasks 2/3; contract updates → Task 8; seams/scope guards → Tasks 4/6 (ship-only skip tested in q4); error handling → Tasks 6/7; all 7 spec gates map 1:1 to gates q1–q7. Live items the spec can't machine-gate → Task 9.
- Type consistency: `fm_verdict_*` signatures identical across Tasks 1–7; exit codes (0/2/3/1) consistent between fm-verify.sh header, q4, q5, q7 tests.
- Freeze is deliberately NOT in this plan: gates freeze later via `ledger freeze` once they've soaked (all tests already honor `LEDGER_MUTATE=1`, so freezing won't flag them vacuous).
