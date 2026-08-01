#!/usr/bin/env bash
# fm-model-verify.sh - verify the model a dispatched worker ACTUALLY ran on
# against the model firstmate RECORDED for it in state/<id>.meta.
#
# Why this exists: `model=` in state/<id>.meta is what firstmate REQUESTED at
# intake, sometimes after a deliberate quota-balanced choice. Nothing verified
# what ran. A worker silently served by a lower tier still reports done, and the
# record still reads as the intended model, so later quota-aware dispatch
# decisions built on that record are fiction. This helper closes that gap by
# comparing the record against runtime-written evidence the agent cannot forge.
#
# Placement rationale (why here and not elsewhere):
#   - NOT at spawn time: at spawn the worker has produced no turn, so there is
#     nothing to compare yet. Verification is necessarily after the fact.
#   - NOT in a PostToolUse guard: that surface sees `resolvedModel` for the
#     HARNESS'S OWN delegation tool, which a firstmate primary already denies
#     (docs/subagent-guard.md). It never observes a bin/fm-spawn.sh dispatch,
#     which is the record actually at risk here.
#   - NOT folded into bin/fm-crew-state.sh: that helper owns one contract,
#     reconciling a crew's CURRENT RUN STATE. Model provenance is orthogonal to
#     run state and belongs to its own owner.
#   Standalone read-only verifier, surfaced through bin/fm-fleet-snapshot.sh,
#   which firstmate already reviews every heartbeat.
#
# Evidence: the harness's own session transcript. The runtime writes it, the
# agent never authors it, and it records the model that served each assistant
# turn. Per-harness adapters below; only a harness with an empirically verified
# evidence source is ever treated as verifiable.
#
# Fails LOUDLY rather than reporting compliance. A verdict is never `match`
# unless a model was actually read and actually compared:
#
#   match        every model attributed to this worker matches the record.
#   mismatch     at least one attributed model does not.                 exit 3
#   unverifiable the record CANNOT be checked - no evidence adapter for the
#                harness, evidence unreadable, jq absent, or evidence that
#                cannot be attributed to this task.                      exit 4
#   pending      an adapter exists and the worker has simply not produced a
#                model-attributed turn yet. NOT a pass - no verdict yet.
#   unpinned     meta records `model=default`: firstmate pinned no tier, so
#                there is no dispatch record for the runtime to contradict.
#
# Output is one stable, parseable line per task:
#
#   <id> · verdict: <v> · recorded: <m> · actual: <a> · source: <s> · <detail>
#
# Read-only and side-effect free.
#
# Usage: fm-model-verify.sh <task-id> [--json]
#        fm-model-verify.sh --all [--json]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  cat <<'EOF'
usage: fm-model-verify.sh <task-id> [--json]
       fm-model-verify.sh --all [--json]

Verify the model a dispatched worker actually ran on against the model recorded
for it in state/<id>.meta.

Exit: 0 match/pending/unpinned · 3 mismatch · 4 unverifiable · 2 usage error.
With --all, the worst verdict across all tasks sets the exit code.
EOF
}

JSON=0
ALL=0
ID=

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1 ;;
    --all) ALL=1 ;;
    -*) usage >&2; exit 2 ;;
    *)
      [ -z "$ID" ] || { usage >&2; exit 2; }
      ID=$arg
      ;;
  esac
done

if [ "$ALL" -eq 1 ]; then
  [ -z "$ID" ] || { usage >&2; exit 2; }
elif [ -z "$ID" ]; then
  usage >&2
  exit 2
fi

# --- model-name comparison --------------------------------------------------
#
# Recorded values are whatever firstmate dispatched with: a bare family alias
# (`opus`), or a specific model id (`claude-opus-4-8`). Actual values come from
# the runtime verbatim and may carry a context-window suffix (`claude-opus-5[1m]`).
# Compare at the granularity the RECORD expresses: a bare alias promises only a
# family, so any member of that family matches; a specific id promises that id.

FAMILIES='opus sonnet haiku fable'

# normalize_model: lowercase, drop a trailing bracketed suffix such as `[1m]`.
normalize_model() {  # <raw>
  local v=$1
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  printf '%s' "${v%%\[*}"
}

# family_of: the family token contained in a normalized model name, or empty.
family_of() {  # <normalized>
  local name=$1 fam
  for fam in $FAMILIES; do
    case "$name" in
      *"$fam"*) printf '%s' "$fam"; return 0 ;;
    esac
  done
  return 0
}

# recorded_is_alias: true when the record names only a family, so it promises a
# tier rather than a specific model version.
recorded_is_alias() {  # <normalized-recorded>
  local fam
  for fam in $FAMILIES; do
    [ "$1" = "$fam" ] && return 0
  done
  return 1
}

# models_match: does <actual> satisfy what <recorded> promised?
models_match() {  # <normalized-recorded> <normalized-actual>
  local recorded=$1 actual=$2
  if recorded_is_alias "$recorded"; then
    [ "$(family_of "$actual")" = "$recorded" ] && return 0
    return 1
  fi
  # A specific id. Compare with an optional vendor prefix on either side, so a
  # record of `claude-opus-4-8` and `opus-4-8` both match the runtime's
  # `claude-opus-4-8` and neither matches `claude-opus-5`.
  [ "$actual" = "$recorded" ] && return 0
  [ "$actual" = "claude-$recorded" ] && return 0
  [ "claude-$actual" = "$recorded" ] && return 0
  return 1
}

# --- claude evidence adapter ------------------------------------------------
#
# Claude Code writes one JSONL transcript per session under
# <config>/projects/<encoded-cwd>/, and records the serving model on every
# assistant record as `.message.model`. The encoding replaces every character
# outside [A-Za-z0-9] with `-` (verified on this host against paths containing
# `/`, `.`, `_`, and a space).
#
# <config> is $CLAUDE_CONFIG_DIR when set, else ~/.claude. bin/fm-spawn.sh
# forwards firstmate's own CLAUDE_CONFIG_DIR onto a claude launch, so resolving
# it the same way here reads the same store the worker wrote to.
#
# `<synthetic>` is a runtime placeholder the CLI records for messages no model
# served (injected notices and the like). It names no model and is dropped, so
# it can neither manufacture a mismatch nor stand in as evidence of a match.

claude_config_dir() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# mtime_of: a file's modification time in epoch seconds, GNU stat then BSD stat.
mtime_of() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

claude_transcript_dir() {  # <worker-cwd>
  local cwd=$1 encoded
  encoded=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
  printf '%s/projects/%s' "$(claude_config_dir)" "$encoded"
}

# claude_models: distinct models recorded across this worker's transcripts, one
# per line. When the evidence cannot be read at all it emits a single
# `ERR:<reason>` line instead. The caller runs this in a command substitution,
# so a shell variable could not carry that failure back out - and a read failure
# that arrived as "no models" would be indistinguishable from a well-behaved
# worker, which is the silent pass this helper exists to prevent.
claude_models() {  # <transcript-dir> <spawned-at-epoch|empty>
  local dir=$1 anchor=$2 files=() f

  # No transcript directory at all means the runtime never wrote a session for
  # this working directory. For a dispatched worker that is a failure to LOCATE
  # the evidence, not evidence of a well-behaved worker, so it must not read as
  # the benign "not yet" case. A worker spawned seconds ago lands here briefly
  # and clears itself on its first turn.
  if [ ! -d "$dir" ]; then
    printf 'ERR:no transcript directory for the working directory recorded for this worker, so its evidence cannot be located: %s\n' "$dir"
    return 0
  fi
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    printf 'ERR:transcript directory is not readable: %s\n' "$dir"
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | sort)
  [ "${#files[@]}" -gt 0 ] || return 0

  # Time-bound the scan to this dispatch when the record allows it. A worktree
  # from a reusable pool can carry transcripts written by a previous occupant;
  # those are never appended to again, so their mtime precedes this spawn.
  if [ -n "$anchor" ]; then
    local kept=() mt
    for f in "${files[@]}"; do
      mt=$(mtime_of "$f") || mt=
      [ -n "$mt" ] || continue
      [ "$mt" -ge "$anchor" ] && kept+=("$f")
    done
    files=("${kept[@]:-}")
    [ -n "${files[0]:-}" ] || return 0
  fi

  # A transcript jq cannot parse is unread evidence, not an absent model, so the
  # read failure is reported rather than degraded into an empty result.
  local raw
  if ! raw=$(jq -r 'select(.type=="assistant") | .message.model // empty' "${files[@]}" 2>/dev/null); then
    printf 'ERR:transcript evidence could not be parsed under %s\n' "$dir"
    return 0
  fi
  printf '%s\n' "$raw" | grep -v '^<' | sort -u | sed '/^$/d'
}

# --- verdict ----------------------------------------------------------------

VERDICT=
RECORDED=
ACTUAL=
SOURCE=
DETAIL=

verify_one() {  # <id>
  local id=$1 meta cwd harness kind anchor models n
  VERDICT=; RECORDED=; ACTUAL=; SOURCE=none; DETAIL=

  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ]; then
    VERDICT=unverifiable
    DETAIL="no durable record at $meta"
    return
  fi

  RECORDED=$(fm_meta_get "$meta" model)
  harness=$(fm_meta_get "$meta" harness)
  kind=$(fm_meta_get "$meta" kind)
  anchor=$(fm_meta_get "$meta" spawned_at)
  case "$anchor" in ''|*[!0-9]*) anchor= ;; esac

  # A secondmate runs in its own home; every other worker runs in the isolated
  # worktree the backend opened its endpoint in. `project=` is the registered
  # clone, not where the worker actually runs, so it is only a last resort.
  if [ "$kind" = secondmate ]; then
    cwd=$(fm_meta_get "$meta" home)
  else
    cwd=$(fm_meta_get "$meta" worktree)
  fi
  [ -n "$cwd" ] || cwd=$(fm_meta_get "$meta" project)

  if [ -z "$RECORDED" ] || [ "$RECORDED" = default ]; then
    VERDICT=unpinned
    RECORDED=${RECORDED:-default}
    DETAIL="no model pinned at dispatch; nothing recorded for the runtime to contradict"
    return
  fi

  if [ "$harness" != claude ]; then
    VERDICT=unverifiable
    DETAIL="no verified model-evidence source for harness '${harness:-unrecorded}'"
    return
  fi
  SOURCE=claude-transcript

  if ! command -v jq >/dev/null 2>&1; then
    VERDICT=unverifiable
    DETAIL="jq is required to read transcript evidence and is not installed"
    return
  fi

  if [ -z "$cwd" ]; then
    VERDICT=unverifiable
    DETAIL="durable record names no working directory, so its evidence cannot be located"
    return
  fi

  local dir
  dir=$(claude_transcript_dir "$cwd")
  models=$(claude_models "$dir" "$anchor")
  case "$models" in
    ERR:*)
      VERDICT=unverifiable
      DETAIL=${models#ERR:}
      return
      ;;
  esac

  if [ -z "$models" ]; then
    VERDICT=pending
    DETAIL="worker has produced no model-attributed turn yet; no verdict"
    return
  fi

  ACTUAL=$(printf '%s' "$models" | paste -sd, -)
  n=$(printf '%s\n' "$models" | wc -l | tr -d ' ')

  # Without a spawn timestamp the scan could not be bounded to this dispatch. A
  # single consistent model is still attributable; disagreeing evidence is not,
  # and guessing which half belongs to this task would be exactly the silent
  # pass this helper exists to prevent.
  if [ -z "$anchor" ] && [ "$n" -gt 1 ]; then
    VERDICT=unverifiable
    DETAIL="record carries no dispatch timestamp and the evidence names $n models, which cannot be attributed to this task"
    return
  fi

  local norm_recorded norm_actual m bad=
  norm_recorded=$(normalize_model "$RECORDED")
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    norm_actual=$(normalize_model "$m")
    models_match "$norm_recorded" "$norm_actual" || bad="${bad:+$bad, }$m"
  done <<EOF
$models
EOF

  if [ -n "$bad" ]; then
    VERDICT=mismatch
    DETAIL="dispatched as '$RECORDED' but ran on $bad"
    return
  fi

  VERDICT=match
  DETAIL="ran on $ACTUAL, as dispatched"
  [ -z "$anchor" ] && DETAIL="$DETAIL (evidence not time-bounded: record predates dispatch timestamps)"
}

exit_for_verdict() {  # <verdict>
  case "$1" in
    mismatch) printf '3' ;;
    unverifiable) printf '4' ;;
    *) printf '0' ;;
  esac
}

emit_line() {  # <id>
  printf '%s · verdict: %s · recorded: %s · actual: %s · source: %s · %s\n' \
    "$1" "$VERDICT" "${RECORDED:--}" "${ACTUAL:--}" "$SOURCE" "$DETAIL"
}

emit_json() {  # <id>
  local actual_json='[]'
  if [ -n "$ACTUAL" ]; then
    actual_json=$(printf '%s' "$ACTUAL" | jq -R 'split(",")' 2>/dev/null) || actual_json='[]'
  fi
  jq -n \
    --arg id "$1" \
    --arg verdict "$VERDICT" \
    --arg recorded "${RECORDED:-}" \
    --arg source "$SOURCE" \
    --arg detail "$DETAIL" \
    --argjson actual "$actual_json" \
    '{id:$id,verdict:$verdict,recorded:($recorded|if .=="" then null else . end),
      actual:$actual,source:$source,detail:$detail}'
}

# JSON output needs jq itself. Without it there is no honest structured answer,
# so say so on stderr and refuse rather than printing something that parses.
if [ "$JSON" -eq 1 ] && ! command -v jq >/dev/null 2>&1; then
  echo "fm-model-verify: jq not found; --json cannot be produced" >&2
  exit 4
fi

worst=0
if [ "$ALL" -eq 1 ]; then
  ids=()
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    ids+=("$(basename "$meta" .meta)")
  done < <(find "$STATE" -maxdepth 1 -type f -name '*.meta' 2>/dev/null | sort)

  # Rendered in this shell rather than a pipeline subshell, so the worst verdict
  # survives to set the exit code without verifying anything twice.
  out=
  for id in "${ids[@]:-}"; do
    [ -n "$id" ] || continue
    verify_one "$id"
    if [ "$JSON" -eq 1 ]; then out="$out$(emit_json "$id")"$'\n'; else out="$out$(emit_line "$id")"$'\n'; fi
    code=$(exit_for_verdict "$VERDICT")
    [ "$code" -gt "$worst" ] && worst=$code
  done
  if [ "$JSON" -eq 1 ]; then
    printf '%s' "$out" | jq -s '.'
  else
    printf '%s' "$out"
  fi
  exit "$worst"
fi

verify_one "$ID"
if [ "$JSON" -eq 1 ]; then emit_json "$ID"; else emit_line "$ID"; fi
exit "$(exit_for_verdict "$VERDICT")"
