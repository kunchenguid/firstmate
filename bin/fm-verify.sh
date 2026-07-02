#!/usr/bin/env bash
# Quarterdeck: the structural verifier stage between a crewmate's `done:` claim
# and firstmate's acceptance. Spec: docs/specs/2026-07-01-agent-os-council.md.
#
# `done:` is a claim, not an acceptance. fm-verify.sh, run by firstmate when a
# ship task reports done:
#   1. snapshots the crewmate's diff        -> data/<id>/lens-diff.patch
#   2. runs the foreign lens on it          -> data/<id>/lens-review.md
#      (chain: FM_LENS_CMD > Fugu > codex > none - degrades loudly, never silently)
#   3. spawns an independent fresh-context verifier (default-REJECT) in the
#      crewmate's worktree                  -> data/<id>/verify-report.md
#   4. appends the decision to state/<id>.verdict (fm-verdict-lib grammar);
#      fm-merge-local/fm-pr-check refuse without a trailing approve.
#   5. on reject: relays findings to the crewmate (FM_RELAY_CMD, default
#      fm-send.sh); after FM_VERIFY_MAX_ATTEMPTS (default 3) rejects, escalates.
#
# Fail closed: verifier won't run / emits no VERDICT line -> escalate, never
# approve. Non-ship tasks (scout/secondmate) skip in Phase 1.
#
# Seams: FM_VERIFY_CMD  verifier command; gets the prompt as $1, cwd=worktree,
#                       stdout must end with "VERDICT: approve|reject|escalate - reason"
#                       (default: claude -p --permission-mode bypassPermissions)
#        FM_LENS_CMD    lens command; diff on stdin, review on stdout
#        FM_RELAY_CMD   reject relay; default bin/fm-send.sh (word-split)
# Exit: 0 approve or skip, 2 reject, 3 escalate, 1 usage error.
# Usage: fm-verify.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

ID=${1:?usage: fm-verify.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "${KIND:-ship}" != ship ]; then
  echo "skip: task $ID kind=${KIND:-?} (Quarterdeck verifies ship tasks only in Phase 1)"
  exit 0
fi

WORKTREE=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2-)
[ -d "$WORKTREE" ] || { echo "error: worktree $WORKTREE missing for task $ID" >&2; exit 1; }
BRIEF="$DATA/$ID/brief.md"
mkdir -p "$DATA/$ID"

MAX=${FM_VERIFY_MAX_ATTEMPTS:-3}

# Already at the cap before this run? Straight to the captain, no more spins.
if [ "$(fm_verdict_reject_count "$STATE" "$ID")" -ge "$MAX" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($MAX rejects); captain decision required"
  echo "escalate: task $ID at attempt cap ($MAX rejects)" >&2
  exit 3
fi

# --- 1. diff payload ---------------------------------------------------------
default_branch() {
  local ref branch
  ref=$(git -C "$WORKTREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then echo "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$WORKTREE" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"; return 0
    fi
  done
  return 1
}

DIFF_FILE="$DATA/$ID/lens-diff.patch"
{
  DEFAULT=$(default_branch || true)
  if [ -n "${DEFAULT:-}" ] && base=$(git -C "$WORKTREE" merge-base HEAD "$DEFAULT" 2>/dev/null); then
    git -C "$WORKTREE" log --oneline "$base..HEAD"
    git -C "$WORKTREE" diff "$base..HEAD"
  else
    echo "(no default branch resolvable; showing HEAD commit only)"
    git -C "$WORKTREE" show HEAD
  fi
} | head -c 200000 > "$DIFF_FILE"

# --- 2. foreign lens: FM_LENS_CMD > Fugu > codex > none ------------------------
LENS_REVIEW="$DATA/$ID/lens-review.md"
LENS_PROMPT="You are a hostile senior reviewer. Roast this diff before it ships: correctness bugs, untested claims, security holes, scope drift. Be specific (file:line). End with the findings that most deserve a reject, or 'no blocking findings'."

lens_fugu() {
  [ -n "${FUGU_API_KEY:-}" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$DIFF_FILE" "$LENS_PROMPT" <<'PY' > "$LENS_REVIEW" && [ -s "$LENS_REVIEW" ]
import json, os, sys, urllib.request
diff = open(sys.argv[1], errors="replace").read()
body = json.dumps({"model": "fugu", "messages": [
    {"role": "system", "content": sys.argv[2]},
    {"role": "user", "content": diff}]}).encode()
req = urllib.request.Request(
    "https://api.sakana.ai/v1/chat/completions", data=body,
    headers={"Authorization": "Bearer " + os.environ["FUGU_API_KEY"],
             "Content-Type": "application/json"})
resp = json.load(urllib.request.urlopen(req, timeout=180))
content = resp["choices"][0]["message"]["content"]
if not content.strip():
    raise SystemExit("empty lens review")
print(content)
PY
}

lens_codex() {
  command -v codex >/dev/null 2>&1 || return 1
  codex exec --cd "$WORKTREE" \
    "$LENS_PROMPT Review the diff at $DIFF_FILE against the worktree around you." \
    > "$LENS_REVIEW" 2>/dev/null && [ -s "$LENS_REVIEW" ]
}

LENS=none
if [ -n "${FM_LENS_CMD:-}" ]; then
  if sh -c "$FM_LENS_CMD" < "$DIFF_FILE" > "$LENS_REVIEW" 2>/dev/null && [ -s "$LENS_REVIEW" ]; then
    LENS=custom
  fi
elif lens_fugu 2>/dev/null; then
  LENS=fugu
elif lens_codex; then
  LENS=codex
fi
if [ "$LENS" = none ]; then
  printf 'no foreign lens available (FUGU_API_KEY unset or failed; codex not on PATH)\n' > "$LENS_REVIEW"
  echo "warning: foreign lens degraded to none for task $ID" >&2
fi
fm_verdict_append "$STATE" "$ID" lens "$LENS $(head -c 120 "$LENS_REVIEW" | tr '\n' ' ')"

# --- 3. independent verifier (fail closed) -------------------------------------
REPORT="$DATA/$ID/verify-report.md"
VERIFY_CMD=${FM_VERIFY_CMD:-claude -p --permission-mode bypassPermissions}

BRIEF_TEXT="(no brief found at $BRIEF)"
[ -f "$BRIEF" ] && BRIEF_TEXT=$(cat "$BRIEF")
PROMPT=$(cat <<EOF
You are the Quarterdeck verifier: a fresh-context independent checker. The
crewmate for task $ID claims done. Default stance: REJECT until proven.
Never trust what the crewmate says - re-run everything yourself from this
worktree ($WORKTREE, branch fm/$ID).

Checklist:
1. If a gates/ dir exists here, run: bash gates/verify.sh - every gate must be
   green; red or unproven gates are an automatic reject.
2. Re-prove each claim in the definition of done below by EXECUTING it (run the
   tests, run the command, read the diff), not by trusting the report the crewmate wrote.
3. Weigh the foreign-lens review below; confirm or dismiss each finding.
4. No cheating: confirm tests were not weakened, skipped, or deleted, and the
   diff stays inside the assigned scope.

# The task brief
$BRIEF_TEXT

# Foreign-lens review (lens=$LENS)
$(cat "$LENS_REVIEW")

Your reply MUST end with exactly one line, nothing after it:
VERDICT: approve - <one-line reason>
VERDICT: reject - <the concrete failure a fix must address>
VERDICT: escalate - <why a human must decide>
EOF
)

verdict_kind=""
verdict_reason=""
if (cd "$WORKTREE" && sh -c "$VERIFY_CMD \"\$1\"" _ "$PROMPT") > "$REPORT" 2>&1; then
  line=$(grep -E '^VERDICT: (approve|reject|escalate)' "$REPORT" | tail -1 || true)
  if [ -n "$line" ]; then
    verdict_kind=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate).*$/\1/')
    verdict_reason=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate)[^A-Za-z0-9]*//')
  fi
fi
if [ -z "$verdict_kind" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "verifier infrastructure failure (no VERDICT line; see data/$ID/verify-report.md) - fail closed"
  echo "escalate: verifier produced no verdict for $ID (see $REPORT)" >&2
  exit 3
fi

# --- 4. record + route ----------------------------------------------------------
case "$verdict_kind" in
  approve)
    fm_verdict_append "$STATE" "$ID" approve "${verdict_reason:-verifier approve} (lens=$LENS)"
    echo "approve: task $ID verified (lens=$LENS)"
    exit 0
    ;;
  escalate)
    fm_verdict_append "$STATE" "$ID" escalate "${verdict_reason:-verifier escalate}"
    echo "escalate: task $ID needs the captain (see $REPORT)" >&2
    exit 3
    ;;
  reject)
    n=$(( $(fm_verdict_reject_count "$STATE" "$ID") + 1 ))
    fm_verdict_append "$STATE" "$ID" reject "(attempt $n of $MAX) ${verdict_reason:-verifier reject}"
    # shellcheck disable=SC2086 # FM_RELAY_CMD is deliberately word-split
    ${FM_RELAY_CMD:-"$SCRIPT_DIR/fm-send.sh"} "fm-$ID" \
      "QUARTERDECK REJECTED (attempt $n of $MAX): ${verdict_reason:-see report}. Findings: data/$ID/verify-report.md and data/$ID/lens-review.md. Fix and append a fresh done: line." \
      || echo "warning: could not relay reject to fm-$ID (window gone?)" >&2
    if [ "$n" -ge "$MAX" ]; then
      fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($n rejects); captain decision required"
      echo "escalate: task $ID hit the attempt cap ($n of $MAX)" >&2
      exit 3
    fi
    echo "reject: task $ID (attempt $n of $MAX); findings relayed" >&2
    exit 2
    ;;
esac
