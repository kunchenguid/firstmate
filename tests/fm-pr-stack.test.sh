#!/usr/bin/env bash
# Behavior tests for the read-only PR-stack inventory and shared SQLite catalog.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/fm-pr-stack.py"
TMP_ROOT=$(fm_test_tmproot fm-pr-stack)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; exit 0; }

assert_present "$CLI" "bin/fm-pr-stack.py is missing"
[ -x "$CLI" ] || fail "bin/fm-pr-stack.py must be executable"

make_inventory_repo() {  # <name>
  local case_dir=$TMP_ROOT/$1 repo=$TMP_ROOT/$1/repo bare=$TMP_ROOT/$1/origin.git odd detached
  mkdir -p "$case_dir"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm base
  git clone --quiet --bare "$repo" "$bare"
  git -C "$repo" remote add origin "file://$bare"
  git -C "$repo" fetch -q origin
  git -C "$repo" remote set-head origin main
  git -C "$repo" branch --set-upstream-to=origin/main main >/dev/null
  git -C "$repo" branch zero main

  odd="$case_dir/odd"$'\n'"worktree with spaces"
  git -C "$repo" worktree add --quiet -b topic "$odd" main
  printf 'topic\n' > "$odd/topic.txt"
  git -C "$odd" add topic.txt
  git -C "$odd" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm topic
  git -C "$repo" branch --set-upstream-to=origin/main topic >/dev/null
  git -C "$repo" branch orphan topic
  printf 'dirty\n' >> "$odd/topic.txt"

  git -C "$repo" switch --quiet --detach main
  printf 'divergent\n' > "$repo/divergent.txt"
  git -C "$repo" add divergent.txt
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm divergent
  git -C "$repo" branch divergent HEAD
  git -C "$repo" switch --quiet main

  detached="$case_dir/detached worktree"
  git -C "$repo" worktree add --quiet --detach "$detached" main
  printf '%s\n' "$repo"
}

working_tree_digest() {  # <worktree>...
  python3 - "$@" <<'PY'
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

digest = hashlib.sha256()
for raw_root in sys.argv[1:]:
    root = Path(raw_root)
    digest.update(os.fsencode(str(root)))
    for path in sorted(root.rglob("*"), key=lambda item: os.fsencode(str(item))):
        relative = path.relative_to(root)
        if relative.parts and relative.parts[0] == ".git":
            continue
        digest.update(os.fsencode(str(relative)))
        if path.is_symlink():
            digest.update(b"L" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(b"F" + path.read_bytes())
        elif path.is_dir():
            digest.update(b"D")
print(digest.hexdigest())
PY
}

test_inventory_json_and_read_only_git() {
  local repo case_dir odd detached out err before_digest after_digest catalog names
  local before_refs=$TMP_ROOT/before.refs after_refs=$TMP_ROOT/after.refs
  local before_worktrees=$TMP_ROOT/before.worktrees after_worktrees=$TMP_ROOT/after.worktrees
  local before_remotes=$TMP_ROOT/before.remotes after_remotes=$TMP_ROOT/after.remotes
  repo=$(make_inventory_repo inventory)
  case_dir=$(dirname "$repo")
  odd="$case_dir/odd"$'\n'"worktree with spaces"
  detached="$case_dir/detached worktree"
  out=$case_dir/out.json
  err=$case_dir/err.txt

  git -C "$repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes > "$before_refs"
  git -C "$repo" worktree list --porcelain -z > "$before_worktrees"
  git -C "$repo" remote -v > "$before_remotes"
  before_digest=$(working_tree_digest "$repo" "$odd" "$detached")

  (cd "$repo" && "$CLI" inventory --json > "$out" 2> "$err") \
    || fail "inventory JSON failed: $(cat "$err")"
  [ ! -s "$err" ] || fail "successful JSON inventory wrote diagnostics: $(cat "$err")"
  jq -e . "$out" >/dev/null || fail "inventory stdout is not valid JSON"

  git -C "$repo" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes > "$after_refs"
  git -C "$repo" worktree list --porcelain -z > "$after_worktrees"
  git -C "$repo" remote -v > "$after_remotes"
  after_digest=$(working_tree_digest "$repo" "$odd" "$detached")
  cmp -s "$before_refs" "$after_refs" || fail "inventory changed refs"
  cmp -s "$before_worktrees" "$after_worktrees" || fail "inventory changed worktree HEADs or branch attachments"
  cmp -s "$before_remotes" "$after_remotes" || fail "inventory changed remotes"
  [ "$before_digest" = "$after_digest" ] || fail "inventory changed worktree contents"

  jq -e '
    .schema_version == 1
      and .query == "inventory"
      and (.observed_at | test("Z$"))
      and (.repository_head | test("^[0-9a-f]{40,64}$"))
      and .selected_base.source == "origin_head"
      and .selected_base.ref == "refs/remotes/origin/main"
      and (.selected_base.oid | test("^[0-9a-f]{40,64}$"))
      and (.worktrees | length) == 3
      and ([.worktrees[] | select(.detached == true)] | length) == 1
      and ([.worktrees[] | select(.path | contains("odd\nworktree with spaces"))] | length) == 1
      and ([.items[].ref] == ([.items[].ref] | sort))
      and ([.worktrees[].path] == ([.worktrees[].path] | sort))
  ' "$out" >/dev/null || fail "top-level inventory/base/worktree schema is wrong"

  names=$(jq -r '[.items[].name] | join(",")' "$out")
  [ "$names" = "divergent,main,orphan,topic,zero" ] \
    || fail "inventory omitted or reordered local branches: $names"
  jq -e '
    .items[] | select(.name == "topic")
    | .ref == "refs/heads/topic"
      and (.head_oid | test("^[0-9a-f]{40,64}$"))
      and .upstream_ref == "refs/remotes/origin/main"
      and .upstream == "origin/main"
      and (.checked_out_worktree | contains("odd\nworktree with spaces"))
      and .worktree_clean == false
      and .reachable_from_base == false
      and .unique_commit_count == 1
      and .unique_commit_proof.count == 1
      and (.unique_commit_proof.revision_range | contains(".."))
      and .disposition == "unregistered"
      and .disposition_reason == "no orchestrator declaration exists"
  ' "$out" >/dev/null || fail "dirty checked-out unique branch facts are wrong"
  jq -e '
    .items[] | select(.name == "orphan")
    | .upstream == null
      and .checked_out_worktree == null
      and .worktree_clean == null
      and .unique_commit_count == 1
      and .disposition == "unregistered"
  ' "$out" >/dev/null || fail "missing-upstream unregistered branch facts are wrong"
  jq -e '
    .items[] | select(.name == "zero")
    | .reachable_from_base == true
      and .unique_commit_count == 0
      and .disposition == "ignored"
      and (.disposition_reason | contains("no commits unique"))
  ' "$out" >/dev/null || fail "zero-unique branch behavior is wrong"
  jq -e '
    .items[] | select(.name == "divergent")
    | .reachable_from_base == false
      and .unique_commit_count == 1
      and .disposition == "unregistered"
  ' "$out" >/dev/null || fail "divergent branch behavior is wrong"

  catalog=$(jq -r .catalog.path "$out")
  [ "$catalog" = "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/pr-stack/orchestrator.sqlite" ] \
    || fail "catalog is not under the common Git directory: $catalog"
  [ "$(sqlite3 "$catalog" 'PRAGMA user_version;')" = 1 ] || fail "catalog user_version is not 1"
  [ "$(sqlite3 "$catalog" 'PRAGMA journal_mode;')" = wal ] || fail "catalog did not enable WAL"
  [ -z "$(sqlite3 "$catalog" 'PRAGMA foreign_key_check;')" ] || fail "catalog foreign keys are invalid"
  for table in branch_declarations branch_observations events operations reconciliations worktree_observations; do
    [ "$(sqlite3 "$catalog" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$table';")" = 1 ] \
      || fail "catalog table missing: $table"
  done
  [ "$(sqlite3 "$catalog" 'SELECT count(*) FROM branch_observations;')" = 5 ] \
    || fail "catalog current branch observations are incomplete"
  [ "$(sqlite3 "$catalog" 'SELECT count(*) FROM events WHERE action="inventory.reconciled";')" = 1 ] \
    || fail "catalog reconciliation event missing"
  pass "inventory is complete, NUL-safe, agent-readable, cataloged, and read-only for Git"
}

test_refresh_reobserves_and_catalog_is_shared() {
  local repo case_dir odd first second catalog first_event_count
  repo="$TMP_ROOT/inventory/repo"
  case_dir=$(dirname "$repo")
  odd="$case_dir/odd"$'\n'"worktree with spaces"
  first=$case_dir/first-refresh.json
  second=$case_dir/second-refresh.json
  (cd "$repo" && "$CLI" inventory --json > "$first") || fail "first refresh failed"
  catalog=$(jq -r .catalog.path "$first")
  first_event_count=$(sqlite3 "$catalog" 'SELECT count(*) FROM events;')
  sqlite3 "$catalog" <<'SQL'
INSERT INTO branch_declarations(
  repository_id, branch_ref, disposition, reason, owner_id, intent,
  metadata_json, created_at, updated_at
) VALUES
  (1, 'refs/heads/topic', 'registered', NULL, 'agent-7', 'topic work', '{}', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'),
  (1, 'refs/heads/orphan', 'ignored', 'fixture exception', NULL, NULL, '{}', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
SQL

  printf 'second dirty line\n' >> "$odd/topic.txt"
  (cd "$odd" && "$CLI" inventory --base main --json > "$second") || fail "linked-worktree refresh failed"
  [ "$(jq -r .catalog.path "$second")" = "$catalog" ] \
    || fail "linked worktree did not share the common-dir catalog"
  [ "$(jq -r '.items[] | select(.name == "topic") | .worktree_clean' "$second")" = false ] \
    || fail "refresh did not reobserve live dirty state"
  [ "$(sqlite3 "$catalog" 'SELECT count(*) FROM events;')" -eq $((first_event_count + 1)) ] \
    || fail "refresh did not append one audit event"
  [ "$(sqlite3 "$catalog" 'SELECT count(*) FROM reconciliations;')" -eq $((first_event_count + 1)) ] \
    || fail "refresh did not append reconciliation evidence"
  [ "$(jq -r .selected_base.source "$second")" = explicit ] \
    || fail "explicit base override identity was not preserved"
  [ "$(jq -r .selected_base.ref "$second")" = refs/heads/main ] \
    || fail "explicit base override did not resolve the full ref"
  jq -e '
    (.items[] | select(.name == "topic") | .disposition == "registered")
      and (.items[] | select(.name == "orphan")
        | .disposition == "ignored" and .disposition_reason == "fixture exception")
  ' "$second" >/dev/null || fail "refresh did not preserve orchestrator declarations"
  pass "refresh reobserves Git and all linked worktrees share one append-only catalog"
}

test_missing_and_ambiguous_default_base() {
  local missing=$TMP_ROOT/missing-base ambiguous=$TMP_ROOT/ambiguous-base out err rc
  git init -q -b topic "$missing"
  printf 'topic\n' > "$missing/file"
  git -C "$missing" add file
  git -C "$missing" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm topic
  out=$TMP_ROOT/missing.out
  err=$TMP_ROOT/missing.err
  rc=0
  (cd "$missing" && "$CLI" inventory --json > "$out" 2> "$err") || rc=$?
  expect_code 2 "$rc" "missing default base"
  [ ! -s "$out" ] || fail "missing-base diagnostics corrupted JSON stdout"
  assert_grep "no default integration base" "$err" "missing-base diagnostic is not actionable"
  (cd "$missing" && "$CLI" inventory --base HEAD --json | jq -e '.selected_base.source == "explicit"') >/dev/null \
    || fail "explicit base did not recover missing-default repository"

  git init -q -b main "$ambiguous"
  printf 'main\n' > "$ambiguous/file"
  git -C "$ambiguous" add file
  git -C "$ambiguous" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm main
  git -C "$ambiguous" branch master
  out=$TMP_ROOT/ambiguous.out
  err=$TMP_ROOT/ambiguous.err
  rc=0
  (cd "$ambiguous" && "$CLI" inventory --json > "$out" 2> "$err") || rc=$?
  expect_code 2 "$rc" "ambiguous default base"
  [ ! -s "$out" ] || fail "ambiguous-base diagnostics corrupted JSON stdout"
  assert_grep "ambiguous default integration base" "$err" "ambiguous-base diagnostic is not actionable"
  (cd "$ambiguous" && "$CLI" inventory --base main --json | jq -e '.selected_base.ref == "refs/heads/main"') >/dev/null \
    || fail "explicit base did not recover ambiguous-default repository"
  pass "missing and ambiguous defaults stop clearly while explicit base overrides recover"
}

test_bounded_concurrent_writer_failure_is_atomic() {
  local repo=$TMP_ROOT/inventory/repo catalog ready=$TMP_ROOT/holder.ready holder out err rc before after
  catalog=$(cd "$repo" && "$CLI" inventory --json | jq -r .catalog.path) || fail "catalog setup failed"
  before=$(sqlite3 "$catalog" 'SELECT count(*) FROM events;')
  python3 - "$catalog" "$ready" <<'PY' &
import sqlite3
import sys
import time

connection = sqlite3.connect(sys.argv[1], isolation_level=None)
connection.execute("BEGIN IMMEDIATE")
open(sys.argv[2], "w", encoding="utf-8").write("ready\n")
time.sleep(1.5)
connection.rollback()
connection.close()
PY
  holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$ready" ] && break
    sleep 0.05
  done
  [ -f "$ready" ] || { kill "$holder" 2>/dev/null || true; fail "catalog lock holder did not start"; }
  out=$TMP_ROOT/busy.out
  err=$TMP_ROOT/busy.err
  rc=0
  (cd "$repo" && FM_PR_STACK_LOCK_TIMEOUT_MS=50 "$CLI" inventory --json > "$out" 2> "$err") || rc=$?
  expect_code 3 "$rc" "bounded concurrent refresh"
  [ ! -s "$out" ] || fail "busy-writer diagnostic corrupted JSON stdout"
  assert_grep "catalog writer remained busy for 50 ms" "$err" "busy-writer diagnostic is not bounded/actionable"
  wait "$holder" || fail "catalog lock holder failed"
  after=$(sqlite3 "$catalog" 'SELECT count(*) FROM events;')
  [ "$before" = "$after" ] || fail "failed refresh exposed a partial catalog event"
  [ -z "$(sqlite3 "$catalog" 'PRAGMA foreign_key_check;')" ] || fail "failed refresh left invalid catalog rows"
  pass "concurrent writer contention fails within a bound and leaves no partial refresh"
}

test_invalid_lock_timeout_env_diagnoses_cleanly() {
  local repo=$TMP_ROOT/inventory/repo out err rc
  out=$TMP_ROOT/badtimeout.out
  err=$TMP_ROOT/badtimeout.err
  rc=0
  (cd "$repo" && FM_PR_STACK_LOCK_TIMEOUT_MS=abc "$CLI" inventory --json > "$out" 2> "$err") || rc=$?
  expect_code 2 "$rc" "non-integer FM_PR_STACK_LOCK_TIMEOUT_MS"
  [ ! -s "$out" ] || fail "non-integer timeout diagnostic corrupted JSON stdout"
  assert_grep "fm-pr-stack: invalid FM_PR_STACK_LOCK_TIMEOUT_MS" "$err" \
    "non-integer timeout diagnostic is not clean/actionable"

  rc=0
  (cd "$repo" && FM_PR_STACK_LOCK_TIMEOUT_MS=999999 "$CLI" inventory --json > "$out" 2> "$err") || rc=$?
  expect_code 2 "$rc" "out-of-range FM_PR_STACK_LOCK_TIMEOUT_MS"
  [ ! -s "$out" ] || fail "out-of-range timeout diagnostic corrupted JSON stdout"
  assert_grep "fm-pr-stack: invalid FM_PR_STACK_LOCK_TIMEOUT_MS" "$err" \
    "out-of-range timeout diagnostic is not clean/actionable"
  pass "invalid FM_PR_STACK_LOCK_TIMEOUT_MS values fail cleanly with a bounded diagnostic"
}

test_human_output_is_concise() {
  local repo=$TMP_ROOT/inventory/repo out
  out=$(cd "$repo" && "$CLI" inventory --base main) || fail "human inventory failed"
  assert_contains "$out" "Base: main @" "human output omitted selected base"
  assert_contains "$out" "Worktrees: 3" "human output omitted worktree summary"
  assert_contains "$out" "unregistered" "human output omitted unregistered work"
  assert_contains "$out" "Catalog:" "human output omitted catalog evidence"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -le 10 ] \
    || fail "human inventory is not concise: $out"
  pass "human inventory is concise and highlights unregistered work"
}

test_inventory_json_and_read_only_git
test_refresh_reobserves_and_catalog_is_shared
test_missing_and_ambiguous_default_base
test_bounded_concurrent_writer_failure_is_atomic
test_invalid_lock_timeout_env_diagnoses_cleanly
test_human_output_is_concise
