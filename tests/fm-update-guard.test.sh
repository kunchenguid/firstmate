#!/usr/bin/env bash
# Tests for the update-guard (bin/fm-update-guard-lib.sh) and its one hook point
# in ff_target (bin/fm-ff-lib.sh).
#
# The guarantee under test: a home never fast-forwards onto a commit that has
# quietly disarmed the fleet - a deleted gate, an unregistered hook, a rule gate
# that is already red on the incoming commit's own rulebook. The advance itself
# was always safe; what was unsafe was what the advanced-to commit no longer
# contained, and that was invisible because a fast-forward reports the same way
# whether it lands a typo fix or removes every guard in bin/.
#
# Covered here:
#   - unarmed (no state/.tor-update-scharf) => total silence, the advance
#     happens exactly as before (this is what keeps every other ff/update test
#     green during the transition);
#   - armed + intact target => the advance happens, the target's OWN
#     bin/fm-regel-eval.sh actually ran, a green line is in the gate log;
#   - armed + broken target (missing exec, unregistered hook, red regel-eval)
#     => "skipped: update-guard red at <commit>", the working copy is untouched,
#     and no verification worktree is left behind;
#   - the same refusal on a secondmate home, proving the hook sits at the ONE
#     place all advances pass rather than on the firstmate path only;
#   - FM_UPDATE_GUARD_SKIP=1 passes loudly and is logged as an exit taken;
#   - a golden row whose fixture does not exist yet warns instead of refusing;
#   - the shipped regeln/INVARIANTEN.tsv is well-formed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"
GUARD_LIB="$ROOT/bin/fm-update-guard-lib.sh"
INVARIANTEN="$ROOT/regeln/INVARIANTEN.tsv"
TAB=$(printf '\t')

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-guard-tests)

# Write the fixture invariant list into <dir>.
write_list() {
  local dir=$1
  mkdir -p "$dir/regeln"
  {
    printf '# fixture invariant list\n'
    printf 'pfad%sregeln/kern.yaml%sthe fixture rule file\n' "$TAB" "$TAB"
    printf 'exec%sbin/tor-a.sh%sthe fixture gate\n' "$TAB" "$TAB"
    printf 'exec%sbin/tor-lib.sh%sthe fixture sourced lib\n' "$TAB" "$TAB"
    printf 'hook%sPreToolUse:tor-a.sh%sthe gate registration\n' "$TAB" "$TAB"
    printf 'golden%stests/golden.tsv%snot built yet - must warn, never refuse\n' "$TAB" "$TAB"
  } > "$dir/regeln/INVARIANTEN.tsv"
}

# Build a world whose seed commit carries a miniature fleet: a rule file, two
# tools (one executable, one sourced lib), a hook registration, a stand-in
# bin/fm-regel-eval.sh, and its own regeln/INVARIANTEN.tsv naming all of them.
# The stand-in regel-eval records that it ran (so we can prove the guard runs the
# TARGET's copy) and goes red when regeln/REGEL-EVAL-RED is present.
# Pass "nolist" as the second argument for a mid-transition home whose checkout
# carries no regeln/INVARIANTEN.tsv at all.
new_world() {
  local name=$1 list=${2:-list} w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  mkdir -p "$w/seed/bin" "$w/seed/regeln" "$w/seed/.claude"
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  printf 'regeln: kern\n' > "$w/seed/regeln/kern.yaml"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/tor-a.sh"
  chmod +x "$w/seed/bin/tor-a.sh"
  printf '# shellcheck shell=bash\ntor_lib_fn() { :; }\n' > "$w/seed/bin/tor-lib.sh"
  cat > "$w/seed/bin/fm-regel-eval.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_GUARD_TEST_MARKER:-}" ] || printf 'ran %s\n' "${FM_ROOT_OVERRIDE:-?}" >> "$FM_GUARD_TEST_MARKER"
if [ -f "${FM_ROOT_OVERRIDE:-.}/regeln/REGEL-EVAL-RED" ]; then
  echo "VIOLATION: fixture rulebook is red"
  exit 1
fi
echo "regel-eval: gate passed"
SH
  chmod +x "$w/seed/bin/fm-regel-eval.sh"
  cat > "$w/seed/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tor-a.sh --claude" }
        ]
      }
    ]
  }
}
JSON
  [ "$list" = nolist ] || write_list "$w/seed"

  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

# Add a secondmate home as a detached worktree plus its state meta.
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

# Advance origin by one commit. mode:
#   good        - harmless README change, every invariant still satisfied
#   drop-exec   - deletes bin/tor-a.sh (a gate vanishes)
#   drop-hook   - unregisters the PreToolUse hook (the gate stops being law)
#   eval-red    - makes the target's own regel-eval check fail
#   add-list-drop-exec - the target both introduces the invariant list and
#                 deletes a gate (the fallback path for a home that has no list)
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  case "$mode" in
    good) ;;
    drop-exec) git -C "$w/seed" rm -q bin/tor-a.sh ;;
    drop-hook) printf '{ "hooks": { "PreToolUse": [] } }\n' > "$w/seed/.claude/settings.json" ;;
    eval-red) printf 'red\n' > "$w/seed/regeln/REGEL-EVAL-RED" ;;
    add-list-drop-exec)
      write_list "$w/seed"
      git -C "$w/seed" rm -q bin/tor-a.sh
      ;;
    *) fail "unknown bump mode $mode" ;;
  esac
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

arm() { touch "$1/home/state/.tor-update-scharf"; }

# Run the real fm-update.sh against the fixture. stdout is returned; stderr is
# parked in $w/err so the loud lines can be asserted separately.
run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" FM_GUARD_TEST_MARKER="$w/marker" \
    "$UPDATE" 2>"$w/err"
}

worktree_count() { git -C "$1" worktree list | wc -l | tr -d ' '; }

# --- T1: unarmed gate is invisible -----------------------------------------
# The transition contract: until state/.tor-update-scharf exists, the guard must
# not change a single advance - this is what keeps fm-update / fm-ff / secondmate
# sync tests green while the gate is built.
test_unarmed_is_silent() {
  local w out
  w=$(new_world t1)
  bump_origin "$w" drop-exec

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "unarmed gate must not block the advance"
  assert_not_contains "$out" "update-guard" "unarmed gate must not speak on stdout"
  assert_not_contains "$(cat "$w/err" 2>/dev/null || true)" "update-guard" \
    "unarmed gate must not speak on stderr"
  [ ! -e "$w/home/state/tor-log/update.jsonl" ] \
    || fail "unarmed gate wrote a log line (it never looked)"
  pass "T1 unarmed update-guard passes in total silence"
}

# --- T2: armed + intact target advances, and the TARGET's rule gate ran -----
test_armed_green_target_advances() {
  local w out err
  w=$(new_world t2)
  arm "$w"
  bump_origin "$w" good

  out=$(run_update "$w")
  err=$(cat "$w/err")

  assert_contains "$out" "firstmate: updated " "intact target still advances"
  assert_not_contains "$out" "update-guard red" "intact target must not be refused"
  # The guard ran the TARGET commit's own regel-eval, not the running repo's.
  assert_present "$w/marker" "target's own bin/fm-regel-eval.sh did not run"
  # A golden row whose fixture does not exist yet warns, it does not refuse.
  assert_contains "$err" "golden fixture tests/golden.tsv does not exist yet" \
    "missing golden fixture must warn"
  assert_grep '"verdikt":"gruen"' "$w/home/state/tor-log/update.jsonl" \
    "armed green passage is not in the gate log"
  pass "T2 armed guard lets an intact target through, runs its rule gate, logs green"
}

# --- T3: a deleted gate refuses the advance, working copy untouched ---------
test_dropped_gate_refuses() {
  local w out err before wt_before
  w=$(new_world t3)
  arm "$w"
  before=$(git -C "$w/main" rev-parse HEAD)
  wt_before=$(worktree_count "$w/main")
  bump_origin "$w" drop-exec

  out=$(run_update "$w")
  err=$(cat "$w/err")

  assert_contains "$out" "firstmate: skipped: update-guard red at " \
    "target that deletes a gate must be refused"
  assert_contains "$err" "missing tool bin/tor-a.sh" "refusal must name the broken invariant"
  assert_contains "$err" "FM_UPDATE_GUARD_SKIP=1" "refusal must name its Ausweg"
  assert_contains "$out" "reread-firstmate: no" "a refused advance changes no instructions"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "refused home moved anyway"
  [ -z "$(git -C "$w/main" status --porcelain)" ] || fail "refused advance dirtied the working copy"
  assert_present "$w/main/bin/tor-a.sh" "the gate vanished from the untouched working copy"
  [ "$(worktree_count "$w/main")" = "$wt_before" ] \
    || fail "verification worktree was left behind"
  assert_grep '"verdikt":"rot"' "$w/home/state/tor-log/update.jsonl" \
    "refusal is not in the gate log"
  pass "T3 a target with a deleted gate is refused, home and worktrees untouched"
}

# --- T4: an unregistered hook refuses too -----------------------------------
test_dropped_hook_refuses() {
  local w out err
  if ! command -v jq >/dev/null 2>&1; then
    pass "T4 skipped: jq not installed (hook rows are unverifiable without it)"
    return 0
  fi
  w=$(new_world t4)
  arm "$w"
  bump_origin "$w" drop-hook

  out=$(run_update "$w")
  err=$(cat "$w/err")

  assert_contains "$out" "firstmate: skipped: update-guard red at " \
    "target that unregisters a hook must be refused"
  assert_contains "$err" "hook PreToolUse:tor-a.sh is not registered" \
    "refusal must name the missing hook registration"
  pass "T4 a target that unregisters a gate hook is refused"
}

# --- T5: the target's own rule gate must pass on the target ------------------
test_red_regel_eval_refuses() {
  local w out err
  w=$(new_world t5)
  arm "$w"
  bump_origin "$w" eval-red

  out=$(run_update "$w")
  err=$(cat "$w/err")

  assert_contains "$out" "firstmate: skipped: update-guard red at " \
    "target whose own regel-eval is red must be refused"
  assert_contains "$err" "regel-eval check fails on the target itself" \
    "refusal must attribute the failure to the target's rule gate"
  assert_contains "$err" "fixture rulebook is red" "refusal must quote regel-eval's own violation"
  pass "T5 a target whose own regel-eval check fails is refused"
}

# --- T6: the emergency exit passes, loudly and logged -----------------------
test_env_ausweg_passes_loudly() {
  local w out err
  w=$(new_world t6)
  arm "$w"
  bump_origin "$w" drop-exec

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" FM_UPDATE_GUARD_SKIP=1 \
    "$UPDATE" 2>"$w/err")
  err=$(cat "$w/err")

  assert_contains "$out" "firstmate: updated " "FM_UPDATE_GUARD_SKIP=1 must let the advance through"
  assert_contains "$err" "update-guard: SKIPPED by FM_UPDATE_GUARD_SKIP=1" \
    "the emergency exit must be loud"
  assert_grep '"ausweg":"FM_UPDATE_GUARD_SKIP"' "$w/home/state/tor-log/update.jsonl" \
    "the emergency exit must be logged as an exit taken"
  pass "T6 FM_UPDATE_GUARD_SKIP=1 passes loudly and leaves a trace"
}

# --- T7: the hook sits where ALL advances pass, not only the firstmate one ---
test_secondmate_advance_is_gated() {
  local w out before
  w=$(new_world t7)
  add_sm "$w" sm1
  arm "$w"
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" drop-exec

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: update-guard red at " \
    "a secondmate home must be gated by the same guard"
  assert_not_contains "$out" "nudge-secondmates: fm-sm1" "a refused secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] || fail "refused secondmate home moved"
  pass "T7 the guard covers secondmate advances through the same ff_target hook"
}

# --- T8: no invariant list anywhere - warn, and still run the rule gate ------
# Mid-transition an older home has no regeln/INVARIANTEN.tsv, and neither does
# the commit it is advancing to. That must warn and fall through to the target's
# rule gate, never silently declare everything green.
test_no_list_anywhere_warns_and_still_evaluates() {
  local w out err
  w=$(new_world t8 nolist)
  arm "$w"
  bump_origin "$w" eval-red

  out=$(run_update "$w")
  err=$(cat "$w/err")

  assert_contains "$err" "no regeln/INVARIANTEN.tsv" "a missing invariant list must warn"
  assert_contains "$out" "firstmate: skipped: update-guard red at " \
    "the target's rule gate must still decide when there is no invariant list"
  assert_contains "$err" "regel-eval check fails on the target itself" \
    "the rule gate must run even without an invariant list"
  pass "T8 no invariant list anywhere warns and still runs the target's rule gate"
}

# --- T8b: a home without a list falls back to the target's own copy ----------
test_missing_list_falls_back_to_target_copy() {
  local w out err before
  w=$(new_world t8b nolist)
  arm "$w"
  before=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" add-list-drop-exec

  out=$(run_update "$w")
  err=$(cat "$w/err")

  assert_contains "$out" "firstmate: skipped: update-guard red at " \
    "the target's own list must stand in when the running home has none"
  assert_contains "$err" "missing tool bin/tor-a.sh" "the fallback list must be the one that judged"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] || fail "refused home moved anyway"
  pass "T8b a home without a list is judged by the target commit's own copy"
}

# --- T9: the shipped invariant list is well-formed --------------------------
# Deliberately NOT "the current repo satisfies every row": the hook rows are the
# Flottenordnung v2 target state and land with the settings.json wiring. What
# must hold today is that every row parses and names a known art, so arming the
# gate is a one-touch decision and never a debugging session.
test_shipped_list_is_wellformed() {
  local rows=0 art ziel rest
  [ -f "$INVARIANTEN" ] || fail "regeln/INVARIANTEN.tsv is missing"
  while IFS="$TAB" read -r art ziel rest || [ -n "${art:-}" ]; do
    case "${art:-}" in ''|'#'*) continue ;; esac
    rows=$((rows + 1))
    case "$art" in
      pfad|exec|hook|golden) ;;
      *) fail "regeln/INVARIANTEN.tsv row '$art' has an unknown art (pfad|exec|hook|golden)" ;;
    esac
    [ -n "$ziel" ] || fail "regeln/INVARIANTEN.tsv row '$art' has no target"
    [ -n "$rest" ] || fail "regeln/INVARIANTEN.tsv row '$art $ziel' has no description"
    if [ "$art" = hook ]; then
      case "$ziel" in
        *:*) ;;
        *) fail "hook row '$ziel' is not <event>:<script>" ;;
      esac
    fi
  done < "$INVARIANTEN"
  [ "$rows" -ge 10 ] || fail "regeln/INVARIANTEN.tsv carries only $rows row(s)"
  bash -n "$GUARD_LIB" || fail "bin/fm-update-guard-lib.sh does not parse"
  pass "T9 shipped regeln/INVARIANTEN.tsv is well-formed ($rows rows)"
}

test_unarmed_is_silent
test_armed_green_target_advances
test_dropped_gate_refuses
test_dropped_hook_refuses
test_red_regel_eval_refuses
test_env_ausweg_passes_loudly
test_secondmate_advance_is_gated
test_no_list_anywhere_warns_and_still_evaluates
test_missing_list_falls_back_to_target_copy
test_shipped_list_is_wellformed

echo "# all fm-update-guard tests passed"
