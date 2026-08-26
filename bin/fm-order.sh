#!/usr/bin/env bash
# fm-order.sh - the order book: every captain word becomes a durable, typed record
# at the moment it is received, and no session acts after a restart without
# reciting the active set (plan v3 U1.1; hardening 1; failure patterns L10/L45/L71).
#
# Usage:
#   fm-order.sh record --type decision|directive|promise|prohibition \
#       --subject <slug> (--quote <text> | --quote-file <path>) \
#       [--translation <text>] [--scope <text>] [--due YYYY-MM-DD] \
#       [--expires YYYY-MM-DD] [--task <task-id>] [--source <who>] \
#       [--enforce '<gate> [allow] <key>=<value>...']...
#   fm-order.sh list [--all]         active orders (default) or every order
#   fm-order.sh show <id>            print one order record
#   fm-order.sh pin                  emit the uncompressible active-orders block
#   fm-order.sh recite <id>...       verify the recited set equals the active set
#   fm-order.sh close <id> --reason <text> [--captain-wording <text>]
#   fm-order.sh check-subject <subject> [--new-fact <text>]
#   fm-order.sh gate-check <gate> [--ctx <key>=<value>]...
#   fm-order.sh --help
#
# Types (L45): decision (captain decision; closing needs his verbatim wording),
# directive (an order to act), promise (a commitment; requires --due),
# prohibition (requires --scope; closing needs his verbatim wording).
#
# File contract (this header is the single owner):
#   $FM_HOME/data/entscheide/<UTC date>/order-<id>.md
#     header block, terminated by the first blank line, one "key: value" per line:
#       id, type, subject, status (active|closed), scope, source, recorded,
#       due, expires, task   ("-" for empty)
#       enforce  OPTIONAL and REPEATABLE, last in the header block: the
#                machine-readable half of the order, format and semantics owned
#                by bin/fm-order-gate-lib.sh's header, validated here at write
#                time so a malformed entry never reaches a gate (L64)
#     "## wording (verbatim, original language)" then the quote, byte-exact
#     "## translation (EN, marked)" then the marked translation or "(none)"
#     closing appends "## closed" with closed/reason/captain-wording lines
#   $FM_HOME/data/entscheide/.order-seq(.lock): flock-guarded id counter (L88).
#
# Guarantees: refuses an empty quote (L57); ids are issued under a lock, never
# from memory (L88); writes are atomic; a decision or prohibition closes only
# with the captain's verbatim wording (hardening 8: an agent message is never
# captain consent); `check-subject` blocks re-submitting a decided subject
# without a named new fact (L71); `recite` fails loudly on any mismatch so a
# restarted session must re-anchor before acting (hardening 1). An order past
# its expires date stops binding: it leaves pin and recite but stays on disk.
#
# Enforcement: an order MAY carry `enforce:` lines so a tool can ask it
# (`gate-check`, or bin/fm-order-gate-lib.sh from inside a gate). The wording
# stays the source of truth; `show` and `pin` print every enforce line twice -
# verbatim as recorded, and once more as an "[interpretation]" line clearly
# marked as such, so no agent ever mistakes our reading for the captain's words
# (L46, L50).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
export FM_HOME
ORDERS="$FM_HOME/data/entscheide"

# shellcheck source=bin/fm-order-gate-lib.sh
. "$SCRIPT_DIR/fm-order-gate-lib.sh"

usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
today() { date -u +%F; }

order_files() {
  [ -d "$ORDERS" ] || return 0
  find "$ORDERS" -mindepth 2 -maxdepth 2 -name 'order-O-*.md' 2>/dev/null | sort
}

field() { # field <file> <key> -> value from the header block
  awk -v k="$2" '/^$/{exit} index($0, k": ")==1 {print substr($0, length(k)+3); exit}' "$1"
}

wording_first_line() {
  awk '/^## wording/{f=1; next} f && NF {print; exit}' "$1"
}

is_expired() { # is_expired <expires-value>
  [ "$1" != "-" ] && [[ "$1" < "$(today)" ]]
}

active_rows() { # prints "<id>\t<file>" for every binding (active, unexpired) order
  local f id status expires
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    status="$(field "$f" status)"
    [ "$status" = "active" ] || continue
    expires="$(field "$f" expires)"
    if is_expired "$expires"; then continue; fi
    id="$(field "$f" id)"
    printf '%s\t%s\n' "$id" "$f"
  done < <(order_files)
}

find_by_id() {
  [ -d "$ORDERS" ] || return 0
  find "$ORDERS" -mindepth 2 -maxdepth 2 -name "order-$1.md" 2>/dev/null | head -1
}

next_id() {
  mkdir -p "$ORDERS"
  local n
  exec 9>"$ORDERS/.order-seq.lock"
  flock 9
  n="$(cat "$ORDERS/.order-seq" 2>/dev/null || echo 0)"
  n=$((n + 1))
  printf '%s\n' "$n" > "$ORDERS/.order-seq"
  printf 'O-%04d' "$n"
}

valid_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

cmd="${1:-}"
case "$cmd" in
  record)
    shift
    type="" subject="" quote="" quote_file="" translation="" scope="-"
    due="-" expires="-" task="-" source="captain"
    enforce_entries=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --enforce) enforce_entries+=("${2:-}"); shift 2 ;;
        --type) type="${2:-}"; shift 2 ;;
        --subject) subject="${2:-}"; shift 2 ;;
        --quote) quote="${2:-}"; shift 2 ;;
        --quote-file) quote_file="${2:-}"; shift 2 ;;
        --translation) translation="${2:-}"; shift 2 ;;
        --scope) scope="${2:-}"; shift 2 ;;
        --due) due="${2:-}"; shift 2 ;;
        --expires) expires="${2:-}"; shift 2 ;;
        --task) task="${2:-}"; shift 2 ;;
        --source) source="${2:-}"; shift 2 ;;
        *) die "unknown argument '$1' for record" ;;
      esac
    done
    case "$type" in
      decision|directive|promise|prohibition) ;;
      *) die "record requires --type decision|directive|promise|prohibition" ;;
    esac
    [[ "$subject" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "record requires --subject as a lowercase slug ([a-z0-9-])"
    if [ -n "$quote_file" ]; then
      [ -f "$quote_file" ] || die "quote file not found: $quote_file"
      quote="$(cat "$quote_file")"
    fi
    [ -n "${quote//[[:space:]]/}" ] || die "record refuses an empty wording: pass the verbatim words via --quote or --quote-file"
    [ "$due" = "-" ] || valid_date "$due" || die "--due must be YYYY-MM-DD"
    [ "$expires" = "-" ] || valid_date "$expires" || die "--expires must be YYYY-MM-DD"
    if [ "$type" = "promise" ] && [ "$due" = "-" ]; then
      die "a promise requires --due (L45: a commitment carries its due date)"
    fi
    if [ "$type" = "prohibition" ] && [ "$scope" = "-" ]; then
      die "a prohibition requires --scope (L45: a prohibition carries its scope)"
    fi
    if { [ "$type" = "decision" ] || [ "$type" = "prohibition" ]; } && [ "$source" != "captain" ]; then
      die "a $type is recorded only from the captain's own words (hardening 8); got --source '$source'"
    fi
    if [ "$task" != "-" ]; then
      command -v tasks-axi >/dev/null 2>&1 || die "--task needs tasks-axi on PATH to hold the backlog item; nothing was recorded"
    fi
    for entry in "${enforce_entries[@]+"${enforce_entries[@]}"}"; do
      fm_order_gate_validate_entry "$entry" \
        || die "--enforce '$entry' is not a valid enforce entry (see bin/fm-order-gate-lib.sh); nothing was recorded"
    done
    id="$(next_id)"
    dir="$ORDERS/$(today)"
    mkdir -p "$dir"
    file="$dir/order-$id.md"
    tmp="$file.tmp.$$"
    {
      printf 'id: %s\n' "$id"
      printf 'type: %s\n' "$type"
      printf 'subject: %s\n' "$subject"
      printf 'status: active\n'
      printf 'scope: %s\n' "$scope"
      printf 'source: %s\n' "$source"
      printf 'recorded: %s\n' "$(utc_now)"
      printf 'due: %s\n' "$due"
      printf 'expires: %s\n' "$expires"
      printf 'task: %s\n' "$task"
      for entry in "${enforce_entries[@]+"${enforce_entries[@]}"}"; do
        printf 'enforce: %s\n' "$entry"
      done
      printf '\n## wording (verbatim, original language)\n%s\n' "$quote"
      printf '\n## translation (EN, marked)\n%s\n' "${translation:-(none)}"
    } > "$tmp"
    mv -f "$tmp" "$file"
    echo "recorded: $id ($type, $subject) -> $file"
    if [ "$task" != "-" ]; then
      hold_args=(hold "$task" --reason "order $id: $subject" --kind captain)
      [ "$due" != "-" ] && hold_args+=(--until "$due")
      if ! tasks-axi "${hold_args[@]}"; then
        echo "error: order $id is recorded, but holding task '$task' FAILED - hold it yourself: tasks-axi ${hold_args[*]}" >&2
        exit 5
      fi
      echo "held: task $task for $id"
    fi
    ;;
  list)
    shift || true
    show_all="no"
    [ "${1:-}" = "--all" ] && show_all="yes"
    found="no"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      status="$(field "$f" status)"
      expires="$(field "$f" expires)"
      state="$status"
      if [ "$status" = "active" ] && is_expired "$expires"; then state="expired"; fi
      if [ "$show_all" = "no" ] && [ "$state" != "active" ]; then continue; fi
      found="yes"
      printf '%s  %-11s %-8s %-30s due=%s expires=%s\n' \
        "$(field "$f" id)" "$(field "$f" type)" "$state" "$(field "$f" subject)" \
        "$(field "$f" due)" "$expires"
    done < <(order_files)
    [ "$found" = "yes" ] || echo "(no matching orders)"
    ;;
  show)
    shift
    [ -n "${1:-}" ] || die "show requires an order id"
    f="$(find_by_id "$1")"
    [ -n "$f" ] || die "no order '$1'"
    cat "$f"
    enforce_lines="$(fm_order_gate_enforce_lines "$f")"
    if [ -n "$enforce_lines" ]; then
      echo
      echo "## enforce (INTERPRETATION, marked - the wording above is the source)"
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        printf '  enforce: %s\n' "$entry"
        printf '    %s' "$(fm_order_gate_deutung "$entry")"
        echo
      done <<< "$enforce_lines"
    fi
    ;;
  pin)
    body=""
    ids=""
    while IFS=$'\t' read -r id f; do
      [ -n "$id" ] || continue
      ids="${ids:+$ids }$id"
      body+="$id $(field "$f" type) $(field "$f" subject) scope=$(field "$f" scope) due=$(field "$f" due) expires=$(field "$f" expires)"$'\n'
      body+="  > $(wording_first_line "$f")"$'\n'
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        body+="  enforce: $entry"$'\n'
        body+="    $(fm_order_gate_deutung "$entry")"$'\n'
      done < <(fm_order_gate_enforce_lines "$f")
    done < <(active_rows)
    count="$(printf '%s' "$ids" | wc -w | tr -d ' ')"
    sha="$(printf '%s' "$body" | sha256sum | cut -c1-12)"
    echo "=== ORDER PIN v1 - active captain orders; do not compress; recite after any restart ==="
    printf '%s' "$body"
    echo "--- count=$count sha=$sha"
    if [ "$count" -gt 0 ]; then
      echo "=== END ORDER PIN - verify with: bin/fm-order.sh recite $ids ==="
    else
      echo "=== END ORDER PIN - no active orders; verify with: bin/fm-order.sh recite ==="
    fi
    ;;
  recite)
    shift
    expected="$(active_rows | cut -f1 | sort -u)"
    given="$(printf '%s\n' "$@" | sed '/^$/d' | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "$expected" | sed '/^$/d') <(printf '%s\n' "$given"))"
    unexpected="$(comm -13 <(printf '%s\n' "$expected" | sed '/^$/d') <(printf '%s\n' "$given"))"
    if [ -z "$missing" ] && [ -z "$unexpected" ]; then
      n="$(printf '%s\n' "$expected" | sed '/^$/d' | wc -l | tr -d ' ')"
      echo "recitation OK: $n active order(s) confirmed"
      exit 0
    fi
    echo "recitation FAILED - re-read the order book before acting:" >&2
    [ -n "$missing" ] && echo "  missing from recitation: $(echo "$missing" | tr '\n' ' ')" >&2
    [ -n "$unexpected" ] && echo "  recited but not active: $(echo "$unexpected" | tr '\n' ' ')" >&2
    exit 1
    ;;
  close)
    shift
    [ -n "${1:-}" ] || die "close requires an order id"
    id="$1"; shift
    reason="" captain_wording="-"
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason) reason="${2:-}"; shift 2 ;;
        --captain-wording) captain_wording="${2:-}"; shift 2 ;;
        *) die "unknown argument '$1' for close" ;;
      esac
    done
    [ -n "${reason//[[:space:]]/}" ] || die "close requires --reason"
    f="$(find_by_id "$id")"
    [ -n "$f" ] || die "no order '$id'"
    [ "$(field "$f" status)" = "active" ] || die "order $id is already closed"
    type="$(field "$f" type)"
    if { [ "$type" = "decision" ] || [ "$type" = "prohibition" ]; } \
       && [ -z "${captain_wording//[[:space:]-]/}" ]; then
      die "closing a $type needs --captain-wording with the captain's verbatim words (hardening 8)"
    fi
    tmp="$f.tmp.$$"
    awk '!done && $0=="status: active" {print "status: closed"; done=1; next} {print}' "$f" > "$tmp"
    {
      printf '\n## closed\nclosed: %s\nreason: %s\ncaptain-wording: %s\n' \
        "$(utc_now)" "$reason" "$captain_wording"
    } >> "$tmp"
    mv -f "$tmp" "$f"
    echo "closed: $id ($reason)"
    ;;
  check-subject)
    shift
    [ -n "${1:-}" ] || die "check-subject requires a subject"
    subj="$1"; shift
    new_fact=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --new-fact) new_fact="${2:-}"; shift 2 ;;
        *) die "unknown argument '$1' for check-subject" ;;
      esac
    done
    blocking=""
    informational=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$(field "$f" subject)" = "$subj" ] || continue
      type="$(field "$f" type)"
      line="$(field "$f" id) $type $(field "$f" status)"
      case "$type" in
        decision|prohibition) blocking="${blocking:+$blocking; }$line" ;;
        *) informational="${informational:+$informational; }$line" ;;
      esac
    done < <(order_files)
    if [ -n "$blocking" ]; then
      if [ -n "${new_fact//[[:space:]]/}" ]; then
        echo "subject '$subj' carries a captain call ($blocking) - resubmission allowed with the named new fact: $new_fact"
        exit 0
      fi
      echo "BLOCKED: subject '$subj' already carries a captain call ($blocking); resubmit only with --new-fact '<what changed>' (L71)" >&2
      exit 3
    fi
    [ -n "$informational" ] && echo "note: subject '$subj' has related orders: $informational"
    echo "subject '$subj' is free for submission"
    ;;
  gate-check)
    shift
    [ -n "${1:-}" ] || die "gate-check requires a gate; known gates: $FM_ORDER_GATE_GATES"
    gate="$1"; shift
    gate_ctx=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --ctx) gate_ctx+=("${2:-}"); shift 2 ;;
        *) die "unknown argument '$1' for gate-check (use --ctx key=value)" ;;
      esac
    done
    set +e
    gate_out="$(fm_order_gate_check "$gate" "${gate_ctx[@]+"${gate_ctx[@]}"}")"
    gate_rc=$?
    set -e
    if [ -n "$gate_out" ]; then printf '%s\n' "$gate_out"; fi
    case "$gate_rc" in
      0) echo "gate '$gate' is free for this context (no active order enforces against it)" ;;
      1) echo "gate '$gate' is BLOCKED by the order(s) above - quote the wording, name the exit, or have the captain close/amend the order" >&2 ;;
    esac
    exit "$gate_rc"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
