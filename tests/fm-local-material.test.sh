#!/usr/bin/env bash
# Behavior tests for bin/fm-local-material.sh.
#
# Everything here runs against temporary directories. Proving the whole path end
# to end needs a real spawn, which no test can do, so what these cases pin is the
# contract the spawn calls into: what gets placed, in which mode, what is
# refused, and what a receiving worker is told.
#
# The placement cases matter more than they look. Both modes exist because they
# fail differently, and the difference is invisible until something breaks in
# production: a symlinked environment file is what makes one rotated key reach
# every live worktree, while a copy that resets a timestamp is what makes an
# expired browser session look current to a consumer that checks freshness by
# modification time. So the link case asserts the link, and the copy case
# asserts a preserved mtime rather than just a present file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-local-material)
LM="$ROOT/bin/fm-local-material.sh"

# A fresh project + home + empty worktree triple. Each case gets its own so a
# refusal in one cannot leave state that makes the next one pass for the wrong
# reason.
new_fixture() { # <name> -> echoes the fixture root
  local name=$1 root
  root="$TMP_ROOT/$name"
  mkdir -p "$root/home/config" "$root/proj/e2e/.auth" "$root/wt"
  printf 'TOKEN=production\n' > "$root/proj/.env"
  printf 'TOKEN=staging\n' > "$root/proj/.env.staging"
  printf '{"servers":{}}\n' > "$root/proj/.mcp.json"
  printf '{"cookies":[]}\n' > "$root/proj/e2e/.auth/admin.json"
  # An old timestamp is the whole point of the copy mode; a fresh one would let
  # a timestamp-resetting copy pass.
  touch -t 202501020304 "$root/proj/e2e/.auth/admin.json"
  git -C "$root/proj" init -q
  git -C "$root/wt" init -q
  # A real project gitignores this material; the placement refuses anything it
  # does not, so the fixture has to look like a real project.
  printf '.env\n.env.staging\n.mcp.json\n/e2e/.auth/\n' > "$root/wt/.gitignore"
  printf '%s\n' "$root"
}

write_manifest() { # <fixture-root> <json>
  printf '%s\n' "$2" > "$1/home/config/project-local-material.json"
}

lm() { # <fixture-root> <args...>
  local root=$1; shift
  FM_HOME="$root/home" "$LM" "$@"
}

FULL_MANIFEST='{
  "proj": {
    "environments": {
      "default": ".env.staging",
      "production": ".env",
      "production_note": "video and social surfaces work nowhere else"
    },
    "entries": [
      { "path": ".env",         "mode": "link" },
      { "path": ".env.staging", "mode": "link" },
      { "path": "e2e/.auth",    "mode": "copy" }
    ]
  }
}'

test_script_parses() {
  local out rc
  out=$(bash -n "$LM" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-local-material.sh must parse cleanly (got: $out)"
  pass "fm-local-material.sh: bash -n succeeds"
}

test_help_prints_the_header() {
  local out
  out=$("$LM" --help)
  assert_contains "$out" "fm-local-material.sh apply <project-path> <worktree-path>" \
    "--help must print the usage block from the header"
  assert_contains "$out" "LINK VERSUS COPY" \
    "--help must carry the mode rationale, since choosing the wrong mode fails silently"
  pass "fm-local-material.sh: --help prints the header contract"
}

# An unconfigured fleet must be untouched. This is what lets the spawn call the
# script unconditionally.
test_unconfigured_project_is_a_silent_no_op() {
  local root out rc
  root=$(new_fixture unconfigured)
  for sub in entries brief-section; do
    out=$(lm "$root" "$sub" "$root/proj"); rc=$?
    expect_code 0 "$rc" "$sub must succeed with no manifest at all"
    [ -z "$out" ] || fail "$sub must print nothing with no manifest (got: $out)"
  done
  out=$(lm "$root" apply "$root/proj" "$root/wt"); rc=$?
  expect_code 0 "$rc" "apply must succeed with no manifest at all"
  [ -z "$out" ] || fail "apply must print nothing with no manifest (got: $out)"

  # A manifest that names OTHER projects is the same no-op for this one.
  write_manifest "$root" '{ "someone-else": { "entries": [ { "path": ".env", "mode": "link" } ] } }'
  out=$(lm "$root" apply "$root/proj" "$root/wt"); rc=$?
  expect_code 0 "$rc" "apply must succeed for a project the manifest does not name"
  [ -z "$out" ] || fail "apply must print nothing for an unnamed project (got: $out)"
  assert_absent "$root/wt/.env" "an unnamed project must receive nothing"
  pass "fm-local-material.sh: an unconfigured project is a silent no-op"
}

test_entries_are_reported_in_configured_order() {
  local root out
  root=$(new_fixture entries)
  write_manifest "$root" "$FULL_MANIFEST"
  out=$(lm "$root" entries "$root/proj")
  local expected
  expected=$(printf 'link\t.env\nlink\t.env.staging\ncopy\te2e/.auth')
  [ "$out" = "$expected" ] || fail "entries must print mode and path in configured order, got: $out"
  pass "fm-local-material.sh: entries reports each configured mode and path in order"
}

# The link mode's whole purpose is that the worktree reads the source, so a
# rotated value propagates without re-placing anything. Asserting the file
# exists would pass for a copy too, so this follows the link and then changes
# the source.
test_link_mode_tracks_the_source() {
  local root target
  root=$(new_fixture link-mode)
  write_manifest "$root" "$FULL_MANIFEST"
  lm "$root" apply "$root/proj" "$root/wt" >/dev/null || fail "apply must succeed"

  [ -L "$root/wt/.env" ] || fail ".env must be placed as a symlink under link mode"
  target=$(readlink "$root/wt/.env")
  case "$target" in
    /*) ;;
    *) fail "a placed link must be absolute so it survives any cwd, got: $target" ;;
  esac
  [ "$target" = "$root/proj/.env" ] || fail "the link must point at the source file, got: $target"

  printf 'TOKEN=rotated\n' > "$root/proj/.env"
  assert_contains "$(cat "$root/wt/.env")" "rotated" \
    "a rotated source value must reach the worktree with no re-placement"
  pass "fm-local-material.sh: link mode points at the source so rotation propagates"
}

# A copy that resets the timestamp is the specific defect this mode exists to
# avoid: a consumer that re-mints by mtime would read an expired file as fresh.
test_copy_mode_is_a_real_copy_with_the_timestamp_preserved() {
  local root src_stamp dest_stamp
  root=$(new_fixture copy-mode)
  write_manifest "$root" "$FULL_MANIFEST"
  lm "$root" apply "$root/proj" "$root/wt" >/dev/null || fail "apply must succeed"

  [ -d "$root/wt/e2e/.auth" ] || fail "a copied directory must be placed"
  [ ! -L "$root/wt/e2e/.auth" ] || fail "copy mode must not place a symlink"
  assert_present "$root/wt/e2e/.auth/admin.json" "a copied directory must carry its contents"

  src_stamp=$(date -r "$root/proj/e2e/.auth/admin.json" +%Y%m%d%H%M)
  dest_stamp=$(date -r "$root/wt/e2e/.auth/admin.json" +%Y%m%d%H%M)
  [ "$src_stamp" = "$dest_stamp" ] ||
    fail "copy mode must preserve mtime ($src_stamp) or a freshness-by-mtime consumer reads an expired file as current (got $dest_stamp)"

  # The copy must also be independent: a source change must NOT reach it, which
  # is what keeps concurrent workers from racing over a re-minted session.
  printf '{"cookies":["changed"]}\n' > "$root/proj/e2e/.auth/admin.json"
  assert_not_contains "$(cat "$root/wt/e2e/.auth/admin.json")" "changed" \
    "a copy must be independent of its source"
  pass "fm-local-material.sh: copy mode copies with the timestamp preserved and stays independent"
}

# A pooled worktree is reused, so it can still hold the previous task's
# material. Leaving that in place would hand a worker stale credentials.
test_apply_replaces_material_left_by_a_previous_task() {
  local root
  root=$(new_fixture reused-slot)
  write_manifest "$root" "$FULL_MANIFEST"
  printf 'TOKEN=someone-elses-stale-value\n' > "$root/wt/.env"
  mkdir -p "$root/wt/e2e/.auth"
  printf 'stale\n' > "$root/wt/e2e/.auth/leftover.json"

  lm "$root" apply "$root/proj" "$root/wt" >/dev/null || fail "apply must succeed on a reused slot"
  [ -L "$root/wt/.env" ] || fail "a leftover regular file must be replaced by the configured link"
  assert_absent "$root/wt/e2e/.auth/leftover.json" \
    "a leftover file inside a copied directory must not survive into the new task"
  pass "fm-local-material.sh: apply replaces material left behind in a reused worktree"
}

# The refusal is the feature. A worktree that looks ready and cannot test is
# what costs a whole validation round, so the spawn must stop here instead.
test_a_missing_source_refuses_without_placing_anything() {
  local root out rc
  root=$(new_fixture missing-source)
  write_manifest "$root" "$FULL_MANIFEST"
  rm "$root/proj/.env.staging"

  out=$(lm "$root" apply "$root/proj" "$root/wt" 2>&1); rc=$?
  expect_code 1 "$rc" "a missing listed source must refuse"
  assert_contains "$out" ".env.staging" "the refusal must name the missing path"
  assert_contains "$out" "cannot run the app or its tests" \
    "the refusal must say what the worker loses, not just that a file is absent"

  # Partial equipment is the trap: .env comes first in the list and would have
  # been placed by a loop that checked sources as it went.
  assert_absent "$root/wt/.env" "a refusal must place nothing at all, not even earlier entries"
  pass "fm-local-material.sh: a missing source refuses before placing anything"
}

# Each of these is a hand-editing mistake that must be named rather than
# silently worked around.
test_malformed_configuration_is_refused_by_name() {
  local root out rc
  root=$(new_fixture malformed)

  # Every case is checked through `validate`, which is the subcommand that reads
  # a project's whole object, so a source mistake and an entry mistake are held
  # to the same standard.
  check() { # <json> <expected-fragment> <label>
    write_manifest "$root" "$1"
    out=$(lm "$root" validate "$root/proj" 2>&1); rc=$?
    expect_code 1 "$rc" "$3 must be refused"
    assert_contains "$out" "$2" "$3 must be named in the refusal"
  }

  check '{ "proj": { "entries": [ { "path": "../elsewhere/.env", "mode": "link" } ] } }' \
    "escapes the project" "a .. path"
  check '{ "proj": { "entries": [ { "path": "/etc/passwd", "mode": "link" } ] } }' \
    "must be relative" "an absolute path"
  check '{ "proj": { "entries": [ { "path": "", "mode": "link" } ] } }' \
    "empty" "an empty path"
  # Apply clears a destination before placing it, so a path that resolves to the
  # project root would aim that clear at the whole worktree.
  check '{ "proj": { "entries": [ { "path": ".", "mode": "copy" } ] } }' \
    "names the project root" "a path of \".\""
  check '{ "proj": { "entries": [ { "path": "./.", "mode": "copy" } ] } }' \
    "names the project root" "a path of only dot components"
  check '{ "proj": { "entries": [ { "path": ".env", "mode": "symlink" } ] } }' \
    'use "link" or "copy"' "an unrecognized mode"
  check '{ "proj": { "entries": [] } }' \
    'non-empty "entries"' "an empty entries array"
  check '{ "proj": { "source": "relative/path", "entries": [ { "path": ".env", "mode": "link" } ] } }' \
    "must be an absolute path" "a relative source"
  check '{ "proj": { "source": "/nonexistent/source/root", "entries": [ { "path": ".env", "mode": "link" } ] } }' \
    "does not exist" "a source directory that is not there"
  check 'this is not json' "not valid JSON" "a malformed file"
  # A jq failure must refuse rather than yield an empty entry list: reading a
  # malformed manifest as "nothing configured" would hand a worker an unequipped
  # worktree with no refusal at all, which is the one outcome this must never
  # produce.
  check '{ "proj": { "entries": [ "not an object" ] } }' \
    "malformed entry" "an entries array of non-objects"
  check '{ "proj": { "entries": [ { "path": ".env", "mode": "link" }, 42 ] } }' \
    "malformed entry" "an entries array with one non-object among valid ones"
  check '[ "a list, not an object" ]' "must be a JSON object" "a top-level array"
  pass "fm-local-material.sh: every malformed configuration is refused by name"
}

# Tracked content arrives with the checkout. A manifest naming it means the
# manifest is wrong, and placing it would overwrite real work.
test_a_git_tracked_path_is_refused() {
  local root out rc
  root=$(new_fixture tracked)
  printf 'tracked content\n' > "$root/proj/config.yml"
  printf 'tracked content\n' > "$root/wt/config.yml"
  git -C "$root/wt" add config.yml
  write_manifest "$root" '{ "proj": { "entries": [ { "path": "config.yml", "mode": "copy" } ] } }'

  out=$(lm "$root" apply "$root/proj" "$root/wt" 2>&1); rc=$?
  expect_code 1 "$rc" "a git-tracked path must be refused"
  assert_contains "$out" "which git tracks" "the refusal must say the path is tracked"
  assert_contains "$(cat "$root/wt/config.yml")" "tracked content" \
    "the tracked file must be left untouched by the refusal"
  pass "fm-local-material.sh: a git-tracked path is refused and left untouched"
}

# Material the project does not ignore would leave every worktree reading as
# having uncommitted changes, which blocks teardown and invites a worker to
# commit a credential.
test_material_the_project_does_not_ignore_is_refused() {
  local root out rc
  root=$(new_fixture unignored)
  printf '.env\n' > "$root/wt/.gitignore"
  write_manifest "$root" "$FULL_MANIFEST"

  out=$(lm "$root" apply "$root/proj" "$root/wt" 2>&1); rc=$?
  expect_code 1 "$rc" "material the project does not gitignore must be refused"
  assert_contains "$out" "does not gitignore" "the refusal must say the path is not ignored"
  assert_absent "$root/wt/.env" "a refused apply must place nothing, including the ignored entry"

  # The directory entry is the case a naive check gets wrong: a directory-only
  # ignore pattern matches only with the trailing slash.
  printf '.env\n.env.staging\n/e2e/.auth/\n' > "$root/wt/.gitignore"
  lm "$root" apply "$root/proj" "$root/wt" >/dev/null ||
    fail "a directory covered by a trailing-slash ignore pattern must be accepted"
  git -C "$root/wt" add .gitignore
  git -C "$root/wt" -c user.name=t -c user.email=t@example.invalid commit -qm ignore
  lm "$root" apply "$root/proj" "$root/wt" >/dev/null || fail "apply must succeed against a committed .gitignore"
  [ -z "$(git -C "$root/wt" status --porcelain)" ] ||
    fail "placed material must leave the worktree reading as clean"$'\n'"$(git -C "$root/wt" status --porcelain)"
  pass "fm-local-material.sh: material the project does not gitignore is refused"
}

test_source_override_reads_from_the_named_checkout() {
  local root
  root=$(new_fixture source-override)
  mkdir -p "$root/elsewhere"
  printf 'TOKEN=from-the-real-checkout\n' > "$root/elsewhere/.env"
  write_manifest "$root" "{ \"proj\": { \"source\": \"$root/elsewhere\",
    \"entries\": [ { \"path\": \".env\", \"mode\": \"link\" } ] } }"

  lm "$root" apply "$root/proj" "$root/wt" >/dev/null || fail "apply must succeed with a source override"
  assert_contains "$(cat "$root/wt/.env")" "from-the-real-checkout" \
    "an explicit source must win over the project clone"
  [ "$(readlink "$root/wt/.env")" = "$root/elsewhere/.env" ] ||
    fail "the link must point into the named source checkout"
  pass "fm-local-material.sh: an explicit source reads from the named checkout"
}

# These rules ship with the credentials because credentials that arrive without
# them are what produced a write against production.
test_brief_section_states_the_operating_rules() {
  local root out
  root=$(new_fixture brief)
  write_manifest "$root" "$FULL_MANIFEST"
  out=$(lm "$root" brief-section "$root/proj")

  assert_contains "$out" "# Local material in this worktree" \
    "the section must be a titled launch-brief section"
  # shellcheck disable=SC2016 # Backticks here are the Markdown code span the section emits.
  assert_contains "$out" '`e2e/.auth`' "the section must list what was actually placed"

  assert_contains "$out" "defaults to STAGING (\`.env.staging\`)" \
    "a dev server must default to the configured default environment"
  assert_contains "$out" "\`.env\` is PRODUCTION" \
    "the production environment must be named as production"
  assert_contains "$out" "video and social surfaces work nowhere else" \
    "the configured reason production exists must be carried through"
  assert_contains "$out" "ALWAYS run in staging" \
    "e2e and screenshots must be pinned to staging with no exception"

  # "do not read them" already proved too vague, so the rule has to draw the
  # line between letting a tool consume a file and looking inside it.
  assert_contains "$out" "inputs to tools, never reading material" \
    "the section must frame these files as tool inputs"
  assert_contains "$out" "grep a value out of one" \
    "the section must forbid extracting a value, not just opening the file"
  assert_contains "$out" "a pull request" \
    "the section must forbid putting a value into outward-facing output"
  pass "fm-local-material.sh: the brief section states the environment and handling rules"
}

# A manifest that sets production without a default still places the
# production credential, so it must still carry the production warning: this
# is the exact case that let a worker treat an unmarked production file as
# safe to use.
test_production_only_environment_still_warns() {
  local root out
  root=$(new_fixture production-only)
  write_manifest "$root" '{
    "proj": {
      "environments": {
        "production": ".env",
        "production_note": "video and social surfaces work nowhere else"
      },
      "entries": [ { "path": ".env", "mode": "link" } ]
    }
  }'
  out=$(lm "$root" brief-section "$root/proj")
  assert_contains "$out" "\`.env\` is PRODUCTION" \
    "a manifest with production but no default must still warn the file is production"
  assert_contains "$out" "video and social surfaces work nowhere else" \
    "the configured reason production exists must still be carried through"
  assert_not_contains "$out" "STAGING" \
    "a manifest with no configured default must not claim a staging default exists"
  pass "fm-local-material.sh: a production-only manifest still warns without claiming a default"
}

# A project with one environment must not be told about a staging/production
# split it does not have.
test_environment_rules_are_omitted_when_unconfigured() {
  local root out
  root=$(new_fixture no-environments)
  write_manifest "$root" '{ "proj": { "entries": [ { "path": ".env", "mode": "link" } ] } }'
  out=$(lm "$root" brief-section "$root/proj")
  assert_contains "$out" "inputs to tools, never reading material" \
    "the handling rules must appear for any placed material"
  assert_not_contains "$out" "STAGING" \
    "a project with no configured environments must not be given environment rules"
  pass "fm-local-material.sh: environment rules appear only when environments are configured"
}

# docs/examples/project-local-material.json is what an operator copies as a
# starting point, so it must actually validate. Its "source" values are
# placeholder paths under /home/you that do not exist on this machine, so this
# rewrites them to real temporary directories before validating rather than
# weakening the source-existence check to let the placeholders through.
test_documented_example_validates_against_real_source_directories() {
  local root out rc example key
  root=$(new_fixture documented-example)
  # These two keys must name the projects the shipped example actually declares.
  # A jq assignment to a missing key ADDS it, so a renamed example would leave
  # this test quietly validating two invented projects alongside the real ones
  # rather than the example itself. Assert they exist first, so a rename fails
  # here loudly instead of hollowing the case out.
  for key in web-app marketing-site; do
    jq -e --arg k "$key" 'has($k)' "$ROOT/docs/examples/project-local-material.json" >/dev/null ||
      fail "the shipped example no longer declares '$key'; update this test's keys to match it"
  done
  mkdir -p "$root/app-source" "$root/site-source"
  example=$(jq --arg app "$root/app-source" --arg site "$root/site-source" \
    '."web-app".source = $app | ."marketing-site".source = $site' \
    "$ROOT/docs/examples/project-local-material.json")
  write_manifest "$root" "$example"
  out=$(lm "$root" validate 2>&1); rc=$?
  expect_code 0 "$rc" "the documented example must validate once its source paths are real directories (got: $out)"
  [ -z "$out" ] || fail "validate must print nothing on success (got: $out)"
  pass "fm-local-material.sh: the documented example validates against real source directories"
}

test_validate_checks_every_project_in_the_file() {
  local root out rc
  root=$(new_fixture validate)
  write_manifest "$root" '{
    "proj":  { "entries": [ { "path": ".env", "mode": "link" } ] },
    "other": { "entries": [ { "path": "../escape", "mode": "link" } ] }
  }'
  out=$(lm "$root" validate 2>&1); rc=$?
  expect_code 1 "$rc" "validate must refuse a file whose SECOND project is malformed"
  assert_contains "$out" "other" "validate must name the offending project"

  write_manifest "$root" '{ "proj": { "entries": [ { "path": ".env", "mode": "link" } ] } }'
  out=$(lm "$root" validate 2>&1); rc=$?
  expect_code 0 "$rc" "validate must accept a well-formed file"
  [ -z "$out" ] || fail "validate must print nothing on success (got: $out)"
  pass "fm-local-material.sh: validate checks every project and stays silent when clean"
}

# A helper that refuses inside a command substitution only ends that subshell, so
# without an explicit guard at each call site the script would carry on with an
# empty value and report success. Every subcommand is checked because the guard
# has to be at each site, not in the helper.
test_an_unusable_path_refuses_rather_than_continuing() {
  local root out rc
  root=$(new_fixture unusable-path)
  write_manifest "$root" "$FULL_MANIFEST"

  for sub in entries brief-section validate; do
    out=$(lm "$root" "$sub" "$root/no-such-project" 2>&1); rc=$?
    expect_code 1 "$rc" "$sub must refuse a project path that is not a directory"
    assert_contains "$out" "is not a directory" "$sub must name the unusable path"
  done

  out=$(lm "$root" apply "$root/no-such-project" "$root/wt" 2>&1); rc=$?
  expect_code 1 "$rc" "apply must refuse a project path that is not a directory"
  assert_contains "$out" "is not a directory" "apply must name the unusable project path"
  assert_absent "$root/wt/.env" "a refused apply must place nothing"

  out=$(lm "$root" apply "$root/proj" "$root/no-such-worktree" 2>&1); rc=$?
  expect_code 1 "$rc" "apply must refuse a worktree path that is not a directory"
  assert_contains "$out" "is not a directory" "apply must name the unusable worktree path"
  pass "fm-local-material.sh: an unusable path refuses instead of continuing with an empty value"
}

test_unknown_subcommand_is_refused() {
  local out rc
  out=$("$LM" place-everything 2>&1); rc=$?
  expect_code 1 "$rc" "an unknown subcommand must be refused"
  assert_contains "$out" "unknown subcommand" "the refusal must name the problem"
  pass "fm-local-material.sh: an unknown subcommand is refused"
}

test_script_parses
test_help_prints_the_header
test_unconfigured_project_is_a_silent_no_op
test_entries_are_reported_in_configured_order
test_link_mode_tracks_the_source
test_copy_mode_is_a_real_copy_with_the_timestamp_preserved
test_apply_replaces_material_left_by_a_previous_task
test_a_missing_source_refuses_without_placing_anything
test_malformed_configuration_is_refused_by_name
test_a_git_tracked_path_is_refused
test_material_the_project_does_not_ignore_is_refused
test_source_override_reads_from_the_named_checkout
test_brief_section_states_the_operating_rules
test_production_only_environment_still_warns
test_environment_rules_are_omitted_when_unconfigured
test_documented_example_validates_against_real_source_directories
test_validate_checks_every_project_in_the_file
test_an_unusable_path_refuses_rather_than_continuing
test_unknown_subcommand_is_refused
