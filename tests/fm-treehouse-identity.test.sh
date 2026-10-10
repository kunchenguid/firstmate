#!/usr/bin/env bash
# Registered Treehouse path identity through the protected teardown interface.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity test test@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-treehouse-identity)

make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" "$dir/pool-store/1"
  git init -q -b main "$dir/project"
  git -C "$dir/project" commit -qm baseline --allow-empty
  git -C "$dir/project" worktree add -qb fm/identity-task "$dir/pool-store/1/project"
  ln -s pool-store "$dir/pool-link"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool-link/1/project" > "$dir/pool-store/treehouse-state.json"
  fm_write_meta "$dir/home/state/identity-task.meta" \
    'window=isolated:fm-identity-task' 'endpoint_task_id=identity-task' \
    "worktree=$dir/pool-store/1/project" "project=$dir/project" \
    'kind=ship' 'mode=local-only' 'spawn_gen=identity-generation'
  {
    printf 'task=identity-task\nhome=%s\n' "$dir/home"
    [ "${2:-modern}" = legacy ] || printf 'spawn_gen=identity-generation\n'
  } > "$dir/pool-store/1/.fm-slot-owner"
  mkdir -p "$dir/pool-store/1/project/.claude"
  printf 'hook sentinel\n' > "$dir/pool-store/1/project/.claude/settings.local.json"
  printf '.claude/\n' >> "$dir/project/.git/info/exclude"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_IDENTITY_CASE:?}/treehouse.log"
if [ "${3:-}" != "${FM_IDENTITY_CASE:?}/pool-link/1/project" ]; then
  echo 'Worktree is not managed by treehouse' >&2
  exit 1
fi
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_IDENTITY_CASE:?}/no-mistakes.log"
exit 0
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'count: 0 (showing first 0)\npull_requests[]: []\n'
SH
  chmod +x "$dir/fakebin/"*
  printf '%s\n' "$dir"
}

run_case() {
  local dir=$1
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
    FM_IDENTITY_CASE="$dir" PATH="$dir/fakebin:$PATH" \
    bash "$ROOT/bin/fm-teardown.sh" identity-task > "$dir/stdout" 2> "$dir/stderr"
}

test_completed_legacy_record_returns_registered_spelling() {
  local dir
  dir=$(make_case legacy-completed legacy)
  printf 'done: completed synthetic work\n' > "$dir/home/state/identity-task.status"
  cp "$dir/pool-store/1/.fm-slot-owner" "$dir/legacy-claim"
  run_case "$dir" || fail "completed legacy slot teardown failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/identity-task.meta" 'legacy return retained task metadata'
  assert_equals 1 "$(wc -l < "$dir/treehouse.log" | tr -d ' ')" 'legacy return invoked the allocator more than once'
  assert_grep "return --force $dir/pool-link/1/project" "$dir/treehouse.log" 'legacy return changed the registered spelling'
  assert_no_grep '^spawn_gen=' "$dir/legacy-claim" 'legacy fixture fabricated a generation'
  pass 'completed legacy physical record returns by its unique registered spelling without a claim generation'
}

test_state_override_uses_actual_owning_home() {
  local dir kind
  for kind in modern legacy; do
    dir=$(make_case "state-override-$kind" "$kind")
    mkdir -p "$dir/runtime"
    mv "$dir/home/state" "$dir/runtime/state"
    mkdir "$dir/home/state"
    FM_STATE_OVERRIDE="$dir/runtime/state" run_case "$dir" \
      || fail "$kind state override rejected its actual home: $(cat "$dir/stderr")"
    assert_absent "$dir/runtime/state/identity-task.meta" 'state override retained task metadata'
    assert_grep "return --force $dir/pool-link/1/project" "$dir/treehouse.log" 'state override changed the registered spelling'
  done
  pass 'modern and legacy custody use the actual home with an external state directory'
}

test_descendant_alias_cleanup_uses_child_owning_home() {
  local dir home variant kind rc TMP_ROOT
  TMP_ROOT=$(TMPDIR=/tmp fm_test_tmproot fm-treehouse-descendant)
  for variant in modern legacy foreign-home; do
    kind=legacy
    [ "$variant" != modern ] || kind=modern
    dir=$(make_case "descendant-$variant" "$kind")
    home="$dir/mate"
    mkdir -p "$home/state" "$home/data" "$home/config"
    printf 'parent\n' > "$home/.fm-secondmate-home"
    mv "$dir/home/state/identity-task.meta" "$home/state/identity-task.meta"
    {
      printf 'task=identity-task\nhome=%s\n' "$home"
      [ "$kind" = legacy ] || printf 'spawn_gen=identity-generation\n'
    } > "$dir/pool-store/1/.fm-slot-owner"
    if [ "$variant" = foreign-home ]; then
      printf 'task=identity-task\nhome=%s\n' "$dir/home" > "$dir/pool-store/1/.fm-slot-owner"
    fi
    fm_write_meta "$dir/home/state/parent.meta" \
      'window=isolated:fm-parent' 'endpoint_task_id=parent' \
      "home=$home" "worktree=$home" "project=$home" \
      'kind=secondmate' 'mode=secondmate' 'harness=echo' 'yolo=off' 'spawn_gen=parent-generation'
    cp "$home/state/identity-task.meta" "$dir/child-before"
    cp "$dir/pool-store/1/.fm-slot-owner" "$dir/claim-before"
    rc=0
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
      FM_IDENTITY_CASE="$dir" PATH="$dir/fakebin:$PATH" \
      bash "$ROOT/bin/fm-teardown.sh" parent --force > "$dir/stdout" 2> "$dir/stderr" || rc=$?
    if [ "$variant" = foreign-home ]; then
      [ "$rc" -ne 0 ] || fail 'descendant accepted its parent home as child custody'
      assert_absent "$dir/treehouse.log" 'foreign descendant custody invoked the allocator'
      assert_absent "$dir/no-mistakes.log" 'foreign descendant custody killed an endpoint'
      cmp -s "$dir/child-before" "$home/state/identity-task.meta" || fail 'foreign descendant custody changed child metadata'
      cmp -s "$dir/claim-before" "$dir/pool-store/1/.fm-slot-owner" || fail 'foreign descendant custody changed its claim'
    else
      [ "$rc" -eq 0 ] || fail "$variant descendant cleanup failed: $(cat "$dir/stderr")"
      assert_absent "$dir/home/state/parent.meta" 'descendant cleanup retained parent metadata'
      assert_absent "$home" 'descendant cleanup retained its retired home'
      assert_absent "$dir/pool-store/1/.fm-slot-owner" 'descendant cleanup retained its spent claim'
      assert_grep "return --force $dir/pool-link/1/project" "$dir/treehouse.log" 'descendant cleanup changed the registered spelling'
    fi
  done
  pass 'descendant preflight, cleanup and return rechecks bind custody to the child owning home'
}

test_physical_record_returns_registered_spelling() {
  local dir
  dir=$(make_case physical)
  run_case "$dir" || fail "physical registered slot teardown failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/identity-task.meta" 'successful return retained task metadata'
  assert_grep "return --force $dir/pool-link/1/project" "$dir/treehouse.log" 'return did not use the exact registered spelling'
  pass 'physical recorded slot returns by its unique registered spelling'
}

assert_refused_before_slot_effects() {
  local dir=$1 label=$2 rc=0 before
  before=$(git -C "$dir/pool-store/1/project" rev-parse HEAD)
  cp "$dir/home/state/identity-task.meta" "$dir/meta-before"
  if [ -f "$dir/pool-store/1/.fm-slot-owner" ]; then
    cp "$dir/pool-store/1/.fm-slot-owner" "$dir/claim-before"
  fi
  run_case "$dir" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/identity-task.meta" "$label: task metadata removed"
  assert_present "$dir/pool-store/1/project/.claude/settings.local.json" "$label: hook removed"
  assert_absent "$dir/treehouse.log" "$label: allocator invoked"
  assert_absent "$dir/no-mistakes.log" "$label: pipeline touched before refusal"
  assert_equals "$before" "$(git -C "$dir/pool-store/1/project" rev-parse HEAD)" "$label: HEAD changed"
  assert_equals fm/identity-task "$(git -C "$dir/pool-store/1/project" symbolic-ref --short HEAD)" "$label: branch detached"
  cmp -s "$dir/meta-before" "$dir/home/state/identity-task.meta" || fail "$label: metadata changed"
  if [ -f "$dir/claim-before" ]; then
    cmp -s "$dir/claim-before" "$dir/pool-store/1/.fm-slot-owner" || fail "$label: claim changed"
  fi
}

test_registration_refusals_precede_effects() {
  local dir variant
  for variant in zero duplicate aliases malformed missing symlink leased lease-holder holder-zero invalid-lease unsafe; do
    dir=$(make_case "registration-$variant" legacy)
    case "$variant" in
      zero) printf '{"worktrees":[]}\n' > "$dir/pool-store/treehouse-state.json" ;;
      duplicate) jq '.worktrees += .worktrees' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"; mv "$dir/new-state" "$dir/pool-store/treehouse-state.json" ;;
      aliases)
        ln -s pool-store "$dir/pool-alias"
        jq --arg path "$dir/pool-alias/1/project" '.worktrees += [{name:"1",path:$path}]' \
          "$dir/pool-store/treehouse-state.json" > "$dir/new-state"
        mv "$dir/new-state" "$dir/pool-store/treehouse-state.json"
        ;;
      malformed) printf 'invalid-json\n' > "$dir/pool-store/treehouse-state.json" ;;
      missing) rm "$dir/pool-store/treehouse-state.json" ;;
      symlink) mv "$dir/pool-store/treehouse-state.json" "$dir/state-copy"; ln -s ../state-copy "$dir/pool-store/treehouse-state.json" ;;
      leased) jq '.worktrees[0].leased = true' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"; mv "$dir/new-state" "$dir/pool-store/treehouse-state.json" ;;
      lease-holder) jq '.worktrees[0].lease_holder = "another-holder"' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"; mv "$dir/new-state" "$dir/pool-store/treehouse-state.json" ;;
      holder-zero) jq '.worktrees[0].lease_holder = "0"' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"; mv "$dir/new-state" "$dir/pool-store/treehouse-state.json" ;;
      invalid-lease) jq '.worktrees[0].leased = "false"' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"; mv "$dir/new-state" "$dir/pool-store/treehouse-state.json" ;;
      unsafe) jq '.worktrees[0].path += "\n"' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"; mv "$dir/new-state" "$dir/pool-store/treehouse-state.json" ;;
    esac
    assert_refused_before_slot_effects "$dir" "$variant"
  done
  pass 'zero, duplicate, aliased, unsafe, unreadable and leased registrations refuse before slot effects'
}

test_custody_refusals_precede_effects() {
  local dir variant
  for variant in absent generation empty-generation duplicate-generation malformed-generation foreign-home legacy-foreign-home missing-home duplicate-home duplicate unknown symlink metadata-generation legacy-metadata-generation; do
    dir=$(make_case "custody-$variant")
    case "$variant" in
      absent) rm "$dir/pool-store/1/.fm-slot-owner" ;;
      generation) printf 'spawn_gen=replacement-generation\n' > "$dir/claim"; sed '/^spawn_gen=/d' "$dir/pool-store/1/.fm-slot-owner" >> "$dir/claim"; mv "$dir/claim" "$dir/pool-store/1/.fm-slot-owner" ;;
      empty-generation) sed 's/^spawn_gen=.*/spawn_gen=/' "$dir/pool-store/1/.fm-slot-owner" > "$dir/claim"; mv "$dir/claim" "$dir/pool-store/1/.fm-slot-owner" ;;
      duplicate-generation) printf 'spawn_gen=identity-generation\n' >> "$dir/pool-store/1/.fm-slot-owner" ;;
      malformed-generation) printf 'spawn_gen=bad token\n' > "$dir/claim"; sed '/^spawn_gen=/d' "$dir/pool-store/1/.fm-slot-owner" >> "$dir/claim"; mv "$dir/claim" "$dir/pool-store/1/.fm-slot-owner" ;;
      foreign-home) printf 'task=identity-task\nhome=%s\nspawn_gen=identity-generation\n' "$dir/project" > "$dir/pool-store/1/.fm-slot-owner" ;;
      legacy-foreign-home) printf 'task=identity-task\nhome=%s\n' "$dir/project" > "$dir/pool-store/1/.fm-slot-owner" ;;
      missing-home) printf 'task=identity-task\n' > "$dir/pool-store/1/.fm-slot-owner" ;;
      duplicate-home) printf 'home=%s\n' "$dir/home" >> "$dir/pool-store/1/.fm-slot-owner" ;;
      duplicate) printf 'task=identity-task\n' >> "$dir/pool-store/1/.fm-slot-owner" ;;
      unknown) printf 'task=identity-task\nhome=%s\nunknown=value\n' "$dir/home" > "$dir/pool-store/1/.fm-slot-owner" ;;
      symlink) mv "$dir/pool-store/1/.fm-slot-owner" "$dir/claim"; ln -s ../../claim "$dir/pool-store/1/.fm-slot-owner" ;;
      metadata-generation) printf 'spawn_gen=replacement-generation\n' >> "$dir/home/state/identity-task.meta" ;;
      legacy-metadata-generation) printf 'task=identity-task\nhome=%s\n' "$dir/home" > "$dir/pool-store/1/.fm-slot-owner"; printf 'spawn_gen=replacement-generation\n' >> "$dir/home/state/identity-task.meta" ;;
    esac
    assert_refused_before_slot_effects "$dir" "$variant"
  done
  pass 'missing, ambiguous, foreign and stale incarnation custody refuses before slot effects'
}

test_registration_refusal_preserves_live_process() {
  local dir worker rc=0 alive=0
  dir=$(make_case live-refusal legacy)
  printf '{"worktrees":[]}\n' > "$dir/pool-store/treehouse-state.json"
  ( cd "$dir/pool-store/1/project" && exec sleep 30 ) &
  worker=$!
  ( assert_refused_before_slot_effects "$dir" 'live process registration refusal' ) || rc=$?
  kill -0 "$worker" 2>/dev/null && alive=1
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  [ "$rc" -eq 0 ] && [ "$alive" -eq 1 ] || fail 'registration refusal reaped its task process'
  pass 'failed registration validation preserves the live task process'
}

test_git_identity_refusals_precede_effects() {
  local dir git_dir
  dir=$(make_case git-common legacy)
  git init -q -b main "$dir/unrelated"
  git -C "$dir/unrelated" commit -qm unrelated --allow-empty
  git -C "$dir/unrelated" worktree add -qb fm/identity-task "$dir/unrelated-slot"
  cp "$dir/unrelated-slot/.git" "$dir/pool-store/1/project/.git"
  assert_refused_before_slot_effects "$dir" 'Git common directory mismatch'
  dir=$(make_case git-marker-symlink legacy)
  git_dir="$dir/pool-store/1/project/.git"
  mv "$git_dir" "$dir/git-marker"
  ln -s "$dir/git-marker" "$git_dir"
  assert_refused_before_slot_effects "$dir" 'symlink Git marker'
  pass 'Git common-directory mismatch and unsafe Git marker refuse before slot effects'
}

test_exact_registered_path_retains_legacy_success() {
  local dir
  dir=$(make_case exact)
  sed "s@pool-store/1/project@pool-link/1/project@" "$dir/home/state/identity-task.meta" > "$dir/meta"
  mv "$dir/meta" "$dir/home/state/identity-task.meta"
  rm "$dir/pool-store/1/.fm-slot-owner"
  run_case "$dir" || fail "exact registered path failed: $(cat "$dir/stderr")"
  assert_grep "return --force $dir/pool-link/1/project" "$dir/treehouse.log" 'exact registered path changed'
  pass 'existing exact registered path success remains without a new claim'
}

test_exact_registered_path_refuses_malformed_legacy_claims() {
  local dir variant
  for variant in empty-home missing-home invalid-task; do
    dir=$(make_case "exact-claim-$variant" legacy)
    sed 's@pool-store/1/project@pool-link/1/project@' "$dir/home/state/identity-task.meta" > "$dir/meta"
    mv "$dir/meta" "$dir/home/state/identity-task.meta"
    case "$variant" in
      empty-home) printf 'task=identity-task\nhome=\n' > "$dir/pool-store/1/.fm-slot-owner" ;;
      missing-home) printf 'task=identity-task\n' > "$dir/pool-store/1/.fm-slot-owner" ;;
      invalid-task) printf 'task=successor/invalid\nhome=%s\n' "$dir/home" > "$dir/pool-store/1/.fm-slot-owner" ;;
    esac
    assert_refused_before_slot_effects "$dir" "$variant"
    assert_grep 'claim that cannot be read' "$dir/stderr" "$variant: malformed claim was not reported"
  done
  pass 'exact registered paths refuse empty or missing homes and invalid task tokens in legacy claims'
}

test_symlink_record_requires_claim_for_physical_registration() {
  local dir
  dir=$(make_case symlink-record legacy)
  sed 's@pool-store/1/project@pool-link/1/project@' "$dir/home/state/identity-task.meta" > "$dir/meta"
  mv "$dir/meta" "$dir/home/state/identity-task.meta"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool-store/1/project" > "$dir/pool-store/treehouse-state.json"
  rm "$dir/pool-store/1/.fm-slot-owner"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_IDENTITY_CASE/treehouse.log"
[ "${3:-}" = "$FM_IDENTITY_CASE/pool-store/1/project" ]
SH
  cp "$dir/pool-store/treehouse-state.json" "$dir/state-before"
  assert_refused_before_slot_effects "$dir" 'symlink record without custody'
  cmp -s "$dir/state-before" "$dir/pool-store/treehouse-state.json" || fail 'symlink refusal changed pool state'
  assert_absent "$dir/pool-store/1/.fm-slot-owner" 'symlink refusal manufactured custody'
  assert_grep 'custody claim' "$dir/stderr" 'symlink refusal did not require custody'
  pass 'a symlinked record cannot use claim-free authority for a physical registration'
}

test_native_state_fields_are_decodable() {
  local dir registered fields target
  dir=$(make_case native-fields legacy)
  registered="$dir/pool-link/1/project"
  printf '{"worktrees":[{"path":"%s","name":"1","leased":false,"lease_holder":"","created_at":"2024-02-29T12:34:56.123456789+08:00","destroying":false,"owner_pid":2147483647,"owner_started_at":9223372036854775807,"lease_id":"","leased_at":"0001-01-01T00:00:00Z"}]}\n' \
    "$registered" > "$dir/pool-store/treehouse-state.json"
  assert_equals "$registered" "$(FM_HOME="$dir/home" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_registered_path "$2" "$3"' \
    _ "$ROOT" "$dir/project" "$dir/pool-store/1/project")" 'valid native fields did not resolve'
  for target in selected unrelated; do
    while IFS= read -r fields; do
      if [ "$target" = selected ]; then
        printf '{"worktrees":[{"path":"%s",%s}]}\n' "$registered" "$fields" > "$dir/pool-store/treehouse-state.json"
      else
        printf '{"worktrees":[{"path":"%s"},{"path":"%s",%s}]}\n' \
          "$registered" "$dir/pool-link/2/project" "$fields" > "$dir/pool-store/treehouse-state.json"
      fi
      cp "$dir/pool-store/treehouse-state.json" "$dir/state-before"
      if registered=$(FM_HOME="$dir/home" bash -c \
        '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_registered_path "$2" "$3"' \
        _ "$ROOT" "$dir/project" "$dir/pool-store/1/project"); then
        fail "resolver accepted undecodable $target native field $fields"
      fi
      assert_equals '' "$registered" 'invalid native fields emitted registration evidence'
      cmp -s "$dir/state-before" "$dir/pool-store/treehouse-state.json" || fail 'resolver changed invalid native state'
      registered="$dir/pool-link/1/project"
    done <<'JSON'
"created_at":"not-a-time"
"name":7
"created_at":"2026-02-30T00:00:00Z"
"created_at":true
"destroying":"false"
"owner_pid":1.5
"owner_pid":2147483648
"owner_started_at":9223372036854775808
"owner_started_at":"1"
"owner_started_at":1.0
"owner_started_at":1e0
"lease_id":[]
"leased_at":"2026-01-01T25:00:00Z"
"lease_holder":0
JSON
  done
  dir=$(make_case invalid-native-timestamp legacy)
  jq '.worktrees[0].created_at = "not-a-time"' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"
  mv "$dir/new-state" "$dir/pool-store/treehouse-state.json"
  cp "$dir/pool-store/treehouse-state.json" "$dir/state-before"
  assert_refused_before_slot_effects "$dir" 'undecodable native timestamp'
  cmp -s "$dir/state-before" "$dir/pool-store/treehouse-state.json" || fail 'timestamp refusal changed pool state'
  pass 'undecodable native fields in selected and unrelated entries refuse without allocator recovery'
}

test_return_refuses_lease_created_after_preflight() {
  local dir rc=0 head
  dir=$(make_case lease-after-preflight legacy)
  head=$(git -C "$dir/pool-store/1/project" rev-parse HEAD)
  cp "$dir/home/state/identity-task.meta" "$dir/meta-before"
  cp "$dir/pool-store/1/.fm-slot-owner" "$dir/claim-before"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
jq '.worktrees[0] += {leased:true,lease_holder:"secondmate"}' "$FM_IDENTITY_CASE/pool-store/treehouse-state.json" > "$FM_IDENTITY_CASE/new-state"
mv "$FM_IDENTITY_CASE/new-state" "$FM_IDENTITY_CASE/pool-store/treehouse-state.json"
touch "$FM_IDENTITY_CASE/lease-created"
SH
  run_case "$dir" || rc=$?
  [ "$rc" -ne 0 ] || fail 'cleanup returned a slot leased after preflight'
  assert_present "$dir/lease-created" 'fixture did not introduce a lease after preflight'
  assert_absent "$dir/treehouse.log" 'cleanup invoked the allocator after a new lease'
  assert_equals true "$(jq -r '.worktrees[0].leased' "$dir/pool-store/treehouse-state.json")" 'cleanup cleared the new lease'
  assert_equals secondmate "$(jq -r '.worktrees[0].lease_holder' "$dir/pool-store/treehouse-state.json")" 'cleanup changed the new lease holder'
  assert_equals "$head" "$(git -C "$dir/pool-store/1/project" rev-parse HEAD)" 'lease refusal changed HEAD'
  cmp -s "$dir/meta-before" "$dir/home/state/identity-task.meta" || fail 'lease refusal changed task metadata'
  cmp -s "$dir/claim-before" "$dir/pool-store/1/.fm-slot-owner" || fail 'lease refusal changed custody'
  assert_grep 'unleased Treehouse registration' "$dir/stderr" 'return did not explain its new-lease refusal'
  pass 'return revalidation preserves a durable lease created after preflight'
}

test_dirty_and_unlanded_work_remains() {
  local dir variant
  for variant in dirty unlanded; do
    dir=$(make_case "$variant" legacy)
    if [ "$variant" = dirty ]; then
      printf 'keep\n' > "$dir/pool-store/1/project/untracked"
    else
      git -C "$dir/pool-store/1/project" commit -qm unlanded --allow-empty
    fi
    assert_refused_before_slot_effects "$dir" "$variant"
  done
  pass 'registered identity resolution preserves dirty and unlanded work refusals'
}

test_reassignment_precedes_identity_resolution() {
  local dir rc=0 worker
  dir=$(make_case reassigned legacy)
  printf 'task=successor\nhome=%s\n' "$dir/home" > "$dir/pool-store/1/.fm-slot-owner"
  fm_write_meta "$dir/home/state/successor.meta" \
    'window=isolated:fm-successor' 'endpoint_task_id=successor' \
    "worktree=$dir/pool-store/1/project" "project=$dir/project" 'kind=ship'
  fm_write_meta "$dir/home/state/stale-copy.meta" \
    'window=isolated:fm-stale-copy' 'endpoint_task_id=stale-copy' \
    "worktree=$dir/pool-store/1/project" "project=$dir/project" 'kind=ship'
  cp "$dir/pool-store/1/.fm-slot-owner" "$dir/successor-claim-before"
  printf 'dirty successor data\n' > "$dir/pool-store/1/project/successor-data"
  # Even an ambiguous allocator entry cannot turn a predecessor into the owner.
  jq '.worktrees += .worktrees' "$dir/pool-store/treehouse-state.json" > "$dir/new-state"
  mv "$dir/new-state" "$dir/pool-store/treehouse-state.json"
  ( cd "$dir/pool-store/1/project" && exec sleep 120 ) &
  worker=$!
  run_case "$dir" || rc=$?
  if ! kill -0 "$worker" 2>/dev/null; then
    fail 'predecessor cleanup killed the successor process'
  fi
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "records-only reassigned cleanup failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/identity-task.meta" 'predecessor record retained'
  assert_present "$dir/home/state/successor.meta" 'successor record removed'
  assert_present "$dir/home/state/stale-copy.meta" 'another predecessor record removed'
  assert_present "$dir/pool-store/1/project/successor-data" 'successor data removed'
  assert_present "$dir/pool-store/1/project/.claude/settings.local.json" 'successor hook removed'
  assert_grep task=successor "$dir/pool-store/1/.fm-slot-owner" 'successor custody changed'
  cmp -s "$dir/successor-claim-before" "$dir/pool-store/1/.fm-slot-owner" || fail 'predecessor changed successor custody bytes'
  assert_absent "$dir/treehouse.log" 'predecessor returned successor slot'
  assert_equals fm/identity-task "$(git -C "$dir/pool-store/1/project" symbolic-ref --short HEAD)" 'predecessor detached successor branch'
  pass 'reassigned predecessor takes records-only cleanup before registered identity resolution'
}

test_return_retry_rechecks_original_record_custody() {
  local dir rc=0
  dir=$(make_case retry-custody)
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_IDENTITY_CASE/treehouse.log"
if [ "$(wc -l < "$FM_IDENTITY_CASE/treehouse.log")" -eq 1 ]; then
  rm "$FM_IDENTITY_CASE/pool-store/1/.fm-slot-owner"
  echo "fatal: Unable to create '/synthetic/index.lock': File exists" >&2
  exit 1
fi
SH
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 run_case "$dir" || rc=$?
  [ "$rc" -ne 0 ] || fail 'return retried after losing the physical record custody claim'
  assert_equals 1 "$(wc -l < "$dir/treehouse.log" | tr -d ' ')" 'lost custody reached a second allocator invocation'
  assert_present "$dir/home/state/identity-task.meta" 'lost custody removed the task record'
  assert_grep 'custody claim' "$dir/stderr" 'retry did not explain the custody refusal'
  pass 'allocator retry rechecks custody against the original physical record'
}

test_legacy_return_retry_refuses_changed_custody_or_registration() {
  local dir variant rc
  for variant in generation registration; do
    dir=$(make_case "legacy-retry-$variant" legacy)
    cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_IDENTITY_CASE/treehouse.log"
case "$FM_IDENTITY_RETRY_CHANGE" in
  generation)
    printf 'task=identity-task\nhome=%s\nspawn_gen=replacement-generation\n' "$FM_IDENTITY_CASE/home" > "$FM_IDENTITY_CASE/pool-store/1/.fm-slot-owner"
    ;;
  registration)
    jq '.worktrees += .worktrees' "$FM_IDENTITY_CASE/pool-store/treehouse-state.json" > "$FM_IDENTITY_CASE/new-state"
    mv "$FM_IDENTITY_CASE/new-state" "$FM_IDENTITY_CASE/pool-store/treehouse-state.json"
    ;;
esac
echo "fatal: Unable to create '/synthetic/index.lock': File exists" >&2
exit 1
SH
    rc=0
    FM_IDENTITY_RETRY_CHANGE="$variant" FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 run_case "$dir" || rc=$?
    [ "$rc" -ne 0 ] || fail "legacy retry accepted changed $variant"
    assert_equals 1 "$(wc -l < "$dir/treehouse.log" | tr -d ' ')" "changed $variant reached a second allocator invocation"
    assert_present "$dir/home/state/identity-task.meta" "changed $variant removed the task record"
  done
  pass 'legacy return retries refuse changed generations and registrations before another allocator invocation'
}

test_stale_lock_final_retry_rechecks_original_record_custody() {
  local dir variant lock rc real_git
  real_git=$(command -v git)
  for variant in unchanged lost-custody; do
    dir=$(make_case "final-retry-$variant" legacy)
    lock="$(git -C "$dir/pool-store/1/project" rev-parse --absolute-git-dir)/index.lock"
    cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${3:-}" = "$FM_IDENTITY_CASE/pool-link/1/project" ] || exit 90
printf '%s\n' "$*" >> "$FM_IDENTITY_CASE/treehouse.log"
if [ "$(wc -l < "$FM_IDENTITY_CASE/treehouse.log")" -eq 1 ]; then
  : > "$FM_IDENTITY_LOCK"
  echo "fatal: Unable to create '$FM_IDENTITY_LOCK': File exists" >&2
  exit 1
fi
SH
    cat > "$dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -C ] && [ "${3:-}" = status ] && [ "${4:-}" = --porcelain ] \
  && [ -f "$FM_IDENTITY_CASE/treehouse.log" ] && [ ! -e "$FM_IDENTITY_LOCK" ]; then
  touch "$FM_IDENTITY_CASE/safety-callback"
  if [ "$FM_IDENTITY_CHANGE" = lost-custody ]; then
    rm "$FM_IDENTITY_CASE/pool-store/1/.fm-slot-owner"
  fi
fi
exec "$FM_IDENTITY_REAL_GIT" "$@"
SH
    cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
    chmod +x "$dir/fakebin/"*
    rc=0
    FM_IDENTITY_REAL_GIT="$real_git" FM_IDENTITY_LOCK="$lock" FM_IDENTITY_CHANGE="$variant" \
      FM_TREEHOUSE_RETURN_LOCK_RETRIES=0 FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
      FM_STALE_WORKTREE_LOCK_AGE_SECS=0 run_case "$dir" || rc=$?
    assert_absent "$lock" 'final retry fixture did not remove the stale lock'
    assert_present "$dir/safety-callback" 'final retry fixture did not reach the safety callback'
    if [ "$variant" = lost-custody ]; then
      [ "$rc" -ne 0 ] || fail 'final retry accepted custody lost during the safety callback'
      assert_equals 1 "$(wc -l < "$dir/treehouse.log" | tr -d ' ')" 'lost custody reached the final allocator retry'
      assert_present "$dir/home/state/identity-task.meta" 'final retry custody refusal removed the task record'
      assert_grep 'custody claim' "$dir/stderr" 'final retry did not explain the custody refusal'
    else
      [ "$rc" -eq 0 ] || fail "unchanged final retry failed: $(cat "$dir/stderr")"
      assert_equals 2 "$(wc -l < "$dir/treehouse.log" | tr -d ' ')" 'unchanged custody did not reach the final allocator retry'
      assert_absent "$dir/home/state/identity-task.meta" 'successful final retry retained the task record'
    fi
  done
  pass 'final allocator retry rechecks original-record custody after the safety callback and allows unchanged custody'
}

test_safety_recovery_rechecks_lease_before_stale_lock_removal() {
  local dir variant lock rc real_git
  real_git=$(command -v git)
  for variant in unchanged new-lease; do
    dir=$(make_case "safety-recovery-$variant" legacy)
    lock="$(git -C "$dir/pool-store/1/project" rev-parse --absolute-git-dir)/index.lock"
    printf 'lock sentinel\n' > "$lock"
    cp "$lock" "$dir/lock-before"
    cp "$dir/home/state/identity-task.meta" "$dir/meta-before"
    cp "$dir/pool-store/1/.fm-slot-owner" "$dir/claim-before"
    cat > "$dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -C ] && [ "${3:-}" = status ] && [ "${4:-}" = --porcelain ] \
  && [ -e "$FM_IDENTITY_LOCK" ]; then
  touch "$FM_IDENTITY_CASE/safety-blocked"
  exit 128
fi
exec "$FM_IDENTITY_REAL_GIT" "$@"
SH
    cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -f "$FM_IDENTITY_CASE/safety-blocked" ]; then
  touch "$FM_IDENTITY_CASE/safety-waited"
  if [ "$FM_IDENTITY_CHANGE" = new-lease ]; then
    jq '.worktrees[0] += {leased:true,lease_holder:"secondmate"}' "$FM_IDENTITY_CASE/pool-store/treehouse-state.json" > "$FM_IDENTITY_CASE/new-state"
    mv "$FM_IDENTITY_CASE/new-state" "$FM_IDENTITY_CASE/pool-store/treehouse-state.json"
  fi
fi
SH
    cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
    chmod +x "$dir/fakebin/"*
    rc=0
    FM_IDENTITY_REAL_GIT="$real_git" FM_IDENTITY_LOCK="$lock" FM_IDENTITY_CHANGE="$variant" \
      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=0 \
      run_case "$dir" || rc=$?
    assert_present "$dir/safety-waited" 'safety recovery fixture did not enter its lock wait'
    if [ "$variant" = new-lease ]; then
      [ "$rc" -ne 0 ] || fail 'safety recovery accepted a lease created during its wait'
      cmp -s "$dir/lock-before" "$lock" || fail 'safety recovery removed or changed the newly leased slot lock'
      cmp -s "$dir/meta-before" "$dir/home/state/identity-task.meta" || fail 'safety recovery lease refusal changed the task record'
      cmp -s "$dir/claim-before" "$dir/pool-store/1/.fm-slot-owner" || fail 'safety recovery lease refusal changed custody'
      assert_present "$dir/pool-store/1/project/.claude/settings.local.json" 'safety recovery lease refusal removed the hook'
      assert_absent "$dir/treehouse.log" 'safety recovery lease refusal invoked the allocator'
      assert_absent "$dir/no-mistakes.log" 'safety recovery lease refusal killed an endpoint'
      assert_equals true "$(jq -r '.worktrees[0].leased' "$dir/pool-store/treehouse-state.json")" 'safety recovery cleared the new lease'
      assert_grep 'unleased Treehouse registration' "$dir/stderr" 'safety recovery did not explain the lease refusal'
    else
      [ "$rc" -eq 0 ] || fail "unchanged safety recovery failed: $(cat "$dir/stderr")"
      assert_absent "$lock" 'unchanged safety recovery retained the stale lock'
      assert_absent "$dir/home/state/identity-task.meta" 'successful safety recovery retained the task record'
      assert_equals 1 "$(wc -l < "$dir/treehouse.log" | tr -d ' ')" 'unchanged safety recovery did not return the slot once'
    fi
  done
  pass 'safety recovery preserves a slot lock leased during its wait and clears an unchanged stale lock'
}

test_installed_treehouse_registered_return() {
  fm_live_gate default-on FM_TREEHOUSE_IDENTITY_REAL treehouse || return 0
  local dir="$TMP_ROOT/installed" binary source state registered physical head
  local -a native_env
  binary=$(command -v treehouse)
  mkdir -p "$dir/source" "$dir/config" "$dir/cache" "$dir/tmp" "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  source="$dir/source"
  printf '#!/bin/sh\nexit 0\n' > "$dir/shell"
  chmod +x "$dir/shell"
  : > "$dir/config/git-empty"
  native_env=(env -i "PATH=$PATH" LANG=C LC_ALL=C "TMPDIR=$dir/tmp" \
    "XDG_CONFIG_HOME=$dir/config" "XDG_CACHE_HOME=$dir/cache" "XDG_STATE_HOME=$dir/state" \
    GIT_CONFIG_NOSYSTEM=1 "GIT_CONFIG_GLOBAL=$dir/config/git-empty" GIT_TERMINAL_PROMPT=0 \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
    TREEHOUSE_NO_UPDATE_CHECK=1 TREEHOUSE_VCS=git "SHELL=$dir/shell")
  "${native_env[@]}" git init -q -b main "$source"
  printf 'pool-store/\npool-link\n.lab-keep\n' > "$source/.gitignore"
  printf 'max_trees = 1\n' > "$source/treehouse.toml"
  "${native_env[@]}" git -C "$source" add .gitignore treehouse.toml
  "${native_env[@]}" git -C "$source" -c commit.gpgsign=false commit -qm baseline
  mkdir "$source/pool-store"
  ln -s pool-store "$source/pool-link"
  ( cd "$source" && "${native_env[@]}" "$binary" --root "$source/pool-link" get --no-fetch ) > "$dir/get.out" 2> "$dir/get.err"
  state=$(find "$source/pool-store" -name treehouse-state.json)
  [ -f "$state" ] || fail "installed Treehouse did not create one contained pool state"
  registered=$(jq -er '.worktrees | if length == 1 then .[0].path else error("expected one slot") end' "$state")
  case "$registered" in "$source/pool-link/"*) ;; *) fail 'installed Treehouse registered a path outside its fixture root' ;; esac
  physical=$(cd "$registered" && pwd -P)
  [ "$registered" -ef "$physical" ] && [ "$registered" != "$physical" ] || fail 'native fixture did not produce a same-directory alias'
  printf 'keep\n' > "$physical/.lab-keep"
  head=$(git -C "$physical" rev-parse HEAD)
  fm_write_meta "$dir/home/state/identity-task.meta" \
    'window=isolated:fm-identity-task' 'endpoint_task_id=identity-task' \
    "worktree=$physical" "project=$source" 'kind=ship' 'mode=local-only' 'spawn_gen=native-generation'
  printf 'task=identity-task\nhome=%s\n' "$dir/home" > "$(dirname "$physical")/.fm-slot-owner"
  for tool in tmux no-mistakes; do
    printf '#!/bin/sh\nexit 0\n' > "$dir/fakebin/$tool"
  done
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = return ] && [ "$2" = --force ] && [ "$#" = 3 ]
[ "$3" = "$FM_TREEHOUSE_EXPECTED" ] || exit 90
printf '%s\n' "$3" > "$FM_TREEHOUSE_RETURN_ARG"
exec "$FM_TREEHOUSE_REAL_BIN" --root "$FM_TREEHOUSE_LAB_ROOT" "$@"
SH
  chmod +x "$dir/fakebin/"*
  "${native_env[@]}" "PATH=$dir/fakebin:$PATH" "FM_HOME=$dir/home" "FM_ROOT_OVERRIDE=$ROOT" \
    FM_GATE_REFUSE_BYPASS=1 FM_TEARDOWN_GUARD_DONE=1 "FM_TREEHOUSE_REAL_BIN=$binary" \
    "FM_TREEHOUSE_LAB_ROOT=$source/pool-link" "FM_TREEHOUSE_EXPECTED=$registered" "FM_TREEHOUSE_RETURN_ARG=$dir/return-arg" \
    bash "$ROOT/bin/fm-teardown.sh" identity-task > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "installed Treehouse teardown refused the verified alias: $(cat "$dir/teardown.err")"
  assert_equals "$registered" "$(cat "$dir/return-arg")" 'native return argument changed'
  assert_absent "$dir/home/state/identity-task.meta" 'native teardown retained task metadata'
  assert_equals "$head" "$(git -C "$physical" rev-parse HEAD)" 'native return changed fixture HEAD'
  assert_equals '' "$(git -C "$physical" status --porcelain)" 'native return left dirt'
  assert_grep keep "$physical/.lab-keep" 'native return removed ignored sentinel'
  pass "installed Treehouse $("${native_env[@]}" "$binary" --root "$source/pool-link" --version): protected legacy physical-path teardown uses the registered alias"
}

test_registered_path_preserves_utf8_spelling() {
  local dir registered variant
  for variant in encoding-ascii encoding-café encoding-中文; do
    dir=$(make_case "$variant")
    registered=$(FM_STATE_OVERRIDE="$dir/home/state" bash -c \
      '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_registered_path "$2" "$3"' \
      _ "$ROOT" "$dir/project" "$dir/pool-store/1/project") \
      || fail "registered $variant path did not resolve"
    assert_equals "$dir/pool-link/1/project" "$registered" "registered $variant spelling changed"
  done
  pass 'registered ASCII, accented and Chinese path spellings remain exact'
}

test_registered_path_preserves_utf8_spelling
test_physical_record_returns_registered_spelling
test_completed_legacy_record_returns_registered_spelling
test_state_override_uses_actual_owning_home
test_descendant_alias_cleanup_uses_child_owning_home
test_registration_refusals_precede_effects
test_custody_refusals_precede_effects
test_registration_refusal_preserves_live_process
test_git_identity_refusals_precede_effects
test_exact_registered_path_retains_legacy_success
test_exact_registered_path_refuses_malformed_legacy_claims
test_symlink_record_requires_claim_for_physical_registration
test_native_state_fields_are_decodable
test_return_refuses_lease_created_after_preflight
test_dirty_and_unlanded_work_remains
test_reassignment_precedes_identity_resolution
test_return_retry_rechecks_original_record_custody
test_legacy_return_retry_refuses_changed_custody_or_registration
test_stale_lock_final_retry_rechecks_original_record_custody
test_safety_recovery_rechecks_lease_before_stale_lock_removal
test_installed_treehouse_registered_return
