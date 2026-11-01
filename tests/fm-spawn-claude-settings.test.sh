#!/usr/bin/env bash
# tests/fm-spawn-claude-settings.test.sh - regression for the per-task claude
# settings file bin/fm-spawn.sh writes to state/<id>.claude-settings.json.
#
# The file must be valid JSON in BOTH shapes: a secondmate launch arms no busy
# contract and gets the policy keys with no "hooks", while a crewmate ship
# launch additionally carries the busy-state/turn-end hooks. A stray brace made
# claude reject the file and skip firstmate's owned hooks entirely, so the whole
# per-launch policy is asserted structurally, not by string match.
# A bypass launch must also carry skipDangerousModePermissionPrompt, because a
# task worker's --setting-sources '' never reads the captain's user-scope
# acceptance and Claude would park the pane on its Bypass Permissions dialog;
# a config/claude-permission-mode=auto launch requests no bypass and carries none.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (JSON validation)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-settings)

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
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

# settings_check <file> <expect-hooks: yes|no> [expect-bypass-skip: yes|no]
# echoes "ok" or the reason it is not.
settings_check() {
  python3 - "$1" "$2" "${3:-yes}" <<'PY'
import json, sys
path, want_hooks, want_skip = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as fh:
        doc = json.load(fh)
except Exception as exc:  # invalid JSON is the regression this guards
    print("not valid JSON: %s: %r" % (exc, open(path).read()))
    sys.exit(0)
if doc.get("feedbackDrafts") != "off":
    print("feedbackDrafts is %r" % (doc.get("feedbackDrafts"),)); sys.exit(0)
if doc.get("attribution") != {"commit": "", "pr": "", "sessionUrl": False}:
    print("attribution is %r" % (doc.get("attribution"),)); sys.exit(0)
if want_skip == "yes":
    if doc.get("skipDangerousModePermissionPrompt") is not True:
        print("bypass launch lacks skipDangerousModePermissionPrompt: true, got %r" % (doc.get("skipDangerousModePermissionPrompt"),)); sys.exit(0)
elif "skipDangerousModePermissionPrompt" in doc:
    print("non-bypass launch carries skipDangerousModePermissionPrompt %r" % (doc["skipDangerousModePermissionPrompt"],)); sys.exit(0)
if want_hooks == "yes":
    hooks = doc.get("hooks")
    if not isinstance(hooks, dict) or not hooks:
        print("expected a non-empty hooks object, got %r" % (hooks,)); sys.exit(0)
    for key, entries in hooks.items():
        if not isinstance(entries, list) or not entries:
            print("hook %s is %r" % (key, entries)); sys.exit(0)
elif "hooks" in doc:
    print("expected no hooks key, got %r" % (doc["hooks"],)); sys.exit(0)
print("ok")
PY
}

run_spawn() {  # <home> <fakebin> <pane path> <spawn args...>
  local home=$1 fakebin=$2 pane=$3
  shift 3
  mkdir -p "$home/user-home"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" >/dev/null 2>&1 || true
}

new_home() {  # <dir>
  local home=$1
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
}

# --- 1. crewmate ship launch: policy keys AND the owned hooks -----------------
CREW="$TMP_ROOT/crew"
new_home "$CREW/home"
fm_git_worktree "$CREW/project" "$CREW/wt" wt-crew
CREW_FAKE=$(make_fakebin "$CREW/fake")
CREW_ID=settings-crew
mkdir -p "$CREW/home/data/$CREW_ID"
cat > "$CREW/home/data/$CREW_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the generated claude settings file.

## Firstmate spec
Nothing to build; the launch itself is the subject.
EOF
run_spawn "$CREW/home" "$CREW_FAKE" "$CREW/wt" "$CREW_ID" "$CREW/project" --mode no-mistakes --yolo off

CREW_SETTINGS="$CREW/home/state/$CREW_ID.claude-settings.json"
[ -f "$CREW_SETTINGS" ] || fail "a crewmate claude launch wrote no settings file at $CREW_SETTINGS"
RESULT=$(settings_check "$CREW_SETTINGS" yes)
[ "$RESULT" = ok ] || fail "crewmate settings file rejected: $RESULT"

# --- 2. secondmate launch: policy keys, no hooks -----------------------------
SM="$TMP_ROOT/sm"
new_home "$SM/home"
SM_FAKE=$(make_fakebin "$SM/fake")
SM_ID=settings-sm
SM_HOME="$SM/secondmate"
mkdir -p "$SM_HOME/bin" "$SM_HOME/data"
printf '# Firstmate\n' > "$SM_HOME/AGENTS.md"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
printf 'charter\n' > "$SM_HOME/data/charter.md"
mkdir -p "$SM/home/data/$SM_ID"
printf 'charter brief\n' > "$SM/home/data/$SM_ID/brief.md"
run_spawn "$SM/home" "$SM_FAKE" "$SM_HOME" "$SM_ID" "$SM_HOME" --secondmate

SM_SETTINGS="$SM/home/state/$SM_ID.claude-settings.json"
[ -f "$SM_SETTINGS" ] || fail "a secondmate claude launch wrote no settings file at $SM_SETTINGS"
RESULT=$(settings_check "$SM_SETTINGS" no)
[ "$RESULT" = ok ] || fail "secondmate settings file rejected: $RESULT"

# --- 3. config/claude-permission-mode=auto: no bypass acceptance -------------
AUTO="$TMP_ROOT/auto"
new_home "$AUTO/home"
printf 'auto\n' > "$AUTO/home/config/claude-permission-mode"
fm_git_worktree "$AUTO/project" "$AUTO/wt" wt-auto
AUTO_FAKE=$(make_fakebin "$AUTO/fake")
AUTO_ID=settings-auto
mkdir -p "$AUTO/home/data/$AUTO_ID"
cp "$CREW/home/data/$CREW_ID/brief.md" "$AUTO/home/data/$AUTO_ID/brief.md"
run_spawn "$AUTO/home" "$AUTO_FAKE" "$AUTO/wt" "$AUTO_ID" "$AUTO/project" --mode no-mistakes --yolo off

AUTO_SETTINGS="$AUTO/home/state/$AUTO_ID.claude-settings.json"
[ -f "$AUTO_SETTINGS" ] || fail "an auto-mode claude launch wrote no settings file at $AUTO_SETTINGS"
RESULT=$(settings_check "$AUTO_SETTINGS" yes no)
[ "$RESULT" = ok ] || fail "auto-mode settings file rejected: $RESULT"

pass "bin/fm-spawn.sh writes valid claude settings JSON with and without the owned hooks, accepting bypass only for bypass launches"
echo "all fm-spawn-claude-settings tests passed"
