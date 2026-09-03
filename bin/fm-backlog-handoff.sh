#!/usr/bin/env bash
# Hand already-identified, in-scope backlog items off from the main firstmate
# backlog to a secondmate's own home backlog. Use this when a secondmate is
# created (or whenever an existing queued item should become its domain's work)
# so the secondmate owns its queue from day one instead of the item staying
# stranded in the main backlog.
#
# Scope-matching is firstmate's JUDGMENT: you pass the task-id keys you have
# already judged in-scope for the secondmate. This script performs only the
# fleet-level validation that the backlog backend cannot know, then DELEGATES
# the actual item move to `tasks-axi mv`, the single owner of the backlog
# format. Delegating the move is the durability end-state: it removes the awk
# that used to re-implement block extraction and insertion here, so the format
# has exactly one parser and cannot drift out of sync (the body-orphaning class
# of bug fixed in PR #401 was exactly that drift).
#
# What this script still owns (never delegated):
#   - resolving the secondmate home from data/secondmates.md;
#   - proving the destination is a genuine seeded secondmate home
#     (.fm-secondmate-home marker, AGENTS.md + bin/), never a project clone, the
#     active home, or the firstmate repo;
#   - moving only `## Queued` items, refusing `## In flight` and historical
#     `## Done` records, which must stay with their home for pruning or
#     archiving;
#   - durably preparing any exact linked or legacy-unlinked source before its
#     row leaves the dispatch backlog, preparing the target before destination
#     receipt, then committing target ownership and a source tombstone;
#   - the multi-key classification and idempotent per-key reporting: a key
#     already present in the secondmate backlog is reported and skipped, and if
#     any key matches neither backlog nothing is moved;
#   - warning, after a successful move, when a moved key still owes a public
#     relay reply bound to main/<key>, or when this home has an open public loop
#     with nothing owed, because routing work out does not close that loop. The
#     move is not blocked: rebinding or rechain is a relay-side decision the
#     caller makes.
#
# What `tasks-axi mv <id>... --to <dest>` owns: moving each full item BLOCK
# byte-exact (header, body lines, blank separators, and indented pseudo-headings
# such as `  ## Intent`), preserving destination section placement, and moving a
# whole connected set (a blocker and its dependents) atomically with blocked-by
# links preserved. It refuses a move that would strand a dependency across the
# two files; that error is surfaced verbatim and nothing is moved.
#
# Item bodies must use at least two leading spaces. The helper refuses a selected
# item with a single-space or tab-indented continuation rather than risk leaving
# it orphaned, because tasks-axi treats only two-or-more-space lines as body.
# The move needs compatible `tasks-axi` on PATH, including atomic multi-ID `mv`
# support. Bootstrap requires a compatible build fleet-wide, so this works
# everywhere; the `config/backlog-backend=manual` knob only governs firstmate's
# own hand-editing of its own backlog, not this validated helper. Idempotent:
# re-running converges. Atomic: on any move failure nothing moves.
# See AGENTS.md project management and task lifecycle.
# Remote routes use an outbox handoff: one atomic local tasks-axi mv removes the
# selected set from the dispatchable backlog into data/handoff/<id>.outbox.md,
# then an idempotent confined transfer and fm-backlog-receive.sh deliver it.
# A present outbox remains the remote retry trigger until backlog receipt,
# identity prepare/commit/tombstone convergence, and receiver wake are confirmed;
# a companion pending-reply correlation makes crash recovery reconcile an attempted
# or confirmed wake instead of blindly resending it. A prepared local wake is bound
# to the exact sorted requested-key batch; an unrelated handoff to that mate refuses
# until the original batch is retried, so it cannot discard wake intent for work
# that already moved. No two-phase backlog journal exists.
# Every newly durable backlog delivery also sends one marked wake to the receiving
# endpoint. A missing endpoint or a live endpoint that rejects the wake makes the
# handoff fail with the delivered backlog and identity recovery state intact.
# Usage: fm-backlog-handoff.sh <secondmate-id> <item-key>...
#        fm-backlog-handoff.sh --resume-pending
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"
MAIN_BACKLOG="$DATA/backlog.md"
FS_OWNER="$SCRIPT_DIR/fm-work-identity-fs.py"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

RECEIVER_WAKE_MESSAGE='New routed work is in your backlog. Run bin/fm-session-start.sh now, then act on the routed task.'

ACTIVE_HANDOFF_LOCK=
ACTIVE_BACKLOG_LOCK=
ACTIVE_TARGET_BACKLOG_LOCK=
ACTIVE_REGISTRY_LOCK=
HANDOFF_PLAN_DIR=
ACTIVE_OUTBOX_PATH=
ACTIVE_OUTBOX_PARENT_INODE=
ACTIVE_OUTBOX_FILE_INODE=
ACTIVE_OUTBOX_STATE=
ACTIVE_OUTBOX_HASH=
release_remote_locks() {
  if [ -n "$HANDOFF_PLAN_DIR" ]; then
    rm -rf -- "$HANDOFF_PLAN_DIR" 2>/dev/null || true
    HANDOFF_PLAN_DIR=
  fi
  if [ -n "$ACTIVE_TARGET_BACKLOG_LOCK" ]; then
    fm_lock_release "$ACTIVE_TARGET_BACKLOG_LOCK"
    ACTIVE_TARGET_BACKLOG_LOCK=
  fi
  if [ -n "$ACTIVE_BACKLOG_LOCK" ]; then
    fm_lock_release "$ACTIVE_BACKLOG_LOCK"
    ACTIVE_BACKLOG_LOCK=
  fi
  if [ -n "$ACTIVE_HANDOFF_LOCK" ]; then
    fm_lock_release "$ACTIVE_HANDOFF_LOCK"
    ACTIVE_HANDOFF_LOCK=
  fi
  if [ -n "$ACTIVE_REGISTRY_LOCK" ]; then
    fm_lock_release "$ACTIVE_REGISTRY_LOCK"
    ACTIVE_REGISTRY_LOCK=
  fi
}
trap release_remote_locks EXIT
trap 'exit 1' HUP INT TERM

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

RESUME_PENDING=0
if [ "${1:-}" = --resume-pending ]; then
  [ "$#" -eq 1 ] || { echo "usage: fm-backlog-handoff.sh --resume-pending" >&2; exit 1; }
  RESUME_PENDING=1
  ID=
  shift
else
  [ "$#" -ge 2 ] || { echo "usage: fm-backlog-handoff.sh <secondmate-id> <item-key>..." >&2; exit 1; }
  ID=$1
  case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "error: unsafe secondmate id: $ID" >&2; exit 1 ;; esac
  shift
fi

secondmate_home() {
  local id=$1 home
  [ -f "$REG" ] || { echo "error: no secondmate registry at $REG" >&2; return 1; }
  home=$(secondmate_registry_field "$REG" "$id" home || true)
  [ -n "$home" ] || { echo "error: secondmate $id has no home in $REG" >&2; return 1; }
  printf '%s\n' "$home"
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: firstmate home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: secondmate $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: secondmate $name directory must resolve inside the secondmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the active firstmate home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: secondmate $name directory cannot be inside the firstmate repo: $dir" >&2
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: secondmate home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: secondmate home cannot be the active firstmate home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: secondmate home cannot be the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: secondmate home cannot be inside the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: secondmate home cannot be inside the firstmate repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: secondmate home cannot be an ancestor of the active firstmate home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: secondmate home cannot be an ancestor of the firstmate repo: $home" >&2
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/.fm-secondmate-home" ]; then
    echo "error: firstmate home $home is not a seeded secondmate home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/.fm-secondmate-home" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: firstmate home $home is marked for secondmate ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a firstmate home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a firstmate home (missing bin/)" >&2
    return 1
  fi
  (
    cd -P "$abs_home" || exit 1
    [ "$(pwd -P)" = "$abs_home" ] || exit 1
    [ ! -L .fm-secondmate-home ] && [ -f .fm-secondmate-home ] \
      && [ "$(cat .fm-secondmate-home 2>/dev/null || true)" = "$id" ] \
      && [ ! -L AGENTS.md ] && [ -f AGENTS.md ] \
      && [ ! -L bin ] && [ -d bin ] || exit 1
    printf '%s\t%s\n' "$abs_home" "$(backlog_file_inode .)"
  )
}

backlog_file_link_count() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%l' "$1" 2>/dev/null
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

backlog_file_inode() {
  if [ "$(uname 2>/dev/null || true)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

validate_backlog_file() {
  local label=$1 path=$2 links
  if [ -L "$path" ]; then
    echo "error: $label must not be a symlink: $path" >&2
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: $label is not a regular file: $path" >&2
    return 1
  fi
  if [ -e "$path" ]; then
    links=$(backlog_file_link_count "$path") || {
      echo "error: cannot inspect $label link count: $path" >&2
      return 1
    }
    if [ "$links" != 1 ]; then
      echo "error: $label must not be hardlinked: $path" >&2
      return 1
    fi
  fi
}

# Classify a single key by the section it lives under (## In flight /
# ## Queued / ## Done), or return non-zero if no `- [ ] <key>` / `- [x] <key>`
# header exists in the file. This reads only section headings and item header
# lines - never item bodies - so it drives the fleet-level classification (in-
# flight refusal, already-present idempotency, missing-key abort) without
# re-implementing the block/body move semantics that tasks-axi mv owns.
backlog_key_section() {
  local file=$1 key=$2
  [ -f "$file" ] || return 1
  awk -v key="$key" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "## ", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (id == key) { print section; found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

backlog_key_noncanonical_body_lines() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { capturing = 1 }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]/ && !/^  / && /[^[:space:]]/ { print }
  ' "$file"
}

safe_child_dir() { # <anchor-dir> <anchor-inode> <child-name>
  local anchor=$1 anchor_inode=$2 child=$3 expected
  case "$child" in ''|.|..|*/*) return 1 ;; esac
  expected="$anchor/$child"
  (
    cd -P "$anchor" || exit 1
    [ "$(backlog_file_inode .)" = "$anchor_inode" ] || exit 1
    [ ! -L "$child" ] || exit 1
    if [ ! -e "$child" ]; then
      mkdir -m 700 -- "$child" || exit 1
    fi
    [ -d "$child" ] && [ ! -L "$child" ] || exit 1
    cd -P -- "$child" || exit 1
    [ "$(pwd -P)" = "$expected" ] || exit 1
    [ "$(backlog_file_inode ..)" = "$anchor_inode" ] || exit 1
    printf '%s\t%s\n' "$expected" "$(backlog_file_inode .)"
  )
}

seed_backlog_scaffold() { # <path> <parent-inode> [report-created]
  local target=$1 expected_dir_inode=$2 dir base
  dir=$(dirname "$target")
  base=$(basename "$target")
  case "$base" in ''|.|..|*/*) return 1 ;; esac
  (
    local staging tmp target_inode source_details source_state source_digest rc=0 report=${3:-}
    cd -P "$dir" || exit 1
    [ "$(backlog_file_inode .)" = "$expected_dir_inode" ] || exit 1
    target=$base
    staging=".${target}.scaffold-publishing"
    tmp=$(umask 077; mktemp './.backlog-scaffold.XXXXXX') || exit 1
    if ! printf '## In flight\n\n## Queued\n\n## Done\n' > "$tmp" \
      || ! chmod 600 "$tmp"; then
      rm -f -- "$tmp"
      exit 1
    fi
    source_details=$(python3 "$FS_OWNER" describe-source "$tmp" 1024) \
      || { rm -f -- "$tmp"; exit 1; }
    source_state=${source_details%%$'\t'*}
    source_digest=${source_details#*$'\t'}
    [ "$source_state" != "$source_details" ] \
      || { rm -f -- "$tmp"; exit 1; }
    python3 "$FS_OWNER" no-clobber . "$expected_dir_inode" "$target" "$tmp" "$staging" \
      "$source_state" "$source_digest" || rc=$?
    rm -f -- "$tmp" || exit 1
    case "$rc" in
      0)
        validate_backlog_file "backlog scaffold target" "$target" || exit 1
        target_inode=$(backlog_file_inode "$target") || exit 1
        [ -z "$report" ] || printf '%s\n' "$target_inode"
        ;;
      2)
        validate_backlog_file "backlog scaffold target" "$target" || exit 1
        ;;
      *) exit "$rc" ;;
    esac
  )
}

recover_backlog_scaffold_publication() { # <path> <parent-inode>
  local target=$1 dir base staging journal
  dir=$(dirname "$target")
  base=$(basename "$target")
  staging="$dir/.${base}.scaffold-publishing"
  journal="$dir/.${base}.no-clobber-journal"
  if [ -e "$staging" ] || [ -L "$staging" ] \
    || [ -e "$journal" ] || [ -L "$journal" ]; then
    seed_backlog_scaffold "$target" "$2"
  fi
}

remove_owned_backlog_file() { # <path> <parent-inode> <file-inode> <sha256>
  local target=$1 expected_dir_inode=$2 expected_file_inode=$3 expected_hash=$4 dir base state
  dir=$(dirname "$target")
  base=$(basename "$target")
  case "$base" in ''|.|..|*/*) return 1 ;; esac
  state=$(python3 "$FS_OWNER" describe "$dir" "$expected_dir_inode" "$base") || return 1
  case "$state" in
    "regular:$expected_file_inode:"*) ;;
    *) return 1 ;;
  esac
  python3 "$FS_OWNER" remove "$dir" "$expected_dir_inode" "$base" "$state" "$expected_hash"
}

remove_owned_backlog_scaffold() {
  remove_owned_backlog_file "$@"
}

anchor_existing_handoff_dir() {
  local home_real data_parent data_parent_real data_base data_expected data_info data_real data_inode
  if [ ! -e "$DATA" ] && [ ! -L "$DATA" ]; then return 2; fi
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 1
  home_real=$(cd -P "$FM_HOME" && pwd -P) || return 1
  data_parent=$(dirname "$DATA")
  data_base=$(basename "$DATA")
  case "$data_base" in ''|.|..|*/*) return 1 ;; esac
  data_parent_real=$(cd -P "$data_parent" && pwd -P) || return 1
  data_expected="$data_parent_real/$data_base"
  data_info=$(cd -P "$DATA" && printf '%s\t%s\n' "$(pwd -P)" "$(backlog_file_inode .)") || return 1
  data_real=${data_info%%$'\t'*}
  data_inode=${data_info#*$'\t'}
  [ "$data_real" = "$data_expected" ] || return 1
  case "$data_real" in "$home_real"/*) ;; *) return 1 ;; esac
  if [ ! -e "$data_real/handoff" ] && [ ! -L "$data_real/handoff" ]; then return 2; fi
  [ -d "$data_real/handoff" ] && [ ! -L "$data_real/handoff" ] || return 1
  (
    cd -P "$data_real" || exit 1
    [ "$(backlog_file_inode .)" = "$data_inode" ] || exit 1
    [ -d handoff ] && [ ! -L handoff ] || exit 1
    cd -P handoff || exit 1
    [ "$(backlog_file_inode ..)" = "$data_inode" ] || exit 1
    printf '%s\t%s\n' "$(pwd -P)" "$(backlog_file_inode .)"
  )
}

prepare_outbox_retirement() { # <outbox-path> <parent-inode>
  local outbox=$1 parent_inode=$2 dir base details state hash kind dev inode rest
  dir=$(dirname "$outbox")
  base=$(basename "$outbox")
  case "$base" in ''|.|..|*/*) return 1 ;; esac
  details=$(python3 "$FS_OWNER" describe-digest "$dir" "$parent_inode" "$base") || return 1
  state=${details%%$'\t'*}
  hash=${details#*$'\t'}
  [ "$state" != "$details" ] || return 1
  IFS=: read -r kind dev inode rest <<< "$state"
  [ "$kind" = regular ] && [ -n "$dev" ] && [ -n "$inode" ] || return 1
  ACTIVE_OUTBOX_PATH=$outbox
  ACTIVE_OUTBOX_PARENT_INODE=$parent_inode
  ACTIVE_OUTBOX_FILE_INODE=$dev:$inode
  ACTIVE_OUTBOX_STATE=$state
  ACTIVE_OUTBOX_HASH=$hash
}

# A public commitment made through the relay binds its work by home AND id, so an
# item that leaves this home takes that binding out of sync: reconciliation would
# still look for main/<key> while the work now lives in the secondmate's home.
# The move itself stays safe and is never blocked - rebinding is a relay-side
# decision the caller owns - but this is the one moment the staleness is
# detectable, so report it loudly instead of letting the promise go quiet.
# A home that never opted into the relay pays one presence check per key here.
warn_stale_public_commitments() { # <secondmate-id> <moved-key>...
  local id=$1 key out rc
  shift
  for key in "$@"; do
    rc=0
    out=$("$SCRIPT_DIR/fm-public-followup.sh" guard-work main "$key" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ] || continue
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'warning: %s still owes a public reply bound to main/%s; rebind it to secondmate:%s (tasks-axi public-followup bind-work, then bin/fm-public-followup.sh register <obligation-id> --relation <relation-id> --work-home secondmate:%s --work-id %s --generation <n>) or the promised reply will be reconciled against work this home no longer owns.\n' \
      "$key" "$key" "$id" "$id" "$key" >&2
  done
  if fm_pf_relay_active "$FM_HOME" && fm_pf_has_delivered_open_loops "$STATE"; then
    printf 'warning: this home has an open public loop with nothing owed; routing work to secondmate:%s does not close it. Hand it on with bin/fm-public-followup.sh rechain or close it with retire --reason.\n' \
      "$id" >&2
  fi
  # Reporting never changes the handoff's own success: the move already landed.
  return 0
}

# Wake a live receiver after its backlog has become durable. The marked message
# uses the normal endpoint route, so local and remote secondmates share the same
# verified submit and failure semantics. A seeded but not-yet-spawned home is a
# valid handoff destination, but its missing endpoint is reported rather than
# pretending the task was started.
receiver_wake_batch_id() { # <item-key>...
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\n' "$@" | LC_ALL=C sort | shasum -a 256 2>/dev/null | awk '{print $1}')
  else
    digest=$(printf '%s\n' "$@" | LC_ALL=C sort | sha256sum 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "$digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
  printf '%s' "${digest:0:16}"
}

receiver_wake_state_write() { # <secondmate-id> <state>
  local id=$1 value=$2 marker="$STATE/.backlog-handoff-$1.wake-pending" tmp
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$value" in
    pending|confirmed) ;;
    prepared:*) printf '%s' "$value" | grep -Eq '^prepared:[a-f0-9]{16}:[a-f0-9]{16}$' || return 1 ;;
    pending:*) printf '%s' "$value" | grep -Eq '^pending:[a-f0-9]{16}$' || return 1 ;;
    confirmed:*) printf '%s' "$value" | grep -Eq '^confirmed:[a-f0-9]{16}$' || return 1 ;;
    *) return 1 ;;
  esac
  tmp=$(umask 077; mktemp "$STATE/.backlog-handoff-wake.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

receiver_wake_mark() { # <secondmate-id> <prepared|pending> [batch-id]
  local id=$1 wake_phase=$2 batch=${3:-} marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec
  local wake_state
  case "$wake_phase" in prepared|pending) ;; *) return 1 ;; esac
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    value=$(cat "$marker" 2>/dev/null || true)
    case "$value" in
      prepared:*|pending:*)
        corr=${value#*:}
        corr=${corr%%:*}
        rec=$(fm_pending_reply_path "$STATE" "$corr")
        [ -f "$rec" ] && [ ! -L "$rec" ] \
          && [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ]
        return $?
        ;;
      pending) ;;
      *) return 1 ;;
    esac
  fi
  corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" "$RECEIVER_WAKE_MESSAGE") || return 1
  wake_state="$wake_phase:$corr"
  if [ "$wake_phase" = prepared ]; then
    printf '%s' "$batch" | grep -Eq '^[a-f0-9]{16}$' || return 1
    wake_state="$wake_state:$batch"
  fi
  if ! receiver_wake_state_write "$id" "$wake_state"; then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" || true
    return 1
  fi
}

receiver_wake_mark_pending() { # <secondmate-id>
  receiver_wake_mark "$1" pending
}

receiver_wake_mark_prepared() { # <secondmate-id> <batch-id>
  receiver_wake_mark "$1" prepared "$2"
}

receiver_wake_discard_prepared() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    prepared:*)
      corr=${value#prepared:}
      corr=${corr%%:*}
      ;;
    *) return 1 ;;
  esac
  fm_pending_reply_discard_undelivered "$STATE" "$corr" || return 1
  rm -f -- "$marker"
}

receiver_wake_promote_prepared() { # <secondmate-id> <batch-id>
  local id=$1 batch=$2 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    prepared:*:"$batch")
      corr=${value#prepared:}
      corr=${corr%%:*}
      ;;
    pending:*) return 0 ;;
    *) return 1 ;;
  esac
  receiver_wake_state_write "$id" "pending:$corr"
}

receiver_wake_discard_pending() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value corr
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    pending:*)
      corr=${value#pending:}
      fm_pending_reply_discard_undelivered "$STATE" "$corr" || return 1
      ;;
    pending) ;;
    *) return 1 ;;
  esac
  rm -f -- "$marker"
}

receiver_wake_clear_confirmed() { # <secondmate-id>
  local id=$1 marker="$STATE/.backlog-handoff-$1.wake-pending" value
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    pending|pending:*) return 0 ;;
    confirmed|confirmed:*) rm -f -- "$marker" ;;
    *) return 1 ;;
  esac
}

wake_secondmate_receiver() { # <secondmate-id> <correlation-id>
  local id=$1 corr=$2 meta="$STATE/$1.meta" out rc=0
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    printf 'error: handed off work to secondmate %s, but no live receiver endpoint is recorded; the destination backlog is durable and the receiver was not woken\n' "$id" >&2
    return 1
  fi
  [ "$(grep '^kind=' "$meta" | cut -d= -f2-)" = secondmate ] || {
    printf 'error: secondmate %s has non-secondmate endpoint metadata; backlog is durable but the receiver was not woken\n' "$id" >&2
    return 1
  }
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$RECEIVER_WAKE_MESSAGE" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'error: backlog delivery to secondmate %s succeeded, but its receiver wake failed; rerun this handoff to retry the wake\n' "$id" >&2
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
}

wake_pending_secondmate_receiver() { # <secondmate-id> [retain-confirmed]
  local id=$1 retain=${2:-0} marker="$STATE/.backlog-handoff-$1.wake-pending" value corr rec delivered
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    printf 'error: receiver wake state for secondmate %s is unsafe or invalid\n' "$id" >&2
    return 1
  fi
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    confirmed|confirmed:*) return 0 ;;
    prepared|prepared:*)
      printf 'error: receiver wake for secondmate %s was prepared before its backlog became durable\n' "$id" >&2
      return 1
      ;;
    pending)
      receiver_wake_mark_pending "$id" || return 1
      value=$(cat "$marker" 2>/dev/null || true)
      ;;
  esac
  case "$value" in pending:*) corr=${value#pending:} ;; *)
    printf 'error: receiver wake state for secondmate %s is unsafe or invalid\n' "$id" >&2
    return 1
    ;;
  esac
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] && [ ! -L "$rec" ] \
    && [ "$(fm_pending_reply_get "$rec" task_id)" = "$id" ] || return 1
  fm_pending_reply_reconcile_delivery "$STATE" "$corr" >/dev/null 2>&1 || true
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  if [ -z "$delivered" ]; then
    fm_pending_reply_corr_reusable "$STATE" "$corr" "$id" || {
      printf 'error: receiver wake delivery for secondmate %s is unresolved; refusing to resend correlation %s\n' "$id" "$corr" >&2
      return 1
    }
    wake_secondmate_receiver "$id" "$corr" || return 1
  fi
  if [ "$retain" = 1 ]; then
    receiver_wake_state_write "$id" "confirmed:$corr" || {
      printf 'error: receiver wake for secondmate %s was confirmed, but confirmed state could not be recorded\n' "$id" >&2
      return 1
    }
  else
    rm -f -- "$marker" || {
      printf 'error: receiver wake for secondmate %s was confirmed, but pending state could not be cleared\n' "$id" >&2
      return 1
    }
  fi
}

outbox_item_count() { # <path>
  awk '/^- \[[ x]\] / { count++ } END { print count + 0 }' "$1"
}

task_array_contains() { # <task-id> [task-id...]
  local wanted=$1 task
  shift
  for task in "$@"; do
    [ "$task" != "$wanted" ] || return 0
  done
  return 1
}

backlog_task_sha256() {
  local file=$1 task=$2
  [ "$(backlog_key_section "$file" "$task" 2>/dev/null || true)" = '## Queued' ] || return 1
  awk -v key="$task" '
    function item_id(line, rest, id) {
      rest=line; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id); return id
    }
    /^- \[[ x]\] / {
      if (capturing) exit
      if (item_id($0) == key) { capturing=1; print }
      next
    }
    capturing && /^##[[:space:]]+/ { exit }
    capturing && /^[[:space:]]*$/ { blanks++; next }
    capturing {
      while (blanks > 0) { print ""; blanks-- }
      print
    }
  ' "$file" | if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

TASKS_AXI_BACKLOG_IDS=()
load_tasks_axi_queued_ids() { # <path>
  local path=$1 output count parsed id state
  TASKS_AXI_BACKLOG_IDS=()
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  output=$(tasks-axi list --file "$path" --limit 1000000 2>&1) || {
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    return 1
  }
  count=$(printf '%s\n' "$output" | sed -n 's/^count: \([0-9][0-9]*\)$/\1/p')
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  parsed=$(printf '%s\n' "$output" | awk '
    /^tasks(\[[0-9]+\])?\{/ { rows=1; next }
    /^help(\[[0-9]+\])?:/ { rows=0; next }
    rows && /^  / {
      line=substr($0, 3)
      first=index(line, ",")
      if (!first) exit 2
      id=substr(line, 1, first-1)
      line=substr(line, first+1)
      second=index(line, ",")
      if (!second) exit 2
      state=substr(line, 1, second-1)
      print id "\t" state
    }
  ') || return 1
  while IFS=$'\t' read -r id state; do
    [ -n "$id" ] || continue
    case "$id" in .*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "$state" = queued ] || {
      echo "error: pending handoff set contains non-Queued task $id ($state): $path" >&2
      return 1
    }
    task_array_contains "$id" "${TASKS_AXI_BACKLOG_IDS[@]}" && return 1
    TASKS_AXI_BACKLOG_IDS+=("$id")
  done <<EOF
$parsed
EOF
  [ "${#TASKS_AXI_BACKLOG_IDS[@]}" -eq "$count" ] || return 1
}

PARSED_MOVE_KEYS=()
parse_tasks_axi_move_result() { # <json>
  local result=$1 parsed task
  PARSED_MOVE_KEYS=()
  parsed=$(printf '%s' "$result" | jq -er '
    select(type == "object" and .ok == true and .action == "mv")
    | if (has("ids") and (.ids | type) == "array" and (.ids | length) > 0
          and (.ids | all(.[]; type == "string"))
          and ((.ids | unique | length) == (.ids | length))) then .ids[]
      elif (has("id") and (.id | type) == "string") then .id
      else error("invalid move identity set") end
  ' 2>/dev/null) || return 1
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    case "$task" in .*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    task_array_contains "$task" "${PARSED_MOVE_KEYS[@]}" && return 1
    PARSED_MOVE_KEYS+=("$task")
  done <<EOF
$parsed
EOF
  [ "${#PARSED_MOVE_KEYS[@]}" -gt 0 ]
}

EXPECTED_MOVE_KEYS=()
RESOLVED_MOVE_KEYS=()
RESOLVED_MOVE_HASHES=()
MOVE_PLAN_SOURCE_HASH=
MOVE_PLAN_TARGET_HASH=
MOVE_PLAN_TARGET_PRESENT=0
resolve_tasks_axi_move_keys() { # <source> <target> <task-id>...
  local source=$1 target=$2 result task
  shift 2
  EXPECTED_MOVE_KEYS=()
  RESOLVED_MOVE_KEYS=()
  RESOLVED_MOVE_HASHES=()
  MOVE_PLAN_SOURCE_HASH=
  MOVE_PLAN_TARGET_HASH=
  MOVE_PLAN_TARGET_PRESENT=0
  [ "$#" -gt 0 ] || return 0
  for task in "$@"; do
    task_array_contains "$task" "${EXPECTED_MOVE_KEYS[@]}" || EXPECTED_MOVE_KEYS+=("$task")
  done
  HANDOFF_PLAN_DIR=$(umask 077; mktemp -d "$STATE/.backlog-handoff-plan.XXXXXX") || return 1
  cp -p -- "$source" "$HANDOFF_PLAN_DIR/source.md" || return 1
  if [ -f "$target" ] && [ ! -L "$target" ]; then
    cp -p -- "$target" "$HANDOFF_PLAN_DIR/target.md" || return 1
    MOVE_PLAN_TARGET_PRESENT=1
  else
    seed_backlog_scaffold "$HANDOFF_PLAN_DIR/target.md" "$(backlog_file_inode "$HANDOFF_PLAN_DIR")" || return 1
  fi
  MOVE_PLAN_SOURCE_HASH=$(sha256_file "$HANDOFF_PLAN_DIR/source.md") || return 1
  MOVE_PLAN_TARGET_HASH=$(sha256_file "$HANDOFF_PLAN_DIR/target.md") || return 1
  if ! result=$(tasks-axi mv "$@" --file "$HANDOFF_PLAN_DIR/source.md" \
    --to "$HANDOFF_PLAN_DIR/target.md" --json 2>&1); then
    [ -z "$result" ] || printf '%s\n' "$result" >&2
    rm -rf -- "$HANDOFF_PLAN_DIR"
    HANDOFF_PLAN_DIR=
    return 1
  fi
  parse_tasks_axi_move_result "$result" || {
    rm -rf -- "$HANDOFF_PLAN_DIR"
    HANDOFF_PLAN_DIR=
    return 1
  }
  for task in "${EXPECTED_MOVE_KEYS[@]}"; do
    task_array_contains "$task" "${PARSED_MOVE_KEYS[@]}" || {
      rm -rf -- "$HANDOFF_PLAN_DIR"
      HANDOFF_PLAN_DIR=
      return 1
    }
  done
  RESOLVED_MOVE_KEYS=("${PARSED_MOVE_KEYS[@]}")
  for task in "${RESOLVED_MOVE_KEYS[@]}"; do
    RESOLVED_MOVE_HASHES+=("$(backlog_task_sha256 "$HANDOFF_PLAN_DIR/target.md" "$task")")
  done
  rm -rf -- "$HANDOFF_PLAN_DIR"
  HANDOFF_PLAN_DIR=
}

resolved_move_hash() { # <task-id>
  local wanted=$1 i=0
  while [ "$i" -lt "${#RESOLVED_MOVE_KEYS[@]}" ]; do
    if [ "${RESOLVED_MOVE_KEYS[$i]}" = "$wanted" ]; then
      printf '%s\n' "${RESOLVED_MOVE_HASHES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

move_plan_inputs_unchanged() { # <source> <target>
  local source=$1 target=$2 current
  current=$(sha256_file "$source") || return 1
  [ "$current" = "$MOVE_PLAN_SOURCE_HASH" ] || return 1
  if [ "$MOVE_PLAN_TARGET_PRESENT" -eq 1 ]; then
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
    current=$(sha256_file "$target") || return 1
    [ "$current" = "$MOVE_PLAN_TARGET_HASH" ] || return 1
  else
    [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
  fi
}

task_sets_match() { # <expected-array-name> <actual-array-name>
  local expected_name=$1 actual_name=$2 task
  local -a expected actual
  case "$expected_name:$actual_name" in *[!A-Za-z0-9_:]*) return 1 ;; esac
  eval "expected=(\"\${${expected_name}[@]}\")"
  eval "actual=(\"\${${actual_name}[@]}\")"
  [ "${#expected[@]}" -eq "${#actual[@]}" ] || return 1
  for task in "${expected[@]}"; do
    task_array_contains "$task" "${actual[@]}" || return 1
  done
}

HANDOFF_IDENTITY_TASKS=()
HANDOFF_IDENTITY_PAYLOADS=()
HANDOFF_IDENTITY_CREATED=()
HANDOFF_IDENTITY_BACKLOG_HASHES=()

prepare_handoff_identity() { # <task-id> <target-home> <target-home-id> <backlog-sha256>
  local task=$1 target_home=$2 target_home_id=$3 backlog_sha=$4 result
  result=$(
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
      FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-work-identity.sh" \
      handoff-prepare "$task" --to-home "$target_home" --to-home-id "$target_home_id" \
        --backlog-sha256 "$backlog_sha" --result
  ) || return $?
  HANDOFF_IDENTITY_PAYLOAD=$(printf '%s' "$result" | jq -e -S -c '
    select(type == "object" and (keys | sort) == ["created","transfer"]
      and (.created | type) == "boolean" and (.transfer | type) == "object")
    | .transfer
  ') || return 1
  HANDOFF_IDENTITY_WAS_CREATED=$(printf '%s' "$result" | jq -r '.created') || return 1
}

source_handoff_action() { # <complete|cancel> <task-id> <payload>
  local action=$1 task=$2 payload=$3
  printf '%s\n' "$payload" \
    | FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
        FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-work-identity.sh" \
        "handoff-$action" "$task" --file - >/dev/null
}

local_target_handoff_action() { # <target-home> <stage|commit|abort> <task-id> <payload>
  local target_home=$1 action=$2 task=$3 payload=$4
  printf '%s\n' "$payload" \
    | FM_HOME="$target_home" FM_DATA_OVERRIDE="$target_home/data" \
        FM_STATE_OVERRIDE="$target_home/state" FM_ROOT_OVERRIDE="$FM_ROOT" \
        "$SCRIPT_DIR/fm-work-identity.sh" "handoff-$action" "$task" --file - >/dev/null
}

remote_target_handoff_action() { # <secondmate-id> <stage|commit|abort> <task-id> <payload>
  local id=$1 action=$2 task=$3 payload=$4
  printf '%s\n' "$payload" \
    | "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-work-identity.sh \
        "handoff-$action" "$task" --file - >/dev/null
}

remote_target_handoff_state() { # <secondmate-id> <task-id> <payload>
  local id=$1 task=$2 payload=$3
  printf '%s\n' "$payload" \
    | "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-work-identity.sh \
        handoff-target-state "$task" --file -
}

local_target_backlog_action() { # <target-home> <prepare|complete> <task-id> <payload>
  local target_home=$1 action=$2 task=$3 payload=$4
  printf '%s\n' "$payload" \
    | FM_HOME="$target_home" FM_ROOT_OVERRIDE="$FM_ROOT" \
        "$SCRIPT_DIR/fm-backlog-receive.sh" "--${action}-handoff" "$task" >/dev/null
}

remote_target_backlog_action() { # <secondmate-id> <prepare|complete> <task-id> <payload>
  local id=$1 action=$2 task=$3 payload=$4 rc=0 state state_rc=0
  printf '%s\n' "$payload" \
    | "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-backlog-receive.sh \
        "--${action}-handoff" "$task" || rc=$?
  if [ "$rc" -eq 255 ]; then
    state=$(printf '%s\n' "$payload" \
      | "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-work-identity.sh \
          handoff-backlog-state "$task" --file -) || state_rc=$?
    if [ "$state_rc" -eq 0 ]; then
      case "$action:$state" in
        prepare:prepared|prepare:backlog-prepared|prepare:backlog-completed|prepare:completed|complete:backlog-completed|complete:completed) rc=0 ;;
      esac
    fi
  fi
  [ "$rc" -eq 0 ] || echo "error: remote exact backlog $action failed for $task (status $rc)" >&2
  return "$rc"
}

prepare_local_handoff_backlog_receipts() { # <target-home>
  local target_home=$1 i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    local_target_backlog_action "$target_home" prepare \
      "${HANDOFF_IDENTITY_TASKS[$i]}" "${HANDOFF_IDENTITY_PAYLOADS[$i]}" || return 1
    i=$((i + 1))
  done
}

complete_local_handoff_backlog_receipts() { # <target-home>
  local target_home=$1 i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    local_target_backlog_action "$target_home" complete \
      "${HANDOFF_IDENTITY_TASKS[$i]}" "${HANDOFF_IDENTITY_PAYLOADS[$i]}" || return 1
    i=$((i + 1))
  done
}

prepare_remote_handoff_backlog_receipts() { # <secondmate-id>
  local id=$1 i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    remote_target_backlog_action "$id" prepare \
      "${HANDOFF_IDENTITY_TASKS[$i]}" "${HANDOFF_IDENTITY_PAYLOADS[$i]}" || return 1
    i=$((i + 1))
  done
}

rollback_local_handoff_identities() { # <target-home> <target-backlog>
  local target_home=$1 target_backlog=$2 i task payload created failed=0 preserved=0 rc
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    created=${HANDOFF_IDENTITY_CREATED[$i]}
    if backlog_key_section "$target_backlog" "$task" >/dev/null 2>&1 \
      && local_target_backlog_action "$target_home" complete "$task" "$payload"; then
      if local_target_handoff_action "$target_home" commit "$task" "$payload" \
        && source_handoff_action complete "$task" "$payload"; then
        :
      else
        failed=1
      fi
    elif [ "$created" = true ]; then
      set +e
      local_target_handoff_action "$target_home" abort "$task" "$payload"
      rc=$?
      set -e
      case "$rc" in
        0) source_handoff_action cancel "$task" "$payload" || failed=1 ;;
        4) source_handoff_action complete "$task" "$payload" || failed=1 ;;
        *) failed=1 ;;
      esac
    else
      preserved=1
    fi
    i=$((i + 1))
  done
  [ "$failed" -eq 0 ] && [ "$preserved" -eq 0 ]
}

stage_local_handoff_identities() { # <target-home> <target-home-id> <target-backlog> <task-id>...
  local target_home=$1 target_home_id=$2 target_backlog=$3 task i=0
  shift 3
  HANDOFF_IDENTITY_TASKS=()
  HANDOFF_IDENTITY_PAYLOADS=()
  HANDOFF_IDENTITY_CREATED=()
  [ "$#" -eq "${#HANDOFF_IDENTITY_BACKLOG_HASHES[@]}" ] || return 1
  for task in "$@"; do
    if ! prepare_handoff_identity "$task" "$target_home" "$target_home_id" \
      "${HANDOFF_IDENTITY_BACKLOG_HASHES[$i]}"; then
      rollback_local_handoff_identities "$target_home" "$target_backlog" || true
      return 1
    fi
    HANDOFF_IDENTITY_TASKS+=("$task")
    HANDOFF_IDENTITY_PAYLOADS+=("$HANDOFF_IDENTITY_PAYLOAD")
    HANDOFF_IDENTITY_CREATED+=("$HANDOFF_IDENTITY_WAS_CREATED")
    if ! local_target_handoff_action "$target_home" stage "$task" "$HANDOFF_IDENTITY_PAYLOAD"; then
      rollback_local_handoff_identities "$target_home" "$target_backlog" || true
      return 1
    fi
    i=$((i + 1))
  done
}

abort_local_handoff_identities() { # <target-home>
  local target_home=$1 i=0 task payload created rc failed=0 preserved=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    created=${HANDOFF_IDENTITY_CREATED[$i]}
    if [ "$created" = true ]; then
      set +e
      local_target_handoff_action "$target_home" abort "$task" "$payload"
      rc=$?
      set -e
      case "$rc" in
        0) source_handoff_action cancel "$task" "$payload" || failed=1 ;;
        4) source_handoff_action complete "$task" "$payload" || failed=1 ;;
        *) failed=1 ;;
      esac
    else
      preserved=1
    fi
    i=$((i + 1))
  done
  [ "$failed" -eq 0 ] && [ "$preserved" -eq 0 ]
}

abort_remote_handoff_identities() { # <secondmate-id>
  local id=$1 i=0 task payload created rc failed=0 preserved=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    created=${HANDOFF_IDENTITY_CREATED[$i]}
    if [ "$created" = true ]; then
      set +e
      remote_target_handoff_action "$id" abort "$task" "$payload"
      rc=$?
      set -e
      case "$rc" in
        0) source_handoff_action cancel "$task" "$payload" || failed=1 ;;
        4) source_handoff_action complete "$task" "$payload" || failed=1 ;;
        *) failed=1 ;;
      esac
    else
      preserved=1
    fi
    i=$((i + 1))
  done
  [ "$failed" -eq 0 ] && [ "$preserved" -eq 0 ]
}

rollback_remote_handoff_identities() { # <secondmate-id> <outbox>
  local id=$1 outbox=$2 i task payload created rc failed=0 preserved=0
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    created=${HANDOFF_IDENTITY_CREATED[$i]}
    if backlog_key_section "$outbox" "$task" >/dev/null 2>&1; then
      preserved=1
    elif [ "$created" = true ]; then
      set +e
      remote_target_handoff_action "$id" abort "$task" "$payload"
      rc=$?
      set -e
      case "$rc" in
        0) source_handoff_action cancel "$task" "$payload" || failed=1 ;;
        4) source_handoff_action complete "$task" "$payload" || failed=1 ;;
        *) failed=1 ;;
      esac
    else
      preserved=1
    fi
    i=$((i + 1))
  done
  [ "$failed" -eq 0 ] && [ "$preserved" -eq 0 ]
}

reconcile_remote_handoff_identities() { # <secondmate-id> <outbox>
  local id=$1 outbox=$2 i task payload created target_state state_rc failed=0 preserved=0
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    created=${HANDOFF_IDENTITY_CREATED[$i]}
    if [ "$created" = true ] && ! backlog_key_section "$outbox" "$task" >/dev/null 2>&1; then
      source_handoff_action cancel "$task" "$payload" || failed=1
      i=$((i + 1))
      continue
    fi
    set +e
    target_state=$(remote_target_handoff_state "$id" "$task" "$payload" 2>/dev/null)
    state_rc=$?
    set -e
    if [ "$state_rc" -ne 0 ]; then
      preserved=1
    elif [ "$target_state" = completed ]; then
      source_handoff_action complete "$task" "$payload" || failed=1
    elif [ "$target_state" = prepared ] || [ "$target_state" = absent ]; then
      preserved=1
    else
      failed=1
    fi
    i=$((i + 1))
  done
  [ "$failed" -eq 0 ] && [ "$preserved" -eq 0 ]
}

prepare_remote_handoff_identities() { # <secondmate-id> <target-home> <target-home-id> <outbox> <task-id>...
  local id=$1 target_home=$2 target_home_id=$3 outbox=$4 task i=0
  shift 4
  HANDOFF_IDENTITY_TASKS=()
  HANDOFF_IDENTITY_PAYLOADS=()
  HANDOFF_IDENTITY_CREATED=()
  [ "$#" -eq "${#HANDOFF_IDENTITY_BACKLOG_HASHES[@]}" ] || return 1
  for task in "$@"; do
    if ! prepare_handoff_identity "$task" "$target_home" "$target_home_id" \
      "${HANDOFF_IDENTITY_BACKLOG_HASHES[$i]}"; then
      reconcile_remote_handoff_identities "$id" "$outbox" || true
      return 1
    fi
    HANDOFF_IDENTITY_TASKS+=("$task")
    HANDOFF_IDENTITY_PAYLOADS+=("$HANDOFF_IDENTITY_PAYLOAD")
    HANDOFF_IDENTITY_CREATED+=("$HANDOFF_IDENTITY_WAS_CREATED")
    i=$((i + 1))
  done
}

stage_prepared_remote_handoff_identities() { # <secondmate-id>
  local id=$1 i task payload
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    remote_target_handoff_action "$id" stage "$task" "$payload" || return 1
    i=$((i + 1))
  done
}

stage_remote_handoff_identities() { # <secondmate-id> <target-home> <target-home-id> <outbox> <task-id>...
  local id=$1 target_home=$2 target_home_id=$3 outbox=$4
  shift 4
  prepare_remote_handoff_identities "$id" "$target_home" "$target_home_id" "$outbox" "$@" || return 1
  stage_prepared_remote_handoff_identities "$id"
}

commit_local_handoff_identities() { # <target-home>
  local target_home=$1 i task payload
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    local_target_handoff_action "$target_home" commit "$task" "$payload" || return 1
    i=$((i + 1))
  done
}

commit_remote_handoff_identities() { # <secondmate-id>
  local id=$1 i task payload
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    remote_target_handoff_action "$id" commit "$task" "$payload" || return 1
    i=$((i + 1))
  done
}

complete_source_handoff_identities() {
  local i task payload
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    payload=${HANDOFF_IDENTITY_PAYLOADS[$i]}
    source_handoff_action complete "$task" "$payload" || return 1
    i=$((i + 1))
  done
}

remote_deliver_outbox() { # <secondmate-id> <outbox-path>
  local id=$1 outbox=$2 remote_rel receive_out snapshot bytes hash generation counter counter_tmp current
  local i task prepared_hash
  [ "$ACTIVE_OUTBOX_PATH" = "$outbox" ] || {
    echo "error: pending outbox identity changed before delivery: $outbox" >&2
    return 1
  }
  [ -f "$outbox" ] && [ ! -L "$outbox" ] || {
    echo "error: pending outbox is unavailable or unsafe: $outbox" >&2
    return 1
  }
  snapshot=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-handoff-payload.XXXXXX") || return 1
  if ! python3 "$FS_OWNER" snapshot "$(dirname "$outbox")" \
    "$ACTIVE_OUTBOX_PARENT_INODE" "$(basename "$outbox")" \
    "$ACTIVE_OUTBOX_STATE" "$ACTIVE_OUTBOX_HASH" > "$snapshot"; then
    rm -f -- "$snapshot"
    return 1
  fi
  bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
  hash=$(sha256_file "$snapshot") || { rm -f -- "$snapshot"; return 1; }
  [ "$hash" = "$ACTIVE_OUTBOX_HASH" ] || { rm -f -- "$snapshot"; return 1; }
  if ! load_tasks_axi_queued_ids "$snapshot" \
    || ! task_sets_match HANDOFF_IDENTITY_TASKS TASKS_AXI_BACKLOG_IDS; then
    rm -f -- "$snapshot"
    echo "error: pending outbox snapshot does not match its prepared identity set: $outbox" >&2
    return 1
  fi
  i=0
  while [ "$i" -lt "${#HANDOFF_IDENTITY_TASKS[@]}" ]; do
    task=${HANDOFF_IDENTITY_TASKS[$i]}
    prepared_hash=${HANDOFF_IDENTITY_BACKLOG_HASHES[$i]}
    [ "$(backlog_task_sha256 "$snapshot" "$task")" = "$prepared_hash" ] || {
      rm -f -- "$snapshot"
      echo "error: pending outbox snapshot changed after identity preparation for $task" >&2
      return 1
    }
    i=$((i + 1))
  done
  counter="$STATE/.remote-handoff-$id.generation"
  current=0
  if [ -e "$counter" ] || [ -L "$counter" ]; then
    [ -f "$counter" ] && [ ! -L "$counter" ] || { rm -f -- "$snapshot"; return 1; }
    IFS= read -r current < "$counter" || { rm -f -- "$snapshot"; return 1; }
    case "$current" in ''|*[!0-9]*) rm -f -- "$snapshot"; return 1 ;; esac
    [ "${#current}" -le 17 ] || { rm -f -- "$snapshot"; return 1; }
  fi
  generation=$((current + 1))
  counter_tmp=$(umask 077; mktemp "$STATE/.remote-handoff-generation.XXXXXX") \
    || { rm -f -- "$snapshot"; return 1; }
  printf '%s\n' "$generation" > "$counter_tmp" \
    || { rm -f -- "$snapshot" "$counter_tmp"; return 1; }
  chmod 600 "$counter_tmp" \
    || { rm -f -- "$snapshot" "$counter_tmp"; return 1; }
  mv -f -- "$counter_tmp" "$counter" \
    || { rm -f -- "$snapshot" "$counter_tmp"; return 1; }
  remote_rel="state/handoff/$id.outbox.md"
  if ! "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-remote-file.sh put "$remote_rel" 1048576 \
    "$bytes" "$hash" "$generation" < "$snapshot"; then
    rm -f -- "$snapshot"
    echo "error: handoff transfer to $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  rm -f -- "$snapshot"
  if ! receive_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-backlog-receive.sh \
    "$remote_rel" "$bytes" "$hash" "$generation" < /dev/null 2>&1); then
    [ -z "$receive_out" ] || printf '%s\n' "$receive_out" >&2
    echo "error: handoff receipt by $id was unavailable or completion is unknown; outbox preserved at $outbox" >&2
    return 1
  fi
  printf '%s\n' "$receive_out"
}

finish_remote_handoff() { # <secondmate-id> <outbox-path>
  local id=$1 outbox=$2 marker="$STATE/.backlog-handoff-$1.wake-pending"
  commit_remote_handoff_identities "$id" || {
    echo "error: remote backlog arrived but exact work identity commit is incomplete; outbox preserved at $outbox" >&2
    return 1
  }
  complete_source_handoff_identities || {
    echo "error: remote work identity arrived but source ownership completion is incomplete; outbox preserved at $outbox" >&2
    return 1
  }
  case "$(cat "$marker" 2>/dev/null || true)" in
    pending:*|confirmed|confirmed:*) ;;
    *) receiver_wake_mark_pending "$id" || {
      echo "error: remote backlog and identity are durable at $id, but receiver wake state could not be recorded; outbox preserved at $outbox" >&2
      return 1
    } ;;
  esac
  if ! wake_pending_secondmate_receiver "$id" 1; then
    echo "error: remote backlog and identity are durable at $id; outbox preserved at $outbox for wake retry" >&2
    return 1
  fi
  if [ "$ACTIVE_OUTBOX_PATH" != "$outbox" ] \
    || ! remove_owned_backlog_file "$outbox" "$ACTIVE_OUTBOX_PARENT_INODE" \
      "$ACTIVE_OUTBOX_FILE_INODE" "$ACTIVE_OUTBOX_HASH"; then
    echo "error: remote receipt, identity commit, and receiver wake were confirmed but local outbox cleanup failed safely: $outbox" >&2
    return 1
  fi
  rm -f -- "$marker" || {
    echo "error: remote outbox cleanup succeeded but confirmed receiver wake state could not be cleared: $marker" >&2
    return 1
  }
}

remove_interrupted_source_duplicates() { # <outbox> <keys...>
  local outbox=$1 key source_hash target_hash source_details source_state source_digest
  local target_details target_state target_digest reconcile_out source_snapshot target_snapshot
  local source_dir source_base source_inode target_dir target_base target_inode
  local -a duplicates
  shift
  source_snapshot=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-handoff-source.XXXXXX") || return 1
  target_snapshot=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-handoff-target.XXXXXX") \
    || { rm -f -- "$source_snapshot"; return 1; }
  source_dir=$(dirname "$MAIN_BACKLOG")
  source_base=$(basename "$MAIN_BACKLOG")
  source_inode=$(backlog_file_inode "$source_dir") \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  source_details=$(python3 "$FS_OWNER" describe-digest \
    "$source_dir" "$source_inode" "$source_base") \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  source_state=${source_details%%$'\t'*}
  source_digest=${source_details#*$'\t'}
  [ "$source_state" != "$source_details" ] \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  python3 "$FS_OWNER" snapshot "$source_dir" "$source_inode" "$source_base" \
    "$source_state" "$source_digest" > "$source_snapshot" \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  target_dir=$(dirname "$outbox")
  target_base=$(basename "$outbox")
  target_inode=$(backlog_file_inode "$target_dir") \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  target_details=$(python3 "$FS_OWNER" describe-digest \
    "$target_dir" "$target_inode" "$target_base") \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  target_state=${target_details%%$'\t'*}
  target_digest=${target_details#*$'\t'}
  [ "$target_state" != "$target_details" ] \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  python3 "$FS_OWNER" snapshot "$target_dir" "$target_inode" "$target_base" \
    "$target_state" "$target_digest" > "$target_snapshot" \
    || { rm -f -- "$source_snapshot" "$target_snapshot"; return 1; }
  duplicates=()
  for key in "$@"; do
    backlog_key_section "$target_snapshot" "$key" >/dev/null 2>&1 || continue
    if backlog_key_section "$source_snapshot" "$key" >/dev/null 2>&1; then
      source_hash=$(backlog_task_sha256 "$source_snapshot" "$key") || {
        rm -f -- "$source_snapshot" "$target_snapshot"
        echo "error: refusing interrupted source removal for $key: source row is not Queued" >&2
        return 1
      }
      target_hash=$(backlog_task_sha256 "$target_snapshot" "$key") || {
        rm -f -- "$source_snapshot" "$target_snapshot"
        return 1
      }
      [ "$source_hash" = "$target_hash" ] || {
        rm -f -- "$source_snapshot" "$target_snapshot"
        echo "error: refusing interrupted source removal for $key: source and destination content differ" >&2
        return 1
      }
      duplicates+=("$key")
    fi
  done
  if [ "${#duplicates[@]}" -eq 0 ]; then
    rm -f -- "$source_snapshot" "$target_snapshot"
    return 0
  fi
  fm_tasks_axi_rm_has_peer_revision_cas || {
    rm -f -- "$source_snapshot" "$target_snapshot"
    echo "error: tasks-axi lacks peer-revision CAS required for interrupted handoff reconciliation" >&2
    return 1
  }
  if ! reconcile_out=$(tasks-axi rm "${duplicates[@]}" --file "$MAIN_BACKLOG" \
    --if-source-sha256 "$source_digest" --if-peer "$outbox" \
    --if-peer-sha256 "$target_digest" --json 2>&1); then
    rm -f -- "$source_snapshot" "$target_snapshot"
    [ -z "$reconcile_out" ] || printf '%s\n' "$reconcile_out" >&2
    echo "error: source or destination backlog changed during interrupted handoff reconciliation; no stale row was removed" >&2
    return 1
  fi
  rm -f -- "$source_snapshot" "$target_snapshot"
  for key in "${duplicates[@]}"; do
    backlog_key_section "$MAIN_BACKLOG" "$key" >/dev/null 2>&1 || continue
    echo "error: tasks-axi peer-revision reconciliation retained source row $key" >&2
    return 1
  done
}

remote_handoff() { # <secondmate-id> <keys...>
  local id=$1 outbox section main_section out_section key mv_out target_home persisted
  local home_real data_parent data_parent_real data_base data_expected
  local data_info data_real data_inode handoff_info handoff_dir handoff_inode
  local -a requested unique_requested to_move already missing in_flight done_items not_queued conflicting delivery_keys
  shift
  requested=("$@")
  unique_requested=()
  for key in "${requested[@]}"; do
    task_array_contains "$key" "${unique_requested[@]}" || unique_requested+=("$key")
  done
  requested=("${unique_requested[@]}")
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || {
    echo "error: active data directory is unsafe: $DATA" >&2
    return 1
  }
  home_real=$(cd -P "$FM_HOME" && pwd -P) || return 1
  data_parent=$(dirname "$DATA")
  data_base=$(basename "$DATA")
  case "$data_base" in ''|.|..|*/*) return 1 ;; esac
  data_parent_real=$(cd -P "$data_parent" && pwd -P) || return 1
  data_expected="$data_parent_real/$data_base"
  data_info=$(cd -P "$DATA" && printf '%s\t%s\n' "$(pwd -P)" "$(backlog_file_inode .)") || return 1
  data_real=${data_info%%$'\t'*}
  data_inode=${data_info#*$'\t'}
  [ "$data_real" = "$data_expected" ] || {
    echo "error: active data directory changed while it was being anchored: $DATA" >&2
    return 1
  }
  case "$data_real" in "$home_real"/*) ;; *)
    echo "error: active data directory resolves outside its firstmate home: $DATA" >&2
    return 1 ;;
  esac
  handoff_info=$(safe_child_dir "$data_real" "$data_inode" handoff) || {
    echo "error: remote handoff directory could not be anchored safely" >&2
    return 1
  }
  handoff_dir=${handoff_info%%$'\t'*}
  handoff_inode=${handoff_info#*$'\t'}
  outbox="$handoff_dir/$id.outbox.md"
  recover_backlog_scaffold_publication "$outbox" "$handoff_inode" || return 1
  validate_backlog_file "main backlog" "$MAIN_BACKLOG" || return 1
  validate_backlog_file "remote handoff outbox" "$outbox" || return 1
  if [ ! -e "$outbox" ] && [ ! -L "$outbox" ]; then
    receiver_wake_clear_confirmed "$id" || {
      echo "error: stale receiver wake state for secondmate $id could not be cleared" >&2
      return 1
    }
  fi
  fm_tasks_axi_handoff_compatible || {
    echo "error: a compatible tasks-axi with revision-checked atomic multi-ID mv support is required to stage remote handoffs; run bin/fm-bootstrap.sh for the required version" >&2
    return 1
  }
  to_move=()
  already=()
  missing=()
  in_flight=()
  done_items=()
  not_queued=()
  conflicting=()
  for key in "${requested[@]}"; do
    out_section=$(backlog_key_section "$outbox" "$key" 2>/dev/null || true)
    main_section=$(backlog_key_section "$MAIN_BACKLOG" "$key" 2>/dev/null || true)
    if [ -n "$out_section" ]; then
      if [ "$out_section" != '## Queued' ] || { [ -n "$main_section" ] && [ "$main_section" != '## Queued' ]; }; then
        not_queued+=("$key")
      elif [ -n "$main_section" ] \
        && [ "$(backlog_task_sha256 "$MAIN_BACKLOG" "$key")" != "$(backlog_task_sha256 "$outbox" "$key")" ]; then
        conflicting+=("$key")
      else
        already+=("$key")
      fi
      continue
    fi
    case "$main_section" in
      '## Queued') to_move+=("$key") ;;
      '## In flight') in_flight+=("$key") ;;
      '## Done') done_items+=("$key") ;;
      '') missing+=("$key") ;;
      *) not_queued+=("$key") ;;
    esac
  done
  if [ "${#in_flight[@]}" -gt 0 ] || [ "${#done_items[@]}" -gt 0 ] \
    || [ "${#not_queued[@]}" -gt 0 ] || [ "${#conflicting[@]}" -gt 0 ] \
    || [ "${#missing[@]}" -gt 0 ]; then
    [ "${#in_flight[@]}" -eq 0 ] || echo "error: refusing to hand off in-flight backlog items: ${in_flight[*]}" >&2
    [ "${#done_items[@]}" -eq 0 ] || echo "error: refusing to hand off Done backlog items: ${done_items[*]}" >&2
    [ "${#not_queued[@]}" -eq 0 ] || echo "error: refusing to hand off non-Queued outbox or backlog items: ${not_queued[*]}" >&2
    [ "${#conflicting[@]}" -eq 0 ] || echo "error: refusing same-ID source and outbox rows with different content: ${conflicting[*]}" >&2
    [ "${#missing[@]}" -eq 0 ] || echo "error: no backlog or pending outbox item matched: ${missing[*]}" >&2
    echo "       nothing new was staged." >&2
    return 1
  fi
  for key in "${to_move[@]}"; do
    while IFS= read -r line; do
      printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' "$key" "$line" >&2
      return 1
    done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
  done
  # A wake already attempted for an older recovery batch must settle before new
  # work joins it; otherwise the old confirmation could suppress the new wake.
  # Before any wake exists, one immutable prepared identity set may safely cover
  # the existing outbox plus fresh rows and deliver them together.
  if [ "${#to_move[@]}" -gt 0 ] && [ -f "$outbox" ] \
    && [ "$(outbox_item_count "$outbox")" -gt 0 ] \
    && { [ -e "$STATE/.backlog-handoff-$id.wake-pending" ] \
         || [ -L "$STATE/.backlog-handoff-$id.wake-pending" ]; }; then
    resume_remote_outbox "$id" "$outbox" "$handoff_inode" || {
      echo "error: previous remote handoff for secondmate $id could not be completed; nothing new was staged" >&2
      return 1
    }
  fi
  target_home=$(secondmate_registry_field "$REG" "$id" home 2>/dev/null || true)
  [ -n "$target_home" ] || {
    echo "error: remote secondmate $id has no target home for work identity handoff" >&2
    return 1
  }
  resolve_tasks_axi_move_keys "$MAIN_BACKLOG" "$outbox" "${to_move[@]}" || {
    echo "error: tasks-axi could not resolve the exact remote move set; nothing new was handed off" >&2
    return 1
  }
  for key in "${RESOLVED_MOVE_KEYS[@]}"; do
    while IFS= read -r line; do
      printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' "$key" "$line" >&2
      return 1
    done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
  done
  delivery_keys=()
  if [ -e "$outbox" ] || [ -L "$outbox" ]; then
    load_tasks_axi_queued_ids "$outbox" || {
      echo "error: tasks-axi could not resolve the pending outbox identity set: $outbox" >&2
      return 1
    }
    delivery_keys=("${TASKS_AXI_BACKLOG_IDS[@]}")
  fi
  for key in "${RESOLVED_MOVE_KEYS[@]}"; do
    task_array_contains "$key" "${delivery_keys[@]}" || delivery_keys+=("$key")
  done
  HANDOFF_IDENTITY_BACKLOG_HASHES=()
  for key in "${delivery_keys[@]}"; do
    if backlog_key_section "$outbox" "$key" >/dev/null 2>&1; then
      HANDOFF_IDENTITY_BACKLOG_HASHES+=("$(backlog_task_sha256 "$outbox" "$key")")
    else
      HANDOFF_IDENTITY_BACKLOG_HASHES+=("$(resolved_move_hash "$key")")
    fi
  done
  prepare_remote_handoff_identities "$id" "$target_home" "secondmate:$id" "$outbox" "${delivery_keys[@]}" || {
    echo "error: exact work identity preparation failed; nothing new was handed off" >&2
    return 1
  }
  stage_prepared_remote_handoff_identities "$id" || {
    rollback_remote_handoff_identities "$id" "$outbox" || true
    echo "error: remote exact work identity reservation failed; nothing new was handed off" >&2
    return 1
  }
  prepare_remote_handoff_backlog_receipts "$id" || {
    rollback_remote_handoff_identities "$id" "$outbox" || true
    echo "error: remote exact backlog reservation failed; nothing new was handed off" >&2
    return 1
  }
  if [ "${#to_move[@]}" -gt 0 ] \
     && ! move_plan_inputs_unchanged "$MAIN_BACKLOG" "$outbox"; then
    rollback_remote_handoff_identities "$id" "$outbox" || true
    echo "error: backlog revisions changed after identity preparation; nothing new was handed off" >&2
    return 1
  fi
  if ! seed_backlog_scaffold "$outbox" "$handoff_inode"; then
    abort_remote_handoff_identities "$id" || true
    echo "error: remote handoff outbox scaffold could not be published safely; nothing new was handed off" >&2
    return 1
  fi
  if [ "${#to_move[@]}" -gt 0 ]; then
    if ! mv_out=$(tasks-axi mv "${RESOLVED_MOVE_KEYS[@]}" --file "$MAIN_BACKLOG" --to "$outbox" \
      --if-source-sha256 "$MOVE_PLAN_SOURCE_HASH" --if-target-sha256 "$MOVE_PLAN_TARGET_HASH" \
      --json 2>&1); then
      [ -z "$mv_out" ] || printf '%s\n' "$mv_out" >&2
      persisted=0
      for key in "${RESOLVED_MOVE_KEYS[@]}"; do
        backlog_key_section "$outbox" "$key" >/dev/null 2>&1 && persisted=1
      done
      if [ "$persisted" -eq 1 ]; then
        echo "error: atomic outbox staging completion is uncertain; identity preparation and outbox are preserved" >&2
      elif ! rollback_remote_handoff_identities "$id" "$outbox"; then
        echo "error: atomic outbox staging failed and identity preparation needs recovery" >&2
      else
        echo "error: atomic outbox staging failed; nothing new was handed off" >&2
      fi
      return 1
    fi
    if ! parse_tasks_axi_move_result "$mv_out" \
      || ! task_sets_match RESOLVED_MOVE_KEYS PARSED_MOVE_KEYS; then
      echo "error: tasks-axi moved a different set than its prepared transaction; outbox preserved at $outbox" >&2
      return 1
    fi
  fi
  # Read indirectly by task_sets_match after its array-name validation.
  # shellcheck disable=SC2034
  DELIVERY_KEYS=("${delivery_keys[@]}")
  if ! load_tasks_axi_queued_ids "$outbox" \
    || ! task_sets_match DELIVERY_KEYS TASKS_AXI_BACKLOG_IDS; then
    echo "error: pending outbox changed outside the prepared identity set; outbox preserved at $outbox" >&2
    return 1
  fi
  # A hard local kill can land tasks-axi's target persist before its source
  # persist. The outbox is already authoritative in that state, so converge by
  # deleting only duplicates that tasks-axi itself confirms are dependency-safe.
  remove_interrupted_source_duplicates "$outbox" "${delivery_keys[@]}" || return 1
  prepare_outbox_retirement "$outbox" "$handoff_inode" || {
    echo "error: pending outbox became unsafe before delivery: $outbox" >&2
    return 1
  }
  remote_deliver_outbox "$id" "$outbox" || return 1
  finish_remote_handoff "$id" "$outbox" || return 1
  echo "handed off ${#requested[@]} item(s) to remote secondmate $id: ${requested[*]}"
  [ "${#already[@]}" -eq 0 ] || echo "  already staged (recovered): ${already[*]}"
  warn_stale_public_commitments "$id" "${delivery_keys[@]}"
}

with_remote_route_locks() { # <secondmate-id> <function> <args...>
  local id=$1 operation=$2 rc
  shift 2
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: unsafe remote handoff id: $id" >&2; return 1 ;; esac
  ACTIVE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
  if [ "$(secondmate_registry_field "$REG" "$id" remote 2>/dev/null || true)" != 1 ]; then
    echo "error: pending outbox has no matching remote secondmate route: $id" >&2
    release_remote_locks
    return 1
  fi
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$id.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  ACTIVE_BACKLOG_LOCK="$STATE/.backlog-mutation.lock"
  fm_lock_acquire_wait "$ACTIVE_BACKLOG_LOCK"
  if "$operation" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  return "$rc"
}

resume_remote_outbox() { # <secondmate-id> <outbox-path> <handoff-dir-inode>
  local id=$1 outbox=$2 handoff_inode=$3 target_home key
  local -a keys
  [ -e "$outbox" ] || [ -L "$outbox" ] || return 0
  if ! prepare_outbox_retirement "$outbox" "$handoff_inode"; then
    echo "error: unsafe pending handoff outbox: $outbox" >&2
    return 1
  fi
  target_home=$(secondmate_registry_field "$REG" "$id" home 2>/dev/null || true)
  [ -n "$target_home" ] || {
    echo "error: pending outbox has no target home for work identity handoff: $id" >&2
    return 1
  }
  fm_tasks_axi_compatible || {
    echo "error: a compatible tasks-axi is required to resolve pending handoff identities" >&2
    return 1
  }
  load_tasks_axi_queued_ids "$outbox" || {
    echo "error: tasks-axi could not resolve the pending outbox identity set: $outbox" >&2
    return 1
  }
  keys=("${TASKS_AXI_BACKLOG_IDS[@]}")
  HANDOFF_IDENTITY_BACKLOG_HASHES=()
  for key in "${keys[@]}"; do
    HANDOFF_IDENTITY_BACKLOG_HASHES+=("$(backlog_task_sha256 "$outbox" "$key")")
  done
  stage_remote_handoff_identities "$id" "$target_home" "secondmate:$id" "$outbox" "${keys[@]}" || {
    echo "error: pending exact work identity staging failed; outbox preserved at $outbox" >&2
    return 1
  }
  prepare_remote_handoff_backlog_receipts "$id" || {
    echo "error: pending exact backlog staging failed; outbox preserved at $outbox" >&2
    return 1
  }
  remove_interrupted_source_duplicates "$outbox" "${keys[@]}" || return 1
  prepare_outbox_retirement "$outbox" "$handoff_inode" || {
    echo "error: pending outbox became unsafe before resumed delivery: $outbox" >&2
    return 1
  }
  remote_deliver_outbox "$id" "$outbox" || return 1
  finish_remote_handoff "$id" "$outbox"
}

resume_pending_outboxes() {
  local outbox id failed=0 handoff_info handoff_dir handoff_inode rc
  set +e
  handoff_info=$(anchor_existing_handoff_dir)
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) echo "error: pending handoff directory is unsafe: $DATA/handoff" >&2; return 1 ;;
  esac
  handoff_dir=${handoff_info%%$'\t'*}
  handoff_inode=${handoff_info#*$'\t'}
  for outbox in "$handoff_dir"/*.outbox.md; do
    [ -e "$outbox" ] || [ -L "$outbox" ] || continue
    id=$(basename "$outbox" .outbox.md)
    case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: unsafe pending handoff id: $id" >&2; failed=1; continue ;; esac
    with_remote_route_locks "$id" resume_remote_outbox "$id" "$outbox" "$handoff_inode" || failed=1
  done
  return "$failed"
}

if [ "$RESUME_PENDING" -eq 1 ]; then
  resume_pending_outboxes
  exit $?
fi

ACTIVE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
fm_lock_acquire_wait "$ACTIVE_REGISTRY_LOCK"
REMOTE=$(secondmate_registry_field "$REG" "$ID" remote 2>/dev/null || true)
if [ "$REMOTE" = 1 ]; then
  ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
  ACTIVE_BACKLOG_LOCK="$STATE/.backlog-mutation.lock"
  fm_lock_acquire_wait "$ACTIVE_BACKLOG_LOCK"
  if remote_handoff "$ID" "$@"; then rc=0; else rc=$?; fi
  release_remote_locks
  exit "$rc"
fi
ACTIVE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
fm_lock_acquire_wait "$ACTIVE_HANDOFF_LOCK"
fm_lock_release "$ACTIVE_REGISTRY_LOCK"
ACTIVE_REGISTRY_LOCK=

ACTIVE_BACKLOG_LOCK="$STATE/.backlog-mutation.lock"
fm_lock_acquire_wait "$ACTIVE_BACKLOG_LOCK"

RAW_HOME=$(secondmate_home "$ID") || exit 1
[ -n "$RAW_HOME" ] || { echo "error: secondmate $ID has no home in $REG" >&2; exit 1; }
SUB_HOME_INFO=$(validate_secondmate_home "$ID" "$RAW_HOME") || exit 1
SUB_HOME=${SUB_HOME_INFO%%$'\t'*}
SUB_HOME_INODE=${SUB_HOME_INFO#*$'\t'}
SUB_DATA_INFO=$(safe_child_dir "$SUB_HOME" "$SUB_HOME_INODE" data) \
  || { echo "error: could not anchor destination data directory" >&2; exit 1; }
SUB_DATA_DIR=${SUB_DATA_INFO%%$'\t'*}
SUB_DATA_INODE=${SUB_DATA_INFO#*$'\t'}
SUB_STATE_INFO=$(safe_child_dir "$SUB_HOME" "$SUB_HOME_INODE" state) \
  || { echo "error: could not anchor destination mutation-lock directory" >&2; exit 1; }
SUB_STATE_DIR=${SUB_STATE_INFO%%$'\t'*}
SUB_BACKLOG="$SUB_DATA_DIR/backlog.md"
ACTIVE_TARGET_BACKLOG_LOCK="$SUB_STATE_DIR/.backlog-mutation.lock"
fm_lock_acquire_wait "$ACTIVE_TARGET_BACKLOG_LOCK"
recover_backlog_scaffold_publication "$SUB_BACKLOG" "$SUB_DATA_INODE" || exit 1
validate_backlog_file "main backlog" "$MAIN_BACKLOG" || exit 1
validate_backlog_file "secondmate backlog" "$SUB_BACKLOG" || exit 1

# Classify every key before changing anything: move-from-main, already-in-sub, or
# missing. Abort with no changes if any key matches neither backlog.
TO_MOVE=()
ALREADY=()
MISSING=()
IN_FLIGHT=()
DONE=()
NOT_QUEUED=()
CONFLICTING=()
for key in "$@"; do
  if section=$(backlog_key_section "$SUB_BACKLOG" "$key"); then
    source_section=$(backlog_key_section "$MAIN_BACKLOG" "$key" 2>/dev/null || true)
    if [ "$section" != "## Queued" ] || { [ -n "$source_section" ] && [ "$source_section" != "## Queued" ]; }; then
      NOT_QUEUED+=("$key")
    elif [ -n "$source_section" ] \
      && [ "$(backlog_task_sha256 "$MAIN_BACKLOG" "$key")" != "$(backlog_task_sha256 "$SUB_BACKLOG" "$key")" ]; then
      CONFLICTING+=("$key")
    else
      ALREADY+=("$key")
    fi
  elif section=$(backlog_key_section "$MAIN_BACKLOG" "$key"); then
    case "$section" in
      "## Queued") TO_MOVE+=("$key") ;;
      "## In flight") IN_FLIGHT+=("$key") ;;
      "## Done") DONE+=("$key") ;;
      *) NOT_QUEUED+=("$key") ;;
    esac
  else
    MISSING+=("$key")
  fi
done

FAILED=0
if [ "${#IN_FLIGHT[@]}" -gt 0 ]; then
  echo "error: refusing to hand off in-flight backlog items: ${IN_FLIGHT[*]}" >&2
  FAILED=1
fi
if [ "${#DONE[@]}" -gt 0 ]; then
  echo "error: refusing to hand off Done (historical) backlog items: ${DONE[*]}; handoffs move in-scope queued work only - Done records stay with their home and are pruned/archived." >&2
  FAILED=1
fi
if [ "${#NOT_QUEUED[@]}" -gt 0 ]; then
  echo "error: refusing to hand off non-queued backlog items: ${NOT_QUEUED[*]}; handoffs move in-scope queued work only." >&2
  FAILED=1
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: no backlog item matched these keys in $MAIN_BACKLOG: ${MISSING[*]}" >&2
  FAILED=1
fi
if [ "${#CONFLICTING[@]}" -gt 0 ]; then
  echo "error: refusing same-ID source and destination rows with different content: ${CONFLICTING[*]}" >&2
  FAILED=1
fi
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

REQUESTED_BATCH=$(receiver_wake_batch_id "$@") || {
  echo "error: receiver wake batch identity could not be recorded; nothing was moved" >&2
  exit 1
}

FAILED=0
for key in "${TO_MOVE[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    FAILED=1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
if [ "$FAILED" -ne 0 ]; then
  echo "       nothing was moved." >&2
  exit 1
fi

if [ "${#TO_MOVE[@]}" -gt 0 ] && ! fm_tasks_axi_handoff_compatible; then
  echo "error: a compatible tasks-axi with revision-checked atomic multi-ID mv support is required to move backlog items; run bin/fm-bootstrap.sh for the required version" >&2
  exit 1
fi

WAKE_PENDING_MARKER="$STATE/.backlog-handoff-$ID.wake-pending"
if [ -e "$WAKE_PENDING_MARKER" ] || [ -L "$WAKE_PENDING_MARKER" ]; then
  case "$(cat "$WAKE_PENDING_MARKER" 2>/dev/null || true)" in
    prepared:*:"$REQUESTED_BATCH")
      [ "${#TO_MOVE[@]}" -eq 0 ] || receiver_wake_discard_prepared "$ID" || exit 1
      ;;
    prepared:*)
      echo "error: a prepared receiver wake for secondmate $ID belongs to a different routed batch; retry that original handoff before handling ${ALREADY[*]}${TO_MOVE[*]}" >&2
      exit 1
      ;;
    *)
      wake_pending_secondmate_receiver "$ID" || {
        echo "error: previous receiver wake for secondmate $ID is unresolved; nothing new was moved" >&2
        exit 1
      }
      ;;
  esac
fi
resolve_tasks_axi_move_keys "$MAIN_BACKLOG" "$SUB_BACKLOG" "${TO_MOVE[@]}" || {
  echo "error: tasks-axi could not resolve the exact move set; nothing was moved." >&2
  exit 1
}
for key in "${RESOLVED_MOVE_KEYS[@]}"; do
  while IFS= read -r line; do
    printf 'error: refusing to hand off %s: non-2-space continuation line: %s\n' \
      "$key" "$line" >&2
    exit 1
  done < <(backlog_key_noncanonical_body_lines "$MAIN_BACKLOG" "$key")
done
LOCAL_IDENTITY_KEYS=()
HANDOFF_IDENTITY_BACKLOG_HASHES=()
for key in "${ALREADY[@]}" "${RESOLVED_MOVE_KEYS[@]}"; do
  task_array_contains "$key" "${LOCAL_IDENTITY_KEYS[@]}" && continue
  LOCAL_IDENTITY_KEYS+=("$key")
  if task_array_contains "$key" "${RESOLVED_MOVE_KEYS[@]}"; then
    HANDOFF_IDENTITY_BACKLOG_HASHES+=("$(resolved_move_hash "$key")")
  else
    HANDOFF_IDENTITY_BACKLOG_HASHES+=("$(backlog_task_sha256 "$SUB_BACKLOG" "$key")")
  fi
done
stage_local_handoff_identities "$SUB_HOME" "secondmate:$ID" "$SUB_BACKLOG" "${LOCAL_IDENTITY_KEYS[@]}" || {
  echo "error: exact work identity preparation failed; nothing was moved." >&2
  exit 1
}
prepare_local_handoff_backlog_receipts "$SUB_HOME" || {
  rollback_local_handoff_identities "$SUB_HOME" "$SUB_BACKLOG" || true
  echo "error: exact destination backlog reservation failed; nothing was moved." >&2
  exit 1
}

if [ "${#TO_MOVE[@]}" -eq 0 ]; then
  complete_local_handoff_backlog_receipts "$SUB_HOME" || {
    echo "error: existing destination row does not match its exact handoff receipt." >&2
    exit 1
  }
  remove_interrupted_source_duplicates "$SUB_BACKLOG" "${LOCAL_IDENTITY_KEYS[@]}" || exit 1
  commit_local_handoff_identities "$SUB_HOME" || {
    echo "error: backlog is already present but exact work identity commit is incomplete." >&2
    exit 1
  }
  complete_source_handoff_identities || {
    echo "error: destination identity is committed but source ownership completion is incomplete." >&2
    exit 1
  }
  case "$(cat "$WAKE_PENDING_MARKER" 2>/dev/null || true)" in
    prepared:*:"$REQUESTED_BATCH") receiver_wake_promote_prepared "$ID" "$REQUESTED_BATCH" || exit 1 ;;
  esac
  echo "nothing to move: ${ALREADY[*]:-no keys} already present in $SUB_BACKLOG"
  wake_pending_secondmate_receiver "$ID" || exit 1
  exit 0
fi

if ! move_plan_inputs_unchanged "$MAIN_BACKLOG" "$SUB_BACKLOG"; then
  rollback_local_handoff_identities "$SUB_HOME" "$SUB_BACKLOG" || true
  echo "error: backlog revisions changed after identity preparation; nothing was moved." >&2
  exit 1
fi
receiver_wake_mark_prepared "$ID" "$REQUESTED_BATCH" || {
  rollback_local_handoff_identities "$SUB_HOME" "$SUB_BACKLOG" || true
  echo "error: receiver wake state for secondmate $ID could not be recorded; nothing was moved" >&2
  exit 1
}
# Seed the destination with firstmate's standard three-section scaffold when it
# does not exist yet, so the moved item lands under the right section. (Left to
# create the file itself, tasks-axi mv writes its own `# Backlog` title format,
# which is not firstmate's home-backlog convention.)
SUB_CREATED_INODE=
if ! SUB_CREATED_INODE=$(seed_backlog_scaffold "$SUB_BACKLOG" "$SUB_DATA_INODE" report-created); then
  abort_local_handoff_identities "$SUB_HOME" || true
  echo "error: destination backlog scaffold could not be published safely; nothing was moved." >&2
  exit 1
fi

# Delegate the move to tasks-axi. Passing the whole in-scope set to one call is a
# single atomic transaction, so a connected set (blocker + dependents) moves
# together and, on any failure, neither backlog's content changes - the only
# cleanup is a scaffold we just created. tasks-axi writes both its success and
# error output to stdout, so capture it and surface it only on failure.
if ! MV_OUT=$(tasks-axi mv "${RESOLVED_MOVE_KEYS[@]}" --file "$MAIN_BACKLOG" --to "$SUB_BACKLOG" \
  --if-source-sha256 "$MOVE_PLAN_SOURCE_HASH" --if-target-sha256 "$MOVE_PLAN_TARGET_HASH" \
  --json 2>&1); then
  PERSISTED=0
  for key in "${RESOLVED_MOVE_KEYS[@]}"; do
    backlog_key_section "$SUB_BACKLOG" "$key" >/dev/null 2>&1 && PERSISTED=1
  done
  if [ -n "$SUB_CREATED_INODE" ] && [ "$PERSISTED" -eq 0 ]; then
    remove_owned_backlog_scaffold "$SUB_BACKLOG" "$SUB_DATA_INODE" \
      "$SUB_CREATED_INODE" "$MOVE_PLAN_TARGET_HASH" || true
  fi
  receiver_wake_discard_prepared "$ID" || {
    echo "error: tasks-axi mv failed and receiver wake state could not be cleared" >&2
    exit 1
  }
  if [ -n "$MV_OUT" ]; then
    printf '%s\n' "$MV_OUT" >&2
  fi
  if [ "$PERSISTED" -eq 1 ]; then
    echo "error: tasks-axi mv completion is uncertain; identity preparation is preserved for recovery." >&2
  elif ! rollback_local_handoff_identities "$SUB_HOME" "$SUB_BACKLOG"; then
    echo "error: tasks-axi mv failed and identity preparation needs recovery." >&2
  else
    echo "error: tasks-axi mv failed; nothing was moved." >&2
  fi
  exit 1
fi
if ! parse_tasks_axi_move_result "$MV_OUT" \
  || ! task_sets_match RESOLVED_MOVE_KEYS PARSED_MOVE_KEYS; then
  echo "error: tasks-axi moved a different set than its prepared transaction; identity preparation is preserved for recovery." >&2
  exit 1
fi
complete_local_handoff_backlog_receipts "$SUB_HOME" || {
  echo "error: moved destination row does not match its exact handoff receipt." >&2
  exit 1
}

remove_interrupted_source_duplicates "$SUB_BACKLOG" "${LOCAL_IDENTITY_KEYS[@]}" || exit 1
commit_local_handoff_identities "$SUB_HOME" || {
  echo "error: backlog moved but exact work identity commit is incomplete; rerun the handoff." >&2
  exit 1
}
complete_source_handoff_identities || {
  echo "error: destination identity is committed but source ownership completion is incomplete; rerun the handoff." >&2
  exit 1
}

echo "handed off ${#RESOLVED_MOVE_KEYS[@]} item(s) to $ID: ${RESOLVED_MOVE_KEYS[*]}"
echo "  into $SUB_BACKLOG"
receiver_wake_promote_prepared "$ID" "$REQUESTED_BATCH" || {
  echo "error: handed off work to secondmate $ID, but durable receiver wake state could not be recorded" >&2
  exit 1
}
wake_pending_secondmate_receiver "$ID" || exit 1
if [ "${#ALREADY[@]}" -gt 0 ]; then
  echo "  already present (skipped): ${ALREADY[*]}"
fi
warn_stale_public_commitments "$ID" "${RESOLVED_MOVE_KEYS[@]}"
