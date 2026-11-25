#!/usr/bin/env bash
# tests/fm-spawn-claude-settings.test.sh - regression for the per-task claude
# settings file bin/fm-spawn.sh writes to state/<id>.claude-settings.json.
#
# The file must be valid JSON for both kinds: every launch carries the policy
# keys and the busy-state hooks, and a secondmate's hooks update only its busy
# record in this parent home, never the parent's turn-ended marker. A stray brace made
# claude reject the file and skip firstmate's owned hooks entirely, so the whole
# per-launch policy is asserted structurally, not by string match.
# A bypass launch must also carry skipDangerousModePermissionPrompt, because a
# task worker's --setting-sources '' never reads the captain's user-scope
# acceptance and Claude would park the pane on its Bypass Permissions dialog;
# a config/claude-permission-mode=auto launch requests no bypass and carries none.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/worker-card-helpers.sh
. "$ROOT/tests/worker-card-helpers.sh"

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
# A task worker also carries the advisory sleep-then-check guard on Bash, logging
# to its own wait-flags file; a secondmate (a supervisor, not a worker) does not.
python3 - "$CREW_SETTINGS" "$CREW_ID" <<'PY' || fail "crewmate settings lack the sleep-then-check PreToolUse guard"
import json, sys
doc = json.load(open(sys.argv[1]))
entries = doc.get("hooks", {}).get("PreToolUse", [])
cmds = [h["command"] for e in entries if e.get("matcher") == "Bash" for h in e.get("hooks", [])]
ok = any("fm-wait-pretool-check.sh" in c and sys.argv[2] + ".wait-flags" in c for c in cmds)
sys.exit(0 if ok else 1)
PY

assert_contains "$(cat "$CREW/home/data/$CREW_ID/notes.md")" 'Exercise the generated claude settings file.' 'launch did not save the initial goal'
assert_worker_card "$CREW_SETTINGS" "$CREW/home/data/$CREW_ID/notes.md" 'Claude spawn (rollout off)'

# --- 2. secondmate launch: policy keys and parent-home busy hooks ------------
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
RESULT=$(settings_check "$SM_SETTINGS" yes)
[ "$RESULT" = ok ] || fail "secondmate settings file rejected: $RESULT"
! grep -F 'fm-wait-pretool-check' "$SM_SETTINGS" >/dev/null \
  || fail "a secondmate must not carry the worker sleep-then-check guard: $(cat "$SM_SETTINGS")"
! grep -F 'turn-ended' "$SM_SETTINGS" >/dev/null \
  || fail "a secondmate's hooks must not touch the parent's turn-ended marker: $(cat "$SM_SETTINGS")"

assert_worker_card "$SM_SETTINGS" "$SM_HOME/data/notes.md" 'Claude secondmate launch'

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

# Lavish hosts are ordinary task workers at launch; page-host.sh owns only park/resume.
PAGE_ID=settings-page
mkdir -p "$AUTO/home/data/$PAGE_ID"
printf '# Task\nHost the Lavish planning page, retain live chat and four critics.\n' > "$AUTO/home/data/$PAGE_ID/brief.md"
run_spawn "$AUTO/home" "$AUTO_FAKE" "$AUTO/wt" "$PAGE_ID" "$AUTO/project" --scout
assert_worker_card "$AUTO/home/state/$PAGE_ID.claude-settings.json" "$AUTO/home/data/$PAGE_ID/notes.md" 'Claude Lavish page-host launch'

# Rollout stays off by default and never changes the secondmate window.
jq -e 'has("autoCompactWindow") | not' "$CREW_SETTINGS" >/dev/null || fail "rollout is not default-off"
printf 'all\n' > "$AUTO/home/config/worker-compaction"
run_spawn "$AUTO/home" "$AUTO_FAKE" "$AUTO/wt" "$AUTO_ID" "$AUTO/project" --mode no-mistakes --yolo off
jq -e '.autoCompactWindow == 300000 and .hooks.SessionStart[0].matcher == "startup|resume|compact" and (.hooks.Stop | length > 0)' "$AUTO_SETTINGS" >/dev/null || fail "enabled worker lacks compact window/hook or lost Stop hook"
printf 'all\n' > "$SM/home/config/worker-compaction"
run_spawn "$SM/home" "$SM_FAKE" "$SM_HOME" "$SM_ID" "$SM_HOME" --secondmate
jq -e 'has("autoCompactWindow") | not' "$SM_SETTINGS" >/dev/null || fail "secondmate joined worker rollout"
assert_contains "$(cat "$SM_HOME/data/notes.md")" 'decision: Claude secondmate launch preserve current revision' 'relaunch overwrote saved secondmate state'

# Exercise the generated hook command itself, including quoted paths and limits.
CARD_BRIEF="$AUTO/home/data/$AUTO_ID/launch-brief.md"
[ -f "$CARD_BRIEF" ] || CARD_BRIEF="$AUTO/home/data/$AUTO_ID/brief.md"
printf '\n# Definition of done\nShip tested change.\n' >> "$CARD_BRIEF"
printf 'working: last status proof\n' > "$AUTO/home/state/$AUTO_ID.status"
printf 'decision: preserve the goal\n' > "$AUTO/home/data/$AUTO_ID/notes.md"
HOOK=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$AUTO_SETTINGS")
CARD=$(printf '{"source":"compact"}' | bash -c "$HOOK")
assert_contains "$CARD" 'Exercise the generated claude settings file.' "task and goal missing"
assert_contains "$CARD" 'Ship tested change.' "done rule missing"
assert_contains "$CARD" 'last status proof' "status missing"
assert_contains "$CARD" 'decision: preserve the goal' "notes missing"
assert_contains "$CARD" "$AUTO/home/state/$AUTO_ID.inbox" "inbox path missing"
[ -z "$(printf '{"source":"clear"}' | bash -c "$HOOK")" ] || fail "unrelated hook emitted a card"
python3 - "$AUTO/home/data/$AUTO_ID/notes.md" <<'PY'
import sys
with open(sys.argv[1], 'w') as f: f.write('é' * 15000)
PY
printf '{"source":"compact"}' | bash -c "$HOOK" > "$AUTO/card"
python3 - "$AUTO/card" <<'PY'
import sys
assert len(open(sys.argv[1]).read()) <= 10000
PY
expect_code 0 "$?" "card exceeded 10000 characters"
rm "$AUTO/home/data/$AUTO_ID/notes.md" "$AUTO/home/state/$AUTO_ID.status"
printf '{"source":"compact"}' | bash -c "$HOOK" >/dev/null || fail "missing notes/status broke hook"

# Refuse unsafe note destinations, retain saved state and support quoted paths.
SAFE_NOTES="$AUTO/home/data/$AUTO_ID/notes 'quoted'.md"
printf 'saved decision survives repeated settings generation\n' > "$SAFE_NOTES"
for _ in 1 2; do
  bash "$ROOT/bin/fm-worker-compact.sh" --settings "$AUTO/home/config" "$AUTO/home/state" "$AUTO_ID" "$CARD_BRIEF" "$CREW_SETTINGS" task "$SAFE_NOTES" > "$AUTO/quoted-settings"
done
HOOK=$(jq -r '.hooks.SessionStart[-1].hooks[0].command' "$AUTO/quoted-settings")
assert_contains "$(printf '{"source":"compact"}' | bash -c "$HOOK")" 'saved decision survives repeated settings generation' 'quoted notes path or saved state lost'
ln -s "$SAFE_NOTES" "$AUTO/unsafe-notes"
if bash "$ROOT/bin/fm-worker-compact.sh" --settings "$AUTO/home/config" "$AUTO/home/state" "$AUTO_ID" "$CARD_BRIEF" "$CREW_SETTINGS" task "$AUTO/unsafe-notes" >/dev/null 2>&1; then
  fail 'symlink planning notes accepted'
fi
assert_contains "$(cat "$SAFE_NOTES")" 'saved decision survives repeated settings generation' 'unsafe notes target was changed'
pass 'saved planning state is preserved, quoted paths replay, symlink destinations refuse'

# Stable half-cohort selection, with both cohorts represented and hooks retained.
printf 'half\n' > "$AUTO/home/config/worker-compaction"
on=0 off=0
for id in cohort-a cohort-b cohort-c cohort-d cohort-e cohort-f; do
  one=$(bash "$ROOT/bin/fm-worker-compact.sh" --settings "$AUTO/home/config" "$AUTO/home/state" "$id" "$CARD_BRIEF" "$CREW_SETTINGS")
  two=$(bash "$ROOT/bin/fm-worker-compact.sh" --settings "$AUTO/home/config" "$AUTO/home/state" "$id" "$CARD_BRIEF" "$CREW_SETTINGS")
  [ "$one" = "$two" ] || fail "half cohort changed for same task id"
  if jq -e '.autoCompactWindow == 300000' <<< "$one" >/dev/null; then on=$((on+1)); else off=$((off+1)); fi
done
[ "$on" -gt 0 ] && [ "$off" -gt 0 ] || fail "half rollout did not split cohorts"
pass "worker compaction default-off/all/half rollout, generated compact card, cap and missing files"
pass "bin/fm-spawn.sh writes valid claude settings JSON with the owned hooks for crewmates and secondmates, accepting bypass only for bypass launches"
echo "all fm-spawn-claude-settings tests passed"
