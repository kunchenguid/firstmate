#!/usr/bin/env bash
# tests/fm-project-mode.test.sh - unit tests for the `forgejo` and `external`
# values of bin/fm-project-mode.sh's closed `forge=` registry binding. The
# binding's grammar, its Gerrit value, and its refusals are pinned in
# tests/fm-task-delivery.test.sh; this file covers only what forgejo and
# external add: forgejo binds in any token order, keeps +yolo (unlike gerrit),
# and is refused on local-only like every forge; external binds, reports
# yolo=off with a refusal like gerrit, and is refused on local-only; and the
# plain (no --forge/--raw) output stays exactly two words, because tests/fm-secondmate-safety.test.sh and
# tests/fm-secondmate-lifecycle-e2e.test.sh assert that shape with strict
# string equality.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode-tests)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"

cat > "$DATA/projects.md" <<'EOF'
## Projects
- legacy - a project registered before any bracket token existed (added 2026-01-01)
- flagged [direct-PR +yolo] - mode and yolo, no forge token (added 2026-01-01)
- lab [no-mistakes forge=forgejo] - forge token after mode (added 2026-01-01)
- lead [forge=forgejo direct-PR +yolo] - forge token first, order must not matter (added 2026-01-01)
- kept [local-only forge=forgejo] - a forge on a mode that publishes nothing (added 2026-01-01)
- colon [no-mistakes forge:forgejo] - a colon-spelled token is not a forge binding (added 2026-01-01)
- glabbed [no-mistakes forge=gitlab] - gitlab is not a forge value (added 2026-01-01)
- reviewed [direct-PR forge=external] - a review tool uploads its own snapshot (added 2026-01-01)
- reviewed-yolo [direct-PR +yolo forge=external] - +yolo cannot apply to an external review (added 2026-01-01)
- reviewed-local [local-only forge=external] - an external review on a mode that publishes nothing (added 2026-01-01)
- near-miss [direct-PR forg=external] - a near miss of the forge key (added 2026-01-01)
- hand [no-mistakes pr=manual] - the worker writes the PR text (added 2026-01-01)
- hand-first [pr=manual no-mistakes +yolo branch=] - pr token first, order must not matter (added 2026-01-01)
- hand-prod [no-mistakes-prod-only pr=manual] - conditional policy keeps the binding (added 2026-01-01)
- hand-direct [direct-PR pr=manual] - direct-PR already leaves the text to the worker (added 2026-01-01)
- hand-local [local-only pr=manual] - local-only opens no PR (added 2026-01-01)
- hand-forgejo [no-mistakes forge=forgejo pr=manual] - a bound forge (added 2026-01-01)
- hand-empty [no-mistakes pr=] - an empty value (added 2026-01-01)
- hand-auto [no-mistakes pr=auto] - auto is the absence of the token, not a value (added 2026-01-01)
- cli-tea [no-mistakes forge=forgejo:tea] - a Forgejo binding may name its CLI (added 2026-01-01)
- cli-fgj [forge=forgejo:fgj direct-PR +yolo] - CLI suffix first, order must not matter (added 2026-01-01)
- cli-fj [no-mistakes forge=forgejo:fj] - forgejo-cli by name (added 2026-01-01)
- cli-empty [direct-PR forge=forgejo:] - an empty CLI suffix (added 2026-01-01)
- cli-unknown [direct-PR forge=forgejo:glab] - an unknown CLI suffix (added 2026-01-01)
- cli-gerrit [no-mistakes forge=gerrit:tea] - a CLI suffix on another provider (added 2026-01-01)
EOF

run_mode() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" "$1" 2>/dev/null
}
run_forge() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge "$1" 2>/dev/null
}
run_forge_cli() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge-cli "$1" 2>/dev/null
}

[ "$(run_mode legacy)" = "no-mistakes off" ] || fail "legacy entry's default output changed: $(run_mode legacy)"
[ "$(run_forge legacy)" = "none" ] || fail "an entry with no forge token must report forge none: $(run_forge legacy)"
[ "$(run_mode flagged)" = "direct-PR on" ] || fail "flagged entry's mode/yolo output changed: $(run_mode flagged)"
[ "$(run_forge flagged)" = "none" ] || fail "mode and +yolo with no forge token must report forge none: $(run_forge flagged)"
pass "fm-project-mode: an entry with no forge token reports forge none and keeps its two-word default output"

[ "$(run_mode lab)" = "no-mistakes off" ] || fail "lab entry's mode output changed: $(run_mode lab)"
[ "$(run_forge lab)" = "forgejo" ] || fail "forge=forgejo after the mode token did not resolve: $(run_forge lab)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" lab 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered forge=forgejo warned: $err"
pass "fm-project-mode: forge=forgejo placed after the mode token binds forgejo without a warning"

[ "$(run_mode lead)" = "direct-PR on" ] || fail "forge=forgejo must keep +yolo, which only gerrit deactivates: $(run_mode lead)"
[ "$(run_forge lead)" = "forgejo" ] || fail "forge=forgejo placed before the mode token did not resolve: $(run_forge lead)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" lead 2>&1 >/dev/null)
[ -z "$err" ] || fail "+yolo on a forge=forgejo project was refused or warned: $err"
pass "fm-project-mode: forge=forgejo binds in any token order and keeps +yolo"

for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag kept 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "local-only with forge=forgejo did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused local-only forge still handed the caller a posture: '$out'"
done
pass "fm-project-mode: forge=forgejo on local-only is refused like every forge"

[ "$(run_mode colon)" = "no-mistakes off" ] || fail "a colon-spelled token changed the posture: $(run_mode colon)"
[ "$(run_forge colon)" = "none" ] || fail "forge:forgejo must not bind a forge; only forge=forgejo does: $(run_forge colon)"
pass "fm-project-mode: the colon spelling forge:forgejo is not a forge binding"

for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag glabbed 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "forge=gitlab did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused forge=gitlab still handed the caller a posture: '$out'"
done
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" glabbed 2>&1 >/dev/null) || true
assert_contains "$err" 'forge=forgejo' "the unknown-forge refusal did not name forge=forgejo as an accepted value"
assert_contains "$err" 'forge=external' "the unknown-forge refusal did not name forge=external as an accepted value"
pass "fm-project-mode: a value outside none|gerrit|forgejo|external is refused and the refusal names the accepted values"

[ "$(run_forge reviewed)" = "external" ] || fail "forge=external did not resolve: $(run_forge reviewed)"
[ "$(run_mode reviewed)" = "direct-PR off" ] || fail "forge=external changed the two-word output: $(run_mode reviewed)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" reviewed 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered forge=external warned: $err"
[ "$(run_mode reviewed-yolo)" = "direct-PR off" ] || fail "+yolo on forge=external must report yolo=off: $(run_mode reviewed-yolo)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" reviewed-yolo 2>&1 >/dev/null)
assert_contains "$err" "yolo is inactive for forge=external" "+yolo on forge=external was dropped without a refusal"
for flag in "" --forge; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag reviewed-local 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "local-only with forge=external did not refuse${flag:+ under $flag} (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused local-only external forge still handed the caller a posture: '$out'"
done
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" near-miss 2>&1 >/dev/null)
assert_contains "$err" "forge=external" "the near-miss warning does not list forge=external"
pass "fm-project-mode: forge=external binds direct-PR, reports yolo=off with a refusal, and is refused on local-only"

[ "$(run_forge missing-project)" = "none" ] || fail "a missing project must default --forge to none: $(run_forge missing-project)"
[ "$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --forge legacy 2>/dev/null)" = "none" ] \
  || fail "an absent registry file must default --forge to none"
pass "fm-project-mode: a missing project or absent registry defaults --forge to none"

run_pr() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --pr "$1" 2>/dev/null
}

[ "$(run_pr legacy)" = "auto" ] || fail "an entry with no pr token must report pr auto: $(run_pr legacy)"
[ "$(run_pr flagged)" = "auto" ] || fail "mode and +yolo with no pr token must report pr auto: $(run_pr flagged)"
[ "$(run_pr missing-project)" = "auto" ] || fail "a missing project must default --pr to auto: $(run_pr missing-project)"
[ "$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --pr legacy 2>/dev/null)" = "auto" ] \
  || fail "an absent registry file must default --pr to auto"
pass "fm-project-mode: an entry with no pr token, a missing project, or an absent registry reports pr auto"

[ "$(run_pr hand)" = "manual" ] || fail "pr=manual did not resolve: $(run_pr hand)"
[ "$(run_mode hand)" = "no-mistakes off" ] || fail "pr=manual changed the two-word output: $(run_mode hand)"
[ "$(run_forge hand)" = "none" ] || fail "pr=manual changed the forge: $(run_forge hand)"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" hand 2>&1 >/dev/null)
[ -z "$err" ] || fail "a registered pr=manual warned: $err"
[ "$(run_pr hand-first)" = "manual" ] || fail "pr=manual placed first did not resolve: $(run_pr hand-first)"
[ "$(run_mode hand-first)" = "no-mistakes on" ] || fail "pr=manual placed first displaced the mode or +yolo: $(run_mode hand-first)"
[ "$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --branch-prefix hand-first 2>/dev/null)" = "" ] \
  || fail "pr=manual placed first displaced the empty branch= override"
pass "fm-project-mode: pr=manual binds in any token order and leaves mode, yolo, forge, and branch alone"

[ "$(run_pr hand-prod)" = "manual" ] || fail "pr=manual on the conditional policy did not resolve: $(run_pr hand-prod)"
[ "$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --raw hand-prod 2>/dev/null)" = "no-mistakes-prod-only off" ] \
  || fail "pr=manual changed the raw conditional-policy output"
pass "fm-project-mode: pr=manual is kept on a no-mistakes-prod-only project"

for name in hand-direct hand-local hand-forgejo hand-empty hand-auto; do
  for flag in "" --pr; do
    # shellcheck disable=SC2086 # An empty flag must expand to nothing.
    out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag "$name" 2>/dev/null)
    status=$?
    [ "$status" -eq 3 ] || fail "$name did not refuse${flag:+ under $flag} (status $status, got '$out')"
    [ -z "$out" ] || fail "a refused $name still handed the caller a posture: '$out'"
  done
  [ "$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge "$name" 2>/dev/null)" != "" ] \
    || fail "--forge refused over the pr token of $name"
done
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --pr hand-empty 2>&1 >/dev/null)
assert_contains "$err" "empty PR-text binding" "the empty pr= refusal did not name the empty value"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --pr hand-auto 2>&1 >/dev/null)
assert_contains "$err" "pr=manual" "the unknown pr value refusal did not name the accepted value"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --pr hand-direct 2>&1 >/dev/null)
assert_contains "$err" "only a no-mistakes ship takes it" "the direct-PR refusal did not say why"
pass "fm-project-mode: pr=manual refuses another mode, a bound forge, an empty value, and an unknown value, but leaves --forge answerable"

[ "$(run_forge_cli lab)" = "auto" ] \
  || fail "forge=forgejo with no CLI named must report auto: $(run_forge_cli lab)"
[ "$(run_forge_cli legacy)" = "auto" ] \
  || fail "an entry with no forge token must report CLI auto: $(run_forge_cli legacy)"
[ "$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --forge-cli legacy 2>/dev/null)" = "auto" ] \
  || fail "an absent registry file must default --forge-cli to auto"
pass "fm-project-mode: --forge-cli reports auto for a project that names no CLI and for an absent registry"

for spec in "cli-tea tea" "cli-fgj fgj" "cli-fj fj"; do
  name=${spec%% *}
  want=${spec#* }
  [ "$(run_forge_cli "$name")" = "$want" ] \
    || fail "$name did not report --forge-cli $want: $(run_forge_cli "$name")"
  [ "$(run_forge "$name")" = "forgejo" ] \
    || fail "$name changed the --forge provider word: $(run_forge "$name")"
  err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" "$name" 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered $name warned: $err"
done
[ "$(run_mode cli-fgj)" = "direct-PR on" ] \
  || fail "the CLI suffix must not displace the mode or +yolo: $(run_mode cli-fgj)"
pass "fm-project-mode: forge=forgejo:<cli> names the CLI in any token order and never changes --forge"

# The suffix is part of the binding grammar, so a malformed one is refused
# exactly like an unknown forge: nothing on stdout, exit 3, and the accepted
# CLI values named. A CLI suffix on any other provider is refused too, because
# only Forgejo has more than one supported CLI.
for name in cli-empty cli-unknown cli-gerrit; do
  out=$(run_forge_cli "$name" 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "$name did not refuse --forge-cli (status $status, got '$out')"
  [ -z "$out" ] || fail "a refused $name still handed the caller a CLI: '$out'"
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" "$name" 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "$name did not refuse the default output (status $status, got '$out')"
done
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge-cli cli-empty 2>&1 >/dev/null)
assert_contains "$err" 'forge=forgejo:tea' "the empty CLI refusal did not name the accepted CLI values"
assert_contains "$err" 'forge=forgejo:fj' "the empty CLI refusal did not name forgejo-cli"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge-cli cli-unknown 2>&1 >/dev/null)
assert_contains "$err" 'forge=forgejo:fgj' "the unknown CLI refusal did not name the accepted CLI values"
err=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge-cli cli-gerrit 2>&1 >/dev/null)
assert_contains "$err" 'unknown forge' "a CLI suffix on gerrit was not refused as an unknown forge"
pass "fm-project-mode: a malformed Forgejo CLI suffix is refused like any other malformed forge binding"

# local-only publishes nothing, so a Forgejo CLI binding is refused there for
# the same reason the forge itself is, and --forge-cli must not become a way
# around that check.
for flag in "" --forge --forge-cli; do
  # shellcheck disable=SC2086 # An empty flag must expand to nothing.
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag kept 2>/dev/null)
  status=$?
  [ "$status" -eq 3 ] || fail "local-only with forge=forgejo did not refuse${flag:+ under $flag} (status $status, got '$out')"
done
pass "fm-project-mode: --forge-cli does not answer for a local-only project that refuses its forge"

echo "# fm-project-mode.test.sh: all assertions passed"
