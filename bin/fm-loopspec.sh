#!/usr/bin/env bash
# fm-loopspec.sh - the single owner of firstmate's canonical LoopSpec
# representation: validation, deterministic selection, and persistent loop state.
#
# A LoopSpec answers one question and only that question: under what conditions
# is this done again, what may execute, how is progress verified, and when must
# it stop. It is not a ticket, a plan, a skill, an ExecutionUnit, a state machine
# or a decomposition node. A node that produces three children has decomposed;
# it has not looped.
#
# WHAT THIS SCRIPT IS NOT. It is not a loop runner. It never schedules, never
# polls, never spawns, never steers, never merges and never executes a skill.
# The intended path reuses what already exists:
#
#   existing detector -> durable wake -> deterministic LoopSpec selection ->
#   authorised skills -> verification -> persisted state -> terminal state or
#   bounded next iteration
#
# This script owns exactly three of those arrows: selection, persisted state,
# and the terminal-state bookkeeping that bounds the next iteration. The wake
# still comes from the existing watcher. The work still happens in a model turn.
#
# EVERYTHING REFUSES BY DEFAULT. Every subcommand that could lead to work prints
# one stable refusal token on stderr and exits 1 rather than proceeding under
# uncertainty. An unavailable verifier can never become a pass.
#
# Usage:
#   fm-loopspec.sh validate [<spec.json>...]   validate the registry, or these files
#   fm-loopspec.sh list                        id, version and status per spec
#   fm-loopspec.sh show <id>                   print one spec
#   fm-loopspec.sh triggers [--summary]        the sixteen-trigger register
#   fm-loopspec.sh select --trigger <id> [--scope <scope>]
#                                              choose exactly one eligible spec
#   fm-loopspec.sh claim <id> --event-key <k> --spec-version <n> [--headroom <pct>]
#                                              open or resume one iteration
#   fm-loopspec.sh finish <id> --event-key <k> --terminal <name>
#                       --verifier-result pass|fail|unavailable [--evidence <text>]...
#                       [--progress made|none]
#                                              drive the iteration to a terminal
#   fm-loopspec.sh state <id>                  print persisted loop state
#   fm-loopspec.sh --help                      print this usage
#
# Exit status: 0 proceed, 1 refused (one refusal token on stderr), 2 usage error.
#
# Refusal tokens are stable contract, because callers and tests key on them:
#   refuse_invalid_spec          the registry does not validate, so nothing may run
#   refuse_unknown_spec          no spec with that id
#   refuse_no_match              no spec matches the event
#   refuse_not_enabled           matched, but draft/specified/ready_not_active/disabled/retired
#   refuse_trigger_unimplemented the trigger has no verified execution path
#   refuse_ambiguous_tie         candidates remain tied after the deterministic key
#   refuse_authority_insufficient the spec's authority class needs the captain first
#   refuse_version_changed       the spec changed under a running iteration
#   refuse_evidence_missing      fewer evidence items than the verifier requires
#   refuse_verifier_unavailable  no verifier verdict, so no success terminal
#   refuse_verification_mismatch the verifier rejected a success terminal
#   refuse_capacity_unknown      capacity is bounded but was not supplied
#   refuse_capacity_stop         capacity is inside the stop band
#   refuse_budget_exceeded       an iteration budget is spent
#   refuse_no_progress           consecutive iterations produced no progress
#   refuse_duplicate_event       this event key was already handled
#   refuse_iteration_open        another event key already holds the open iteration
#   refuse_no_open_iteration     nothing to finish
#   refuse_unknown_terminal      the terminal is not declared by this spec
#   refuse_state_unreadable      persistent state exists but cannot be read truthfully
#   refuse_state_unwritable      persistent state cannot be written truthfully
#
# The schema, the trigger register and each spec are data, owned by loopspecs/.
# This script is their only interpreter; it never restates their content.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SPEC_DIR="${FM_LOOPSPEC_DIR:-$FM_ROOT/loopspecs}"
SKILL_DIRS=("$FM_ROOT/.agents/skills" "$FM_ROOT/skills")

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-loopspec.sh" | sed 's/^# \{0,1\}//; $d'
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

refuse() {
  # One stable token, then a human-readable reason on the same line. Callers that
  # invoke a refusing helper inside a command substitution must propagate the
  # status with `|| exit 1`, because an exit inside a subshell ends only that
  # subshell.
  printf '%s %s\n' "$1" "$2" >&2
  exit 1
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die_usage "jq is required"
}

schema_path() { printf '%s/schema.json' "$SPEC_DIR"; }
triggers_path() { printf '%s/triggers.json' "$SPEC_DIR"; }

# Every *.json under the registry except the two contract files.
spec_files() {
  local f base
  for f in "$SPEC_DIR"/*.json; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      schema.json|triggers.json) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

installed_skills_json() {
  local d entry
  local -a names=()
  for d in "${SKILL_DIRS[@]}"; do
    [ -d "$d" ] || continue
    for entry in "$d"/*/; do
      [ -d "$entry" ] || continue
      names+=("$(basename "$entry")")
    done
  done
  if [ "${#names[@]}" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${names[@]}" | jq -R -s 'split("\n") | map(select(length > 0))'
}

# Structural and invariant validation of one spec against schema.json.
# Prints one line per problem, nothing when sound, and returns non-zero if the
# validator itself could not run - an unrunnable validator is never a pass.
validate_structure() {
  local spec_file=$1 file_id=$2 skills_json=$3 out rc
  out=$(jq -r --slurpfile schema "$(schema_path)" \
              --slurpfile triggers "$(triggers_path)" \
              --arg file_id "$file_id" \
              --argjson skills "$skills_json" '
    # Identifiers are kebab-case; terminal-state names are snake_case tokens.
    # Keeping them distinct stops one vocabulary drifting into the other.
    def is_slug($v): (($v|type) == "string") and ($v|test("^[a-z0-9][a-z0-9-]*$"));
    def is_token($v): (($v|type) == "string") and ($v|test("^[a-z0-9][a-z0-9_]*$"));
    def typeok($v; $t; $enums):
      if $t == "string" then (($v|type) == "string") and (($v|length) > 0)
      elif $t == "slug" then is_slug($v)
      elif $t == "token" then is_token($v)
      elif $t == "token[]" then (($v|type) == "array") and (all($v[]?; is_token(.)))
      elif $t == "int" then (($v|type) == "number") and (($v|floor) == $v)
      elif $t == "nonneg_int" then (($v|type) == "number") and (($v|floor) == $v) and ($v >= 0)
      elif $t == "pos_int" then (($v|type) == "number") and (($v|floor) == $v) and ($v >= 1)
      elif $t == "bool" then (($v|type) == "boolean")
      elif $t == "object" then (($v|type) == "object")
      elif $t == "string[]" then (($v|type) == "array") and (all($v[]?; (type == "string") and (length > 0)))
      elif $t == "slug[]" then (($v|type) == "array") and (all($v[]?; is_slug(.)))
      elif $t == "object[]" then (($v|type) == "array") and (($v|length) > 0) and (all($v[]?; type == "object"))
      elif ($t|startswith("enum:")) then ((($enums[$t[5:]] // []) | index($v)) != null)
      else false
      end;
    # Only ever yields objects, so a mistyped branch can never crash the walk.
    def objects_at($spec; $p):
      if $p == "" then [$spec]
      elif ($p|endswith("[]")) then
        ((try ($spec | getpath($p[0:-2] | split("."))) catch null)) as $arr
        | if ($arr|type) == "array" then [$arr[] | select(type == "object")] else [] end
      else
        ((try ($spec | getpath($p | split("."))) catch null)) as $v
        | if ($v|type) == "object" then [$v] else [] end
      end;
    def fieldname($obj; $field): "\($obj)\(if $obj == "" then "" else "." end)\($field)";

    . as $spec
    | $schema[0] as $S
    | $triggers[0] as $T
    | ($S.enums) as $enums
    | ((try ($spec.trigger.id) catch null)) as $trigger_id
    | ((try ($spec.no_progress.terminal) catch null)) as $np_terminal
    | (((try ($spec.escalation.on) catch null)) // []) as $esc_on
    | (((try ($spec.authority.permitted_skills) catch null)) // []) as $need_skills
    | ((try ($spec.authority.class) catch null)) as $authority_class
    | (((try ($spec.terminal_states | map(select(type == "object") | .name)) catch null)) // []) as $declared
    | [
        ( $S.objects | to_entries[] as $obj
          | objects_at($spec; $obj.key)[] as $val
          | (($obj.value.required // {}) | keys) as $req
          | (($obj.value.optional // {}) | keys) as $opt
          | ($val | keys) as $have
          | (
              ( ($have - ($req + $opt))[] | "unknown field: \(fieldname($obj.key; .))" ),
              ( ($req - $have)[] | "missing required field: \(fieldname($obj.key; .))" ),
              ( (($obj.value.required // {}) + ($obj.value.optional // {})) | to_entries[] as $e
                | select(($val | has($e.key)) and ((typeok($val[$e.key]; $e.value; $enums)) | not))
                | "wrong type for \(fieldname($obj.key; $e.key)): expected \($e.value)" )
            )
        ),

        ( select($spec.loopspec_schema_version != $S.loopspec_schema_version)
          | "schema version \($spec.loopspec_schema_version) does not match the contract version \($S.loopspec_schema_version)" ),
        ( select($spec.id != $file_id)
          | "id \"\($spec.id)\" does not match its filename \"\($file_id)\"" ),
        ( select(($T.triggers | map(.id) | index($trigger_id)) == null)
          | "trigger \"\($trigger_id)\" is not in the trigger register" ),

        ( (($S.required_terminal_states - $declared)[]) | "missing required terminal state: \(.)" ),
        ( select(($np_terminal != null) and (($declared | index($np_terminal)) == null))
          | "no_progress.terminal \"\($np_terminal)\" is not a declared terminal state" ),
        ( (($esc_on - $declared)[]) | "escalation.on names an undeclared terminal state: \(.)" ),
        ( ($declared | group_by(.) | map(select(length > 1) | .[0]))[] | "duplicate terminal state: \(.)" ),

        ( select($spec.status == "enabled")
          | (
              ( ($T.triggers[] | select(.id == $trigger_id)) as $t
                | ( select((($t.execution_path_implemented) // false) | not)
                    | "status is enabled but trigger \"\($t.id)\" has no implemented execution path" ),
                  ( select((($t.verified) // false) | not)
                    | "status is enabled but trigger \"\($t.id)\" is not verified" ),
                  ( select((($t.enabled) // false) | not)
                    | "status is enabled but trigger \"\($t.id)\" is not enabled" )
              ),
              ( $need_skills[] as $sk | select(($skills | index($sk)) == null)
                | "status is enabled but permitted skill \"\($sk)\" is not installed" ),
              ( select($authority_class == "captain-required")
                | "status is enabled but authority class captain-required cannot self-enable" )
            )
        )
      ] | .[]
  ' "$spec_file")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'the validator could not run against this file\n'
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

# Registry-wide validation. Returns 0 only when every spec is sound.
validate_registry() {
  local -a files=()
  local f base file_id problems skills_json rc=0 count=0 dupes

  if [ "$#" -gt 0 ]; then
    files=("$@")
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      files+=("$f")
    done < <(spec_files)
  fi

  [ -f "$(schema_path)" ] || { printf 'refuse_invalid_spec registry schema is missing: %s\n' "$(schema_path)" >&2; return 1; }
  [ -f "$(triggers_path)" ] || { printf 'refuse_invalid_spec trigger register is missing: %s\n' "$(triggers_path)" >&2; return 1; }
  jq -e . "$(schema_path)" >/dev/null 2>&1 || { printf 'refuse_invalid_spec registry schema is not readable JSON\n' >&2; return 1; }
  jq -e . "$(triggers_path)" >/dev/null 2>&1 || { printf 'refuse_invalid_spec trigger register is not readable JSON\n' >&2; return 1; }

  skills_json=$(installed_skills_json)

  for f in "${files[@]}"; do
    [ -f "$f" ] || { printf 'refuse_invalid_spec %s: not a file\n' "$f" >&2; rc=1; continue; }
    base=$(basename "$f")
    file_id=${base%.json}
    if ! jq -e . "$f" >/dev/null 2>&1; then
      printf 'refuse_invalid_spec %s: not readable JSON\n' "$base" >&2
      rc=1
      continue
    fi
    problems=$(validate_structure "$f" "$file_id" "$skills_json") || rc=1
    if [ -n "$problems" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'refuse_invalid_spec %s: %s\n' "$base" "$line" >&2
      done <<<"$problems"
      rc=1
      continue
    fi
    count=$((count + 1))
  done

  # Ambiguity is a registry property, so it is checked across specs, not inside one.
  if [ "${#files[@]}" -gt 1 ]; then
    dupes=$(jq -sr '
      map(select(type == "object"))
      | map({k: "\(.trigger.id)/\(.selection.scope)/\(.selection.priority)", id: .id})
      | group_by(.k) | map(select(length > 1))
      | .[] | "\(.[0].k) claimed by \(map(.id) | join(", "))"
    ' "${files[@]}" 2>/dev/null)
    if [ -n "$dupes" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'refuse_invalid_spec ambiguous selection key: %s\n' "$line" >&2
      done <<<"$dupes"
      rc=1
    fi
  fi

  [ "$rc" -eq 0 ] && printf 'LOOPSPEC_VALIDATE ok specs=%s\n' "$count"
  return "$rc"
}

spec_path_for() {
  printf '%s/%s.json' "$SPEC_DIR" "$1"
}

state_path_for() {
  local id=$1 template=$2 rel
  rel=${template//<id>/$id}
  case "$rel" in
    state/*) printf '%s/%s' "$STATE" "${rel#state/}" ;;
    *) printf '%s/%s' "$STATE" "$(basename "$rel")" ;;
  esac
}

read_state() {
  # Prints the state object, or an empty object when no state exists yet.
  # Refuses when a state file exists but cannot be read truthfully. Callers use
  # `state=$(read_state ...) || exit 1` so the refusal is not lost in a subshell.
  local path=$1
  if [ ! -e "$path" ]; then
    printf '{}'
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] \
    || refuse refuse_state_unreadable "persistent state is not a readable regular file: $path"
  jq -e . "$path" >/dev/null 2>&1 \
    || refuse refuse_state_unreadable "persistent state is not readable JSON: $path"
  cat "$path"
}

write_state() {
  # Atomic replace, so a crash mid-write can never leave a half-truth on disk.
  local path=$1 payload=$2 dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || refuse refuse_state_unwritable "cannot create state directory: $dir"
  [ -w "$dir" ] || refuse refuse_state_unwritable "state directory is not writable: $dir"
  tmp=$(mktemp "$dir/.loopspec.XXXXXX" 2>/dev/null) \
    || refuse refuse_state_unwritable "cannot create a temporary state file in: $dir"
  printf '%s\n' "$payload" >"$tmp" 2>/dev/null \
    || { rm -f "$tmp"; refuse refuse_state_unwritable "cannot write state: $path"; }
  mv -f "$tmp" "$path" 2>/dev/null \
    || { rm -f "$tmp"; refuse refuse_state_unwritable "cannot replace state: $path"; }
}

# Eligibility to START an iteration, enforced wherever an iteration can begin.
# Selection is the ordinary route in, but claiming must gate independently:
# otherwise naming a spec directly would bypass the status and trigger checks and
# an inert spec could still run. Finishing deliberately does NOT gate on this, so
# an iteration already in flight can always be closed out truthfully even after
# its spec is disabled.
assert_runnable() {
  local spec=$1 id status trigger class
  id=$(printf '%s' "$spec" | jq -r '.id')
  status=$(printf '%s' "$spec" | jq -r '.status')
  trigger=$(printf '%s' "$spec" | jq -r '.trigger.id')
  class=$(printf '%s' "$spec" | jq -r '.authority.class')

  [ "$status" = "enabled" ] \
    || refuse refuse_not_enabled "spec \"$id\" is $status, so it may not start an iteration"
  jq -e --arg t "$trigger" '
    (.triggers[] | select(.id == $t))
    | (.execution_path_implemented and .verified and .enabled)
  ' "$(triggers_path)" >/dev/null 2>&1 \
    || refuse refuse_trigger_unimplemented "trigger \"$trigger\" has no verified, enabled execution path"
  [ "$class" != "captain-required" ] \
    || refuse refuse_authority_insufficient "spec \"$id\" needs the captain's word before an iteration may start"
}

# Load a spec by id after proving the whole registry validates. A registry that
# does not validate is not a registry anything may be selected from.
load_spec_or_refuse() {
  local id=$1 path
  path=$(spec_path_for "$id")
  [ -f "$path" ] || refuse refuse_unknown_spec "no spec with id \"$id\" in $SPEC_DIR"
  validate_registry >/dev/null || exit 1
  cat "$path"
}

cmd_validate() {
  need_jq
  validate_registry "$@"
}

cmd_list() {
  need_jq
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    jq -r '"\(.id)\tversion=\(.spec_version)\tstatus=\(.status)\ttrigger=\(.trigger.id)\tscope=\(.selection.scope)\tpriority=\(.selection.priority)"' "$f" 2>/dev/null \
      || printf '%s\tUNREADABLE\n' "$(basename "$f")"
  done < <(spec_files)
}

cmd_show() {
  need_jq
  [ "$#" -eq 1 ] || die_usage "show requires exactly one spec id"
  local path
  path=$(spec_path_for "$1")
  [ -f "$path" ] || refuse refuse_unknown_spec "no spec with id \"$1\" in $SPEC_DIR"
  cat "$path"
}

cmd_triggers() {
  need_jq
  local summary=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --summary) summary=1; shift ;;
      *) die_usage "unknown option for triggers: $1" ;;
    esac
  done
  [ -f "$(triggers_path)" ] || refuse refuse_invalid_spec "trigger register is missing"

  if [ "$summary" -eq 1 ]; then
    # Every count is computed here and stored nowhere, so no figure can rot.
    jq -r '
      .triggers as $t
      | "LOOPSPEC_TRIGGERS total=\($t|length)",
        "  specified=\([$t[]|select(.specified)]|length)",
        "  detector_implemented=\([$t[]|select(.detector_implemented)]|length)",
        "  deterministically_selectable=\([$t[]|select(.deterministically_selectable)]|length)",
        "  execution_path_implemented=\([$t[]|select(.execution_path_implemented)]|length)",
        "  verified=\([$t[]|select(.verified)]|length)",
        "  enabled=\([$t[]|select(.enabled)]|length)",
        "  ruled_never_deterministic=\([$t[]|select(.ruled_never_deterministic)]|length)",
        "  outside_the_sixteen=\(.outside_the_sixteen|length) (not counted in total)"
    ' "$(triggers_path)"
    return 0
  fi

  jq -r '
    .triggers[]
    | "\(.id)\tdetector=\(.detector_status)\tdeterministic=\(.deterministically_selectable)\texec_path=\(.execution_path_implemented)\tverified=\(.verified)\tenabled=\(.enabled)"
  ' "$(triggers_path)"
}

cmd_select() {
  need_jq
  local trigger="" scope=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger) [ "$#" -gt 1 ] || die_usage "--trigger requires a value"; trigger=$2; shift 2 ;;
      --scope) [ "$#" -gt 1 ] || die_usage "--scope requires a value"; scope=$2; shift 2 ;;
      *) die_usage "unknown option for select: $1" ;;
    esac
  done
  [ -n "$trigger" ] || die_usage "select requires --trigger <id>"

  validate_registry >/dev/null || exit 1

  local -a files=()
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    files+=("$f")
  done < <(spec_files)
  [ "${#files[@]}" -gt 0 ] || refuse refuse_no_match "the registry contains no specs"

  # Refuse an unregistered trigger before matching, so a typo can never read as
  # "there is no work to do".
  jq -e --arg t "$trigger" '(.triggers | map(.id) | index($t)) != null' "$(triggers_path)" >/dev/null 2>&1 \
    || refuse refuse_no_match "trigger \"$trigger\" is not in the register"

  local matched enabled winners lowest count
  matched=$(jq -sr --arg t "$trigger" --arg s "$scope" '
    map(select(.trigger.id == $t and ($s == "" or .selection.scope == $s)))
    | .[] | "\(.id)\t\(.spec_version)\t\(.status)\t\(.selection.priority)"
  ' "${files[@]}")
  [ -n "$matched" ] || refuse refuse_no_match "no spec declares trigger \"$trigger\"${scope:+ in scope \"$scope\"}"

  enabled=$(printf '%s\n' "$matched" | awk -F'\t' '$3 == "enabled"')
  if [ -z "$enabled" ]; then
    refuse refuse_not_enabled "matched specs for \"$trigger\", none enabled: $(printf '%s\n' "$matched" | awk -F'\t' '{printf "%s(%s) ", $1, $3}')"
  fi

  # Defence in depth: validation already refuses an enabled spec on an
  # unimplemented trigger, so reaching here means the register changed under us.
  jq -e --arg t "$trigger" '
    (.triggers[] | select(.id == $t))
    | (.execution_path_implemented and .verified and .enabled)
  ' "$(triggers_path)" >/dev/null 2>&1 \
    || refuse refuse_trigger_unimplemented "trigger \"$trigger\" has no verified, enabled execution path"

  # The deterministic selection key is (trigger, scope, priority); lowest wins.
  # A remaining tie is ambiguity, and ambiguity refuses rather than picking.
  lowest=$(printf '%s\n' "$enabled" | awk -F'\t' '{print $4}' | sort -n | head -1)
  winners=$(printf '%s\n' "$enabled" | awk -F'\t' -v p="$lowest" '$4 == p')
  count=$(printf '%s\n' "$winners" | wc -l | tr -d ' ')
  if [ "$count" -ne 1 ]; then
    refuse refuse_ambiguous_tie "priority $lowest is claimed by: $(printf '%s\n' "$winners" | awk -F'\t' '{printf "%s ", $1}')"
  fi

  printf 'LOOPSPEC_SELECT %s version=%s priority=%s\n' \
    "$(printf '%s' "$winners" | cut -f1)" \
    "$(printf '%s' "$winners" | cut -f2)" \
    "$lowest"
}

cmd_claim() {
  need_jq
  [ "$#" -ge 1 ] || die_usage "claim requires a spec id"
  local id=$1; shift
  local event_key="" want_version="" headroom=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --event-key) [ "$#" -gt 1 ] || die_usage "--event-key requires a value"; event_key=$2; shift 2 ;;
      --spec-version) [ "$#" -gt 1 ] || die_usage "--spec-version requires a value"; want_version=$2; shift 2 ;;
      --headroom) [ "$#" -gt 1 ] || die_usage "--headroom requires a value"; headroom=$2; shift 2 ;;
      *) die_usage "unknown option for claim: $1" ;;
    esac
  done
  [ -n "$event_key" ] || die_usage "claim requires --event-key <key>"
  [ -n "$want_version" ] || die_usage "claim requires --spec-version <n>"

  local spec disk_version path state state_version
  spec=$(load_spec_or_refuse "$id") || exit 1
  assert_runnable "$spec"
  disk_version=$(printf '%s' "$spec" | jq -r '.spec_version')
  [ "$disk_version" = "$want_version" ] \
    || refuse refuse_version_changed "spec \"$id\" is version $disk_version on disk, the iteration requested version $want_version"

  path=$(state_path_for "$id" "$(printf '%s' "$spec" | jq -r '.state.path_template')")
  state=$(read_state "$path") || exit 1

  # State that names a different version than the spec on disk means the spec
  # moved under a live iteration. Refuse; never silently re-base it.
  state_version=$(printf '%s' "$state" | jq -r '.spec_version // empty')
  if [ -n "$state_version" ] && [ "$state_version" != "$disk_version" ]; then
    refuse refuse_version_changed "persistent state holds version $state_version but the spec on disk is version $disk_version"
  fi

  local open open_key iteration no_progress last_key
  open=$(printf '%s' "$state" | jq -r '.open // false')
  open_key=$(printf '%s' "$state" | jq -r '.event_key // empty')
  iteration=$(printf '%s' "$state" | jq -r '.iteration // 0')
  no_progress=$(printf '%s' "$state" | jq -r '.consecutive_no_progress // 0')
  last_key=$(printf '%s' "$state" | jq -r '.last_event_key // empty')

  # Crash recovery: the same key still holding an open iteration resumes it, at
  # the same version and the same iteration number. Nothing is re-counted.
  if [ "$open" = "true" ] && [ "$open_key" = "$event_key" ]; then
    printf 'LOOPSPEC_CLAIM %s version=%s iteration=%s resumed=true\n' "$id" "$disk_version" "$iteration"
    return 0
  fi
  [ "$open" != "true" ] \
    || refuse refuse_iteration_open "iteration $iteration is open for event key \"$open_key\""

  # A repeated wake for an already-finished key does no work and mutates nothing.
  [ "$last_key" != "$event_key" ] \
    || refuse refuse_duplicate_event "event key \"$event_key\" was already handled at iteration $iteration"

  # No-progress terminates the loop. The terminal is reached and recorded, not
  # merely reported, so the loop cannot be restarted into the same dead end.
  local np_max np_terminal
  np_max=$(printf '%s' "$spec" | jq -r '.no_progress.max_iterations_without_progress')
  np_terminal=$(printf '%s' "$spec" | jq -r '.no_progress.terminal')
  if [ "$no_progress" -ge "$np_max" ]; then
    write_state "$path" "$(printf '%s' "$state" | jq --arg t "$np_terminal" \
      '.open = false | .event_key = null | .last_terminal = $t | .terminal_kind = "failure"')"
    refuse refuse_no_progress "$no_progress consecutive iterations without progress reached terminal \"$np_terminal\""
  fi

  local max_iterations
  max_iterations=$(printf '%s' "$spec" | jq -r '.budgets.max_iterations')
  [ "$((iteration + 1))" -le "$max_iterations" ] \
    || refuse refuse_budget_exceeded "iteration budget $max_iterations is spent"

  # Capacity bounds STARTING an iteration only. Verifying work already in flight
  # is never blocked here, and unknown capacity is never treated as headroom.
  local stop_band
  stop_band=$(printf '%s' "$spec" | jq -r '.budgets.capacity_stop_band_percent')
  if [ "$stop_band" -gt 0 ]; then
    [ -n "$headroom" ] \
      || refuse refuse_capacity_unknown "spec bounds capacity at ${stop_band}% but --headroom was not supplied"
    case "$headroom" in
      ''|*[!0-9]*) die_usage "--headroom must be a whole percentage" ;;
    esac
    [ "$headroom" -ge "$stop_band" ] \
      || refuse refuse_capacity_stop "headroom ${headroom}% is inside the ${stop_band}% stop band"
  fi

  iteration=$((iteration + 1))
  write_state "$path" "$(printf '%s' "$state" | jq \
    --arg id "$id" --arg key "$event_key" --arg status "$(printf '%s' "$spec" | jq -r .status)" \
    --argjson version "$disk_version" --argjson iter "$iteration" \
    '.spec_id = $id | .spec_version = $version | .status = $status
     | .iteration = $iter | .event_key = $key | .open = true
     | .consecutive_no_progress = (.consecutive_no_progress // 0)')"
  printf 'LOOPSPEC_CLAIM %s version=%s iteration=%s resumed=false\n' "$id" "$disk_version" "$iteration"
}

cmd_finish() {
  need_jq
  [ "$#" -ge 1 ] || die_usage "finish requires a spec id"
  local id=$1; shift
  local event_key="" terminal="" verifier="" progress="made"
  local -a evidence=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --event-key) [ "$#" -gt 1 ] || die_usage "--event-key requires a value"; event_key=$2; shift 2 ;;
      --terminal) [ "$#" -gt 1 ] || die_usage "--terminal requires a value"; terminal=$2; shift 2 ;;
      --verifier-result) [ "$#" -gt 1 ] || die_usage "--verifier-result requires a value"; verifier=$2; shift 2 ;;
      --evidence) [ "$#" -gt 1 ] || die_usage "--evidence requires a value"; evidence+=("$2"); shift 2 ;;
      --progress) [ "$#" -gt 1 ] || die_usage "--progress requires a value"; progress=$2; shift 2 ;;
      *) die_usage "unknown option for finish: $1" ;;
    esac
  done
  [ -n "$event_key" ] || die_usage "finish requires --event-key <key>"
  [ -n "$terminal" ] || die_usage "finish requires --terminal <name>"
  [ -n "$verifier" ] || die_usage "finish requires --verifier-result pass|fail|unavailable"
  case "$verifier" in pass|fail|unavailable) ;; *) die_usage "--verifier-result must be pass, fail or unavailable" ;; esac
  case "$progress" in made|none) ;; *) die_usage "--progress must be made or none" ;; esac

  local spec path state kind open_key
  spec=$(load_spec_or_refuse "$id") || exit 1
  path=$(state_path_for "$id" "$(printf '%s' "$spec" | jq -r '.state.path_template')")
  state=$(read_state "$path") || exit 1

  [ "$(printf '%s' "$state" | jq -r '.open // false')" = "true" ] \
    || refuse refuse_no_open_iteration "no open iteration for spec \"$id\""
  open_key=$(printf '%s' "$state" | jq -r '.event_key // empty')
  [ "$open_key" = "$event_key" ] \
    || refuse refuse_no_open_iteration "the open iteration belongs to event key \"$open_key\""

  kind=$(printf '%s' "$spec" | jq -r --arg t "$terminal" '.terminal_states[] | select(.name == $t) | .kind')
  [ -n "$kind" ] || refuse refuse_unknown_terminal "\"$terminal\" is not a terminal state declared by spec \"$id\""

  # An unavailable verifier can never become a pass. Neither can a rejecting one.
  if [ "$kind" = "success" ]; then
    [ "$verifier" != "unavailable" ] \
      || refuse refuse_verifier_unavailable "terminal \"$terminal\" is a success state and the verifier was unavailable"
    [ "$verifier" = "pass" ] \
      || refuse refuse_verification_mismatch "terminal \"$terminal\" is a success state and the verifier returned \"$verifier\""
    local required have
    required=$(printf '%s' "$spec" | jq -r '.verification.required_evidence | length')
    have=${#evidence[@]}
    [ "$have" -ge "$required" ] \
      || refuse refuse_evidence_missing "terminal \"$terminal\" requires $required evidence items, $have supplied"
  fi

  local next_no_progress
  if [ "$progress" = "made" ]; then
    next_no_progress=0
  else
    next_no_progress=$(( $(printf '%s' "$state" | jq -r '.consecutive_no_progress // 0') + 1 ))
  fi

  write_state "$path" "$(printf '%s' "$state" | jq \
    --arg t "$terminal" --arg k "$kind" --arg key "$event_key" --arg v "$verifier" \
    --argjson np "$next_no_progress" --argjson ev "${#evidence[@]}" \
    '.open = false | .last_terminal = $t | .terminal_kind = $k
     | .last_event_key = $key | .event_key = null
     | .verifier_result = $v | .evidence_count = $ev
     | .consecutive_no_progress = $np')"
  printf 'LOOPSPEC_FINISH %s terminal=%s kind=%s verifier=%s\n' "$id" "$terminal" "$kind" "$verifier"
}

cmd_state() {
  need_jq
  [ "$#" -eq 1 ] || die_usage "state requires exactly one spec id"
  local id=$1 spec path state
  spec=$(load_spec_or_refuse "$id") || exit 1
  path=$(state_path_for "$id" "$(printf '%s' "$spec" | jq -r '.state.path_template')")
  state=$(read_state "$path") || exit 1
  printf '%s\n' "$state"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  validate) cmd_validate "$@" ;;
  list) cmd_list "$@" ;;
  show) cmd_show "$@" ;;
  triggers) cmd_triggers "$@" ;;
  select) cmd_select "$@" ;;
  claim) cmd_claim "$@" ;;
  finish) cmd_finish "$@" ;;
  state) cmd_state "$@" ;;
  -h|--help|help) usage ;;
  *) die_usage "unknown command: $COMMAND" ;;
esac
