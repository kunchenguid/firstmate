#!/usr/bin/env bash
# Exercise fm-brief -> fm-spawn -> staged executable input without a model.
# Catches dropped role bindings, stale association bodies, prelaunch omissions,
# lost independent choices, duplicate bodies and incorrect provenance.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-preparation)

new_case() {
  case_dir="$TMP_ROOT/$1"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id="prepare-$1"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" codex omp)
  fm_test_spawn_home "$home" "${2:-codex}"
  fm_git_worktree "$proj" "$wt" "wt-$1"
  roles="$case_dir/config/roles/example"
  skills="$home/user-home/.agents/skills"
  mkdir -p "$roles" "$skills/associated" "$skills/independent"
  printf '%s\n' '---' 'name: fm-example' 'description: Example worker' 'autoloadSkills:' '  - associated' '---' 'ROLE_BODY_SENTINEL' > "$roles/ROLE.md"
  printf '%s\n' '---' 'name: associated' 'description: Associated method' 'disable-model-invocation: true' '---' 'ASSOCIATED_BODY_SENTINEL' > "$skills/associated/SKILL.md"
  printf '%s\n' '---' 'name: independent' 'description: Selected method' '---' 'INDEPENDENT_BODY_SENTINEL' > "$skills/independent/SKILL.md"
}

scaffold() {
  local rc=0
  FM_HOME="$home" HOME="$home/user-home" bash "$ROOT/bin/fm-brief.sh" "$id" example --mode local-only "$@" > "$case_dir/brief.log" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$case_dir/brief.exit"
  [ "$rc" -eq 0 ] || return "$rc"
  # Fill only author-owned placeholders, not the generated launch/input.
  node - "$home/data/$id/brief.md" <<'JS'
const fs = require('node:fs');
const file = process.argv[2];
fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('{TASK}', 'Exercise preparation.').replace('{FIRSTMATE_SPEC}', 'No model generation.'));
JS
}

spawn() {
  local rc=0
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.sh" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" --mode local-only --yolo off > "$case_dir/spawn.log" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$case_dir/spawn.exit"
  return "$rc"
}

receive() {
  # Execute the actual emitted command with only its terminal model binary
  # replaced. Every envelope, argument and file read is production code.
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' started > "$FM_RECEIVER_DIR/started"
printf '%s' "${!#}" > "$FM_RECEIVER_DIR/input.txt"
SH
  cp "$fakebin/codex" "$fakebin/omp"
  chmod +x "$fakebin/codex" "$fakebin/omp"
  command=$(fm_test_launch_command "$(cat "$case_dir/launch.sh")")
  FM_RECEIVER_DIR="$case_dir" PATH="$fakebin:$PATH" bash -c "$command"
  [ -f "$case_dir/started" ] || fail 'receiver did not start'
  assert_grep 'FIRSTMATE_OP: v1 launch-brief:' "$case_dir/input.txt" 'initial envelope lost'
}

save_evidence() {
  [ -z "${FM_PREPARATION_EVIDENCE_DIR:-}" ] || {
    mkdir -p "$FM_PREPARATION_EVIDENCE_DIR"
    cp -R "$case_dir" "$FM_PREPARATION_EVIDENCE_DIR/"
  }
}

new_case bound omp
scaffold --worker-role "$roles/ROLE.md"
spawn || { cat "$case_dir/spawn.log"; fail 'bound role spawn refused'; }
receive
assert_grep ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt" 'associated body missing from actual input'
assert_grep ROLE_BODY_SENTINEL "$case_dir/input.txt" 'role body missing from actual input'
save_evidence
pass 'role-associated hidden skill body reaches actual initial OMP input'

new_case removed
scaffold --worker-role "$roles/ROLE.md"
printf '%s\n' '---' 'name: fm-example' 'description: Example worker' '---' 'ROLE_BODY_SENTINEL' > "$roles/ROLE.md"
spawn
receive
assert_no_grep ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt" 'removed association still supplied'
save_evidence
pass 'removing association after scaffolding removes body at spawn'

new_case missing
scaffold --worker-role "$roles/ROLE.md"
rm "$skills/associated/SKILL.md"
if spawn; then fail 'missing associated skill started worker'; fi
assert_grep associated "$case_dir/spawn.log" 'refusal did not identify missing skill'
[ ! -s "$case_dir/launch.sh" ] || fail 'missing association emitted executable launch'
[ ! -e "$case_dir/started" ] || fail 'missing association started receiver'
save_evidence
pass 'missing association refuses before any worker launch'

new_case combined
scaffold --worker-role "$roles/ROLE.md" --skill "$skills/independent/SKILL.md" --skill "$skills/associated/SKILL.md"
spawn
receive
assert_grep INDEPENDENT_BODY_SENTINEL "$case_dir/input.txt" 'independent skill lost'
[ "$(grep -c ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt")" -eq 1 ] || fail 'duplicate associated body'
jq -e '.skills[] | select(.name == "associated") | .origins == ["role", "independent"]' "$home/data/$id/worker-preparation.json" >/dev/null || fail 'both origins not recorded'
save_evidence
pass 'independent and associated bodies coexist, canonical duplicate supplied once with both origins'

new_case plain
printf '%s\n' '---' 'name: fm-example' 'description: Example worker' '---' 'ROLE_BODY_SENTINEL' > "$roles/ROLE.md"
scaffold --worker-role "$roles/ROLE.md"
spawn
receive
assert_grep ROLE_BODY_SENTINEL "$case_dir/input.txt" 'plain role lost'
assert_no_grep ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt" 'plain role acquired unselected skill'
save_evidence
pass 'existing role without associations launches unchanged task'

new_case legacy
scaffold
spawn
receive
assert_no_grep ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt" 'legacy acquired unselected skill'
assert_no_grep ROLE_BODY_SENTINEL "$case_dir/input.txt" 'legacy acquired unselected role'
save_evidence
pass 'legacy no-role task still launches'

# Claude's first user message is deliberately only a record doorbell. Its
# configured SessionStart command must supply the prepared context without
# requiring the first model turn to read that record.
new_case claude-context claude
scaffold --worker-role "$roles/ROLE.md"
spawn
cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = --settings ]; then
    shift
    printf '%s' "$1" > "$FM_RECEIVER_DIR/settings.json"
  fi
  shift
done
jq -r '.hooks.SessionStart[].hooks[].command' "$FM_RECEIVER_DIR/settings.json" |
  while IFS= read -r hook; do bash -c "$hook"; done > "$FM_RECEIVER_DIR/context.txt"
SH
chmod +x "$fakebin/claude"
command=$(fm_test_launch_command "$(cat "$case_dir/launch.sh")")
FM_RECEIVER_DIR="$case_dir" PATH="$fakebin:$PATH" bash -c "$command"
assert_grep ASSOCIATED_BODY_SENTINEL "$case_dir/context.txt" 'Claude pre-turn context lost associated skill'
assert_grep 'Current worker role contract' "$case_dir/context.txt" 'Claude pre-turn context lost worker authority'
save_evidence
pass 'Claude record-backed launch provides role and skills through executable startup context'

new_case managed-links
mkdir -p "$case_dir/shared" "$case_dir/managed"
mv "$skills/associated" "$case_dir/shared/associated"
ln -s "$case_dir/shared/associated" "$skills/associated"
ln -s "$roles/ROLE.md" "$case_dir/managed/fm-example.md"
printf '%s\n' '---' 'name: fm-example' 'description: Example worker' 'autoloadSkills: [associated]' '---' 'ROLE_BODY_SENTINEL' > "$roles/ROLE.md"
scaffold --worker-role "$case_dir/managed/fm-example.md" --skill "$case_dir/shared/associated/SKILL.md"
spawn
receive
[ "$(grep -c ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt")" -eq 1 ] || fail 'managed link duplicated skill'
jq -e '.skills[0].origins == ["role", "independent"]' "$home/data/$id/worker-preparation.json" >/dev/null || fail 'managed canonical identity lost origins'
save_evidence
pass 'canonical role and installed skill symlinks retain identity and deduplicate'

new_case independent-only
scaffold --skill "$skills/independent/SKILL.md"
spawn
receive
assert_grep INDEPENDENT_BODY_SENTINEL "$case_dir/input.txt" 'independent-only selection lost'
assert_no_grep ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt" 'independent choice inferred role defaults'
save_evidence
pass 'independent selection works without guessing a role'

malformed_index=0
for binding in 'false' '[../escape]' '[associated,]' '{"method":"associated"}' '*alias' ''; do
  malformed_index=$((malformed_index + 1))
  new_case "malformed-$malformed_index"
  scaffold --worker-role "$roles/ROLE.md"
  printf '%s\n' '---' 'name: fm-example' 'description: Example worker' "autoloadSkills: $binding" '---' 'ROLE_BODY_SENTINEL' > "$roles/ROLE.md"
  if spawn; then fail "malformed binding launched worker: $binding"; fi
  assert_grep autoloadSkills "$case_dir/spawn.log" 'malformed binding diagnostic lost field'
  [ ! -s "$case_dir/launch.sh" ] || fail 'malformed binding emitted launch'
  save_evidence
done
pass 'malformed, null, alias and traversing role bindings stop before launch'

new_case unresolved-scaffold
rm "$skills/associated/SKILL.md"
if scaffold --worker-role "$roles/ROLE.md"; then fail 'unresolved scaffold accepted'; fi
[ ! -e "$home/data/$id/brief.md" ] || fail 'failed resolution created a partial brief'
save_evidence
pass 'unresolved selection refuses before scaffolding'

new_case nonregular
scaffold --worker-role "$roles/ROLE.md"
rm "$skills/associated/SKILL.md"
mkdir "$skills/associated/SKILL.md"
if spawn; then fail 'nonregular associated skill launched'; fi
[ ! -s "$case_dir/launch.sh" ] || fail 'nonregular skill emitted launch'
save_evidence
pass 'nonregular skill content refuses before launch'

new_case raw-command
scaffold --worker-role "$roles/ROLE.md"
if spawn 'codex custom prompt'; then fail 'raw command bypassed prepared delivery'; fi
[ ! -s "$case_dir/launch.sh" ] || fail 'raw command emitted unsupported launch'
save_evidence
pass 'typed preparation cannot silently disappear through a custom launch command'

new_case root-precedence
local_skills="$case_dir/local-skills"
mkdir -p "$local_skills/associated"
printf '%s\n' '---' 'name: associated' 'description: Local method' '---' 'LOCAL_METHOD_BODY' > "$local_skills/associated/SKILL.md"
scaffold --worker-role "$roles/ROLE.md" --skill "$skills/independent/SKILL.md" --skill-root "$local_skills" --skill-root "$skills"
spawn
receive
assert_grep LOCAL_METHOD_BODY "$case_dir/input.txt" 'higher-precedence local skill not supplied'
assert_no_grep ASSOCIATED_BODY_SENTINEL "$case_dir/input.txt" 'shadowed shared body supplied'
assert_grep INDEPENDENT_BODY_SENTINEL "$case_dir/input.txt" 'lower-root independent selection lost'
save_evidence
pass 'explicit allowed roots preserve project-local source precedence and independent selection'

new_case duplicate-binding
scaffold --worker-role "$roles/ROLE.md"
printf '%s\n' '---' 'name: fm-example' 'description: Example worker' 'autoloadSkills: [associated]' 'autoloadSkills: []' '---' 'ROLE_BODY_SENTINEL' > "$roles/ROLE.md"
if spawn; then fail 'duplicate bindings silently discarded association'; fi
[ ! -s "$case_dir/launch.sh" ] || fail 'duplicate binding emitted executable launch'
save_evidence
pass 'duplicate metadata fields cannot silently override a declared association'
