#!/usr/bin/env bash
# Behavior tests for bin/fm-tool-wiring.sh: the skill, brief include and merge
# gate that ship inside the pinned done-done and sign-off packages are wired
# into a home once, and a second run changes nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tool-wiring)
WIRING="$ROOT/bin/fm-tool-wiring.sh"
INCLUDE_BEGIN='<!-- done-done brief include (managed by bin/fm-tool-wiring.sh) -->'

# make_case <name>: a fixture with a fake npm global root holding the two
# companion packages. Echoes the case dir.
make_case() {
  local name=$1 case_dir root fakebin
  case_dir="$TMP_ROOT/$name"
  root="$case_dir/npm-root"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$root/done-done-axi/skills/done-done" "$root/done-done-axi/integrations/firstmate" \
    "$root/sign-off-axi/skills/sign-off-axi" "$case_dir/home" "$case_dir/user-home"
  printf -- '---\nname: done-done\n---\nbody\n' > "$root/done-done-axi/skills/done-done/SKILL.md"
  printf -- '---\nname: sign-off-axi\n---\nbody\n' > "$root/sign-off-axi/skills/sign-off-axi/SKILL.md"
  printf '## Proof with done-done\nProve the real journey.\n' \
    > "$root/done-done-axi/integrations/firstmate/brief-include.md"
  printf '#!/bin/sh\necho "done-done: no receipt"\nexit 3\n' \
    > "$root/done-done-axi/integrations/firstmate/merge-gate"
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "'$root'" > "$fakebin/npm"
  chmod +x "$fakebin/npm"
  printf '%s\n' "$case_dir"
}

run_wiring() {  # <case-dir> <tool>
  local case_dir=$1
  shift
  HOME="$case_dir/user-home" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$case_dir/fakebin:$PATH" "$WIRING" "$@"
}

test_first_run_wires_skill_include_and_gate_once() {
  local case_dir before
  case_dir=$(make_case first-run)
  mkdir -p "$case_dir/home/config"
  printf 'Our own standing rule.\n' > "$case_dir/home/config/brief-include.md"

  run_wiring "$case_dir" done-done >/dev/null || fail "first-run: the wiring failed"

  [ -f "$case_dir/user-home/.agents/skills/done-done/SKILL.md" ] \
    || fail "first-run: the done-done skill was not linked"
  assert_grep 'Prove the real journey.' "$case_dir/home/config/brief-include.md" \
    "first-run: the include carried no shipped text"
  assert_grep 'Our own standing rule.' "$case_dir/home/config/brief-include.md" \
    "first-run: the wiring dropped a line the home already had"
  [ -x "$case_dir/home/config/merge-gate" ] \
    || fail "first-run: the merge gate was not placed executable"
  before="$case_dir/before.md"
  cp "$case_dir/home/config/brief-include.md" "$before"

  run_wiring "$case_dir" done-done >/dev/null || fail "second-run: the wiring failed"

  cmp -s "$before" "$case_dir/home/config/brief-include.md" \
    || fail "second-run: a second run changed the brief include"
  [ "$(grep -c "^$INCLUDE_BEGIN\$" "$case_dir/home/config/brief-include.md")" = 1 ] \
    || fail "second-run: a second run duplicated the include"
  pass "a first run links the skill, writes the include block and places the gate, and a second run is a no-op"
}

test_an_existing_gate_is_never_replaced() {
  local case_dir
  case_dir=$(make_case existing-gate)
  mkdir -p "$case_dir/home/config"
  printf '#!/bin/sh\nexec owner-guard merge-gate "$@"\n' > "$case_dir/home/config/merge-gate"
  chmod +x "$case_dir/home/config/merge-gate"
  cp "$case_dir/home/config/merge-gate" "$case_dir/gate-before"

  run_wiring "$case_dir" done-done >/dev/null || fail "existing-gate: the wiring failed"

  cmp -s "$case_dir/gate-before" "$case_dir/home/config/merge-gate" \
    || fail "existing-gate: a chained gate was overwritten"
  pass "wiring never replaces a gate the home already chains"
}

test_an_absent_package_is_a_silent_no_op() {
  local case_dir rc
  case_dir=$(make_case absent-package)
  rm -rf -- "$case_dir/npm-root/done-done-axi"

  run_wiring "$case_dir" done-done > "$case_dir/out" 2>&1
  rc=$?

  [ "$rc" -eq 0 ] || fail "absent-package: a missing package failed a session start (exit $rc)"
  [ ! -s "$case_dir/out" ] || fail "absent-package: a missing package was reported: $(cat "$case_dir/out")"
  assert_absent "$case_dir/home/config/brief-include.md" \
    "absent-package: a missing package still wrote the include"
  pass "an absent companion package is left alone silently"
}

test_sign_off_links_its_skill_and_says_how_to_arm_once() {
  local case_dir out
  case_dir=$(make_case sign-off)

  out=$(run_wiring "$case_dir" sign-off) || fail "sign-off: the wiring failed"

  [ -f "$case_dir/user-home/.agents/skills/sign-off-axi/SKILL.md" ] \
    || fail "sign-off: the sign-off skill was not linked"
  printf '%s\n' "$out" | grep -F 'bin/fm-procevent-signoff.sh arm' >/dev/null \
    || fail "sign-off: the first wiring did not say how to arm the home"
  assert_absent "$case_dir/home/config/merge-gate" \
    "sign-off: wiring sign-off placed the done-done gate"
  out=$(run_wiring "$case_dir" sign-off) || fail "sign-off: the second wiring failed"
  [ -z "$out" ] || fail "sign-off: an already wired home repeated itself: $out"
  pass "wiring sign-off links its skill, says how to arm once, and never arms"
}

test_first_run_wires_skill_include_and_gate_once
test_an_existing_gate_is_never_replaced
test_an_absent_package_is_a_silent_no_op
test_sign_off_links_its_skill_and_says_how_to_arm_once
echo "all fm-tool-wiring tests passed"
