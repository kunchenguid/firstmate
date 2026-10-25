#!/usr/bin/env bash
# zai-quota-check e2e: the real check in its file-argument test mode against a
# quota JSON fixture sequence, with ZAI_QUOTA_MARK holding the repeat state
# across the runs of one sequence. Journeys (repeat-signature fix): with the
# week-ahead condition true all week and the 5 h window above 30%, fp
# 90->80->...->40 wakes once, where the old fp//10|wp//10 signature woke on
# every run; with the 5 h condition (under 30% left, more than 45 min to its
# reset) each 10% step wakes once; a week 10% step always wakes once. Needs
# bash and python3 on PATH; no real tool, home or quota read is touched.
set -u

here=$(cd "$(dirname "$0")" && pwd) || exit 1
bin=$here/../zai-quota-check
[ -x "$bin" ] || { echo "not ok - $here/../zai-quota-check is missing"; exit 1; }
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
mark=$work/mark
export ZAI_QUOTA_MARK=$mark

fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

fixture() { # fixture <file> <fp> <five-left-min> <wp> <week-left-min>
  python3 - "$@" <<'PY'
import json,sys,datetime as D
out,fp,left,wp,wl=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4]),int(sys.argv[5])
now=D.datetime.now(D.timezone.utc)
z=lambda m:(now+D.timedelta(minutes=m)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"providers":[{"provider":"zai","windows":[
  {"id":"five_hour","percentRemaining":fp,"resetsAt":z(left)},
  {"id":"weekly","percentRemaining":wp,"resetsAt":z(wl)}]}]},open(out,"w"))
PY
}

wakes() { # wakes <file>: 1 when the run printed a wake, else 0
  local out
  out=$("$bin" "$1") || { no "check exited nonzero on $1"; echo 0; return; }
  grep -q '^zai-quota:' <<<"$out" && { echo 1; return; }
  echo 0
}

seq() { # seq <five-left-min> <week-left-min> <fp,wp>...: wake count over the runs
  local left=$1 wl=$2 spec fp wp w=0
  shift 2
  : > "$mark"
  for spec in "$@"; do
    fp=${spec%,*}; wp=${spec#*,}
    fixture "$work/q.json" "$fp" "$left" "$wp" "$wl"
    w=$((w + $(wakes "$work/q.json")))
  done
  echo "$w"
}

# Week-ahead all week (wp 30, half the week gone: 70 > 50+15), 5 h window
# above 30%: the old signature woke on every 10% step; now one wake only.
is "week-ahead true, fp 90..40 above 30% wakes once" \
  "$(seq 120 5040 90,30 80,30 70,30 60,30 50,30 40,30)" 1

# 5 h condition (under 30% left, 120 min to reset): each 10% step wakes once
# (29, 19, 9), plus the first firing of the sweep.
is "fp under 30 with 120 min left: each 10% step wakes once" \
  "$(seq 120 5040 90,30 80,30 70,30 60,30 50,30 40,30 29,30 19,30 9,30)" 4

# Week step alone (fp parked at 90, week 50 -> 40 -> 30 with a sixth of the
# week gone, so the week-ahead condition holds): every week 10% step wakes once.
is "week 50..40..30 steps each wake once" \
  "$(seq 120 8640 90,50 90,40 90,30)" 3

exit "$fails"
