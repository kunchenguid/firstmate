#!/usr/bin/env bash
# Opt-in live guard: the installed Claude loader really loads a composed skill
# overlay for the Zeta/Obsidian consumer shape.
#
# tests/fm-skill-system.test.sh proves hermetically that the Zeta project skill
# and the Obsidian user skills compose into one overlay of symlinks. Whether
# Claude Code then loads that overlay through --add-dir is a vendor behavior no
# stub can confirm, so this guard runs the real binary against it and reads the
# loader's own debug report: the "additional:" count must rise from 0 to the
# number composed, and the overlay's .claude/skills must be among the watched
# skill directories.
#
# Everything is synthetic and under a temp root: the loader gets an empty
# throwaway HOME and CLAUDE_CONFIG_DIR, so neither the real Zeta clone nor the
# real user skill directory is read. The prompt is expected to fail without
# credentials; the skill load it logs happens first either way.
#
#   FM_SKILL_OVERLAY_LOAD_LIVE_E2E=1 tests/fm-skill-overlay-load-live-e2e.test.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SKILL_OVERLAY_LOAD_LIVE_E2E claude

TMP_ROOT=$(fm_test_tmproot fm-skill-overlay-load-live-e2e)
SKILLS="verify obsidian-cli obsidian-bases obsidian-markdown"

write_skill() {  # <dir> <name>
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: %s description\n---\nbody\n' "$2" "$2" > "$1/SKILL.md"
}

run_loader() {  # <log> [--add-dir <dir>]
  local log=$1
  shift
  (cd "$TMP_ROOT/cwd" && env -u CLAUDECODE -u ANTHROPIC_API_KEY \
    HOME="$TMP_ROOT/loader-home" CLAUDE_CONFIG_DIR="$TMP_ROOT/loader-home/.claude" \
    timeout 120 claude "$@" --print --debug-file "$log" 'reply ok' >/dev/null 2>&1) || true
}

additional_count() {  # <log>
  sed -n 's/.*Loaded [0-9]* unique skills (.*additional: \([0-9]*\),.*/\1/p' "$1" | tail -n 1
}

home="$TMP_ROOT/zeta-home"
user_home="$TMP_ROOT/zeta-user"
target="$TMP_ROOT/zeta-target"
mkdir -p "$home/data" "$home/projects/.zeta/.claude/skills" "$user_home/.claude/skills" \
  "$target" "$TMP_ROOT/loader-home/.claude" "$TMP_ROOT/cwd"
printf '%s\n' '- .zeta [no-mistakes] - Zeta distribution clone' > "$home/data/projects.md"
write_skill "$home/projects/.zeta/.claude/skills/verify" verify
for name in obsidian-cli obsidian-bases obsidian-markdown; do
  write_skill "$user_home/.claude/skills/$name" "$name"
done

env -u HOME CLAUDE_CONFIG_DIR="$user_home/.claude" \
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
  "$ROOT/bin/fm-skill-map.sh" --output "$home/data/skill-map.md" --quiet \
  || fail "cold-home map generation failed for the Zeta and Obsidian consumer"
# shellcheck disable=SC2086  # SKILLS is a fixed word list.
FM_HOME="$home" "$ROOT/bin/fm-skill-compose.sh" --target-home "$target" \
  --map "$home/data/skill-map.md" $SKILLS >/dev/null \
  || fail "the Zeta and Obsidian skill set did not compose"
overlay="$target/config/skill-compose/claude/home"
overlay_real=$(cd "$overlay" && pwd -P)
for name in $SKILLS; do
  [ -L "$overlay/.claude/skills/$name" ] || fail "$name was not composed as a symlink"
done

run_loader "$TMP_ROOT/baseline.log"
run_loader "$TMP_ROOT/overlay.log" --add-dir "$overlay_real"

baseline=$(additional_count "$TMP_ROOT/baseline.log")
loaded=$(additional_count "$TMP_ROOT/overlay.log")
[ -n "$baseline" ] || fail "the loader reported no skill load without the overlay; nothing was verified"
[ -n "$loaded" ] || fail "the loader reported no skill load with the overlay; nothing was verified"
[ "$baseline" = 0 ] || fail "the empty loader home already had $baseline additional skills"
[ "$loaded" = 4 ] || fail "the loader took $loaded additional skills from the overlay, expected 4"
grep -F "Watching for changes in skill/command directories:" "$TMP_ROOT/overlay.log" \
  | grep -Fq "$overlay_real/.claude/skills" \
  || fail "the loader did not watch the overlay's .claude/skills directory"

pass "the installed Claude loader loads the composed Zeta and Obsidian overlay through --add-dir"
