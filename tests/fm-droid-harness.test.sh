#!/usr/bin/env bash
# Portable Droid control, process identity, and adapter-scoped busy regression.
set -u
unset FM_BUSY_REGEX
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-droid-harness)
mkdir -p "$TMP_ROOT/state"
[ "$(fm_control_harnesses | sort | uniq -d)" = '' ] || fail 'control adapter registry contains duplicates'
fm_control_harness_supported droid || fail 'Droid is not a verified control adapter'
fm_control_harness_supports_kind droid ship || fail 'Droid ship capability missing'
fm_control_harness_supports_kind droid scout || fail 'Droid scout capability missing'
if fm_control_harness_supports_kind droid secondmate; then fail 'Droid must refuse secondmates'; fi
[ "$(fm_control_interrupt_key droid)" = Escape ] || fail 'Droid interrupt key drifted'
[ "$(fm_control_interrupt_repeat droid)" = 1 ] || fail 'Droid interrupt repeat drifted'
[ "$(fm_control_exit_command droid)" = /quit ] || fail 'Droid exit command drifted'
[ "$(fm_control_harness_wiring_paths droid /unused "$TMP_ROOT/state" task)" = "$TMP_ROOT/state/task.droid-settings.json" ] \
  || fail 'Droid settings not owned by control cleanup'
pass 'Droid control supports crews/scouts, refuses secondmates, and retires task settings'
[ "$(fm_agent_process_classify_name /usr/local/bin/droid)" = agent ] || fail 'Droid process identity missing'
[ "$(fm_agent_process_classify_name /usr/local/bin/android)" = other ] || fail 'Droid substring match claims an unrelated process'
pass 'Droid process identity is anchored to the executable name'
[ -z "$(fm_busy_sources_for_harness droid)" ] || fail 'Droid must not arm a record without a semantic writer'
[ "$(fm_busy_classify cmux target droid task "$TMP_ROOT/state" 'Executing... (Press ESC to stop)')" = 'busy droid-regex' ] \
  || fail 'Droid busy footer lost through cmux classification'
[ "$(fm_busy_classify cmux target droid task "$TMP_ROOT/state" 'idle composer')" = 'idle droid-regex' ] \
  || fail 'Droid idle footer did not settle'
[ "$(fm_busy_classify tmux target claude task "$TMP_ROOT/state" 'Press ESC to stop')" = 'unknown missing' ] \
  || fail 'Droid rendered fallback leaked into Claude'
if printf '%s' 'Press ESC to stop' | fm_busy_lines_match claude; then fail 'Droid delivery signature leaked into Claude'; fi
if printf '%s' 'Press ESC to stop' | fm_busy_lines_match; then fail 'Droid delivery signature leaked into the shared fallback'; fi
printf '%s' 'Press ESC to stop' | fm_busy_lines_match droid || fail 'Droid scoped delivery signature disappeared'
spinner=' ⠸ Thinking...'
[ "$(fm_busy_classify cmux target droid task "$TMP_ROOT/state" "$spinner")" = 'busy droid-regex' ] \
  || fail 'Droid working spinner alone did not classify busy'
printf '%s' "$spinner" | fm_busy_lines_match droid || fail 'Droid delivery lost the spinner-only signal'
printf '%s' "$spinner" | LC_ALL=C fm_busy_lines_match droid || fail 'Droid spinner depends on a UTF-8 locale'
if printf '%s' "$spinner" | fm_busy_lines_match claude; then fail 'Droid spinner leaked into Claude'; fi
[ "$(fm_busy_classify tmux target claude task "$TMP_ROOT/state" "$spinner")" = 'unknown missing' ] \
  || fail 'Droid spinner fallback leaked into Claude state'
pass 'Droid independent busy signals and idle are adapter-scoped, including cmux'
fm_backend_capture() { return 1; }
[ "$(fm_busy_classify tmux target droid task "$TMP_ROOT/state")" = 'unknown capture-failed' ] \
  || fail 'Droid capture failure was promoted to idle'
[ "$(fm_busy_classify tmux target droidish task "$TMP_ROOT/state" 'Press ESC to stop')" = 'unknown missing' ] \
  || fail 'Droid busy fallback claimed an unverified prefix'
pass 'Droid capture failure remains unknown and unverified prefixes are refused'

# The live Droid footer sits directly below the box; a shell or arbitrary
# activity below the same box must still refuse delivery.
caps=$'styled=0\ncursor=0\nidentity=0'
screen=$'╭──────────╮\n│ >        │\n╰──────────╯\n[⏱ 17s, context: <1%] TMUX ⧉\nworkspace main'
[ "$(fm_composer_classify_screen "$caps" "$screen")" = empty ] || fail 'Droid timer made an empty box stale'
[ "$(LC_ALL=C fm_composer_classify_screen "$caps" "$screen")" = empty ] || fail 'Droid timer classification depends on UTF-8 locale'
[ "$(fm_composer_classify_screen "$caps" "$screen"$'\n$ typed command')" = unknown ] || fail 'Droid timer hid a newer shell composer'
screen=$'╭──────────╮\n│ >        │\n╰──────────╯\nunclaimed activity'
[ "$(fm_composer_classify_screen "$caps" "$screen")" = unknown ] || fail 'arbitrary activity was accepted as a Droid footer'
pass 'Droid elapsed-time footer preserves box delivery without hiding shell or activity'

# Droid 0.237.0 leaves the terminal cursor below its composer after Stop.
# Render that placement with a real named process in a private tmux server.
test_droid_parked_cursor() (
  command -v tmux >/dev/null 2>&1 || { echo 'skip: tmux not found for Droid composer regression'; exit 0; }
  real_tmux=$(command -v tmux)
  socket="fm-droid-composer-$$"
  lab="$TMP_ROOT/composer"
  mkdir -p "$lab/bin" "$lab/shim"
  trap '"$real_tmux" -L "$socket" kill-server >/dev/null 2>&1 || true' EXIT
  for name in droid android claude; do cp "$(command -v bash)" "$lab/bin/$name"; done
  cat > "$lab/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -L "$socket" "\$@"
SH
  chmod +x "$lab/shim/tmux"
  . "$ROOT/bin/fm-tmux-lib.sh"
  idle=$'╭──────────╮\n│ >        │\n╰──────────╯\n[⏱ 17s, context: <1%] TMUX ⧉\nworkspace main'
  for name in droid android claude; do
    printf '%s\n' "$idle" > "$lab/screen"
    "$real_tmux" -L "$socket" new-session -d -s "$name" -x 40 -y 10 \
      "$lab/bin/$name" -c 'cat "$1"; printf "\033[8;1H"; while IFS= read -r line; do :; done' _ "$lab/screen" \
      || fail 'cannot start private composer pane'
    for _ in $(seq 1 100); do
      current=$("$real_tmux" -L "$socket" display-message -p -t "$name" '#{pane_current_command}')
      cy=$("$real_tmux" -L "$socket" display-message -p -t "$name" '#{cursor_y}')
      [ "$current" != "$name" ] || [ "$cy" != 7 ] || break
      sleep 0.1
    done
    [ "$current" = "$name" ] && [ "$cy" = 7 ] || fail "fixture did not park $name below the box (command=$current cursor=$cy)"
    want=unknown
    [ "$name" != droid ] || want=empty
    verdict=$(PATH="$lab/shim:$PATH" fm_tmux_composer_state "$name")
    [ "$verdict" = "$want" ] || fail "$name parked composer classified $verdict, expected $want"
    "$real_tmux" -L "$socket" kill-session -t "$name"
  done
  # Preserve user text and refuse a newer shell composer despite Droid identity.
  for variant in typed shell activity; do
    case "$variant" in
      typed) screen=${idle/│ >        │/│ > draft  │}; want=pending ;;
      shell) screen="$idle"$'\n$ typed command'; want=unknown ;;
      activity) screen=$'╭──────────╮\n│ >        │\n╰──────────╯\nunclaimed activity'; want=unknown ;;
    esac
    printf '%s\n' "$screen" > "$lab/screen"
    "$real_tmux" -L "$socket" new-session -d -s droid -x 40 -y 10 \
      "$lab/bin/droid" -c 'cat "$1"; printf "\033[8;1H"; while IFS= read -r line; do :; done' _ "$lab/screen" \
      || fail 'cannot start private refusal pane'
    for _ in $(seq 1 100); do
      current=$("$real_tmux" -L "$socket" display-message -p -t droid '#{pane_current_command}')
      [ "$current" != droid ] || break
      sleep 0.1
    done
    [ "$current" = droid ] || fail 'refusal fixture lacks live Droid identity'
    verdict=$(PATH="$lab/shim:$PATH" fm_tmux_composer_state droid)
    [ "$verdict" = "$want" ] || fail "$variant Droid composer classified $verdict, expected $want"
    "$real_tmux" -L "$socket" kill-session -t droid
  done
  pass 'Droid parked cursor uses composer structure without relaxing other process or input guards'
)
test_droid_parked_cursor || exit 1

fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/task" droid-trust
mkdir -p "$TMP_ROOT/user/.factory"
store="$TMP_ROOT/user/.factory/settings.json"
printf '%s\n' '{"otherSetting":"preserve","trustedFolders":{"/already-trusted":{"trustedAt":"existing"}}}' > "$store"
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'linked Droid worktree trust registration failed'
physical=$(cd "$TMP_ROOT/task" && pwd -P)
jq -e --arg path "$physical" '.otherSetting == "preserve" and .trustedFolders["/already-trusted"].trustedAt == "existing" and (.trustedFolders[$path].trustedAt | type == "string") and (.trustedFolders | length == 2)' "$store" >/dev/null \
  || fail 'Droid registration lost settings or trusted more than the exact worktree'
before=$(cat "$store")
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'repeated Droid registration failed'
[ "$(cat "$store")" = "$before" ] || fail 'repeated Droid trust registration changed the store'
if HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/project" "$TMP_ROOT/project" >/dev/null 2>&1; then fail 'Droid trusted the primary checkout'; fi
if HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT" "$TMP_ROOT/project" >/dev/null 2>&1; then fail 'Droid trusted a parent directory'; fi
if HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/user" "$TMP_ROOT/project" >/dev/null 2>&1; then fail 'Droid trusted the home directory'; fi
[ "$(cat "$store")" = "$before" ] || fail 'scope refusal changed Droid settings'
jq -n --arg path "$physical" '{trustedFolders:{($path):false}}' > "$store"
before=$(cat "$store")
if HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null 2>&1; then fail 'Droid accepted an invalid existing task trust entry'; fi
[ "$(cat "$store")" = "$before" ] || fail 'Droid replaced an invalid existing trust entry'
printf '%s\n' '{"trustedFolders":[]}' > "$store"
if HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null 2>&1; then fail 'Droid accepted a malformed trust registry'; fi
[ "$(cat "$store")" = '{"trustedFolders":[]}' ] || fail 'Droid replaced malformed user settings'
printf '%s\n' 'secret-registry-value-not-json' > "$store"
before=$(cat "$store")
if out=$(HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/task" "$TMP_ROOT/project" 2>&1); then
  fail 'Droid accepted invalid settings JSON'
fi
assert_not_contains "$out" 'secret-reg' 'invalid settings error exposed settings contents'
[ "$(cat "$store")" = "$before" ] || fail 'Droid replaced invalid settings JSON'
pass 'Droid trust is exact-worktree scoped, idempotent, and preserves user settings'

# Cleanup is idempotent and preserves settings outside the task's exact paths.
printf '%s\n' '{"otherSetting":"preserve","trustedFolders":{"/already-trusted":{"trustedAt":"existing"}}}' > "$store"
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'cleanup setup failed'
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --remove "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'Droid trust cleanup failed'
jq -e --arg path "$physical" '.otherSetting == "preserve" and .trustedFolders["/already-trusted"].trustedAt == "existing" and (.trustedFolders | has($path) | not) and (.trustedFolders | length == 1)' "$store" >/dev/null || fail 'cleanup changed unrelated settings or retained task trust'
before=$(cat "$store")
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --remove "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'repeated trust cleanup failed'
[ "$(cat "$store")" = "$before" ] || fail 'repeated trust cleanup changed settings'
if HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --remove "$TMP_ROOT/project" "$TMP_ROOT/project" >/dev/null 2>&1; then fail 'cleanup accepted the primary checkout'; fi
[ "$(cat "$store")" = "$before" ] || fail 'scope refusal changed trust during cleanup'
pass 'Droid trust cleanup removes only task paths and is idempotent'

# The crew classifier remains separate from primary-session lock ownership.
if fm_harness_process_matches droid droid; then fail 'Droid acquired primary-session identity'; fi
if fm_harness_path_name /opt/droid/droid; then fail 'Droid path acquired primary-session identity'; fi
pass 'Droid crew detection does not enable primary-session lock ownership'

receipt="$TMP_ROOT/state/task.droid-trust"
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --receipt "$receipt" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'receipt registration failed'
jq -e --arg path "$physical" '.schema == "fm-droid-trust.v1" and .paths == [$path] and (.acquired | has($path))' "$receipt" >/dev/null || fail 'receipt did not record acquired exact path'
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --rollback "$receipt" >/dev/null || fail 'acquired trust rollback failed'
[ ! -e "$receipt" ] || fail 'rollback retained receipt'
jq -e --arg path "$physical" '.trustedFolders | has($path) | not' "$store" >/dev/null || fail 'rollback retained acquired trust'
# A grant predating this spawn must survive its failure.
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'existing grant setup failed'
before=$(cat "$store")
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --receipt "$receipt" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'existing grant receipt failed'
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --rollback "$receipt" >/dev/null || fail 'existing grant rollback failed'
[ "$(cat "$store")" = "$before" ] || fail 'rollback removed pre-existing trust'
# Preserve a grant another writer changed after acquisition.
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --remove "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'changed grant setup failed'
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --receipt "$receipt" "$TMP_ROOT/task" "$TMP_ROOT/project" >/dev/null || fail 'changed grant receipt failed'
jq --arg path "$physical" '.trustedFolders[$path].trustedAt = "changed-by-user"' "$store" > "$store.new"
mv "$store.new" "$store"
before=$(cat "$store")
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --rollback "$receipt" >/dev/null || fail 'changed grant rollback failed'
[ "$(cat "$store")" = "$before" ] || fail 'rollback removed a grant changed by another writer'
pass 'Droid receipts roll back only unchanged newly acquired grants'

# The successor can use a physical spelling and any harness. Its receipt must
# survive retirement of the original metadata and disappearance of the copy.
ln -s "$TMP_ROOT/task" "$TMP_ROOT/task-alias"
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --receipt "$receipt" "$TMP_ROOT/task-alias" "$TMP_ROOT/project" >/dev/null || fail 'logical alias registration failed'
printf 'worktree=%s\nharness=claude\n' "$physical" > "$TMP_ROOT/state/successor.meta"
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --retire "$receipt" "$TMP_ROOT/state" task >/dev/null || fail 'trust transfer failed'
[ ! -e "$receipt" ] && [ -f "$TMP_ROOT/state/successor.droid-trust" ] || fail 'cleanup ownership was lost during transfer'
jq -e --arg physical "$physical" --arg logical "$TMP_ROOT/task-alias" '.trustedFolders | has($physical) and has($logical)' "$store" >/dev/null || fail 'live successor lost trust'
git -C "$TMP_ROOT/project" worktree remove --force "$TMP_ROOT/task"
HOME="$TMP_ROOT/user" "$ROOT/bin/fm-droid-trust.sh" --retire "$TMP_ROOT/state/successor.droid-trust" "$TMP_ROOT/state" successor >/dev/null || fail 'vanished worktree trust retirement failed'
jq -e '.otherSetting == "preserve" and .trustedFolders == {"/already-trusted":{"trustedAt":"existing"}}' "$store" >/dev/null || fail 'final retirement retained aliases or lost other settings'
[ ! -e "$TMP_ROOT/state/successor.droid-trust" ] || fail 'final retirement retained receipt'
pass 'Droid cleanup transfers to a non-Droid successor and retires aliases after worktree removal'

# Concurrent helpers reached through different symlinks share the resolved
# store lock. Repeated registrations and removals must never lose each other.
mkdir -p "$TMP_ROOT/alias-user/.factory"
ln -s "$store" "$TMP_ROOT/alias-user/.factory/settings.json"
for i in 1 2 3 4; do
  git -C "$TMP_ROOT/project" worktree add -q "$TMP_ROOT/concurrent-$i" -b "concurrent-$i"
done
for round in 1 2 3; do
  pids=()
  for i in 1 2 3 4; do
    user="$TMP_ROOT/user"
    [ "$((i % 2))" -eq 0 ] || user="$TMP_ROOT/alias-user"
    HOME="$user" "$ROOT/bin/fm-droid-trust.sh" "$TMP_ROOT/concurrent-$i" "$TMP_ROOT/project" >/dev/null &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || fail 'concurrent registration failed'; done
  jq -e '.trustedFolders | length == 5' "$store" >/dev/null || fail 'concurrent registration lost trust'
  pids=()
  for i in 1 2 3 4; do
    user="$TMP_ROOT/user"
    [ "$((i % 2))" -eq 0 ] || user="$TMP_ROOT/alias-user"
    HOME="$user" "$ROOT/bin/fm-droid-trust.sh" --remove "$TMP_ROOT/concurrent-$i" "$TMP_ROOT/project" >/dev/null &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || fail 'concurrent removal failed'; done
  jq -e '.trustedFolders == {"/already-trusted":{"trustedAt":"existing"}}' "$store" >/dev/null || fail 'concurrent removal restored retired trust'
done
[ -L "$TMP_ROOT/alias-user/.factory/settings.json" ] || fail 'atomic write replaced the settings symlink'
pass 'Droid concurrent settings transactions serialize across symlinked stores'
