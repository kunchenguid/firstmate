#!/usr/bin/env bash
# tests/fm-skill-system.test.sh - generated skill map and symlink composition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-skill-system)
MAP="$ROOT/bin/fm-skill-map.sh"
COMPOSE="$ROOT/bin/fm-skill-compose.sh"

assert_file_contains() {
  local file=$1 needle=$2 msg=$3
  grep -F -- "$needle" "$file" >/dev/null 2>&1 || fail "$msg"
}

assert_file_not_contains() {
  local file=$1 needle=$2 msg=$3
  if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    fail "$msg"
  fi
}

readlink_real() {
  local path=$1 target dir
  target=$(readlink "$path") || return 1
  case "$target" in
    /*) cd "$target" && pwd -P ;;
    *) dir=$(dirname "$path"); cd "$dir/$target" && pwd -P ;;
  esac
}

write_skill() {  # <dir> <name> <description-mode>
  local dir=$1 name=$2 mode=${3:-plain}
  mkdir -p "$dir"
  case "$mode" in
    folded)
      cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: >-
  folded
  description
metadata:
  test: true
---
body must not be read by the map
EOF
      ;;
    crlf)
      printf '%s\r\n' \
        '---' \
        "name: $name" \
        "description: $name description" \
        '---' \
        'body must not be read by the map' > "$dir/SKILL.md"
      ;;
    *)
      cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: $name description
---
body must not be read by the map
EOF
      ;;
  esac
}

test_skill_map_generates_flat_deduped_registry() {
  local home="$TMP_ROOT/map-home" user_home="$TMP_ROOT/user-home" before_count after_count
  mkdir -p "$home/data" "$home/projects/alpha/.claude/skills" "$home/projects/alpha/.agents/skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$home/projects/alpha/.claude/skills/project-skill" project-skill folded
  write_skill "$home/projects/alpha/.claude/skills/crlf-skill" crlf-skill crlf
  ln -s ../../.claude/skills/project-skill "$home/projects/alpha/.agents/skills/project-skill-link"
  [ -d "$home/projects/alpha/.agents/skills/project-skill-link" ] \
    || fail "canonical-path de-duplication fixture symlink does not resolve"
  write_skill "$user_home/.claude/skills/user-skill" user-skill plain

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "skill map generation failed"
  cp "$home/data/skill-map.md" "$home/data/skill-map.before"
  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "second skill map generation failed"
  cmp -s "$home/data/skill-map.before" "$home/data/skill-map.md" \
    || fail "skill map regeneration was not byte-idempotent"

  assert_file_contains "$home/data/skill-map.md" '## firstmate' "firstmate skill group missing"
  assert_file_contains "$home/data/skill-map.md" 'firstmate-coding-guidelines' "firstmate internal skill missing"
  assert_file_contains "$home/data/skill-map.md" '## projects/alpha' "project skill group missing"
  assert_file_contains "$home/data/skill-map.md" '- project-skill — folded description — ' "folded description was not collapsed"
  assert_file_contains "$home/data/skill-map.md" '- crlf-skill — crlf-skill description — ' "CRLF frontmatter skill was not mapped"
  assert_file_contains "$home/data/skill-map.md" '## user' "user skill group missing"
  assert_file_contains "$home/data/skill-map.md" '- user-skill — user-skill description — ' "user skill missing"

  before_count=$(grep -c '^- project-skill ' "$home/data/skill-map.md")
  after_count=$before_count
  [ "$after_count" -eq 1 ] || fail "canonical-path de-duplication failed for symlinked project skill"

  pass "skill map scans frontmatter, groups sources, de-dupes canonical paths, and is idempotent"
}

test_skill_compose_reconciles_symlink_set_and_removes() {
  local home="$TMP_ROOT/compose-home" source="$TMP_ROOT/canonical — source" add_dir skills_dir alpha_real beta_real first_target second_target
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  write_skill "$source/beta" beta plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  beta_real=$(cd "$source/beta" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
- beta — beta description — $beta_real
EOF

  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha beta >/dev/null \
    || fail "initial skill composition failed"
  add_dir="$home/config/skill-compose/claude/home"
  skills_dir="$add_dir/.claude/skills"
  [ -L "$skills_dir/alpha" ] || fail "alpha was not composed as a symlink"
  [ -L "$skills_dir/beta" ] || fail "beta was not composed as a symlink"
  [ "$(readlink_real "$skills_dir/alpha")" = "$alpha_real" ] || fail "alpha symlink does not point at canonical source"
  [ "$(readlink_real "$skills_dir/beta")" = "$beta_real" ] || fail "beta symlink does not point at canonical source"
  [ "$(readlink "$skills_dir/alpha")" = "$alpha_real" ] || fail "map delimiter in canonical path was not preserved"
  [ -f "$skills_dir/alpha/SKILL.md" ] || fail "composed alpha skill is not loadable through the symlink"

  first_target=$(readlink "$skills_dir/alpha")
  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha beta >/dev/null \
    || fail "idempotent skill composition failed"
  second_target=$(readlink "$skills_dir/alpha")
  [ "$first_target" = "$second_target" ] || fail "idempotent run rewrote alpha to a different target"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null \
    || fail "subset reconciliation failed"
  [ -L "$skills_dir/alpha" ] || fail "alpha was removed during subset reconciliation"
  [ ! -e "$skills_dir/beta" ] && [ ! -L "$skills_dir/beta" ] || fail "stale beta symlink survived subset reconciliation"
  [ -d "$beta_real" ] || fail "canonical beta source was removed instead of only its symlink"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" --remove alpha >/dev/null \
    || fail "skill un-compose failed"
  [ ! -e "$skills_dir/alpha" ] && [ ! -L "$skills_dir/alpha" ] || fail "alpha symlink survived --remove"
  [ -d "$alpha_real" ] || fail "canonical alpha source was removed by --remove"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha beta >/dev/null \
    || fail "failed to prepare successful clear"
  FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear >/dev/null \
    || fail "skill set clear failed"
  [ ! -e "$add_dir" ] || fail "--clear left the managed composition set behind"
  [ -d "$alpha_real" ] && [ -d "$beta_real" ] \
    || fail "--clear removed a canonical skill source"

  pass "skill compose creates canonical symlinks, reconciles, removes, and clears without touching sources"
}

test_skill_compose_accepts_internal_double_dots_without_traversal() {
  local home="$TMP_ROOT/double-dot-home" source="$TMP_ROOT/double-dot-source" alpha_real composed
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF

  FM_HOME="$home" "$COMPOSE" --target-home "$home" --set task-fix..bug alpha >/dev/null \
    || fail "internal double dots in a composed set name were rejected"
  composed="$home/config/skill-compose/claude/task-fix..bug/.claude/skills/alpha"
  [ -L "$composed" ] || fail "double-dot set did not compose its requested skill"
  [ "$(readlink_real "$composed")" = "$alpha_real" ] || fail "double-dot set symlink lost its canonical target"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set .. alpha >/dev/null 2>&1; then
    fail "traversal set name was accepted"
  fi
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set ../escape alpha >/dev/null 2>&1; then
    fail "slash traversal set name was accepted"
  fi
  [ ! -e "$home/config/skill-compose/escape" ] || fail "traversal set escaped the Claude composition directory"

  pass "skill compose accepts internal double dots while refusing traversal"
}

test_skill_compose_refuses_non_symlink_collision() {
  local home="$TMP_ROOT/collision-home" source="$TMP_ROOT/collision-source" alpha_real skills_dir
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  skills_dir="$home/config/skill-compose/claude/home/.claude/skills"
  mkdir -p "$skills_dir/alpha"
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null 2>"$home/collision.err"; then
    fail "skill compose replaced a non-symlink collision"
  fi
  assert_file_contains "$home/collision.err" 'refusing to replace non-symlink entry' "collision refusal did not explain the unsafe entry"
  [ -d "$skills_dir/alpha" ] || fail "collision directory was removed"
  [ -d "$alpha_real" ] || fail "canonical alpha source was disturbed after collision refusal"

  pass "skill compose refuses non-symlink collisions"
}

test_skill_compose_prevalidates_before_reconciliation() {
  local home="$TMP_ROOT/prevalidation-home" source="$TMP_ROOT/prevalidation-source" alpha_real beta_real mode skills_dir overlong cold
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  write_skill "$source/beta" beta plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  beta_real=$(cd "$source/beta" && pwd -P)
  overlong=$(printf 'x%.0s' {1..201})
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
- beta — beta description — $beta_real
- $overlong — overlong description — $alpha_real
EOF

  # A refused invocation must leave a previously cold target home untouched: the
  # lock's own mkdir -p would otherwise materialize the managed parent chain.
  cold="$TMP_ROOT/prevalidation-cold"
  mkdir -p "$cold"
  if FM_HOME="$home" "$COMPOSE" --target-home "$cold" --set invalid alpha bad..name >/dev/null 2>&1; then
    fail "compose accepted an unsafe skill name"
  fi
  [ ! -e "$cold/config" ] && [ ! -L "$cold/config" ] \
    || fail "a refused compose created managed state in a cold target home: $(find "$cold")"
  if FM_HOME="$home" "$COMPOSE" --target-home "$cold" --set invalid --remove bad..name >/dev/null 2>&1; then
    fail "remove accepted an unsafe skill name"
  fi
  [ ! -e "$cold/config" ] && [ ! -L "$cold/config" ] \
    || fail "a refused remove created managed state in a cold target home: $(find "$cold")"

  # A resolve-class refusal happens after the lock's own mkdir, so the parent
  # levels may exist afterwards. What must hold is that it created no SET and
  # disturbed nothing the home already had.
  local warm="$TMP_ROOT/prevalidation-warm"
  mkdir -p "$warm/config"
  printf '%s\n' claude > "$warm/config/crew-harness"
  if FM_HOME="$home" "$COMPOSE" --target-home "$warm" --set later nosuchskill >/dev/null 2>&1; then
    fail "compose resolved a skill name that is not in the map"
  fi
  [ -f "$warm/config/crew-harness" ] \
    || fail "a refused compose removed real configuration from the target home"
  [ ! -e "$warm/config/skill-compose/claude/later" ] \
    || fail "a refused compose created its set in the target home: $(find "$warm")"

  # Removing from a set that was never composed must not create the very tree
  # --clear exists to collapse.
  FM_HOME="$home" "$COMPOSE" --target-home "$cold" --set later --remove alpha >/dev/null \
    || fail "remove failed against a set that was never composed"
  [ ! -e "$cold/config/skill-compose/claude/later" ] \
    || fail "remove materialized a set that was never composed: $(find "$cold")"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set invalid alpha bad..name >/dev/null 2>&1; then
    fail "compose accepted an unsafe skill name"
  fi
  [ ! -e "$home/config/skill-compose/claude/invalid" ] \
    || fail "invalid compose arguments created a partial managed set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set "$overlong" alpha >/dev/null 2>&1; then
    fail "compose accepted an overlong set name"
  fi
  [ ! -e "$home/config/skill-compose/claude/$overlong" ] \
    || fail "overlong set name created managed state"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" --set long-skill alpha >/dev/null \
    || fail "failed to prepare overlong skill-name fixture"
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set long-skill beta "$overlong" >/dev/null 2>&1; then
    fail "compose accepted an overlong skill name"
  fi
  [ -L "$home/config/skill-compose/claude/long-skill/.claude/skills/alpha" ] \
    || fail "overlong skill name reconciled the managed set"
  [ ! -e "$home/config/skill-compose/claude/long-skill/.claude/skills/beta" ] \
    || fail "overlong skill name partially added another requested skill"

  for mode in compose remove clear; do
    FM_HOME="$home" "$COMPOSE" --target-home "$home" --set "$mode" alpha beta >/dev/null \
      || fail "failed to prepare $mode prevalidation fixture"
    skills_dir="$home/config/skill-compose/claude/$mode/.claude/skills"
    mkdir "$skills_dir/z-collision"
  done

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set remove --remove alpha bad..name >/dev/null 2>&1; then
    fail "remove accepted an unsafe skill name"
  fi
  [ -L "$home/config/skill-compose/claude/remove/.claude/skills/alpha" ] \
    || fail "invalid remove arguments deleted an earlier valid skill"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set clear --clear alpha >/dev/null 2>&1; then
    fail "clear accepted a skill name"
  fi
  [ -L "$home/config/skill-compose/claude/clear/.claude/skills/alpha" ] \
    || fail "invalid clear arguments mutated the managed set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set compose beta >/dev/null 2>&1; then
    fail "compose reconciled through a non-symlink collision"
  fi
  [ -L "$home/config/skill-compose/claude/compose/.claude/skills/alpha" ] \
    || fail "failed compose removed a stale skill before validating the full set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set remove --remove alpha >/dev/null 2>&1; then
    fail "remove reconciled through a non-symlink collision"
  fi
  [ -L "$home/config/skill-compose/claude/remove/.claude/skills/alpha" ] \
    || fail "failed remove deleted a skill before validating the full set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set clear --clear >/dev/null 2>&1; then
    fail "clear reconciled through a non-symlink collision"
  fi
  [ -L "$home/config/skill-compose/claude/clear/.claude/skills/alpha" ] \
    || fail "failed clear deleted a skill before validating the full set"

  pass "skill compose prevalidates failures before mutating managed sets"
}

test_skill_compose_generates_the_default_map_when_absent() {
  local home="$TMP_ROOT/coldmap-home" user_home="$TMP_ROOT/coldmap-user"
  local target="$TMP_ROOT/coldmap-target" skills
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills" "$target"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/cold-skill" cold-skill plain
  [ ! -e "$home/data/skill-map.md" ] || fail "the cold-map fixture already has a map"

  # No --map and no existing map: composition must generate the default map
  # itself. This is the path fm-spawn --skills takes on a home's first spawn.
  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$COMPOSE" --target-home "$target" cold-skill >/dev/null \
    || fail "composition did not generate the default skill map when it was absent"
  [ -f "$home/data/skill-map.md" ] \
    || fail "composition composed without leaving the generated default map behind"
  [ -L "$target/config/skill-compose/claude/home/.claude/skills/cold-skill" ] \
    || fail "the cold-home composition did not publish its requested skill"

  pass "skill compose generates the default map when a cold home has none"
}

test_skill_compose_refuses_unverified_harnesses() {
  local home="$TMP_ROOT/harness-home" source="$TMP_ROOT/harness-source" alpha_real
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --harness codex alpha \
    >"$home/harness.out" 2>"$home/harness.err"; then
    fail "skill composition accepted an unverified Codex load point"
  fi
  assert_file_contains "$home/harness.err" 'has no verified per-home load point' \
    "unsupported harness refusal did not explain the missing load point"
  [ ! -e "$home/config/skill-compose" ] \
    || fail "unsupported harness refusal created composition state"

  pass "skill compose refuses harnesses without a verified per-home load point"
}

test_locked_session_start_refreshes_map_and_read_only_skips() {
  local world="$TMP_ROOT/session-world" root home user_home fakebin skill out holder
  root="$world/root"
  home="$world/home"
  user_home="$world/user"
  fakebin="$world/fakebin"
  skill="$root/.agents/skills/session-skill"
  mkdir -p "$skill" "$home/state" "$home/data" "$home/config" \
    "$home/projects" "$user_home/.claude/skills" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial --allow-empty
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_skill "$skill" session-skill plain
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh gh-axi treehouse no-mistakes lavish-axi
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
harness=0
[ "$pid" = "$FM_FAKE_HARNESS_PID" ] || [ "$pid" = "${FM_FAKE_LIVE_HOLDER_PID:-}" ] && harness=1
case "$*" in
  *"comm="*) [ "$harness" = 1 ] && printf '%s\n' /usr/local/bin/claude || printf '%s\n' /bin/bash ;;
  *"args="*) [ "$harness" = 1 ] && printf '%s\n' claude || printf '%s\n' bash ;;
  *"ppid="*) /bin/ps -o ppid= -p "$pid" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_FAKE_HARNESS_PID=$$ FM_FAKE_LIVE_HOLDER_PID="${holder:-}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-session-start.sh") \
    || fail "locked session start failed while refreshing the skill map"
  FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-startup-network.sh" wait 60 >/dev/null \
    || fail "the deferred startup stage did not publish after a locked session start"
  assert_file_contains "$home/data/skill-map.md" '- session-skill — session-skill description — ' \
    "locked session start did not refresh the generated skill map"
  # The map's source group is the scanned source, not a label derived from the
  # containing git repository, even though $root is a git repo with no remote.
  assert_file_contains "$home/data/skill-map.md" '## firstmate' \
    "the skill map did not group this repo's skills under their source group"
  assert_file_not_contains "$home/data/skill-map.md" '## root' \
    "the skill map labelled a group from its containing git repository"

  # A reported skip must reach the deferred report, naming the skill, rather than being
  # swallowed or reduced to a blank line.
  mkdir -p "$root/.agents/skills/broken"
  printf -- '---\nname: broken\n' > "$root/.agents/skills/broken/SKILL.md"
  if ! out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_FAKE_HARNESS_PID=$$ FM_FAKE_LIVE_HOLDER_PID="${holder:-}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-session-start.sh"); then
    fail "locked session start failed because one skill was skipped"
  fi
  FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-startup-network.sh" wait 60 >/dev/null \
    || fail "the deferred startup stage did not publish after a skipped skill"
  out=$(FM_FAKE_HARNESS_PID=$$ PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$ROOT/bin/fm-startup-network.sh" report)
  case "$out" in
    *"$root/.agents/skills/broken/SKILL.md"*) ;;
    *) fail "the deferred startup report did not surface the skipped skill the map reported" ;;
  esac
  case "$out" in
    *'refresh failed'*) fail "the report called a written-with-skips map a refresh failure" ;;
    *) ;;
  esac
  rm -rf "$root/.agents/skills/broken"

  printf '%s\n' 'sentinel map must survive read-only session start' > "$home/data/skill-map.md"
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  if ! out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_FAKE_HARNESS_PID=$$ FM_FAKE_LIVE_HOLDER_PID="${holder:-}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-session-start.sh"); then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "read-only session start failed while checking the skill-map boundary"
  fi
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" 'READ-ONLY SESSION' \
    "session-start lock fixture did not enter read-only mode"
  [ "$(cat "$home/data/skill-map.md")" = 'sentinel map must survive read-only session start' ] \
    || fail "read-only session start mutated the private skill map"

  pass "locked session start refreshes the skill map and read-only start leaves it untouched"
}

test_skill_compose_serializes_same_set_reconciliation() {
  local home="$TMP_ROOT/locked-home" source="$TMP_ROOT/locked-source" alpha_real beta_real
  local fakebin="$TMP_ROOT/locked-fakebin" real_awk gate first_pid second_pid skills_dir
  mkdir -p "$home/data" "$fakebin"
  write_skill "$source/alpha" alpha plain
  write_skill "$source/beta" beta plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  beta_real=$(cd "$source/beta" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
- beta — beta description — $beta_real
EOF
  real_awk=$(command -v awk)
  gate="$home/awk-gate"
  cat > "$fakebin/awk" <<EOF
#!/usr/bin/env bash
if [ -n "\${FM_TEST_AWK_GATE:-}" ] && /bin/mkdir "\$FM_TEST_AWK_GATE.owner" 2>/dev/null; then
  /usr/bin/touch "\$FM_TEST_AWK_GATE.entered"
  for _ in \$(seq 1 1500); do
    [ -e "\$FM_TEST_AWK_GATE.release" ] && break
    sleep 0.02
  done
fi
exec "$real_awk" "\$@"
EOF
  chmod +x "$fakebin/awk"

  FM_HOME="$home" FM_TEST_AWK_GATE="$gate" PATH="$fakebin:$PATH" \
    "$COMPOSE" --target-home "$home" alpha >/dev/null &
  first_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$gate.entered" ] && break
    sleep 0.02
  done
  [ -e "$gate.entered" ] || fail "first composition did not enter the serialized reconciliation"

  FM_HOME="$home" FM_TEST_AWK_GATE="$gate" PATH="$fakebin:$PATH" \
    "$COMPOSE" --target-home "$home" beta >/dev/null &
  second_pid=$!
  sleep 0.2
  skills_dir="$home/config/skill-compose/claude/home/.claude/skills"
  [ ! -e "$skills_dir/beta" ] && [ ! -L "$skills_dir/beta" ] \
    || fail "second composition mutated the set while the first reconciliation was active"

  touch "$gate.release"
  wait "$first_pid" || fail "first serialized composition failed"
  wait "$second_pid" || fail "second serialized composition failed"
  [ -L "$skills_dir/beta" ] || fail "second serialized composition did not publish its requested set"
  [ ! -e "$skills_dir/alpha" ] && [ ! -L "$skills_dir/alpha" ] \
    || fail "serialized reconciliation left a stale skill from the first request"
  [ "$(readlink_real "$skills_dir/beta")" = "$beta_real" ] \
    || fail "serialized reconciliation published beta with the wrong canonical target"

  pass "skill compose serializes concurrent reconciliation of one set"
}

test_skill_map_bounds_frontmatter_and_reports_skips() {
  local home="$TMP_ROOT/loud-home" user_home="$TMP_ROOT/loud-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/valid-skill" valid-skill plain

  # Frontmatter opened and never closed, followed by megabytes of body whose own
  # `description:` line the parser must never reach.
  mkdir -p "$skills/unterminated"
  {
    printf '%s\n' '---' 'name: unterminated' 'description: header description'
    yes 'padding line that belongs to the skill body' | head -n 80000
    printf '%s\n' 'description: BODY_WAS_PARSED'
  } > "$skills/unterminated/SKILL.md"

  mkdir -p "$skills/unreadable"
  write_skill "$skills/unreadable" unreadable plain
  chmod 000 "$skills/unreadable/SKILL.md"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e
  chmod 644 "$skills/unreadable/SKILL.md"

  [ "$status" -ne 0 ] \
    || fail "map generation stayed silent about malformed and unreadable skills"
  case "$out" in
    *"$skills/unterminated/SKILL.md"*) ;;
    *) fail "map generation did not name the unterminated skill it skipped: $out" ;;
  esac
  case "$out" in
    *"$skills/unreadable/SKILL.md"*) ;;
    *) fail "map generation did not name the unreadable skill it skipped: $out" ;;
  esac
  assert_file_not_contains "$home/data/skill-map.md" 'BODY_WAS_PARSED' \
    "unterminated frontmatter was read through the skill body"
  assert_file_not_contains "$home/data/skill-map.md" '- unterminated — ' \
    "a skill whose frontmatter is never closed was mapped anyway"
  assert_file_contains "$home/data/skill-map.md" '- valid-skill — ' \
    "a valid sibling skill was dropped along with the malformed ones"

  chmod 000 "$skills/unreadable/SKILL.md"
  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$COMPOSE" --target-home "$home" --refresh-map valid-skill 2>&1)
  status=$?
  set -e
  chmod 644 "$skills/unreadable/SKILL.md"
  [ "$status" -eq 0 ] \
    || fail "a reported skill skip blocked composition of the skills that did parse: $out"
  [ -L "$home/config/skill-compose/claude/home/.claude/skills/valid-skill" ] \
    || fail "composition alongside a reported skip did not publish the valid skill"

  pass "skill map is closed-delimiter bound, names every skipped skill, and still composes"
}

test_skill_map_reports_unreadable_skill_md_kinds() {
  local home="$TMP_ROOT/kinds-home" user_home="$TMP_ROOT/kinds-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/valid-skill" valid-skill plain

  # A SKILL.md that exists but is not a readable regular file is a skill this scan
  # cannot read, so each kind must be reported rather than dropped.
  mkdir -p "$skills/dir-skill-md/SKILL.md"
  mkdir -p "$skills/dangling"
  ln -s /nonexistent/target "$skills/dangling/SKILL.md"
  mkdir -p "$skills/fifo"
  mkfifo "$skills/fifo/SKILL.md"
  # An unsearchable skill folder hides its own SKILL.md from every stat, so the
  # folder itself must be reported rather than vanishing.
  mkdir -p "$skills/unsearchable"
  write_skill "$skills/unsearchable" unsearchable plain
  chmod 000 "$skills/unsearchable"
  # A folder with no SKILL.md at all is not a skill and must stay unreported.
  mkdir -p "$skills/not-a-skill-folder"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e
  chmod 755 "$skills/unsearchable"

  [ "$status" -ne 0 ] || fail "map generation stayed silent about unreadable SKILL.md kinds: $out"
  case "$out" in
    *"$skills/dir-skill-md/SKILL.md"*) ;;
    *) fail "a SKILL.md that is a directory was skipped without being named: $out" ;;
  esac
  case "$out" in
    *"$skills/dangling/SKILL.md"*) ;;
    *) fail "a dangling SKILL.md symlink was skipped without being named: $out" ;;
  esac
  case "$out" in
    *"$skills/fifo/SKILL.md"*) ;;
    *) fail "a SKILL.md that is a FIFO was skipped without being named: $out" ;;
  esac
  case "$out" in
    *"$skills/unsearchable"*) ;;
    *) fail "an unsearchable skill folder was skipped without being named: $out" ;;
  esac
  case "$out" in
    *not-a-skill-folder*) fail "a folder with no SKILL.md was reported as a skipped skill: $out" ;;
    *) ;;
  esac
  case "$out" in
    *'4 skill(s) skipped'*) ;;
    *) fail "the skipped count did not match the four unreadable skills: $out" ;;
  esac
  assert_file_contains "$home/data/skill-map.md" '- valid-skill — ' \
    "the valid sibling skill was dropped alongside the unreadable ones"

  pass "skill map names every unreadable SKILL.md kind and counts each one"
}

test_skill_map_stops_reading_at_its_frontmatter_bound() {
  local home="$TMP_ROOT/bound-home" user_home="$TMP_ROOT/bound-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Frontmatter that IS properly closed, but whose closing delimiter sits beyond
  # the generator's byte bound. Only the bound can refuse this one: the
  # closed-delimiter check alone would accept it after reading the whole file.
  mkdir -p "$skills/past-bound"
  {
    printf '%s\n' '---' 'name: past-bound' 'description: past-bound description'
    yes '  padding: this indented line sits inside the frontmatter block' | head -n 2000
    printf '%s\n' '---' 'body'
  } > "$skills/past-bound/SKILL.md"
  [ "$(wc -c < "$skills/past-bound/SKILL.md")" -gt 65536 ] \
    || fail "the past-bound fixture is not larger than the generator's byte bound"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] \
    || fail "frontmatter closed past the byte bound was accepted, so nothing bounds the read: $out"
  case "$out" in
    *"$skills/past-bound/SKILL.md"*) ;;
    *) fail "the past-bound skill was not named as skipped: $out" ;;
  esac
  assert_file_not_contains "$home/data/skill-map.md" '- past-bound — ' \
    "a skill whose frontmatter closes past the byte bound was mapped anyway"

  pass "skill map stops reading each SKILL.md at its frontmatter byte bound"
}

test_skill_map_refuses_a_delimiter_manufactured_by_the_bound() {
  local home="$TMP_ROOT/trunc-home" user_home="$TMP_ROOT/trunc-user" skills out status pad header
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Frontmatter that is never closed, plus a longer run of dashes placed so the
  # byte bound cuts it to exactly three. The bound must not manufacture the
  # closing delimiter it exists to require.
  # The generator reads one byte past its bound to tell a truncated file from one
  # ending exactly at it, so the dash run is aligned to that read, not to the
  # bound itself: bytes 65535..65537 must be "---" so the truncated final line is
  # exactly a closing delimiter. Aligning to 65536 instead leaves "----", which
  # never reaches the guard and makes this test vacuous.
  mkdir -p "$skills/manufactured"
  header="$TMP_ROOT/manufactured.header"
  printf -- '---\nname: manufactured\ndescription: manufactured description\n' > "$header"
  pad=$((65533 - $(wc -c < "$header")))
  [ "$pad" -gt 0 ] || fail "the manufactured-close fixture header does not fit under the bound"
  {
    cat "$header"
    head -c "$pad" /dev/zero | tr '\0' 'x'
    printf -- '\n-------\nbody\n'
  } > "$skills/manufactured/SKILL.md"
  [ "$(head -c 65537 "$skills/manufactured/SKILL.md" | tail -c 4)" = "$(printf -- '\n---')" ] \
    || fail "the manufactured-close fixture does not truncate to a bare --- at the read bound"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] \
    || fail "a dash run truncated by the byte bound was accepted as a closing delimiter: $out"
  assert_file_not_contains "$home/data/skill-map.md" '- manufactured — ' \
    "unclosed frontmatter was mapped because the bound manufactured its delimiter"

  pass "skill map refuses a closing delimiter manufactured by truncation"
}

test_skill_map_refuses_unusable_skill_names() {
  local home="$TMP_ROOT/names-home" user_home="$TMP_ROOT/names-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/alpha-skill" alpha-skill plain

  # A name carrying the map's own separator would shadow or redirect another skill
  # when the map is read back, so it must never reach the map.
  mkdir -p "$skills/separator"
  printf -- '---\nname: alpha-skill — hijacked\ndescription: d\n---\nbody\n' \
    > "$skills/separator/SKILL.md"
  # A block-scalar name used to be emitted as the literal block indicator.
  mkdir -p "$skills/blockname"
  printf -- '---\nname: >-\n  real-name\ndescription: d\n---\nbody\n' \
    > "$skills/blockname/SKILL.md"
  # A name ending in an em dash forms a separator against the renderer's own
  # spacing, so the reader splits inside the name and resolves the wrong folder.
  mkdir -p "$skills/boundary"
  printf -- '---\nname: alpha-skill \xe2\x80\x94\ndescription: attacker skill\n---\nATTACKER\n' \
    > "$skills/boundary/SKILL.md"
  # A leading em dash is the mirror image of the same trick.
  mkdir -p "$skills/leading"
  printf -- '---\nname: \xe2\x80\x94 alpha-skill\ndescription: attacker skill\n---\nATTACKER\n' \
    > "$skills/leading/SKILL.md"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "unusable skill names were accepted silently: $out"
  assert_file_not_contains "$home/data/skill-map.md" 'hijacked' \
    "a name carrying the map separator reached the map"
  assert_file_not_contains "$home/data/skill-map.md" '- >- — ' \
    "a block-scalar name was emitted as the literal block indicator"
  assert_file_contains "$home/data/skill-map.md" '- alpha-skill — alpha-skill description — ' \
    "the legitimate skill was lost or shadowed by the unusable names"
  assert_file_not_contains "$home/data/skill-map.md" 'attacker skill' \
    "a name forming a separator at the field boundary reached the map"

  # The legitimate name must still resolve to its own folder, not an attacker's,
  # and must not have become ambiguous.
  FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" alpha-skill \
    >/dev/null || fail "a crafted name made the legitimate skill unresolvable"
  [ "$(readlink_real "$home/config/skill-compose/claude/home/.claude/skills/alpha-skill")" \
    = "$(cd "$skills/alpha-skill" && pwd -P)" ] \
    || fail "the trusted skill name resolved to a folder the crafted name chose"

  pass "skill map refuses every skill name that could form the record separator"
}

test_skill_map_refuses_a_skill_folder_that_breaks_the_record() {
  local home="$TMP_ROOT/pathframe-home" user_home="$TMP_ROOT/pathframe-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/good" good plain

  # The path is the one field written raw. A folder name carrying a field or
  # record delimiter reframes the record, so a later lookup of the crafted name
  # resolves to the prefix of that path, which is a real and different skill.
  mkdir -p "$skills/$(printf 'good\tshadow')"
  printf -- '---\nname: tabbed\ndescription: tab folder\n---\nbody\n' \
    > "$skills/$(printf 'good\tshadow')/SKILL.md"
  mkdir -p "$skills/$(printf 'nl\ninjected')"
  printf -- '---\nname: newlined\ndescription: nl folder\n---\nbody\n' \
    > "$skills/$(printf 'nl\ninjected')/SKILL.md"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "skill folders that break the map record were accepted: $out"
  assert_file_not_contains "$home/data/skill-map.md" '- tabbed ' \
    "a folder name carrying a tab produced a map record"
  assert_file_not_contains "$home/data/skill-map.md" '- newlined ' \
    "a folder name carrying a newline produced a map record"
  # Every surviving record must still split into exactly three fields.
  awk -F ' — ' '/^- /{ if (NF != 3) exit 1 }' "$home/data/skill-map.md" \
    || fail "a record in the generated map does not split into exactly three fields"
  assert_file_contains "$home/data/skill-map.md" '- good — good description — ' \
    "the legitimate skill was lost along with the record-breaking folders"

  # And the crafted name must not resolve at all, least of all to good's folder.
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" tabbed \
    >/dev/null 2>&1; then
    fail "a name from a record-breaking folder resolved and composed"
  fi

  pass "skill map refuses a skill folder whose path would break the record"
}

test_skill_map_refuses_a_record_breaking_path_before_deduping() {
  local home="$TMP_ROOT/poison-home" user_home="$TMP_ROOT/poison-user" proj out status
  proj="$home/projects/p"
  mkdir -p "$home/data" "$proj/.claude/skills/impostor" "$proj/.agents/skills/trusted-skill" \
    "$user_home/.claude/skills"
  printf '%s\n' '- p [no-mistakes] - fixture project' > "$home/data/projects.md"

  # A folder whose name carries a newline is also the dedupe key, and grep -F
  # reads a newline in its pattern as a pattern separator. Reached first, such a
  # path seeds the seen set with its own pre-newline prefix, which would then
  # silently erase the real skill of that name and leave an impostor alone on it.
  mkdir -p "$proj/.agents/skills/$(printf 'trusted-skill\nJUNK')"
  printf -- '---\nname: decoy\ndescription: decoy\n---\nbody\n' \
    > "$proj/.agents/skills/$(printf 'trusted-skill\nJUNK')/SKILL.md"
  ln -s "$proj/.agents/skills/$(printf 'trusted-skill\nJUNK')" "$proj/.claude/skills/aa-early"
  printf -- '---\nname: trusted-skill\ndescription: REAL\n---\nbody\n' \
    > "$proj/.agents/skills/trusted-skill/SKILL.md"
  printf -- '---\nname: trusted-skill\ndescription: IMPOSTOR\n---\nbody\n' \
    > "$proj/.claude/skills/impostor/SKILL.md"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "the record-breaking path was accepted: $out"
  # The real skill must survive, so the duplicate name still fails closed as
  # ambiguous instead of resolving silently to the impostor.
  assert_file_contains "$home/data/skill-map.md" '- trusted-skill — REAL — ' \
    "the poisoned dedupe key erased the real skill"
  [ "$(grep -c '^- trusted-skill ' "$home/data/skill-map.md")" -eq 2 ] \
    || fail "the trusted name no longer has both records, so it cannot fail closed"
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" \
    trusted-skill >/dev/null 2>&1; then
    fail "a duplicated trusted skill name resolved instead of refusing as ambiguous"
  fi
  # Each skip is one diagnostic line. Printed raw, the embedded newline would put
  # the suffix on a line of its own and make the line above read as the innocent
  # prefix, so no output line may be the bare suffix.
  [ "$(printf '%s\n' "$out" | grep -cx 'JUNK')" -eq 0 ] \
    || fail "a hostile path was printed raw and split its own diagnostic line: $out"

  pass "skill map refuses a record-breaking path before it can poison the dedupe"
}

test_skill_map_quotes_every_path_it_names() {
  local home="$TMP_ROOT/inject-home" user_home="$TMP_ROOT/inject-user" skills out forged
  skills="$home/projects/p/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- p [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Every SKILL_MAP: line goes to the session digest verbatim, and a folder name is
  # attacker-controlled in any repo a project clone tracks. A newline in one must
  # not be able to forge a whole diagnostic line there.
  forged='SKILL_MAP: 0 skill(s) skipped; the map above is complete'
  ln -s /nonexistent/target "$skills/$(printf 'a\n%s' "$forged")"
  mkdir -p "$skills/$(printf 'b\n%s' "$forged")"
  chmod 000 "$skills/$(printf 'b\n%s' "$forged")"
  mkdir -p "$skills/c" && printf -- '---\nname: c\n' > "$skills/c/SKILL.md"
  mkdir -p "$home/projects/p/.agents"
  ln -s "$skills/$(printf 'b\n%s' "$forged")" "$home/projects/p/.agents/skills"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  set -e
  chmod 755 "$skills/$(printf 'b\n%s' "$forged")"

  [ "$(printf '%s\n' "$out" | grep -cxF "$forged")" -eq 0 ] \
    || fail "a crafted path forged a standalone SKILL_MAP diagnostic line: $out"
  case "$out" in
    *'skipped skill folder symlink that does not resolve'*) ;;
    *) fail "the dangling symlink was not reported at all: $out" ;;
  esac

  pass "skill map quotes every path it names so none can forge a diagnostic line"
}

test_skill_map_keeps_an_em_dash_in_a_skill_path() {
  local home="$TMP_ROOT/dashpath-home" user_home="$TMP_ROOT/dashpath-user" skills real
  skills="$home/projects/p/.claude/skills"
  mkdir -p "$home/data" "$user_home/.claude/skills"
  # An em dash in a path does not break the record: the reader takes everything
  # after the second separator, so refusing it would disable every skill under an
  # ordinarily named parent directory.
  mkdir -p "$home/projects/p/Work — Notes/.claude/skills/dashed"
  skills="$home/projects/p/Work — Notes/.claude/skills"
  printf '%s\n' '- p [no-mistakes] - fixture project' > "$home/data/projects.md"
  mkdir -p "$home/projects/p/.claude"
  ln -s "$skills" "$home/projects/p/.claude/skills"
  printf -- '---\nname: dashed\ndescription: dashed description\n---\nbody\n' \
    > "$skills/dashed/SKILL.md"
  real=$(cd "$skills/dashed" && pwd -P)

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "a skill under a path containing an em dash was refused"
  assert_file_contains "$home/data/skill-map.md" '- dashed — dashed description — ' \
    "the skill under an em-dash path was not mapped"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" dashed \
    >/dev/null || fail "a skill under an em-dash path did not compose"
  [ "$(readlink_real "$home/config/skill-compose/claude/home/.claude/skills/dashed")" = "$real" ] \
    || fail "the em-dash path resolved to the wrong folder"

  pass "skill map records and resolves a skill whose path contains an em dash"
}

test_skill_map_reports_an_unresolvable_skill_folder_symlink() {
  local home="$TMP_ROOT/dangdir-home" user_home="$TMP_ROOT/dangdir-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/good" good plain
  # A skill folder that is a symlink going nowhere is as present to a human as a
  # dangling SKILL.md, which is already reported.
  ln -s /nonexistent/skill-target "$skills/dangling-folder"
  ln -s loop-folder "$skills/loop-folder"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] \
    || fail "an unresolvable skill folder symlink was dropped silently: $out"
  case "$out" in
    *"$skills/dangling-folder"*) ;;
    *) fail "the dangling skill folder symlink was not named: $out" ;;
  esac
  case "$out" in
    *"$skills/loop-folder"*) ;;
    *) fail "the looping skill folder symlink was not named: $out" ;;
  esac
  assert_file_contains "$home/data/skill-map.md" '- good — ' \
    "the valid sibling skill was dropped alongside the unresolvable symlinks"

  pass "skill map names a skill folder symlink that does not resolve"
}

test_skill_map_accepts_trailing_space_on_the_closing_delimiter() {
  local home="$TMP_ROOT/closews-home" user_home="$TMP_ROOT/closews-user" skills
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  # Trailing whitespace on a delimiter is an ordinary editor artifact and the
  # frontmatter is closed, so requiring the close must not refuse it.
  mkdir -p "$skills/closews"
  printf -- '---\nname: closews\ndescription: an ordinary skill\n--- \nbody\n' \
    > "$skills/closews/SKILL.md"

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "trailing whitespace on the closing delimiter was refused as unclosed"
  assert_file_contains "$home/data/skill-map.md" '- closews — an ordinary skill — ' \
    "frontmatter closed by a delimiter with trailing whitespace was not mapped"

  pass "skill map accepts trailing whitespace on a frontmatter delimiter"
}

test_skill_map_keeps_em_dash_descriptions_out_of_the_separator() {
  local home="$TMP_ROOT/desc-home" user_home="$TMP_ROOT/desc-user" skills
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Valid human YAML whose description carries em dashes where the old single
  # spaced-separator replacement could not reach, or re-formed one.
  mkdir -p "$skills/trailing"
  printf -- '---\nname: trailing\ndescription: Audit the thing \xe2\x80\x94\n---\nbody\n' \
    > "$skills/trailing/SKILL.md"
  mkdir -p "$skills/doubled"
  printf -- '---\nname: doubled\ndescription: a \xe2\x80\x94 \xe2\x80\x94 b\n---\nbody\n' \
    > "$skills/doubled/SKILL.md"

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "a description carrying an em dash was refused instead of sanitized"

  # Each record must still carry exactly three separators, so the reader's split
  # finds the real canonical folder.
  local name
  for name in trailing doubled; do
    FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" "$name" \
      >/dev/null || fail "an em-dash description made $name unresolvable"
    [ "$(readlink_real "$home/config/skill-compose/claude/home/.claude/skills/$name")" \
      = "$(cd "$skills/$name" && pwd -P)" ] \
      || fail "an em-dash description redirected $name away from its canonical folder"
  done

  pass "skill map sanitizes every em dash out of a description rather than refusing it"
}

test_skill_compose_refuses_a_relative_mapped_path() {
  local home="$TMP_ROOT/relpath-home" out status
  mkdir -p "$home/data"
  cat > "$home/data/skill-map.md" <<'MAPEOF'
# Skill map

## fixture
- relskill — d — relative/decoy/path
MAPEOF
  set +e
  out=$(cd "$home" && FM_HOME="$home" "$COMPOSE" --target-home "$home" \
    --map "$home/data/skill-map.md" relskill 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a relative mapped path was composed: $out"
  case "$out" in
    *'not absolute'*) ;;
    *) fail "the refusal did not name the relative mapped path: $out" ;;
  esac

  pass "skill compose refuses a mapped skill path that is not absolute"
}

test_skill_map_reports_an_unreadable_source_directory() {
  local home="$TMP_ROOT/srcdir-home" user_home="$TMP_ROOT/srcdir-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/one" one plain
  write_skill "$skills/two" two plain
  write_skill "$user_home/.claude/skills/user-skill" user-skill plain
  chmod 0111 "$skills"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e
  chmod 0755 "$skills"

  [ "$status" -ne 0 ] \
    || fail "an unreadable skill source directory dropped every skill silently: $out"
  case "$out" in
    *"$skills"*) ;;
    *) fail "the unreadable source directory was not named: $out" ;;
  esac
  assert_file_contains "$home/data/skill-map.md" '- user-skill — ' \
    "a readable source was dropped along with the unreadable one"

  pass "skill map names an unreadable skill source directory instead of reporting no skills"
}

test_skill_map_accepts_a_delimiter_at_end_of_file() {
  local home="$TMP_ROOT/eof-home" user_home="$TMP_ROOT/eof-user" skills
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Valid, fully closed frontmatter whose last byte is the closing delimiter.
  # The truncation guard must not refuse a delimiter at a real end of file.
  mkdir -p "$skills/no-trailing-newline"
  printf -- '---\nname: no-trailing-newline\ndescription: valid frontmatter\n---' \
    > "$skills/no-trailing-newline/SKILL.md"

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "a closing delimiter at a real end of file was refused as truncated"
  assert_file_contains "$home/data/skill-map.md" '- no-trailing-newline — valid frontmatter — ' \
    "valid frontmatter ending at the closing delimiter was not mapped"

  pass "skill map accepts a closing delimiter at a real end of file"
}

test_skill_compose_clear_collapses_a_legacy_set() {
  local home="$TMP_ROOT/legacy-home" source="$TMP_ROOT/legacy-source" alpha_real add_dir out
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null \
    || fail "failed to prepare the legacy clear fixture"
  add_dir="$home/config/skill-compose/claude/home"
  # A set composed by a version that still generated manifest.tsv.
  printf 'alpha\t%s\n' "$alpha_real" > "$add_dir/manifest.tsv"

  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear) \
    || fail "clear failed on a legacy set"
  [ ! -e "$add_dir" ] \
    || fail "clear reported success but left the legacy set root behind: $out ($(find "$add_dir"))"
  [ -d "$alpha_real" ] || fail "clear removed the canonical skill source"

  pass "skill compose clear collapses a set left behind by a manifest-writing version"
}

test_skill_compose_clear_reports_what_it_could_not_remove() {
  local home="$TMP_ROOT/clearhonest-home" source="$TMP_ROOT/clearhonest-source"
  local alpha_real add_dir skills_dir out
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null \
    || fail "failed to prepare the honest-clear fixture"
  add_dir="$home/config/skill-compose/claude/home"
  skills_dir="$add_dir/.claude/skills"
  # Something the helper does not own, such as a file Claude itself wrote under
  # the added directory, keeps the set root alive after every link is gone.
  printf '%s\n' '{}' > "$add_dir/settings.local.json"

  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear 2>&1) \
    || fail "clear failed with an unowned file in the set root"
  [ ! -e "$skills_dir/alpha" ] && [ ! -L "$skills_dir/alpha" ] \
    || fail "clear left a composed skill link behind"
  case "$out" in
    *'still holds'*) ;;
    *) fail "clear claimed success while the set root survived: $out" ;;
  esac
  case "$out" in
    *settings.local.json*) ;;
    *) fail "clear did not name what kept the set root alive: $out" ;;
  esac
  [ -d "$alpha_real" ] || fail "clear removed the canonical skill source"

  # --print-add-dir must keep its bare-path stdout contract and still report the
  # leftover, rather than losing the report on the machine-consumed path.
  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear --print-add-dir 2>/dev/null)
  [ "$out" = "$add_dir" ] \
    || fail "--print-add-dir clear did not print the bare overlay path: $out"
  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear --print-add-dir 2>&1 >/dev/null)
  case "$out" in
    *'still holds'*) ;;
    *) fail "--print-add-dir clear lost the report of what it could not remove: $out" ;;
  esac

  # A no-op on a cold home must not create the SET. The three parent levels the
  # lock needs may remain: nothing removes them, deliberately, because every
  # version of that cleanup proved more dangerous than three empty directories.
  local cold="$TMP_ROOT/clearhonest-cold"
  mkdir -p "$cold"
  FM_HOME="$home" "$COMPOSE" --target-home "$cold" --clear >/dev/null \
    || fail "clear failed on a cold target home"
  [ ! -e "$cold/config/skill-compose/claude/home" ] \
    || fail "a no-op clear created the set it was asked to clear: $(find "$cold")"
  FM_HOME="$home" "$COMPOSE" --target-home "$cold" --remove alpha >/dev/null \
    || fail "remove failed on a cold target home"
  [ ! -e "$cold/config/skill-compose/claude/home" ] \
    || fail "a no-op remove created the set it had nothing to remove from: $(find "$cold")"

  pass "skill compose clear reports the set root it could not remove on both paths"
}

test_skill_map_scans_hidden_projects_and_config_dir_without_home() {
  local home="$TMP_ROOT/discovery-home" user_home="$TMP_ROOT/discovery-user"
  mkdir -p "$home/data" "$home/projects/.hidden/.claude/skills" "$user_home/.claude/skills" \
    "$home/projects/foo bar/.agents/skills" "$home/projects/legacy name/.claude/skills"
  printf '%s\n' '- .hidden [no-mistakes] - registered dot-prefixed project' \
    '- foo bar [local-only] - registered multi-word project' \
    '- legacy name - registered multi-word project without a posture' > "$home/data/projects.md"
  write_skill "$home/projects/.hidden/.claude/skills/hidden-skill" hidden-skill plain
  write_skill "$home/projects/foo bar/.agents/skills/spaced-skill" spaced-skill plain
  write_skill "$home/projects/legacy name/.claude/skills/legacy-skill" legacy-skill plain
  write_skill "$user_home/.claude/skills/config-dir-skill" config-dir-skill plain

  env -u HOME CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "skill map generation failed with HOME unset"

  assert_file_contains "$home/data/skill-map.md" '- hidden-skill — ' \
    "a registered dot-prefixed project was not scanned"
  assert_file_contains "$home/data/skill-map.md" '- spaced-skill — ' \
    "a registered multi-word project was not scanned"
  assert_file_contains "$home/data/skill-map.md" '- legacy-skill — ' \
    "a registered multi-word project without a posture was not scanned"
  assert_file_contains "$home/data/skill-map.md" '- config-dir-skill — ' \
    "CLAUDE_CONFIG_DIR skills were skipped because HOME was unset"

  pass "skill map scans registered dot-prefixed projects and honors CLAUDE_CONFIG_DIR without HOME"
}

test_skill_compose_revalidates_ancestry_before_mutating() {
  local home="$TMP_ROOT/window-home" target="$TMP_ROOT/window-target"
  local source="$TMP_ROOT/window-source" alpha_real tracked out status gate bindir
  mkdir -p "$home/data" "$target/config/skill-compose/claude/home/.claude/skills"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  tracked="$target/.agents/skills"
  mkdir -p "$tracked"
  write_skill "$source/keep" keep plain
  ln -s "$(cd "$source/keep" && pwd -P)" "$tracked/keep"

  # The refresh between the ancestry check and the first mutation takes seconds on
  # a real tree, and every fm-spawn --skills launch walks it. Stand in for a slow
  # refresh with one that swaps the validated ancestry for a symlink into the
  # tracked tree, using a copied bin/ so no test hook is needed in the script.
  gate="$TMP_ROOT/window-gate"
  bindir="$TMP_ROOT/window-bin"
  mkdir -p "$bindir"
  cp "$ROOT/bin/fm-skill-compose.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$bindir/"
  cat > "$bindir/fm-skill-map.sh" <<SH
#!/usr/bin/env bash
rm -rf "$target/config/skill-compose/claude/home/.claude"
ln -s "$tracked" "$target/config/skill-compose/claude/home/.claude"
touch "$gate.swapped"
exit 0
SH
  chmod +x "$bindir/fm-skill-map.sh"

  set +e
  out=$(FM_HOME="$home" "$bindir/fm-skill-compose.sh" --target-home "$target" \
    --refresh-map --map "$home/data/skill-map.md" alpha 2>&1)
  status=$?
  set -e
  [ -e "$gate.swapped" ] \
    || fail "the ancestry swap never ran, so the pre-mutation window was not exercised"
  [ "$status" -ne 0 ] \
    || fail "composition mutated through an ancestry symlink planted during the refresh: $out"
  [ ! -e "$tracked/alpha" ] && [ ! -L "$tracked/alpha" ] \
    || fail "composition wrote into the tracked tree through the swapped ancestry"
  [ -L "$tracked/keep" ] \
    || fail "composition removed a tracked entry through the swapped ancestry"

  pass "skill compose re-checks the managed ancestry before it mutates"
}

test_skill_compose_revalidates_entries_before_mutating() {
  local home="$TMP_ROOT/entrywin-home" target="$TMP_ROOT/entrywin-target"
  local source="$TMP_ROOT/entrywin-source" alpha_real out status gate bindir skills_dir
  skills_dir="$target/config/skill-compose/claude/home/.claude/skills"
  mkdir -p "$home/data" "$skills_dir"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF

  # The ancestry is only half the pre-mutation re-check. A real directory planted
  # at a requested entry during the slow refresh must also be refused, rather than
  # reaching the reconciliation loop where rm and ln fail raw.
  gate="$TMP_ROOT/entrywin-gate"
  bindir="$TMP_ROOT/entrywin-bin"
  mkdir -p "$bindir"
  cp "$ROOT/bin/fm-skill-compose.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$bindir/"
  cat > "$bindir/fm-skill-map.sh" <<SH
#!/usr/bin/env bash
mkdir -p "$skills_dir/alpha"
printf 'planted\n' > "$skills_dir/alpha/marker"
touch "$gate.planted"
exit 0
SH
  chmod +x "$bindir/fm-skill-map.sh"

  set +e
  out=$(FM_HOME="$home" "$bindir/fm-skill-compose.sh" --target-home "$target" \
    --refresh-map --map "$home/data/skill-map.md" alpha 2>&1)
  status=$?
  set -e
  [ -e "$gate.planted" ] || fail "the entry was never planted, so the window was not exercised"
  [ "$status" -ne 0 ] \
    || fail "composition reconciled over a non-symlink entry planted during the refresh: $out"
  case "$out" in
    *'refusing to replace non-symlink entry'*) ;;
    *) fail "the refusal did not name the planted non-symlink entry: $out" ;;
  esac
  [ -f "$skills_dir/alpha/marker" ] \
    || fail "the planted directory was clobbered instead of refused"

  pass "skill compose re-checks managed entries, not only the ancestry, before mutating"
}

test_skill_compose_refuses_symlinked_managed_ancestry() {
  local home="$TMP_ROOT/escape-home" target="$TMP_ROOT/escape-target"
  local source="$TMP_ROOT/escape-source" alpha_real tracked out status level
  mkdir -p "$home/data" "$target/config/skill-compose/claude/home/.claude"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  # The tracked tree holds only symlinks, exactly like a real .agents/skills set,
  # so nothing but the ancestry check itself can refuse this composition.
  tracked="$target/.agents/skills"
  mkdir -p "$tracked"
  write_skill "$source/keep" keep plain
  ln -s "$(cd "$source/keep" && pwd -P)" "$tracked/keep"

  # Every managed level must be refused, not just the innermost one: the compose
  # lock's own mkdir -p creates the upper levels, so a symlink at any of them
  # would be followed on the way down.
  for level in \
    config \
    config/skill-compose \
    config/skill-compose/claude \
    config/skill-compose/claude/home \
    config/skill-compose/claude/home/.claude \
    config/skill-compose/claude/home/.claude/skills; do
    rm -rf "$target/config"
    mkdir -p "$target/$(dirname "$level")"
    ln -s "$tracked" "$target/$level"

    set +e
    out=$(FM_HOME="$home" "$COMPOSE" --target-home "$target" alpha 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] \
      || fail "composition followed the symlinked managed path $level instead of refusing: $out"
    case "$out" in
      *'refusing to compose through a symlinked managed path'*) ;;
      *) fail "refusal for $level did not name the symlinked managed path: $out" ;;
    esac
    [ -L "$tracked/keep" ] \
      || fail "refused composition at $level deleted an unrelated skill from the tracked tree"
    [ ! -e "$tracked/alpha" ] && [ ! -L "$tracked/alpha" ] \
      || fail "refused composition at $level wrote a composed link into the tracked tree"
  done

  pass "skill compose refuses a symlink at every managed ancestry level before any mutation"
}

test_skill_compose_quotes_entry_names_it_names() {
  local home="$TMP_ROOT/cquote-home" source="$TMP_ROOT/cquote-source"
  local alpha_real skills_dir out forged
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null \
    || fail "failed to prepare the entry-quoting fixture"
  skills_dir="$home/config/skill-compose/claude/home/.claude/skills"

  # The composed worker writes into this overlay, so an entry name is not trusted
  # input. A newline in one must not forge a standalone refusal line.
  forged='error: refusing to compose through a symlinked managed path: HOME-config'
  mkdir -p "$skills_dir/$(printf 'zz\n%s' "$forged")"
  set +e
  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha 2>&1)
  set -e
  [ "$(printf '%s\n' "$out" | grep -cxF "$forged")" -eq 0 ] \
    || fail "a crafted overlay entry forged a standalone refusal line: $out"
  rm -rf "${skills_dir:?}/$(printf 'zz\n%s' "$forged")"

  # The clear listing walks the same directory and must quote it too.
  printf '%s\n' x > "$home/config/skill-compose/claude/home/$(printf 'notes\n%s' "$forged")"
  set +e
  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear 2>&1)
  set -e
  [ "$(printf '%s\n' "$out" | grep -cxF "$forged")" -eq 0 ] \
    || fail "the clear listing let a crafted file name forge a refusal line: $out"

  pass "skill compose quotes every entry name it prints"
}

test_skill_map_summary_line_is_one_line_when_empty() {
  local home="$TMP_ROOT/count-home" user_home="$TMP_ROOT/count-user" root out
  root="$TMP_ROOT/count-root"
  mkdir -p "$home/data" "$home/projects" "$user_home/.claude/skills" "$root/.agents/skills"

  # bootstrap-diagnostics tells an operator to rerun this command by hand, so its
  # summary must be one line with one count even when nothing was found.
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" 2>&1) \
    || fail "map generation failed on an empty source set"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] \
    || fail "the empty-map summary spans more than one line: $out"
  case "$out" in
    *'(0 skill(s))'*) ;;
    *) fail "the empty-map summary did not report a single zero count: $out" ;;
  esac

  pass "skill map reports an empty map on one line with one count"
}

test_skill_compose_names_every_mapped_path_it_refuses() {
  local home="$TMP_ROOT/rquote-home" source="$TMP_ROOT/rquote-source"
  local good_real out forged esc crafted nosk
  mkdir -p "$home/data"
  write_skill "$source/good" good plain
  good_real=$(cd "$source/good" && pwd -P)

  # Field three of a record is a skill folder path, so it comes from a scanned
  # source. A refusal has to do two things with it: name it, so the operator can
  # fix the map, and quote it, so a carriage return or ANSI sequence cannot erase
  # the refusal and leave a plausible different one in its place.
  esc=$(printf '\033')
  forged="error: skill map refresh failed with status 1"
  crafted="$source/$(printf 'x\r%s' "$forged")"
  mkdir -p "$crafted"
  write_skill "$crafted" collide plain
  nosk="$source/$(printf 'n%s[2K%s' "$esc" "$forged")"
  mkdir -p "$nosk"
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- collide — a — $good_real
- collide — b — $crafted
- lone — c — $source/$(printf 'm%s[2K%s' "$esc" "$forged")
- nosk — d — $nosk
- rel — e — relative$(printf '\r')$forged/path
EOF

  assert_no_raw_controls() {  # <label> <output>
    [ "$(printf '%s' "$2" | LC_ALL=C tr -dc '\r\033' | wc -c | tr -d ' ')" -eq 0 ] \
      || fail "$1 passed a raw control byte through: $2"
    [ "$(printf '%s\n' "$2" | grep -cxF "$forged")" -eq 0 ] \
      || fail "$1 let a corpus path forge its own line: $2"
  }

  # Ambiguity must ENUMERATE its candidates: a refusal that names none leaves the
  # operator unable to find the colliding records at all.
  set +e
  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" \
    collide 2>&1)
  set -e
  assert_no_raw_controls "the ambiguous dump" "$out"
  case "$out" in
    *'is ambiguous'*) ;;
    *) fail "the ambiguous refusal itself went missing: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | grep -c '^  ' || true)" -eq 2 ] \
    || fail "the ambiguous refusal did not enumerate both candidates: $out"
  case "$out" in
    *"$good_real"*) ;;
    *) fail "the ambiguous refusal did not name the uncrafted candidate: $out" ;;
  esac

  # Each single-path refusal must name its path too, not merely the skill name.
  set +e
  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" \
    lone 2>&1)
  set -e
  assert_no_raw_controls "the not-a-directory refusal" "$out"
  case "$out" in
    *'is not a directory'*) ;;
    *) fail "the not-a-directory refusal did not appear: $out" ;;
  esac
  case "$out" in
    *"$source/"*) ;;
    *) fail "the not-a-directory refusal did not name its path: $out" ;;
  esac

  set +e
  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" \
    nosk 2>&1)
  set -e
  assert_no_raw_controls "the missing-SKILL.md refusal" "$out"
  case "$out" in
    *'lacks SKILL.md'*) ;;
    *) fail "the missing-SKILL.md refusal did not appear: $out" ;;
  esac
  case "$out" in
    *"$source/"*) ;;
    *) fail "the missing-SKILL.md refusal did not name its path: $out" ;;
  esac

  set +e
  out=$(cd "$home" && FM_HOME="$home" "$COMPOSE" --target-home "$home" \
    --map "$home/data/skill-map.md" rel 2>&1)
  set -e
  assert_no_raw_controls "the not-absolute refusal" "$out"
  case "$out" in
    *'is not absolute'*) ;;
    *) fail "the not-absolute refusal did not appear: $out" ;;
  esac
  case "$out" in
    *relative*) ;;
    *) fail "the not-absolute refusal did not name its path: $out" ;;
  esac

  pass "skill compose names and quotes every mapped path it refuses"
}

test_skill_compose_never_removes_anything_outside_the_target_home() {
  local home="$TMP_ROOT/outside-home" target="$TMP_ROOT/outside-target"
  local victim="$TMP_ROOT/outside-victim" source="$TMP_ROOT/outside-source"
  local alpha_real out status gate bindir
  mkdir -p "$home/data" "$target" "$victim/skill-compose/claude" "$victim/keepme"
  printf '%s\n' keep > "$victim/keepme/f"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF

  # The dangerous shape is a symlinked ANCESTOR, not a symlinked level: a path
  # based removal resolves through it and reaches outside the home, whereas a
  # trailing symlink rmdir could never follow. Plant the link during the refresh
  # so the run starts from a genuinely cold home and refuses afterwards.
  gate="$TMP_ROOT/outside-gate"
  bindir="$TMP_ROOT/outside-bin"
  mkdir -p "$bindir"
  cp "$ROOT/bin/fm-skill-compose.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$bindir/"
  cat > "$bindir/fm-skill-map.sh" <<SH
#!/usr/bin/env bash
rm -rf "$target/config"
ln -s "$victim" "$target/config"
touch "$gate.swapped"
exit 0
SH
  chmod +x "$bindir/fm-skill-map.sh"

  set +e
  out=$(FM_HOME="$home" "$bindir/fm-skill-compose.sh" --target-home "$target" \
    --refresh-map --map "$home/data/skill-map.md" alpha 2>&1)
  status=$?
  set -e
  [ -e "$gate.swapped" ] || fail "the ancestor swap never ran, so the window was not exercised"
  [ "$status" -ne 0 ] || fail "composition succeeded through a symlinked ancestor: $out"
  [ -d "$victim/skill-compose/claude" ] && [ -d "$victim/skill-compose" ] \
    || fail "a directory outside the target home was removed through a symlinked ancestor: $out"
  [ -f "$victim/keepme/f" ] \
    || fail "unrelated content outside the target home was disturbed"

  pass "skill compose never removes anything outside the target home"
}

test_zeta_obsidian_consumer_composes_from_cold_home() {
  local home="$TMP_ROOT/zeta-home" user_home="$TMP_ROOT/zeta-user"
  local target="$TMP_ROOT/zeta-target" skills_dir name
  mkdir -p "$home/data" "$home/projects/.zeta/.claude/skills" "$user_home/.claude/skills" "$target"
  printf '%s\n' '- .zeta [no-mistakes] - Zeta distribution clone' > "$home/data/projects.md"
  write_skill "$home/projects/.zeta/.claude/skills/verify" verify plain
  for name in obsidian-cli obsidian-bases obsidian-markdown; do
    write_skill "$user_home/.claude/skills/$name" "$name" plain
  done

  env -u HOME CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "cold-home map generation failed for the Zeta and Obsidian consumer"

  FM_HOME="$home" "$COMPOSE" --target-home "$target" --map "$home/data/skill-map.md" \
    verify obsidian-cli obsidian-bases obsidian-markdown >/dev/null \
    || fail "the Zeta and Obsidian skill set did not compose"

  skills_dir="$target/config/skill-compose/claude/home/.claude/skills"
  for name in verify obsidian-cli obsidian-bases obsidian-markdown; do
    [ -L "$skills_dir/$name" ] || fail "$name was not composed as a symlink"
    [ -f "$skills_dir/$name/SKILL.md" ] \
      || fail "$name is not loadable through the composed overlay"
  done

  pass "the Zeta project skill and Obsidian user skills compose into one loadable cold-home overlay"
}

test_skill_map_generates_flat_deduped_registry
test_skill_map_bounds_frontmatter_and_reports_skips
test_skill_map_reports_unreadable_skill_md_kinds
test_skill_map_stops_reading_at_its_frontmatter_bound
test_skill_map_refuses_a_delimiter_manufactured_by_the_bound
test_skill_map_refuses_unusable_skill_names
test_skill_map_refuses_a_skill_folder_that_breaks_the_record
test_skill_map_refuses_a_record_breaking_path_before_deduping
test_skill_map_quotes_every_path_it_names
test_skill_map_keeps_an_em_dash_in_a_skill_path
test_skill_map_reports_an_unresolvable_skill_folder_symlink
test_skill_map_accepts_trailing_space_on_the_closing_delimiter
test_skill_map_keeps_em_dash_descriptions_out_of_the_separator
test_skill_map_reports_an_unreadable_source_directory
test_skill_map_accepts_a_delimiter_at_end_of_file
test_skill_map_scans_hidden_projects_and_config_dir_without_home
test_zeta_obsidian_consumer_composes_from_cold_home
test_skill_compose_reconciles_symlink_set_and_removes
test_skill_compose_accepts_internal_double_dots_without_traversal
test_skill_compose_refuses_non_symlink_collision
test_skill_compose_refuses_a_relative_mapped_path
test_skill_compose_revalidates_ancestry_before_mutating
test_skill_compose_revalidates_entries_before_mutating
test_skill_compose_refuses_symlinked_managed_ancestry
test_skill_compose_quotes_entry_names_it_names
test_skill_map_summary_line_is_one_line_when_empty
test_skill_compose_names_every_mapped_path_it_refuses
test_skill_compose_never_removes_anything_outside_the_target_home
test_skill_compose_clear_collapses_a_legacy_set
test_skill_compose_clear_reports_what_it_could_not_remove
test_skill_compose_prevalidates_before_reconciliation
test_skill_compose_generates_the_default_map_when_absent
test_skill_compose_refuses_unverified_harnesses
test_locked_session_start_refreshes_map_and_read_only_skips
test_skill_compose_serializes_same_set_reconciliation
