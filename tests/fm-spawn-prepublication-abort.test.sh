#!/usr/bin/env bash
# Behavior tests for the two aborts that sit between endpoint creation and task-record
# publication in bin/fm-spawn.sh: a failed GOTMPDIR delivery, and a TRACEPARENT delivery
# that could not clear the input it typed.
#
# Both happen after the backend has already created a pane/surface and before
# state/<id>.meta exists, so the endpoint they leave behind is reachable through nothing
# at all: no teardown, no crew-state reconciliation, and no recovery sweep can name a
# window that no record points at. They must therefore end the same way a failed
# publication does - discard the endpoint and confirm it is gone, or say exactly which
# endpoint survived and that nothing recorded it.
#
# Every case drives the real bin/fm-spawn.sh against a fake backend CLI that models
# endpoint PRESENCE, because that is what the spawn re-reads to decide whether its
# endpoint is gone (fm_backend_endpoint_confirmed_gone). FM_FAKE_KILL_NOOP makes the
# close return success while the endpoint survives - the real shape of every adapter's
# best-effort kill - so the stranded case is observed rather than assumed.
#
# Coverage is per backend, not per code path, because each backend answers the discard
# with its own kill and its own confirmed-absence primitive: tmux windows, zellij tabs,
# cmux workspaces, and herdr panes. Orca is deliberately absent: its terminal and
# worktree are unwound by the EXIT trap, whose cleanup flags are still set at both of
# these aborts, and discard_unpublished_endpoint returns early for it - as it also does
# for a herdr spawn whose projection the trap owns, which is why the herdr case here is
# the flat, non-projected layout. The uncleared-input refusal is exercised only where an adapter
# can actually produce it: fm_backend_zellij_send_text_line and
# fm_backend_cmux_send_text_line are the two that return 2 after a failed Enter whose
# C-c recovery also failed; tmux's and herdr's send_text_line have no such status, so
# for them a failed TRACEPARENT delivery is the ordinary non-fatal omission covered in
# tests/fm-trace-context-spawn.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-prepublication-abort)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the zellij and cmux adapters)"; exit 0; }

# --- fake tmux ---------------------------------------------------------------
#
# Windows live under FM_FAKE_LIVE_DIR and are listed by `list-windows`, the inventory
# the tmux adapter's confirmed-absence check reads; a killed window moves to
# FM_FAKE_GONE_DIR so the `#{pane_id}` probe fails for it exactly as real tmux answers
# for a window that no longer exists.
write_fake_tmux() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
set -u
fake_target_window() {
  local arg prev= win=
  for arg in "$@"; do
    [ "$prev" = "-t" ] && win=$arg
    prev=$arg
  done
  win=${win##*:}
  printf '%s' "${win#=}"
}
fake_window_name() {
  local arg prev= name=
  for arg in "$@"; do
    [ "$prev" = "-n" ] && name=$arg
    prev=$arg
  done
  printf '%s' "$name"
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*)
    win=$(fake_target_window "$@")
    if [ -n "${FM_FAKE_GONE_DIR:-}" ] && [ -n "$win" ] && [ -e "$FM_FAKE_GONE_DIR/$win" ]; then
      echo "can't find window: $win" >&2
      exit 1
    fi
    printf '%%1\n'
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_LIVE_DIR:-}" ] || ls "$FM_FAKE_LIVE_DIR" 2>/dev/null
    exit 0
    ;;
  new-window)
    name=$(fake_window_name "$@")
    if [ -n "${FM_FAKE_LIVE_DIR:-}" ] && [ -n "$name" ]; then
      : > "$FM_FAKE_LIVE_DIR/$name"
    fi
    exit 0
    ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    if [ "${FM_FAKE_KILL_NOOP:-0}" != 1 ]; then
      win=$(fake_target_window "$@")
      if [ -n "$win" ]; then
        [ -z "${FM_FAKE_GONE_DIR:-}" ] || : > "$FM_FAKE_GONE_DIR/$win"
        [ -z "${FM_FAKE_LIVE_DIR:-}" ] || rm -f "$FM_FAKE_LIVE_DIR/$win"
      fi
    fi
    exit 0
    ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in
        "export GOTMPDIR="*) [ "${FM_FAKE_GOTMPDIR_SEND_FAIL:-0}" != 1 ] || exit 1 ;;
      esac
    done
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

# --- fake zellij -------------------------------------------------------------
#
# Tabs and terminal panes live as files under FM_FAKE_RUNTIME so `action list-panes
# --json` - the read fm_backend_zellij_endpoint_confirmed_gone demands a definitive
# answer from - reflects what close-tab-by-id actually did. The pasted text of the last
# send is remembered so the Enter that submits it can be failed per payload: that is the
# only way to reproduce the adapter's status 2, which is returned by the Enter/C-c pair
# rather than by the paste itself.
write_fake_zellij() {  # <fakebin>
  cat > "$1/zellij" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_RUNTIME:?}"
mkdir -p "$S/tabs" "$S/panes"

arg_value() {  # <flag> <args...>
  local want=$1 prev= arg
  shift
  for arg in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s' "$arg"; return 0; }
    prev=$arg
  done
  return 1
}

if [ "${1:-}" = --version ]; then printf 'zellij 0.44.0\n'; exit 0; fi
if [ "${1:-}" = list-sessions ]; then
  [ ! -s "$S/session" ] || cat "$S/session"
  exit 0
fi
if [ "${1:-}" = attach ]; then printf '%s\n' "${3:-}" > "$S/session"; exit 0; fi
if [ "${1:-}" = --session ]; then shift 2; fi
[ "${1:-}" = action ] || exit 0
shift
sub=${1:-}
shift || true

case "$sub" in
  list-tabs)
    printf '['
    first=1
    for f in "$S"/tabs/*; do
      [ -e "$f" ] || continue
      [ "$first" = 1 ] || printf ','
      printf '{"tab_id":%s,"name":"%s","active":false}' "${f##*/}" "$(cat "$f")"
      first=0
    done
    printf ']\n'
    exit 0
    ;;
  new-tab)
    name=$(arg_value --name "$@") || name=untitled
    n=$(( $(cat "$S/next" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$S/next"
    printf '%s' "$name" > "$S/tabs/$n"
    printf '%s' "$n" > "$S/panes/$n"
    printf '%s\n' "$n"
    exit 0
    ;;
  list-panes)
    printf '['
    first=1
    for f in "$S"/panes/*; do
      [ -e "$f" ] || continue
      [ "$first" = 1 ] || printf ','
      printf '{"id":%s,"tab_id":%s,"is_plugin":false}' "${f##*/}" "$(cat "$f")"
      first=0
    done
    printf ']\n'
    exit 0
    ;;
  paste)
    text=${*: -1}
    printf '%s' "$text" > "$S/last-paste"
    case "$text" in
      "export GOTMPDIR="*) [ "${FM_FAKE_GOTMPDIR_SEND_FAIL:-0}" != 1 ] || exit 1 ;;
    esac
    exit 0
    ;;
  send-keys)
    if [ "${FM_FAKE_TRACEPARENT_SEND_UNSAFE:-0}" = 1 ]; then
      case "$(cat "$S/last-paste" 2>/dev/null || true)" in
        "export TRACEPARENT="*) exit 1 ;;
      esac
    fi
    exit 0
    ;;
  dump-screen)
    printf '__FM_ZELLIJ_CWD_BEGIN__\n%s\n__FM_ZELLIJ_CWD_END__\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  close-tab-by-id|close-pane)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s %s\n' "$sub" "$*" >> "$FM_FAKE_KILL_LOG"
    if [ "${FM_FAKE_KILL_NOOP:-0}" != 1 ]; then
      if [ "$sub" = close-tab-by-id ]; then
        tab=${1:-}
        rm -f "$S/tabs/$tab"
        for f in "$S"/panes/*; do
          [ -e "$f" ] || continue
          [ "$(cat "$f")" = "$tab" ] && rm -f "$f"
        done
      else
        pane=$(arg_value --pane-id "$@") || pane=
        [ -z "$pane" ] || rm -f "$S/panes/$pane"
      fi
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$1/zellij"
}

# --- fake cmux ---------------------------------------------------------------
#
# One window holding every workspace, which is what fm_backend_cmux_workspace_presence_state
# walks: it asks list-windows for the inventory and then each window for its own scoped
# `workspace list`, and calls the endpoint gone only when every window answered and none
# held the workspace. A second, untitled workspace is seeded at setup so the task's
# workspace is never the last one in its window, keeping close-workspace on the plain
# path rather than the sibling-creation branch.
write_fake_cmux() {  # <fakebin>
  cat > "$1/cmux" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_RUNTIME:?}"
mkdir -p "$S/ws"

arg_value() {  # <flag> <args...>
  local want=$1 prev= arg
  shift
  for arg in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s' "$arg"; return 0; }
    prev=$arg
  done
  return 1
}

sub=${1:-}
shift || true
case "$sub" in
  version) printf 'cmux 0.64.17 (97) [abcdef1]\n'; exit 0 ;;
  ping) printf 'PONG\n'; exit 0 ;;
  list-windows)
    printf '[{"id":"win-1","workspace_count":%s}]\n' "$(find "$S/ws" -type f -name 'ws-*' 2>/dev/null | wc -l | tr -d ' ')"
    exit 0
    ;;
  workspace)
    [ "${1:-}" = list ] || exit 0
    printf '{"workspaces":['
    first=1
    for f in "$S"/ws/ws-*; do
      [ -e "$f" ] || continue
      [ "$first" = 1 ] || printf ','
      printf '{"id":"%s","title":"%s"}' "${f##*/}" "$(cat "$f")"
      first=0
    done
    printf ']}\n'
    exit 0
    ;;
  new-workspace)
    name=$(arg_value --name "$@") || name=untitled
    n=$(( $(cat "$S/next" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$S/next"
    printf '%s' "$name" > "$S/ws/ws-$n"
    exit 0
    ;;
  list-panes)
    wsid=$(arg_value --workspace "$@") || wsid=
    if [ -n "$wsid" ] && [ -e "$S/ws/$wsid" ]; then
      printf '{"panes":[{"selected_surface_id":"sf-%s","surface_ids":["sf-%s"]}]}\n' "${wsid#ws-}" "${wsid#ws-}"
    else
      printf '{"panes":[]}\n'
    fi
    exit 0
    ;;
  send)
    text=${*: -1}
    printf '%s' "$text" > "$S/last-send"
    case "$text" in
      "export GOTMPDIR="*) [ "${FM_FAKE_GOTMPDIR_SEND_FAIL:-0}" != 1 ] || exit 1 ;;
    esac
    exit 0
    ;;
  send-key)
    if [ "${FM_FAKE_TRACEPARENT_SEND_UNSAFE:-0}" = 1 ]; then
      case "$(cat "$S/last-send" 2>/dev/null || true)" in
        "export TRACEPARENT="*) exit 1 ;;
      esac
    fi
    exit 0
    ;;
  read-screen)
    jq -n --arg t "__FM_CMUX_CWD_BEGIN__
${FM_FAKE_PANE_PATH:-}
__FM_CMUX_CWD_END__" '{text:$t}'
    exit 0
    ;;
  close-workspace)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf 'close-workspace %s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    if [ "${FM_FAKE_KILL_NOOP:-0}" != 1 ]; then
      wsid=$(arg_value --workspace "$@") || wsid=
      [ -z "$wsid" ] || rm -f "$S/ws/$wsid"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$1/cmux"
}

# --- fake herdr --------------------------------------------------------------
#
# A stateful stub in the shape of tests/fm-backend-herdr.test.sh's make_herdr_statefake,
# extended with the reads a whole spawn needs: `pane get` (the pane's own
# foreground_cwd is what fm-spawn.sh's worktree-discovery poll reads, and its structured
# pane_not_found is the only proof fm_backend_herdr_endpoint_confirmed_gone accepts),
# `pane run` (herdr's atomic send_text_line), and `session list --json` (the socket the
# task-kill presentation lock is keyed on). Only closes of a task tab are logged, so the
# workspace's seeded default-tab prune cannot be mistaken for the discard under test.
#
# herdr is covered here for the GOTMPDIR abort only: fm_backend_herdr_send_text_line is
# a single `pane run`, so it has no uncleared-input status to return, and a failed
# TRACEPARENT delivery there is the ordinary non-fatal omission instead.
write_fake_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_FAKE_RUNTIME:?}"
mkdir -p "$S"
STATE="$S/state.json"
[ -f "$STATE" ] || printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$STATE"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
arg_value() {  # <flag> <args...>
  local want=$1 prev= arg
  shift
  for arg in "$@"; do
    [ "$prev" = "$want" ] && { printf '%s' "$arg"; return 0; }
    prev=$arg
  done
  return 1
}
ws=$(arg_value --workspace "$@" || true)
label=$(arg_value --label "$@" || true)

case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true,"protocol":14,"version":"0.7.1"}}\n'
    ;;
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s/sock"}]}\n' \
      "${HERDR_SESSION:-default}" "$S"
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next')
    jq_state --arg wsid "w$n" --arg wlabel "$label" \
      --arg tabid "w$n:t$((n + 1))" --arg paneid "w$n:p$((n + 1))" \
      '.workspaces += [{workspace_id:$wsid,label:$wlabel}]
       | .tabs += [{tab_id:$tabid,label:"1",workspace_id:$wsid,pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"w%s","label":"%s"},"tab":{"tab_id":"w%s:t%s"},"root_pane":{"pane_id":"w%s:p%s"}}}\n' \
      "$n" "$label" "$n" "$((n + 1))" "$n" "$((n + 1))"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next')
    jq_state --arg w "$ws" --arg l "$label" --arg tabid "$ws:t$n" --arg paneid "$ws:p$n" \
      '.tabs += [{tab_id:$tabid,label:$l,workspace_id:$w,pane_id:$paneid}] | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s:t%s"},"root_pane":{"pane_id":"%s:p%s"}}}\n' "$ws" "$n" "$ws" "$n"
    ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id,tab_id:.tab_id}]}}'
    ;;
  "pane get")
    row=$(jq_state -r --arg p "${3:-}" '.tabs[]|select(.pane_id==$p)|@json' 2>/dev/null)
    if [ -z "$row" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "${3:-}"
    else
      printf '%s' "$row" | jq --arg p "${3:-}" --arg cwd "${FM_FAKE_PANE_PATH:-}" \
        '{result:{pane:{pane_id:$p,tab_id:.tab_id,workspace_id:.workspace_id,cwd:$cwd,foreground_cwd:$cwd}}}'
    fi
    ;;
  "pane run")
    text=${4:-}
    printf '%s' "$text" > "$S/last-run"
    case "$text" in
      "export GOTMPDIR="*) [ "${FM_FAKE_GOTMPDIR_SEND_FAIL:-0}" != 1 ] || exit 1 ;;
    esac
    ;;
  "pane close")
    pane=${3:-}
    closed_label=$(jq_state -r --arg p "$pane" '.tabs[]|select(.pane_id==$p)|.label' 2>/dev/null)
    case "$closed_label" in
      fm-*) [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf 'pane close %s\n' "$pane" >> "$FM_FAKE_KILL_LOG" ;;
    esac
    if [ "${FM_FAKE_KILL_NOOP:-0}" != 1 ]; then
      jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    fi
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found","message":"no agent registered"}}\n'
    ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

# make_abort_case <backend> <name> <id>: a home, a real project with a real worktree,
# and the fake toolchain that backend's spawn drives. Trace context is frozen on for
# the home session so the TRACEPARENT delivery the second abort needs actually happens.
make_abort_case() {  # <backend> <name> <id>
  local backend=$1 name=$2 id=$3 case_dir home proj wt fakebin runtime
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  runtime="$case_dir/runtime"
  fakebin=$(fm_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/gone" "$case_dir/live" "$runtime"
  printf 'codex\n' > "$home/config/crew-harness"
  : > "$home/config/trace-context"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s on\n' "$$" > "$home/state/.trace-context-effective"
  fm_fake_exit0 "$fakebin" treehouse
  case "$backend" in
    tmux) write_fake_tmux "$fakebin" ;;
    zellij)
      write_fake_zellij "$fakebin"
      printf 'firstmate\n' > "$runtime/session"
      ;;
    cmux)
      write_fake_cmux "$fakebin"
      mkdir -p "$runtime/ws"
      printf 'scratch\n' > "$runtime/ws/ws-0"
      ;;
    herdr)
      write_fake_herdr "$fakebin"
      printf 'off\n' > "$home/config/herdr-presentation-spaces"
      ;;
  esac
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$case_dir/kill-log|$case_dir/gone|$case_dir/live|$runtime"
}

read_abort_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR KILL_LOG GONE_DIR LIVE_DIR RUNTIME_DIR <<EOF
$1
EOF
}

run_abort_spawn() {  # <backend> <id>
  local backend=$1 id=$2
  # HERDR_ENV/HERDR_PANE_ID are unset so a runner that happens to sit in a real herdr
  # pane cannot hand the spawn a cross-session parent identity, and HERDR_SESSION names
  # a per-run session so no invocation could ever address a shared "default" one.
  env -u FM_TRACE_CONTEXT -u TMUX -u FM_BACKEND -u HERDR_ENV -u HERDR_PANE_ID \
    HERDR_SESSION="fm-preabort-$$" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_KILL_LOG="$KILL_LOG" \
    FM_FAKE_GONE_DIR="$GONE_DIR" FM_FAKE_LIVE_DIR="$LIVE_DIR" \
    FM_FAKE_RUNTIME="$RUNTIME_DIR" \
    FM_FAKE_KILL_NOOP="${FM_FAKE_KILL_NOOP:-0}" \
    FM_FAKE_GOTMPDIR_SEND_FAIL="${FM_FAKE_GOTMPDIR_SEND_FAIL:-0}" \
    FM_FAKE_TRACEPARENT_SEND_UNSAFE="${FM_FAKE_TRACEPARENT_SEND_UNSAFE:-0}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --backend "$backend" 2>&1
}

# assert_discarded_endpoint <backend> <id> <output>: the abort closed the endpoint it
# created, confirmed the close from a read that answered, published nothing, and still
# told the operator that no record exists for this task.
assert_discarded_endpoint() {  # <backend> <id> <output>
  local backend=$1 id=$2 out=$3
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "$backend: a task record was published by an aborted spawn: $(cat "$HOME_DIR/state/$id.meta")"
  [ -s "$KILL_LOG" ] \
    || fail "$backend: the aborted spawn left its endpoint behind without even attempting a close: $out"
  assert_contains "$out" "task metadata could not be published" \
    "$backend: the aborted spawn did not report that nothing was recorded"
  assert_contains "$out" "no task record was written for $id" \
    "$backend: the aborted spawn did not state that no task record exists"
  case "$out" in
    *"was not confirmed gone"*)
      fail "$backend: a close that demonstrably worked was reported as a stranded endpoint: $out" ;;
  esac
}

# assert_stranded_endpoint <backend> <id> <output>: the close returned success while the
# endpoint survived - the shape every adapter's best-effort kill can produce - so the
# abort must name the surviving endpoint instead of implying a clean unwind.
assert_stranded_endpoint() {  # <backend> <id> <output>
  local backend=$1 id=$2 out=$3
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "$backend: a task record was published by an aborted spawn: $(cat "$HOME_DIR/state/$id.meta")"
  assert_contains "$out" "was not confirmed gone" \
    "$backend: a surviving endpoint was not reported after a success-shaped close: $out"
  assert_contains "$out" "no task record names it" \
    "$backend: the stranded-endpoint warning did not say that nothing records this endpoint"
  assert_contains "$out" "$id" "$backend: the stranded-endpoint warning did not name the task"
}

# --- the GOTMPDIR abort, on every backend that can strand an endpoint ---------

test_gotmpdir_failure_discards_the_endpoint() {  # <backend>
  local backend=$1 rec id out
  id="preabort-gotmp-$backend-z1"
  rec=$(make_abort_case "$backend" "preabort-gotmp-$backend" "$id")
  read_abort_record "$rec"

  out=$(FM_FAKE_GOTMPDIR_SEND_FAIL=1 run_abort_spawn "$backend" "$id") || true
  assert_contains "$out" "temporary-directory environment could not be delivered" \
    "$backend: the aborted spawn did not say which delivery failed: $out"
  assert_discarded_endpoint "$backend" "$id" "$out"
  pass "$backend: a failed GOTMPDIR delivery discards the endpoint it created"
}

test_gotmpdir_failure_reports_a_surviving_endpoint() {  # <backend>
  local backend=$1 rec id out
  id="preabort-gotmp-strand-$backend-z2"
  rec=$(make_abort_case "$backend" "preabort-gotmp-strand-$backend" "$id")
  read_abort_record "$rec"

  out=$(FM_FAKE_GOTMPDIR_SEND_FAIL=1 FM_FAKE_KILL_NOOP=1 run_abort_spawn "$backend" "$id") || true
  assert_stranded_endpoint "$backend" "$id" "$out"
  pass "$backend: an endpoint surviving a failed GOTMPDIR delivery is reported as stranded"
}

# --- the uncleared-TRACEPARENT-input abort, on the two adapters that produce it ---

test_unsafe_trace_delivery_discards_the_endpoint() {  # <backend>
  local backend=$1 rec id out
  id="preabort-trace-$backend-z3"
  rec=$(make_abort_case "$backend" "preabort-trace-$backend" "$id")
  read_abort_record "$rec"

  out=$(FM_FAKE_TRACEPARENT_SEND_UNSAFE=1 run_abort_spawn "$backend" "$id") || true
  assert_contains "$out" "refusing to append the launch command" \
    "$backend: the uncleared-input refusal did not report why the spawn stopped: $out"
  assert_discarded_endpoint "$backend" "$id" "$out"
  pass "$backend: an uncleared TRACEPARENT input discards the endpoint it created"
}

test_unsafe_trace_delivery_reports_a_surviving_endpoint() {  # <backend>
  local backend=$1 rec id out
  id="preabort-trace-strand-$backend-z4"
  rec=$(make_abort_case "$backend" "preabort-trace-strand-$backend" "$id")
  read_abort_record "$rec"

  out=$(FM_FAKE_TRACEPARENT_SEND_UNSAFE=1 FM_FAKE_KILL_NOOP=1 run_abort_spawn "$backend" "$id") || true
  assert_stranded_endpoint "$backend" "$id" "$out"
  pass "$backend: an endpoint surviving an uncleared TRACEPARENT input is reported as stranded"
}

for BACKEND in tmux zellij cmux herdr; do
  test_gotmpdir_failure_discards_the_endpoint "$BACKEND"
  test_gotmpdir_failure_reports_a_surviving_endpoint "$BACKEND"
done
for BACKEND in zellij cmux; do
  test_unsafe_trace_delivery_discards_the_endpoint "$BACKEND"
  test_unsafe_trace_delivery_reports_a_surviving_endpoint "$BACKEND"
done

echo "# all fm-spawn-prepublication-abort tests passed"
