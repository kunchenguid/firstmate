#!/usr/bin/env bash
# Formal completeness gate for a task-lifecycle decision (AGENTS.md sections 2, 7).
#
# Derives the observed facts for a task (or takes them explicitly), then asks the
# Z3-backed engine (fm-completeness.py + fm-completeness.rules.json) to PROVE the
# completion claim consistent with firstmate's invariants. Hard rules gate; soft
# rules score. Prints a one-line verdict; on a blocked claim it names the violated
# rule and exits non-zero.
#
# Usage:
#   fm-completeness-check.sh --gate teardown --id <task-id>
#   fm-completeness-check.sh --gate merge    --id <task-id>   # approval via $FM_CAPTAIN_APPROVED
#   fm-completeness-check.sh --kind ship --landed none --worktree holds_unlanded_work [...]
#
# Flags (explicit facts override anything derived):
#   --gate <teardown|merge|done>   what decision this guards (drives fact derivation)
#   --id <task-id>                 derive facts from state/<id>.meta + data/<id>/ + git
#   --kind --landed --report --worktree --captain-approval <value>
#   --mode <strict|graded>         strict (default) gates on invariants; graded also scores soft rules
#   --meta <key>                   set a soft-rule metadata key true (repeatable)
#
# Exit: 0 = SAT (proceed), 2 = UNSAT (blocked), 64 = invalid facts/usage (a typo,
# not a pass - callers must treat it as blocking), 0 = tooling unavailable or
# broken (FAIL-OPEN, warns and defers to the caller's own checks) unless
# FM_COMPLETENESS_STRICT=1. Set FM_COMPLETENESS_GATE=0 to skip the gate entirely
# (still exits 0).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ENGINE="$SCRIPT_DIR/fm-completeness.py"

GATE=""
ID=""
MODE="strict"
KIND=""
LANDED=""
REPORT=""
WORKTREE=""
APPROVAL=""
META_KEYS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --gate) GATE="$2"; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --kind) KIND="$2"; shift 2 ;;
    --landed) LANDED="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --captain-approval) APPROVAL="$2"; shift 2 ;;
    --meta) META_KEYS+=("$2"); shift 2 ;;
    *) echo "fm-completeness-check: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

# Honor the global off-switch.
if [ "${FM_COMPLETENESS_GATE:-1}" = "0" ]; then
  exit 0
fi

fail_open() {
  # Tooling missing or broken: never wedge the lifecycle. Warn and defer to the
  # caller's own (bash) safety checks, unless the operator demands strictness.
  if [ "${FM_COMPLETENESS_STRICT:-0}" = "1" ]; then
    echo "completeness gate: $1 (FM_COMPLETENESS_STRICT=1 -> refusing)" >&2
    exit 3
  fi
  echo "completeness gate: $1; skipping formal check (set FM_COMPLETENESS_STRICT=1 to enforce)" >&2
  exit 0
}

command -v python3 >/dev/null 2>&1 || fail_open "python3 not found"
[ -f "$ENGINE" ] || fail_open "engine $ENGINE missing"

git_unlanded_facts() {
  # Mirror fm-teardown.sh's notion of "landed" so the gate never diverges from
  # the script it guards. Sets LANDED and WORKTREE for a ship task.
  local wt=$1 proj=$2 mode=$3 dirty unpushed default branch unmerged
  if [ ! -d "$wt" ]; then
    # No worktree on disk means there is nothing to discard, exactly as
    # fm-teardown.sh skips its unlanded check when [ ! -d "$WT" ]. Resolve to a
    # non-blocking state: clean worktree and a landed value that clears
    # SHIP_REQUIRES_LANDED, rather than landed=none which would false-block.
    if [ "$mode" = "local-only" ]; then
      LANDED="${LANDED:-local_merged}"
    else
      LANDED="${LANDED:-pushed}"
    fi
    WORKTREE="${WORKTREE:-clean}"
    return 0
  fi
  # Untracked-residue filter, byte-identical to the one in fm-teardown.sh's
  # validate_worktree_teardown_safety: firstmate-owned scratch (.claude/, the
  # grok/kimi turn-end pointers) is not the crewmate's work. Edit both or
  # neither, or this gate refuses a teardown its own guarded check would allow.
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)
  unpushed=$(git -C "$wt" log --oneline HEAD --not --remotes -- 2>/dev/null | head -1 || true)
  # Name the concrete evidence so a blocked claim's output cites it alongside
  # the violated rule (uncommitted changes are never landed).
  [ -z "$dirty" ] || echo "completeness gate: uncommitted changes present in $wt" >&2
  if [ "$mode" = "local-only" ]; then
    default=$(git -C "$proj" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    if [ -z "$default" ]; then
      for branch in main master; do
        if git -C "$proj" show-ref --verify --quiet "refs/heads/$branch"; then
          default=$branch
          break
        fi
      done
    fi
    if [ -n "$default" ]; then
      unmerged=$(git -C "$wt" log --oneline HEAD --not "$default" -- 2>/dev/null | head -1 || true)
    else
      # No determinable default branch: fm-merge-local.sh/fm-teardown.sh refuse
      # here, so the gate mirrors them by treating the work as unmerged.
      unmerged="no-default-branch"
    fi
    if [ -z "$unmerged" ]; then
      LANDED="${LANDED:-local_merged}"
    elif [ -z "$unpushed" ]; then
      LANDED="${LANDED:-pushed}"
    else
      LANDED="${LANDED:-none}"
    fi
    if [ -n "$dirty" ] || { [ -n "$unmerged" ] && [ -n "$unpushed" ]; }; then
      WORKTREE="${WORKTREE:-holds_unlanded_work}"
    else
      WORKTREE="${WORKTREE:-clean}"
    fi
  else
    # Unpushed commits alone are not provably unlanded for a remote-backed
    # task: fm-teardown.sh's work_is_landed recognizes squash-merged PRs and
    # content already present in the default branch (gh-backed), which git
    # alone cannot see here. Resolve to the non-blocking value and defer to
    # the guarded script's own landed checks; uncommitted changes still block.
    LANDED="${LANDED:-pushed}"
    if [ -n "$dirty" ]; then
      WORKTREE="${WORKTREE:-holds_unlanded_work}"
    else
      WORKTREE="${WORKTREE:-clean}"
    fi
  fi
}

# Derive facts from a task id when one is given (explicit flags still win).
if [ -n "$ID" ]; then
  META="$STATE/$ID.meta"
  if [ -f "$META" ]; then
    [ -n "$KIND" ] || KIND=$(grep '^kind=' "$META" | cut -d= -f2- || true)
    meta_mode=$(grep '^mode=' "$META" | cut -d= -f2- || true)
    wt=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
    proj=$(grep '^project=' "$META" | cut -d= -f2- || true)
  else
    meta_mode=""; wt=""; proj=""
  fi
  [ -n "$KIND" ] || KIND=ship
  [ -n "$meta_mode" ] || meta_mode=no-mistakes

  if [ -z "$REPORT" ]; then
    if [ -f "$DATA/$ID/report.md" ]; then REPORT=present; else REPORT=absent; fi
  fi

  case "$GATE" in
    merge)
      [ -n "$KIND" ] || KIND=ship
      LANDED="${LANDED:-merged}"
      WORKTREE="${WORKTREE:-clean}"
      ;;
    *)
      if [ "$KIND" = scout ]; then
        # Scout carve-out: the report governs, the worktree is scratch by contract.
        LANDED="${LANDED:-none}"; WORKTREE="${WORKTREE:-clean}"; APPROVAL="${APPROVAL:-not_required}"
      elif [ "$KIND" = ship ]; then
        git_unlanded_facts "$wt" "$proj" "$meta_mode"
        APPROVAL="${APPROVAL:-not_required}"
      else
        LANDED="${LANDED:-none}"; WORKTREE="${WORKTREE:-clean}"; APPROVAL="${APPROVAL:-not_required}"
      fi
      ;;
  esac
fi

# Approval at a merge gate is an explicit assertion the caller must make
# (directive #2): $FM_CAPTAIN_APPROVED in {granted,yes,1} -> granted;
# {not_required} -> not_required; anything else / unset -> pending (blocks).
if [ "$GATE" = "merge" ] && [ -z "$APPROVAL" ]; then
  case "${FM_CAPTAIN_APPROVED:-}" in
    granted|yes|1|true) APPROVAL=granted ;;
    not_required) APPROVAL=not_required ;;
    *) APPROVAL=pending ;;
  esac
fi

# Defaults for any axis still unset.
[ -n "$KIND" ] || KIND=ship
[ -n "$LANDED" ] || LANDED=none
[ -n "$REPORT" ] || REPORT=absent
[ -n "$WORKTREE" ] || WORKTREE=clean
[ -n "$APPROVAL" ] || APPROVAL=not_required

case "$ID" in *\"*|*\\*) echo "fm-completeness-check: refusing id with quote/backslash" >&2; exit 64 ;; esac

# Every interpolated axis value must be one the rules file declares. An
# undeclared value is a typo or corrupted meta, not a pass: refuse loudly
# (exit 64) instead of letting the engine's error fail open.
validate_axis() {
  local name=$1 value=$2 allowed=$3
  case " $allowed " in
    *" $value "*) ;;
    *) echo "fm-completeness-check: invalid $name '$value' (expected one of: $allowed)" >&2; exit 64 ;;
  esac
}
validate_axis --gate "${GATE:-teardown}" "teardown merge done"
validate_axis --mode "$MODE" "strict graded"
validate_axis --kind "$KIND" "ship scout secondmate"
validate_axis --landed "$LANDED" "merged pushed local_merged none"
validate_axis --report "$REPORT" "present absent"
validate_axis --worktree "$WORKTREE" "clean holds_unlanded_work"
validate_axis --captain-approval "$APPROVAL" "granted not_required pending"
for key in ${META_KEYS[@]+"${META_KEYS[@]}"}; do
  case "$key" in
    ''|*[!A-Za-z0-9_]*) echo "fm-completeness-check: invalid --meta key '$key' (expected [A-Za-z0-9_]+)" >&2; exit 64 ;;
  esac
done

# Build the metadata object from repeated --meta keys.
meta_json="{}"
if [ "${#META_KEYS[@]}" -gt 0 ]; then
  meta_json="{"
  sep=""
  for key in "${META_KEYS[@]}"; do
    meta_json="$meta_json$sep\"$key\": true"
    sep=", "
  done
  meta_json="$meta_json}"
fi

facts=$(printf '{"name": "%s", "mode": "%s", "kind": "%s", "landed": "%s", "report": "%s", "worktree": "%s", "captain_approval": "%s", "metadata": %s}' \
  "${ID:-task}" "$MODE" "$KIND" "$LANDED" "$REPORT" "$WORKTREE" "$APPROVAL" "$meta_json")

errfile=$(mktemp "${TMPDIR:-/tmp}/fm-completeness.XXXXXX")
set +e
out=$(printf '%s' "$facts" | python3 "$ENGINE" 2>"$errfile")
rc=$?
err=$(cat "$errfile" 2>/dev/null || true)
rm -f "$errfile"
set -e

label="${ID:-task}${GATE:+ ($GATE)}"
case "$rc" in
  0)
    if [ "$MODE" = "graded" ]; then
      compliance=$(printf '%s' "$out" | sed -n 's/.*"compliance": \([0-9.]*\).*/\1/p')
      echo "completeness gate: SAT - $label clears every invariant (compliance ${compliance:-1.0})"
    else
      echo "completeness gate: SAT - $label clears every invariant"
    fi
    exit 0
    ;;
  2)
    reason=$(printf '%s' "$out" | sed -n 's/.*"reason": "\(.*\)", "violated_rules.*/\1/p')
    violated=$(printf '%s' "$out" | sed -n 's/.*"violated_rules": \[\(.*\)\], "counterexample.*/\1/p')
    echo "completeness gate: BLOCKED - $label is provably premature" >&2
    [ -n "$violated" ] && echo "  violated: $violated" >&2
    [ -n "$reason" ] && echo "  reason: $reason" >&2
    [ -z "$reason" ] && echo "  $out" >&2
    exit 2
    ;;
  64)
    echo "completeness gate: INVALID FACTS for $label - ${err:-unknown}" >&2
    exit 64
    ;;
  3)
    fail_open "engine error: ${err:-unknown}"
    ;;
  *)
    fail_open "unexpected engine exit $rc: ${err:-unknown}"
    ;;
esac
