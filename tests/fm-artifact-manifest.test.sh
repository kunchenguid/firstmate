#!/usr/bin/env bash
# Behavioral coverage for the artifact-first WorkerResult contract: the manifest
# writer/verifier, its refusal of transcripts and unsafe paths, and the
# parent-channel pair that points at a verified manifest.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$ROOT/bin/fm-artifact-manifest.sh"
RECON="$ROOT/bin/fm-inactive-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-artifact-manifest)
fm_git_identity fmtest fmtest@example.invalid

make_home() { # <home>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
}

run_manifest() { # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$MANIFEST" "$@"
}

run_report() { # <home> <child>
  local home=$1 child=$2
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$RECON" report "$child"
}

write_child() { # <home> <id> <status>
  local home=$1 id=$2 status=$3 sha
  mkdir -p "$home/projects/$id"
  git -C "$home/projects/$id" init -q
  git -C "$home/projects/$id" commit -q --allow-empty -m init
  sha=$(git -C "$home/projects/$id" rev-parse HEAD)
  git -C "$home/projects/$id" update-ref refs/remotes/origin/main "$sha"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=$home/projects/$id" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=s${BASHPID:-$$}.$RANDOM" 'pr=https://example.test/owner/repo/pull/1' \
    "pr_head=$sha"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

test_write_verify_and_ref_roundtrip() {
  local home="$TMP_ROOT/roundtrip" out ref
  make_home "$home"
  mkdir -p "$home/data/task"
  printf 'diff --git a/x b/x\n' > "$home/data/task/worker.patch"
  printf 'all tests passed\n' > "$home/data/task/test.log"
  printf '# findings\n' > "$home/data/task/report.md"

  out=$(run_manifest "$home" write --task task \
    --artifact patch=data/task/worker.patch \
    --artifact test-log=data/task/test.log \
    --artifact report=data/task/report.md) \
    || fail "manifest write failed"
  assert_equals "$home/data/task/artifacts.json" "$out" "write did not name its manifest"
  run_manifest "$home" verify --task task >/dev/null || fail "a fresh manifest did not verify"
  grep -Eq '"sha256": "[0-9a-f]{64}"' "$out" || fail "manifest has no full SHA-256"
  assert_contains "$(cat "$out")" '"kind": "patch"' "manifest dropped the patch entry"
  assert_contains "$(cat "$out")" '"kind": "test-log"' "manifest dropped the test-log entry"
  assert_contains "$(cat "$out")" '"kind": "report"' "manifest dropped the report entry"

  ref=$(run_manifest "$home" ref --task task) || fail "ref refused a verified manifest"
  assert_contains "$ref" 'artifacts=data/task/artifacts.json artifacts_sha256=' \
    "ref did not name the manifest and its digest"
  pass "manifest write, verify, and ref round-trip"
}

test_changed_artifact_fails_verification() {
  local home="$TMP_ROOT/changed" rc=0 err
  make_home "$home"
  mkdir -p "$home/data/task"
  printf 'original\n' > "$home/data/task/report.md"
  run_manifest "$home" write --task task --artifact report=data/task/report.md >/dev/null \
    || fail "manifest write failed"
  printf 'tampered\n' >> "$home/data/task/report.md"

  err="$TMP_ROOT/changed.err"
  run_manifest "$home" verify --task task >/dev/null 2> "$err" || rc=$?
  expect_code 5 "$rc" "changed artifact verification"
  assert_contains "$(cat "$err")" 'artifact hash mismatch: data/task/report.md' \
    "changed artifact did not name its hash mismatch"
  rc=0
  run_manifest "$home" ref --task task >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "ref published a manifest that no longer verifies"
  pass "a changed artifact fails verification and is not referenced"
}

test_transcript_kind_is_refused() {
  local home="$TMP_ROOT/transcript" rc=0 err
  make_home "$home"
  mkdir -p "$home/data/task"
  printf 'assistant: here is what I did\n' > "$home/data/task/chat.txt"

  err="$TMP_ROOT/transcript.err"
  run_manifest "$home" write --task task --artifact transcript=data/task/chat.txt \
    >/dev/null 2> "$err" || rc=$?
  expect_code 3 "$rc" "transcript kind"
  assert_absent "$home/data/task/artifacts.json" "a refused transcript still wrote a manifest"
  pass "a transcript is refused as a WorkerResult"
}

test_unsafe_paths_are_refused() {
  local home="$TMP_ROOT/unsafe" rc=0
  make_home "$home"
  mkdir -p "$home/data/task" "$home/data/other"
  printf 'x\n' > "$home/data/other/report.md"
  printf 'x\n' > "$home/data/task/real.md"
  ln -s real.md "$home/data/task/link.md"

  rc=0
  run_manifest "$home" write --task task --artifact report=data/other/report.md >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "artifact outside the task directory"

  rc=0
  run_manifest "$home" write --task task --artifact report=data/task/../other/report.md >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "parent-traversal artifact"

  rc=0
  run_manifest "$home" write --task task --artifact report=data/task/link.md >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "symlinked artifact"
  assert_absent "$home/data/task/artifacts.json" "an unsafe path still wrote a manifest"
  pass "paths outside data/<task>/ or through a symlink are refused"
}

test_parent_channel_carries_artifact_pair() {
  local MAIN="$TMP_ROOT/local/main" MATE="$TMP_ROOT/local/mate" line ref
  mkdir -p "$MAIN" "$MATE"
  make_home "$MAIN"
  make_home "$MATE"
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  cat > "$MATE/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$MAIN
EOF
  write_child "$MATE" child 'done: report written'
  mkdir -p "$MATE/data/child"
  printf '# findings\n' > "$MATE/data/child/report.md"
  printf 'diff\n' > "$MATE/data/child/worker.patch"
  run_manifest "$MATE" write --task child \
    --artifact report=data/child/report.md \
    --artifact patch=data/child/worker.patch >/dev/null \
    || fail "manifest write failed for the local route"

  run_report "$MATE" child || fail "the local parent delivery failed"
  line=$(sed -n '/child child done/p' "$MAIN/state/mate.status")
  [ -n "$line" ] || fail "the child outcome never reached the parent channel"
  assert_contains "$line" 'report=data/child/report.md' "the delivery lost its report pointer"
  ref=$(run_manifest "$MATE" ref --task child) || fail "ref refused the delivered manifest"
  assert_contains "$line" "$ref" "the delivery did not carry the exact artifact-lineage pair"
  pass "the local parent channel carries the manifest pointer and digest"
}

test_remote_route_omits_unreachable_artifact_pair() {
  local MAIN="$TMP_ROOT/remote/main" MATE="$TMP_ROOT/remote/mate" line
  mkdir -p "$MAIN" "$MATE"
  make_home "$MAIN"
  make_home "$MATE"
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  cat > "$MATE/.fm-secondmate-parent" <<'EOF'
schema=fm-secondmate-parent.v1
route=remote
EOF
  write_child "$MATE" child 'done: report written'
  mkdir -p "$MATE/data/child"
  printf '# findings\n' > "$MATE/data/child/report.md"
  run_manifest "$MATE" write --task child --artifact report=data/child/report.md >/dev/null \
    || fail "manifest write failed for the remote route"

  run_report "$MATE" child
  line=$(grep 'child child done' "$MATE/state/parent-replies.status" 2>/dev/null || true)
  [ -n "$line" ] || fail "the remote parent delivery never reached parent-replies.status"
  assert_contains "$line" 'report=data/child/report.md' "the remote delivery lost its report pointer"
  assert_not_contains "$line" 'artifacts=' \
    "the remote route published a manifest pointer its transport cannot fetch"
  pass "the remote route keeps the report pointer and omits the unfetchable manifest pair"
}

test_write_verify_and_ref_roundtrip
test_changed_artifact_fails_verification
test_transcript_kind_is_refused
test_unsafe_paths_are_refused
test_parent_channel_carries_artifact_pair
test_remote_route_omits_unreachable_artifact_pair

echo "all artifact manifest tests passed"
