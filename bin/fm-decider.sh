#!/usr/bin/env bash
# fm-decider.sh - the standing lane that empties the captain-hold queue.
#
# The problem this exists for: a hold is written and then sits until a human
# happens to read it. Nothing walks the queue. This lane walks it, on a timer,
# and enforces one invariant:
#
#   at any moment every held item is either (a) at the one-act boundary waiting
#   on the captain, or (b) owned by a live worker.
#
# There is no third state. A held item with no worker and no one-act boundary is
# a defect this lane fixes on sight.
#
# The governing order is "nothing should be held up without workers". A hold is
# legitimate only when the work is DONE and the single remaining act is the
# captain's - a click, a send, a spend, a signature. If work remains, the item is
# not held, it is stalled, and a worker is dispatched to finish it.
#
# The semantic policy for what counts as a captain call is owned once by
# .agents/skills/captain-hold-lifecycle/SKILL.md. This script does not re-derive
# it; it applies the two-axis test the lane is built on:
#
#   readiness  ready | work | unknown   (is the deliverable finished?)
#   class      A | B                    (is the remaining act the captain's alone?)
#
# Class B is the closed list: new spend or a vendor contract; logins or
# credentials only the captain holds; legal signatures or sends under his name;
# irreversible customer-data destruction; a security change judged risky.
# Everything else is Class A, which this lane rules and executes.
#
# Usage:
#   fm-decider.sh scan [--json|--summary] [--class A|B] [--readiness R] [--ids]
#   fm-decider.sh digest [--cap N] [--out PATH]
#   fm-decider.sh record <id> <ruling> <reason> <evidence> <revert>
#   fm-decider.sh rulings
#   fm-decider.sh plan
#   fm-decider.sh apply [--yes]
#   fm-decider.sh status
#   fm-decider.sh arm
#
# `scan` runs the deterministic classifier (bin/fm-hold-scan.py) and, unless a
# filter is given, also refreshes the durable snapshot at
# data/decider/holds.jsonl. It costs no model tokens.
#
# `digest` renders the one captain-facing surface (bin/fm-hold-digest.py) from
# that snapshot plus the ruling ledger, and writes it to
# data/decider/digest-<YYYY-MM-DD>.md unless --out says otherwise.
#
# `record` appends one ruling line to data/decider/rulings.md:
#
#   <id> | <ruling> | <reason> | <evidence> | <revert>
#
# The ledger is append-only and is the authoritative record of what the lane
# decided. A ruling is reversible by the captain for 24 h; silence is consent.
# Every ruling must carry its revert, so `record` refuses an empty one.
#
# `plan` prints what `apply` would do and changes nothing. `apply` performs it:
# it lifts the hold on every Class A row that already has a ledger ruling, and
# prints - never runs - the dispatch line for every row whose readiness is
# `work`, because dispatching a worker is the chair's authority, not this
# lane's. `apply` refuses to lift a Class A hold with no ruling, and never
# touches a Class B row.
#
# `status` prints one line: held, class A, class B, ready, work, unknown, and
# how many Class A rows are still awaiting a ruling.
#
# `arm` installs the hourly scan-and-rule check as a registered custom check so
# the lane runs without a human remembering it. It prints the exact commands
# rather than mutating state, because arming a check is a chair action.
#
# Guardrails this script enforces mechanically:
#   - never lift a Class B hold, and never lift a Class A hold with no ruling;
#   - never dispatch anything itself, only print the dispatch line;
#   - never send a legal letter or formal response to any outside party, and
#     never re-queue an item whose only remaining act is a legal send;
#   - never widen its own authority: a new Class B pattern is a reviewed diff
#     to CLASS_B_RULES in bin/fm-hold-scan.py, not a runtime decision;
#   - if the scan finds zero Class A items it says so and exits, and does not
#     invent work.
#
# The backlog is read and mutated through the active home's data directory the
# way bin/fm-captain-hold.sh does, so main-home and secondmate-home ownership
# stay aligned with the work that discovered the call.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DECIDER="$DATA/decider"
LEDGER="$DECIDER/rulings.md"
SNAPSHOT="$DECIDER/holds.jsonl"
SCAN="$SCRIPT_DIR/fm-hold-scan.py"
DIGEST="$SCRIPT_DIR/fm-hold-digest.py"

die() { printf 'fm-decider: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

ensure_decider_dir() { mkdir -p "$DECIDER"; }

# The ledger is the authoritative ruling record, so a ruling is only "made" when
# its line is present. Matching is on the exact id field, never a substring.
has_ruling() {  # <id>
  [ -f "$LEDGER" ] || return 1
  awk -F'|' -v want="$1" '
    /^[[:space:]]*#/ { next }
    NF < 2 { next }
    { id = $1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id); if (id == want) { found = 1; exit } }
    END { exit(found ? 0 : 1) }
  ' "$LEDGER"
}

cmd_scan() {
  [ -f "$SCAN" ] || die "missing $SCAN"
  local filtered=0
  for arg in "$@"; do
    case "$arg" in
      --class|--readiness) filtered=1 ;;
    esac
  done
  if [ "$filtered" -eq 0 ] && [ "${1:-}" != "--summary" ] && [ "${1:-}" != "--ids" ]; then
    ensure_decider_dir
    python3 "$SCAN" "$@" > "$SNAPSHOT.tmp"
    mv "$SNAPSHOT.tmp" "$SNAPSHOT"
    cat "$SNAPSHOT"
    return 0
  fi
  python3 "$SCAN" "$@"
}

cmd_digest() {
  local cap=15 out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cap) cap=${2:?--cap needs a value}; shift 2 ;;
      --out) out=${2:?--out needs a value}; shift 2 ;;
      *) die "digest: unknown argument $1" ;;
    esac
  done
  [ -f "$DIGEST" ] || die "missing $DIGEST"
  if [ ! -f "$SNAPSHOT" ]; then
    ensure_decider_dir
    python3 "$SCAN" > "$SNAPSHOT"
  fi
  if [ -z "$out" ]; then
    ensure_decider_dir
    out="$DECIDER/digest-$(date -u +%Y-%m-%d).md"
  fi
  python3 "$DIGEST" --scan "$SNAPSHOT" --rulings "$LEDGER" --cap "$cap" --out "$out"
  printf '%s\n' "$out"
}

cmd_record() {
  [ $# -eq 5 ] || die "record: expected <id> <ruling> <reason> <evidence> <revert>"
  local id=$1 ruling=$2 reason=$3 evidence=$4 revert=$5
  [ -n "$id" ] || die "record: empty id"
  [ -n "$ruling" ] || die "record: empty ruling"
  [ -n "$revert" ] || die "record: every ruling must carry its revert"
  case "$id$ruling$reason$evidence$revert" in
    *'|'*) die "record: fields may not contain a pipe" ;;
  esac
  ensure_decider_dir
  if [ ! -f "$LEDGER" ]; then
    {
      printf '# Rulings made by the decider lane. Append-only.\n'
      printf '# <id> | <ruling> | <reason> | <evidence> | <revert>\n'
      printf '# A ruling is reversible by the captain for 24 h; silence is consent.\n'
    } > "$LEDGER"
  fi
  if has_ruling "$id"; then
    die "record: $id already has a ruling; the ledger is append-only"
  fi
  printf '%s | %s | %s | %s | %s\n' "$id" "$ruling" "$reason" "$evidence" "$revert" >> "$LEDGER"
  printf 'ruled: %s -> %s\n' "$id" "$ruling"
}

cmd_rulings() {
  [ -f "$LEDGER" ] || { printf 'no rulings yet\n'; return 0; }
  grep -v '^[[:space:]]*#' "$LEDGER" | grep -v '^[[:space:]]*$' || printf 'no rulings yet\n'
}

# plan and apply share one walk so the preview can never drift from the action.
walk() {  # <apply|plan>
  local mode=$1
  [ -f "$SCAN" ] || die "missing $SCAN"
  local rows
  rows=$(python3 "$SCAN")
  local total a b ready work unknown awaiting=0 lifted=0 dispatched=0
  total=$(printf '%s\n' "$rows" | grep -c . || true)
  a=$(printf '%s\n' "$rows" | python3 -c 'import sys,json;print(sum(1 for l in sys.stdin if l.strip() and json.loads(l)["class"]=="A"))')
  b=$((total - a))
  ready=$(printf '%s\n' "$rows" | python3 -c 'import sys,json;print(sum(1 for l in sys.stdin if l.strip() and json.loads(l)["readiness"]=="ready"))')
  work=$(printf '%s\n' "$rows" | python3 -c 'import sys,json;print(sum(1 for l in sys.stdin if l.strip() and json.loads(l)["readiness"]=="work"))')
  unknown=$(printf '%s\n' "$rows" | python3 -c 'import sys,json;print(sum(1 for l in sys.stdin if l.strip() and json.loads(l)["readiness"]=="unknown"))')

  printf 'held=%s class_a=%s class_b=%s ready=%s work=%s unknown=%s\n' \
    "$total" "$a" "$b" "$ready" "$work" "$unknown"

  if [ "$a" -eq 0 ]; then
    printf 'class_a=0: nothing for the lane to rule; exiting without inventing work\n'
    return 0
  fi

  local id klass readiness
  while IFS=$'\t' read -r id klass readiness; do
    [ -n "$id" ] || continue
    if [ "$klass" = "A" ]; then
      if has_ruling "$id"; then
        if [ "$mode" = "apply" ]; then
          if tasks-axi unhold "$id" >/dev/null 2>&1; then
            printf 'lifted: %s (ruled)\n' "$id"
            lifted=$((lifted + 1))
          else
            printf 'lift-failed: %s\n' "$id" >&2
          fi
        else
          printf 'would-lift: %s (ruled)\n' "$id"
        fi
      else
        printf 'awaiting-ruling: %s\n' "$id"
        awaiting=$((awaiting + 1))
      fi
    fi
    if [ "$readiness" = "work" ]; then
      printf 'dispatch: %s (work outstanding; chair dispatches a worker)\n' "$id"
      dispatched=$((dispatched + 1))
    fi
  done <<EOF
$(printf '%s\n' "$rows" | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    print("\t".join([row["id"], row["class"], row["readiness"]]))
')
EOF

  printf 'awaiting_ruling=%s lifted=%s dispatch_needed=%s\n' \
    "$awaiting" "$lifted" "$dispatched"
}

cmd_plan() { walk plan; }

cmd_apply() {
  local yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) die "apply: unknown argument $1" ;;
    esac
  done
  if [ "$yes" -eq 0 ]; then
    printf 'apply: dry run; pass --yes to lift ruled Class A holds\n'
    walk plan
    return 0
  fi
  walk apply
}

cmd_status() {
  [ -f "$SCAN" ] || die "missing $SCAN"
  local rows
  rows=$(python3 "$SCAN")
  printf '%s\n' "$rows" | python3 -c '
import sys, json
rows = [json.loads(l) for l in sys.stdin if l.strip()]
a = [r for r in rows if r["class"] == "A"]
b = [r for r in rows if r["class"] == "B"]
def count(rs, key, val):
    return sum(1 for r in rs if r[key] == val)
print(
    "held=%d class_a=%d class_b=%d ready=%d work=%d unknown=%d"
    % (
        len(rows), len(a), len(b),
        count(rows, "readiness", "ready"),
        count(rows, "readiness", "work"),
        count(rows, "readiness", "unknown"),
    )
)
'
  local awaiting=0 id
  while read -r id; do
    [ -n "$id" ] || continue
    has_ruling "$id" || awaiting=$((awaiting + 1))
  done <<EOF
$(printf '%s\n' "$rows" | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row["class"] == "A":
        print(row["id"])
')
EOF
  printf 'class_a_awaiting_ruling=%s\n' "$awaiting"
}

cmd_arm() {
  cat <<'EOF'
# Arming the lane is a chair action. Run these from the home that holds the lock:
#
#   install -m 0700 bin/fm-decider-check.sh state/decider.check.sh
#   bin/fm-check-register.sh decider
#
# The check prints one line only when the lane has work it can do without the
# captain: a Class A hold with no ruling, or a hold whose readiness is `work`.
# It prints nothing when the queue is already at the one-act boundary.
EOF
}

main() {
  local sub=${1:-}
  [ -n "$sub" ] || { usage; exit 1; }
  shift
  case "$sub" in
    scan) cmd_scan "$@" ;;
    digest) cmd_digest "$@" ;;
    record) cmd_record "$@" ;;
    rulings) cmd_rulings ;;
    plan) cmd_plan ;;
    apply) cmd_apply "$@" ;;
    status) cmd_status ;;
    arm) cmd_arm ;;
    -h|--help|help) usage ;;
    *) die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
