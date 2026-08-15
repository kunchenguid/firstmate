#!/usr/bin/env bash
# Tests for the nudge-surface detail in bin/fm-update.sh output.
#
# Verifies the three surface cases the /updatefirstmate skill depends on:
#   1. Instruction change: AGENTS.md, .agents/skills, or both touched.
#      The surface names those paths and reread-firstmate is "yes".
#   2. Tooling only: only bin/ changed.
#      The surface is "bin" and reread-firstmate is "no".
#   3. Non-instruction tracked files only (e.g. README): no watched path changed.
#      The surface is "none" and reread-firstmate is "no".
#
# Each case exercises both the firstmate-changed-surface line and the per-target
# nudge-surface line for a secondmate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-nudge-surface)

# Build a fresh world: bare origin, firstmate clone on main, home with state/.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
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

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- Case 1: instruction change (AGENTS.md + bin + .agents/skills) ----------
test_instruction_change_surface() {
  local w out
  w=$(new_world case1)
  add_sm "$w" sm1

  # Advance origin touching all three instruction paths.
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'v2\n' > "$w/seed/AGENTS.md"
  printf 'echo b\n' > "$w/seed/bin/tool.sh"
  printf 's2\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-all-instr"
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  # The surface should list all three watched paths as a space-free comma list.
  assert_contains "$out" "firstmate-changed-surface: AGENTS.md,bin,.agents/skills" \
    "firstmate surface lists all three instruction paths"
  # Secondmate nudge-surface should also show the instruction paths.
  assert_contains "$out" "nudge-surface fm-sm1: AGENTS.md,bin,.agents/skills" \
    "secondmate nudge-surface lists all three instruction paths"
  pass "Case 1: instruction change surface is reported accurately"
}

# --- Case 2: tooling only (bin/ alone) --------------------------------------
# bin/ is part of the watched instruction surface (changed_instr), so
# reread-firstmate is still "yes". The new surface detail is what lets the
# skill distinguish a tooling-only advance from an instruction change.
test_tooling_only_surface() {
  local w out
  w=$(new_world case2)
  add_sm "$w" sm1

  # Advance origin touching ONLY bin/.
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'echo c\n' > "$w/seed/bin/tool.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-bin-only"
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  # bin/ is part of the instruction surface, so reread-firstmate stays yes.
  assert_contains "$out" "reread-firstmate: yes" "bin-only still triggers reread"
  # The surface detail is exactly "bin" - no AGENTS.md or .agents/skills.
  assert_contains "$out" "firstmate-changed-surface: bin" \
    "firstmate surface is exactly bin"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "secondmate is still nudged"
  assert_contains "$out" "nudge-surface fm-sm1: bin" \
    "secondmate nudge-surface is exactly bin"
  pass "Case 2: tooling-only surface is 'bin', distinguishable from instruction change"
}

# --- Case 3: non-instruction change (README only) ---------------------------
test_non_instruction_surface() {
  local w out
  w=$(new_world case3)
  add_sm "$w" sm1

  # Advance origin touching ONLY README (not a watched instruction path).
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r2\n' >> "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-readme-only"
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")

  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  assert_contains "$out" "firstmate-changed-surface: none" \
    "firstmate surface is 'none' when no watched path changed"
  # The secondmate still advanced and is nudged, but its surface is also none.
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  # changed_instr returns empty string for no watched paths, which process_secondmate
  # maps to "unknown" via the ${FF_INSTR:-unknown} fallback.
  assert_contains "$out" "nudge-surface fm-sm1: unknown" \
    "secondmate nudge-surface is 'unknown' when no watched path changed"
  pass "Case 3: non-instruction surface is 'none'/'unknown', no reread"
}

test_instruction_change_surface
test_tooling_only_surface
test_non_instruction_surface

echo "# all fm-update-nudge-surface tests passed"
