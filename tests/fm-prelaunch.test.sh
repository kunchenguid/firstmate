#!/usr/bin/env bash
# Executable/process regression tests for bin/fm-prelaunch.sh and its native
# session-lock handoff.  Every home is a disposable standalone repository; no
# live Firstmate home, launcher, or lifecycle is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRELAUNCH="$ROOT/bin/fm-prelaunch.sh"
LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-prelaunch)
TOKEN_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TOKEN_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TOKEN_C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

fm_git_identity fmtest fmtest@example.invalid

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  cp "$ROOT/.gitignore" "$home/.gitignore"
  cp -R "$ROOT/bin/." "$home/bin/"
  printf 'initial\n' > "$home/version.txt"
  git init -q -b main "$home"
  git -C "$home" add .gitignore AGENTS.md bin version.txt
  git -C "$home" commit -qm initial
  git -C "$home" remote add origin https://example.invalid/firstmate.git
  printf '%s\n' "$home"
}

run_pre() {  # <home> <action-and-args...>
  local home=$1
  shift
  bash "$PRELAUNCH" "$@" --home "$home"
}

reserve_main() {  # <home> <token>
  run_pre "$1" reserve --owner-pid "$$" --token "$2"
}

release_main() {  # <home> <token>
  run_pre "$1" release --owner-pid "$$" --token "$2"
}

add_candidate() {  # <home> <content>
  local home=$1 content=$2
  printf '%s\n' "$content" > "$home/version.txt"
  git -C "$home" add version.txt
  git -C "$home" commit -qm "$content"
  git -C "$home" rev-parse HEAD
}

test_capabilities_are_read_only_and_explicit() {
  local home out before after harness fakebin
  home=$(new_home capabilities)
  fakebin="$TMP_ROOT/capabilities-bin"
  mkdir -p "$fakebin"
  fm_fake_version_tool "$fakebin" claude FM_FAKE_CLAUDE_VERSION '1.0.0 (Claude Code)'
  before=$(git -C "$home" status --porcelain)
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" run_pre "$home" capabilities) \
    || fail "capabilities refused a standalone primary: $out"
  after=$(git -C "$home" status --porcelain)
  [ "$before" = "$after" ] || fail "capabilities changed the checkout"
  printf '%s\n' "$out" | jq -e '
    .version == 1 and .status == "compatible"
    and .source_remote == "origin"
    and .source_ref == "refs/heads/main"
    and (.bundle_files | index("bin/fm-prelaunch.sh")) != null
    and (.profiles | length) > 0
    and ([.profiles[].harness_version] | all(type == "string" and length > 0))
    and ([.profiles[].argv_grammar] | all(.kind == "exact" and .args == [] and .session == "fresh-only"))
  ' >/dev/null || fail "capabilities JSON did not expose the v1 closure and fresh-only grammar: $out"
  [ ! -e "$home/state" ] || fail "read-only capabilities created state"
  harness=$(printf '%s\n' "$out" | jq -r '.profiles | keys[0]')
  out=$(PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$PRELAUNCH" profile --home "$home" --harness "$harness" --) \
    || fail "profile refused its advertised harness: $out"
  printf '%s\n' "$out" | jq -e --arg harness "$harness" '
    .version == 1 and .status == "fresh" and (.binary | startswith("/"))
    and (.harness_version | length) > 0 and .argv == []
  ' >/dev/null || fail "profile did not return the validated fresh invocation: $out"
  if PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$PRELAUNCH" profile --home "$home" --harness "$harness" -- --resume >/dev/null 2>&1; then
    fail "profile accepted a saved-session selector"
  fi
  pass "prelaunch: capabilities are read-only and expose a frozen closure plus exact fresh profiles"
}

test_profile_launch_env_matches_capabilities() {
  local home fakebin caps out harness expected
  home=$(new_home launch-env)
  fakebin="$TMP_ROOT/launch-env-bin"
  mkdir -p "$fakebin"
  fm_fake_version_tool "$fakebin" claude FM_FAKE_CLAUDE_VERSION '1.0.0 (Claude Code)'
  fm_fake_version_tool "$fakebin" pi-signed FM_FAKE_PI_SIGNED_VERSION 'pi-signed 1.0.0'
  fm_fake_version_tool "$fakebin" omp FM_FAKE_OMP_VERSION 'omp 1.0.0'
  caps=$(FM_PI_HARNESS=forged FM_OMP_HARNESS=forged PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    run_pre "$home" capabilities) || fail "capabilities refused the launch-env fixture: $caps"
  for harness in claude pi-signed omp; do
    case "$harness" in
      pi-signed) expected='{"FM_PI_HARNESS":"pi-signed"}' ;;
      omp) expected='{"FM_OMP_HARNESS":"omp"}' ;;
      *) expected='{}' ;;
    esac
    out=$(FM_PI_HARNESS=forged FM_OMP_HARNESS=forged PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
      bash "$PRELAUNCH" profile --home "$home" --harness "$harness" --) \
      || fail "profile refused advertised harness $harness: $out"
    jq -en --argjson caps "$caps" --argjson out "$out" --argjson expected "$expected" --arg h "$harness" '
      $out.status == "fresh"
      and $caps.profiles[$h].launch_env == $expected
      and $out.launch_env == $expected
    ' >/dev/null || fail "profile launch_env for $harness diverged from capabilities or its allowlist: $out"
  done
  pass "prelaunch: profile launch_env equals the advertised allowlisted capability object"
}

test_strict_inventory_errors_refuse_reservation() {
  local home out
  home=$(new_home dangling-inventory)
  mkdir -p "$home/state"
  ln -s "$TMP_ROOT/missing-meta-target" "$home/state/w1.meta"
  if reserve_main "$home" "$TOKEN_A" >/dev/null 2>&1; then
    fail "a dangling fleet metadata symlink was treated as a proven idle home"
  fi
  [ ! -e "$home/state/.prelaunch-reservation" ] \
    || fail "an unreadable inventory left a reservation behind"
  rm -f "$home/state/w1.meta"
  mkdir -p "$home/state/procevent"
  ln -s "$TMP_ROOT/missing-source-target" "$home/state/procevent/w1.source"
  if reserve_main "$home" "$TOKEN_A" >/dev/null 2>&1; then
    fail "a dangling procevent source symlink was treated as a proven idle home"
  fi
  rm -f "$home/state/procevent/w1.source"
  out=$(reserve_main "$home" "$TOKEN_A") || fail "a clean inventory refused reservation: $out"
  release_main "$home" "$TOKEN_A" >/dev/null || fail "release of the clean inventory reservation failed"
  pass "prelaunch: unsafe fleet inventories fail the strict idleness proof"
}

test_guard_write_admits_ineligible_unreserved_primaries() {
  local home base linked out
  home=$(new_home no-origin)
  git -C "$home" remote remove origin
  out=$(run_pre "$home" guard-write) || fail "guard-write refused an unreserved home without origin: $out"
  assert_contains "$out" '"status":"clear"' "an ineligible unreserved home should stay clear"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-update.sh" 2>&1) \
    || fail "the explicit updater refused an unreserved home without origin: $out"
  mkdir -p "$TMP_ROOT/outside-data"
  ln -s "$TMP_ROOT/outside-data" "$home/data"
  out=$(run_pre "$home" guard-write) || fail "guard-write refused an unreserved home with symlinked data: $out"
  assert_contains "$out" '"status":"clear"' "a symlinked data home without a reservation should stay clear"
  mkdir -p "$home/state"
  printf 'not-a-reservation\n' > "$home/state/.prelaunch-reservation"
  if run_pre "$home" guard-write >/dev/null 2>&1; then
    fail "an ineligible home with a reservation record failed open for a writer"
  fi
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-update.sh" >/dev/null 2>&1; then
    fail "the explicit updater crossed an ambiguous reservation on an ineligible home"
  fi
  base=$(new_home guard-linked-base)
  linked="$TMP_ROOT/guard-linked-worker"
  git -C "$base" worktree add -q --detach "$linked" HEAD
  out=$(run_pre "$linked" guard-write) || fail "guard-write refused an unreserved linked worktree: $out"
  assert_contains "$out" '"status":"clear"' "an unreserved linked worktree should stay clear"
  pass "prelaunch: guard-write refuses only reservations, not enrollment-ineligible primaries"
}

test_attached_child_survives_parent_death_as_occupancy() {
  local home ready info stop launcher child owner clear=0 fakebin result
  home=$(new_home parent-death)
  fakebin="$TMP_ROOT/parent-death-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"
  ready="$TMP_ROOT/parent-death.ready"
  info="$TMP_ROOT/parent-death.info"
  stop="$TMP_ROOT/parent-death.stop"
  result="$TMP_ROOT/parent-death.result"
  bash -c '
    pre=$1; home=$2; token=$3; ready=$4; info=$5; stop=$6; harness=$7; lock=$8; lib=$9; result=${10}
    owner=$$
    head=$(git -C "$home" rev-parse HEAD) || exit 1
    bash "$pre" reserve --home "$home" --owner-pid "$owner" --token "$token" >/dev/null || exit 2
    bash "$pre" update --home "$home" --owner-pid "$owner" --token "$token" --commit "$head" >/dev/null || exit 3
    (
      n=0
      while [ ! -e "$stop" ] && [ "$n" -lt 500 ]; do sleep 0.02; n=$((n + 1)); done
      exec env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_PRELAUNCH_OWNER_PID="$owner" \
        FM_PRELAUNCH_TOKEN="$token" "$harness" -c '\''
          "$1" > "$6.lock" 2>&1 || exit 1
          . "$2"
          if fm_prelaunch_handoff_authenticated "$3/state" "$3" "$4" "$5"; then
            printf "verified\n" > "$6"
          else
            printf "refused\n" > "$6"
            exit 2
          fi
        '\'' _ "$lock" "$lib" "$home" "$owner" "$token" "$result"
    ) &
    child=$!
    bash "$pre" attach --home "$home" --owner-pid "$owner" --token "$token" --child-pid "$child" >/dev/null || exit 4
    printf "%s %s\n" "$owner" "$child" > "$info"
    : > "$ready"
    wait "$child"
  ' _ "$PRELAUNCH" "$home" "$TOKEN_A" "$ready" "$info" "$stop" \
    "$fakebin/codex" "$LOCK" "$ROOT/bin/fm-session-lock-lib.sh" "$result" &
  launcher=$!
  for _ in $(seq 1 250); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || fail "attached-child parent-death fixture did not become ready"
  read -r owner child < "$info"
  kill -TERM "$launcher"
  wait "$launcher" 2>/dev/null || true
  kill -0 "$child" 2>/dev/null || fail "the attached child did not outlive its launcher"
  if run_pre "$home" guard-write >/dev/null 2>&1; then
    fail "parent death opened a write window while the attached child lived"
  fi
  if run_pre "$home" release --owner-pid "$owner" --token "$TOKEN_A" >/dev/null 2>&1; then
    fail "an unrelated process released a live attached child after parent death"
  fi
  : > "$stop"
  for _ in $(seq 1 250); do
    if [ -e "$result" ] && run_pre "$home" guard-write >/dev/null 2>&1; then clear=1; break; fi
    sleep 0.02
  done
  [ "$(cat "$result" 2>/dev/null || true)" = verified ] \
    || fail "the attached child could not authenticate its handoff after launcher death"
  [ -f "$home/state/.prelaunch-handoff" ] \
    || fail "parent-death handoff did not publish its receipt"
  [ "$clear" -eq 1 ] || fail "dead parent and child did not become reclaimable"
  pass "prelaunch: attached child keeps occupancy and completes verified handoff after launcher death"
}

test_reservation_validation_guard_and_release() {
  local home out
  home=$(new_home reservation)
  out=$(reserve_main "$home" "$TOKEN_A") || fail "reserve failed: $out"
  assert_contains "$out" '"status":"reserved"' "reserve should report its status"
  [ -f "$home/state/.prelaunch-reservation" ] || fail "reserve did not publish its record"
  out=$(run_pre "$home" validate --owner-pid "$$" --token "$TOKEN_A") \
    || fail "validate refused the owner: $out"
  assert_contains "$out" '"status":"valid"' "validate should authenticate the owner"
  if run_pre "$home" guard-write >/dev/null 2>&1; then
    fail "an unauthenticated writer crossed a live reservation"
  fi
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-update.sh" >/dev/null 2>&1; then
    fail "the explicit source updater crossed a live reservation"
  fi
  out=$(run_pre "$home" guard-write --owner-pid "$$" --token "$TOKEN_A") \
    || fail "the authenticated writer was refused: $out"
  assert_contains "$out" '"status":"owned"' "the authenticated guard should report owned"
  if run_pre "$home" validate --owner-pid "$$" --token "$TOKEN_B" >/dev/null 2>&1; then
    fail "a forged token authenticated the reservation"
  fi
  out=$(release_main "$home" "$TOKEN_A") || fail "release refused the owner: $out"
  assert_contains "$out" '"status":"released"' "release should report release"
  [ ! -e "$home/state/.prelaunch-reservation" ] || fail "release left the reservation"
  out=$(run_pre "$home" guard-write) || fail "a clear home refused an explicit writer: $out"
  assert_contains "$out" '"status":"clear"' "an unreserved guard should preserve explicit authority"
  pass "prelaunch: reservation validation, write guard, token binding and release are enforced"
}

test_pinned_update_preflight_and_no_candidate_execution() {
  local home base candidate out hook
  home=$(new_home update)
  base=$(git -C "$home" rev-parse HEAD)
  candidate=$(add_candidate "$home" candidate)
  git -C "$home" reset -q --hard "$base"
  hook="$home/hook-ran"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'touch %q\n' "$hook"
  } > "$home/.git/hooks/post-merge"
  chmod +x "$home/.git/hooks/post-merge"

  reserve_main "$home" "$TOKEN_A" >/dev/null || fail "update fixture reserve failed"
  out=$(run_pre "$home" check-update --owner-pid "$$" --token "$TOKEN_A" --commit "$candidate") \
    || fail "check-update refused a safe descendant: $out"
  printf '%s\n' "$out" | jq -e --arg candidate "$candidate" '
    .version == 1 and .status == "updated" and .source_head == $candidate
    and .changed == true
    and (keys | sort) == ["changed", "home", "source_head", "status", "version"]
  ' >/dev/null || fail "preflight did not return the exact pinned-commit projection: $out"
  [ "$(git -C "$home" rev-parse HEAD)" = "$base" ] || fail "check-update moved HEAD"

  out=$(run_pre "$home" update --owner-pid "$$" --token "$TOKEN_A" --commit "$candidate") \
    || fail "pinned update failed: $out"
  assert_contains "$out" '"status":"updated"' "update should report the advance"
  assert_contains "$out" '"changed":true' "a documentation-sized SHA advance must count as changed"
  [ "$(git -C "$home" rev-parse HEAD)" = "$candidate" ] || fail "update missed the pinned commit"
  [ ! -e "$hook" ] || fail "candidate movement executed a post-merge hook"
  release_main "$home" "$TOKEN_A" >/dev/null || fail "updated reservation did not release"

  reserve_main "$home" "$TOKEN_B" >/dev/null || fail "current fixture reserve failed"
  out=$(run_pre "$home" check-update --owner-pid "$$" --token "$TOKEN_B" --commit "$candidate") \
    || fail "current preflight failed: $out"
  printf '%s\n' "$out" | jq -e --arg candidate "$candidate" '
    .version == 1 and .status == "current" and .source_head == $candidate
    and .changed == false
    and (keys | sort) == ["changed", "home", "source_head", "status", "version"]
  ' >/dev/null || fail "current preflight did not return the exact pinned-commit projection: $out"
  out=$(run_pre "$home" update --owner-pid "$$" --token "$TOKEN_B" --commit "$candidate") \
    || fail "current update failed: $out"
  assert_contains "$out" '"status":"current"' "same-SHA update should be current"
  assert_contains "$out" '"changed":false' "same-SHA update should be unchanged"
  release_main "$home" "$TOKEN_B" >/dev/null || fail "current reservation did not release"
  pass "prelaunch: pinned preflight/update are local-only, count SHA movement, and disable Git hooks"
}

test_filter_dirty_branch_and_divergence_refuse_without_mutation() {
  local home base filter_candidate head
  home=$(new_home update-refusals)
  base=$(git -C "$home" rev-parse HEAD)
  printf '*.txt filter=untrusted\n' > "$home/.gitattributes"
  printf 'candidate\n' > "$home/filtered.txt"
  git -C "$home" add .gitattributes filtered.txt
  git -C "$home" commit -qm filtered-candidate
  filter_candidate=$(git -C "$home" rev-parse HEAD)
  git -C "$home" reset -q --hard "$base"

  reserve_main "$home" "$TOKEN_A" >/dev/null || fail "filter fixture reserve failed"
  if run_pre "$home" update --owner-pid "$$" --token "$TOKEN_A" --commit "$filter_candidate" >/dev/null 2>&1; then
    fail "a candidate-declared checkout filter was accepted"
  fi
  [ "$(git -C "$home" rev-parse HEAD)" = "$base" ] || fail "filter refusal moved HEAD"
  release_main "$home" "$TOKEN_A" >/dev/null || fail "filter fixture release failed"

  printf 'dirty\n' >> "$home/version.txt"
  reserve_main "$home" "$TOKEN_B" >/dev/null || fail "dirty fixture reserve failed"
  if run_pre "$home" update --owner-pid "$$" --token "$TOKEN_B" --commit "$filter_candidate" >/dev/null 2>&1; then
    fail "a dirty checkout was updated"
  fi
  [ "$(git -C "$home" rev-parse HEAD)" = "$base" ] || fail "dirty refusal moved HEAD"
  git -C "$home" checkout -q -- version.txt
  release_main "$home" "$TOKEN_B" >/dev/null || fail "dirty fixture release failed"

  git -C "$home" checkout -qb feature
  reserve_main "$home" "$TOKEN_C" >/dev/null || fail "wrong-branch fixture reserve failed"
  if run_pre "$home" update --owner-pid "$$" --token "$TOKEN_C" --commit "$filter_candidate" >/dev/null 2>&1; then
    fail "a non-default branch was updated"
  fi
  head=$(git -C "$home" rev-parse HEAD)
  [ "$head" = "$base" ] || fail "wrong-branch refusal moved HEAD"
  release_main "$home" "$TOKEN_C" >/dev/null || fail "wrong-branch fixture release failed"
  pass "prelaunch: filters, dirty state and wrong branches refuse without checkout mutation"
}

test_session_fleet_queue_and_unknown_state_refuse() {
  local home user_home
  home=$(new_home idle-refusals)
  mkdir -p "$home/state"
  printf 'kind=ship\n' > "$home/state/live.meta"
  if reserve_main "$home" "$TOKEN_A" >/dev/null 2>&1; then
    fail "active fleet metadata allowed a reservation"
  fi
  rm -f "$home/state/live.meta"
  printf '1\tsignal:test\n' > "$home/state/.wake-queue"
  if reserve_main "$home" "$TOKEN_A" >/dev/null 2>&1; then
    fail "a pending wake queue allowed a reservation"
  fi
  rm -f "$home/state/.wake-queue"
  printf '%s\n' "$$" > "$home/state/.lock"
  if reserve_main "$home" "$TOKEN_A" >/dev/null 2>&1; then
    fail "an unknown live session-lock owner allowed a reservation"
  fi
  rm -f "$home/state/.lock"
  ln -s "$home/state/missing-lock" "$home/state/.lock"
  if reserve_main "$home" "$TOKEN_A" >/dev/null 2>&1; then
    fail "a dangling session-lock symlink allowed a reservation"
  fi
  rm -f "$home/state/.lock"
  printf 'not-a-reservation\n' > "$home/state/.prelaunch-reservation"
  if run_pre "$home" guard-write >/dev/null 2>&1; then
    fail "a malformed reservation failed open for a writer"
  fi
  if reserve_main "$home" "$TOKEN_A" >/dev/null 2>&1; then
    fail "a malformed reservation failed open for a launcher"
  fi
  rm -f "$home/state/.prelaunch-reservation"
  ln -s "$home/state/missing-reservation" "$home/state/.prelaunch-reservation"
  if run_pre "$home" guard-write >/dev/null 2>&1; then
    fail "a dangling reservation symlink failed open for a writer"
  fi
  rm -f "$home/state/.prelaunch-reservation"

  user_home="$TMP_ROOT/dotfiles-lock-home"
  mkdir -p "$user_home/.local/state/dotfiles/lock"
  printf '%s\n' "$$" > "$user_home/.local/state/dotfiles/lock/pid"
  if HOME="$user_home" bash "$PRELAUNCH" reserve --home "$home" \
    --owner-pid "$$" --token "$TOKEN_A" >/dev/null 2>&1; then
    fail "a live dotfiles publication lock allowed a reservation"
  fi
  [ ! -e "$home/state/.prelaunch-reservation" ] \
    || fail "dotfiles publication refusal left a reservation"
  rm -f "$user_home/.local/state/dotfiles/lock/pid"
  if HOME="$user_home" bash "$PRELAUNCH" reserve --home "$home" \
    --owner-pid "$$" --token "$TOKEN_A" >/dev/null 2>&1; then
    fail "an ambiguous dotfiles publication lock allowed a reservation"
  fi
  pass "prelaunch: active fleet, pending queue, session/publication locks and malformed state refuse"
}

test_source_identity_change_refuses_validation() {
  local home
  home=$(new_home source-identity)
  reserve_main "$home" "$TOKEN_A" >/dev/null || fail "source-identity fixture reserve failed"
  git -C "$home" remote set-url origin https://example.invalid/replaced.git
  if run_pre "$home" validate --owner-pid "$$" --token "$TOKEN_A" >/dev/null 2>&1; then
    fail "changed enrolled source identity retained reservation authority"
  fi
  pass "prelaunch: source origin/default identity remains bound after reservation"
}

test_race_dead_owner_pid_reuse_and_ancestry() {
  local home result_a result_b ready_a ready_b stop_a stop_b successes
  home=$(new_home ownership)
  result_a="$TMP_ROOT/race-a"
  result_b="$TMP_ROOT/race-b"
  ready_a="$TMP_ROOT/ready-a"
  ready_b="$TMP_ROOT/ready-b"
  stop_a="$TMP_ROOT/stop-a"
  stop_b="$TMP_ROOT/stop-b"
  bash -c '
    pre=$1; home=$2; token=$3; result=$4; ready=$5; stop=$6
    rc=0
    bash "$pre" reserve --home "$home" --owner-pid "$$" --token "$token" >"$result.out" 2>"$result.err" || rc=$?
    printf "%s\n" "$rc" > "$result"
    : > "$ready"
    if [ "$rc" -eq 0 ]; then
      while [ ! -e "$stop" ]; do sleep 0.02; done
      bash "$pre" release --home "$home" --owner-pid "$$" --token "$token" >/dev/null 2>&1 || true
    fi
  ' _ "$PRELAUNCH" "$home" "$TOKEN_A" "$result_a" "$ready_a" "$stop_a" &
  pid_a=$!
  bash -c '
    pre=$1; home=$2; token=$3; result=$4; ready=$5; stop=$6
    rc=0
    bash "$pre" reserve --home "$home" --owner-pid "$$" --token "$token" >"$result.out" 2>"$result.err" || rc=$?
    printf "%s\n" "$rc" > "$result"
    : > "$ready"
    if [ "$rc" -eq 0 ]; then
      while [ ! -e "$stop" ]; do sleep 0.02; done
      bash "$pre" release --home "$home" --owner-pid "$$" --token "$token" >/dev/null 2>&1 || true
    fi
  ' _ "$PRELAUNCH" "$home" "$TOKEN_B" "$result_b" "$ready_b" "$stop_b" &
  pid_b=$!
  for _ in $(seq 1 250); do
    [ -e "$ready_a" ] && [ -e "$ready_b" ] && break
    sleep 0.02
  done
  [ -e "$ready_a" ] && [ -e "$ready_b" ] || fail "racing launchers did not settle"
  successes=0
  [ "$(cat "$result_a")" -ne 0 ] || successes=$((successes + 1))
  [ "$(cat "$result_b")" -ne 0 ] || successes=$((successes + 1))
  [ "$successes" -eq 1 ] || fail "racing launchers produced $successes owners"
  : > "$stop_a"
  : > "$stop_b"
  wait "$pid_a" || true
  wait "$pid_b" || true

  # A launcher that dies without release is reclaimed only after kernel
  # identity proves it is gone.
  bash -c '
    bash "$1" reserve --home "$2" --owner-pid "$$" --token "$3" >/dev/null
  ' _ "$PRELAUNCH" "$home" "$TOKEN_A" || fail "dead-owner fixture could not reserve"
  reserve_main "$home" "$TOKEN_B" >/dev/null || fail "a verified dead owner was not reclaimed"
  # A live PID with a mismatched recorded identity models PID reuse.  It is
  # stale evidence, never authority for the process now carrying that PID.
  sed 's/^owner_identity_sha256=.*/owner_identity_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
    "$home/state/.prelaunch-reservation" > "$home/state/.prelaunch-reservation.next"
  mv "$home/state/.prelaunch-reservation.next" "$home/state/.prelaunch-reservation"
  reserve_main "$home" "$TOKEN_C" >/dev/null || fail "a PID-reuse identity mismatch was not safely reclaimed"
  release_main "$home" "$TOKEN_C" >/dev/null || fail "PID-reuse fixture release failed"

  # A sibling process knows the token and PID but is not below that launcher.
  ready_a="$TMP_ROOT/ancestry-ready"
  stop_a="$TMP_ROOT/ancestry-stop"
  result_a="$TMP_ROOT/ancestry-owner"
  bash -c '
    printf "%s\n" "$$" > "$4"
    bash "$1" reserve --home "$2" --owner-pid "$$" --token "$3" >/dev/null || exit 1
    : > "$5"
    while [ ! -e "$6" ]; do sleep 0.02; done
    bash "$1" release --home "$2" --owner-pid "$$" --token "$3" >/dev/null
  ' _ "$PRELAUNCH" "$home" "$TOKEN_A" "$result_a" "$ready_a" "$stop_a" &
  pid_a=$!
  for _ in $(seq 1 250); do [ -e "$ready_a" ] && break; sleep 0.02; done
  [ -e "$ready_a" ] || fail "ancestry owner did not reserve"
  if run_pre "$home" validate --owner-pid "$(cat "$result_a")" --token "$TOKEN_A" >/dev/null 2>&1; then
    fail "a sibling process authenticated with copied PID and token"
  fi
  : > "$stop_a"
  wait "$pid_a" || fail "ancestry owner could not release"
  pass "prelaunch: races, death, PID reuse and copied-token ancestry are fail-closed"
}

test_scope_and_physical_home_exclusions() {
  local home linked alias base
  home=$(new_home scope)
  alias="$TMP_ROOT/scope-alias"
  ln -s "$home" "$alias"
  if run_pre "$alias" capabilities >/dev/null 2>&1; then
    fail "a symlink spelling enrolled instead of the exact physical home"
  fi
  printf 'mate\n' > "$home/.fm-secondmate-home"
  if run_pre "$home" capabilities >/dev/null 2>&1; then
    fail "a secondmate home exposed startup-pull capabilities"
  fi
  rm -f "$home/.fm-secondmate-home"
  if NO_MISTAKES_GATE=1 run_pre "$home" capabilities >/dev/null 2>&1; then
    fail "a no-mistakes phase exposed startup-pull capabilities"
  fi

  base=$(new_home linked-base)
  linked="$TMP_ROOT/linked-worker"
  git -C "$base" worktree add -q --detach "$linked" HEAD
  if run_pre "$linked" capabilities >/dev/null 2>&1; then
    fail "a linked worker worktree exposed startup-pull capabilities"
  fi
  pass "prelaunch: aliases, secondmates, no-mistakes phases and linked workers are excluded"
}

test_native_child_handoff_and_foreign_refusal() {
  local home fakebin out launcher_result dirty_result
  home=$(new_home handoff)
  fakebin="$TMP_ROOT/handoff-bin"
  mkdir -p "$fakebin"
  ln -s /bin/bash "$fakebin/codex"

  reserve_main "$home" "$TOKEN_A" >/dev/null || fail "foreign-child fixture reserve failed"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$fakebin/codex" "$LOCK" >/dev/null 2>&1; then
    fail "a harness child without the reservation environment crossed the handoff"
  fi
  release_main "$home" "$TOKEN_A" >/dev/null || fail "foreign-child fixture release failed"

  dirty_result="$TMP_ROOT/handoff-dirty-result"
  bash -c '
    pre=$1; lock=$2; harness=$3; home=$4; token=$5; result=$6
    owner=$$
    head=$(git -C "$home" rev-parse HEAD) || exit 1
    bash "$pre" reserve --home "$home" --owner-pid "$owner" --token "$token" >/dev/null || exit 2
    bash "$pre" update --home "$home" --owner-pid "$owner" --token "$token" --commit "$head" >/dev/null || exit 3
    (
      while [ ! -e "$result.go" ]; do sleep 0.02; done
      exec env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_PRELAUNCH_OWNER_PID="$owner" \
        FM_PRELAUNCH_TOKEN="$token" GIT_DIR="$result.ambient-git-dir" \
        GIT_INDEX_FILE="$result.ambient-index" "$harness" "$lock"
    ) >"$result.lock" 2>&1 &
    child=$!
    bash "$pre" attach --home "$home" --owner-pid "$owner" --token "$token" \
      --child-pid "$child" >/dev/null || exit 4
    printf "changed after update\n" >> "$home/version.txt"
    : > "$result.go"
    rc=0
    wait "$child" || rc=$?
    printf "%s\n" "$rc" > "$result"
    git -C "$home" checkout -q -- version.txt || exit 5
    bash "$pre" release --home "$home" --owner-pid "$owner" --token "$token" >/dev/null || exit 6
  ' _ "$PRELAUNCH" "$LOCK" "$fakebin/codex" "$home" "$TOKEN_B" "$dirty_result" \
    || fail "dirty-before-handoff launcher fixture failed"
  [ "$(cat "$dirty_result")" -ne 0 ] || fail "a dirty source completed session-lock handoff"
  assert_contains "$(cat "$dirty_result.lock")" 'source became dirty before session-lock handoff' \
    "dirty handoff refusal did not name the source change"
  [ ! -e "$home/state/.lock" ] || fail "dirty handoff refusal published a session lock"

  launcher_result="$TMP_ROOT/handoff-result"
  bash -c '
    pre=$1; lock=$2; harness=$3; home=$4; token=$5; result=$6
    owner=$$
    head=$(git -C "$home" rev-parse HEAD) || exit 1
    bash "$pre" reserve --home "$home" --owner-pid "$owner" --token "$token" >/dev/null || exit 2
    bash "$pre" update --home "$home" --owner-pid "$owner" --token "$token" --commit "$head" >/dev/null || exit 3
    (
      while [ ! -e "$result.go" ]; do sleep 0.02; done
      exec env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_PRELAUNCH_OWNER_PID="$owner" \
        FM_PRELAUNCH_TOKEN="$token" GIT_DIR="$result.ambient-git-dir" \
        GIT_INDEX_FILE="$result.ambient-index" "$harness" "$lock"
    ) >"$result.lock" 2>&1 &
    child=$!
    bash "$pre" attach --home "$home" --owner-pid "$owner" --token "$token" \
      --child-pid "$child" >"$result.attach" 2>&1 || exit 4
    : > "$result.go"
    rc=0
    wait "$child" || rc=$?
    printf "%s\n" "$rc" > "$result"
    bash "$pre" release --home "$home" --owner-pid "$owner" --token "$token" >"$result.release" 2>&1 || exit 5
  ' _ "$PRELAUNCH" "$LOCK" "$fakebin/codex" "$home" "$TOKEN_C" "$launcher_result" \
    || fail "authenticated child handoff launcher failed"
  [ "$(cat "$launcher_result")" -eq 0 ] || fail "authenticated child lock failed: $(cat "$launcher_result.lock")"
  assert_contains "$(cat "$launcher_result.lock")" 'lock acquired: harness pid' \
    "the genuine harness process should own the session lock"
  [ ! -e "$home/state/.prelaunch-reservation" ] || fail "handoff left the reservation live"
  [ -f "$home/state/.prelaunch-handoff" ] || fail "handoff did not publish its receipt"
  assert_contains "$(cat "$launcher_result.release")" '"status":"handed-off"' \
    "release should recognize an already completed handoff"
  pass "prelaunch: only the authenticated genuine child atomically exchanges into the session lock"
}

test_capabilities_are_read_only_and_explicit
test_profile_launch_env_matches_capabilities
test_strict_inventory_errors_refuse_reservation
test_guard_write_admits_ineligible_unreserved_primaries
test_reservation_validation_guard_and_release
test_pinned_update_preflight_and_no_candidate_execution
test_filter_dirty_branch_and_divergence_refuse_without_mutation
test_session_fleet_queue_and_unknown_state_refuse
test_source_identity_change_refuses_validation
test_race_dead_owner_pid_reuse_and_ancestry
test_attached_child_survives_parent_death_as_occupancy
test_scope_and_physical_home_exclusions
test_native_child_handoff_and_foreign_refusal
