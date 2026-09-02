#!/usr/bin/env bash
# fm-usage-ledger.sh - the single owner of Firstmate's durable, home-private
# task-usage ledger: its schema, its safety rules, its event identity, and its
# retention. Every other script calls this one instead of serializing a record
# itself, so the format is stated here exactly once.
#
# WHY IT EXISTS. A task's implementation axes (harness, model, effort, kind,
# project, delivery mode, autonomy posture, backend) live only in
# state/<id>.meta, and bin/fm-teardown.sh removes that record as part of
# ordinary successful cleanup. Nothing durable then remained to join a merged
# PR back to the model that produced it. This ledger is that durable join: it
# is written under $FM_HOME/data/, which teardown never touches, at the
# lifecycle points docs/architecture.md owns and this header does not
# restate.
#
# STORE. $FM_HOME/data/task-usage.jsonl (FM_DATA_OVERRIDE wins), strictly
# APPEND-ONLY outside the explicit `prune` verb, mode 0600, one JSON object per
# line. Its sibling lock is data/.task-usage.jsonl.lock. Nothing else may write
# it.
#
# RECORD. Every v1 record carries the SAME fixed key set in the SAME order, so
# the file is parseable with awk/sed and needs no JSON processor (firstmate does
# not require jq):
#
#   {"v":1,"seq":N,"at":EPOCH,"event":"E","id":"I","task":"T","gen":"G",
#    "kind":"K","harness":"H","model":"M","effort":"F","project":"P",
#    "mode":"D","yolo":"Y","backend":"B","pr":"U","pr_head":"S",
#    "landing":"L","outcome":"O","status_class":"C",
#    "validator_harness":"VH","validator_model":"VM"}
#
#   v      schema version, 1 today.
#   seq    assigned under the lock, strictly increasing, and not re-issued in a
#          store's lifetime as long as the record clock does not regress. It
#          starts at 1 and appends leave no gap; `prune` removes records, so
#          gaps after a retention run are expected, and when retention leaves
#          the coverage marker as the only record that marker carries the
#          highest sequence the store had reached, so the next append still
#          continues past every number a pruned record used. A prune that keeps
#          dated records instead continues from the last record it kept, which
#          is the store's high-water mark only because appends land in
#          increasing time order; a clock that jumps backwards can leave a
#          lower-numbered record behind the horizon of a higher-numbered one it
#          drops. `id` is the stable key for joining exports taken at different
#          times.
#   at     epoch seconds when the record was appended, never a time inferred
#          from somewhere else. Because each record is written at its own
#          lifecycle point, a spawn record's `at` IS that incarnation's spawn
#          time and a cleanup record's `at` IS its cleanup timestamp.
#   event  ledger-open | spawn | pr | merge | cleanup.
#   id     the stable event identity that makes a repeated call idempotent
#          (see IDENTITY below).
#   task   task id.
#   gen    the task's spawn generation (incarnation token) from meta spawn_gen=,
#          or "unknown" when that record carries none.
#   kind   ship | scout | secondmate. Every record states what the task
#          record said at that moment, so a scout promoted to a ship keeps
#          kind=scout on its spawn row and carries kind=ship on its cleanup
#          row rather than being rewritten.
#   harness / model / effort
#          the IMPLEMENTING worker's axes, exactly as spawn recorded them.
#          "default" is fm-spawn's own recorded value for an unpinned axis, and
#          "unknown" appears when the task record could not be read at all.
#          These, kind, project, mode, yolo, backend, and gen are the axes the
#          task record supplies. A caller whose OWN sequence deletes that
#          record before it can append captures them first with the `axes`
#          verb and hands them back with --axes, so "unknown" here means an
#          axis nothing could prove rather than one merely read too late.
#   project the project or home DIRECTORY NAME from meta project=, never its
#          path, with any trailing separator removed first. This is the name
#          data/projects.md registers, so it is the joinable key: a record that
#          carries a project reads "unknown" when its name cannot be taken,
#          never "" - that would claim the task had no project at all.
#   mode   no-mistakes | direct-PR | local-only | secondmate; "" for a scout,
#          which records no delivery posture until promotion.
#   yolo   on | off; "" where no delivery posture is recorded.
#   backend the runtime session backend, read from whichever writer owns the
#          record: a LOCAL task record resolves through fm-spawn's documented
#          default that an absent backend= means tmux, because that writer
#          writes the key exactly when the backend is not tmux. A REMOTE
#          secondmate record is written by a different writer that never writes
#          backend= at all and states the endpoint's own backend instead, so it
#          is read from there and reads "unknown" when that writer proved none.
#   pr     the full canonical PR or MR URL.
#   pr_head the forge's exact head commit when it could be read.
#   landing the landing commit for an approved local-only merge.
#   outcome landed | discarded | reported | retired | merged.
#   status_class the task's FINAL status verb, mapped to the closed vocabulary
#          done | failed | blocked | needs-decision | working, plus the pause,
#          resolution, and captain-held verbs in THIS home's configured
#          spelling, read from bin/fm-classify-lib.sh - which owns that
#          vocabulary - rather than restated here. "none" means the task logged
#          no status at all, which only a status directory that is still there
#          can establish, and "unknown" means the class could not be proven:
#          the last line carries no recognised verb, a log that is there could
#          not be safely read, or the directory that would hold it is itself
#          gone. The status NOTE is never stored. A caller whose own sequence
#          retires the status log before it can record passes the
#          already-resolved class with --status-class instead of the file, so it
#          stores the class the task actually ended on rather than the empty log
#          it left behind.
#   validator_harness / validator_model
#          the no-mistakes VALIDATOR's identity, deliberately separate from the
#          implementer's axes above. Firstmate cannot prove them today (the
#          pipeline does not expose the agent it ran), so they are recorded as
#          the explicit literal "unknown" rather than inferred from the
#          implementer. The flags exist so a caller that CAN prove them records
#          them without a schema change.
#
# A field that does not apply to an event is the empty string; a field that
# applies but could not be proven is the literal "unknown". The two are
# deliberately different: "" means not-applicable, "unknown" means unproven.
#
# PRIVACY BOUNDARY. Only the allowlisted meta keys above are ever read, and
# project is reduced to its directory name. Credentials, tokens, account or
# host identity, prompt or response text, captain text, PHI, free-form status
# notes, worktree/tasktmp/home paths, traceparent carriers, and relay request
# payloads are never read and have no field to land in. Values are reduced to
# printable ASCII with " and \ removed and truncated at 200 characters, so a
# record is always well-formed JSON with no escaping and nothing is inferred
# from a name or from prose. That reduction is for free-form LABELS only: an
# identity-bearing value - task, gen, PR URL, PR head, landing - is checked
# against a bound and REFUSED when it does not fit, never reduced, because a
# bound that rewrote one real merge request into another valid one would store
# a fabricated fact. The PR URL carries its OWN bound rather than the label
# bound, sized to every canonical URL fm_pr_url_parse accepts (a 253-character
# host, a 1024-character project path, a 10-digit request number), so a nested
# self-hosted merge request is recorded rather than dropped. The composed id
# carries its own larger bound over those already-bounded parts, see IDENTITY.
#
# IDENTITY (idempotency). A repeated call with the same identity is a no-op
# that reports `duplicate` and exits 0; a genuinely distinct event appends a
# new record.
#   ledger-open  "ledger-open"
#   spawn        spawn:<task>:<gen>
#   pr           pr:<task>:<gen>:<pr>:<pr_head or ->
#   merge        merge:<task>:<pr or ->:<landing or ->
#   cleanup      cleanup:<task>:<gen>
# Every fresh spawn and relaunch mints a new gen, so a replacement worker is a
# distinct spawn row and its own cleanup row. An identity is composed from
# fields that are each already bounded, and its own bound is the widest such
# composition - the pr event's, carrying the full PR-URL bound - so composing
# it can never truncate two distinct events, a long self-hosted MR URL and its
# head say, into one false duplicate. The probe compares whole parsed ids
# across the WHOLE store, so a retried spawn, a re-armed PR poll, an
# at-least-once merge notification, and a rerun teardown dedupe no matter how
# much history sits between them. A task record with no spawn_gen= at all has
# gen "unknown", so repeated launches of that one id would collapse into a
# single row; every path that CREATES a task record today mints one - the local
# launch, the remote secondmate launch, and the Orca cleanup-recovery record an
# aborted launch leaves behind - and every path that rewrites an existing record
# preserves it, so that is a legacy record's shape rather than any current one.
#
# FIRST OBSERVED. The store's first record is `ledger-open`, whose `at` is the
# instant this home started recording. NOTHING before it is backfilled, and no
# verb here fabricates history: an analysis must treat that timestamp as the
# start of coverage.
#
# SAFETY. Every mutation runs under the store's lock. The store and any temp
# file must be a regular, single-linked, non-symlink file at mode 0600 on the
# data directory's own device; anything else refuses without writing. A
# malformed record among the ones an operation actually READS stops that
# operation and leaves the file's bytes untouched, so no verb here ever
# rewrites a damaged ledger.
# `verify` and `prune` are the verbs that read and validate EVERY record, so
# they are what proves the whole store. `record` deliberately reads only what
# one append needs - the last record, which is where it continues the sequence
# from, plus any record already carrying the identity it is deduping against -
# so a malformed record ELSEWHERE is never read, never detected, and the store
# is still extended past it; `verify` is what finds that damage. In exchange an
# append costs one fixed-string scan of the store rather than parsing every
# record in bash while holding the lock on the spawn, PR, merge, and cleanup
# paths. Because every append validates the last record first and nothing but
# `prune` ever rewrites the file, the ledger's own writes cannot introduce a
# break; damage can only come from something else.
# Forward compatibility: a record whose v is not 1 is accepted as opaque if it
# still carries the common v/seq/at/event/id prefix, so a newer writer's rows
# are preserved rather than declared malformed.
# `record` takes the lock with a BOUND, FM_USAGE_LEDGER_LOCK_TIMEOUT seconds
# (default 60, generous enough that ordinary contention still wins it), and
# refuses when that expires. A data directory the lock can never be created in -
# read-only, full, or another user's - would otherwise leave the caller waiting
# forever inside the lifecycle step it is only instrumenting; refusing hands the
# failure to the warning path bin/fm-usage-ledger-lib.sh owns. `prune` is an
# explicit operator command and waits.
#
# RETENTION. History is bounded ONLY by the explicit `prune` verb. No lifecycle
# call ever rewrites history, so an unrelated task mutation cannot lose a row.
# `prune` keeps the ledger-open record plus every record within
# FM_USAGE_LEDGER_RETENTION_DAYS (default 400) days, which preserves 30-day,
# quarterly, and year-over-year comparisons. At a few hundred bytes per record
# and a handful of records per task, a busy home costs single-digit megabytes a
# year, so pruning is an operator decision rather than an automatic one.
#
# Usage:
#   fm-usage-ledger.sh record --event <spawn|pr|merge|cleanup> --task <id>
#       [--meta <path> | --axes <line>] [--gen <token>] [--pr <url>]
#       [--pr-head <sha>] [--landing <sha>]
#       [--outcome <landed|discarded|reported|retired|merged>]
#       [--status-file <path> | --status-class <class>]
#       [--validator-harness <name>] [--validator-model <name>]
#     Append one record, or report `duplicate` when its identity is already
#     stored. --meta supplies the implementation axes and --axes supplies an
#     already-captured set of them; --status-file supplies the final status
#     class, and --status-class supplies an already-resolved one for a caller
#     that had to read it earlier.
#   fm-usage-ledger.sh status-class --status-file <path>
#     Print that status log's final class, so a caller whose sequence retires
#     the log before it records can capture the class first and pass it back
#     through record --status-class. Touches no store.
#   fm-usage-ledger.sh axes --meta <path>
#     Print that task record's implementation axes as one opaque line, so a
#     caller whose sequence DELETES the record before it records can capture
#     them first and pass them back through record --axes. A secondmate
#     retirement is that caller: it removes the home its own state directory
#     sits in, and without the capture its cleanup row would carry unknown
#     axes and an incarnation-less identity that collides with every other
#     retirement of the same id. Touches no store.
#   fm-usage-ledger.sh list [--recent <n>]
#     Print the last n records (default 20) as raw JSONL.
#   fm-usage-ledger.sh verify
#     Validate every record and print `ok records=<n> first_observed=<epoch>`.
#   fm-usage-ledger.sh prune [--days <n>]
#     Apply retention atomically. Refuses a malformed store.
#   fm-usage-ledger.sh path
#     Print the store path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# fm-backend.sh owns fm_meta_get and the "absent backend= means tmux"
# compatibility contract; this script reads task records through it rather than
# restating either.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# Only fm-wake-lib.sh's lock primitives are used here, never a state tree, so
# it is told not to create the state directory it resolves at source time.
FM_WAKE_LOCKS_ONLY=1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE_NAME='task-usage.jsonl'
SCHEMA_VERSION=1
RETENTION_DAYS=${FM_USAGE_LEDGER_RETENTION_DAYS:-400}
# The bound `record` puts on taking the store lock, see SAFETY.
RECORD_LOCK_TIMEOUT=${FM_USAGE_LEDGER_LOCK_TIMEOUT:-60}
case "$RECORD_LOCK_TIMEOUT" in ''|*[!0-9]*|0) RECORD_LOCK_TIMEOUT=60 ;; esac
# One free-form field's bound.
UL_FIELD_MAX=200
# The PR/MR URL's own bound. It is identity-bearing rather than a label, so it
# is sized to every canonical URL fm_pr_url_parse accepts rather than reusing
# the label bound: "https://" (8) + a host of at most 253
# (fm_pr_gitlab_host_valid) + "/" + a project path of at most 1024 across at
# most 20 segments (fm_pr_gitlab_path_valid) + "/-/merge_requests/" (18) + a
# request number of at most 10 digits, which is the widest a GitLab iid can be.
# GitHub's shape is strictly shorter. Nothing inside those limits is ever
# refused, so a nested self-hosted merge request keeps its ledger row.
UL_PR_MAX=$((8 + 253 + 1 + 1024 + 18 + 10))
# The bound a composed event identity carries. The widest identity is the pr
# event's pr:<task>:<gen>:<pr>:<pr_head>, so this is that worst case exactly:
# two field-bounded parts, one PR-bounded part, a 64-character head, and the
# literal separators. Composing an identity therefore never truncates - two
# distinct events must never collapse into the same id.
UL_IDENTITY_MAX=$((3 + UL_FIELD_MAX + 1 + UL_FIELD_MAX + 1 + UL_PR_MAX + 1 + 64))
# The separator of a captured axes line: the same quote no stored value may
# contain, because ul_clean removes it. That is what lets the line split
# without any escaping, exactly as it lets a record be emitted without any. It
# is deliberately not whitespace: bash collapses runs of IFS whitespace, which
# would silently merge two adjacent EMPTY axes - a scout's mode and yolo, say -
# and shift every axis after them onto the wrong field.
UL_AXES_SEP='"'
# How many fields that line carries; see ul_axes_emit for the order.
UL_AXES_COUNT=9

# The common prefix every record of every schema version carries, plus the
# closing brace. Captures: 1 v, 2 seq, 3 at, 4 event, 5 id.
UL_PREFIX_RE='^[{]"v":([1-9][0-9]*),"seq":([1-9][0-9]*),"at":([0-9]+),"event":"([a-z-]+)","id":"([^"\]*)",.*[}]$'
# The exact v1 shape: same key set, same order, every value a plain string.
UL_V1_RE='^[{]"v":1,"seq":[1-9][0-9]*,"at":[0-9]+,"event":"[a-z-]+","id":"[^"\]*","task":"[^"\]*","gen":"[^"\]*","kind":"[^"\]*","harness":"[^"\]*","model":"[^"\]*","effort":"[^"\]*","project":"[^"\]*","mode":"[^"\]*","yolo":"[^"\]*","backend":"[^"\]*","pr":"[^"\]*","pr_head":"[^"\]*","landing":"[^"\]*","outcome":"[^"\]*","status_class":"[^"\]*","validator_harness":"[^"\]*","validator_model":"[^"\]*"[}]$'

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  printf 'run fm-usage-ledger.sh --help for the contract\n' >&2
  exit 2
}

# Reduce one caller value to a ledger-safe scalar: printable ASCII only, no
# quote or backslash, bounded length. This is what makes every emitted line
# well-formed JSON without escaping logic.
ul_clean() {  # <value> [<max-length>]
  local v=${1-} max=${2:-$UL_FIELD_MAX}
  v=$(printf '%s' "$v" | LC_ALL=C tr -cd '\040-\176' | LC_ALL=C tr -d '\042\134')
  printf '%s' "${v:0:max}"
}

# 0 when <value> survives ul_clean unchanged at that field's own bound. An
# identity-bearing value is checked with this and REFUSED rather than reduced,
# because a reduction that rewrote one real merge request, incarnation, or task
# into another valid one would store a fabricated fact.
ul_identity_intact() {  # <value> [<max-length>]
  [ "${1-}" = "$(ul_clean "${1-}" "${2:-$UL_FIELD_MAX}")" ]
}

ul_resolve_dir() {  # <label> <path>
  local label=$1 path=$2 resolved
  [ -n "$path" ] || die "$label directory is empty"
  [ ! -L "$path" ] || die "$label directory is a symlink: $path"
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || die "$label directory cannot be resolved: $path"
  printf '%s\n' "$resolved"
}

# 0 when <line> is a record this version may keep. Sets UL_REC_V/SEQ/AT/EVENT/ID.
ul_record_parse() {  # <line>
  local line=$1
  UL_REC_V=
  UL_REC_SEQ=
  UL_REC_AT=
  UL_REC_EVENT=
  UL_REC_ID=
  [[ "$line" =~ $UL_PREFIX_RE ]] || return 1
  UL_REC_V=${BASH_REMATCH[1]}
  UL_REC_SEQ=${BASH_REMATCH[2]}
  UL_REC_AT=${BASH_REMATCH[3]}
  UL_REC_EVENT=${BASH_REMATCH[4]}
  UL_REC_ID=${BASH_REMATCH[5]}
  # A record claiming this version must match this version exactly. A newer
  # version is opaque but preserved.
  if [ "$UL_REC_V" = "$SCHEMA_VERSION" ]; then
    [[ "$line" =~ $UL_V1_RE ]] || return 1
  fi
}

# Validate the whole store, printing the first malformed line number on stderr.
# Sets UL_COUNT, UL_LAST_SEQ, and UL_FIRST_OBSERVED. This is the whole-store
# read `verify` and `prune` owe their callers; an append uses ul_store_probe.
ul_store_scan() {
  local line n=0
  UL_COUNT=0
  UL_LAST_SEQ=0
  UL_FIRST_OBSERVED=
  [ -s "$STORE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if ! ul_record_parse "$line"; then
      printf 'error: task-usage ledger record %s is malformed; its bytes are left untouched at %s\n' "$n" "$STORE" >&2
      return 1
    fi
    [ -n "$UL_FIRST_OBSERVED" ] || UL_FIRST_OBSERVED=$UL_REC_AT
    UL_LAST_SEQ=$UL_REC_SEQ
    UL_COUNT=$n
  done < "$STORE"
}

# What ONE append needs, and nothing more: the sequence number to continue from,
# and whether this identity is already stored. Sets UL_LAST_SEQ and
# UL_DUPLICATE. Every record it reads is parsed and must be well formed, and a
# candidate's identity is still compared as a whole parsed id rather than as
# text matched anywhere in a line - the fixed-string search only narrows which
# records are worth parsing, because a record always carries its identity as
# exactly these bytes and no stored value may contain a quote.
ul_store_probe() {  # <identity>
  local want=$1 last hits line rc
  UL_LAST_SEQ=0
  UL_DUPLICATE=0
  [ -s "$STORE" ] || return 0
  last=$(tail -n 1 "$STORE") || die "task-usage ledger could not be read at $STORE"
  if ! ul_record_parse "$last"; then
    printf 'error: the last task-usage ledger record is malformed; its bytes are left untouched at %s - run fm-usage-ledger.sh verify\n' "$STORE" >&2
    return 1
  fi
  UL_LAST_SEQ=$UL_REC_SEQ
  hits=$(grep -F -- ",\"id\":\"$want\"," "$STORE") || {
    rc=$?
    [ "$rc" -eq 1 ] || die "task-usage ledger could not be read at $STORE"
    hits=
  }
  [ -n "$hits" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if ! ul_record_parse "$line"; then
      printf 'error: a task-usage ledger record carrying this event identity is malformed; its bytes are left untouched at %s - run fm-usage-ledger.sh verify\n' "$STORE" >&2
      return 1
    fi
    [ "$UL_REC_ID" != "$want" ] || UL_DUPLICATE=1
  done <<EOF
$hits
EOF
}

# The store must be a private, regular, single-linked file on the data device.
ul_store_valid() {
  fm_pr_private_file_valid "$STORE" 600 "$DATA_DEVICE"
}

ul_publish() {  # <tmp> <destination>
  local tmp=$1 dest=$2
  chmod 0600 "$tmp" || return 1
  fm_pr_private_file_valid "$tmp" 600 "$DATA_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$DATA_DEVICE" || return 1
  mv -f -- "$tmp" "$dest" || return 1
  fm_pr_private_file_valid "$dest" 600 "$DATA_DEVICE"
}

ul_emit() {  # <seq> <at> <event> <id>
  printf '{"v":%s,"seq":%s,"at":%s,"event":"%s","id":"%s","task":"%s","gen":"%s","kind":"%s","harness":"%s","model":"%s","effort":"%s","project":"%s","mode":"%s","yolo":"%s","backend":"%s","pr":"%s","pr_head":"%s","landing":"%s","outcome":"%s","status_class":"%s","validator_harness":"%s","validator_model":"%s"}\n' \
    "$SCHEMA_VERSION" "$1" "$2" "$3" "$4" \
    "$F_TASK" "$F_GEN" "$F_KIND" "$F_HARNESS" "$F_MODEL" "$F_EFFORT" \
    "$F_PROJECT" "$F_MODE" "$F_YOLO" "$F_BACKEND" "$F_PR" "$F_PR_HEAD" \
    "$F_LANDING" "$F_OUTCOME" "$F_STATUS_CLASS" \
    "$F_VALIDATOR_HARNESS" "$F_VALIDATOR_MODEL"
}

# Retention removed every dated record, so the coverage marker is the only one
# left and nothing in the file remembers how far the sequence had run. Carry
# that high-water mark onto the marker instead, so no later append re-issues a
# number a pruned record already used. Only the seq field is rewritten, so a
# record some newer writer produced keeps the rest of its own shape.
ul_prune_carry_sequence() {  # <staging-file> <high-water>
  local file=$1 high=$2 line prefix rest
  IFS= read -r line < "$file" || return 1
  ul_record_parse "$line" || return 1
  [ "$UL_REC_SEQ" -lt "$high" ] || return 0
  prefix="{\"v\":$UL_REC_V,\"seq\":$UL_REC_SEQ,"
  rest=${line#"$prefix"}
  [ "$rest" != "$line" ] || return 1
  printf '{"v":%s,"seq":%s,%s\n' "$UL_REC_V" "$high" "$rest" > "$file" || return 1
}

PRUNE_TMP=
prune_cleanup() {
  [ -z "$PRUNE_TMP" ] || rm -f -- "$PRUNE_TMP"
  fm_lock_release "$LOCK" || true
}

record_cleanup() {
  fm_lock_release "$LOCK" || true
}

ul_fields_reset() {
  F_TASK=
  F_GEN=
  F_KIND=
  F_HARNESS=
  F_MODEL=
  F_EFFORT=
  F_PROJECT=
  F_MODE=
  F_YOLO=
  F_BACKEND=
  F_PR=
  F_PR_HEAD=
  F_LANDING=
  F_OUTCOME=
  F_STATUS_CLASS=
  F_VALIDATOR_HARNESS=
  F_VALIDATOR_MODEL=
}

# Create the store with its first-observed record when it does not exist yet.
# Runs under the lock.
ul_store_open() {
  local tmp
  if [ -e "$STORE" ] || [ -L "$STORE" ]; then
    ul_store_valid || die "task-usage ledger is not a private regular file on the data device: $STORE"
    return 0
  fi
  tmp=$(mktemp "$DATA/.$STORE_NAME.XXXXXX") || die "task-usage ledger temp file could not be created in $DATA"
  # The reset runs in a subshell so opening the store cannot clobber the fields
  # the caller already resolved for the record it came here to append.
  if ! ( ul_fields_reset; ul_emit 1 "$(date +%s)" ledger-open ledger-open ) > "$tmp"; then
    rm -f -- "$tmp"
    die "task-usage ledger could not be initialised at $STORE"
  fi
  if ! ul_publish "$tmp" "$STORE"; then
    rm -f -- "$tmp"
    die "task-usage ledger could not be published at $STORE"
  fi
}

# Read the allowlisted implementation axes out of one task record. A record that
# EXISTS but is not an ordinary private file is refused, because reading it
# would be unsafe. A record that is simply gone leaves every axis it would have
# supplied as the explicit literal "unknown": losing the row entirely would be
# worse than recording honestly that these axes could not be read.
ul_load_meta() {  # <meta-path>
  local meta=$1 project gen remote_backend
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    F_KIND=unknown
    F_HARNESS=unknown
    F_MODEL=unknown
    F_EFFORT=unknown
    F_MODE=unknown
    F_YOLO=unknown
    F_BACKEND=unknown
    F_PROJECT=unknown
    [ -n "$F_GEN" ] || F_GEN=unknown
    return 0
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "task record is unavailable: $meta"
  F_KIND=$(ul_clean "$(fm_meta_get "$meta" kind)")
  F_HARNESS=$(ul_clean "$(fm_meta_get "$meta" harness)")
  F_MODEL=$(ul_clean "$(fm_meta_get "$meta" model)")
  F_EFFORT=$(ul_clean "$(fm_meta_get "$meta" effort)")
  F_MODE=$(ul_clean "$(fm_meta_get "$meta" mode)")
  F_YOLO=$(ul_clean "$(fm_meta_get "$meta" yolo)")
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    remote_backend=$(fm_meta_get "$meta" remote_backend)
    if [ -n "$remote_backend" ] && ul_identity_intact "$remote_backend"; then
      F_BACKEND=$remote_backend
    else
      F_BACKEND=unknown
    fi
  else
    # fm-spawn.sh's compatibility contract: an absent backend= means tmux.
    F_BACKEND=$(ul_clean "$(fm_backend_of_meta "$meta")")
  fi
  # The directory NAME only. The recorded path itself never enters the ledger.
  project=$(fm_meta_get "$meta" project)
  if [ -z "$project" ]; then
    F_PROJECT=
  else
    # Trailing separators come off before the name is taken. A remote route is
    # registered in data/secondmates.md exactly as it was written, so a root
    # written "/srv/mate/" reaches the task record with its separator still on
    # and would otherwise reduce to the empty string this schema reads as
    # not-applicable.
    while [ "$project" != "${project%/}" ] && [ -n "${project%/}" ]; do
      project=${project%/}
    done
    F_PROJECT=$(ul_clean "${project##*/}")
    # A project the record DOES carry is unproven rather than absent when its
    # name cannot be read, the same distinction every other axis draws.
    [ -n "$F_PROJECT" ] || F_PROJECT=unknown
  fi
  if [ -z "$F_GEN" ]; then
    gen=$(fm_meta_get "$meta" spawn_gen)
    [ -z "$gen" ] || ul_identity_intact "$gen" \
      || die "task record carries an incarnation token the ledger cannot store unchanged: $meta"
    F_GEN=$gen
  fi
}

# The axes ul_load_meta resolved, as one line, in this fixed order. Only the
# meta-backed fields appear: the outcome fields belong to the event being
# recorded, not to the task record that is about to disappear.
ul_axes_emit() {
  printf '%s"%s"%s"%s"%s"%s"%s"%s"%s\n' \
    "$F_KIND" "$F_HARNESS" "$F_MODEL" "$F_EFFORT" "$F_PROJECT" \
    "$F_MODE" "$F_YOLO" "$F_BACKEND" "$F_GEN"
}

# Restore a previously captured axes line into the same fields ul_load_meta
# sets. Every part was emitted through ul_clean, so a part that does not
# survive it unchanged did not come from a capture and is refused rather than
# reduced into a different, valid-looking task.
ul_axes_load() {  # <line>
  local line=$1 rest part fields=1 kind harness model effort project mode yolo backend gen
  rest=$line
  while [ "$rest" != "${rest#*"$UL_AXES_SEP"}" ]; do
    rest=${rest#*"$UL_AXES_SEP"}
    fields=$((fields + 1))
  done
  [ "$fields" -eq "$UL_AXES_COUNT" ] \
    || die "captured axes do not carry the ledger's $UL_AXES_COUNT fields"
  IFS="$UL_AXES_SEP" read -r kind harness model effort project mode yolo backend gen \
    <<< "$line"
  for part in "$kind" "$harness" "$model" "$effort" "$project" "$mode" "$yolo" \
      "$backend" "$gen"; do
    ul_identity_intact "$part" || die "captured axes carry a value the ledger cannot store unchanged"
  done
  F_KIND=$kind
  F_HARNESS=$harness
  F_MODEL=$model
  F_EFFORT=$effort
  F_PROJECT=$project
  F_MODE=$mode
  F_YOLO=$yolo
  F_BACKEND=$backend
  # An explicit --gen still wins, exactly as it does over a task record.
  [ -n "$F_GEN" ] || F_GEN=$gen
}

# 0 when <class> is a verb this home's vocabulary recognises. bin/fm-classify-lib.sh
# owns that vocabulary, so the three verbs a home may rename are resolved
# through its overrides rather than spelled out again here. A configured verb
# the ledger could not store unchanged is not one it can record.
ul_status_class_known() {  # <class>
  local class=$1
  ul_identity_intact "$class" || return 1
  case "$class" in
    done|failed|blocked|needs-decision|working) return 0 ;;
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") return 0 ;;
    "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}") return 0 ;;
    "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") return 0 ;;
  esac
  return 1
}

# The final status VERB only, mapped to the closed vocabulary. The note is
# never read into the ledger. A log missing from a directory that is still
# there is an absence the task proved ("none"); one that cannot be read safely,
# or whose directory is gone too, is a class nothing proved ("unknown"), the
# same distinction ul_load_meta draws.
ul_status_class() {  # <status-file>
  local file=$1 line verb dir
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    dir=${file%/*}
    [ "$dir" != "$file" ] || dir=.
    if [ -d "$dir" ]; then
      printf 'none\n'
    else
      printf 'unknown\n'
    fi
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] \
    || { printf 'unknown\n'; return 0; }
  line=$(last_status_line "$file")
  [ -n "$line" ] || { printf 'none\n'; return 0; }
  verb=$(status_line_verb "$line")
  if ul_status_class_known "$verb"; then
    printf '%s\n' "$verb"
  else
    printf 'unknown\n'
  fi
}

CMD=${1:-}
shift 2>/dev/null || true
case "$CMD" in
  record|list|verify|prune|path|status-class|axes) ;;
  '') usage_error "no subcommand given" ;;
  *) usage_error "unknown subcommand '$CMD'" ;;
esac

# Answered before the store is resolved, because they read no store at all.
if [ "$CMD" = status-class ]; then
  [ "$#" -eq 2 ] && [ "$1" = --status-file ] \
    || usage_error "status-class takes only --status-file <path>"
  ul_status_class "$2"
  exit 0
fi

if [ "$CMD" = axes ]; then
  [ "$#" -eq 2 ] && [ "$1" = --meta ] \
    || usage_error "axes takes only --meta <path>"
  ul_fields_reset
  ul_load_meta "$2"
  [ -n "$F_GEN" ] || F_GEN=unknown
  ul_axes_emit
  exit 0
fi

DATA=$(ul_resolve_dir data "$DATA")
STORE="$DATA/$STORE_NAME"
LOCK="$DATA/.$STORE_NAME.lock"
DATA_DEVICE=$(fm_pr_file_device "$DATA") || die "data directory device is unreadable: $DATA"

if [ "$CMD" = path ]; then
  [ "$#" -eq 0 ] || usage_error "path takes no arguments"
  printf '%s\n' "$STORE"
  exit 0
fi

if [ "$CMD" = list ]; then
  RECENT=20
  if [ "${1:-}" = --recent ]; then
    RECENT=${2:-}
    case "$RECENT" in ''|*[!0-9]*|0) usage_error "--recent requires a positive integer" ;; esac
    shift 2
  fi
  [ "$#" -eq 0 ] || usage_error "list takes only --recent <n>"
  [ -s "$STORE" ] || exit 0
  ul_store_valid || die "task-usage ledger is not a private regular file on the data device: $STORE"
  tail -n "$RECENT" "$STORE"
  exit 0
fi

if [ "$CMD" = verify ]; then
  [ "$#" -eq 0 ] || usage_error "verify takes no arguments"
  if [ ! -e "$STORE" ] && [ ! -L "$STORE" ]; then
    printf 'ok records=0 first_observed=none\n'
    exit 0
  fi
  ul_store_valid || die "task-usage ledger is not a private regular file on the data device: $STORE"
  ul_store_scan || exit 1
  printf 'ok records=%s first_observed=%s\n' "$UL_COUNT" "${UL_FIRST_OBSERVED:-none}"
  exit 0
fi

if [ "$CMD" = prune ]; then
  DAYS=$RETENTION_DAYS
  if [ "${1:-}" = --days ]; then
    DAYS=${2:-}
    shift 2
  fi
  case "$DAYS" in ''|*[!0-9]*|0) usage_error "--days requires a positive integer" ;; esac
  [ "$#" -eq 0 ] || usage_error "prune takes only --days <n>"
  fm_lock_acquire_wait "$LOCK"
  trap prune_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  if [ ! -e "$STORE" ] && [ ! -L "$STORE" ]; then
    printf 'pruned 0 kept 0\n'
    exit 0
  fi
  ul_store_valid || die "task-usage ledger is not a private regular file on the data device: $STORE"
  ul_store_scan || exit 1
  CUTOFF=$(( $(date +%s) - DAYS * 86400 ))
  PRUNE_TMP=$(mktemp "$DATA/.$STORE_NAME.XXXXXX") || die "task-usage ledger temp file could not be created in $DATA"
  KEPT=0
  DROPPED=0
  while IFS= read -r line || [ -n "$line" ]; do
    ul_record_parse "$line" || die "task-usage ledger became unreadable mid-prune; its bytes are left untouched at $STORE"
    if [ "$UL_REC_EVENT" != ledger-open ] && [ "$UL_REC_AT" -lt "$CUTOFF" ]; then
      DROPPED=$((DROPPED + 1))
      continue
    fi
    printf '%s\n' "$line" || die "task-usage ledger retention could not be staged"
    KEPT=$((KEPT + 1))
  done < "$STORE" >> "$PRUNE_TMP"
  if [ "$DROPPED" -gt 0 ] && [ "$KEPT" -eq 1 ]; then
    ul_prune_carry_sequence "$PRUNE_TMP" "$UL_LAST_SEQ" \
      || die "task-usage ledger retention could not carry the sequence forward at $STORE"
  fi
  if [ "$DROPPED" -eq 0 ]; then
    rm -f -- "$PRUNE_TMP"
    PRUNE_TMP=
    printf 'pruned 0 kept %s\n' "$KEPT"
    exit 0
  fi
  ul_publish "$PRUNE_TMP" "$STORE" || die "task-usage ledger retention could not be published at $STORE"
  PRUNE_TMP=
  printf 'pruned %s kept %s\n' "$DROPPED" "$KEPT"
  exit 0
fi

# record
EVENT=
TASK=
META=
RAW_AXES=
STATUS_FILE=
RAW_GEN=
RAW_PR=
RAW_PR_HEAD=
RAW_LANDING=
ul_fields_reset
F_VALIDATOR_HARNESS=unknown
F_VALIDATOR_MODEL=unknown
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event) EVENT=${2:-}; shift 2 || usage_error "--event requires a value" ;;
    --task) TASK=${2:-}; shift 2 || usage_error "--task requires a value" ;;
    --meta) META=${2:-}; shift 2 || usage_error "--meta requires a value" ;;
    --axes) RAW_AXES=${2:-}; shift 2 || usage_error "--axes requires a value" ;;
    --gen) RAW_GEN=${2:-}; shift 2 || usage_error "--gen requires a value" ;;
    --pr) RAW_PR=${2:-}; shift 2 || usage_error "--pr requires a value" ;;
    --pr-head) RAW_PR_HEAD=${2:-}; shift 2 || usage_error "--pr-head requires a value" ;;
    --landing) RAW_LANDING=${2:-}; shift 2 || usage_error "--landing requires a value" ;;
    --outcome) F_OUTCOME=${2:-}; shift 2 || usage_error "--outcome requires a value" ;;
    --status-file) STATUS_FILE=${2:-}; shift 2 || usage_error "--status-file requires a value" ;;
    --status-class) F_STATUS_CLASS=${2:-}; shift 2 || usage_error "--status-class requires a value" ;;
    --validator-harness) F_VALIDATOR_HARNESS=$(ul_clean "${2:-}"); shift 2 || usage_error "--validator-harness requires a value" ;;
    --validator-model) F_VALIDATOR_MODEL=$(ul_clean "${2:-}"); shift 2 || usage_error "--validator-model requires a value" ;;
    *) usage_error "unknown record option '$1'" ;;
  esac
done

case "$EVENT" in
  spawn|pr|merge|cleanup) ;;
  '') usage_error "record requires --event <spawn|pr|merge|cleanup>" ;;
  *) usage_error "unknown --event '$EVENT'" ;;
esac
# Every identity-bearing input is validated in the RAW form the caller supplied
# and refused when the ledger cannot store it unchanged. Reducing one first
# would let the field bound rewrite a real merge request, incarnation, or task
# into a different real one and record that as fact.
ul_identity_intact "$TASK" \
  || usage_error "--task must be at most $UL_FIELD_MAX printable characters"
fm_pr_task_id_valid "$TASK" || usage_error "record requires a valid --task id"
ul_identity_intact "$RAW_GEN" \
  || usage_error "--gen must be at most $UL_FIELD_MAX printable characters"
F_GEN=$RAW_GEN
case "$F_OUTCOME" in
  ''|landed|discarded|reported|retired|merged) ;;
  *) usage_error "unknown --outcome '$F_OUTCOME'" ;;
esac
# A PR URL is only ever stored in its validated canonical form.
if [ -n "$RAW_PR" ]; then
  ul_identity_intact "$RAW_PR" "$UL_PR_MAX" \
    || usage_error "--pr must be at most $UL_PR_MAX printable characters"
  fm_pr_url_parse "$RAW_PR" || usage_error "--pr requires a canonical pull request or merge request URL"
  F_PR=$FM_PR_URL
fi
# A full hash is short and hexadecimal, so validating the raw value is itself
# the proof that storing it needs no reduction.
if [ -n "$RAW_PR_HEAD" ]; then
  fm_pr_head_valid "$RAW_PR_HEAD" || usage_error "--pr-head requires a full commit hash"
  F_PR_HEAD=$RAW_PR_HEAD
fi
if [ -n "$RAW_LANDING" ]; then
  fm_pr_head_valid "$RAW_LANDING" || usage_error "--landing requires a full commit hash"
  F_LANDING=$RAW_LANDING
fi
# A caller supplies the final status class either as the log to read or as an
# already-resolved class, never as both, and only from the closed vocabulary.
if [ -n "$F_STATUS_CLASS" ]; then
  [ -z "$STATUS_FILE" ] \
    || usage_error "--status-class and --status-file are alternatives"
  case "$F_STATUS_CLASS" in
    none|unknown) ;;
    *) ul_status_class_known "$F_STATUS_CLASS" \
         || usage_error "unknown --status-class '$F_STATUS_CLASS'" ;;
  esac
fi
# An explicitly empty validator axis is still unproven, never not-applicable.
if [ -z "$F_VALIDATOR_HARNESS" ]; then F_VALIDATOR_HARNESS=unknown; fi
if [ -z "$F_VALIDATOR_MODEL" ]; then F_VALIDATOR_MODEL=unknown; fi

F_TASK=$TASK
# The axes come from the task record, or from a capture a caller took while
# that record was still there. Never from both: they are the same axes read at
# two different moments, and a caller that has the capture is exactly the
# caller whose own sequence has since deleted the record.
if [ -n "$RAW_AXES" ]; then
  [ -z "$META" ] || usage_error "--axes and --meta are alternatives"
  ul_axes_load "$RAW_AXES"
elif [ -n "$META" ]; then
  ul_load_meta "$META"
fi
[ -n "$F_GEN" ] || F_GEN=unknown
if [ -n "$STATUS_FILE" ]; then
  F_STATUS_CLASS=$(ul_status_class "$STATUS_FILE")
fi

case "$EVENT" in
  spawn) IDENTITY="spawn:$F_TASK:$F_GEN" ;;
  pr) IDENTITY="pr:$F_TASK:$F_GEN:$F_PR:${F_PR_HEAD:--}" ;;
  merge) IDENTITY="merge:$F_TASK:${F_PR:--}:${F_LANDING:--}" ;;
  cleanup) IDENTITY="cleanup:$F_TASK:$F_GEN" ;;
esac
IDENTITY=$(ul_clean "$IDENTITY" "$UL_IDENTITY_MAX")

if [ ! -d "$DATA" ] || [ -L "$DATA" ]; then
  die "data directory is unavailable: $DATA"
fi
fm_lock_acquire_wait_bounded "$LOCK" "$RECORD_LOCK_TIMEOUT" \
  || die "task-usage ledger lock could not be taken within ${RECORD_LOCK_TIMEOUT}s at $LOCK"
trap record_cleanup EXIT
trap 'exit 1' HUP INT TERM
ul_store_open
ul_store_probe "$IDENTITY" || exit 1
if [ "$UL_DUPLICATE" = 1 ]; then
  printf 'duplicate\n'
  exit 0
fi
SEQ=$(( UL_LAST_SEQ + 1 ))
ul_emit "$SEQ" "$(date +%s)" "$EVENT" "$IDENTITY" >> "$STORE" \
  || die "task-usage ledger record could not be appended at $STORE"
printf 'recorded %s\n' "$SEQ"
