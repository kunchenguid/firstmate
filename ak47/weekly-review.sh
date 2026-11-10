#!/usr/bin/env bash
# ak47/weekly-review.sh - read the tick's own logs and propose threshold changes.
#
# The review is a reader, not an actor. It produces a unified diff against
# ak47/budget.conf and files it for a human. It never writes budget.conf, never
# adds a class to the tick's table, and never widens its own authority: a new
# action class needs the captain's word, and this script has no code path that
# could add one.
#
# What it reads:
#   $AK47_STATE/samples.log   one numeric sample per tick (epoch key=value ...)
#   $AK47_STATE/devops.log    one line per tick (moved, deleted, failures, ...)
#   $AK47_STATE/reap.log      one line per action, with its revert
#   $AK47_STATE/findings.log  findings the table could not settle
#
# What it proposes, and only this:
#   raise   p95 sits within 20% of the ceiling - the ceiling is about to be the
#           thing that pages, not the thing that describes the box
#   lower   p95 sits below 50% of the ceiling - the ceiling has drifted away from
#           what the box actually does and no longer means anything
#   keep    anything else
#
# Usage: weekly-review.sh [--days N] [--print] [--no-inbox]
#   --days N    window to review (default 7)
#   --print     print the report and the diff to stdout
#   --no-inbox  do not file the report with the chair
#
# Exit: 0 review written, 2 malformed budget or no samples.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}
# shellcheck source=lib/common.sh
. "$AK47_ROOT/lib/common.sh"

DAYS=7; PRINT=0; INBOX=1
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS=${2:?--days needs a number}; shift 2 ;;
    --print) PRINT=1; shift ;;
    --no-inbox) INBOX=0; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "weekly-review.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*) echo "weekly-review.sh: --days needs a whole number" >&2; exit 2 ;; esac

SAMPLES=$AK47_STATE/samples.log
DEVOPS=$AK47_STATE/devops.log
REAP=$AK47_STATE/reap.log
FINDINGS=$AK47_STATE/findings.log
BUDGET=$AK47_BUDGET
stamp=$(date -u +%Y%m%d)
REPORT=$AK47_STATE/review-$stamp.md
DIFF=$AK47_STATE/review-$stamp.diff

if [ ! -r "$SAMPLES" ]; then
  echo "weekly-review.sh: no samples at $SAMPLES; the tick has not run yet" >&2
  exit 2
fi

# ---- statistics ----------------------------------------------------------------
# One python pass: per-metric p05/p50/p95/max over the window. The low tail is
# carried because a `min` ceiling is breached from below, so p95 is the wrong
# statistic for it. Emits `key<TAB>p05<TAB>p50<TAB>p95<TAB>max<TAB>n`.
stats=$(python3 - "$SAMPLES" "$DEVOPS" "$(( $(ak47_epoch) - DAYS * 86400 ))" <<'PY'
import collections, sys
samples, devops, since = sys.argv[1], sys.argv[2], int(sys.argv[3])
vals = collections.defaultdict(list)
with open(samples, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        parts = line.split()
        if not parts:
            continue
        try:
            ts = int(parts[0])
        except ValueError:
            continue
        if ts < since:
            continue
        for kv in parts[1:]:
            k, _, v = kv.partition("=")
            try:
                vals[k].append(float(v))
            except ValueError:
                pass
for k in sorted(vals):
    xs = sorted(vals[k])
    n = len(xs)
    def pct(p):
        return xs[min(n - 1, int(round(p * (n - 1))))]
    print(f"{k}\t{pct(0.05):.0f}\t{pct(0.50):.0f}\t{pct(0.95):.0f}\t{xs[-1]:.0f}\t{n}")
PY
) || exit 2

[ -n "$stats" ] || { echo "weekly-review.sh: no samples in the last $DAYS days" >&2; exit 2; }

# ---- the proposal --------------------------------------------------------------
# A unified diff against budget.conf, built by rewriting only the ceiling column
# of the rows the rule fires on. Nothing is applied.
proposal=$(python3 - "$BUDGET" "$stats" <<'PY'
import sys
budget, stats = sys.argv[1], sys.argv[2]
p05, p95 = {}, {}
for line in stats.splitlines():
    f = line.split("\t")
    if len(f) >= 4:
        p05[f[0]] = float(f[1])
        p95[f[0]] = float(f[3])
rows = []
with open(budget, encoding="utf-8") as fh:
    for line in fh:
        rows.append(line.rstrip("\n"))
out = []
changes = []
for line in rows:
    if not line.strip() or line.lstrip().startswith("#"):
        out.append(line)
        continue
    f = line.split("|")
    if len(f) < 5:
        sys.stderr.write("weekly-review.sh: malformed budget row: %s\n" % line)
        sys.exit(2)
    key, ceil, direction, unit, reason = f[0], f[1], f[2], f[3], f[4]
    # A row the review cannot read is a broken budget, not a row to skip: a
    # silently ignored ceiling is a ceiling nobody is watching.
    try:
        c = float(ceil)
    except ValueError:
        sys.stderr.write("weekly-review.sh: non-numeric ceiling in budget row: %s\n" % line)
        sys.exit(2)
    if c <= 0:
        sys.stderr.write("weekly-review.sh: non-positive ceiling in budget row: %s\n" % line)
        sys.exit(2)
    if direction not in ("max", "min"):
        sys.stderr.write("weekly-review.sh: bad direction in budget row: %s\n" % line)
        sys.exit(2)
    step = 10 ** max(0, len(str(int(c))) - 2)
    new = None
    if direction == "min":
        # A floor is breached from below, so the low tail is the statistic that
        # matters. p05 within 20% of the floor means the floor is about to be
        # the thing that pages; p05 at twice the floor means the floor has
        # drifted away from what the box actually does.
        v = p05.get(key)
        if v is None:
            out.append(line)
            continue
        if v <= c * 1.20:
            new = int((v * 0.80 // step) * step)
            why = f"p05 {v:.0f} is within 20% of the floor {ceil}"
        elif v >= c * 2.00:
            new = int((v * 0.50 // step + 1) * step)
            why = f"p05 {v:.0f} is more than twice the floor {ceil}"
    else:
        v = p95.get(key)
        if v is None:
            out.append(line)
            continue
        if v >= c * 0.80:
            new = int((v * 1.25 // step + 1) * step)
            why = f"p95 {v:.0f} is within 20% of {ceil}"
        elif v <= c * 0.50:
            new = int((v * 1.5 // step + 1) * step)
            why = f"p95 {v:.0f} is below half of {ceil}"
    if new is None or new == int(c) or new <= 0:
        out.append(line)
        continue
    f[1] = str(new)
    out.append("|".join(f))
    changes.append(f"{key}: {ceil} -> {new} ({why}; the reason text may need rewriting)")
if not changes:
    print("NO_CHANGES")
    raise SystemExit(0)
import difflib
for d in difflib.unified_diff(rows, out, fromfile="ak47/budget.conf", tofile="ak47/budget.conf (proposed)", lineterm=""):
    print(d)
print("---")
for c in changes:
    print(f"CHANGE {c}")
PY
) || exit 2

# ---- the report ----------------------------------------------------------------
{
  echo "# ak47 hygiene review - $stamp (last $DAYS days)"
  echo
  echo "## what the box actually did"
  echo
  printf '%-16s %8s %8s %8s %8s %6s\n' METRIC p05 p50 p95 max n
  printf '%-16s %8s %8s %8s %8s %6s\n' ------ --- --- --- --- -
  printf '%s\n' "$stats" | awk -F'\t' '{printf "%-16s %8s %8s %8s %8s %6s\n", $1, $2, $3, $4, $5, $6}'
  echo
  echo "## tick health"
  echo
  if [ -r "$DEVOPS" ]; then
    since=$(( $(ak47_epoch) - DAYS * 86400 ))
    # grep -c prints 0 AND exits 1 on no match, so `|| echo 0` would print twice.
    count_in() { local n; n=$(grep -c "$1" "$DEVOPS" 2>/dev/null); echo "${n:-0}"; }
    echo "- tick lines in the window: $(awk -v s="$since" '{print $1}' "$DEVOPS" 2>/dev/null | wc -l)"
    echo "- last tick: $(tail -n 1 "$DEVOPS" 2>/dev/null | cut -d' ' -f1)"
    echo "- runs reporting a failure: $(count_in 'failures=[1-9]')"
    echo "- runs with a loop gap over 3 intervals: $(count_in 'loop_gap=[0-9]\{4,\}')"
  else
    echo "- no tick log at $DEVOPS"
  fi
  # A missing log is a fact worth printing, not a shell error worth leaking.
  if [ -r "$REAP" ]; then
    echo "- actions recorded: $(wc -l <"$REAP")"
  else
    echo "- no action log at $REAP"
  fi
  if [ -r "$FINDINGS" ]; then
    echo "- findings recorded: $(wc -l <"$FINDINGS")"
  else
    echo "- no findings log at $FINDINGS"
  fi
  echo
  echo "## proposed threshold changes"
  echo
  if [ "$proposal" = "NO_CHANGES" ]; then
    echo "None. Every ceiling still describes the box."
  else
    echo '```diff'
    printf '%s\n' "$proposal" | sed '/^---$/,$d'
    echo '```'
    echo
    printf '%s\n' "$proposal" | sed -n 's/^CHANGE /- /p'
  fi
  echo
  echo "## what this review will not do"
  echo
  echo "It will not apply the diff, add a class to the tick's table, or widen the"
  echo "tick's authority. A new action class needs the captain's word; a threshold"
  echo "change needs a human to accept the diff above."
} >"$REPORT"

if [ "$proposal" != "NO_CHANGES" ]; then
  printf '%s\n' "$proposal" | sed '/^---$/,$d' >"$DIFF"
fi

[ "$PRINT" = 1 ] && { cat "$REPORT"; [ -f "$DIFF" ] && { echo; echo "diff: $DIFF"; }; }

if [ "$INBOX" = 1 ] && [ -x "$FM_HOME/bin/fm-inbox.sh" ]; then
  if [ -f "$DIFF" ]; then
    "$FM_HOME/bin/fm-inbox.sh" note --source ak47-devops \
      "ak47 weekly review proposes threshold changes: $DIFF (report $REPORT)" >/dev/null 2>&1 || true
  else
    "$FM_HOME/bin/fm-inbox.sh" note --source ak47-devops \
      "ak47 weekly review: no threshold changes; report $REPORT" >/dev/null 2>&1 || true
  fi
fi

echo "weekly-review.sh: wrote $REPORT"
[ -f "$DIFF" ] && echo "weekly-review.sh: proposed diff at $DIFF"
exit 0
