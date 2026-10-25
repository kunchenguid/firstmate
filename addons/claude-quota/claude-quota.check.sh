#!/usr/bin/env bash
# Wake Main when the whole Claude account pool will run dry before its soonest reset. Workers spread over every pool
# account (claude-accounts), so one low account is not an alarm: the next lane or relaunch takes another one. For each
# window (5 h, week) it adds up every account's percent left and the pool's burn rate over the last 1-5 h, and wakes
# when that sum runs out before the soonest reset among the accounts (again on each 10% step of the pool's mean left).
# At most one read per 10 min. Readings come from the claude-accounts reader's state/claude-accounts.json; an
# unreadable, stale or failed reading prints a diagnostic on stderr and no verdict, so it never wakes falsely.
# Usage: $0 [claude-accounts-json-file] (file = test input; CQ_MARK and CQ_HIST then name the repeat-state and
# history files, default fresh temp files).
set -u
FM_MAIN=${FM_MAIN_HOME:-$HOME/firstmate}
MARK=$FM_MAIN/state/.claude-quota.last
HIST=$FM_MAIN/state/.claude-quota.hist
SRC=$FM_MAIN/state/claude-accounts.json
now=$(date +%s)
if [ $# -eq 0 ]; then
  [ -f "$MARK" ] && [ $((now - $(stat -c %Y "$MARK"))) -lt 600 ] && exit 0
else
  SRC=$1; MARK=${CQ_MARK:-$(mktemp)}; HIST=${CQ_HIST:-$(mktemp)}
fi
out=$(SRC=$SRC HIST=$HIST PREV=$(cat "$MARK" 2>/dev/null) python3 -I -c '
import json,os,sys,time,datetime as D
now=time.time()
def bad(m): print(f"claude-quota: {m}; no pool verdict this round",file=sys.stderr); sys.exit(3)
try: r=json.load(open(os.environ["SRC"])); A=r["accounts"]; age=now-r["generated_at"]
except Exception as e: bad(f"cannot read the account readings ({type(e).__name__}: {e})")
if age>1800: bad(f"the account readings are {age/60:.0f} min old; is the claude-accounts reader timer running")
if not A: bad("the account readings name no account")
B=[a.get("name") or a["id"] for a in A]
N=[b+(f" {B[:i].count(b)+1}" if b in B[:i] else "") for i,b in enumerate(B)]  # a repeated name gets an ordinal, as on the dashboard
W={"five_hour":"5 h window","seven_day":"week"}
failed=[n+" ("+(a.get("problem") or "no window")+")" for a,n in zip(A,N)
        if a.get("problem") or any((a.get(k) or {}).get("left") is None for k in W)]
if failed: bad("no current reading for "+", ".join(failed))
P=lambda s: D.datetime.fromisoformat(s.replace("Z","+00:00")).timestamp()
cur=[sum(a[k]["left"] for a in A) for k in W]
hp=os.environ["HIST"]
try: h=[tuple(map(float,l.split())) for l in open(hp) if len(l.split())==4]
except Exception: h=[]
h=[x for x in h if now-x[0]<5*3600 and x[1]==len(A)]+[(now,len(A),*cur)]
open(hp,"w").write("".join(" ".join(str(int(v)) for v in x)+"\n" for x in h[-40:]))
prev=os.environ.get("PREV","").split("|"); sig=[]; lines=[]
for i,(k,label) in enumerate(W.items()):
    s=[(x[0],x[2+i]) for x in h]
    s=s[max([j for j in range(1,len(s)) if s[j][1]>s[j-1][1]],default=0):]  # a rise is a reset: rate from after it
    old=[x for x in s if now-x[0]>=3600]
    rate=(old[0][1]-cur[i])/((now-old[0][0])/3600) if old else 0
    resets=sorted((P(a[k]["resets_at"]),n) for a,n in zip(A,N) if a[k].get("resets_at") and P(a[k]["resets_at"])>now)
    if rate<=0 or not resets or cur[i]/rate>=(resets[0][0]-now)/3600: sig.append("-"); continue
    sig.append(str(cur[i]//len(A)//10))
    if prev[i:i+1]==[sig[-1]]: continue
    each=", ".join(n+" "+str(a[k]["left"])+"%" for a,n in zip(A,N))
    lines.append(f"claude-quota: Claude pool {label} runs dry before its soonest reset: {cur[i]} points left over {len(A)} accounts ({each}), "
                 f"burning {rate:.1f} points/h over the last {(now-old[0][0])/3600:.1f} h = dry in {cur[i]/rate:.1f} h; "
                 f"{resets[0][1]} resets first, in {(resets[0][0]-now)/3600:.1f} h. Action: new lanes pick the pool account with the most runway; "
                 "relaunch --account next on a limit; never usage credits")
if sig!=["-","-"]: print("|".join(sig)); print("\n".join(lines))
')
case $? in 3) touch "$MARK"; exit 0 ;; esac
[ -n "$out" ] || { : > "$MARK"; exit 0; }
printf '%s' "${out%%$'\n'*}" > "$MARK"
case $out in *$'\n'?*) printf '%s\n' "${out#*$'\n'}" ;; esac
