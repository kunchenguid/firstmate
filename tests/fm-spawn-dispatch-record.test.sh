#!/usr/bin/env bash
# tests/fm-spawn-dispatch-record.test.sh - the dispatch route and capability
# floor recorded in state/<id>.meta at spawn (bin/fm-dispatch-record-lib.sh,
# bin/fm-spawn.sh).
#
# The load-bearing guarantee is NOT that the happy path records a route. It is
# that an unresolvable route records the literal token `unknown` instead of
# being omitted, left blank, or carried over from another task: a field
# populated only when resolution succeeds would make a capability floor LOOK
# recorded while under-reporting it, and later escalation logic would trust it.
# Every case below therefore asserts the exact recorded value, and the
# integration cases additionally assert that no recorded field is ever empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dispatch-record-lib.sh
. "$ROOT/bin/fm-dispatch-record-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-record)
export FM_BACKEND=tmux

# A dispatch config in the documented shape plus the optional route identity
# fields this sensor reads. R2-GEN and R3-LOW are distinct routes; DUP-ROUTE is
# carried by two rules that disagree about the floor; NO-FLOOR carries a route
# with no floor at all.
DISPATCH_JSON='{
  "_policy": { "version": "2026-08-03 routing redesign, rev 5" },
  "rules": [
    { "when": "big ambiguous work", "use": { "harness": "claude" }, "route": "R2-GEN", "floor": "F-GEN" },
    { "when": "small mechanical work", "use": { "harness": "claude" }, "route": "R3-LOW", "floor": "F-IMPL-LOW" },
    { "when": "one", "use": { "harness": "claude" }, "route": "DUP-ROUTE", "floor": "F-GEN" },
    { "when": "two", "use": { "harness": "claude" }, "route": "DUP-ROUTE", "floor": "F-RISK" },
    { "when": "floored", "use": { "harness": "claude" }, "route": "PARTIAL-FLOOR", "floor": "F-GEN" },
    { "when": "floorless", "use": { "harness": "claude" }, "route": "PARTIAL-FLOOR" },
    { "when": "three", "use": { "harness": "claude" }, "route": "NO-FLOOR" }
  ],
  "default": { "harness": "claude", "route": "R1-DEFAULT", "floor": "F-DEFAULT" }
}'

# --- fixtures ---------------------------------------------------------------

# Fake tmux answering the pane-path query; treehouse is a no-op because the
# worktree already exists. Nothing here depends on the recorded route, so the
# same stub serves every spawn case.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_home <name> [<dispatch-json>]: a locked firstmate home with one project
# worktree. Omitting the JSON leaves the home with no dispatch config at all.
# Sets HOME_DIR/PROJ_DIR/WT_DIR/FAKEBIN_DIR for the caller.
make_home() {
  local name=$1 json=${2-}
  local case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  FAKEBIN_DIR=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  [ -z "$json" ] || printf '%s\n' "$json" > "$HOME_DIR/config/crew-dispatch.json"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
}

# run_spawn <id> [flag...]: seed the brief and drive the real spawn path.
run_spawn() {
  local id=$1
  shift
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude "$@" 2>&1
}

meta_field() { sed -n "s/^$2=//p" "$1"; }

# assert_recorded <meta> <route> <floor> <revision> <label>: the three fields
# hold exactly these values, and no recorded field anywhere in the meta is
# blank. The blank check is what catches a field that "exists" but says nothing.
assert_recorded() {
  local meta=$1 route=$2 floor=$3 revision=$4 label=$5 got
  [ -f "$meta" ] || fail "$label: no meta at $meta"
  got=$(meta_field "$meta" route)
  [ "$got" = "$route" ] || fail "$label: route= expected '$route', got '$got'"
  got=$(meta_field "$meta" floor)
  [ "$got" = "$floor" ] || fail "$label: floor= expected '$floor', got '$got'"
  got=$(meta_field "$meta" policy_revision)
  [ "$got" = "$revision" ] || fail "$label: policy_revision= expected '$revision', got '$got'"
  ! grep -Eq '^(route|floor|policy_revision)=$' "$meta" \
    || fail "$label: a recorded field is blank"$'\n'"$(cat "$meta")"
}

# --- spawn integration ------------------------------------------------------

# The matched rule's own route and floor reach the metadata, for both
# deliverable kinds. A scout is included because a scout is dispatched through
# the same rules and its promotion inherits the work, so a floor recorded only
# for ships would be missing exactly where a promotion needs it.
test_matched_rule_is_recorded() {
  make_home matched "$DISPATCH_JSON"
  run_spawn ship-matched --mode no-mistakes --yolo off --route R2-GEN >/dev/null
  assert_recorded "$HOME_DIR/state/ship-matched.meta" \
    R2-GEN F-GEN '2026-08-03 routing redesign, rev 5' "ship on a matched rule"

  run_spawn scout-matched --scout --route R3-LOW >/dev/null
  assert_recorded "$HOME_DIR/state/scout-matched.meta" \
    R3-LOW F-IMPL-LOW '2026-08-03 routing redesign, rev 5' "scout on a matched rule"
  pass "a matched dispatch rule records its own route, floor, and policy revision"
}

# A dispatch that matched no rule took the config's explicit default, and that
# is a positive fact, not a missing one: it records the default's route and
# floor rather than the reserved token it was requested with.
test_explicit_default_is_recorded() {
  make_home defaulted "$DISPATCH_JSON"
  run_spawn ship-default --mode no-mistakes --yolo off --route default >/dev/null
  assert_recorded "$HOME_DIR/state/ship-default.meta" \
    R1-DEFAULT F-DEFAULT '2026-08-03 routing redesign, rev 5' "explicit default"
  pass "a dispatch that matched no rule records the explicit default's route and floor"
}

test_array_default_is_recorded() {
  local config
  config=$(printf '%s' "$DISPATCH_JSON" | jq \
    '.default = [
      {"harness":"claude","route":"R1-DEFAULT","floor":"F-DEFAULT"},
      {"harness":"codex","route":"R1-DEFAULT","floor":"F-DEFAULT"}
    ]')
  make_home array-default "$config"
  run_spawn ship-array-default --mode no-mistakes --yolo off --route default >/dev/null
  assert_recorded "$HOME_DIR/state/ship-array-default.meta" \
    R1-DEFAULT F-DEFAULT '2026-08-03 routing redesign, rev 5' "array default"
  pass "an array-form default records its unambiguous route and floor"
}

# The load-bearing case. Three ways a route fails to resolve, each recording
# `unknown` rather than vanishing - including immediately after a resolved
# spawn in the same home, which is where a leaked or defaulted value would show.
test_unresolvable_records_unknown() {
  make_home unresolvable "$DISPATCH_JSON"
  run_spawn ship-resolved --mode no-mistakes --yolo off --route R2-GEN >/dev/null
  assert_recorded "$HOME_DIR/state/ship-resolved.meta" \
    R2-GEN F-GEN '2026-08-03 routing redesign, rev 5' "resolved neighbour"

  run_spawn ship-noflag --mode no-mistakes --yolo off >/dev/null
  assert_recorded "$HOME_DIR/state/ship-noflag.meta" \
    unknown unknown '2026-08-03 routing redesign, rev 5' "no route declared"

  run_spawn ship-stale --mode no-mistakes --yolo off --route R9-RETIRED >/dev/null
  assert_recorded "$HOME_DIR/state/ship-stale.meta" \
    unknown unknown '2026-08-03 routing redesign, rev 5' "route absent from the config"

  make_home noconfig
  run_spawn ship-noconfig --mode no-mistakes --yolo off --route R2-GEN >/dev/null
  assert_recorded "$HOME_DIR/state/ship-noconfig.meta" \
    unknown unknown unknown "no dispatch config in the home"
  pass "an unresolvable route, floor, or revision records 'unknown' and never inherits or blanks"
}

# The shared route reaches the re-exec'd single-task spawn, like the shared
# harness and delivery contract already do.
test_batch_shares_the_route() {
  make_home batched "$DISPATCH_JSON"
  local id=batch-pair-z1
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/projects"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  ln -s "$PROJ_DIR" "$HOME_DIR/projects/alpha"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id=projects/alpha" --harness claude --mode no-mistakes --yolo off \
    --route R3-LOW >/dev/null 2>&1
  assert_recorded "$HOME_DIR/state/$id.meta" \
    R3-LOW F-IMPL-LOW '2026-08-03 routing redesign, rev 5' "batch pair"
  pass "a batch shares one dispatch route across its pairs"
}

# --route names an identity, so a value that could break the key=value record,
# or that names no dispatched task at all, is refused rather than recorded.
test_route_flag_is_refused_where_it_cannot_apply() {
  make_home refused "$DISPATCH_JSON"
  local out status label expect args
  while IFS='|' read -r label expect args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_spawn refused-$label $args)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label"
    assert_absent "$HOME_DIR/state/refused-$label.meta" "$label: recorded a meta anyway"
  done <<'ROWS'
empty|--route requires a non-empty value|--mode no-mistakes --yolo off --route=
punctuation|--route must be a single route identifier|--mode no-mistakes --yolo off --route=R2;GEN
unresolved-token|--route cannot be 'unknown'|--mode no-mistakes --yolo off --route=unknown
secondmate|--route applies only to ship and scout spawns|--secondmate --route=R2-GEN
ROWS

  # A newline is the value that would silently split the key=value record into a
  # forged extra metadata line, so it is asserted on its own rather than through
  # the word-splitting table above.
  out=$(run_spawn refused-newline --mode no-mistakes --yolo off --route "R2-GEN
kind=secondmate")
  status=$?
  [ "$status" -ne 0 ] || fail "newline: expected a non-zero exit"
  assert_contains "$out" "--route must be a single route identifier" "newline"
  assert_absent "$HOME_DIR/state/refused-newline.meta" "newline: recorded a meta anyway"
  pass "--route refuses an empty, unusable, or non-task value"
}

# --- resolution unit cases --------------------------------------------------
#
# Driven through the library's public entry point so the ambiguity, tooling and
# sanitising paths are asserted directly rather than inferred from a spawn.

record() { fm_dispatch_record_lines "$1" "$2"; }

expect_lines() { # <actual> <route> <floor> <revision> <label>
  local want
  want=$(printf 'route=%s\nfloor=%s\npolicy_revision=%s' "$2" "$3" "$4")
  [ "$1" = "$want" ] || fail "$5: expected"$'\n'"$want"$'\n'"got"$'\n'"$1"
}

test_ambiguous_and_missing_floors() {
  local cfg="$TMP_ROOT/unitcfg"
  mkdir -p "$cfg"
  printf '%s\n' "$DISPATCH_JSON" > "$cfg/crew-dispatch.json"

  # Two rules claim DUP-ROUTE with different floors. Recording whichever came
  # first would invent a floor the dispatch may not have used, so the floor is
  # unknown while the declared route still stands.
  expect_lines "$(record "$cfg" DUP-ROUTE)" DUP-ROUTE unknown \
    '2026-08-03 routing redesign, rev 5' "rules disagreeing about a floor"
  expect_lines "$(record "$cfg" NO-FLOOR)" NO-FLOOR unknown \
    '2026-08-03 routing redesign, rev 5' "a route carrying no floor"
  expect_lines "$(record "$cfg" PARTIAL-FLOOR)" PARTIAL-FLOOR unknown \
    '2026-08-03 routing redesign, rev 5' "a route with floored and floorless rules"
  pass "an ambiguous or absent floor records 'unknown' with the route intact"
}

test_config_defects_never_abort_or_guess() {
  local cfg="$TMP_ROOT/defects" out
  mkdir -p "$cfg"

  printf '%s\n' '{ "rules": [ }' > "$cfg/crew-dispatch.json"
  out=$(record "$cfg" R2-GEN) || fail "malformed config must not fail the caller"
  expect_lines "$out" unknown unknown unknown "malformed dispatch config"

  # A default profile with no route identity at all: taking the default is
  # still a fact, but there is no identity to record for it.
  printf '%s\n' '{ "rules": [], "default": { "harness": "claude" } }' > "$cfg/crew-dispatch.json"
  expect_lines "$(record "$cfg" default)" unknown unknown unknown "default without a route"

  # A revision string is prose, so it is reduced to one sanitized line rather
  # than truncated: a shortened revision is a different revision.
  printf '%s\n' '{ "_policy": { "version": "rev 6\ttabbed\nsecond line" }, "rules": [] }' \
    > "$cfg/crew-dispatch.json"
  expect_lines "$(record "$cfg" '')" unknown unknown 'rev 6 tabbed' "multi-line revision"

  printf '%s\n' '{ "_policy": { "version": "  rev  7  " }, "rules": [] }' \
    > "$cfg/crew-dispatch.json"
  expect_lines "$(record "$cfg" '')" unknown unknown '  rev  7  ' "printable revision spacing"

  expect_lines "$(record "$TMP_ROOT/does-not-exist" R2-GEN)" unknown unknown unknown "absent config"
  pass "a malformed, incomplete, or absent dispatch config records 'unknown' without failing"
}

# jq reads the config; without it nothing can be resolved from the file, but the
# route firstmate declared cannot be confirmed and the spawn must not be disturbed.
test_missing_jq_degrades_to_unknown() {
  local cfg="$TMP_ROOT/nojq" fakebin
  mkdir -p "$cfg"
  printf '%s\n' "$DISPATCH_JSON" > "$cfg/crew-dispatch.json"
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq-bin")
  # A PATH holding only the shim dir, with every other external the library uses
  # linked in, so jq is the single variable removed and the library's own
  # dependency check is what has to notice.
  ln -sf "$(command -v tr)" "$fakebin/tr"
  local out
  out=$(PATH="$fakebin" fm_dispatch_record_lines "$cfg" R2-GEN) \
    || fail "a missing jq must not fail the caller"
  expect_lines "$out" unknown unknown unknown "jq unavailable"
  pass "an unavailable jq records 'unknown' rather than omitting the floor"
}

test_matched_rule_is_recorded
test_explicit_default_is_recorded
test_array_default_is_recorded
test_unresolvable_records_unknown
test_batch_shares_the_route
test_route_flag_is_refused_where_it_cannot_apply
test_ambiguous_and_missing_floors
test_config_defects_never_abort_or_guess
test_missing_jq_degrades_to_unknown
