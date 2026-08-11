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
  ln -s ../../.claude/skills/project-skill "$home/projects/alpha/.agents/skills/project-skill-link"
  [ -d "$home/projects/alpha/.agents/skills/project-skill-link" ] \
    || fail "canonical-path de-duplication fixture symlink does not resolve"
  write_skill "$user_home/.claude/skills/user-skill" user-skill plain

  HOME="$user_home" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "skill map generation failed"
  cp "$home/data/skill-map.md" "$home/data/skill-map.before"
  HOME="$user_home" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "second skill map generation failed"
  cmp -s "$home/data/skill-map.before" "$home/data/skill-map.md" \
    || fail "skill map regeneration was not byte-idempotent"

  assert_file_contains "$home/data/skill-map.md" '## firstmate' "firstmate skill group missing"
  assert_file_contains "$home/data/skill-map.md" 'firstmate-coding-guidelines' "firstmate internal skill missing"
  assert_file_contains "$home/data/skill-map.md" '## projects/alpha' "project skill group missing"
  assert_file_contains "$home/data/skill-map.md" '- project-skill — folded description — ' "folded description was not collapsed"
  assert_file_contains "$home/data/skill-map.md" '## user' "user skill group missing"
  assert_file_contains "$home/data/skill-map.md" '- user-skill — user-skill description — ' "user skill missing"

  before_count=$(grep -c '^- project-skill ' "$home/data/skill-map.md")
  after_count=$before_count
  [ "$after_count" -eq 1 ] || fail "canonical-path de-duplication failed for symlinked project skill"

  pass "skill map scans frontmatter, groups sources, de-dupes canonical paths, and is idempotent"
}

test_skill_compose_reconciles_symlink_set_and_removes() {
  local home="$TMP_ROOT/compose-home" source="$TMP_ROOT/canonical" add_dir skills_dir alpha_real beta_real first_target second_target
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

  pass "skill compose creates canonical symlinks, reconciles, and un-composes without touching sources"
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
  local home="$TMP_ROOT/prevalidation-home" source="$TMP_ROOT/prevalidation-source" alpha_real beta_real mode skills_dir
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

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set invalid alpha bad..name >/dev/null 2>&1; then
    fail "compose accepted an unsafe skill name"
  fi
  [ ! -e "$home/config/skill-compose/claude/invalid" ] \
    || fail "invalid compose arguments created a partial managed set"

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
  [ -f "$home/config/skill-compose/claude/clear/manifest.tsv" ] \
    || fail "failed clear removed the manifest before validating the full set"

  pass "skill compose prevalidates failures before mutating managed sets"
}

test_skill_map_generates_flat_deduped_registry
test_skill_compose_reconciles_symlink_set_and_removes
test_skill_compose_accepts_internal_double_dots_without_traversal
test_skill_compose_refuses_non_symlink_collision
test_skill_compose_prevalidates_before_reconciliation
