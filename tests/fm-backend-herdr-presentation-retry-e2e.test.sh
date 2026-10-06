#!/usr/bin/env bash
# Drive a failed projected spawn and retry through a guarded named Herdr lab.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/git-config-helpers.sh
. "$ROOT/tests/git-config-helpers.sh"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1
command -v herdr >/dev/null || { echo 'skip: herdr unavailable'; exit 0; }
command -v jq >/dev/null || { echo 'skip: jq unavailable'; exit 0; }

ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$ROOT/.herdr-retry.XXXXXX") || exit 1
FM_HOME=$TMP_ROOT/home
FAKEBIN=$TMP_ROOT/bin
PANE_BIN=$TMP_ROOT/pane-bin
mkdir -p "$FAKEBIN" "$PANE_BIN"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-herdr-presentation-retry-20261002) || exit 1
LAB_READY=0
HOME_READY=0
LAB_TMUX_DIR=
cleanup() {
  local result=$? cleanup_result=0
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" tmux kill-server >/dev/null 2>&1 || true
  fi
  if [ "$HOME_READY" -eq 1 ]; then
    "$LAB_HOME_HELPER" teardown "$FM_HOME" || cleanup_result=1
  fi
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_result=1
  fi
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  if [ "$cleanup_result" -ne 0 ]; then
    echo 'not ok - guarded lab teardown failed' >&2
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT

"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null || exit 1
HOME_READY=1
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME") || exit 1

lab() { PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# Every adapter call is redirected through the guarded lab command, including
# its session-independent version read. A server launch is never expected.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
count=${#args[@]}
if [ "$count" -ge 2 ] && [ "${args[count-2]}" = --session ] &&
  [ "${args[count-1]}" = "$HERDR_LAB_SESSION" ]; then
  unset 'args[count-1]' 'args[count-2]'
fi
set -- "${args[@]}"
case "${1:-} ${2:-}" in
  'server '*|'session stop'|'session delete') echo 'unexpected lifecycle call' >&2; exit 1 ;;
esac
PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = get ] || { echo "unexpected treehouse operation: $*" >&2; exit 1; }
cd "$FIXTURE_WORKER" || exit 1
exec bash --noprofile --norc -i
SH
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FIXTURE_WORKER" ] &&
  [ "${3:-}" = fetch ] && [ -f "$FAIL_FETCH" ]; then
  rm -f "$FAIL_FETCH"
  echo 'controlled fetch failure' >&2
  exit 1
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse" "$FAKEBIN/git"
cp "$FAKEBIN/treehouse" "$PANE_BIN/treehouse"

PROJECT=$TMP_ROOT/project
REMOTE=$TMP_ROOT/remote.git
FIXTURE_WORKER=$TMP_ROOT/worker
FAIL_FETCH=$TMP_ROOT/fail-fetch
REAL_GIT=$(command -v git)
export FIXTURE_WORKER FAIL_FETCH REAL_GIT ORIGINAL_PATH HERDR_LAB_HELPER HERDR_LAB_SESSION
git init -q -b main "$PROJECT"
printf 'scratch\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$PROJECT" "$REMOTE"
git clone -q "$REMOTE" "$FIXTURE_WORKER"
printf 'on\n' > "$FM_HOME/config/herdr-presentation-spaces"
PATH="$PANE_BIN:$ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || exit 1
LAB_READY=1
export PATH="$FAKEBIN:$PATH" FM_HOME HERDR_SESSION="$HERDR_LAB_SESSION"
PARENT_OUT=$(lab workspace create --cwd "$PROJECT" --label firstmate --no-focus) ||
  fail 'could not create the owning firstmate workspace'
PARENT_PANE=$(printf '%s' "$PARENT_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PARENT_PANE" ] || fail 'parent workspace has no probe pane'
lab pane send-text "$PARENT_PANE" "command -v treehouse > '$TMP_ROOT/pane-treehouse-path'" >/dev/null ||
  fail 'could not submit the Treehouse path probe'
lab pane send-keys "$PARENT_PANE" enter >/dev/null ||
  fail 'could not run the Treehouse path probe'
for _ in $(seq 1 30); do
  [ -f "$TMP_ROOT/pane-treehouse-path" ] && break
  sleep 0.2
done
[ -f "$TMP_ROOT/pane-treehouse-path" ] || fail 'lab pane did not run the Treehouse path probe'
[ "$(cat "$TMP_ROOT/pane-treehouse-path")" = "$PANE_BIN/treehouse" ] ||
  fail "lab pane resolves a non-fixture Treehouse: $(cat "$TMP_ROOT/pane-treehouse-path")"
echo 'ok - lab pane resolves the fake Treehouse command before any spawn'

write_brief() {
  mkdir -p "$FM_HOME/data/$1"
  printf '# Task\n## Captain\047s intent\nVerify a Herdr workspace for %s.\n\n## Firstmate spec\nExercise the isolated Herdr fixture.\n' "$1" > "$FM_HOME/data/$1/brief.md"
}
spawn() {
  FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJECT" "sh -c 'while :; do sleep 60; done'" \
      --mode no-mistakes --yolo off --backend herdr
}
workspace_of() {
  sed -n 's/^herdr_workspace_id=//p' "$FM_HOME/state/$1.meta"
}
label_of() {
  lab workspace get "$1" | jq -r '.result.workspace.label // empty'
}

write_brief clean
spawn clean > "$TMP_ROOT/clean.out" 2> "$TMP_ROOT/clean.err" || fail "clean spawn: $(cat "$TMP_ROOT/clean.err")"
CLEAN_SPACE=$(workspace_of clean)
case "$(label_of "$CLEAN_SPACE")" in
  *' · p:'*) : ;;
  *) fail 'clean spawn did not create a presentation workspace' ;;
esac
echo 'ok - clean launch created a presentation workspace'

write_brief retry
: > "$FAIL_FETCH"
if spawn retry > "$TMP_ROOT/failed.out" 2> "$TMP_ROOT/failed.err"; then
  fail 'controlled fetch failure did not stop the first spawn'
fi
grep -F 'could not fetch origin for pooled worktree' "$TMP_ROOT/failed.err" >/dev/null ||
  fail "first spawn failed for another reason: $(cat "$TMP_ROOT/failed.err")"
JOURNAL=$FM_HOME/state/retry.herdr-presentation
[ -f "$JOURNAL" ] || fail 'failed spawn did not leave its presentation journal'
[ "$(sed -n 's/^version=//p' "$JOURNAL")" = 2 ] || fail 'failed spawn did not bind its workspace'
[ ! -e "$FM_HOME/state/retry.meta" ] || fail 'failed spawn published metadata'
OLD_SPACE=$(sed -n 's/^workspace_id=//p' "$JOURNAL")
if lab workspace get "$OLD_SPACE" >/dev/null 2>&1; then
  fail 'failed spawn left its bound workspace live'
fi
echo 'ok - failed fetch left a bound journal and removed the exact workspace'

spawn retry > "$TMP_ROOT/retry.out" 2> "$TMP_ROOT/retry.err" || fail "retry spawn: $(cat "$TMP_ROOT/retry.err")"
RETRY_SPACE=$(workspace_of retry)
case "$(label_of "$RETRY_SPACE")" in
  *' · p:'*) echo 'ok - retry created a presentation workspace' ;;
  *) fail "retry landed flat: $(cat "$TMP_ROOT/retry.err")" ;;
esac
[ "$RETRY_SPACE" != "$CLEAN_SPACE" ] || fail 'retry reused the clean task workspace'

write_brief collision
: > "$FAIL_FETCH"
if spawn collision > "$TMP_ROOT/collision-first.out" 2> "$TMP_ROOT/collision-first.err"; then
  fail 'collision first spawn did not fail its fetch'
fi
COLLISION_JOURNAL=$FM_HOME/state/collision.herdr-presentation
[ -f "$COLLISION_JOURNAL" ] || fail 'collision spawn left no journal'
COLLISION_TOKEN=$(sed -n 's/^projection_id=//p' "$COLLISION_JOURNAL")
FOREIGN_LABEL="foreign collision · p:$COLLISION_TOKEN"
FOREIGN_OUT=$(lab workspace create --cwd "$PROJECT" --label "$FOREIGN_LABEL" --no-focus) ||
  fail 'could not create unverified collision workspace'
FOREIGN_SPACE=$(printf '%s' "$FOREIGN_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$FOREIGN_SPACE" ] || fail 'unverified collision workspace has no id'
FOREIGN_TABS_BEFORE=$(lab tab list --workspace "$FOREIGN_SPACE" | jq -c '.result.tabs')
spawn collision > "$TMP_ROOT/collision-retry.out" 2> "$TMP_ROOT/collision-retry.err" ||
  fail "collision retry failed: $(cat "$TMP_ROOT/collision-retry.err")"
[ "$(label_of "$(workspace_of collision)")" = firstmate ] ||
  fail 'unverified matching token did not force flat fallback'
[ "$(label_of "$FOREIGN_SPACE")" = "$FOREIGN_LABEL" ] ||
  fail 'unverified matching workspace was renamed or removed'
[ "$(lab tab list --workspace "$FOREIGN_SPACE" | jq -c '.result.tabs')" = "$FOREIGN_TABS_BEFORE" ] ||
  fail 'unverified matching workspace tabs changed'
echo 'ok - unverified token match stayed untouched and forced flat fallback'

write_brief renamed
: > "$FAIL_FETCH"
if spawn renamed > "$TMP_ROOT/renamed-first.out" 2> "$TMP_ROOT/renamed-first.err"; then
  fail 'renamed first spawn did not fail its fetch'
fi
RENAMED_JOURNAL=$FM_HOME/state/renamed.herdr-presentation
[ -f "$RENAMED_JOURNAL" ] || fail 'renamed spawn left no journal'
RENAMED_LABEL='renamed former task space'
RENAMED_OUT=$(lab workspace create --cwd "$PROJECT" --label "$RENAMED_LABEL" --no-focus) ||
  fail 'could not create renamed bound-workspace fixture'
RENAMED_SPACE=$(printf '%s' "$RENAMED_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$RENAMED_SPACE" ] || fail 'renamed bound-workspace fixture has no id'
sed "s/^workspace_id=.*/workspace_id=$RENAMED_SPACE/" "$RENAMED_JOURNAL" > "$RENAMED_JOURNAL.next"
mv "$RENAMED_JOURNAL.next" "$RENAMED_JOURNAL"
RENAMED_TABS_BEFORE=$(lab tab list --workspace "$RENAMED_SPACE" | jq -c '.result.tabs')
spawn renamed > "$TMP_ROOT/renamed-retry.out" 2> "$TMP_ROOT/renamed-retry.err" ||
  fail "renamed retry failed: $(cat "$TMP_ROOT/renamed-retry.err")"
[ "$(label_of "$(workspace_of renamed)")" = firstmate ] ||
  fail 'renamed bound workspace did not force flat fallback'
[ "$(label_of "$RENAMED_SPACE")" = "$RENAMED_LABEL" ] ||
  fail 'renamed bound workspace was renamed or removed'
[ "$(lab tab list --workspace "$RENAMED_SPACE" | jq -c '.result.tabs')" = "$RENAMED_TABS_BEFORE" ] ||
  fail 'renamed bound workspace tabs changed'
echo 'ok - renamed bound workspace stayed untouched and forced flat fallback'
