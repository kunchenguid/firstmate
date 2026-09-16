#!/usr/bin/env bash
# Migrate one explicitly selected, registered LOCAL home without retiring it.
# Entry point: fm-remote-home-seed.sh --migrate <id> <local-home> <ssh-alias>
#                                            <remote-root> <remote-home>
# Rerun the identical command to reconcile an interrupted/SSH255 attempt. The
# journal binds identity and both placements permanently and records the exact
# transferred bytes; until cutover it re-snapshots them, so a steer the parent
# queues for the stopped mate between attempts crosses on the next run.
# No wildcard, batch, automatic local failover, secret grant, or cleanup verb.
#
# Before invocation the secondmate must persist its work and exit through
# fm-control.sh. Only tmux/herdr can prove this postcondition. Any child meta,
# nested mate, active process source, away daemon, or live session refuses.
# The local home is frozen before snapshotting and remains a non-running archive
# even on rollback. Its treehouse lease, projects, and all unlanded work remain.
# A refusal that lands before anything has been staged on the host unwinds the
# freeze and the journal this invocation created: nothing crossed, so the home
# must stay startable. Once staging has begun, nothing local is ever unwound.
# State evidence is not executable on the new machine; fm-home-migration-lib.sh
# owns the transfer boundary. Secrets embedded in ordinary prose are not detected:
# the operator must inspect durable records before authorizing their transfer.
#
# The existing read-only remote doctor must pass; migration never runs --fix.
# A private route is used to provision/verify before the primary route changes.
# Registry replacement is atomic under its ordinary lock. Normal fm-spawn owns
# launch, metadata and reply monitoring. A known failed launch rolls the route
# back ONLY after the remote endpoint is proved dead/missing. All copies remain
# for reconciliation and the local archive stays stopped; rerunning then retries
# the launch against the published home rather than re-sending records to it.
# SSH255 or unreadable
# completion preserves the remote route if cutover happened, and never launches
# locally. Reruns on that same route converge through the normal launch owner.
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=${FM_HOME:?FM_HOME is required}
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
# shellcheck source=bin/fm-home-migration-lib.sh
. "$SCRIPT_DIR/fm-home-migration-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 6 ] || die 'use fm-remote-home-seed.sh --migrate <id> <local-home> <ssh-alias> <remote-root> <remote-home>'
# Six includes the mode token supplied by the seed dispatcher.
[ "$1" = --migrate ] || die 'migration must be explicitly selected'
shift
ID=$1 SOURCE=$2 HOST=$3 REMOTE_ROOT=$4 REMOTE_HOME=$5
case "$ID" in ''|-*|*[!A-Za-z0-9._-]*) die 'invalid secondmate id' ;; esac
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die 'invalid SSH alias' ;; esac
for path in "$SOURCE" "$REMOTE_ROOT" "$REMOTE_HOME"; do
  case "$path" in /*) ;; *) die 'home/root paths must be absolute' ;; esac
  case "$path" in *';'*|*')'*|*$'\n'*|*$'\r'*|*$'\t'*|*'//'*) die 'unsafe path' ;; esac
  case "/$path/" in */../*|*/./*) die 'noncanonical path' ;; esac
done
[ "$(cd "$SOURCE" && pwd -P)" = "$SOURCE" ] || die 'source home must be canonical'
[ "$SOURCE" != "$FM_HOME" ] && [ "$SOURCE" != "$FM_ROOT" ] || die 'source must be a separate secondmate home'
REG="$DATA/secondmates.md"
META="$STATE/$ID.meta"
JOURNAL="$DATA/$ID/migration"
LOCKS=()
FROZE_HERE=0
REMOTE_STAGED=0
cleanup() { local lock; for lock in ${LOCKS[@]+"${LOCKS[@]}"}; do fm_lock_release "$lock" || true; done; }
unwind() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$FROZE_HERE" = 1 ] && [ "$REMOTE_STAGED" = 0 ]; then
    if [ -f "$SOURCE/.fm-home-migration" ] && [ ! -L "$SOURCE/.fm-home-migration" ] \
      && [ "$(cat "$SOURCE/.fm-home-migration")" = "$JOURNAL" ]; then
      rm -f "$SOURCE/.fm-home-migration"
    fi
    rm -rf -- "$JOURNAL"
  fi
  cleanup
}
trap unwind EXIT
lock() { fm_lock_try_acquire "$1" || die "migration lock unavailable: $1"; LOCKS+=("$1"); }
for dir in "$DATA" "$STATE" "$DATA/$ID" "$SOURCE/data" "$SOURCE/state" "$SOURCE/config" "$SOURCE/projects"; do
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(cd "$dir" && pwd -P)" = "$dir" ] || die "unsafe operational directory: $dir"
done
case "$SOURCE/" in "$FM_HOME/"*|"$FM_ROOT/"*) die 'source overlaps its primary' ;; esac
case "$FM_HOME/" in "$SOURCE/"*) die 'source contains its primary' ;; esac
lock "$STATE/.spawn-$ID.lock"
lock "$(secondmate_registry_lock_path "$STATE")"
lock "$(fm_meta_lock_path "$META")"
lock "$(fm_task_set_lock_path "$SOURCE/state")"
lock "$SOURCE/state/.lock.acquire"
lock "$SOURCE/state/.watch.lock"
secondmate_registry_validate_bindings "$REG" secondmate_registry_path_key || die "$SECONDMATE_REGISTRY_ERROR"
[ -f "$SOURCE/.fm-secondmate-home" ] && [ ! -L "$SOURCE/.fm-secondmate-home" ] \
  && [ "$(cat "$SOURCE/.fm-secondmate-home")" = "$ID" ] || die 'source identity does not match'
for dir in data state config projects; do
  [ ! -L "$SOURCE/$dir" ] && [ -d "$SOURCE/$dir" ] || die "unsafe source directory: $dir"
done
# Any retained child record counts, including unlanded/dead work; never infer
# completion from a status sentence or silently discard it to permit migration.
[ -z "$(find "$SOURCE/state" -maxdepth 1 -name '*.meta' -print)" ] || die 'child work records remain; finish and land children first'
[ -z "$(find "$SOURCE/state" -maxdepth 1 -name '*.check.sh' -print)" ] || die 'active check registrations remain; retire them through their owners first'
if [ -f "$SOURCE/data/backlog.md" ]; then
  if awk '/^## / {active=($0 == "## In flight")} active && /^- \[/ {found=1} END {exit !found}' "$SOURCE/data/backlog.md"; then
    die 'backlog still contains in-flight work'
  fi
fi
if [ -f "$SOURCE/data/secondmates.md" ] && grep -q '^-' "$SOURCE/data/secondmates.md"; then die 'nested secondmate routes remain'; fi
for dir in procevent when; do
  [ ! -d "$SOURCE/state/$dir" ] || [ -z "$(find "$SOURCE/state/$dir" -type f -print)" ] || die "active $dir registrations remain"
done
[ ! -e "$SOURCE/state/.afk" ] && [ ! -e "$SOURCE/state/.afk-contract" ] || die 'leave away/quiet mode before migration'
fm_migration_data classify "$SOURCE" \
  || die 'source configuration cannot cross as reported above; nothing was frozen'
# Probe the SOURCE home's own code for the archive guard, because that code is
# what has to refuse a session once the home is frozen. A pre-guard copy reads
# the probe word as an ordinary acquire, so the probe is pointed at a throwaway
# state directory and can never leave a lock behind in the home being migrated.
GUARD_PROBE=$(mktemp -d "${TMPDIR:-/tmp}/fm-migration-guard.XXXXXX") || die 'cannot probe the source guard'
GUARD=$(FM_HOME="$SOURCE" FM_STATE_OVERRIDE="$GUARD_PROBE" "$SOURCE/bin/fm-lock.sh" migration-guard-version 2>/dev/null || true)
rm -rf -- "$GUARD_PROBE"
[ "$GUARD" = 1 ] || die 'update the source home to archive-guard-capable Firstmate before migration'
SESSION=$(FM_HOME="$SOURCE" FM_STATE_OVERRIDE="$SOURCE/state" "$SCRIPT_DIR/fm-lock.sh" status)
case "$SESSION" in 'lock: free'|'lock: stale '*) ;; *) die "source session is not stopped: $SESSION" ;; esac

if [ -e "$JOURNAL" ] || [ -L "$JOURNAL" ]; then
  [ -d "$JOURNAL" ] && [ ! -L "$JOURNAL" ] || die 'unsafe migration journal'
  [ -z "$(find "$JOURNAL" ! -type d ! -type f -print)" ] && [ -z "$(find "$JOURNAL" -type f -links +1 -print)" ] || die 'unsafe migration journal artifacts'
  [ -f "$SOURCE/.fm-home-migration" ] && [ ! -L "$SOURCE/.fm-home-migration" ] \
    && [ "$(cat "$SOURCE/.fm-home-migration")" = "$JOURNAL" ] || die 'source freeze no longer matches this migration'
  for field in source host root home; do
    case "$field" in source) expected=$SOURCE ;; host) expected=$HOST ;; root) expected=$REMOTE_ROOT ;; home) expected=$REMOTE_HOME ;; esac
    [ -f "$JOURNAL/$field" ] && [ ! -L "$JOURNAL/$field" ] && [ "$(cat "$JOURNAL/$field")" = "$expected" ] || die 'migration is bound to another placement; reconcile its retained journal'
  done
else
  secondmate_registry_line_for_id "$REG" "$ID" || die 'missing local route'
  [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] && [ "$SECONDMATE_REGISTRY_HOME" = "$SOURCE" ] || die 'route does not match the explicitly selected local home'
  fm_backend_validate_task_endpoint "$META" "$ID" || die 'local endpoint metadata is not verifiable'
  [ "$(fm_meta_get "$META" kind)" = secondmate ] && [ "$(fm_meta_get "$META" home)" = "$SOURCE" ] \
    && [ -z "$(fm_meta_get "$META" remote_host)" ] || die 'local metadata binding differs'
  case "$FM_BACKEND_VALIDATED_BACKEND" in tmux|herdr) ;; *) die 'source runtime cannot prove a stopped agent; migration refused' ;; esac
  CURRENT=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")
  case "$CURRENT" in dead|missing) ;; *) die "source agent is $CURRENT; persist records and use fm-control exit first" ;; esac
  [ ! -e "$SOURCE/.fm-home-migration" ] && [ ! -L "$SOURCE/.fm-home-migration" ] || die 'source already frozen by another migration'
  umask 077
  mkdir "$JOURNAL"
  FROZE_HERE=1
  printf '%s\n' "$SOURCE" > "$JOURNAL/source"
  printf '%s\n' "$HOST" > "$JOURNAL/host"
  printf '%s\n' "$REMOTE_ROOT" > "$JOURNAL/root"
  printf '%s\n' "$REMOTE_HOME" > "$JOURNAL/home"
  printf '%s\n' "$SECONDMATE_REGISTRY_LINE" > "$JOURNAL/route.before"
  cp -p "$META" "$JOURNAL/meta.before"
  printf -- '- %s - %s (host: %s; root: %s; home: %s; scope: %s; projects: %s; added %s)\n' \
    "$ID" "$SECONDMATE_REGISTRY_SUMMARY" "$HOST" "$REMOTE_ROOT" "$REMOTE_HOME" \
    "$SECONDMATE_REGISTRY_SCOPE" "$SECONDMATE_REGISTRY_PROJECTS" "$SECONDMATE_REGISTRY_ADDED" > "$JOURNAL/route.after"
  mkdir "$JOURNAL/route"
  cp "$JOURNAL/route.after" "$JOURNAL/route/secondmates.md"
  printf '%s\n' "$JOURNAL" > "$SOURCE/.fm-home-migration"
  printf 'snapshot\n' > "$JOURNAL/phase"
fi

remote() { FM_DATA_OVERRIDE="$JOURNAL/route" "$SCRIPT_DIR/fm-on.sh" "$@"; }
# Do not repair account-level prerequisites as a side effect of migration.
remote "$ID" fm-remote-doctor.sh || { rc=$?; printf 'remote prerequisites unresolved; no route switched\n' >&2; exit "$rc"; }
PHASE=$(cat "$JOURNAL/phase")
if [ "$PHASE" = complete ]; then printf 'already-migrated: %s archive=%s\n' "$ID" "$SOURCE"; exit 0; fi
# Re-snapshot on every run that has published nothing yet, rather than only on
# the first one. The parent can still queue a steer for the stopped mate between
# attempts, and that is real work: an attempt that ended in the snapshot phase
# must carry it across on the rerun instead of failing the pre-cutover comparison
# against a stale snapshot identically forever. An unchanged source packs
# byte-identically, so a rerun that changes nothing keeps the same digest and the
# same idempotent staging. Once a placement has been published the remote copy is
# the newer one: a cutover or rolled-back rerun retries the launch against it and
# never re-lands the frozen source's older records over it.
if [ "$PHASE" = snapshot ]; then
  fm_migration_data pack "$SOURCE" "$STATE" "$ID" "$REMOTE_HOME" > "$JOURNAL/data.next"
  {
    printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\n' "$(printf '%s' "$ID" | base64 | tr -d '\n')"
    printf 'parent_host_b64=%s\n' "$(printf '%s' "$HOST" | base64 | tr -d '\n')"
    printf 'charter_b64=%s\n' "$(jq -r '.records[] | select(.path=="data/charter.md") | .bytes' "$JOURNAL/data.next")"
    count=0
    if [ -f "$SOURCE/data/projects.md" ]; then count=$(awk '$1=="-" {n++} END {print n+0}' "$SOURCE/data/projects.md"); fi
    printf 'project_count=%s\n' "$count"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '- '*) ;; *) continue ;; esac
      project=$(printf '%s\n' "$line" | awk '{print $2}')
      case "$project" in ''|*[!A-Za-z0-9._-]*) die 'invalid project registry identity' ;; esac
      mode=$(FM_HOME="$SOURCE" FM_DATA_OVERRIDE="$SOURCE/data" "$SCRIPT_DIR/fm-project-mode.sh" "$project" | awk '{print $1}')
      case "$mode" in no-mistakes|direct-PR) ;; *) die "project $project cannot be remote: $mode" ;; esac
      origin=$(git -C "$SOURCE/projects/$project" remote get-url origin) || die "project $project has no registered origin"
      fm_project_origin_safe "$origin" || die "project $project origin is unsafe"
      printf 'project=%s|%s|%s|%s\n' "$(printf '%s' "$project" | base64 | tr -d '\n')" \
        "$(printf '%s' "$origin" | base64 | tr -d '\n')" "$(printf '%s' "$line" | base64 | tr -d '\n')" "$(printf '%s' "$mode" | base64 | tr -d '\n')"
    done < <(if [ -f "$SOURCE/data/projects.md" ]; then cat "$SOURCE/data/projects.md"; fi)
  } > "$JOURNAL/provision.next"
  jq --rawfile provision "$JOURNAL/provision.next" '. + {provision: $provision}' "$JOURNAL/data.next" > "$JOURNAL/bundle.tmp"
  mv "$JOURNAL/data.next" "$JOURNAL/data.json"
  mv "$JOURNAL/provision.next" "$JOURNAL/provision"
  mv "$JOURNAL/bundle.tmp" "$JOURNAL/bundle.json"
fi
DIGEST=$(fm_inherit_sha256 "$JOURNAL/bundle.json")
if [ "$PHASE" = snapshot ]; then
  REMOTE_STAGED=1
  remote --stdin "$ID" fm-remote-home-provision.sh --migration "$ID" "$DIGEST" < "$JOURNAL/bundle.json" || exit $?
  # Byte-for-byte check that the staged snapshot still matches before switching.
  fm_migration_data pack "$SOURCE" "$STATE" "$ID" "$REMOTE_HOME" > "$JOURNAL/recheck.json"
  cmp -s "$JOURNAL/data.json" "$JOURNAL/recheck.json" \
    || die 'source changed after staging; both copies retained, route not switched; rerun the identical command to carry the newer records across'
fi
secondmate_registry_line_for_id "$REG" "$ID" || die 'route disappeared during migration'
BEFORE=$(cat "$JOURNAL/route.before")
AFTER=$(cat "$JOURNAL/route.after")
case "$SECONDMATE_REGISTRY_LINE" in "$BEFORE"|"$AFTER") ;; *) die 'route changed outside this migration' ;; esac
publish_route() {
  local replacement=$1 line
  : > "$REG.migration.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- $ID "*) printf '%s\n' "$replacement" ;; *) printf '%s\n' "$line" ;; esac
  done < "$REG" > "$REG.migration.$$"
  secondmate_registry_validate_bindings "$REG.migration.$$" secondmate_registry_path_key || die "$SECONDMATE_REGISTRY_ERROR"
  mv -f "$REG.migration.$$" "$REG"
}
# Persist the recovery obligation before either publication. The source freeze
# prevents local recovery even if the process dies between these two files.
printf 'cutover\n' > "$JOURNAL/phase"
publish_route "$AFTER"
if [ -f "$META" ] && [ -z "$(fm_meta_get "$META" remote_host)" ]; then
  cmp -s "$JOURNAL/meta.before" "$META" || die 'local endpoint record changed'
  mv "$META" "$JOURNAL/meta.local"
fi
cleanup
LOCKS=()
HARNESS=$(fm_meta_get "$JOURNAL/meta.before" harness)
MODEL=$(fm_meta_get "$JOURNAL/meta.before" model)
EFFORT=$(fm_meta_get "$JOURNAL/meta.before" effort)
ARGS=("$ID" --secondmate --harness "$HARNESS" --backend herdr)
[ -z "$MODEL" ] || ARGS+=(--model "$MODEL")
[ -z "$EFFORT" ] || ARGS+=(--effort "$EFFORT")
rc=0
"$SCRIPT_DIR/fm-spawn.sh" "${ARGS[@]}" || rc=$?
if [ "$rc" -eq 255 ]; then printf 'unknown completion; remote route and local archive preserved\n' >&2; exit 255; fi
lock "$STATE/.spawn-$ID.lock"
lock "$(secondmate_registry_lock_path "$STATE")"
lock "$(fm_meta_lock_path "$META")"
probe_rc=0
CURRENT=$(remote "$ID" fm-remote-secondmate-control.sh state "$ID") || probe_rc=$?
if [ "$probe_rc" -eq 0 ] && [ "$CURRENT" = alive ] && [ "$rc" -eq 0 ]; then
  printf 'complete\n' > "$JOURNAL/phase"
  printf 'migrated: %s remote=%s:%s archive=%s\n' "$ID" "$HOST" "$REMOTE_HOME" "$SOURCE"
  exit 0
fi
if [ "$probe_rc" -eq 0 ]; then
  case "$CURRENT" in
    dead|missing)
      secondmate_registry_line_for_id "$REG" "$ID" && [ "$SECONDMATE_REGISTRY_LINE" = "$AFTER" ] || die 'route changed; rollback refused'
      publish_route "$BEFORE"
      [ ! -f "$META" ] || cp -p "$META" "$JOURNAL/meta.remote"
      cp -p "$JOURNAL/meta.before" "$META.migration.$$"
      mv -f "$META.migration.$$" "$META"
      printf 'rolled-back\n' > "$JOURNAL/phase"
      die 'remote launch failed; original route restored; both homes retained and local archive remains stopped for reconciliation'
      ;;
  esac
fi
printf 'unknown/unverified completion; remote route and both homes preserved; reconcile with the identical migration command\n' >&2
exit 255
