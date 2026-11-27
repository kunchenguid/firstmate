#!/usr/bin/env bash
# fm-captain-hold.sh - deterministic mechanics for tasks held for the captain.
#
# The semantic policy is owned once by
# .agents/skills/captain-hold-lifecycle/SKILL.md. This script never reads
# report, visual-review, chat, or terminal prose to guess whether the captain
# owes an answer. The invoking agent decides what is genuinely waiting on the
# captain; this script supplies guarded creation, a durable record of what the
# captain actually said, the investigation completion gate, and the one
# keyed-answer intake every channel feeds.
#
# There is no separate decision type. A captain call is an ordinary backlog
# task held for the captain through this script's mandatory `hold` subcommand,
# and its identity is simply the task id. Older installs created derived
# `<origin>-decision-<key>` identities through bin/fm-decision-hold.sh; those
# rows are already plain task ids, so they keep working here unchanged, and
# the legacy inputs noted below resolve them without a migration.
# All backlog reads and mutations address the active home's configured data
# directory the way bin/fm-backlog-transition-lib.sh does, which keeps main-home
# and secondmate-home ownership aligned with the work that discovered the call.
#
# Usage:
#   fm-captain-hold.sh hold <task-id> --reason <reason> \
#     [--title <title>] [--repo <repo>] [--origin <origin-id>] [--until YYYY-MM-DD] \
#     --category <category> [--context-file <path>]
#   fm-captain-hold.sh answer <task-id> --decision-file <path> [--release] [--expected-lifecycle <identity>] [--check-only]
#   fm-captain-hold.sh answer <task-id> --deadline-default
#   fm-captain-hold.sh defaults-due
#   fm-captain-hold.sh stop-clock <task-id> --source <provenance>
#   fm-captain-hold.sh contexts   (pure canonical-backlog JSON codec on stdin)
#   fm-captain-hold.sh answers [<legacy-origin> | --any-origin] --source <provenance> [--prepare]   (keyed answers on stdin)
#     --prepare emits only validated rows without closing; --check-only validates
#     one answer without recording it. Delivery callers must recheck at closure.
#   fm-captain-hold.sh reconcile-requests --source-id <source-id> --source <provenance>   (task ids on stdin)
#   fm-captain-hold.sh bind <source-id> [<legacy-origin> | --any-origin]
#   fm-captain-hold.sh unbind <source-id>
#   fm-captain-hold.sh binding <source-id>
#   fm-captain-hold.sh complete <origin-id> (--none | <task-id>...)
#   fm-captain-hold.sh verify <origin-id>
#   fm-captain-hold.sh open <task-id> [--identity] [--distinguish-absent]
#   fm-captain-hold.sh answered <task-id>  (read-only; a completed call with the captain's own answer)
#   fm-captain-hold.sh diverged
#   fm-captain-hold.sh reconcile list
#   fm-captain-hold.sh reconcile close <task-id> --evidence-file <path>
#   fm-captain-hold.sh reconcile note <task-id> --note-file <path>
#
# `hold` places an existing task under an active captain hold, or creates the
# task first when no work item exists to hold (--title required to create; the
# optional --origin records provenance in the new task's body and supplies the
# default repo from that origin's metadata). Prefer holding the work item the
# question gates over minting a new row. Creating a missing row uses
# `tasks-axi add --kind captain`: that kind is backlog metadata, and the Beads
# adapter maps it to native issue type `task`. Captain holds have no due
# semantics (`--until` is the optional hold deferral), so the create waives
# Beads `due.required` through `BD_DUE_REQUIRED` rather than inventing a due
# date or registering a `types.custom` captain issue type. The command records
# a UTC `Captain hold set:` timestamp in the task body: repeating an active
# hold preserves the existing timestamp, while re-holding released work starts
# a new lifecycle. A task already closed is refused rather than reopened.
# `--origin` also records the origin on a `Captain hold origin:` body line, which
# `complete` and `verify` check. The reason may hold parentheses and line breaks:
# tasks-axi refuses them, so `hold` escapes them where it writes the reason and
# readers decode them (bin/fm-hold-reason-lib.sh owns the encoding).
# `--until` records the captain's own deferral date through `tasks-axi hold
# --until`, so a "revisit later" answer is stored as a date instead of a live
# card.
# `--category` declares which captain-owned class the call is: money,
# architecture-deviation, destructive, security-sensitive, credential-or-login,
# or captain-only-fact. A fresh hold lifecycle is refused without a valid
# category: ASK LESS (data/captain-shared.md) keeps only those classes with the
# captain, so a call outside them is chosen and reported instead of held, and a
# read-only or reversible in-plan step needs no hold absent a genuine gate.
# The category is recorded on a `Captain hold category:` body line below the
# same durable pattern as the origin line. Re-holding an active call preserves
# its recorded category (an exact retry passes the same one), and a row held
# before this gate re-holds uncategorized with a warning instead of breaking,
# because its lifecycle already exists.
#
# `answer` records the captain's exact words and resolves the call in the same
# act. It requires a non-empty captain decision file of at most 8192 bytes and
# writes a resolution block while preserving the leading hold-set stamp until
# the close succeeds (the previous body is preserved and archived through
# tasks-axi --archive-body). It closes a question with `tasks-axi done` - or,
# with `--release`, lifts the hold with `tasks-axi unhold` so a captain-gated
# WORK item resumes without closing - and restores resolution-first body
# ordering. `--release` is attended-only: while the away-posture record exists
# (state/.afk-contract, or the daemon flag state/.afk, read as away; a quiet
# record is a present captain) it is refused before anything is written, so an
# unattended supervisor cannot free held work with its own words and then steer
# it; the captain releases the hold in an attended session. A closing answer
# without `--release` is not gated by posture. An exact retry also completes
# unfinished ordering normalization and
# is idempotent only when its requested close mode
# matches the newest record; a changed decision or a mode mismatch is rejected.
# A re-held task may record a new answer on top. On a task already closed outside this script,
# `answer` records the missing resolution block (the old `repair` path) only
# when the task still carries the captain-hold provenance tasks-axi preserves
# through a close, so an ordinary finished task cannot be dressed up as an
# answered captain call. A hold that expired by date (`--until` in the past) is
# still answerable: the surviving hold annotations, not tasks-axi's live
# `held:` bit, prove the captain owned it.
#
# QUESTION CONTEXT: ONE OWNER, SAME BACKLOG BODY.
# `hold --context-file` accepts one JSON object, at most 8192 bytes, with schema
# `fm-captain-question.v1`, mandatory close `done|release`, about and purpose
# (below), optional question
# (the full question as the captain should read it: nonblank, <=600 chars,
# newlines allowed but no other control characters), options
# (at most 12 unique {value,label,detail} objects; slug values <=64 chars, printable
# nonblank labels <=120 chars, printable nonblank detail <=300 chars; `reconcile`
# is reserved), recommendation (null
# or an option value), and subject (null or {artifact:<slug <=128>,
# version:<numeric x.y.z <=64 chars>}). Unknown fields/versions and malformed input refuse
# before any mutation. Omitted options/recommendation/subject become []/null/null;
# an omitted or null question stays absent. about, purpose, question and detail
# are display text only and never change answer routing.
# PLAIN LANGUAGE: the reader is a non-technical manager who did not build the
# work and must understand the card at once. `about` says what this is and
# `purpose` says what answering it unlocks or prevents and what happens while
# it stays unanswered: each one printable line of <=600 chars with no link,
# backtick or GUID, and by the author's care no jargon and no task id, branch,
# path or other internal name.
# Each option's `detail` is the plain consequence of picking it, and the
# recommended option's detail also says why it is recommended. `hold` refuses a
# context that lacks about, purpose or any option detail, or whose about or
# purpose carries a link, backtick or GUID, naming that reader.
# A context stored before this rule stays valid and answerable, and the live
# board marks it as needing a plain-language explanation.
# PERSONAL ACTION: set `action: true` for a step only the captain can take.
# Give the destination by its familiar name in `about`; use `question` for
# the ordered steps and exact result to send back (include a link there if
# needed); use `purpose` for what waits and what the crew can keep doing.
# An action needs a question and can never carry a recommendation or deadline
# default. `answered` checks the completed call's latest resolution without
# printing the answer. It does not judge whether the reported result passed.
# DEADLINE DEFAULT: a context may also carry scope (a nonempty unique list from
# product, copy, outward-facing, irreversible, money, security),
# default_eligible (exactly "small-reversible") and exactly one deadline:
# default_date (YYYY-MM-DD, day level) or default_at (YYYY-MM-DDTHH:MM:SSZ,
# hour level). The marker and the deadline come together, and they require a
# recommendation and a scope of only product or copy; `hold` refuses anything
# else, including a default_date that is not later than today or a default_at
# less than 24 hours after the hold-set stamp, unless that exact deadline is
# already published. A stored context that breaks the rule reads as invalid, so
# it never comes due.
# EFFECT CHECK: independently of the declared scope, `hold` refuses a default
# whose recommended option or question names an effect a default may never
# carry (merging, pushing, publishing, sending, deleting, spending, access,
# credentials, customers and the like; the word list lives in
# fm_question_default_effect in bin/fm-captain-question-context.jq), and on
# read such a call never comes due, so a self-labelled small call cannot
# proceed without the captain. A false match only keeps the call waiting.
# A default_date is the captain's last day to answer: the call comes due the
# UTC day after it. A default_at comes due at that instant. Either way it is
# due only while the call is still open, not deferred to a later `--until`, and
# its clock was not stopped.
# `stop-clock` stops this lifecycle's deadline default for good: it appends one
# `Captain deadline default stopped: <lifecycle> at <stamp> by <provenance>`
# line to the active header under the task-control lock, after which the call
# never comes due and only an answer settles it. It is idempotent, needs an
# open captain call whose active context carries a default, and a later hold
# of the same task starts a new lifecycle the stop does not cover.
# `defaults-due` lists due calls as
# `<task-id>\t<deadline>\t<value>\t<label>\t<close>\t<title>` and changes nothing.
# It keeps what the backlog says about each pending default in state/.defaults-due-cache
# (keyed on the backlog, its backend and these scripts, so any change rereads it) and
# reads the clock live, so a default still comes due at its instant.
# `answer --deadline-default` is the only way to apply one: it rechecks that the
# call is due, generates the words itself, and records them through the same
# guarded answer path under a label that says they are not the captain's. It uses
# the context's close mode, so a `release` default stays attended-only like any
# other release. A captain answer needs no special handling: it closes the call,
# after which the lifecycle guard refuses the default.
# The owner adds lifecycle, the exact `open --identity` stamp#answer-count.
# Guarded context requires a valid full UTC stamp; legacy date-only/unknown
# stamps remain read-only until owner review, never assigned an invented time.
# It writes a single `Captain question context: <compact JSON>` line directly
# after the leading hold-set stamp. Historical markers below the newest
# resolution, or prefixed `Previous captain question context:`, are history,
# never authority for a new hold. Missing,
# malformed, misplaced, duplicate or stale active context is not answerable.
# An active hold may acquire missing context, repeat identical context, or gain
# an about, purpose or option detail it lacks with everything else identical,
# or gain a deadline default it lacks with everything else identical apart from
# a previously empty recommendation,
# but cannot change already-published context within that lifecycle.
# Re-holding starts without context unless the owner explicitly supplies it.
# `contexts` enriches canonical {records:[...]} JSON with question_context;
# it reads no home files. The shared jq implementation is mechanical plumbing
# in bin/fm-captain-question-context.jq, not another contract or state reader.
# The canonical reader and home summary retain that structured field; the live
# projection publishes only validated context, not arbitrary body contents.
# `answer --expected-lifecycle` and the optional fifth `answers` field guard
# captured answers under the same task-control lock as hold/answer mutations.
# A guarded new answer requires ready context and its explicit close mode;
# stale lifecycle/mode refuses without mutation, including after same-second
# release/re-hold. The resolution records the answered lifecycle, so exact
# retries can finish interrupted closure/normalization or replay safely.
# A guarded retry may not settle a newer held call even with identical words.
# Legacy unguarded callers retain their existing behavior and default mode.
# No context or guard chooses options/modes from prose or grants new authority.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer resolves its matching captain-held task" is a single
# capability, owned here and nowhere else. `answers` reads
# `<task-id>\t<answer>\t<label>[\t<mode>[\t<expected-lifecycle>]]` lines on stdin and resolves each named
# task through the very same `answer` path above, so every guard applies
# identically no matter which channel the answer arrived on. The key IS the
# task id - no identity arithmetic. The optional fourth field selects the close:
# empty or `done` completes the task, `release` lifts the hold so held work
# resumes; anything else is skipped. A `release` line while the away-posture
# record exists is reported as `refused:` under the same attended-only rule as
# `answer --release` and feeds nothing. A key that names no task, a task that is
# not held for the captain, or a task already closed is reported as `skipped:`
# and feeds nothing. A replayed delivery whose answer digest and requested
# close mode both match the newest record is reported `closed:` and is a no-op;
# a mode mismatch is skipped. The command exits nonzero when any key was
# skipped. `--source` is provenance text recorded in the
# durable decision, never a behavior switch: this command has no per-channel
# branch and no knowledge of chat, review decks, or any transport.
# Legacy input: an optional positional origin (or a stored concrete-origin
# binding) makes a key that names no task fall back to the old
# `<origin>-decision-<key>` identity, so an in-flight pre-collapse channel
# keeps closing its rows; `--any-origin` and the stored `(any)` marker mean
# what an absent origin means and are accepted for the same reason.
#
# RECONCILE IS RESERVED AT THIS INTAKE, NOT FILTERED IN A CHANNEL.
# The exact answer value `reconcile` means "go re-check reality", never "the
# captain answered". `answers` matches it before it reads the close mode,
# visibly refuses it, and never passes it to `answer`, so no channel and no
# card-declared mode can turn it into a close, release, or request. A separate
# `reconcile-requests` intake verifies a captured source's binding before it
# records a durable request under `state/reconcile-requests/`.
#
# `reconcile` is the verify-then-decide half. Both outcomes require the pending
# request created by the captain's board selection. `close` is the moot outcome:
# it requires the evidence that made the call moot, writes a `reconciled` resolution record
# under a `Reconciliation evidence:` label so it can never read as the
# captain's words, and closes the task. `note` is the still-active outcome: it
# appends one dated `Captain hold reconciled:` note and leaves the hold in
# place. A normal answer also retires the request because the call is settled.
# `list` is the read-only enumeration.
# docs/captain-hold-lifecycle.md owns the semantics.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines
# and pipe them here. It must never map keys to tasks, build decision records,
# choose a close mode beyond what its card declared, or close anything itself.
#
# `bind`, `unbind`, and `binding` record that a captured-answer SOURCE feeds
# this intake, for any channel whose answers arrive detached from their origin
# (a process-event source id, for example). The binding is a private record
# under `state/decision-bindings/`; a source with no binding feeds nothing, so
# this whole path is opt-in per source and an unbound source behaves as if it
# did not exist. `bind` deliberately does not require the source to exist yet,
# so a channel can be bound BEFORE it is armed. The optional second argument
# exists only for legacy pre-collapse records and callers: a concrete origin is
# stored verbatim and used as the composition fallback above, and
# `--any-origin` stores the same `(any)` marker a plain `bind <source-id>`
# stores. `binding` prints the stored value verbatim and `answers` accepts it,
# so the process-event runner's feed seam is unchanged.
#
# `complete` is the shared investigation and visual-review completion gate.
# It attests, in the origin task's metadata, the reviewed inventory of
# captain-held tasks that carry the origin's unresolved captain calls.
# `--none` is an explicit semantic attestation that the just-reviewed surface
# has no unresolved captain call, and is refused while the origin still has an
# open keyed status decision. With a non-empty inventory, every listed task is
# verified durable (docs/captain-hold-lifecycle.md owns the inventory checks),
# is never the origin itself, and, when `hold --origin` recorded one, was held
# for this origin; a hold with no recorded origin is accepted on durability
# alone and named in the output,
# the inventory is unioned idempotently into the metadata, and every still-open
# keyed status decision is transferred to its durable owner with a
# `captain-held [key=...]` status close naming the inventory. Later review
# passes may add ids. A post-teardown visual review can complete against the
# surviving report and tasks without recreating task state.
# `verify` is read-only and is called by scout teardown, so teardown cannot
# erase a source before this gate has succeeded: every recorded inventory
# entry must still satisfy the same durability and origin checks as `complete`,
# and no keyed status decision may be open.
# `complete` and `verify` also read an entry that markdown Done retention moved
# into the configured Done archive, where it counts only through a recorded
# resolution; no other subcommand reads the archive.
# Metadata compatibility: the attestation keeps the historical
# `decisions_reviewed=1` and `decision_keys=` keys, and an inventory entry that
# names no existing task resolves through the legacy `<origin>-decision-<entry>`
# identity, so pre-collapse metadata written by fm-decision-hold.sh verifies
# unchanged. An entry that exists as a task id is always that task. On the
# Beads backend an attested legacy markdown id that resolves to no task is
# accepted through the migrated row fm-hold-migration produced, found by the
# authoritative evidence first: a row whose notes carry the marker line
# "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>". Only when no row carries that line is the legacy id tried under
# the configured beads prefix, and that name-only guess is accepted solely for
# a single row still held for the captain; two such rows refuse rather than
# attest, and `complete` names each prefix-resolved row beside its attested
# legacy id so the guess stays auditable.
#
# `open` is the read-only predicate a mechanical closer asks before it may
# retire a task's row: is this task still an open captain call? Exit 0 means it
# is (not Done, hold kind captain), 1 means it is not, and 2 means the answer
# could not be established, so a caller that must never close a live call can
# treat "cannot tell" as its own case instead of as a no. With
# `--distinguish-absent`, an absent local task returns 3 instead of 1; a home
# with no backlog file counts as absent, because it records no captain calls.
# It prints nothing on these predicate results and mutates nothing, unless
# `--identity` asks it to print this call's
# LIFECYCLE identity, which it does on an exit 0 only. That identity - the
# hold-set stamp and the count of recorded answers - is what distinguishes two
# successive calls on one task id: re-holding released work starts a new
# lifecycle without necessarily touching the task's status log, so a consumer
# that bounds repeated work per call cannot use the task id alone.
# bin/fm-teardown.sh asks it before its automatic
# backlog close and, on 0, returns the row to Queued with its deliverable
# recorded instead (bin/fm-backlog-transition-lib.sh owns that transition), so
# holding the very work item a question gates is safe; only `answer` with the
# captain's words or evidence-backed `reconcile close` closes the call.
# bin/fm-watch.sh asks it when an ordinary
# crew task reaches a due stale alarm - its open backlog hold need not appear in
# the task's last status line - and on a 0 bounds repeated alarms from new pane
# hashes for the decision.
#
# `diverged` is the read-only guard over the seam between the two records of
# one captain call. See "record divergence" beside command_diverged below.
#
# Resolution records: the block written into the body names this script, the
# decision digest, and a `Resolution mode:` of answered, released, repaired, or
# reconciled. Records written by the retired fm-decision-hold.sh (routed,
# declined, answered, repaired) are recognized everywhere a record is read, so
# nothing already closed needs rewriting.
#
# Parent channel: inside a secondmate home a task held for the captain, and its
# answer, are captain-facing facts the moment they are recorded, so `hold`
# publishes `needs-decision [key=captain-hold-<task>-<n>]` and `answer` (and
# `answers`) the matching `resolved` line on the parent channel through
# bin/fm-parent-channel-lib.sh, whether or not the mate model appends anything.
# <n> is the count of resolution records the body already carries plus one, so
# a released and re-held task opens and closes a distinct parent decision with
# no new persisted state, and an exact retry republishes the same line, which
# the channel deduplicates. A main home has no channel and publishes nothing.
# The hold or answer is already durable in the backlog, so a channel that
# cannot be written is reported as `actionable:` on stderr rather than undoing
# the record; bin/fm-inactive-reconcile.sh's diagnostics name a broken binding.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-afk-contract.sh"

PARENT_HOLD_PUBLISHED=0
publish_parent_hold() {  # <task-id> <occurrence> <verb> <note>
  local id=$1 occurrence=$2 verb=$3 note=$4 rc=0
  PARENT_HOLD_PUBLISHED=0
  fm_parent_channel_report "$FM_HOME" "$STATE" \
    "$verb [key=captain-hold-$id-$occurrence]: captain hold $id: $(fm_parent_channel_clean_note "$note")" || rc=$?
  case "$rc" in
    0|1) PARENT_HOLD_PUBLISHED=1 ;;
    *) printf 'actionable: task %s is held for the captain in this home but that did not reach the parent channel (rc=%s)\n' "$id" "$rc" >&2 ;;
  esac
}

CAPTAIN_META_LOCK=
CAPTAIN_META_LOCK_HELD=0
CAPTAIN_CONTROL_LOCK=
CAPTAIN_CONTROL_LOCK_HELD=0
captain_hold_cleanup() {
  if [ "$CAPTAIN_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_META_LOCK" || true
    CAPTAIN_META_LOCK_HELD=0
  fi
  if [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_CONTROL_LOCK" || true
    CAPTAIN_CONTROL_LOCK_HELD=0
  fi
  fm_afk_contract_lock_release || true
}
trap captain_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

# ASK LESS (data/captain-shared.md) keeps only these call classes with the
# captain, so every fresh hold lifecycle declares which one it is; a call
# outside them is refused before any write and the agent decides and reports
# it instead of stalling the work on the captain.
CAPTAIN_HOLD_CATEGORIES='money architecture-deviation destructive security-sensitive credential-or-login captain-only-fact'
CAPTAIN_HOLD_CATEGORY_LIST='money, architecture-deviation, destructive, security-sensitive, credential-or-login, captain-only-fact'
CAPTAIN_HOLD_CATEGORY_GATE="a captain hold must declare --category ($CAPTAIN_HOLD_CATEGORY_LIST): a call outside those classes belongs to ASK LESS (data/captain-shared.md), so choose the best option and report it - a read-only or reversible in-plan step needs no hold absent a genuine captain-owned gate; continue work within standing authority and report afterwards"

valid_hold_category() {  # <category>
  local accepted
  for accepted in $CAPTAIN_HOLD_CATEGORIES; do
    [ "$1" != "$accepted" ] || return 0
  done
  return 1
}

acquire_task_control_lock() {  # <task-id>
  CAPTAIN_CONTROL_LOCK="$STATE/.control-$1.lock"
  fm_lock_acquire_wait "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=1
}

release_task_control_lock() {
  [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=0
  CAPTAIN_CONTROL_LOCK=
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

# The legacy derived identity older installs minted for a captain call.
# Kept only to resolve pre-collapse rows, metadata entries, and channel keys.
legacy_hold_id() {  # <origin-id> <key>
  printf '%s-decision-%s' "$1" "$2"
}

# The legacy any-origin binding marker. Slug validation rejects parentheses, so
# no real origin id or task id can collide with it.
BINDING_ANY='(any)'

DECISION_TEXT=''
DECISION_DIGEST=''
ANSWER_LIFECYCLE=''

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

# Mutations address the configured data directory's backlog from its root, the
# way bin/fm-backlog-transition-lib.sh addresses every transition, so a home
# with a relocated data directory keeps one backlog. The explicit --file file
# belongs to the markdown backend only; a non-markdown backend is addressed by
# the root's own tasks-axi configuration, exactly like the transition library's
# mutate path.
tasks_axi() {
  local data file root backend
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  root=$(fm_backlog_root "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
    (cd "$root" && tasks-axi "$@" --file "$file")
  else
    (cd "$root" && tasks-axi "$@")
  fi
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

# Read one row into TASK_SHOW_OUTPUT; a non-zero return means the row is
# absent. A read that could not finish inside its bound is NOT absence, and
# every caller below would otherwise spend it as one - minting a duplicate task,
# skipping a keyed answer, or reporting a task that exists as missing. So the
# bound's own status stops the command instead, loudly and by name, and it
# leaves 124 intact rather than collapsing to fail's 1 so a caller running this
# inside a command substitution can still tell a wedged backend from a
# genuinely unknown id.
TASK_SHOW_OUTPUT=
task_show() {  # <id>; sets TASK_SHOW_OUTPUT
  local data status=0 reason
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  TASK_SHOW_OUTPUT=$(fm_backlog_row_show "$data" "$1" --full 2>/dev/null) || status=$?
  if [ "$status" -eq 124 ]; then
    reason=${TASK_SHOW_OUTPUT%%$'\n'*}
    printf 'fm-captain-hold: %s\n' \
      "${reason:-tasks-axi show $1 exceeded its backlog read bound}" >&2
    exit 124
  fi
  return "$status"
}

# Read one row into `show`, failing with <absence-message> only when the read
# genuinely failed; a read-bound hit (124) stops the command by name instead.
# task_show must be called in THIS shell, not inside a command substitution:
# it carries the row in TASK_SHOW_OUTPUT, which a subshell cannot hand back.
task_show_or_fail() {  # <id> <absence-message>; sets show
  task_show "$1" || {
    [ "$?" -ne 124 ] || fail "the backlog backend exceeded its read bound reading $1"
    fail "$2"
  }
  show=$TASK_SHOW_OUTPUT
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# A shown scalar field arrives as a JSON-encoded bare string, which decode_json
# accepts only where the installed JSON::PP defaults allow_nonref on. Older
# libraries default it off and reject the whole value as "must be object or
# array", so ask for it explicitly rather than inheriting the local default.
decode_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Decode show-encoded scalar fields and normalize the empty marker.
show_field_value() {  # <show-output> <field>
  local value
  value=$(decode_shown_value "$(show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1"
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# A resolution record written by this script or by the retired
# fm-decision-hold.sh. Both carry the same leader-then-captain-decision shape.
body_has_resolution_record() {  # <task-body>
  case "$1" in
    *"Resolution recorded by fm-captain-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-decision-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"Reconciliation evidence:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"$DEADLINE_DEFAULT_LABEL"*) return 0 ;;
  esac
  return 1
}

# The recorded decision digest of either record format, from the show-escaped
# body (multi-line bodies print as one quoted line with \n escapes). Records
# are prepended, so the first match is the newest record.
recorded_decision_digest() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Decision digest: "*) rest=${rest#*"Decision digest: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

# How many resolution records the shown body carries, in either record format.
resolution_record_count() {  # <task-body>
  local body
  body=$(decode_shown_value "$1") || return 1
  printf '%s\n' "$body" \
    | grep -Ec '^Resolution recorded by fm-(captain|decision)-hold\.$' || true
}

# The newest record's `Resolution mode:` value; empty for a record predating it.
recorded_resolution_mode() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Resolution mode: "*) rest=${rest#*"Resolution mode: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

closed_answer_replay_mode_compatible() {  # <mode> <task-body>
  case "$1" in
    answered|repaired|routed) return 0 ;;
  esac
  return 1
}

# The record's label is what keeps an evidence-backed reconciliation or a
# deadline default from reading as the captain's own words. `reconciled` closes a
# call that went moot and carries verified evidence; a deadline default carries
# the owner's generated words; everything else carries what the captain said.
DEADLINE_DEFAULT_LABEL="Deadline default (not the captain's words):"
DEADLINE_DEFAULT=0
resolution_block() {  # <mode>
  local label='Captain decision:'
  [ "$1" != reconciled ] || label='Reconciliation evidence:'
  [ "$DEADLINE_DEFAULT" != 1 ] || label=$DEADLINE_DEFAULT_LABEL
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: %s\n' "$DECISION_DIGEST" "$1"
  [ -z "$ANSWER_LIFECYCLE" ] || printf 'Captain answer lifecycle: %s\n' "$ANSWER_LIFECYCLE"
  printf '\n%s\n%s\n' "$label" "$DECISION_TEXT"
}

# Durable state of one captain call: an active captain hold (annotations
# surviving even when a date gate has expired) or a recorded captain answer.
# Without captain annotations, an open task's leading stamp can signal an
# incomplete re-hold or unfinished release normalization; the old record alone
# cannot vouch for that state. Done tasks retain their recorded resolution as
# evidence, and verify_entry_durable separately checks the stored origin.
verify_hold_durable() {  # <task-id>
  local id=$1 show state hold_kind body archived_status
  task_show "$id" || {
    [ "$?" -ne 124 ] || fail "the backlog backend exceeded its read bound reading $id"
    task_show_archived "$id" || {
      archived_status=$?
      [ "$archived_status" -ne 124 ] || exit 124
      fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
    }
  }
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" != "done" ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if body_has_resolution_record "$body"; then
    if [ "$state" != "done" ] \
      && [ -n "$(body_hold_set_timestamp "$(decode_shown_value "$body")")" ]; then
      fail "captain-held task $id carries a recorded answer from an earlier call, but its newer hold never completed; re-run the hold or answer it again"
    fi
    return 0
  fi
  fail "captain-held task $id is neither held for the captain nor closed with a recorded captain answer"
}

# --- migrated legacy-id resolution on the Beads backend ---------------------
#
# A home that moved its backlog from markdown to Beads no longer carries the
# legacy hold ids a scout report attested: the migration rehomed every held
# row under a prefixed fm- id and recorded its markdown identity in the row's
# notes as "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>" (fm-hold-migration wrote the dated form on 2026-09-04). When an
# attested legacy id resolves to no task, the beads backend accepts the row the
# migration produced, found by scanning the configured graph's notes for either
# form of that marker line, and only when no row carries the marker by
# prepending the configured prefix to the legacy id - a name-only guess, so it
# is accepted solely for a row still held for the captain and only when it is
# the single such row. A markdown home keeps its legacy rows verbatim, so its
# exact-id resolution is unchanged.

CAPTAIN_MIGRATION_SCAN_LOADED=0
CAPTAIN_MIGRATION_SCAN_JSON=
NL_SEP=$'\n'

# Section-aware extraction from a .tasks.toml: only the named keys inside the
# named section, comments stripped. Prints "<key> <value>" lines.
captain_toml_section_entries() {  # <toml-file> <section> <key-alternation>
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v section="[$2]" -v keys="^($3)[[:space:]]*=" '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    BEGIN { insection = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { insection = (line == section); next }
      if (!insection) next
      if (line ~ keys) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "%s %s\n", key, line
      }
    }
  ' "$1"
}

captain_beads_toml_entries() {  # <toml-file>
  captain_toml_section_entries "$1" beads 'prefix|path|binary'
}

captain_beads_setting() {  # <entries-output> <setting>
  printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1
}

# Read the configured beads graph's row listing for a migration-note scan.
# The listing is deliberately re-read per unresolvable key: the cache below
# lives and dies with the command-substitution subshell every resolve_entry
# call site runs in, so it cannot persist across keys - bounded by a scout
# report's handful of attested ids. Returns 0 when the listing loads, and 2
# with the reason on stderr when the graph cannot be read.
captain_migration_scan_load() {  # <resolved-data-dir>
  local data=$1 root entries bd_bin bd_path backend
  [ "$CAPTAIN_MIGRATION_SCAN_LOADED" = 1 ] && return 0
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the configured data directory cannot be resolved for a migration scan: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" != beads ]; then
    CAPTAIN_MIGRATION_SCAN_LOADED=1
    return 0
  fi
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  bd_bin=$(captain_beads_setting "$entries" binary)
  bd_path=$(captain_beads_setting "$entries" path)
  bd_bin=${bd_bin:-bd}
  if [ -z "$bd_path" ]; then
    printf 'fm-captain-hold: the beads backend carries no graph path in %s, so a migrated hold cannot be found\n' "$root/.tasks.toml" >&2
    return 2
  fi
  # A relative [beads] path resolves against the backlog root, the same rule
  # every other .tasks.toml path consumer uses, never against the process CWD.
  case "$bd_path" in
    /*) ;;
    *) bd_path="$root/$bd_path" ;;
  esac
  command -v "$bd_bin" >/dev/null 2>&1 || {
    printf 'fm-captain-hold: the beads binary %s is not on PATH, so a migrated hold cannot be found\n' "$bd_bin" >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-captain-hold: jq is required to scan the beads graph for a migrated hold\n' >&2
    return 2
  }
  local bd_err
  bd_err=$(mktemp "${TMPDIR:-/tmp}/fm-captain-hold-bd.XXXXXX") || {
    printf 'fm-captain-hold: cannot stage the beads graph read diagnostics\n' >&2
    return 2
  }
  if ! CAPTAIN_MIGRATION_SCAN_JSON=$(BEADS_DIR="$bd_path" "$bd_bin" list --all --json 2>"$bd_err"); then
    printf 'fm-captain-hold: reading the beads graph at %s failed (%s), so a migrated hold cannot be found\n' \
      "$bd_path" "$(sanitize_field "$(head -c 200 "$bd_err" | tr '\n' ' ')")" >&2
    rm -f "$bd_err"
    return 2
  fi
  rm -f "$bd_err"
  CAPTAIN_MIGRATION_SCAN_LOADED=1
  return 0
}

# Resolve one attested legacy id to the migrated row that carries it on the
# beads backend. Prints "<row id> <how>" and returns 0 when exactly one
# migration matches, returns 1 when none does, and returns 2 with the reason on
# stderr when the scan itself cannot run or is ambiguous. The marker note is the
# authoritative evidence and is scanned first; the bare configured prefix is a
# guess, so it only runs when no marker line matches any identity and it accepts
# a row solely when that row is itself still held for the captain.
resolve_migrated_entry() {  # <origin-or-empty> <entry>
  local origin=$1 entry=$2 data root entries prefix derived show backend
  local candidate candidate_matches prefixed matches count prefixed_matches prefixed_count
  data=$(fm_backlog_data_absolute "$DATA") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  [ "$backend" = beads ] || return 1
  # Every identity this entry could have been migrated under: the raw entry,
  # and - for a pre-collapse channel key - the derived legacy identity its
  # origin would have minted, because fm-hold-migration recorded the DERIVED
  # id in each migrated row's marker note.
  CAPTAIN_MIGRATION_IDENTITIES=$entry
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    derived=$(legacy_hold_id "$origin" "$entry")
    if [ "$derived" != "$entry" ]; then
      CAPTAIN_MIGRATION_IDENTITIES="$CAPTAIN_MIGRATION_IDENTITIES $derived"
    fi
  fi
  captain_migration_scan_load "$data" || return 2
  matches=
  if [ -n "$CAPTAIN_MIGRATION_SCAN_JSON" ]; then
    for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
      candidate_matches=$(printf '%s\n' "$CAPTAIN_MIGRATION_SCAN_JSON" | jq -r \
        --arg exact "migrated from data/backlog.md id $candidate" \
        --arg dated "migrated from data/backlog.md id $candidate on " \
        '.[] | select(((.notes // "") | split("\n")) | any(. == $exact or startswith($dated))) | .id' 2>/dev/null) || {
        printf 'fm-captain-hold: the beads graph scan for the migrated hold of %s could not be parsed\n' "$candidate" >&2
        return 2
      }
      matches="${matches}${matches:+$NL_SEP}${candidate_matches}"
    done
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$count" in
      0) : ;;
      1) printf '%s migrated-note' "$(printf '%s\n' "$matches" | sed '/^$/d' | sed -n 1p)"; return 0 ;;
      *)
        printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s rows carry its marker line (identities tried: %s)\n' \
          "$entry" "$count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
        return 2
        ;;
    esac
  fi
  # No marker line anywhere: a mechanical migration keeps the legacy id under
  # the configured prefix, but that name alone is evidence of nothing, so only
  # a row still held for the captain - and only one of them - is accepted.
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  prefix=$(captain_beads_setting "$entries" prefix)
  [ -n "$prefix" ] || return 1
  prefixed_matches=
  for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
    case "$prefix" in
      *-) prefixed="$prefix$candidate" ;;
      *) prefixed="$prefix-$candidate" ;;
    esac
    # Same shell rule as task_show_or_fail: the row is read out of
    # TASK_SHOW_OUTPUT, so the read cannot sit inside a command substitution.
    task_show "$prefixed" 2>/dev/null || {
      [ "$?" -ne 124 ] || return 124
      continue
    }
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
    prefixed_matches="${prefixed_matches}${prefixed_matches:+$NL_SEP}$prefixed"
  done
  prefixed_count=$(printf '%s\n' "$prefixed_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$prefixed_count" in
    0) return 1 ;;
    1) printf '%s migrated-prefix' "$prefixed_matches"; return 0 ;;
  esac
  printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s captain-held rows carry the configured prefix (identities tried: %s)\n' \
    "$entry" "$prefixed_count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
  return 2
}

# Resolve one inventory entry or channel key to the task that carries it: the
# exact task id when it exists, else the legacy derived identity, else - on the
# beads backend - the migrated row the markdown-to-beads hold migration wrote.
# Prints "<resolved id> <how>", where <how> is exact, legacy, migrated-note or
# migrated-prefix, so a caller can record which evidence carried the attestation.
resolve_entry() {  # <origin-or-empty> <entry>; prints "<id> <how>" or fails
  local origin=$1 entry=$2 legacy migrated rc
  if task_show "$entry"; then
    printf '%s exact' "$entry"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if task_show "$legacy"; then
      printf '%s legacy' "$legacy"
      return 0
    fi
  fi
  rc=0
  migrated=$(resolve_migrated_entry "$origin" "$entry") || rc=$?
  case "$rc" in
    0) printf '%s' "$migrated"; return 0 ;;
    2) return 2 ;;
    124) return 124 ;;
  esac
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA); the nearest legacy identity $legacy also resolves to nothing"
  fi
  fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA)"
}

body_hold_set_timestamp() {  # <decoded-task-body>
  printf '%s\n' "$1" \
    | sed -n \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\)$/\1/p' \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | head -1
}

require_context_codec() {
  command -v jq >/dev/null 2>&1 || fail "jq is required for question context"
}

command_contexts() {  # pure canonical JSON codec, no backend/home reads
  [ "$#" = 0 ] || { usage >&2; exit 2; }
  require_context_codec
  jq -L "$SCRIPT_DIR" 'include "fm-captain-question-context";
    if (.records | type) != "array" then error("canonical records required") else
      .records |= map(if .structured and .hold_kind == "captain" and .state != "done"
        then .question_context = fm_question_context_read else . end) end'
}

context_for_body() {  # <decoded-body>; same codec as the canonical reader
  require_context_codec
  printf '%s' "$1" | jq -Rsc -L "$SCRIPT_DIR" 'include "fm-captain-question-context";
    split("\n") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))
    | {body_lines:.,hold_set:(.[0] // "" | ltrimstr("Captain hold set: "))}
    | fm_question_context_read'
}

load_question_context() {  # <path>; sets QUESTION_CONTEXT
  require_context_codec
  [ -f "$1" ] && [ -s "$1" ] || fail "context file must be a nonempty regular file"
  [ "$(LC_ALL=C wc -c < "$1" | tr -d ' ')" -le 8192 ] || fail "context file exceeds 8192 bytes"
  # Name the deadline-default refusal; malformed input falls through to the codec.
  case "$(jq -Rrs -L "$SCRIPT_DIR" 'include "fm-captain-question-context";
    fm_question_json_decode | fm_question_default_problem // "ok"' "$1" 2>/dev/null)" in
    action) fail "a personal action can never carry a deadline default; it waits for the captain" ;;
    marker) fail "a deadline default needs default_eligible set to exactly \"small-reversible\" together with default_date" ;;
    missing) fail "a deadline default needs all of recommendation, default_date and scope" ;;
    date) fail "a deadline default needs exactly one of default_date (a real YYYY-MM-DD date) or default_at (a real YYYY-MM-DDTHH:MM:SSZ UTC time)" ;;
    excluded) fail "a call with outward-facing, irreversible, money or security scope can never carry a deadline default; it waits for the captain" ;;
    scope) fail "a deadline default is only for small reversible product or copy calls: scope may name only product or copy" ;;
  esac
  QUESTION_CONTEXT=$(jq -RcS -s -L "$SCRIPT_DIR" 'include "fm-captain-question-context";
    fm_question_json_decode
    | if fm_question_valid(false) then fm_question_normalize
    else error("unsupported or malformed question context") end' "$1") \
    || fail "unsupported or malformed question context"
  # The reader is a manager who did not build the work: refuse a card he cannot place.
  case "$(printf '%s' "$QUESTION_CONTEXT" | jq -r -L "$SCRIPT_DIR" \
    'include "fm-captain-question-context"; fm_question_explanation_problem // "ok"')" in
    ok) : ;;
    missing) fail "question context needs \"about\" and \"purpose\": the captain is a non-technical manager who did not build this, so say in plain words what this is about, and what answering it unlocks or what happens while it stays unanswered" ;;
    markup) fail "\"about\" and \"purpose\" are read by a non-technical manager: drop links, backticks and GUIDs and say it in plain words" ;;
    option) fail "every option needs a \"detail\" telling a non-technical manager what happens when he picks it" ;;
    *) fail "cannot check the question context's plain-language explanation" ;;
  esac
  local effect
  effect=$(printf '%s' "$QUESTION_CONTEXT" | jq -r -L "$SCRIPT_DIR" 'include "fm-captain-question-context";
    if .default_eligible == null then "" else fm_question_default_effect // "" end') \
    || fail "cannot check the deadline default's effect"
  [ -z "$effect" ] || fail "a deadline default can never carry this effect ($effect); the call waits for the captain"
}

write_hold_set_stamp() {  # <id> <shown-body> <stamp> <preserve> [<normalized-context>]
  local id=$1 body=$2 hold_set=$3 preserve=$4 context=${5:-} existing new_body tmp old_context lifecycle context_line archive_flag='' explained=0
  body=$(decode_shown_value "$body") || fail "could not decode the existing body for $id"
  existing=$(body_hold_set_timestamp "$body")
  if [ "$preserve" = 1 ] && [ -n "$existing" ]; then
    [ -n "$context" ] || return 0
    hold_set=$existing
    old_context=$(context_for_body "$body") || fail "cannot read existing question context"
    case "$(printf '%s' "$old_context" | jq -r .status)" in
      legacy|ready) : ;;
      *) fail "existing active question context is invalid; owner review required" ;;
    esac
  fi
  if [ -n "$context" ]; then
    lifecycle="$hold_set#$(resolution_record_count "$body")"
    context=$(printf '%s' "$context" | jq -cS --arg lifecycle "$lifecycle" '. + {lifecycle:$lifecycle}')
    printf '%s' "$context" | jq -e -L "$SCRIPT_DIR" 'include "fm-captain-question-context"; fm_question_valid(true)' >/dev/null \
      || fail "question context requires a valid hold lifecycle"
    if [ "$preserve" = 1 ] && [ -n "${old_context:-}" ] \
      && [ "$(printf '%s' "$old_context" | jq -r .status)" = ready ]; then
      [ "$(printf '%s' "$old_context" | jq -cS .context)" != "$context" ] || return 0
      printf '%s' "$old_context" | jq -e -L "$SCRIPT_DIR" --argjson new "$context" \
        'include "fm-captain-question-context"; .context as $old | $new | fm_question_adds_only($old)' >/dev/null \
        || fail "active question context differs; resolve this call before publishing new semantics"
      explained=1
    fi
  fi
  if [ -n "$existing" ]; then
    body=${body#"Captain hold set: $existing"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
  fi
  # The extended context contains the one it replaces, so that line is
  # superseded in place: same lifecycle, no second active marker, no history lost.
  if [ "$explained" = 1 ]; then
    case "$body" in
      'Captain question context: '*$'\n'*) body=${body#*$'\n'}; body=${body#$'\n'} ;;
      'Captain question context: '*) body='' ;;
      *) fail "existing active question context is invalid; owner review required" ;;
    esac
  fi
  # Expired deferrals retain captain annotations/body but report held=no.
  # A fresh lifecycle must not leave their old header active beside the new one.
  if [ "$preserve" != 1 ]; then
    case "$body" in
      'Captain question context: '*)
        context_line=${body%%$'\n'*}
        body=${body#"$context_line"}
        body=$(printf 'Previous captain question context: %s%s' "${context_line#Captain question context: }" "$body")
        archive_flag=--archive-body
        ;;
    esac
  fi
  new_body=$(printf 'Captain hold set: %s' "$hold_set")
  [ -z "$context" ] || new_body=$(printf '%s\nCaptain question context: %s' "$new_body" "$context")
  [ -z "$body" ] || new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-stamp.XXXXXX") || fail "cannot stage the hold-set stamp"
  # shellcheck disable=SC2086  # archive_flag is empty or the literal --archive-body.
  if ! printf '%s\n' "$new_body" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" $archive_flag >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the hold-set stamp on $id"
  fi
  rm -f -- "$tmp"
}

# The origin a hold was recorded for lives in the held task's own body, on a
# line of its own, so `complete` can tell a call held for this origin from one
# held for another. Omitting --origin leaves any existing association intact.
body_hold_origin() {  # <decoded-task-body>
  printf '%s\n' "$1" | sed -n 's/^Captain hold origin: \(.*\)$/\1/p' | head -1
}

# The category a hold declared lives on its own body line below the hold
# header, the same durable pattern as the origin line. A row held before the
# category gate carries none, and reads as an empty category.
body_hold_category() {  # <decoded-task-body>
  printf '%s\n' "$1" | sed -n 's/^Captain hold category: \([A-Za-z0-9._-]\{1,\}\)$/\1/p' | head -1
}

task_identity() {
  local id=$1
  if task_show "$id"; then
    id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
    validate_slug backend-task-id "$id"
  elif ! printf '%s\n' "$TASK_SHOW_OUTPUT" | grep -q '^code: NOT_FOUND$'; then
    fail "could not resolve the backend identity of $id"
  fi
  printf '%s' "$id"
}

write_hold_origin() {  # <task-id> <shown-body> <origin>
  local id=$1 body=$2 origin=$3 stamp rest new_body tmp context_line=''
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  stamp=$(printf '%s\n' "$body" | sed -n 1p)
  [ -n "$(body_hold_set_timestamp "$body")" ] \
    || fail "task $id lost its hold-set stamp before its origin was recorded"
  rest=$(printf '%s\n' "$body" | sed 1d | awk '!/^Captain hold origin: /' \
    | awk 'NF || started { started = 1; print }')
  new_body=$stamp
  # Structured context must remain directly below the stamp; the origin is
  # independent authority and follows that header, never displacing it.
  case "$rest" in
    'Captain question context: '*)
      context_line=${rest%%$'\n'*}
      rest=${rest#"$context_line"}
      rest=${rest#$'\n'}
      rest=${rest#$'\n'}
      new_body=$(printf '%s\n%s' "$new_body" "$context_line")
      ;;
  esac
  new_body=$(printf '%s\nCaptain hold origin: %s' "$new_body" "$origin")
  if [ -n "$rest" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$rest")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-origin.XXXXXX") \
    || fail "cannot stage the hold origin"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold origin for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    printf 'fm-captain-hold: could not record the hold origin on %s\n' "$id" >&2
    return 1
  fi
  rm -f -- "$tmp"
}

# The declared category lives on one `Captain hold category:` line below the
# hold header, deduplicated the way write_hold_origin deduplicates its line,
# so exactly one active category line exists no matter how often a task is
# re-held across lifecycles.
write_hold_category() {  # <task-id> <shown-body> <category>
  local id=$1 body=$2 category=$3 stamp rest new_body tmp context_line=''
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  stamp=$(printf '%s\n' "$body" | sed -n 1p)
  [ -n "$(body_hold_set_timestamp "$body")" ] \
    || fail "task $id lost its hold-set stamp before its category was recorded"
  rest=$(printf '%s\n' "$body" | sed 1d | awk '!/^Captain hold category: /' \
    | awk 'NF || started { started = 1; print }')
  new_body=$stamp
  # Structured context must remain directly below the stamp; the category is
  # independent authority and follows that header, never displacing it.
  case "$rest" in
    'Captain question context: '*)
      context_line=${rest%%$'\n'*}
      rest=${rest#"$context_line"}
      rest=${rest#$'\n'}
      rest=${rest#$'\n'}
      new_body=$(printf '%s\n%s' "$new_body" "$context_line")
      ;;
  esac
  new_body=$(printf '%s\nCaptain hold category: %s' "$new_body" "$category")
  if [ -n "$rest" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$rest")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-category.XXXXXX") \
    || fail "cannot stage the hold category"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold category for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    printf 'fm-captain-hold: could not record the hold category on %s\n' "$id" >&2
    return 1
  fi
  rm -f -- "$tmp"
}

# Best-effort restoration removes a refused hold attempt's stamp while
# preserving the prior body; the new origin has not been published yet.
# tasks-axi cannot write an empty body, and a task that began empty carries no
# earlier answer for a stale stamp to mislabel, so that case keeps its body.
restore_hold_body() {  # <task-id> <shown-original-body>
  local id=$1 body tmp
  body=$(decode_shown_value "$2") || return 1
  [ -n "$body" ] || return 0
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-restore.XXXXXX") || return 1
  if ! printf '%s\n' "$body" > "$tmp" || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    printf 'fm-captain-hold: could not restore the body of %s after an incomplete hold\n' "$id" >&2
    return 1
  fi
  rm -f -- "$tmp"
}

refuse_self_inventory() {
  local origin=$1 entry=$2 meta="$STATE/$1.meta"
  if list_has_key "$(meta_value "$meta" decision_keys)" "$entry"; then
    fail "origin $origin cannot be its own captain-call inventory entry; historical decision_keys in $meta still contains $entry; hold a separate captain task with --origin $origin, replace only $entry in the final decision_keys= line with that task id while preserving all other entries, then re-run complete $origin <task-id>"
  fi
  fail "origin $origin cannot be its own captain-call inventory entry; hold a separate captain task for the call and list that task"
}

recorded_answer_lifecycle() {  # <decoded-body>; only the newest record header
  printf '%s\n' "$1" | awk '
    /^Resolution recorded by fm-(captain|decision)-hold\.$/ { record=1; next }
    record && /^$/ { exit }
    record && /^Captain answer lifecycle: / { sub(/^Captain answer lifecycle: /, ""); print; exit }'
}

guard_answer_lifecycle() {  # <expected> <mode> <shown-body> <state> <hold-kind>
  local expected=$1 mode=$2 shown=$3 state=$4 hold_kind=$5 body context current stored stamp
  require_context_codec
  printf '%s' "$expected" | jq -Rse -L "$SCRIPT_DIR" 'include "fm-captain-question-context"; fm_question_lifecycle_valid' >/dev/null \
    || fail "invalid expected lifecycle"
  body=$(decode_shown_value "$shown") || fail "cannot decode held question context"
  context=$(context_for_body "$body") || fail "cannot read held question context"
  current=$(printf '%s' "$context" | jq -r '.lifecycle // ""')
  if [ "$state" != "done" ] && [ "$hold_kind" = captain ] && [ "$current" = "$expected" ]; then
    printf '%s' "$context" | jq -e --arg mode "$mode" '.status == "ready" and .context.close == $mode' >/dev/null \
      || fail "guarded answer requires ready context with matching close mode"
    return 0
  fi
  stored=$(recorded_answer_lifecycle "$body")
  [ "$stored" = "$expected" ] && [ "$(recorded_decision_digest "$shown" || true)" = "$DECISION_DIGEST" ] \
    || fail "stale captain question lifecycle"
  if [ "$state" != "done" ] && [ "$hold_kind" = captain ]; then
    # Still held means an interrupted close ONLY when its active context is the
    # old call. A fresh re-hold has new/missing context, even in the same second.
    stamp=$(body_hold_set_timestamp "$body")
    [ "$stamp" = "${expected%#*}" ] || fail "stale captain question lifecycle"
    printf '%s' "$context" | jq -e --arg expected "$expected" --arg mode "$mode" \
      '.status == "stale" and .context.lifecycle == $expected and .context.close == $mode' >/dev/null \
      || fail "stale captain question lifecycle"
  fi
}

# --- Done-archive reads on the markdown backend -----------------------------
#
# Done retention moves closed markdown rows into the configured archive, which
# tasks-axi show never reads, so an answered call a scout attested would read as
# absent once retention ran. Only the completion gate consults the archive: an
# archived row is closed, so it can satisfy the gate solely through a recorded
# resolution, and every mutating path keeps seeing it as absent.

# The [markdown] archive key tasks-axi would honour, resolved with tasks-axi's
# own source precedence: the backlog root's .tasks.toml first, then the
# user-level $HOME/.tasks-axi/config.toml. Empty when neither sets it; a relative
# value resolves against the backlog root wherever it was configured, the way
# tasks-axi resolves it.
captain_markdown_archive_setting() {  # <backlog-root>
  local root=$1 archive
  archive=$(captain_toml_section_entries "$root/.tasks.toml" markdown archive | sed -n 's/^archive //p' | head -1)
  if [ -z "$archive" ] && [ -n "${HOME:-}" ]; then
    archive=$(captain_toml_section_entries "$HOME/.tasks-axi/config.toml" markdown archive | sed -n 's/^archive //p' | head -1)
  fi
  printf '%s\n' "$archive"
}

# The archive tasks-axi writes: the [markdown] archive key resolved against the
# backlog root, else done-archive.md beside the addressed backlog file. Returns
# 1 when the configured backend keeps no markdown archive.
captain_markdown_archive_path() {
  local data root backend archive file
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  root=$(fm_backlog_root "$data") || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 1
  [ "$backend" = markdown ] || return 1
  archive=$(captain_markdown_archive_setting "$root")
  case "$archive" in
    '')
      file=$(fm_backlog_file "$data") || return 1
      archive="${file%/*}/done-archive.md"
      ;;
    /*) ;;
    *) archive="$root/$archive" ;;
  esac
  printf '%s\n' "$archive"
}

# Read an archived row into TASK_SHOW_OUTPUT exactly as tasks-axi shows a live
# one, by replaying its newest archived block under a scratch Done section. A
# reused id can be archived more than once, and retention appends, so the last
# block is the newest. Returns 1 when the row is not archived.
task_show_archived() {  # <id>; sets TASK_SHOW_OUTPUT
  local id=$1 archive dir status=0 secs=${FM_BACKLOG_ROW_TIMEOUT_SECS:-10}
  TASK_SHOW_OUTPUT=
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  archive=$(captain_markdown_archive_path) || return 1
  [ -f "$archive" ] || return 1
  dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-captain-hold-archive.XXXXXX") \
    || fail "cannot stage the Done archive read for $id"
  printf 'backend = "markdown"\n' > "$dir/.tasks.toml"
  {
    printf '## Done\n'
    LC_ALL=C awk -v id="$id" '
      /^- \[.\] / {
        rest = substr($0, 7)
        inrow = (rest == id || index(rest, id " ") == 1)
        if (inrow) block = $0 "\n"
        next
      }
      inrow && ($0 == "" || $0 ~ /^[[:space:]]/) { block = block $0 "\n"; next }
      { inrow = 0 }
      END { printf "%s", block }
    ' "$archive"
  } > "$dir/backlog.md" || status=1
  if [ "$status" -eq 0 ]; then
    # The replayed archive read gets the same bound as a live backlog read, so a
    # wedged tasks-axi cannot hang verify, or complete while it holds the origin
    # metadata lock. A bound hit is not absence, so it stops loudly with 124.
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
    TASK_SHOW_OUTPUT=$(fm_run_timed "$secs" bash -c \
      'cd "$1" 2>/dev/null || exit 1; shift; exec tasks-axi show "$@"' \
      _ "$dir" "$id" --full --file "$dir/backlog.md" 2>/dev/null)
    status=$?
    if [ "$status" -eq 124 ]; then
      printf 'fm-captain-hold: tasks-axi show %s exceeded its %ss Done-archive read bound\n' "$id" "$secs" >&2
    elif [ "$status" -ne 0 ]; then
      status=1
    fi
  fi
  rm -f -- "$dir/backlog.md" "$dir/.tasks.toml"
  rmdir -- "$dir" 2>/dev/null || true
  return "$status"
}

# The archived row an entry names, under its exact id or its legacy identity.
# A read that hit its bound is not absence: it returns 124 so the caller stops
# loudly instead of reading the row as unarchived.
archived_entry() {  # <origin-or-empty> <entry>; prints the archived id
  local origin=$1 entry=$2 legacy status=0
  task_show_archived "$entry" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s' "$entry"
    return 0
  fi
  [ "$status" -ne 124 ] || return 124
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    status=0
    task_show_archived "$legacy" || status=$?
    if [ "$status" -eq 0 ]; then
      printf '%s' "$legacy"
      return 0
    fi
    [ "$status" -ne 124 ] || return 124
  fi
  return 1
}

# Resolve one entry and verify the row it names is durably captain-held. A
# resolution failure that is not the read bound keeps resolve_entry's own
# status - its stderr already named the entry; 124 means the backend never
# answered, which is not the same as an unknown entry and must not be spent
# as absence. The result carries the attestation evidence and whether an
# origin was recorded, so completion can disclose the legacy fallback.
verify_entry_durable() {  # <origin-or-empty> <entry>; prints "<id> <how> <origin-state>"
  local origin=$1 entry=$2 resolved resolve_status=0 id how stored origin_state=unrecorded origin_id stored_id resolve_err archived archived_status
  # The origin task is never its own captain-call inventory: it is the work the
  # calls were found in, so accepting it would let a refused hold look recorded.
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ] && [ "$entry" = "$origin" ]; then
    refuse_self_inventory "$origin" "$entry"
  fi
  resolve_err=$(mktemp "${TMPDIR:-/tmp}/fm-captain-hold-resolve.XXXXXX") \
    || fail "cannot stage the resolution diagnostics for $entry"
  resolved=$(resolve_entry "$origin" "$entry" 2>"$resolve_err") || resolve_status=$?
  if [ "$resolve_status" -eq 1 ]; then
    archived_status=0
    archived=$(archived_entry "$origin" "$entry") || archived_status=$?
    if [ "$archived_status" -eq 0 ]; then
      resolved="$archived archived"
      resolve_status=0
    elif [ "$archived_status" -eq 124 ]; then
      rm -f -- "$resolve_err"
      exit 124
    else
      cat "$resolve_err" >&2
    fi
  else
    cat "$resolve_err" >&2
  fi
  rm -f -- "$resolve_err"
  if [ "$resolve_status" -ne 0 ]; then
    [ "$resolve_status" -ne 124 ] \
      || fail "the backlog backend exceeded its read bound resolving $entry"
    exit "$resolve_status"
  fi
  id=${resolved%% *}
  how=${resolved##* }
  verify_hold_durable "$id"
  id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
  validate_slug backend-task-id "$id"
  stored=$(body_hold_origin "$(decode_shown_value "$(show_field "$TASK_SHOW_OUTPUT" body)")")
  origin_id=$origin
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    origin_id=$(task_identity "$origin") || exit $?
    [ "$id" != "$origin_id" ] || refuse_self_inventory "$origin" "$entry"
  fi
  if [ -n "$stored" ]; then
    if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
      stored_id=$(task_identity "$stored") || exit $?
      if [ "$stored_id" != "$origin_id" ]; then
        fail "captain-held task $id was held for origin $stored, not $origin; hold a task for $origin or list the right one"
      fi
    fi
    origin_state=recorded
  fi
  printf '%s %s %s\n' "$id" "$how" "$origin_state"
}

# A default whose deadline already passed would apply before the captain ever
# saw it, so a day must be later than today and an hour stamp at least 24 hours
# after the hold-set stamp. A repeat of the deadline already published on this
# active call is not a new promise.
require_future_default_date() {  # <hold-set> <preserve> <shown-body>; reads QUESTION_CONTEXT
  local date at published=''
  [ -n "$QUESTION_CONTEXT" ] || return 0
  date=$(printf '%s' "$QUESTION_CONTEXT" | jq -r '.default_date // ""')
  at=$(printf '%s' "$QUESTION_CONTEXT" | jq -r '.default_at // ""')
  [ -n "$date$at" ] || return 0
  if [ "$2" = 1 ]; then
    published=$(context_for_body "$(decode_shown_value "$3")" \
      | jq -r '.context.default_date // .context.default_at // ""') || published=''
  fi
  if [ -n "$date" ]; then
    [ "$date" = "$published" ] || [[ "$date" > "${1%%T*}" ]] \
      || fail "default_date must be later than today so the captain can see it first: $date"
    return 0
  fi
  [ "$at" = "$published" ] \
    || jq -ne --arg at "$at" --arg set "$1" '($at | fromdateiso8601) >= (($set | fromdateiso8601) + 86400)' >/dev/null \
    || fail "default_at must be at least 24 hours after the hold is set so the captain can see it first: $at"
}

command_hold() {
  local id=${1:-} title='' reason='' repo='' origin='' until='' show state existing_title body='' hold_kind hold_set occurrence
  local existing_hold_kind='' existing_held='' preserve_hold_set=0 stored_reason original_body='' hold_status=0
  local context_file='' QUESTION_CONTEXT='' category='' recorded_category=''
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --origin) shift; origin=${1:-} ;;
      --until) shift; until=${1:-} ;;
      --category) [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--category requires a value"; shift; category=$1 ;;
      --context-file) [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--context-file requires a path"; shift; context_file=$1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$reason" ] || fail "reason must not be empty"
  if [ -n "$category" ]; then
    valid_hold_category "$category" \
      || fail "--category must be one of: $CAPTAIN_HOLD_CATEGORY_LIST (got: $category); $CAPTAIN_HOLD_CATEGORY_GATE"
  fi
  # bin/fm-hold-reason-lib.sh owns the storage constraint and reversible encoding.
  stored_reason=$(fm_hold_reason_encode "$reason") || fail "could not encode the hold reason"
  if [ -n "$origin" ]; then
    validate_slug origin-id "$origin"
  fi
  if [ -n "$until" ]; then
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) fail "--until must be a YYYY-MM-DD date: $until" ;;
    esac
  fi
  hold_set=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$hold_set" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "FM_CAPTAIN_HOLD_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  if [ -n "$context_file" ]; then
    load_question_context "$context_file"
    printf '%s' "$hold_set" | jq -Rse -L "$SCRIPT_DIR" 'include "fm-captain-question-context"; fm_question_timestamp' >/dev/null \
      || fail "question context requires a valid UTC hold timestamp"
  fi
  acquire_task_control_lock "$id"
  require_tasks_axi
  if task_show "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    [ "$state" != "done" ] \
      || fail "task $id is already closed; a new captain call needs its own task"
    existing_hold_kind=$(show_field_value "$show" hold_kind)
    existing_held=$(show_field_value "$show" held)
    if [ "$existing_hold_kind" = captain ] && [ "$existing_held" = yes ]; then
      preserve_hold_set=1
    fi
    require_future_default_date "$hold_set" "$preserve_hold_set" "$(show_field "$show" body)"
    if [ -n "$title" ]; then
      existing_title=$(show_field_value "$show" title)
      [ "$existing_title" = "$title" ] || fail "existing task $id has a different title"
    fi
    if [ "$preserve_hold_set" = 1 ]; then
      recorded_category=$(body_hold_category "$(show_field_value "$show" body)")
      if [ -z "$category" ]; then
        if [ -z "$recorded_category" ]; then
          printf 'fm-captain-hold: warning: active hold %s carries no category (held before the category gate); continuing uncategorized\n' "$id" >&2
        elif ! valid_hold_category "$recorded_category"; then
          printf 'fm-captain-hold: warning: active hold %s carries an unknown category (%s); keeping it\n' "$id" "$recorded_category" >&2
        fi
      fi
    else
      [ -n "$category" ] || fail "$CAPTAIN_HOLD_CATEGORY_GATE"
    fi
  else
    [ -n "$category" ] || fail "$CAPTAIN_HOLD_CATEGORY_GATE"
    [ -n "$title" ] || fail "--title is required to create task $id"
    validate_one_line title "$title"
    require_future_default_date "$hold_set" 0 ''
    if [ -z "$repo" ] && [ -n "$origin" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    [ -z "$origin" ] || body=$(printf 'Origin: %s' "$origin")
    # tasks-axi add never passes --due. Beads due.required would refuse this
    # create, and captain holds have no due semantics, so waive it for this
    # call only. --kind captain stays metadata; Beads native type is task.
    if [ -n "$body" ]; then
      BD_DUE_REQUIRED=false tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
        || fail "could not create task $id"
    else
      BD_DUE_REQUIRED=false tasks_axi add "$id" "$title" --kind captain --repo "$repo" >/dev/null \
        || fail "could not create task $id"
    fi
  fi
  # Publish the timestamp before the captain-hold annotation. A concurrent
  # snapshot may see the harmless stamp by itself, but can never see a newly
  # held task without the timestamp that defines this hold lifecycle's age.
  # Resolve the origin identity before stamping or holding. A lookup failure
  # leaves an existing task untouched, but a missing row was already created.
  if [ -n "$origin" ]; then
    origin=$(task_identity "$origin") || exit $?
  fi
  task_show_or_fail "$id" "task $id disappeared before recording its hold-set stamp"
  original_body=$(show_field "$show" body)
  write_hold_set_stamp "$id" "$(show_field "$show" body)" "$hold_set" "$preserve_hold_set" "$QUESTION_CONTEXT"
  task_show_or_fail "$id" "task $id disappeared while recording its hold-set stamp"
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id did not retain its hold-set stamp"
  if [ -n "$until" ]; then
    tasks_axi hold "$id" --reason "$stored_reason" --kind captain --until "$until" >/dev/null \
      || hold_status=$?
  else
    tasks_axi hold "$id" --reason "$stored_reason" --kind captain >/dev/null \
      || hold_status=$?
  fi
  if [ "$hold_status" -ne 0 ]; then
    # Restore the body without resolving its old origin again. The new origin
    # is still unpublished even if this best-effort restoration fails.
    restore_hold_body "$id" "$original_body" || true
    fail "could not hold task $id for the captain"
  fi
  task_show "$id" || fail "task $id disappeared while holding it"
  show=$TASK_SHOW_OUTPUT
  hold_kind=$(show_field_value "$show" hold_kind)
  [ "$hold_kind" = captain ] || fail "task $id did not retain its captain hold"
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id lost its hold-set stamp while being held"
  occurrence=$(( $(resolution_record_count "$(show_field "$show" body)") + 1 ))
  publish_parent_hold "$id" "$occurrence" needs-decision "$reason"
  if [ -n "$category" ] && [ "$category" != "$recorded_category" ]; then
    write_hold_category "$id" "$(show_field "$show" body)" "$category" || exit $?
    task_show_or_fail "$id" "task $id disappeared while recording its category"
  fi
  if [ -n "$origin" ]; then
    write_hold_origin "$id" "$(show_field "$show" body)" "$origin" || exit $?
  fi
  printf '%s\n' "$id"
}

# Record a resolution block beneath any leading active hold-set stamp,
# preserving the previous body below it and archiving the pristine original.
# Successful closure removes the stamp to restore resolution-first ordering.
write_resolution_record() {  # <task-id> <mode> <shown-body>
  local id=$1 mode=$2 body=$3 new_body tmp hold_set context_line=''
  new_body=$(resolution_block "$mode")
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  hold_set=$(body_hold_set_timestamp "$body")
  if [ -n "$hold_set" ]; then
    body=${body#"Captain hold set: $hold_set"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
    case "$body" in
      'Captain question context: '*)
        context_line=${body%%$'\n'*}
        body=${body#"$context_line"}
        body=${body#$'\n'}
        body=${body#$'\n'}
        ;;
    esac
    if [ -n "$context_line" ]; then
      new_body=$(printf 'Captain hold set: %s\n%s\n\n%s' "$hold_set" "$context_line" "$new_body")
    else
      new_body=$(printf 'Captain hold set: %s\n\n%s' "$hold_set" "$new_body")
    fi
  fi
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-body.XXXXXX") \
    || fail "cannot stage the resolution record"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the resolution record for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the captain decision on $id"
  fi
  rm -f -- "$tmp"
}

report_retained_artifact_failure() {  # <task-id> <marker-path>
  printf 'fm-captain-hold: cannot apply the artifact recorded for %s in %s: %s\n' \
    "$1" "$2" "${FM_BACKLOG_TRANSITION_ERROR:-no reason reported}" >&2
}

apply_pending_retained_artifact() {  # <task-id>
  local id=$1 marker label
  local -a args=()
  RETAINED_CLOSE_ARGS=()
  marker=$(fm_backlog_close_marker_path "$STATE" "$id") || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  fm_backlog_close_marker_validate "$marker" "$DATA" "$id" "$STATE" \
    || { report_retained_artifact_failure "$id" "$marker"; return 1; }
  [ "$FM_BACKLOG_CLOSE_VALIDATED_MODE" = retain ] || return 0
  args=("${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]+"${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]}"}")
  case "${args[0]-}" in
    --pr|--report)
      if [ "${args[0]}" = --pr ] && label=$(fm_backlog_pr_note_label "${args[1]-}"); then
        RETAINED_CLOSE_ARGS=(--note "$label ${args[1]}")
        return 0
      fi
      fm_backlog_row_artifact_supported "$id" "${args[@]}" || return 0
      fm_backlog_mutate "$DATA" update "$id" "${args[@]}" \
        || { report_retained_artifact_failure "$id" "$marker"; return 1; }
      ;;
  esac
}

# A captain hold is released only in an attended session. The away daemon flag
# (state/.afk, bin/fm-wake-lib.sh fm_afk_mode) and the posture record
# (state/.afk-contract, bin/fm-afk-contract.sh mode) are both read: either one
# reading away refuses, a quiet record is a present captain, and no record is
# attended. The check runs before any write, so a refusal leaves the hold and
# the body untouched.
RELEASE_AWAY_REASON='the away-posture record exists, and a captain hold is released only by the captain in an attended session; retry --release after the return archives the record'
release_attended() {
  if [ -e "$STATE/.afk" ] && [ "$(fm_afk_mode "$STATE")" = away ]; then
    return 1
  fi
  ! fm_afk_contract_away_present "$STATE"
}

close_answered() {  # <task-id> <release-0-or-1>
  if [ "$2" = 1 ]; then
    tasks_axi unhold "$1" >/dev/null
  else
    apply_pending_retained_artifact "$1" || return 1
    tasks_axi "done" "$1" "${RETAINED_CLOSE_ARGS[@]+"${RETAINED_CLOSE_ARGS[@]}"}" >/dev/null
  fi
}

remove_interrupted_answer_stamp() {  # <task-id>
  local id=$1 show body existing tmp context_line=''
  task_show_or_fail "$id" "task $id disappeared after closing"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the closed body for $id"
  existing=$(body_hold_set_timestamp "$body")
  [ -n "$existing" ] || return 0
  body=${body#"Captain hold set: $existing"}
  case "$body" in
    $'\n\n'*) body=${body#$'\n\n'} ;;
    $'\n'*) body=${body#$'\n'} ;;
  esac
  case "$body" in
    'Captain question context: '*)
      context_line=${body%%$'\n'*}
      body=${body#"$context_line"}
      body=${body#$'\n'}
      body=${body#$'\n'}
      body=$(printf '%s\n\n%s' "$body" "$context_line")
      ;;
  esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-normalize.XXXXXX") \
    || fail "cannot stage the closed body for $id"
  if ! printf '%s\n' "$body" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not restore the resolution record ordering for $id"
  fi
  rm -f -- "$tmp"
}

# The pending default of a call firstmate may proceed on now, as JSON; nonzero
# otherwise. A date gate the captain set himself still defers it, and a stopped
# clock ends it.
deadline_default_due() {  # <task-show-output> <now-YYYY-MM-DDTHH:MM:SSZ>
  local show=$1 now=$2 today=${2%%T*} hold_until body
  [ "$(show_field "$show" state)" != "done" ] || return 1
  [ "$(show_field_value "$show" hold_kind)" = captain ] || return 1
  hold_until=$(show_field_value "$show" hold_until)
  case "$hold_until" in
    ''|-) : ;;
    *) if [[ "$hold_until" > "$today" ]]; then return 1; fi ;;
  esac
  body=$(decode_shown_value "$(show_field "$show" body)") || return 1
  context_for_body "$body" | jq -ce -L "$SCRIPT_DIR" --arg now "$now" \
    'include "fm-captain-question-context";
     select(.status == "ready" and .default_stopped == null) | .lifecycle as $lifecycle | .context
     | .close as $close | fm_question_default_pending
     | select(. != null and .due_at <= $now) | . + {close:$close,lifecycle:$lifecycle}'
}

# Build the arguments `answer --deadline-default` runs with. An interrupted close
# of this same default reads as stale context; regenerating its identical words
# under its recorded lifecycle lets the answer guard finish it, while any other
# recorded decision has a different digest and is refused.
DEADLINE_DECISION_FILE=
DEADLINE_DECISION_RELEASE=0
DEADLINE_DECISION_LIFECYCLE=
prepare_deadline_default() {  # <task-id>
  local id=$1 show now pending words
  require_context_codec
  require_tasks_axi
  task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  show=$TASK_SHOW_OUTPUT
  now=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  pending=$(deadline_default_due "$show" "$now") \
    || pending=$(context_for_body "$(decode_shown_value "$(show_field "$show" body)")" | jq -ce -L "$SCRIPT_DIR" \
      --arg now "$now" 'include "fm-captain-question-context";
        select(.status == "stale") | .context | .close as $close | .lifecycle as $lifecycle
        | fm_question_default_pending | select(. != null and .due_at <= $now)
        | . + {close:$close,lifecycle:$lifecycle}') \
    || fail "task $id has no deadline default due: it is answered, deferred, stopped, not eligible, or its deadline has not passed"
  words=$(printf '%s' "$pending" | jq -r '(if (.date | test("T")) then "by \(.date[11:16]) UTC on \(.date[:10])" else "by the end of \(.date) UTC" end) as $by
    | "The captain had not answered \($by), so Firstmate proceeded on its recommendation: \(.label) (\(.value)). These are not the captain'"'"'s words."')
  DEADLINE_DECISION_LIFECYCLE=$(printf '%s' "$pending" | jq -r .lifecycle)
  [ "$(printf '%s' "$pending" | jq -r .close)" != release ] || DEADLINE_DECISION_RELEASE=1
  DEADLINE_DECISION_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-default.XXXXXX") \
    || fail "cannot stage the deadline default"
  printf '%s\n' "$words" > "$DEADLINE_DECISION_FILE" || fail "cannot stage the deadline default"
}

command_answer() {
  local id=${1:-} decision_file='' release=0 deadline_default=0 show state hold_kind body outcome recorded_mode occurrence expected='' requested_mode='done' check_only=0
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --release) release=1 ;;
      --expected-lifecycle) [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--expected-lifecycle requires an identity"; shift; expected=$1 ;;
      --deadline-default) deadline_default=1 ;;
      --check-only) check_only=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  if [ "$deadline_default" = 1 ]; then
    # The owner chooses the words, close and guard so no caller can supply them.
    [ -z "$decision_file" ] && [ "$release" = 0 ] && [ -z "$expected" ] \
      || fail "--deadline-default takes no decision file, --release or --expected-lifecycle"
    prepare_deadline_default "$id"
    DEADLINE_DEFAULT=1
    decision_file=$DEADLINE_DECISION_FILE
    release=$DEADLINE_DECISION_RELEASE
    expected=$DEADLINE_DECISION_LIFECYCLE
  fi
  if [ "$release" = 1 ] && ! release_attended; then
    [ -z "$DEADLINE_DECISION_FILE" ] || rm -f -- "$DEADLINE_DECISION_FILE"
    fail "task $id stays held: $RELEASE_AWAY_REASON"
  fi
  load_decision "$decision_file"
  [ -z "$DEADLINE_DECISION_FILE" ] || rm -f -- "$DEADLINE_DECISION_FILE"
  acquire_task_control_lock "$id"
  if [ "$release" = 1 ]; then
    fm_afk_contract_lock_hold "$STATE" || fail "task $id stays held: the away-posture record is locked"
    release_attended || fail "task $id stays held: $RELEASE_AWAY_REASON"
  fi
  require_tasks_axi
  task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$release" = 1 ]; then outcome=released; requested_mode=release; else outcome=answered; fi
  ANSWER_LIFECYCLE="$(body_hold_set_timestamp "$(decode_shown_value "$body")")#$(resolution_record_count "$body")"
  case "$ANSWER_LIFECYCLE" in '#'* ) ANSWER_LIFECYCLE='' ;; esac
  [ -z "$expected" ] || guard_answer_lifecycle "$expected" "$requested_mode" "$body" "$state" "$hold_kind"
  # The occurrence the parent line names: the record about to be written is
  # one past those already in the body, and a retry names the newest one.
  occurrence=$(( $(resolution_record_count "$body") + 1 ))

  if [ "$state" = "done" ]; then
    if body_has_resolution_record "$body"; then
      # An exact compatible retry is an idempotent no-op; drift is rejected.
      [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
        || fail "captain-held task $id records a different captain decision"
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      closed_answer_replay_mode_compatible "$recorded_mode" "$body" \
        || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay"
      [ "$release" = 0 ] \
        || fail "task $id records this answer with mode ${recorded_mode:-unknown}; --release cannot reopen a closed task"
      [ "$check_only" = 0 ] || return 0
      remove_interrupted_answer_stamp "$id"
      if [ "$recorded_mode" = repaired ]; then
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "answered (repaired)"
      else
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) answered
      fi
      printf 'answered: %s\n' "$id"
      return 0
    fi
    [ "$release" = 0 ] || fail "task $id is already closed; --release cannot reopen it"
    # Closed outside this script: record the captain's answer retroactively.
    # tasks-axi keeps hold_kind through a close, so it is the surviving proof
    # this really was the captain's item rather than ordinary finished work.
    [ "$hold_kind" = captain ] \
      || fail "task $id was never held for the captain; nothing to record an answer on"
    [ "$check_only" = 0 ] || return 0
    write_resolution_record "$id" repaired "$body"
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared while recording the answer"
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field "$show" state)" = "done" ] || fail "recording the answer reopened closed task $id"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)"
    printf 'repaired: %s\n' "$id"
    return 0
  fi

  if [ "$hold_kind" = captain ]; then
    # Actively the captain's item (a date-expired hold keeps its annotations
    # and stays answerable). A matching record means an interrupted close to
    # finish; a different digest is a NEW answer on a re-held task and gets
    # its own record on top. Either way the close mode is the caller's flag,
    # checked against an interrupted close's recorded mode so a retry cannot
    # silently flip a release into a close.
    if body_has_resolution_record "$body" \
      && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      && { [ -z "$expected" ] || [ "$(recorded_answer_lifecycle "$(decode_shown_value "$body")")" = "$expected" ]; }; then
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      case "$recorded_mode" in
        released) [ "$release" = 1 ] || fail "task $id records this answer as a release; retry with --release" ;;
        answered|routed) [ "$release" = 0 ] || fail "task $id records this answer as a close; retry without --release" ;;
        *) fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay" ;;
      esac
      [ "$check_only" = 0 ] || return 0
      if ! close_answered "$id" "$release"; then
        fail "could not close answered captain-held task $id"
      fi
      remove_interrupted_answer_stamp "$id"
      publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "$outcome"
      printf '%s: %s\n' "$outcome" "$id"
      return 0
    fi
    [ "$check_only" = 0 ] || return 0
    write_resolution_record "$id" "$outcome" "$body"
    if ! close_answered "$id" "$release"; then
      fail "could not close answered captain-held task $id"
    fi
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared after closing"
    show=$TASK_SHOW_OUTPUT
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "$outcome"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi

  # Not held and not closed: only an already-recorded release replays cleanly.
  if body_has_resolution_record "$body"; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different captain decision with mode ${recorded_mode:-unknown}"
    [ "$recorded_mode" = released ] && [ "$release" = 1 ] \
      || fail "task $id records this answer with mode ${recorded_mode:-unknown}; replay requires matching --release"
    [ "$check_only" = 0 ] || return 0
    remove_interrupted_answer_stamp "$id"
    publish_parent_resolution_then_retire "$id" $((occurrence - 1)) released
    printf 'released: %s\n' "$id"
    return 0
  fi
  fail "task $id is not held for the captain; hold it first or name the right task"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The stored binding value, or empty when the source is unbound. An unreadable
# or wrong-schema record is a hard error rather than a silent "unbound":
# feeding nothing is the safe direction only when it is a deliberate choice,
# never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  if [ "$origin" != "$BINDING_ANY" ]; then
    case "$origin" in
      ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
    esac
  fi
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  if [ -z "$origin" ] || [ "$origin" = --any-origin ]; then
    origin=$BINDING_ANY
  else
    validate_slug legacy-origin "$origin"
  fi
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <task-id> <answer> <label>
  printf 'Captain answered this call through %s.\n' "$1"
  printf 'Task: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

legacy_keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

sanitize_reconcile_provenance() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-1024
}

command_answers() {
  local origin='' source='' row rest key answer label mode id show state hold_kind body digest legacy_digest legacy_key
  local recorded_digest recorded_mode occurrence tmp err closed=0 skipped=0 reason release_flag tab=$'\t'
  local resolve_rc expected prepare=0 report_fd=1 guard_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      --any-origin) origin=$BINDING_ANY ;;
      --prepare) prepare=1; report_fd=2 ;;
      --*) usage >&2; exit 2 ;;
      *)
        [ -z "$origin" ] || { usage >&2; exit 2; }
        origin=$1
        ;;
    esac
    shift
  done
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    validate_slug legacy-origin "$origin"
  fi
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS= read -r row; do
    key=${row%%"$tab"*}
    rest=''
    case "$row" in *"$tab"*) rest=${row#*"$tab"} ;; esac
    answer=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    label=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    mode=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) expected=${rest#*"$tab"} ;; *) expected='' ;; esac
    guard_args=()
    [ -z "$expected" ] || guard_args=(--expected-lifecycle "$expected")
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 128 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    if [ "$answer" = "$RECONCILE_VALUE" ]; then
      printf 'refused: %s (reconcile requests require a bound captured source)\n' "$key" >&"$report_fd"
      skipped=$((skipped + 1))
      continue
    fi
    release_flag=''
    case "${mode:-}" in
      ''|done) : ;;
      release) release_flag=--release ;;
      *)
        printf 'skipped: %s (unknown close mode %s)\n' "$key" "$(sanitize_field "$mode")" >&"$report_fd"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    if [ "$release_flag" = --release ] && ! release_attended; then
      printf 'refused: %s (%s)\n' "$key" "$RELEASE_AWAY_REASON" >&"$report_fd"
      skipped=$((skipped + 1))
      continue
    fi
    resolve_rc=0
    id=$(resolve_entry "$origin" "$key" 2>"$err") || resolve_rc=$?
    id=${id%% *}
    if [ "$resolve_rc" = 2 ]; then
      reason=$(tr -d '\n' < "$err")
      printf 'skipped: %s (migrated-hold scan refused%s)\n' "$key" "${reason:+: $reason}" >&"$report_fd"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$resolve_rc" -ne 0 ]; then
      # resolve_entry runs in a command substitution, so task_show's exit
      # cannot stop this loop; only its status crosses back. 124 means the
      # backend never answered, which is not the same as an unknown key and
      # must not be spent as a skip.
      [ "$resolve_rc" -ne 124 ] \
        || fail "the backlog backend exceeded its read bound resolving $key"
      printf 'skipped: %s (no captain-held task with that id)\n' "$key" >&"$report_fd"
      skipped=$((skipped + 1))
      continue
    fi
    keyed_decision_text "$source" "$id" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $id"
    digest=$(sha256_text "$(cat "$tmp")")
    legacy_digest=''
    if [ "$id" != "$key" ]; then
      legacy_key=$key
    elif { [ -z "$origin" ] || [ "$origin" = "$BINDING_ANY" ]; } \
      && [ "${id#*-decision-}" != "$id" ]; then
      legacy_key=${id#*-decision-}
    else
      legacy_key=''
    fi
    if [ -n "$legacy_key" ]; then
      legacy_digest=$(sha256_text "$(legacy_keyed_decision_text "$source" "$legacy_key" "$answer" "$label")")
    fi
    task_show "$id" || { printf 'skipped: %s (absent)\n' "$id" >&"$report_fd"; skipped=$((skipped + 1)); continue; }
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    hold_kind=$(show_field_value "$show" hold_kind)
    body=$(show_field "$show" body)
    recorded_digest=$(recorded_decision_digest "$body" || true)
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    if [ -z "$expected" ] && body_has_resolution_record "$body" \
      && { [ "$recorded_digest" = "$digest" ] \
        || { case "$body" in *"Resolution recorded by fm-decision-hold."*) true ;; *) false ;; esac \
          && [ -n "$legacy_digest" ] && [ "$recorded_digest" = "$legacy_digest" ]; }; }; then
      if { [ -z "$release_flag" ] && [ "$state" = "done" ] \
          && closed_answer_replay_mode_compatible "$recorded_mode" "$body"; } \
        || { [ "$release_flag" = --release ] && [ "$state" != "done" ] \
          && [ "$hold_kind" != captain ] && [ "$recorded_mode" = released ]; }; then
        if [ "$prepare" = 1 ]; then
          printf '%s\n' "$row"
          closed=$((closed + 1))
          continue
        fi
        occurrence=$(resolution_record_count "$body")
        case "$recorded_mode" in
          repaired) publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)" ;;
          released) publish_parent_resolution_then_retire "$id" "$occurrence" released ;;
          *) publish_parent_resolution_then_retire "$id" "$occurrence" answered ;;
        esac
        printf 'closed: %s\n' "$id"
        closed=$((closed + 1))
        continue
      fi
    fi
    if [ "$state" = "done" ] && [ -z "$expected" ]; then
      printf 'skipped: %s (already closed)\n' "$id" >&"$report_fd"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$hold_kind" != captain ] && [ -z "$expected" ]; then
      printf 'skipped: %s (not held for the captain)\n' "$id" >&"$report_fd"
      skipped=$((skipped + 1))
      continue
    fi
    [ "$prepare" = 0 ] || guard_args+=(--check-only)
    # shellcheck disable=SC2086  # release_flag is empty or a single literal flag.
    if "$0" answer "$id" --decision-file "$tmp" $release_flag ${guard_args[@]+"${guard_args[@]}"} </dev/null >/dev/null 2>"$err"; then
      if [ "$prepare" = 1 ]; then
        printf '%s\n' "$row"
        closed=$((closed + 1))
        continue
      fi
      # A parent-channel delivery problem is reported on stderr by the answer
      # path even when the close succeeded; keep it visible.
      [ ! -s "$err" ] || cat "$err" >&2
      printf 'closed: %s\n' "$id"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-captain-hold: //')
      printf 'skipped: %s (%s)\n' "$id" "$reason" >&"$report_fd"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  [ "$prepare" = 0 ] || return 0
  printf 'answers: closed=%s skipped=%s\n' "$closed" "$skipped"
  [ "$skipped" -eq 0 ]
}

# --- reconcile: verify latest state, then close with evidence or annotate ----
#
# The semantics are owned by docs/captain-hold-lifecycle.md; this section owns
# the durable record and the two terminal operations that retire it. Nothing
# here closes a captain call on the strength of a reconcile alone: `close`
# demands the evidence that made the call moot, and `note` leaves it open.

RECONCILE_DIR="$STATE/reconcile-requests"
RECONCILE_SCHEMA=fm-reconcile-request.v1
RECONCILE_VALUE=reconcile

reconcile_request_path() { printf '%s/%s.request\n' "$RECONCILE_DIR" "$1"; }

# Idempotent per task: a repeated reconcile keeps the one request and its
# original timestamp, so a re-delivered board answer never resets the clock on
# an obligation that is already open.
reconcile_request_record() {  # <task-id> <provenance>
  local id=$1 source=$2 path tmp
  path=$(reconcile_request_path "$id")
  [ ! -e "$path" ] || return 0
  (umask 077; mkdir -p "$RECONCILE_DIR") || return 1
  [ -d "$RECONCILE_DIR" ] && [ ! -L "$RECONCILE_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$RECONCILE_DIR/.request.XXXXXX") || return 1
  if {
    printf 'schema=%s\n' "$RECONCILE_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'requested=%s\n' "${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf 'source=%s\n' "$(sanitize_reconcile_provenance "$source")"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

reconcile_request_read() {  # <task-id>; sets RECONCILE_REQUESTED/RECONCILE_SOURCE
  local id=$1 path schema task
  path=$(reconcile_request_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$RECONCILE_SCHEMA" ] || fail "reconcile request has an incompatible schema: $path"
  task=$(sed -n 's/^task=//p' "$path" | head -1)
  [ "$task" = "$id" ] || fail "reconcile request names a different task: $path"
  RECONCILE_REQUESTED=$(sed -n 's/^requested=//p' "$path" | head -1)
  RECONCILE_SOURCE=$(sed -n 's/^source=//p' "$path" | head -1)
}

reconcile_request_retire() {  # <task-id>
  rm -f -- "$(reconcile_request_path "$1")" \
    || fail "could not retire the pending reconcile request for $1"
}

publish_parent_resolution_then_retire() {  # <task-id> <occurrence> <note>
  local id=$1 occurrence=$2 note=$3 request
  [ "$DEADLINE_DEFAULT" != 1 ] || note="$note by deadline default, not by the captain"
  request=$(reconcile_request_path "$id")
  publish_parent_hold "$id" "$occurrence" resolved "$note"
  if [ -e "$request" ] && [ "$PARENT_HOLD_PUBLISHED" != 1 ]; then
    fail "could not publish the answered captain-held task $id to its parent"
  fi
  reconcile_request_retire "$id"
}

command_reconcile_requests() {
  local source_id='' source='' origin row id note provenance show show_status=0 created=0 skipped=0 tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) shift; source_id=${1:-} ;;
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_source_id "$source_id"
  [ -n "$source" ] || fail "--source provenance is required"
  origin=$(read_binding "$source_id") || fail "cannot verify the binding for source $source_id"
  [ -n "$origin" ] || fail "source $source_id is not bound; no reconcile requests were created"
  require_tasks_axi
  while IFS= read -r row; do
    id=${row%%"$tab"*}
    note=''
    case "$row" in *"$tab"*) note=${row#*"$tab"} ;; esac
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*) printf 'refused: %s (invalid task id)\n' "$id"; skipped=$((skipped + 1)); continue ;;
    esac
    [ "${#id}" -le 128 ] \
      || { printf 'refused: %s (task id is too long)\n' "$id"; skipped=$((skipped + 1)); continue; }
    acquire_task_control_lock "$id"
    show_status=0
    show=''
    task_show "$id" || show_status=$?
    [ "$show_status" -ne 0 ] || show=$TASK_SHOW_OUTPUT
    if [ "$show_status" -eq 124 ]; then
      fail "the backlog backend exceeded its read bound reading $id"
    fi
    if [ -z "$show" ]; then
      printf 'refused: %s (absent)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field "$show" state)" = "done" ]; then
      printf 'refused: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field_value "$show" hold_kind)" != captain ]; then
      printf 'refused: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
    else
      provenance=$source
      [ -z "$note" ] || provenance="$source; captain note: $(sanitize_field "$note")"
      if reconcile_request_record "$id" "$provenance"; then
        printf 'reconcile: %s\n' "$id"
        created=$((created + 1))
      else
        printf 'refused: %s (cannot record the reconcile request)\n' "$id"
        skipped=$((skipped + 1))
      fi
    fi
    release_task_control_lock || fail "cannot release task control for $id"
  done
  printf 'reconcile-requests: created=%s skipped=%s\n' "$created" "$skipped"
  [ "$skipped" -eq 0 ]
}

command_reconcile() {
  local action=${1:-}
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$action" in
    list)    reconcile_list "$@" ;;
    close)   reconcile_close "$@" ;;
    note)    reconcile_note "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

reconcile_list() {
  local path id count=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$RECONCILE_DIR" ] || { printf 'reconcile-requests: 0\n'; return 0; }
  for path in "$RECONCILE_DIR"/*.request; do
    [ -e "$path" ] || continue
    id=${path##*/}; id=${id%.request}
    RECONCILE_REQUESTED=''
    RECONCILE_SOURCE=''
    reconcile_request_read "$id" || continue
    printf '%s\trequested=%s\tsource=%s\n' "$id" "$RECONCILE_REQUESTED" "$RECONCILE_SOURCE"
    count=$((count + 1))
  done
  printf 'reconcile-requests: %s\n' "$count"
}

# The moot outcome. The evidence is what closes the call, and the `reconciled`
# resolution mode is what keeps the record from claiming the captain answered.
reconcile_close() {
  local id=${1:-} evidence_file='' show state hold_kind body occurrence recorded_mode
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence-file) shift; evidence_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$evidence_file" ] || fail "--evidence-file is required; a moot call closes on evidence, never on assertion"
  load_decision "$evidence_file"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  occurrence=$(( $(resolution_record_count "$body") + 1 ))
  if [ "$state" = "done" ]; then
    # An exact retry finishes an interrupted close and stays idempotent; a
    # different evidence text on an already closed call is refused.
    body_has_resolution_record "$body" \
      || fail "task $id is already closed with no resolution record; use answer to record what closed it"
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different resolution; it cannot be reconciled again"
    [ "$(recorded_resolution_mode "$body" || true)" = reconciled ] \
      || fail "task $id was not closed by reconciliation"
    occurrence=$(resolution_record_count "$body")
    remove_interrupted_answer_stamp "$id"
    publish_parent_hold "$id" "$occurrence" resolved reconciled
    [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
      || fail "could not publish the reconciled captain-held task $id to its parent"
    reconcile_request_retire "$id"
    printf 'reconciled: %s\n' "$id"
    return 0
  fi
  [ "$hold_kind" = captain ] \
    || fail "task $id is not held for the captain; there is no captain call to reconcile"
  if body_has_resolution_record "$body" \
    && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$recorded_mode" = reconciled ] \
      || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a reconciliation retry"
    occurrence=$(resolution_record_count "$body")
  else
    write_resolution_record "$id" reconciled "$body"
  fi
  close_answered "$id" 0 || fail "could not close reconciled captain-held task $id"
  remove_interrupted_answer_stamp "$id"
  task_show_or_fail "$id" "task $id disappeared after closing"
  body_has_resolution_record "$(show_field "$show" body)" \
    || fail "captain-held task $id did not retain its durable resolution record"
  publish_parent_hold "$id" "$occurrence" resolved reconciled
  [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
    || fail "could not publish the reconciled captain-held task $id to its parent"
  reconcile_request_retire "$id"
  printf 'reconciled: %s\n' "$id"
}

# The still-active outcome. The hold survives, so the call stays the captain's
# and stays on Captain's Call, now carrying what the re-check found.
reconcile_note() {
  local id=${1:-} note_file='' note show body stamp tmp note_digest marker
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-file) shift; note_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$note_file" ] || fail "--note-file is required; leaving a call open records what the re-check found"
  [ -f "$note_file" ] || fail "note file does not exist: $note_file"
  note=$(cat "$note_file")
  [ -n "$note" ] || fail "note file must not be empty"
  [ "$(printf '%s' "$note" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "note file exceeds 8192 bytes"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  command_open "$id" \
    || fail "task $id is not an open captain call; a note cannot keep a closed call open"
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  note_digest=$(sha256_text "$note")
  marker="Reconcile request: $RECONCILE_REQUESTED | $RECONCILE_SOURCE | note digest: $note_digest"
  case "$body" in
    *"$marker"*)
      reconcile_request_retire "$id" \
        || fail "could not retire the applied reconcile request for $id"
      command_open "$id" || fail "recording the reconcile note released captain-held task $id"
      printf 'still-open: %s\n' "$id"
      return 0
      ;;
  esac
  stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-note.XXXXXX") \
    || fail "cannot stage the reconcile note"
  if ! printf '%s\n\nCaptain hold reconciled: %s\n%s\n%s\n' "$body" "$stamp" "$marker" "$note" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the reconcile note for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the reconcile note on $id"
  fi
  rm -f -- "$tmp"
  reconcile_request_retire "$id" \
    || fail "could not retire the applied reconcile request for $id"
  command_open "$id" || fail "recording the reconcile note released captain-held task $id"
  printf 'still-open: %s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' entry key status_file open has_meta=0 transfer_rc transfers=() resolved
  local resolved_how attested_by_prefix='' origin_state unrecorded_origin='' tmp verify_status
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    CAPTAIN_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with task ids"
      validate_slug task-id "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      verify_status=0
      resolved=$(verify_entry_durable "$origin" "$entry") || verify_status=$?
      if [ "$verify_status" -ne 0 ]; then
        # Union with the record means a refused entry may be one this command
        # never named. It keeps refusing: an unprovable call must not vanish.
        if list_has_key "$previous" "$entry" && ! printf '%s\n' "$supplied" | tr ' ' '\n' | grep -Fxq -- "$entry"; then
          printf 'fm-captain-hold: %s came from the decision_keys= line already in %s, not from this command; complete keeps every recorded entry until it verifies. If the task now holding that call has another id, or the call was answered and its row is gone from this backlog, replace or remove only %s on that line once the answer is confirmed, then re-run complete.\n' "$entry" "$meta" "$entry" >&2
        fi
        exit "$verify_status"
      fi
      origin_state=${resolved##* }
      resolved=${resolved% *}
      resolved_how=${resolved##* }
      resolved=${resolved%% *}
      if [ "$origin_state" = unrecorded ]; then
        unrecorded_origin="${unrecorded_origin}${unrecorded_origin:+ }$resolved"
      fi
      if [ "$resolved_how" = migrated-prefix ]; then
        attested_by_prefix="${attested_by_prefix}${attested_by_prefix:+ }$entry=$resolved"
      fi
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  open=$(status_open_decisions "$status_file")
  if [ -n "$open" ] && [ -z "$keys" ]; then
    fail "origin $origin still has open captain decisions in its status stream; hold a captain task for what remains, or answer them, before attesting --none"
  fi

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      tmp=$(mktemp "$STATE/.$origin.meta.XXXXXX") \
        || fail "cannot stage the completion record for $origin"
      if ! awk -v keys="$keys" '
          /^(decisions_reviewed|decision_keys)=/ { next }
          /^pr=/ && !done { print "decisions_reviewed=1"; print "decision_keys=" keys; done = 1 }
          { print }
          END { if (!done) { print "decisions_reviewed=1"; print "decision_keys=" keys } }
        ' "$meta" > "$tmp" || ! mv -f -- "$tmp" "$meta"; then
        rm -f -- "$tmp"
        fail "cannot record completion for $origin"
      fi
    fi
    fm_lock_release "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=0

    # Transfer every still-open status decision to the durable captain-held
    # inventory so the live status fold does not duplicate the same Captain's
    # Call item. The transfer lines are this home's own bookkeeping closes,
    # written by the turn that just reviewed the inventory, so they go through
    # ONE guarded self-announced append (bin/fm-wake-lib.sh) and do not wake
    # this same session; an append failure still fails this command loudly.
    if [ -n "$keys" ]; then
      while IFS=$'\t' read -r key _verb _summary; do
        [ -n "$key" ] || continue
        transfers+=("captain-held [key=$key]: tracked by $keys")
      done <<EOF
$open
EOF
      if [ "${#transfers[@]}" -gt 0 ]; then
        transfer_rc=0
        fm_wake_status_append_self_announced "$STATE" "$status_file" "${transfers[@]}" || transfer_rc=$?
        [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin"
      fi
    fi
  fi
  printf 'complete: %s captain-call inventory reviewed%s%s%s\n' "$origin" "${keys:+ ($keys)}" \
    "${attested_by_prefix:+ [attested through the configured prefix: $attested_by_prefix]}" \
    "${unrecorded_origin:+ [no recorded origin on: $unrecorded_origin; not checked against $origin]}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys entry key open resolved
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed captain-call inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      verify_entry_durable "$origin" "$entry" >/dev/null
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(status_open_decisions "$STATE/$origin.status")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    fail "open captain decision $origin/$key is not transferred to the captain-held inventory; re-run complete"
  done <<EOF
$open
EOF
  printf 'verified: %s captain-call inventory\n' "$origin"
}

# --- record divergence ------------------------------------------------------
#
# A captain call can be written down twice, and until now nothing said when
# those two records disagreed. A `resolved [key=...]` line closes the status-log
# fold outright; the structured captain-held task is closed by a SEPARATE act
# (`answer` above). Closing only on the status side therefore looks complete
# there while the durable record still says the captain owes an answer and
# keeps resurfacing it. The defect was never the separation; it was the silence.
#
# `diverged` is a read-only report of that contradiction and nothing else. It
# closes NOTHING. A captain call closed wrongly disappears without review, which
# is strictly worse than the noise this prints, so reconciling a divergence stays
# a human-owned act - and it runs in either direction: record what the captain
# actually said with `answer`, or re-open the status decision when that
# resolution was not the captain's word.
#
# What it flags, and only this: a task that is still open and still carries the
# captain-hold annotations, whose key was closed on the status side by the
# RESOLVE verb. The other closing verb is not a divergence: a `captain-held`
# close is the VERIFIED transfer to that very task, written by command_complete
# only after verifying it, so the structured row staying open behind it is the
# correct state. Neither is a still-open status decision - the OPEN DECISIONS
# fold already owns that one.
#
# Routed work is deliberately irrelevant. When the decision IS the deliverable
# there is nothing to route, so the test is only whether the status side already
# declared this task's key resolved.
# Nor does the report interpret why that resolution exists. A call can turn out
# not to be a captain arbitration at all - a premise can dissolve, or a question
# of fact can prove its first reading wrong - so the report says only that the
# two records disagree and names both reconciliation directions above.
#
# Cost stays flat on a healthy home: one `tasks-axi list`, one key scan per
# status log, and the precise per-key fold only for a key that already names a
# still-open task. If tasks-axi is unavailable or its listing cannot be parsed,
# the guard cannot read the structured record and prints nothing.
#
# Output: one `<task-id>\t<origin>\t<key>\t<title>` line per divergence, in
# status-log then key order; nothing when the two records agree.

# Every still-open task id in this home's backlog, one per line. Only the first
# two comma-separated listing fields are read - both are slugs that precede any
# quoted title - so a title containing commas or quotes cannot shift them.
open_task_ids() {
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  fm_backlog_row_list "$data" 2>/dev/null | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      if ($2 != "done") print id
    }
  '
}

open_captain_task_ids() {
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  fm_backlog_row_list "$data" --fields hold_kind 2>/dev/null | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      if ($2 != "done" && $NF == "captain") print id
    }
  '
}

# Every key token stated anywhere in a status log. A cheap candidate scan: it
# over-includes tokens that are only prose, and status_key_closing_verb below is
# what actually decides what the stream says about a key.
status_log_key_tokens() {  # <status-file>
  grep -o '\[key=[A-Za-z0-9._-]*\]' "$1" 2>/dev/null |
    sed 's/^\[key=//; s/\]$//' | LC_ALL=C sort -u
}

list_has_line() {  # <newline-separated-list> <value>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

command_diverged() {
  local ids resolve f origin tokens id keys key show title
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # Both records must belong to the SAME home or the comparison is meaningless:
  # tasks-axi reads $FM_HOME's backlog, so a state dir pointed somewhere else
  # would report one home's status logs against another home's tasks. Every
  # production caller pairs the two; a mismatch stays silent rather than
  # inventing a cross-home divergence.
  [ "$STATE" = "$FM_HOME/state" ] || return 0
  # A read-only listing on a per-wake path, so it skips the mutation-oriented
  # compatibility floor and its extra probes: a listing this parser cannot read
  # simply yields no candidates and the report stays silent.
  command -v tasks-axi >/dev/null 2>&1 || return 0
  ids=$(open_task_ids) || return 0
  [ -n "$ids" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    origin=$(basename "$f"); origin=${origin%.status}
    tokens=$(status_log_key_tokens "$f")
    [ -n "$tokens" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # The keys that could name this task in THIS log: the collapsed identity
      # (the key IS the task id) and, for a pre-collapse row, the legacy derived
      # one this origin would have minted.
      keys=$id
      case "$id" in
        "$origin-decision-"?*) keys="$keys"$'\n'"${id#"$origin-decision-"}" ;;
      esac
      while IFS= read -r key; do
        list_has_line "$tokens" "$key" || continue
        [ "$(status_key_closing_verb "$f" "$key")" = "$resolve" ] || continue
        task_show "$id" || continue
        show=$TASK_SHOW_OUTPUT
        [ "$(show_field "$show" state)" != "done" ] || continue
        [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
        # The title is the only free-text field here, and the report is
        # TAB-separated, so it goes through the same sanitizer every other
        # emitted field uses rather than being trusted to stay one clean line.
        title=$(sanitize_field "$(show_field_value "$show" title)")
        printf '%s\t%s\t%s\t%s\n' "$id" "$origin" "$key" "$title"
        break
      done <<INNER
$keys
INNER
    done <<EOF
$ids
EOF
  done
}

# `defaults-due` runs on every wake, and reading each open captain call costs one
# backlog-backend process, so what the backlog says about each pending default is
# kept in $STATE/.defaults-due-cache between runs. The cache holds only what the
# records themselves say (every call carrying a pending default, with its clock),
# keyed on a checksum of the backlog file, its backend config, the backend binary
# and the scripts that read a call; the clock is still read live, so a default
# comes due at its instant whatever the cache holds.
DEFAULTS_DUE_CACHE_VERSION=1
DEFAULTS_DUE_SEP=$'\037'
# Far past any real deadline: asks deadline_default_due for every pending default
# regardless of the clock, so the candidate list does not depend on it.
DEFAULTS_DUE_ANY_TIME=9999-12-31T23:59:59Z

# Sets DEFAULTS_DUE_CACHE_KEY, or fails when this home's backlog is not a plain
# markdown file this script can checksum (the read then goes uncached).
defaults_due_cache_key() {
  local data sums tasks_axi
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  fm_backlog_tasks_axi_addressing "$data" || return 1
  [ -n "$FM_BACKLOG_AXI_FILE" ] && [ -f "$FM_BACKLOG_AXI_FILE" ] || return 1
  tasks_axi=$(command -v tasks-axi) || return 1
  sums=$(LC_ALL=C cksum "$FM_BACKLOG_AXI_FILE" "$FM_BACKLOG_AXI_ROOT/.tasks.toml" "$tasks_axi" \
    "$SCRIPT_DIR/fm-captain-hold.sh" "$SCRIPT_DIR/fm-captain-question-context.jq" 2>/dev/null | tr '\n' ' ') || return 1
  [ -n "$sums" ] || return 1
  DEFAULTS_DUE_CACHE_KEY="v$DEFAULTS_DUE_CACHE_VERSION $sums"
}

# Print one row per open captain call that carries a pending default, whatever the
# clock says: id, hold-until gate, due instant, date, value, label, close, title,
# separated by DEFAULTS_DUE_SEP (a byte no field can hold, so an empty gate or
# title keeps its place). Fails, leaving nothing worth caching, when the open
# calls cannot be listed or any one of them cannot be read.
defaults_due_candidates() {
  local ids id pending complete=0 hold_until due_at date value label close title
  ids=$(open_captain_task_ids) || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    task_show "$id" || { complete=1; continue; }
    pending=$(deadline_default_due "$TASK_SHOW_OUTPUT" "$DEFAULTS_DUE_ANY_TIME") || continue
    hold_until=$(show_field_value "$TASK_SHOW_OUTPUT" hold_until)
    due_at=$(printf '%s' "$pending" | jq -r .due_at)
    date=$(printf '%s' "$pending" | jq -r .date)
    value=$(printf '%s' "$pending" | jq -r .value)
    label=$(sanitize_field "$(printf '%s' "$pending" | jq -r .label)")
    close=$(printf '%s' "$pending" | jq -r .close)
    title=$(sanitize_field "$(show_field_value "$TASK_SHOW_OUTPUT" title)")
    printf '%s\n' "$id$DEFAULTS_DUE_SEP$hold_until$DEFAULTS_DUE_SEP$due_at$DEFAULTS_DUE_SEP$date$DEFAULTS_DUE_SEP$value$DEFAULTS_DUE_SEP$label$DEFAULTS_DUE_SEP$close$DEFAULTS_DUE_SEP$title"
  done <<EOF
$ids
EOF
  [ "$complete" -eq 0 ]
}

# Print the rows of <candidates> that are due at <now> in the report format, with
# the same two gates deadline_default_due applies: the captain's own date gate and
# the deadline instant.
defaults_due_report() {  # <now> <candidates>
  local now=$1 today=${1%%T*} row id hold_until due_at date value label close title
  while IFS=$DEFAULTS_DUE_SEP read -r id hold_until due_at date value label close title; do
    [ -n "$id" ] || continue
    case "$hold_until" in
      ''|-) : ;;
      *) if [[ "$hold_until" > "$today" ]]; then continue; fi ;;
    esac
    # shellcheck disable=SC2310 # A deadline later than now is simply not due.
    if (LC_ALL=C; [[ "$due_at" > "$now" ]]); then continue; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$date" "$value" "$label" "$close" "$title"
  done <<EOF
$2
EOF
}

command_defaults_due() {
  local now candidates='' cache cached_key key='' have=0 tmp
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # A read-only listing on a per-wake path, like `diverged`: what it cannot read
  # stays undue, so a default only ever proceeds on a record it read in full.
  command -v tasks-axi >/dev/null 2>&1 || return 0
  require_context_codec
  now=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  cache="$STATE/.defaults-due-cache"
  if defaults_due_cache_key; then
    key=$DEFAULTS_DUE_CACHE_KEY
    if [ -f "$cache" ] && [ ! -L "$cache" ] && [ -r "$cache" ]; then
      { IFS= read -r cached_key && [ "$cached_key" = "$key" ] && have=1 && { IFS= read -r -d '' candidates || true; }; } < "$cache" 2>/dev/null || true
    fi
  fi
  if [ "$have" -eq 0 ]; then
    candidates=$(defaults_due_candidates) || {
      # Part of the backlog could not be read: report what was readable, as before,
      # but keep it out of the cache so the next run reads those calls again.
      defaults_due_report "$now" "$candidates"
      return 0
    }
    if [ -n "$key" ] && [ ! -L "$cache" ]; then
      tmp="$cache.tmp.$$"
      if { printf '%s\n' "$key"; [ -z "$candidates" ] || printf '%s\n' "$candidates"; } > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
      else
        rm -f "$tmp"
      fi
    fi
  fi
  defaults_due_report "$now" "$candidates"
}

# Stop this lifecycle's deadline default (see the header). The line goes
# directly under the active context, so a later answer moves it below the
# resolution with the rest of the header and it never outlives its lifecycle.
command_stop_clock() {
  local id=${1:-} source='' body read lifecycle stamp context_line rest tmp
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--source requires provenance text"; shift; source=$1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$source" ] || fail "--source is required: say who stopped the clock and through which channel"
  validate_one_line source "$source"
  [ "${#source}" -le 200 ] || fail "--source must be at most 200 characters"
  require_context_codec
  acquire_task_control_lock "$id"
  require_tasks_axi
  command_open "$id" || fail "task $id is not an open captain call; there is no clock to stop"
  task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  body=$(decode_shown_value "$(show_field "$TASK_SHOW_OUTPUT" body)") \
    || fail "could not decode the existing body for $id"
  read=$(context_for_body "$body") || fail "cannot read the question context of $id"
  [ "$(printf '%s' "$read" | jq -r .status)" = ready ] \
    || fail "task $id has no readable question context, so it carries no deadline default"
  [ "$(printf '%s' "$read" | jq -r '.context.default_eligible // ""')" = small-reversible ] \
    || fail "task $id carries no deadline default; nothing to stop"
  lifecycle=$(printf '%s' "$read" | jq -r .lifecycle)
  if [ "$(printf '%s' "$read" | jq -r '.default_stopped // ""')" != "" ]; then
    printf 'stopped: %s (already, at %s)\n' "$id" "$(printf '%s' "$read" | jq -r .default_stopped)"
    return 0
  fi
  stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$body" in
    "Captain hold set: "*$'\n''Captain question context: '*) : ;;
    *) fail "task $id does not carry its active context where the owner wrote it; owner review required" ;;
  esac
  context_line=${body#*$'\n'}
  rest=''
  case "$context_line" in *$'\n'*) rest=${context_line#*$'\n'} ;; esac
  context_line=${context_line%%$'\n'*}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-stop.XXXXXX") || fail "cannot stage the stopped clock"
  if ! printf '%s\n%s\nCaptain deadline default stopped: %s at %s by %s\n%s\n' \
      "${body%%$'\n'*}" "$context_line" "$lifecycle" "$stamp" "$source" "$rest" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the stopped clock on $id"
  fi
  rm -f -- "$tmp"
  task_show "$id" || fail "task $id disappeared while stopping its clock"
  [ "$(context_for_body "$(decode_shown_value "$(show_field "$TASK_SHOW_OUTPUT" body)")" \
    | jq -r '.status + " " + (.default_stopped // "")')" = "ready $stamp" ] \
    || fail "task $id did not retain a readable stopped clock; owner review required"
  printf 'stopped: %s\n' "$id"
}

# Still an open captain call? Exit 0 yes, 1 no, 2 cannot tell (see the header).
# A row this home does not carry is 3 when the caller requests the distinction,
# and so is a home with no backlog file at all, because a backlog that does not
# exist holds nothing. Every read failure over a record that DOES exist is a 2,
# printed to stderr, because a mechanical closer must never read "cannot tell"
# as permission to close.
command_open() {  # <task-id> [--identity] [--distinguish-absent]
  local id='' identity=0 distinguish_absent=0 data state root file backend show shown_body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity=1 ;;
      --distinguish-absent) distinguish_absent=1 ;;
      -*) usage >&2; exit 2 ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 2; }
        id=$1
        ;;
    esac
    shift
  done
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      printf 'fm-captain-hold: task id must be a non-empty privacy-safe slug: %s\n' "$id" >&2
      exit 2
      ;;
  esac
  data=$(fm_backlog_data_absolute "$DATA") \
    || { printf 'fm-captain-hold: data directory cannot be resolved: %s\n' "$DATA" >&2; exit 2; }
  root=$(fm_backlog_root "$data") \
    || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
  if ! backend=$(fm_tasks_axi_backend_resolve "$root"); then
    exit 2
  fi
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") \
      || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      # No backlog file at all: this home records no captain calls, so the task
      # is absent from it rather than held. A record that EXISTS but cannot be
      # read is a different state and still leaves by the exit 2 paths below,
      # because that one may hide a live hold.
      [ "$distinguish_absent" = 0 ] || return 3
      return 1
    fi
  fi
  fm_tasks_axi_compatible || { printf 'fm-captain-hold: compatible tasks-axi is required\n' >&2; exit 2; }
  if fm_backlog_row_probe "$data" "$id"; then
    state=${FM_BACKLOG_ROW_STATE%% *}
    if [ "$state" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      if [ "$identity" -eq 1 ]; then
        task_show "$id" || {
          printf 'fm-captain-hold: captain call %s is open but its record could not be read\n' "$id" >&2
          exit 2
        }
        show=$TASK_SHOW_OUTPUT
        shown_body=$(show_field "$show" body)
        printf '%s#%s\n' \
          "$(body_hold_set_timestamp "$(decode_shown_value "$shown_body")")" \
          "$(resolution_record_count "$shown_body")"
      fi
      return 0
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    [ "$distinguish_absent" = 0 ] || return 3
    return 1
  fi
  printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_ROW_ERROR" >&2
  exit 2
}

command_answered() {  # <task-id>
  local id=${1:-} body leader digest mode line
  [ "$#" -eq 1 ] || { usage >&2; return 2; }
  validate_slug task-id "$id"
  task_show "$id" || return 1
  [ "$(show_field "$TASK_SHOW_OUTPUT" state)" = 'done' ] || return 1
  body=$(decode_shown_value "$(show_field "$TASK_SHOW_OUTPUT" body)") || return 1
  # Check only the latest resolution header; historical answers, default words
  # and evidence-backed reconciliation must not vouch for a personal result.
  {
    IFS= read -r leader && IFS= read -r digest && IFS= read -r mode && IFS= read -r line || return 1
    [ "$leader" = 'Resolution recorded by fm-captain-hold.' ] || return 1
    [[ "$digest" =~ ^Decision\ digest:\ [a-f0-9]{64}$ ]] || return 1
    case "$mode" in 'Resolution mode: answered'|'Resolution mode: repaired') ;; *) return 1 ;; esac
    case "$line" in 'Captain answer lifecycle: '*) IFS= read -r line || return 1 ;; esac
    [ -z "$line" ] && IFS= read -r line && [ "$line" = 'Captain decision:' ]
  } <<< "$body"
}

case "${1:-}" in
  hold) shift; command_hold "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  contexts) shift; command_contexts "$@" ;;
  reconcile-requests) shift; command_reconcile_requests "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  open) shift; command_open "$@" ;;
  answered) shift; command_answered "$@" ;;
  diverged) shift; command_diverged "$@" ;;
  defaults-due) shift; command_defaults_due "$@" ;;
  stop-clock) shift; command_stop_clock "$@" ;;
  reconcile) shift; command_reconcile "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
