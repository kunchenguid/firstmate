#!/usr/bin/env bash
# End-to-end: drive the real check over sample pool readings in its file-argument mode and once live, then drive install.sh
# against a throwaway firstmate home and HOME. Usage: claude-quota/tests/claude-quota.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/data TMPDIR=$d CQ_MARK=$d/mark CQ_HIST=$d/hist
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/bin"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
# claude-accounts.json shape (the claude-accounts reader's output) at $d/q.json; each argument is one pool account:
# name:5 h % left:min to its reset:week % left:h to its reset[:problem]. A problem account has no windows.
# R_AGE backdates generated_at by that many seconds.
reading() {
  python3 -I -c 'import json,sys,time,datetime as D
n=D.datetime.now(D.timezone.utc); iso=lambda m: (n+D.timedelta(minutes=m)).isoformat()
def acct(s):
    f=s.split(":"); w=lambda l,m: {"left":int(l),"resets_at":iso(float(m))}
    if len(f)>5: return {"id":f[0]+"-id","name":f[0],"folder":"/x","five_hour":None,"seven_day":None,"problem":f[5]}
    return {"id":f[0]+"-id","name":f[0],"folder":"/x","five_hour":w(f[1],f[2]),"seven_day":w(f[3],float(f[4])*60),"problem":None}
print(json.dumps({"schema":1,"generated_at":int(time.time())-int(sys.argv[1]),"accounts":[acct(s) for s in sys.argv[2:]]}))' "${R_AGE:-0}" "$@" > "$d/q.json"
}
# hist <seconds ago> <5 h points summed> <week points summed>: one earlier pool reading of 3 accounts.
hist() { echo "$(($(date +%s) - $1)) 3 $2 $3" >> "$CQ_HIST"; }
run() { "$SRC/claude-quota.check.sh" "$d/q.json" 2> "$d/err"; }
ACTION="Action: new lanes pick the pool account with the most runway; relaunch --account next on a limit; never usage credits"

# (a) One account low, the others fine: the week burns 5 points/h, the pool's 174 points last 35 h and the soonest
# reset is in 30 h, so no wake even with umeranjum17 at 4% of its week and 5% of its 5 h window.
hist 7200 275 184
reading umeranjum17:5:200:4:30 cognify:85:240:80:60 seecs:95:260:90:90
check "a: one account low, the pool fine: no wake" "$(run)" ""
check "a: ... and no diagnostic" "$(cat "$d/err")" ""

# (b) All accounts together short of the soonest reset: the week has 35 points burning 5/h (dry in 7 h), the
# soonest reset is in 30 h. One wake with the new action text; the 5 h windows burn 0 and stay quiet.
: > "$CQ_HIST"; rm -f -- "$CQ_MARK"
hist 7200 255 45
reading umeranjum17:85:200:10:30 cognify:85:240:15:60 seecs:85:260:10:90
out=$(run)
check "b: the pool short of the soonest reset wakes once, one line" "$(printf '%s\n' "$out" | grep -c .)" 1
has "b: ... names the pool's week" "$out" "Claude pool week runs dry before its soonest reset: 35 points left over 3 accounts (umeranjum17 10%, cognify 15%, seecs 10%)"
has "b: ... the burn and the soonest reset" "$out" "umeranjum17 resets first, in 30.0 h"
has "b: ... with the new action text" "$out" "$ACTION"
check "b: no route move off Claude in the wake" "$(printf '%s' "$out" | grep -ciE 'glm|\bgo\b' || true)" 0
check "b: the same step does not wake again" "$(run)" ""
reading default:85:200:8:30 cognify:85:240:10:60 default:85:260:7:90
out=$(run)
check "b: the next 10% step of the pool's mean wakes again" "$(printf '%s' "$out" | grep -c "$ACTION")" 1
has "b: ... a repeated profile name gets an ordinal" "$out" "(default 8%, cognify 10%, default 2 7%)"

# (c) One reading source failing: seecs has no reading. The other two would be short, but there is no verdict:
# a diagnostic on stderr naming the account and its cause, and no wake.
rm -f -- "$CQ_MARK"
reading umeranjum17:85:200:3:30 cognify:85:240:4:60 "seecs:0:0:0:0:quota-axi exited 1"
check "c: one account unread: no wake" "$(run)" ""
has "c: ... a diagnostic naming the account and the cause" "$(cat "$d/err")" "no current reading for seecs (quota-axi exited 1); no pool verdict this round"
R_AGE=3600 reading umeranjum17:85:200:3:30 cognify:85:240:4:60 seecs:85:260:3:90
check "c: an hour-old reading: no wake" "$(run)" ""
has "c: ... a diagnostic naming the stale file" "$(cat "$d/err")" "the account readings are 60 min old"
rm -f -- "$d/q.json"
check "c: no reading file: no wake" "$(run)" ""
has "c: ... a diagnostic" "$(cat "$d/err")" "cannot read the account readings (FileNotFoundError"

# (d) Live mode reads the home's state/claude-accounts.json and its history, then holds 10 min between reads.
M=$d/main; mkdir -p "$M/state"
reading umeranjum17:85:200:10:30 cognify:85:240:15:60 seecs:85:260:10:90
cp "$d/q.json" "$M/state/claude-accounts.json"
echo "$(($(date +%s) - 7200)) 3 255 45" > "$M/state/.claude-quota.hist"
check "d: live mode wakes on the pool's reading" "$(FM_MAIN_HOME=$M "$SRC/claude-quota.check.sh" | grep -c "$ACTION")" 1
reading umeranjum17:85:200:2:30 cognify:85:240:2:60 seecs:85:260:2:90
cp "$d/q.json" "$M/state/claude-accounts.json"
check "d: a second read inside 10 min is held, even a step lower" "$(FM_MAIN_HOME=$M "$SRC/claude-quota.check.sh")" ""

# (e) install --dry-run: prints the steps, writes nothing.
# shellcheck disable=SC2016 # expands in the stub, not here
printf '#!/bin/sh\necho "$FM_HOME|${FM_STATE_OVERRIDE-unset}|$*" >> "%s/register.calls"\n' "$d" > "$FM/bin/fm-check-register.sh"
chmod +x "$FM/bin/fm-check-register.sh"
printf '#!/usr/bin/env bash\necho old check\n' > "$FM/state/claude-quota.check.sh"
chmod 700 "$FM/state/claude-quota.check.sh"
before=$(find "$d" | sort)
out=$("$SRC/install.sh" --dry-run "$FM")
has "e: dry run names the backup" "$out" "would back up: $FM/state/claude-quota.check.sh -> $FM/state/claude-quota.check.sh.bak-claude-quota-"
has "e: dry run names the register" "$out" "would run: $FM/bin/fm-check-register.sh claude-quota"
check "e: dry run wrote nothing" "$(find "$d" | sort)" "$before"

# (f) install: backs up the old check, writes the exec shim (mode 700), re-registers with FM_STATE_OVERRIDE dropped.
export FM_STATE_OVERRIDE=
"$SRC/install.sh" "$FM" > /dev/null
check "f: old check backed up" "$(cat "$FM"/state/claude-quota.check.sh.bak-claude-quota-*)" "$(printf '#!/usr/bin/env bash\necho old check')"
check "f: shim mode" "$(stat -c %a "$FM/state/claude-quota.check.sh")" 700
check "f: registered once, override dropped" "$(cat "$d/register.calls")" "$FM|unset|claude-quota"
rm -f -- "$CQ_MARK"; : > "$CQ_HIST"; hist 7200 255 45
reading umeranjum17:85:200:10:30 cognify:85:240:15:60 seecs:85:260:10:90
check "f: the shim runs the installed check" "$("$FM/state/claude-quota.check.sh" "$d/q.json" | grep -c "$ACTION")" 1
"$SRC/install.sh" "$FM" > /dev/null
check "f: rerun makes no second backup" "$(find "$FM/state" -name '*.bak-claude-quota-*' | wc -l)" 1
check "f: rerun registers again" "$(wc -l < "$d/register.calls")" 2

[ "$fails" -eq 0 ] && echo "all claude-quota checks passed" || { echo "$fails check(s) failed"; exit 1; }
