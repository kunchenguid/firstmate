#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)
UPDATE_TEST_PIDS=""

cleanup_update_tests() {
  local pid
  for pid in $UPDATE_TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_update_tests EXIT

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, a skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

new_protocol_migration_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  if [ -n "${FM_TEST_PREDECESSOR_BIN:-}" ]; then
    cp -R "$FM_TEST_PREDECESSOR_BIN" "$w/seed/bin"
  else
    cp -R "$ROOT/bin" "$w/seed/bin"
    sed "s/^FM_WATCHER_PROTOCOL_VERSION=.*/FM_WATCHER_PROTOCOL_VERSION='pending-reply-ticket-v2'/" \
      "$w/seed/bin/fm-watcher-protocol-lib.sh" \
      > "$w/seed/bin/fm-watcher-protocol-lib.sh.tmp"
    mv "$w/seed/bin/fm-watcher-protocol-lib.sh.tmp" \
      "$w/seed/bin/fm-watcher-protocol-lib.sh"
  fi
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'state/\ndata/\nconfig/\nprojects/\n' > "$w/seed/.gitignore"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm protocol-v1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  cp -R "$ROOT/bin/." "$w/seed/bin/"
  git -C "$w/seed" add bin
  git -C "$w/seed" commit -qm protocol-v3
  git -C "$w/seed" push -q origin main
  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  ( cd "$w/main" && FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" ) 2>/dev/null
}

ack_firstmate_reread() {
  local w=$1 generation
  generation=$(fm_update_obligation_generation \
    "$w/home/state/.watch-protocol-reread-required" "$w/main")
  ( cd "$w/main" && FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$generation" >/dev/null )
}

ack_secondmate_nudge() {
  local w=$1 target=$2 generation
  generation=$(fm_update_obligation_generation \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1")
  ( cd "$w/main" && FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-secondmate-nudge "$target" "$generation" >/dev/null )
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "restart-firstmate-watcher: no" "updated firstmate without a watcher needs no restart"
  assert_contains "$out" "restart-secondmate-watchers: none" "updated secondmate without a watcher needs no restart"
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "updated secondmate is nudged"
  fm_update_obligation_pending "$w/home/state/.watch-protocol-reread-required" "$w/main" \
    || fail "firstmate reread obligation was not retained for acknowledgement"
  fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "secondmate nudge obligation was not retained for acknowledgement"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both
  ack_firstmate_reread "$w"
  ack_secondmate_nudge "$w" main:fm-sm1

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "restart-firstmate-watcher: no" "current firstmate skips watcher restart"
  assert_contains "$out" "restart-secondmate-watchers: none" "current secondmate skips watcher restart"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "main:fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

test_replays_interrupted_reread_and_nudge_obligations() {
  local w out
  w=$(new_world t12)
  add_sm "$w" sm1
  printf '%s\n' state/ >> "$(git -C "$w/sm1" rev-parse --git-path info/exclude)"
  mkdir -p "$w/sm1/state"
  printf '%s\n' pending-reply-ticket-v2 > "$w/home/state/.watch-protocol-reread-required"
  printf '%s\n' pending-reply-ticket-v2 > "$w/sm1/state/.watch-protocol-reread-required"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: already current" "retry keeps current firstmate"
  assert_contains "$out" "secondmate sm1: already current" "retry keeps current secondmate"
  assert_contains "$out" "reread-firstmate: yes" "retry replays firstmate reread"
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "retry replays secondmate nudge"
  fm_update_obligation_pending "$w/home/state/.watch-protocol-reread-required" "$w/main" \
    || fail "firstmate reread obligation cleared before acknowledgement"
  fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "secondmate nudge obligation cleared before acknowledgement"

  ack_firstmate_reread "$w"
  ack_secondmate_nudge "$w" main:fm-sm1
  ! fm_update_obligation_pending "$w/home/state/.watch-protocol-reread-required" "$w/main" \
    || fail "firstmate reread acknowledgement did not clear obligation"
  ! fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "secondmate nudge acknowledgement did not clear obligation"
  pass "T12 interrupted update obligations persist until acknowledged"
}

test_first_protocol_upgrade_requires_installed_updater_pass() {
  local w fakebin watcher arm out rc
  w=$(new_protocol_migration_world t13)
  fakebin="$w/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"

  ( cd "$w/main" && exec env PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$w/home/state" FM_POLL=5 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$w/main/bin/fm-watch.sh" >/dev/null 2>&1 ) &
  watcher=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $watcher"
  for _ in $(seq 1 60); do
    [ "$(cat "$w/home/state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] \
      && [ "$(cat "$w/home/state/.watch.lock/pending-reply-protocol" 2>/dev/null || true)" = pending-reply-ticket-v2 ] \
      && break
    sleep 0.1
  done
  [ "$(cat "$w/home/state/.watch.lock/pending-reply-protocol" 2>/dev/null || true)" = pending-reply-ticket-v2 ] \
    || fail "migration fixture did not start the predecessor watcher"

  ( cd "$w/main" && exec env PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$w/home/state" FM_POLL=5 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$w/main/bin/fm-watch-arm.sh" >"$w/arm.out" ) &
  arm=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $arm"
  for _ in $(seq 1 60); do
    [ "$(cat "$w/home/state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$arm" ] && break
    sleep 0.1
  done
  [ "$(cat "$w/home/state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$arm" ] \
    || fail "migration fixture did not attach a v1 follower"

  rc=0
  # A v2 updater completed the install before the v3 updater learned to re-exec.
  out=$(cd "$w/main" && PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_UPDATE_REEXECED=1 \
    FM_STATE_OVERRIDE="$w/home/state" "$w/main/bin/fm-update.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "predecessor updater did not install the new updater"
  assert_contains "$out" "firstmate: updated " "predecessor updater installed v3"

  rc=0
  ( cd "$w/main" && PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$w/home/state" "$w/main/bin/fm-update.sh" >"$w/second-pass.out" 2>&1 ) || rc=$?
  out=$(cat "$w/second-pass.out")
  [ "$rc" -ne 0 ] || fail "installed updater accepted the predecessor watcher"
  assert_contains "$out" "watcher protocol restart could not be verified" \
    "installed updater enforces the required second pass"
  [ "$(cat "$w/home/state/.watch-protocol-required" 2>/dev/null || true)" = pending-reply-ticket-v3 ] \
    || fail "first protocol upgrade did not publish the v3 fence"
  wait "$watcher" 2>/dev/null || true
  wait "$arm" 2>/dev/null || true
  pass "T13 real predecessor requires the installed updater pass"
}

test_acknowledgements_are_generation_bound() {
  local w old_generation new_generation out rc
  w=$(new_world t14)
  old_generation=$(git -C "$w/main" rev-parse HEAD)
  printf 'generation=%s\n' "$old_generation" > "$w/home/state/.watch-protocol-reread-required"
  bump_origin "$w" instr

  out=$(run_update "$w")
  new_generation=$(sed -n 's/^reread-firstmate-generation: //p' <<< "$out")
  [ -n "$new_generation" ] && [ "$new_generation" != "$old_generation" ] \
    || fail "new update generation was not reported"

  rc=0
  ( cd "$w/main" && FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$old_generation" >/dev/null 2>&1 ) || rc=$?
  [ "$rc" -ne 0 ] || fail "stale acknowledgement cleared a newer obligation"
  [ "$(fm_update_obligation_generation \
    "$w/home/state/.watch-protocol-reread-required" "$w/main")" = "$new_generation" ] \
    || fail "newer reread generation was not preserved"

  ( cd "$w/main" && FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$new_generation" >/dev/null )
  pass "T14 stale acknowledgements cannot clear newer generations"
}

test_herdr_target_acknowledges_exact_live_meta() {
  local w out generation
  w=$(new_world t15)
  add_sm "$w" sm1
  sed -i 's/^window=.*/window=default:w1:p2/' "$w/home/state/sm1.meta"
  bump_origin "$w" instr

  out=$(run_update "$w")
  assert_contains "$out" "nudge-secondmates: default:w1:p2" "Herdr target is surfaced unchanged"
  generation=$(sed -n 's/^nudge-secondmate-generation: default:w1:p2|//p' <<< "$out")
  [ -n "$generation" ] || fail "Herdr target generation was not reported"
  ( cd "$w/main" && FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-secondmate-nudge default:w1:p2 "$generation" >/dev/null )
  ! fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "Herdr target acknowledgement did not clear its obligation"
  pass "T15 Herdr acknowledgements resolve exact live metadata"
}

test_immutable_generations_preserve_prepared_and_newer_markers() {
  local w marker records generation_a generation_b generation_c fail_target failed rc
  w=$(new_world t16)
  marker="$w/home/state/.watch-protocol-reread-required"
  generation_a=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" readme
  generation_b=$(git -C "$w/seed" rev-parse HEAD)
  bump_origin "$w" readme
  generation_c=$(git -C "$w/seed" rev-parse HEAD)

  fm_update_obligation_write "$marker" "$generation_a"
  fm_update_obligation_write "$marker" "$generation_b"
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_a" ] \
    || fail "prepared future generation became active before fast-forward"

  git -C "$w/main" fetch -q origin main
  git -C "$w/main" merge -q --ff-only origin/main
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_b" ] \
    || fail "ancestor obligation was not selected after a later fast-forward"
  rc=0
  fm_update_obligation_ack "$marker" "$generation_a" "$w/main" || rc=$?
  [ "$rc" -ne 0 ] || fail "older generation acknowledged a newer checkout"

  records=$(fm_update_obligation_records_dir "$marker")
  fail_target="$records/$generation_b"
  failed="$w/ack-failed"
  rm() {
    if [ "${1:-}" = -f ] && [ "${2:-}" = "$fail_target" ] && [ ! -f "$failed" ]; then
      touch "$failed"
      return 1
    fi
    command rm "$@"
  }
  rc=0
  fm_update_obligation_ack "$marker" "$generation_b" "$w/main" || rc=$?
  unset -f rm
  [ "$rc" -ne 0 ] || fail "interrupted acknowledgement unexpectedly succeeded"
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_b" ] \
    || fail "interrupted acknowledgement lost its retry generation"
  fm_update_obligation_ack "$marker" "$generation_b" "$w/main" \
    || fail "ancestor generation acknowledgement retry failed at $generation_c"
  ! fm_update_obligation_pending "$marker" "$w/main" \
    || fail "current acknowledgement left superseded generations"
  pass "T16 ancestor obligations remain acknowledgeable and retries are durable"
}

test_skipped_update_reports_existing_generation() {
  local w generation out
  w=$(new_world t17)
  generation=$(git -C "$w/main" rev-parse HEAD)
  printf 'generation=%s\n' "$generation" > "$w/home/state/.watch-protocol-reread-required"
  printf 'local edit\n' >> "$w/main/README.md"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: dirty working tree" "dirty update remains skipped"
  assert_contains "$out" "reread-firstmate: yes" "skipped update replays pending reread"
  assert_contains "$out" "reread-firstmate-generation: $generation" \
    "skipped update reports the existing generation"
  pass "T17 skipped updates retain acknowledgement generations"
}

test_future_legacy_generation_survives_concurrent_ack() {
  local w marker generation_a generation_c
  w=$(new_world t18)
  marker="$w/home/state/.watch-protocol-reread-required"
  generation_a=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" readme
  bump_origin "$w" readme
  generation_c=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/main" fetch -q origin main

  fm_update_obligation_write "$marker" "$generation_a"
  printf 'generation=%s\n' "$generation_c" > "$marker"
  fm_update_obligation_ack "$marker" "$generation_a" "$w/main" \
    || fail "current acknowledgement rejected a prepared legacy generation"
  ! fm_update_obligation_pending "$marker" "$w/main" \
    || fail "future legacy generation became active before fast-forward"

  git -C "$w/main" merge -q --ff-only origin/main
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_c" ] \
    || fail "future legacy generation was lost during concurrent acknowledgement"
  fm_update_obligation_ack "$marker" "$generation_c" "$w/main" \
    || fail "preserved future legacy generation could not be acknowledged"
  pass "T18 future legacy generations survive concurrent acknowledgements"
}

test_future_only_legacy_generation_updates_on_first_retry() {
  local w marker generation out
  w=$(new_world t19)
  marker="$w/home/state/.watch-protocol-reread-required"
  bump_origin "$w" readme
  generation=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/main" fetch -q origin main
  printf 'generation=%s\n' "$generation" > "$marker"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " \
    "future-only legacy obligation does not block its first retry"
  assert_contains "$out" "reread-firstmate-generation: $generation" \
    "future-only legacy obligation activates after fast-forward"
  pass "T19 future-only legacy generations recover on the first retry"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_replays_interrupted_reread_and_nudge_obligations
test_first_protocol_upgrade_requires_installed_updater_pass
test_acknowledgements_are_generation_bound
test_herdr_target_acknowledges_exact_live_meta
test_immutable_generations_preserve_prepared_and_newer_markers
test_skipped_update_reports_existing_generation
test_future_legacy_generation_survives_concurrent_ack
test_future_only_legacy_generation_updates_on_first_retry

echo "# all fm-update tests passed"
