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
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     the two secondmate action sets are disjoint and correctly gated -
#     restart-secondmates carries EVERY live mate this pass left on origin's tip
#     whose recorded runtime can prove a restart, INCLUDING one that was already
#     there and one whose advance touched no instruction surface, because a
#     restart is also what re-resolves launch-time harness wiring; a live mate
#     whose runtime cannot prove a restart falls to nudge-secondmates; and a mate
#     whose home was skipped or whose endpoint is stopped gets no action at all.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in main:fm-*) target=$arg ;; esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
  chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
# The recorded runtime matters to the action split, so it is part of the fixture:
# harness defaults to a control-verified adapter on the default (tmux) backend,
# which is what makes a restart provable. Pass a backend to model one that cannot
# prove an agent stopped.
add_sm() {
  local w=$1 id=$2 harness=${3:-claude} backend=${4:-}
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/%s\n' "$w" "$id"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf 'fm-%s\n' "$id" >> "$w/fake/windows"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the whole instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=bin changes only bin/, which
# a running agent re-executes rather than holding; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  if [ "$mode" = bin ]; then
    printf 'echo b-%s\n' "$RANDOM" > "$w/seed/bin/tool.sh"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1
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
  assert_contains "$out" "restart-secondmates: fm-sm1" "a changed AGENTS.md must move the secondmate into the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"

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
  pass "T1 main + secondmate fast-forward (single-parent), reread + restart signalled"
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
  # The running firstmate reads nothing new, but the mate's agent still holds its
  # launch-time wiring from before the pass, which only a restart re-resolves.
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live mate on the new tip must restart even when no instruction file moved"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3 a non-instruction advance still restarts the live secondmate"
}

# --- T3b: a bin/-only advance restarts too ---------------------------------
# Helpers under bin/ do reload themselves on the next call, but the mate's agent
# still froze its launch-time harness wiring before this pass, so the restart is
# not redundant and the old bin/-only carve-out no longer applies.
test_bin_only_advance_restarts() {
  local w out
  w=$(new_world t3b)
  add_sm "$w" sm1
  bump_origin "$w" bin

  out=$(run_update "$w")

  assert_contains "$out" "reread-firstmate: yes" "a bin/ change is still an instruction-surface advance"
  assert_contains "$out" "restart-secondmates: fm-sm1" "a bin/-only advance must still restart the live mate"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T3b a bin/-only advance restarts the secondmate"
}

# --- T3c: an unverifiable runtime receives the fallback nudge ----------------
test_unprovable_runtime_gets_fallback_nudge() {
  local w out
  w=$(new_world t3c)
  # zellij has no recovery-grade agent-state classifier, so no restart there can
  # ever prove the old agent stopped and the replacement came up.
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "restart-secondmates: none" "an unprovable runtime must stay out of the restart set"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "an unverifiable runtime must retain the fallback re-read nudge"
  pass "T3c an unverifiable secondmate receives the fallback nudge"
}

# --- T3d: an already-stopped mate is left to startup recovery ---------------
test_dead_secondmate_gets_no_action() {
  local w out
  w=$(new_world t3d)
  add_sm "$w" sm1
  : > "$w/fake/dead-sm1"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: updated " "the stopped mate's safe checkout still advances"
  assert_contains "$out" "restart-secondmates: none" "a stopped mate must not be sent to restart"
  assert_contains "$out" "nudge-secondmates: none" "a stopped mate must not receive a queued nudge"
  pass "T3d an already-stopped secondmate is left to startup recovery"
}

# --- T3e: a legacy remote advance still restarts ---------------------------
# The host's instr= suffix is reporting detail; the parent no longer routes on it,
# so an older host that cannot report a diff can no longer suppress the restart.
test_legacy_remote_advance_restarts() {
  local w out fake_ssh
  w=$(new_world t3e)
  fake_ssh="$w/fakebin/fake-ssh"
  cat > "$fake_ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
case "${rargs[1]:-}" in
  update)
    if [ -f "$FM_FAKE_DIR/remote-fail" ]; then
      printf 'fork sync failed: protected fork branch\n' >&2
      exit 1
    fi
    if [ -f "$FM_FAKE_DIR/remote-current" ]; then
      # cmd_sync appends " verified=1" only when its own root run verified.
      if [ "$(cat "$FM_FAKE_DIR/remote-current")" = verified ]; then
        printf 'current: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb verified=1\n'
      else
        printf 'current: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
      fi
      exit 0
    fi
    printf 'synced: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa verified=1\n' ;;
  state) printf 'alive\n' ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fake_ssh"
  cat > "$w/home/state/sm1.meta" <<EOF
window=remote:sm1
endpoint_task_id=sm1
worktree=/srv/sm1
project=/srv/sm1
harness=claude
kind=secondmate
home=/srv/sm1
remote_host=remote-mac
remote_backend=herdr
EOF
  printf -- '- sm1 - remote domain (host: remote-mac; root: /srv/fm; home: /srv/sm1; scope: things; projects: p; added 2026-09-03)\n' \
    > "$w/home/data/secondmates.md"

  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w")

  assert_contains "$out" "remote secondmate sm1: updated on remote-mac" \
    "the legacy remote advance was not accepted"
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "a live remote mate on the new tip must restart even when the host reports no instruction diff"
  assert_contains "$out" "nudge-secondmates: none" \
    "a restarted remote mate must not also be steered"
  pass "T3e a legacy remote advance still restarts the live remote mate"
  touch "$w/fake/remote-fail"
  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w") \
    || fail "one failing remote host must not fail the whole fleet"
  assert_contains "$out" "fork sync failed: protected fork branch" "remote failure diagnostic survives"
  assert_contains "$out" "restart-secondmates: none" "failed remote update cannot restart"
  pass "T3f a failed remote secondmate is reported and skipped, not escalated to the fleet"

  # PROPERTY 2: the host proves it verified currency on the result line the
  # parent parses. A host whose fork discovery failed, or which is too old to
  # prove anything, sends no proof - and the captain-facing summary must not
  # then claim the mate is already current.
  rm -f "$w/fake/remote-fail"
  printf 'unverified\n' > "$w/fake/remote-current"
  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w") \
    || fail "an unverified remote host must not fail the fleet"
  assert_contains "$out" "remote secondmate sm1: cannot confirm current on remote-mac" \
    "an unproven remote result must not be labelled already current"
  assert_not_contains "$out" "already current on remote-mac" \
    "the captain-facing summary must never claim unverified currency"
  assert_contains "$out" "origin-verified: no" "an unverified remote makes the run non-authoritative"
  pass "T3g an unverified remote host never reports already current to the captain"

  printf 'verified\n' > "$w/fake/remote-current"
  out=$(FM_TEST_SSH_BIN="$fake_ssh" run_update "$w") \
    || fail "a verified remote host must succeed"
  assert_contains "$out" "remote secondmate sm1: already current on remote-mac" \
    "a proven remote result still reports already current"
  assert_contains "$out" "origin-verified: yes" "a wholly verified run is authoritative"
  pass "T3h a remote host that proves verification still reports already current"
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

# --- T6: the git side is idempotent; the restart set is not -----------------
# This is the SSHHIP case: that mate's home was already at the target commit, so
# the old classifier skipped it entirely and its agent kept running the launch-time
# wiring it started with. An already-current live mate must still be restarted.
test_already_current_secondmate_still_restarts() {
  local w out restart_line
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing left to fast-forward

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live secondmate must still be in the restart set"
  assert_contains "$out" "nudge-secondmates: none" "a restarted secondmate must not also be nudged"
  pass "T6 an already-current live secondmate is still restarted"
}

# --- T6b: an already-current mate that cannot be restarted stays honest -----
# Unconditional restart must not become an unconditional CLAIM of one.
test_already_current_unprovable_mate_is_nudged() {
  local w out restart_line nudge_line
  w=$(new_world t6b)
  add_sm "$w" sm1 claude zellij
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: the home is already on the tip

  assert_contains "$out" "secondmate sm1: already current" "the mate must need no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" "an unprovable runtime must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" "an unprovable runtime must keep the honest re-read steer"
  pass "T6b an already-current mate with an unprovable runtime is steered, not claimed as reloaded"
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
  local restart_line
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" "live-meta secondmate is restarted"
  assert_not_contains "$restart_line" "reg1" "registry-only secondmate without live metadata gets no action"
  assert_not_contains "$nudge_line" "sm1" "a restarted secondmate must not also be nudged"
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

# --- T12: a self-update rebinds a locally armed watch on the primary --------
# A self-update fast-forwards bin/ in place, changing bytes an armed
# fm-procevent-when watch's trust binding was hashed against with no
# tampering involved; without a rebind the very next fire would be refused.
test_primary_update_rebinds_local_watch() {
  local w before_hash after_hash out spec
  w=$(new_world t12)
  mkdir -p "$w/seed/bin"
  printf "#!/usr/bin/env bash\necho v1 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  chmod +x "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm add-watched-action
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q origin main

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$ROOT/bin/fm-procevent-when.sh" \
    arm rebind-primary --interval 60 --stable 1 \
    --condition true --action "$w/main/bin/watched-action.sh" "$w/rebind.log" >/dev/null
  spec="$w/home/state/when/when-rebind-primary.spec"
  before_hash=$(grep '^action_sha256=' "$spec")

  printf "#!/usr/bin/env bash\necho v2 >> \"\$1\"\n" > "$w/seed/bin/watched-action.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm bump-watched-action
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "the primary still advanced"
  assert_contains "$out" "rebound: when-rebind-primary" "the primary self-update rebound its own locally armed watch"
  after_hash=$(grep '^action_sha256=' "$spec")
  [ "$before_hash" != "$after_hash" ] \
    || fail "the watch's trust binding was not refreshed to match the updated action bytes"
  pass "T12 a self-update rebinds a locally armed watch on the primary"
}

# GitHub discovery is stubbed; fetches, ancestry, pushes, rejection hooks, and
# checkout updates run real Git against local bare repositories via insteadOf.
# The stub models gh-axi's caller-selected flat TOON output, not a raw gh JSON API.
new_fork_world() {
  local w=$1 branch=${2:-main}
  if [ "$branch" != main ]; then
    git -C "$w/seed" branch -m main "$branch"
    git -C "$w/seed" push -q origin "$branch"
    git -C "$w/origin.git" symbolic-ref HEAD "refs/heads/$branch"
    git -C "$w/main" fetch -q origin
    git -C "$w/main" checkout -qb "$branch" "origin/$branch"
  fi
  git clone -q --bare "$w/origin.git" "$w/fork.git"
  git -C "$w/main" remote set-url origin https://github.com/operator/firstmate.git
  git -C "$w/main" config url."$w/fork.git".insteadOf https://github.com/operator/firstmate.git
  # Every parent URL ff_sync_origin_fork can derive from origin's own transport.
  git -C "$w/main" config url."$w/origin.git".insteadOf https://github.com/author/firstmate.git
  git -C "$w/main" config --add url."$w/origin.git".insteadOf git@github.com:author/firstmate.git
  git -C "$w/main" config --add url."$w/origin.git".insteadOf ssh://git@github.com/author/firstmate.git
  cat > "$w/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/api-calls"
[ ! -f "$FM_FAKE_DIR/api-fail" ] || { echo 'authentication failed' >&2; exit 1; }
[ "$1" = api ] && [ "$2" = /repos/operator/firstmate ] || exit 1
cat "$FM_FAKE_DIR/metadata"
SH
  chmod +x "$w/fakebin/gh-axi"
  printf 'fork: true\nname: operator/firstmate\nbranch: %s\nparent: author/firstmate\nparentBranch: %s\n' \
    "$branch" "$branch" > "$w/fake/metadata"
}

advance_parent() {
  local w=$1 branch=${2:-main}
  printf 'authoritative advance\n' >> "$w/seed/README.md"
  git -C "$w/seed" commit -qam upstream-advance
  git -C "$w/seed" push -q origin "$branch"
}

test_fork_update() {
  local spelling w branch origin_url before expected out
  # One fork, written four ways Git accepts. A spelling the matcher fails to
  # place would skip synchronization and report the stale fork as current.
  for spelling in plain credential scp ssh; do
    w=$(new_world "fork-$spelling")
    branch=release/stable
    new_fork_world "$w" "$branch"
    case "$spelling" in
      plain) origin_url=https://github.com/operator/firstmate.git ;;
      credential) origin_url=https://captain@github.com/operator/firstmate.git ;;
      scp) origin_url=git@github.com:operator/firstmate.git ;;
      ssh) origin_url=ssh://git@github.com/operator/firstmate.git ;;
    esac
    if [ "$spelling" != plain ]; then
      git -C "$w/main" remote set-url origin "$origin_url"
      git -C "$w/main" config --add url."$w/fork.git".insteadOf "$origin_url"
    fi
    add_sm "$w" sm1
    # add_sm starts at main; the detached home still safely follows origin's
    # actual default, which is intentionally stale in origin/HEAD at this point.
    before=$(git -C "$w/main" rev-parse HEAD)
    advance_parent "$w" "$branch"
    expected=$(git -C "$w/origin.git" rev-parse "$branch")
    # A configured push URL must not redirect the fork synchronization.
    git -C "$w/main" remote set-url --push origin "$w/never-push-here.git"
    git -C "$w/main" config push.followTags true
    git -C "$w/main" tag -a private-tag -m private "$before"
    out=$(run_update "$w") || fail "fork update failed: $out"
    assert_contains "$out" "fork sync: fast-forwarded operator/firstmate/$branch" "fork sync is visible"
    assert_contains "$out" 'firstmate: updated ' "primary advances after fork"
    assert_contains "$out" 'secondmate sm1: updated ' "linked home follows same result"
    [ "$(git -C "$w/fork.git" rev-parse "$branch")" = "$expected" ] || fail 'fork remained stale'
    [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] || fail 'primary remained stale'
    [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$expected" ] || fail 'secondmate remained stale'
    [ "$(git -C "$w/main" rev-list --count "$before..HEAD")" = 1 ] || fail 'sync created a commit'
    git -C "$w/fork.git" show-ref --verify --quiet refs/tags/private-tag && fail 'sync pushed unrelated tag'
    [ "$(wc -l < "$w/fake/api-calls" | tr -d ' ')" = 1 ] || fail 'shared object store synchronized twice'
    out=$(run_update "$w") || fail 'repeat fork update failed'
    assert_contains "$out" 'firstmate: already current' "repeat converges"
    assert_not_contains "$out" 'fork sync: fast-forwarded' "repeat does not push"
    pass "fork origin spelled $spelling: custom default, safe push, worktree convergence, idempotence"
  done
}

test_authoritative_origin_noop() {
  local w before out
  w=$(new_world authoritative)
  new_fork_world "$w"
  # The origin name stays operator/firstmate, but GitHub says it is authoritative.
  printf 'fork: false\nname: operator/firstmate\nbranch: main\nparent: "-"\nparentBranch: "-"\n' > "$w/fake/metadata"
  git -C "$w/main" remote add upstream https://github.com/unrelated/other.git
  before=$(git -C "$w/fork.git" rev-parse main)
  advance_parent "$w"
  out=$(run_update "$w") || fail 'authoritative origin no-op failed'
  assert_contains "$out" 'firstmate: already current' "non-fork origin is authoritative"
  assert_not_contains "$out" 'fork sync:' "no fork synchronization"
  [ "$(git -C "$w/fork.git" rev-parse main)" = "$before" ] || fail 'non-fork changed'
  pass 'authoritative origin is a no-op even with an unrelated upstream remote'
}

# A push-to-mirrors origin (git remote set-url --add) is an ordinary supported
# config: Git fetches from the first URL, so discovery must classify that one
# rather than refusing the whole update.
test_fork_sync_with_mirror_origin() {
  local w expected out
  w=$(new_world fork-mirror)
  new_fork_world "$w"
  git -C "$w/main" config --add remote.origin.url https://github.com/operator/mirror.git
  advance_parent "$w"
  expected=$(git -C "$w/origin.git" rev-parse main)
  out=$(run_update "$w") || fail "a mirrored origin blocked the update: $out"
  assert_contains "$out" 'fork sync: fast-forwarded operator/firstmate/main' \
    'a second origin URL must not suppress fork synchronization'
  [ "$(git -C "$w/fork.git" rev-parse main)" = "$expected" ] || fail 'mirrored origin left the fork stale'
  pass 'a push-to-mirrors origin still synchronizes the fork'
}

# "Preserve the no-fork case as a no-op": an authoritative origin must take none
# of the new machinery. A long-standing checkout on master whose GitHub default
# has since been renamed to main must still fast-forward master, not be skipped
# because origin/HEAD was repointed at a branch no fork sync needed.
test_authoritative_origin_keeps_local_default() {
  local w expected out
  w=$(new_world authoritative-renamed)
  new_fork_world "$w" master
  printf 'fork: false\nname: operator/firstmate\nbranch: main\nparent: "-"\nparentBranch: "-"\n' \
    > "$w/fake/metadata"
  # Cloned back when the GitHub default was still master.
  git -C "$w/main" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  git clone -q "$w/fork.git" "$w/authoritative-writer"
  printf 'authoritative advance\n' >> "$w/authoritative-writer/README.md"
  git -C "$w/authoritative-writer" commit -qam authoritative-advance
  git -C "$w/authoritative-writer" push -q origin master
  expected=$(git -C "$w/fork.git" rev-parse master)
  out=$(run_update "$w") || fail "authoritative origin failed to update: $out"
  assert_contains "$out" 'firstmate: updated ' 'a non-fork origin must still fast-forward its own default'
  assert_not_contains "$out" 'expected main' 'a non-fork origin must not have origin/HEAD repointed'
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] || fail 'authoritative origin remained stale'
  pass 'an authoritative origin keeps its own default branch untouched'
}

# The fork verdict describes ONE object store, but a fleet can hold several: a
# standalone-clone home carries its own origin, and fetch_once memoizes per
# git-common-dir. The verdict must ride that memo - otherwise a worktree of an
# unverified store inherits whichever store happened to be fetched most recently
# and claims currency the run never checked.
test_fork_unverified_is_per_object_store() {
  local w out
  w=$(new_world fork-multi-store)
  new_fork_world "$w"
  touch "$w/fake/api-fail"
  advance_parent "$w"
  # Its own origin is a local path, so its discovery succeeds and clears the
  # verdict. Sorting before zmate puts that reset between the primary's
  # unverified store and zmate's cache hit on that same store.
  git clone -q "$w/origin.git" "$w/aclone"
  git -C "$w/aclone" checkout -q --detach HEAD
  printf 'aclone\n' > "$w/aclone/.fm-secondmate-home"
  {
    printf 'window=main:fm-aclone\n'
    printf 'endpoint_task_id=aclone\n'
    printf 'kind=secondmate\n'
    printf 'harness=claude\n'
    printf 'home=%s/aclone\n' "$w"
  } > "$w/home/state/aclone.meta"
  printf 'fm-aclone\n' >> "$w/fake/windows"
  add_sm "$w" zmate
  out=$(run_update "$w") || fail "multi-store update failed: $out"
  assert_contains "$out" 'firstmate: cannot confirm current' \
    'the primary store is the unverified one'
  assert_contains "$out" 'secondmate aclone: already current' \
    'a clone with its own non-GitHub origin is verified on its own terms'
  assert_contains "$out" 'secondmate zmate: cannot confirm current' \
    'a worktree of the unverified store must not inherit another store verdict'
  pass 'the fork verdict is per object store, not per run'
}

# PROPERTY 1: only a fork that IS established and genuinely could not be
# synchronized fails the whole update. An ordinary unreachable origin - offline,
# VPN down - is a reported skip, exit unchanged, exactly as before this change.
test_offline_clone_does_not_fail_the_fleet() {
  local w out
  w=$(new_world offline-clone)
  git clone -q "$w/origin.git" "$w/aclone"
  git -C "$w/aclone" checkout -q --detach HEAD
  printf 'aclone\n' > "$w/aclone/.fm-secondmate-home"
  {
    printf 'window=main:fm-aclone\n'
    printf 'endpoint_task_id=aclone\n'
    printf 'kind=secondmate\n'
    printf 'harness=claude\n'
    printf 'home=%s/aclone\n' "$w"
  } > "$w/home/state/aclone.meta"
  printf 'fm-aclone\n' >> "$w/fake/windows"
  # Its origin is a local path: no fork to synchronize, just an unreachable one.
  git -C "$w/aclone" remote set-url origin "$w/vanished.git"
  printf 'more\n' >> "$w/seed/README.md"
  git -C "$w/seed" commit -qam advance
  git -C "$w/seed" push -q origin main
  out=$(run_update "$w") \
    || fail "an unreachable clone origin must not fail the whole update: $out"
  assert_contains "$out" 'firstmate: updated ' 'the reachable primary still advances'
  assert_contains "$out" 'secondmate aclone: skipped: fetch failed' 'the offline clone is reported'
  assert_contains "$out" 'origin-verified: no' 'a skipped origin fast-forward is not authoritative'
  pass 'an ordinary unreachable origin is a skip, not a whole-fleet failure'
}

test_fork_ahead_preserves_commits() {
  local w expected out
  w=$(new_world fork-ahead)
  new_fork_world "$w"
  git clone -q "$w/fork.git" "$w/fork-writer"
  printf 'fork-only\n' > "$w/fork-writer/unique"
  git -C "$w/fork-writer" add unique
  git -C "$w/fork-writer" commit -qm fork-only
  git -C "$w/fork-writer" push -q origin main
  expected=$(git -C "$w/fork.git" rev-parse main)
  out=$(run_update "$w") || fail "ahead fork update failed: $out"
  assert_contains "$out" 'firstmate: updated ' "ahead fork remains the update target"
  assert_not_contains "$out" 'fork sync: fast-forwarded' "ahead fork is never reset"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$expected" ] || fail 'ahead fork commit lost'
  [ "$(git -C "$w/fork.git" rev-parse main)" = "$expected" ] || fail 'ahead fork moved'
  pass 'fork ahead of upstream keeps its existing commits'
}

test_fork_failures() {
  local mode w before fork_before out rc
  for mode in unclassifiable mismatch diverged reject offline; do
    w=$(new_world "fork-fail-$mode")
    new_fork_world "$w"
    before=$(git -C "$w/main" rev-parse HEAD)
    advance_parent "$w"
    case "$mode" in
      unclassifiable) git -C "$w/main" remote set-url origin 'https://github.com/operator' ;;
      mismatch) sed 's/parentBranch: main/parentBranch: different/' "$w/fake/metadata" > "$w/fake/new"; mv "$w/fake/new" "$w/fake/metadata" ;;
      diverged)
        git clone -q "$w/fork.git" "$w/fork-writer"
        printf 'fork-only\n' > "$w/fork-writer/unique"
        git -C "$w/fork-writer" add unique
        git -C "$w/fork-writer" commit -qm fork-only
        git -C "$w/fork-writer" push -q origin main
        ;;
      reject)
        printf '#!/bin/sh\necho "protected fork branch" >&2\nexit 1\n' > "$w/fork.git/hooks/pre-receive"
        chmod +x "$w/fork.git/hooks/pre-receive"
        ;;
      offline) mv "$w/origin.git" "$w/offline.git" ;;
    esac
    fork_before=$(git -C "$w/fork.git" rev-parse main)
    rc=0
    out=$(run_update "$w") || rc=$?
    [ "$rc" -ne 0 ] || fail "$mode synchronization falsely succeeded"
    assert_contains "$out" 'firstmate: skipped: fork' "$mode is actionable"
    assert_not_contains "$out" 'already current' "$mode must not report current"
    assert_contains "$out" 'restart-secondmates: none' "$mode must not restart"
    [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "$mode moved local HEAD"
    [ "$(git -C "$w/fork.git" rev-parse main)" = "$fork_before" ] || fail "$mode lost fork work"
    pass "fork $mode failure is visible and preserves both tips"
  done
}

# Discovery that cannot answer leaves fork-ness UNKNOWN, not absent. The ordinary
# Git origin update must still run rather than taking the home down, but the run
# must never claim currency it did not verify: with upstream ahead of the fork,
# "already current" would be a false statement on the channel callers read.
test_fork_discovery_fallback() {
  local mode w before out
  for mode in auth malformed; do
    w=$(new_world "fork-fallback-$mode")
    new_fork_world "$w"
    case "$mode" in
      auth) touch "$w/fake/api-fail" ;;
      malformed) printf 'api_response:\n  body: null\n' > "$w/fake/metadata" ;;
    esac
    before=$(git -C "$w/fork.git" rev-parse main)
    advance_parent "$w"
    out=$(run_update "$w") || fail "$mode discovery blocked the ordinary origin update"
    assert_contains "$out" 'fork sync: discovery unavailable for operator/firstmate' \
      "$mode discovery failure is announced"
    assert_contains "$out" 'firstmate: cannot confirm current: fork sync unavailable' \
      "$mode must report the result as unverified"
    assert_not_contains "$out" 'already current' \
      "$mode must never claim currency it could not check"
    [ "$(git -C "$w/fork.git" rev-parse main)" = "$before" ] || fail "$mode touched the fork"
    pass "fork discovery $mode falls back to plain Git without claiming currency"
  done
}

# The gh-axi metadata record is an owned wire contract between the discovery call
# and its decoder: flat "<key>: <value>" lines for exactly fork, name, branch,
# parent and parentBranch, as the real CLI emits for this --jq selection. Pin it
# by behavior - the documented shape must drive a real fork sync, and a drifted
# shape must degrade to the visible unverified path, never to a silent success.
test_gh_axi_record_contract() {
  local shape w expected out
  for shape in real absent-parent json reordered-extra; do
    w=$(new_world "gh-axi-$shape")
    new_fork_world "$w"
    case "$shape" in
      real) printf 'fork: true\nname: operator/firstmate\nbranch: main\nparent: author/firstmate\nparentBranch: main\n' \
        > "$w/fake/metadata" ;;
      absent-parent) printf 'fork: false\nname: operator/firstmate\nbranch: main\nparent: "-"\nparentBranch: "-"\n' \
        > "$w/fake/metadata" ;;
      json) printf '{"fork":true,"name":"operator/firstmate","branch":"main","parent":"author/firstmate","parentBranch":"main"}\n' \
        > "$w/fake/metadata" ;;
      reordered-extra) printf 'branch: main\nfork: true\nname: operator/firstmate\nparent: author/firstmate\nparentBranch: main\nprivate: false\n' \
        > "$w/fake/metadata" ;;
    esac
    advance_parent "$w"
    expected=$(git -C "$w/origin.git" rev-parse main)
    out=$(run_update "$w") || fail "$shape record failed the update: $out"
    case "$shape" in
      real)
        assert_contains "$out" 'fork sync: fast-forwarded operator/firstmate/main' \
          "the real gh-axi record shape must drive a fork sync"
        [ "$(git -C "$w/fork.git" rev-parse main)" = "$expected" ] || fail 'fork remained stale'
        ;;
      absent-parent)
        assert_contains "$out" 'firstmate: already current' \
          'a decoded non-fork record is an ordinary no-op'
        assert_not_contains "$out" 'fork sync:' 'a non-fork record syncs nothing'
        ;;
      *)
        assert_contains "$out" 'firstmate: cannot confirm current: fork sync unavailable' \
          "a $shape record must surface as unverified, not as silent success"
        assert_not_contains "$out" 'fork sync: fast-forwarded' "a $shape record must not sync"
        ;;
    esac
    pass "gh-axi $shape metadata record is honoured by contract"
  done
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_bin_only_advance_restarts
test_unprovable_runtime_gets_fallback_nudge
test_dead_secondmate_gets_no_action
test_legacy_remote_advance_restarts
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_already_current_secondmate_still_restarts
test_already_current_unprovable_mate_is_nudged
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_primary_update_rebinds_local_watch

test_fork_update
test_authoritative_origin_noop
test_fork_failures
test_fork_discovery_fallback
test_gh_axi_record_contract
test_fork_sync_with_mirror_origin
test_authoritative_origin_keeps_local_default
test_fork_unverified_is_per_object_store
test_offline_clone_does_not_fail_the_fleet
test_fork_ahead_preserves_commits

echo "# all fm-update tests passed"
