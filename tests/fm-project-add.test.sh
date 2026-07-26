#!/usr/bin/env bash
# Behavior tests for bin/fm-project-add.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-project-add)
SCRIPT="$ROOT/bin/fm-project-add.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/tools")
NM_LOG="$TMP_ROOT/no-mistakes.log"
: > "$NM_LOG"

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "${FM_FAKE_NO_MISTAKES_FAIL:-}" = "${1:-}" ]; then exit 17; fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

make_home() {
  local home=$1
  mkdir -p "$home/bin" "$home/data" "$home/projects" "$home/state"
  printf '# Firstmate test home\n' > "$home/AGENTS.md"
}

make_origin() {
  local source="$TMP_ROOT/source-$1" remote="$TMP_ROOT/remotes/$1.git"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$remote")"
  git clone --quiet --bare "$source" "$remote"
  printf 'file://%s\n' "$(cd "$remote" && pwd -P)"
}

run_add() {
  PATH="$FAKEBIN:$PATH" FM_FAKE_NO_MISTAKES_LOG="$NM_LOG" "$SCRIPT" "$@"
}

CURRENT_HOME="$TMP_ROOT/current home"
make_home "$CURRENT_HOME"
ALPHA_ORIGIN=$(make_origin alpha)
out=$(FM_HOME="$CURRENT_HOME" run_add --name alpha --description "alpha service" "$ALPHA_ORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "current-home clone"
assert_contains "$out" "home=$CURRENT_HOME" "current-home clone did not report its target"
assert_present "$CURRENT_HOME/projects/alpha/.git" "current-home clone is missing"
assert_present "$CURRENT_HOME/projects/alpha/.no-mistakes-init" "current-home clone was not initialized"
assert_present "$CURRENT_HOME/projects/alpha/.no-mistakes-doctor" "current-home clone was not doctored"
[ "$(git -C "$CURRENT_HOME/projects/alpha" remote get-url origin)" = "$ALPHA_ORIGIN" ] \
  || fail "current-home clone did not preserve origin"
EXPECTED_ALPHA="- alpha [no-mistakes] - alpha service (added $(date +%F))"
[ "$(grep -F -- '- alpha ' "$CURRENT_HOME/data/projects.md")" = "$EXPECTED_ALPHA" ] \
  || fail "current-home registry entry is incorrect"
[ "$(FM_HOME="$CURRENT_HOME" "$ROOT/bin/fm-project-mode.sh" alpha)" = "no-mistakes off" ] \
  || fail "current-home registry posture is not parseable"
pass "project-add clones, initializes, and registers a URL in the current home"

SOURCE_HOME="$TMP_ROOT/source home"
SECOND_HOME="$TMP_ROOT/secondmate home"
make_home "$SOURCE_HOME"
make_home "$SECOND_HOME"
BETA_ORIGIN=$(make_origin beta)
git clone --quiet -- "$BETA_ORIGIN" "$SOURCE_HOME/projects/beta"
BETA_LINE="- beta [no-mistakes +yolo] - beta customer portal (added 2026-07-01)"
printf '%s\n' "$BETA_LINE" > "$SOURCE_HOME/data/projects.md"
out=$(FM_HOME="$SOURCE_HOME" run_add --home "$SECOND_HOME" beta 2>&1); rc=$?
expect_code 0 "$rc" "secondmate-home clone"
assert_contains "$out" "home=$SECOND_HOME" "secondmate-home clone did not report the target home"
assert_present "$SECOND_HOME/projects/beta/.git" "registered project was not cloned into the secondmate home"
assert_present "$SECOND_HOME/projects/beta/.no-mistakes-init" "registered no-mistakes project was not initialized"
[ "$(grep -F -- '- beta ' "$SECOND_HOME/data/projects.md")" = "$BETA_LINE" ] \
  || fail "registered project line was not preserved in the secondmate registry"
[ "$(FM_HOME="$SECOND_HOME" "$ROOT/bin/fm-project-mode.sh" beta)" = "no-mistakes on" ] \
  || fail "secondmate registry did not preserve delivery posture"
assert_absent "$SOURCE_HOME/projects/beta/.no-mistakes-init" "registered source clone was mutated"
pass "project-add resolves a registered origin and targets a different Firstmate home"

DIRECT_HOME="$TMP_ROOT/direct PR home"
make_home "$DIRECT_HOME"
DELTA_ORIGIN=$(make_origin delta)
out=$(FM_HOME="$DIRECT_HOME" run_add --name delta --mode direct-PR --description "delta utility" --yolo "$DELTA_ORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "direct-PR clone"
[ "$(FM_HOME="$DIRECT_HOME" "$ROOT/bin/fm-project-mode.sh" delta)" = "direct-PR on" ] \
  || fail "explicit direct-PR posture was not registered"
assert_absent "$DIRECT_HOME/projects/delta/.no-mistakes-init" "direct-PR clone ran no-mistakes initialization"
pass "project-add records explicit delivery posture and initializes only no-mistakes projects"

ALPHA_HEAD=$(git -C "$CURRENT_HOME/projects/alpha" rev-parse HEAD)
ALPHA_REGISTRY=$(cksum < "$CURRENT_HOME/data/projects.md")
out=$(FM_HOME="$CURRENT_HOME" run_add --name alpha "$ALPHA_ORIGIN" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "project-add clobbered an existing clone"
assert_contains "$out" "refusing to clobber existing project path" "existing-clone refusal was not explicit"
[ "$(git -C "$CURRENT_HOME/projects/alpha" rev-parse HEAD)" = "$ALPHA_HEAD" ] \
  || fail "existing clone changed after refusal"
[ "$(cksum < "$CURRENT_HOME/data/projects.md")" = "$ALPHA_REGISTRY" ] \
  || fail "registry changed after existing-clone refusal"
pass "project-add refuses an existing clone without changing it or the registry"

BAD_HOME="$TMP_ROOT/bad remote home"
make_home "$BAD_HOME"
BAD_ORIGIN="file://$TMP_ROOT/remotes/does-not-exist.git"
out=$(FM_HOME="$BAD_HOME" run_add --name broken "$BAD_ORIGIN" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "project-add accepted a bad remote"
assert_contains "$out" "failed to clone" "bad-remote failure was not explained"
assert_absent "$BAD_HOME/projects/broken" "bad remote left a partial clone"
assert_absent "$BAD_HOME/data/projects.md" "bad remote wrote a registry entry"
pass "project-add fails closed on a bad remote"

INIT_HOME="$TMP_ROOT/init failure home"
make_home "$INIT_HOME"
GAMMA_ORIGIN=$(make_origin gamma)
out=$(FM_FAKE_NO_MISTAKES_FAIL=doctor FM_HOME="$INIT_HOME" \
  run_add --name gamma "$GAMMA_ORIGIN" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "project-add accepted failed no-mistakes initialization"
assert_contains "$out" "failed to initialize no-mistakes" "initialization failure was not explained"
assert_absent "$INIT_HOME/projects/gamma" "initialization failure left the new clone"
assert_absent "$INIT_HOME/data/projects.md" "initialization failure wrote a registry entry"
pass "project-add rolls back only its new clone when initialization fails"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$SCRIPT" "$ROOT/tests/fm-project-add.test.sh" \
    || fail "project-add owner and test must be shellcheck-clean"
fi
pass "project-add owner and test are shellcheck-clean"
