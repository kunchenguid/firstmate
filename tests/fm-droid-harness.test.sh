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
