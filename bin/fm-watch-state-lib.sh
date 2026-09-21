#!/usr/bin/env bash
# bin/fm-watch-state-lib.sh - the ONE owner of the watcher pane-supervision
# marker lifecycle under state/.
#
# fm-watch.sh names every per-window bookkeeping file by one derivation
# (fm_watch_state_key): the recorded endpoint target with ':', '/', and '.'
# flattened to '_'. That key outlives the task that created it: a window handed
# to a successor (a reused pane slot, a relaunched endpoint, a remote route
# claimed again) resolves to the NEW task through window_to_task while the OLD
# task's .hash-/.count-/.stale-/.stale-since-/.wedge-escalations- and
# pause/write/wait markers still sit on disk. The first stable-hash sight then
# classifies the successor inside the predecessor's escalation timeline - the
# false "possible wedge, escalation N" alarms on healthy workers that this
# retirement exists to stop (the 2026-09 phantom stale/wedge incidents).
#
# Retirement has two complementary mechanisms, both inside existing lifecycle
# paths - no ad-hoc cleaner:
#
#   bind    fm_watch_window_bind, called by the watcher for every recorded
#           window once at startup and again per poll before any marker is
#           read. The .window-owner-<key> marker records which task the key's
#           state belongs to. Three cases: the recorded owner IS the task -
#           one marker read and return; the recorded owner is another task
#           still live on an endpoint that derives this key - the flattened
#           key space is lossy (sess:a.b and sess:a_b share one key), so a
#           live sharer's marker set is shared state left untouched, not
#           residue; anything else - a dead or moved owner, or no record at
#           all - makes the key foreign residue retired before it can be
#           read, then the new owner is written, except while another live
#           task still shares the key, where only the owner record is
#           re-pointed. Spawn claims the key before it publishes the record,
#           so a task never loses its own live markers to this bind.
#           Detection semantics are unchanged: the successor's own fresh
#           counters still classify, absorb, and escalate exactly as before.
#
#   retire  fm_watch_retire_window_state + fm_watch_retire_task_state, called
#           by bin/fm-teardown.sh when a task's endpoint goes away and by
#           bin/fm-spawn.sh just before it publishes a task record claiming an
#           endpoint. The task retire also removes the per-incarnation turn
#           anchors (<task>.turn-ended, <task>.progress, and the turn-end seen
#           marker) so a relaunched incarnation's turn-age clock starts from
#           its own record, never a predecessor's stale mtime - a stale anchor
#           reads as already over the completed-turn bound and skips the wedge
#           hold on the new incarnation's first silent step.
#           fm_watch_orphan_state_sweep, called by bin/fm-bootstrap.sh
#          's locked session-start mutating phase after backlog reconciliation
#           settles the live meta set, removes whatever those paths could not:
#           window-keyed markers whose key no live meta records, task-keyed
#           markers whose task has no meta, signal files whose task is gone,
#           and seen markers whose signal file is gone.
#
# The status-paired marker families (.seen-<task>_status, .hb-surfaced-<task>,
# .subsuper-seen-status-<task>, .<task>.open-decisions-cursor) stay owned by
# status_retire_presentation_task (bin/fm-classify-lib.sh), which removes them
# together with <task>.status - a deliberately kept orphan log keeps its
# markers so it can never replay. The sweep removes one of those markers only
# when its <task>.status is gone.
#
# Requires fm-backend.sh sourced (fm_meta_get, fm_backend_target_of_meta);
# every production caller already has it.
set -u

# The single shared derivation of a watcher marker key: ':', '/', and '.'
# become '_' so an endpoint target or task id is usable as a filename suffix.
# Every per-window file the watcher keeps is named by it (.hash-, .count-,
# .stale-, .stale-since-, .wedge-escalations-, .paused-*, .writing-*,
# .waiting-*, .churn-since-, .dead-reported-, .window-owner-), the
# sub-supervisor keys its per-task episode markers with the same derivation
# (.subsuper-stale-, .subsuper-paused-, .subsuper-pause-until-due-), and live
# homes hold those markers on disk under this exact format. The status-paired
# names above keep their own encoders (bin/fm-classify-lib.sh's
# status_signal_seen_marker_path, status_heartbeat_seen_marker_path, and
# status_daemon_seen_marker_path, plus bin/fm-wake-lib.sh's
# fm_wake_signal_seen_path), and the sweep reconstructs them with this
# derivation, so a drift on either side silently mispairs or orphans live
# markers.
fm_watch_state_key() {  # <window-target-or-task-id> -> marker key
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

# Every per-window marker family, as filename prefixes after state/. Order
# matters for the sweep's glob pass: a family that prefixes another must come
# first (.stale-since- before .stale-, .paused-rechecked-/.paused-resurfaced-
# before .paused-) so each file is claimed by its longest family exactly once.
fm_watch_window_marker_families() {
  printf '%s\n' \
    .stale-since- \
    .paused-rechecked- \
    .paused-resurfaced- \
    .writing-since- \
    .writing-resurfaced- \
    .waiting-resurfaced- \
    .wedge-escalations- \
    .churn-since- \
    .dead-reported- \
    .window-owner- \
    .count- \
    .hash- \
    .paused- \
    .stale-
}

# Print the id of a live task - a task whose <task>.meta survives - whose
# recorded endpoint target derives <key>, excluding <exclude-task>. Prints
# nothing and returns 1 when no live task shares the key. The flattened key
# space is lossy, so two distinct endpoints can derive one key (sess:a.b and
# sess:a_b) and share its marker set: while a live task sits on a colliding
# endpoint the set is shared state, never residue.
fm_watch_key_live_sharer() {  # <state-dir> <key> [exclude-task] -> prints task
  local state=$1 key=$2 excl=${3:-} meta mt mw
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    mt=${meta##*/}
    mt=${mt%.meta}
    [ "$mt" = "$excl" ] && continue
    mw=$(fm_backend_target_of_meta "$meta" 2>/dev/null || true)
    [ -n "$mw" ] || continue
    [ "$(fm_watch_state_key "$mw")" = "$key" ] || continue
    printf '%s' "$mt"
    return 0
  done
  return 1
}

# Print the id of a live task whose own id derives <enc> under the same lossy
# key derivation, excluding <exclude-task>. Prints nothing and returns 1 when
# no live task shares the encoding. Task ids carry both '.' and '_'
# (fm_task_id_path_safe allows [A-Za-z0-9._-]), so two live tasks like
# v2.ship and v2_ship encode to one key: while a live sibling shares the
# encoding the .subsuper-* markers under it are shared state, not residue.
fm_watch_task_key_live_sharer() {  # <state-dir> <enc> [exclude-task] -> prints task
  local state=$1 enc=$2 excl=${3:-} meta mt
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    mt=${meta##*/}
    mt=${mt%.meta}
    [ "$mt" = "$excl" ] && continue
    [ "$(fm_watch_state_key "$mt")" = "$enc" ] || continue
    printf '%s' "$mt"
    return 0
  done
  return 1
}

# Remove every per-window marker one recorded endpoint target owns. Idempotent;
# safe to call for a target that never had markers written. A no-op while
# another live task's endpoint derives the same flattened key: the marker set
# is shared with that survivor, not residue to wipe. <exclude-task> names the
# acting task so its own record cannot count as the sharer.
fm_watch_retire_window_state() {  # <state-dir> <window-target> [exclude-task]
  local state=$1 w=$2 excl=${3:-} key family
  [ -n "$w" ] || return 0
  key=$(fm_watch_state_key "$w")
  [ -n "$(fm_watch_key_live_sharer "$state" "$key" "$excl" || true)" ] && return 0
  while IFS= read -r family; do
    [ -n "$family" ] || continue
    rm -f -- "$state/$family$key" || return 1
  done <<EOF
$(fm_watch_window_marker_families)
EOF
}

# Remove the task-keyed supervision markers a retired or replaced task leaves:
# the per-incarnation turn anchors (<task>.turn-ended, <task>.progress, and
# the turn-end's .seen- signature marker - busy_turn_over_age reads those
# mtimes as the recorded-step age, and a relaunched incarnation must never
# start its clock from a predecessor's stale anchor), the sub-supervisor's
# per-task stale/pause episode markers, and the parent-side secondmate
# wake-stall trackers. The raw-id files belong to this task alone and always
# go. The .subsuper-* families and the turn-end's .seen- name are all derived
# through lossy flattening, so while a live sibling task's id encodes to the
# same key they are shared state left untouched - removing them would reset
# that sibling's declared-wait epoch or make its next turn-end replay.
# Deliberately excludes the status-paired families - the status-presentation
# owner retires those with <task>.status, and a task's log legitimately
# outlives one incarnation. Safe at both teardown (task gone) and spawn
# (fresh incarnation of a reused id or claimed endpoint).
fm_watch_retire_task_state() {  # <state-dir> <task-id>
  local state=$1 task=$2 enc
  [ -n "$task" ] || return 0
  enc=$(fm_watch_state_key "$task")
  rm -f -- "$state/$task.turn-ended" "$state/$task.progress" \
    "$state/.secondmate-wake-stall-$task" "$state/.secondmate-wake-progress-$task" \
    || return 1
  if [ -d "$state/.secondmate-wake-stall-receipts/$task" ]; then
    rm -rf -- "$state/.secondmate-wake-stall-receipts/$task" || return 1
  fi
  if [ -z "$(fm_watch_task_key_live_sharer "$state" "$enc" "$task" || true)" ]; then
    rm -f -- "$state/.seen-$(printf '%s' "$task.turn-ended" | tr '.' '_')" \
      "$state/.subsuper-stale-$enc" "$state/.subsuper-paused-$enc" \
      "$state/.subsuper-pause-until-due-$enc" || return 1
  fi
}

# Write an owner record atomically. A reader that caught a partial owner line
# would retire the whole marker set as if another task owned it, so the record
# is staged and renamed.
fm_watch_window_owner_write() {  # <owner-file> <task>
  local owner_file=$1 task=$2 tmp
  tmp="$owner_file.tmp.$$"
  printf '%s' "$task" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$owner_file"
}

# Claim an endpoint's marker set for a task at record time: retire whatever a
# previous owner left under the key, then publish this task as the owner. Spawn
# calls this just before it publishes the task's meta, so the owner's task id
# is already recorded by the time any watcher poll can see the window - a
# first-poll bind then never mistakes the new task's own fresh markers for a
# predecessor's residue.
fm_watch_window_claim() {  # <state-dir> <window-target> <task>
  local state=$1 w=$2 task=$3 key
  [ -n "$w" ] && [ -n "$task" ] || return 0
  key=$(fm_watch_state_key "$w")
  fm_watch_retire_window_state "$state" "$w" "$task" || return 1
  fm_watch_window_owner_write "$state/.window-owner-$key" "$task"
}

# Bind a recorded window's marker set to its current owning task. The owner
# recorded in .window-owner-<key> decides:
#   same task:     one marker read and return - the steady-state cost.
#   live sharer:   the recorded owner is another task whose meta still records
#                  an endpoint deriving this key. Distinct endpoints collide
#                  on the flattened key space, so the marker set is shared
#                  state - leave it and its owner record untouched, or the
#                  colliding tasks would thrash-retire each other's counters
#                  and throttle markers every poll.
#   otherwise:     the key is foreign. A dead or moved owner means a
#                  predecessor's residue; no owner at all means markers from
#                  before the owner era (or a predecessor whose record did
#                  not survive). Retire the set before it can be read, then
#                  write the new owner. The retire itself stays collision-
#                  safe: while another live task still shares the key it only
#                  re-points the dead record at this claimant and keeps the
#                  shared set.
#               Spawn claims the key before publishing its record, so this can
#               never erase the current task's own live markers.
fm_watch_window_bind() {  # <state-dir> <window-target> <task>
  local state=$1 w=$2 task=$3 key owner_file owner owner_w
  [ -n "$w" ] && [ -n "$task" ] || return 0
  key=$(fm_watch_state_key "$w")
  owner_file="$state/.window-owner-$key"
  owner=$(cat "$owner_file" 2>/dev/null || true)
  [ "$owner" = "$task" ] && return 0
  if [ -n "$owner" ] && [ -e "$state/$owner.meta" ]; then
    owner_w=$(fm_backend_target_of_meta "$state/$owner.meta" 2>/dev/null || true)
    [ -n "$owner_w" ] && [ "$(fm_watch_state_key "$owner_w")" = "$key" ] && return 0
  fi
  fm_watch_retire_window_state "$state" "$w" "$task" || return 1
  fm_watch_window_owner_write "$owner_file" "$task"
}

# Retire watcher bookkeeping whose owner is gone. Prints the number of files
# removed. Runs inside bootstrap's locked session-start mutating phase after
# backlog reconciliation, so the meta set it reads is settled for this session.
#
#   window-keyed markers: removed when no live *.meta records a target that
#     derives their key (longest-family-first claiming handles prefixes that
#     nest, like .stale- inside .stale-since-).
#   task-keyed markers: .subsuper-{stale,paused,pause-until-due}-<enc>,
#     .secondmate-wake-{stall,progress}-<task>, and
#     .secondmate-wake-stall-receipts/<task>/ removed when no <task>.meta lives.
#   signal files: <task>.turn-ended and <task>.progress removed when no
#     <task>.meta lives - a dead task's marker can only phantom-signal.
#   seen markers: .seen-<enc>_status and .seen-<enc>_turn-ended removed when
#     their signal file is gone; .hb-surfaced-<enc>,
#     .subsuper-seen-status-<enc>, and .<task>.open-decisions-cursor removed
#     when <task>.status is gone. Kept while the log survives: an orphan log
#     must keep its markers or it replays as fresh on the next scan.
#   <task>.status itself is NEVER touched: deliberately kept orphan logs are a
#     session-start digest input, not watcher residue.
fm_watch_orphan_state_sweep() {  # <state-dir>
  local state=$1 meta task w family marker base key enc f d removed=0
  local live_tasks=$'\n' live_keys=$'\n' live_enc=$'\n'
  local status_enc=$'\n' status_raw=$'\n' seen_status=$'\n' seen_turnend=$'\n'
  local seen_files=$'\n'

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    live_tasks="$live_tasks$task"$'\n'
    live_enc="$live_enc$(fm_watch_state_key "$task")"$'\n'
    w=$(fm_backend_target_of_meta "$meta") || w=
    if [ -n "$w" ]; then
      live_keys="$live_keys$(fm_watch_state_key "$w")"$'\n'
    fi
  done

  # Meta-less signal-source files are residue; removing them first also makes
  # their .seen- markers orphans for the pairing passes below.
  for f in "$state"/*.turn-ended "$state"/*.progress; do
    [ -f "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    task=${base%.*}
    case "$live_tasks" in *$'\n'"$task"$'\n'*) continue ;; esac
    rm -f -- "$f" || return 1
    removed=$((removed + 1))
  done

  # Pairing keep-sets are built from the surviving signal FILES, because the
  # marker-name encoding is lossy (a.b and a_b share one encoded name; a marker
  # is live while any file it could encode exists).
  for f in "$state"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base=${f##*/}
    seen_status="$seen_status$(fm_watch_state_key "$base")"$'\n'
    task=${base%.status}
    status_enc="$status_enc$(fm_watch_state_key "$task")"$'\n'
    status_raw="$status_raw$task"$'\n'
  done
  for f in "$state"/*.turn-ended; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    seen_turnend="$seen_turnend$(fm_watch_state_key "${f##*/}")"$'\n'
  done

  for marker in "$state"/.seen-*_status; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    enc=${marker##*/.seen-}
    case "$seen_status" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.seen-*_turn-ended; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    enc=${marker##*/.seen-}
    case "$seen_turnend" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.hb-surfaced-* "$state"/.subsuper-seen-status-*; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    enc=${base#.hb-surfaced-}
    enc=${enc#.subsuper-seen-status-}
    case "$status_enc" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.*.open-decisions-cursor; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    task=${base#.}
    task=${task%.open-decisions-cursor}
    case "$status_raw" in *$'\n'"$task"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done

  for marker in "$state"/.subsuper-stale-* "$state"/.subsuper-paused-* \
      "$state"/.subsuper-pause-until-due-*; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    enc=${base#.subsuper-stale-}
    enc=${enc#.subsuper-paused-}
    enc=${enc#.subsuper-pause-until-due-}
    case "$live_enc" in *$'\n'"$enc"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  for marker in "$state"/.secondmate-wake-stall-* "$state"/.secondmate-wake-progress-*; do
    [ -f "$marker" ] || [ -L "$marker" ] || continue
    base=${marker##*/}
    case "$base" in
      .secondmate-wake-stall-*)   task=${base#.secondmate-wake-stall-} ;;
      *)                          task=${base#.secondmate-wake-progress-} ;;
    esac
    case "$live_tasks" in *$'\n'"$task"$'\n'*) continue ;; esac
    rm -f -- "$marker" || return 1
    removed=$((removed + 1))
  done
  if [ -d "$state/.secondmate-wake-stall-receipts" ]; then
    for d in "$state"/.secondmate-wake-stall-receipts/*/; do
      [ -d "$d" ] || continue
      task=${d%/}
      task=${task##*/}
      case "$live_tasks" in *$'\n'"$task"$'\n'*) continue ;; esac
      rm -rf -- "$d" || return 1
      removed=$((removed + 1))
    done
  fi

  while IFS= read -r family; do
    [ -n "$family" ] || continue
    for marker in "$state/$family"*; do
      [ -f "$marker" ] || [ -L "$marker" ] || continue
      base=${marker##*/}
      case "$seen_files" in *$'\n'"$base"$'\n'*) continue ;; esac
      seen_files="$seen_files$base"$'\n'
      key=${base#"$family"}
      case "$live_keys" in *$'\n'"$key"$'\n'*) continue ;; esac
      rm -f -- "$marker" || return 1
      removed=$((removed + 1))
    done
  done <<EOF
$(fm_watch_window_marker_families)
EOF

  printf '%s\n' "$removed"
}
