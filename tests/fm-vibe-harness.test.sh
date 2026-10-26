#!/usr/bin/env bash
# Portable Vibe worker identity, lifecycle, composer and journal regressions.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-vibe-harness)
HARNESS="$ROOT/bin/fm-harness.sh"
mkdir -p "$TMP_ROOT/names"
ln -s /bin/bash "$TMP_ROOT/names/vibe-rs"
ln -s /bin/bash "$TMP_ROOT/names/vibe-rs-helper"
# shellcheck disable=SC2016
out=$(CLAUDECODE=1 "$TMP_ROOT/names/vibe-rs" -c '"$1"; :' _ "$HARNESS")
[ "$out" = vibe ] || fail "native Vibe ancestry lost to foreign marker: $out"
# shellcheck disable=SC2016
out=$("$TMP_ROOT/names/vibe-rs-helper" -c '"$1" ancestry "$$"; :' _ "$HARNESS")
[ "$out" != 'comm vibe' ] || fail 'helper name claimed Vibe identity'
[ "$(fm_agent_process_classify_name /usr/bin/vibe-rs)" = agent ] || fail 'Vibe liveness lost'
[ "$(fm_agent_process_classify_name vibe-rs-helper)" = other ] || fail 'helper claimed as agent'
pass 'anchored Vibe identity and liveness'
[ "$(fm_control_interrupt_key vibe)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat vibe)" = 1 ] || fail 'wrong interrupt repeat'
[ -z "$(fm_control_interrupt_clear_key vibe)" ] || fail 'interrupt must preserve drafts'
[ "$(fm_control_exit_command vibe)" = /exit ] || fail 'wrong exit command'
fm_control_harness_supports_kind vibe ship || fail 'ship refused'
fm_control_harness_supports_kind vibe scout || fail 'scout refused'
! fm_control_harness_supports_kind vibe secondmate || fail 'secondmate accepted'
pass 'worker-only Vibe lifecycle'
rule=$(printf '─%.0s' $(seq 1 80))
screen() {
  printf '%s\n' "$rule accept edits · auto-approve ─" "> $1" '' '' "$rule" '/project [PID 123] 15k/800k tokens (2%)'
}
caps=$'styled=1\ncursor=0\nidentity=0'
[ "$(fm_composer_classify_screen "$caps" "$(screen '')")" = empty ] || fail 'Vibe ruled empty composer lost'
[ "$(fm_composer_classify_screen "$caps" "$(screen 'unsent draft')")" = pending ] || fail 'Vibe draft not preserved'
[ "$(fm_vibe_composer_state "$rule" )" = unknown ] || fail 'partial redraw read as empty'
[ "$(fm_vibe_screen_state "$(printf '⠋ Generating… (2s Esc/Ctrl+C to interrupt)\n'; screen '')")" = busy ] || fail 'delivery busy shape lost'
[ "$(fm_vibe_screen_state "$(screen '')")" = idle ] || fail 'idle shape lost'
pass 'Vibe ruled composer, pending draft, redraw and delivery busy shape'
vibe_busy='⠋ Generating… (2s Esc/Ctrl+C to interrupt)'
printf '%s' "$vibe_busy" | FM_BUSY_REGEX='' fm_busy_lines_match vibe || fail 'Vibe busy footer lost'
! printf '%s' "$vibe_busy" | FM_BUSY_REGEX='' fm_busy_lines_match || fail 'harness-less default claimed Vibe busy footer'
pass 'Vibe busy footer stays in its own delivery arm'
python3 "$ROOT/tests/fm-vibe-state.test.py" || fail 'Vibe session-state regression failed'
pass 'Vibe semantic session state and journal updates'
# Herdr does not yet catalog Vibe: exact foreground evidence fills that gap,
# but a failed process read cannot be taken as proof that no agent remains.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
STATE="$TMP_ROOT/herdr-state"
mkdir -p "$STATE"
printf 'backend=herdr\nwindow=lab:w1:p1\nharness=vibe\n' > "$STATE/vibe.meta"
fm_backend_herdr_pane_presence_state() { printf present; }
probe_mode=vibe
probe_shell_pid=$$
probe_calls="$TMP_ROOT/process-calls"
fm_backend_herdr_cli() {
  if [ "$2" = agent ]; then
    printf '%s' '{"error":{"code":"agent_not_found"}}'
  else
    printf 'process-info\n' >> "$probe_calls"
    case "$probe_mode" in
      vibe|foreign)
        local pane=w1:p1
        [ "$probe_mode" != foreign ] || pane=w2:p1
        jq -nc --arg pane "$pane" --argjson pid "$probe_shell_pid" '{result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:$pid,foreground_processes:[{pid:999999,name:"vibe-rs",argv0:"vibe-rs"}]}}}' ;;
      malformed) printf '%s' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","foreground_processes":[]}}}' ;;
      shell|empty)
        jq -nc --arg mode "$probe_mode" --argjson pid "$probe_shell_pid" '{result:{type:"pane_process_info",process_info:{pane_id:"w1:p1",shell_pid:$pid,foreground_processes:(if $mode == "empty" then [] else [{pid:$pid,name:"bash",argv0:"bash"}] end)}}}' ;;
      *) return 1 ;;
    esac
  fi
}
[ "$(fm_backend_herdr_pane_agent_state lab w1:p1)" = live ] || fail 'Herdr foreground Vibe lost'
for probe_mode in shell empty; do
  [ "$(fm_backend_herdr_pane_agent_state lab w1:p1)" = no-agent ] || fail 'shell or empty handoff claimed as Vibe'
done
# An empty foreground cannot hide a verified descendant outside its group.
mkfifo "$TMP_ROOT/vibe-input"
exec 9<> "$TMP_ROOT/vibe-input"
"$TMP_ROOT/names/vibe-rs" -c 'while IFS= read -r line; do :; done' <&9 &
probe_child=$!
probe_mode=empty
[ "$(fm_backend_herdr_pane_agent_state lab w1:p1)" = live ] || fail 'empty handoff hid live Vibe descendant'
kill "$probe_child" 2>/dev/null || true
wait "$probe_child" 2>/dev/null || true
exec 9>&-
for probe_mode in foreign unavailable malformed; do
  [ "$(fm_backend_herdr_pane_agent_state lab w1:p1)" = unknown ] || fail 'unreadable or foreign process evidence claimed absence'
done
# Unregistered non-Vibe and unrecorded panes keep their original semantics
# and must not consume a process-info response or inspect another pane.
printf 'backend=herdr\nwindow=lab:w1:p1\nharness=pi\n' > "$STATE/vibe.meta"
: > "$probe_calls"
[ "$(fm_backend_herdr_pane_agent_state lab w1:p1)" = no-agent ] || fail 'non-Vibe agent_not_found changed'
[ ! -s "$probe_calls" ] || fail 'non-Vibe fallback read process-info'
[ "$(fm_backend_herdr_pane_agent_state lab w2:p1)" = no-agent ] || fail 'unrecorded pane agent_not_found changed'
[ ! -s "$probe_calls" ] || fail 'unrecorded fallback read process-info'
pass 'recorded Vibe liveness, empty handoff, uncertain reads and unchanged shared Herdr semantics'
case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
# The model-free fixture needs only the vendor version surface.
printf '#!/bin/sh\nprintf "vibe 3.0.2\\n"\n' > "$fakebin/vibe"
chmod +x "$fakebin/vibe"
home="$case_dir/home"
proj="$case_dir/source"
wt="$case_dir/worker"
fm_test_spawn_home "$home" vibe
fm_git_init_commit "$proj"
fm_git_add_origin "$proj" "$case_dir/origin.git"
fm_git_init_commit "$wt"
fm_test_spawn_brief "$home" vibe-default
out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" vibe-default "$proj" --scout --harness vibe --backend tmux) || fail "default spawn refused: $out"
launch=$(cat "$case_dir/launch")
assert_contains "$launch" '--trust --auto-approve --' 'native trust/approval missing'
assert_contains "$launch" 'encode launch-brief' 'typed launch brief missing'
assert_contains "$launch" 'VIBE_SESSION_LOGGING__SAVE_DIR=' 'generation-local journal missing'
case "$launch" in *--worktree*) fail 'Vibe-owned worktree requested' ;; esac
for kind in effort secondmate version; do
  id="vibe-$kind"
  fm_test_spawn_brief "$home" "$id"
  case "$kind" in
    effort) args=(--scout --effort low) ;;
    secondmate) args=(--secondmate) ;;
    version) printf '#!/bin/sh\nprintf "vibe 9.0.0\\n"\n' > "$fakebin/vibe"; args=(--scout) ;;
  esac
  if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --harness vibe --backend tmux "${args[@]}"); then fail "$kind accepted"; fi
  case "$kind" in
    effort) assert_contains "$out" 'effort pinning is unsupported' 'wrong effort refusal' ;;
    secondmate) assert_contains "$out" 'crewmate/scout adapter only' 'wrong secondmate refusal' ;;
    version) assert_contains "$out" 'requires live adapter verification' 'wrong version refusal' ;;
  esac
done
pass 'Vibe launch envelope, journal generation and unsupported effort/secondmate/version refusals'
