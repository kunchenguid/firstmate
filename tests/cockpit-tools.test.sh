#!/usr/bin/env bash
# Behavior test for tools/cockpit/: build a synthetic cockpit page, a lane
# status directory, a local git origin and a fake `gh`, run each tool through its
# command line, and prove a second run changes nothing. The fixture holds only
# invented demo names; no real board content, no secrets.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

TOOLS="$ROOT/tools/cockpit"
TMP_ROOT=$(fm_test_tmproot cockpit-tools)
FM_FIX="$TMP_ROOT/fmhome"
DATA="$FM_FIX/data/miko-all-in-one-lavish"
FAKEBIN="$TMP_ROOT/fakebin"
SCRATCH="$TMP_ROOT/tmp"
ORIGIN="$TMP_ROOT/origin.git"
WORK="$TMP_ROOT/work"
mkdir -p "$FM_FIX/state" "$DATA" "$FAKEBIN" "$SCRATCH" "$TMP_ROOT/home"

# ---- git origin: the register files the cockpit reads from origin/main ----
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
git init -q --bare -b main "$ORIGIN" || fail "git init --bare failed"
git clone -q "$ORIGIN" "$WORK" 2>/dev/null || fail "git clone failed"
mkdir -p "$WORK/apps/portal/registers" "$WORK/docs/project"
printf '%s\n' '{"components":{"comp-a":{"G1":true,"G2":true,"G3":false}}}' > "$WORK/apps/portal/registers/prod-gate.json"
printf '%s\n' '{"components":[{"id":"comp-a","state":"live"},{"id":"comp-b","state":"planned"}]}' > "$WORK/apps/portal/registers/portal-states.json"
printf '%s\n' '# demo architecture' > "$WORK/docs/project/architecture.md"
git -C "$WORK" add -A || fail "fixture add failed"
git -C "$WORK" commit -q -m fixture || fail "fixture commit failed"
git -C "$WORK" push -q origin HEAD:main || fail "fixture push failed"
SHA=$(git -C "$WORK" rev-parse HEAD)

# ---- fake gh: answers only the four calls the cockpit makes, from fixture files ----
cat > "$TMP_ROOT/graphql.json" <<'EOF'
{"data":{"repository":{
 "open":{"nodes":[{"number":502,"mergeable":"MERGEABLE","isInMergeQueue":false,"mergeQueueEntry":null,
   "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}]},
 "merged":{"nodes":[{"number":501,"mergedAt":"2026-11-10T10:00:00Z"}]}}}}
EOF
printf '%s\n' '{"workflow_runs":[{"id":101,"name":"vercel","status":"completed"}]}' > "$TMP_ROOT/runs.json"
printf '%s\n' '{"jobs":[{"id":201,"name":"portal-deploy"}]}' > "$TMP_ROOT/jobs.json"
printf 'deployed: %s serves production\n' "$SHA" > "$TMP_ROOT/log.txt"
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
fx="$TMP_ROOT"
for a in "\$@"; do
  case "\$a" in
    graphql) cat "\$fx/graphql.json"; exit 0 ;;
    repos/*/actions/runs\?*) cat "\$fx/runs.json"; exit 0 ;;
    repos/*/actions/runs/*/jobs) cat "\$fx/jobs.json"; exit 0 ;;
    repos/*/actions/jobs/*/logs) cat "\$fx/log.txt"; exit 0 ;;
  esac
done
echo "fake gh: unexpected call: \$*" >&2
exit 1
EOF
chmod +x "$FAKEBIN/gh"

# ---- synthetic cockpit page ----
bars() { # bars <closed-count> : eight step cells
  local i out=''
  for i in 1 2 3 4 5 6 7 8; do
    if [ "$i" -le "$1" ]; then out="$out<i style=\"flex:1;height:4px;border-radius:1px;background:#3fa36b\"></i>"
    else out="$out<i style=\"flex:1;height:4px;border-radius:1px;background:#353b47\"></i>"; fi
  done
  printf '%s' "$out"
}
card() { # card <wbs-id> <title> <note> <closed-count> [extra-html]
  printf '<div class="kb-card" data-wbs="%s" style="border:1.6px solid #9aa4b2;border-radius:7px;padding:4px 6px;margin:0 0 5px;background:#181b22;font-size:12.5px;min-width:0;overflow-wrap:anywhere"><b>%s</b><br><span class="mute" style="font-size:11.5px">%s</span><br><span class="kb-next" style="display:inline-block;margin:2px 0 0;font-size:10.5px;font-weight:700;color:#9aa4b2;border:1px solid #9aa4b2;border-radius:9px;padding:0 5px">· nog in te delen</span>%s<span style="display:flex;gap:2px;margin:3px 0 0" title="acht stappen: %s van 8">%s</span></div>' \
    "$1" "$2" "$3" "${5:-}" "$(( $4 + 1 ))" "$(bars "$4")"
}
gstrip() {
  printf '<span style="display:flex;gap:2px;align-items:center;margin:2px 0 0" title="nodig nu: 8 controles (G8 en G9 later); met bewijs op main: 0 van 8"><i style="flex:1;height:9px;border-radius:1px;background:transparent;border:1.5px solid #c9ced6"></i><b style="font-size:10px;margin-left:3px">0/8</b></span>'
}
column() { # column <n> <title> <sub> [cards]
  printf '<div style="border:1px solid #2b3140;border-radius:8px;padding:5px;background:#141821;min-width:0"><p style="margin:0;font-size:12.5px"><b>%s %s</b> <span class="mute">(0)</span></p><p class="small mute" style="margin:0 0 5px;font-size:11px">%s</p>%s</div>' "$1" "$2" "$3" "${4:-}"
}
box() { # box <id> <title> <x> <y> <closed-count> [status]
  local id=$1 title=$2 x=$3 y=$4 n=$5 st=${6:-bezig} i fills=''
  for i in 1 2 3 4 5 6 7 8; do
    local c='#353b47'; [ "$i" -le "$n" ] && c='#3fa36b'
    fills="$fills<rect x=\"$(( x + 5 + (i - 1) * 15 )).0\" y=\"$(( y + 35 )).0\" width=\"13.5\" height=\"3.5\" rx=\"1\" fill=\"$c\"/>"
  done
  printf '<g data-id="%s" data-tip="%s&#10;Status: %s&#10;Acht stappen: 1 opdracht klaar"><title>%s</title><rect x="%s" y="%s" width="128" height="40" rx="6" fill="#0f1218" stroke="#9aa4b2" stroke-width="1.5"/><text x="%s" y="%s" font-size="10.5" font-weight="700" fill="#f1f3f6">%s</text>%s</g>' \
    "$id" "$title" "$st" "$title" "$x" "$y" "$(( x + 7 ))" "$(( y + 16 ))" "$title" "$fills"
}
build_page() {
  local cols='' n
  local c2 c3 c4
  c2=$(card 'I2:DEMO' 'Demo scherm' 'PR 501 en 502 in de weg' 1)
  c3=$(card 'I3:DEMO2' 'Demo koppeling' 'PR 502 open' 2)
  c4=$(card 'I3:DEMO3' 'Demo register' 'PR 501 open' 3 "$(gstrip)")
  for n in 1 2 3 4 5 6 7 8; do
    case $n in
      2) cols="$cols$(column 2 Code 'code open' "$c2")" ;;
      3) cols="$cols$(column 3 Review 'PR open' "$c3")" ;;
      4) cols="$cols$(column 4 Main 'op main' "$c4")" ;;
      *) cols="$cols$(column "$n" "Stap$n" "stap $n")" ;;
    esac
  done
  cat <<EOF
<html><body>
<h1>Demo cockpit</h1>
<p class="small">Hoofdtekening: stand ma 02-11-2026 (nagekeken ma 02-11)</p>
<p class="small">bijgewerkt ma 16-11-2026 08:00 CET</p>
<section id="captain-door"><p>Demo bovenaan</p></section>
<section id="kanban"><h2 style="margin:0 0 4px">2. Kanban <span class="small mute">(stand 08:00)</span></h2>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,128px),1fr));gap:5px">$cols</div>
<p class="small mute" style="margin:6px 0 0">Alles uit de WBS staat hier (0 kaarten).</p></section>
<section id="wbs-blok"><h2>WBS</h2><div id="wbs-zoom"><svg width="2300" height="1500">
$(box 'I2:DEMO' 'Demo scherm' 100 270 1)
$(box 'I3:DEMO2' 'Demo koppeling' 250 490 2)
$(box 'I3:DEMO3' 'Demo register' 400 490 3)
$(box 'I5:EXTRA' 'Demo rapport' 100 790 0 'later')
$(box 'I6:EXTRA' 'Demo app PR 502' 100 870 1)
$(box 'DONE:I1:OLD' 'Demo oud' 100 50 8 klaar)
<path data-f="I2:DEMO" data-t="I3:DEMO2" d="M0 0"/>
</svg></div></section>
<script type="application/json" id="card-data">{}</script>
</body></html>
EOF
}
build_page > "$DATA/cockpit-2.html"
cat > "$DATA/card-data.json" <<'EOF'
{"_lane_names":{"miko-new-thing":"Demo nieuw"},
 "Demo scherm":{"lane":"miko-demo-lane","eta":"onbekend"},
 "Demo koppeling":{"eta":"onbekend"},
 "Demo register":{"register":["comp-a"],"eta":"onbekend"}}
EOF
# lane files: one lane already on the board and running, one new lane the tool must add once
printf 'working [at=1]: demo lane working\n' > "$FM_FIX/state/miko-demo-lane.status"
printf 'working [at=1]: demo new thing in progress\n' > "$FM_FIX/state/miko-new-thing.status"
printf 'kind=ship\n' > "$FM_FIX/state/miko-new-thing.meta"
printf 'kind=ship\n' > "$FM_FIX/state/miko-demo-lane.meta"

# Every run keeps its temp dirs, caches and home inside the fixture, and reaches
# the fake gh only. FM_HOME/COCKPIT_DATA_DIR/MIKO_WORKTREE are the documented knobs.
run_refresh() { # run_refresh [extra env assignments...] -> stdout of refresh-cockpit.sh
  env -i PATH="$FAKEBIN:$PATH" HOME="$TMP_ROOT/home" TMPDIR="$SCRATCH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    FM_HOME="$FM_FIX" COCKPIT_DATA_DIR="$DATA" MIKO_WORKTREE="$WORK" "$@" \
    bash "$TOOLS/refresh-cockpit.sh"
}
minute() { TZ=Europe/Amsterdam date +%H%M; }
snapshot() { cat "$DATA/cockpit-2.html" "$DATA/card-data.json" | md5sum | cut -d' ' -f1; }

# ---- refresh-cockpit.sh (wraps refresh-cockpit.py): in place, twice ----
PRISTINE_PAGE=$(md5sum < "$DATA/cockpit-2.html")
FIRST_OUT="$TMP_ROOT/run1.out"
SECOND_OUT="$TMP_ROOT/run2.out"
attempt=0
while :; do
  attempt=$((attempt + 1))
  m1=$(minute)
  run_refresh > "$FIRST_OUT" 2> "$TMP_ROOT/run1.err" || fail "first refresh failed: $(cat "$TMP_ROOT/run1.err")"
  snap1=$(snapshot)
  run_refresh > "$SECOND_OUT" 2> "$TMP_ROOT/run2.err" || fail "second refresh failed: $(cat "$TMP_ROOT/run2.err")"
  snap2=$(snapshot)
  m2=$(minute)
  # The page carries a wall-clock HH:MM stamp, so a pair straddling a minute change proves nothing.
  [ "$m1" = "$m2" ] && break
  [ "$attempt" -lt 3 ] || fail "could not get two refresh runs inside one minute"
  FIRST_OUT="$TMP_ROOT/run1.out.$attempt"
done

[ "$PRISTINE_PAGE" != "$(md5sum < "$DATA/cockpit-2.html")" ] || fail "refresh left the fixture page untouched (vacuous run)"
if [ "$attempt" -eq 1 ]; then
  grep -q 'LANES-ADDED: miko-new-thing' "$FIRST_OUT" || fail "first refresh did not add the new lane: $(cat "$FIRST_OUT")"
  grep -q 'Demo nieuw' "$DATA/cockpit-2.html" || fail "new lane card missing from the page"
fi
grep -q '^production serves ' "$SECOND_OUT" || fail "second refresh printed no production line: $(cat "$SECOND_OUT")"
grep -q 'LANES-ADDED' "$SECOND_OUT" && fail "second refresh added the lane again: $(cat "$SECOND_OUT")"
grep -q ' 0 cards updated, 0 moved, 0 boxes synced' "$SECOND_OUT" || fail "second refresh still changed cards: $(cat "$SECOND_OUT")"
[ "$snap1" = "$snap2" ] || fail "second refresh changed the page or card-data.json"
[ "$(grep -c 'data-wbs="I2:AUTO-NEW-THING"' "$DATA/cockpit-2.html")" -ge 1 ] || fail "auto-added card is missing"
[ "$(grep -o 'data-id="I2:AUTO-NEW-THING"' "$DATA/cockpit-2.html" | wc -l)" -eq 1 ] || fail "auto-added WBS box is missing or duplicated"
[ -e "$DATA/.refresh.lock" ] || fail "lock file not created under COCKPIT_DATA_DIR"
[ -z "$(find "$DATA" -name '*.tmp*' -print -quit)" ] || fail "a temp file was left next to the page"
pass "refresh-cockpit: second run changes nothing (page and card-data identical)"

# ---- COCKPIT_OUT: writes elsewhere, leaves the installed page alone, also idempotent ----
INSTALLED=$(snapshot)
cp "$DATA/card-data.json" "$TMP_ROOT/card-before.json"
attempt=0
while :; do
  attempt=$((attempt + 1))
  m1=$(minute)
  run_refresh COCKPIT_OUT="$TMP_ROOT/out-a.html" > /dev/null 2>&1 || fail "COCKPIT_OUT run A failed"
  run_refresh COCKPIT_OUT="$TMP_ROOT/out-b.html" > /dev/null 2>&1 || fail "COCKPIT_OUT run B failed"
  m2=$(minute)
  [ "$m1" = "$m2" ] && break
  [ "$attempt" -lt 3 ] || fail "could not get two COCKPIT_OUT runs inside one minute"
done
[ -s "$TMP_ROOT/out-a.html" ] || fail "COCKPIT_OUT wrote nothing"
cmp -s "$TMP_ROOT/out-a.html" "$TMP_ROOT/out-b.html" || fail "two COCKPIT_OUT runs differ"
[ "$INSTALLED" = "$(snapshot)" ] || fail "COCKPIT_OUT run touched the installed page or card-data.json"
cmp -s "$TMP_ROOT/card-before.json" "$DATA/card-data.json" || fail "COCKPIT_OUT run rewrote card-data.json"
pass "refresh-cockpit: COCKPIT_OUT leaves the installed page alone and is repeatable"

# ---- existing Doelen cards get one keyed switch each, and round-trip through the real answer reader ----
GOAL_HOME="$TMP_ROOT/goals-home"
mkdir -p "$GOAL_HOME/state" "$GOAL_HOME/data"
goal() { env -i PATH="$PATH" HOME="$TMP_ROOT/home" FM_HOME="$GOAL_HOME" bash "$ROOT/bin/fm-goal.sh" "$@"; }
printf '%s\n' \
  'item [id=check] [owner=main]: Ready' \
  'item [id=orphan] [owner=main]: No live task' \
  'item [id=live] [owner=main] [task=demo-goal-task]: Live task' \
  'item [id=dep] [owner=main] [after=live]: Unmet dependency' \
  'item [id=hold] [owner=main]: Blocked' \
  'item [id=wait] [owner=main]: Waiting' \
  'item [id=landed] [owner=main]: Landed' \
  'item [id=removed] [owner=main]: Dropped' \
  'item [id=decision] [owner=captain] [class=captain]: Decision' > "$TMP_ROOT/items-alpha"
printf 'item [id=check] [owner=main]: Paused goal step\n' > "$TMP_ROOT/items-beta"
for id in alpha beta; do
  goal start "$id" --title "Doel $id" --done-when 'demo complete' --named-by 'do this' \
    --plan plan.md --items-file "$TMP_ROOT/items-$id" >/dev/null || fail "could not start $id"
done
printf 'kind=ship\n' > "$GOAL_HOME/state/demo-goal-task.meta"
printf 'working [at=%s]: fixture live task\n' "$(date +%s)" > "$GOAL_HOME/state/demo-goal-task.status"
mark_alpha() { goal mark alpha "$@" >/dev/null || fail "could not mark alpha/$1 $2"; }
mark_alpha orphan running -- 'task missing'
mark_alpha live running -- 'task live'
mark_alpha hold blocked -- 'blocked'
mark_alpha wait waiting -- 'waiting'
mark_alpha landed 'done' -- 'landed via https://github.com/demo/repo/pull/1'
mark_alpha removed dropped -- 'dropped'
goal pause beta >/dev/null || fail 'could not pause beta'
python3 - "$DATA/cockpit-2.html" <<'PY'
from pathlib import Path
import sys
page = Path(sys.argv[1])
source = page.read_text()
rich = source.index('</div>', source.index('class="kb-card" data-wbs="I2:DEMO"'))
source = (source[:rich] + '<span class="fm-goal-item-status" data-fm-goal-item="alpha/check"></span>'
          + source[rich:])
for wbs_id, item in [('I2:DEMO', 'check'), ('I5:EXTRA', 'orphan')]:
    end = source.index('</g>', source.index(f'<g data-id="{wbs_id}"'))
    slot = f'<text x="4" y="25" class="fm-goal-item-status" data-fm-goal-item="alpha/{item}"></text>'
    source = source[:end] + slot + source[end:]
page.write_text(source.replace('</body>', '''
<section><h2 id="doelen">Doelen</h2>
<div id="doel-alpha"><details><summary>Alpha</summary>Alpha steps</details></div>
<div id="doel-beta"><details><summary>Beta</summary>Beta steps</details></div>
</section></body>'''))
PY
preview="$TMP_ROOT/goals.html"
run_refresh COCKPIT_GOAL_HOME="$GOAL_HOME" COCKPIT_OUT="$preview" >/dev/null || fail 'goal-drive refresh failed'
python3 - "$preview" "$TMP_ROOT/toggles.result" <<'PY' || fail 'wrong goal-drive rendering'
import csv
from html.parser import HTMLParser
import json
from pathlib import Path
import sys

page = Path(sys.argv[1]).read_text()
assert '1 van 2 doelen actief gedreven' in page
assert '[data-fm-goal-drive="off"] { filter: grayscale(1); }' in page
assert 'wordt gedreven' in page and '>uit</span>' in page
assert 'Alpha steps' in page and 'Beta steps' in page

class Switches(HTMLParser):
    def __init__(self):
        super().__init__()
        self.states, self.answers = {}, {}
        self.labels, self.legend = [], {}
        self.status = self.key = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'data-fm-goal-status' in a and (tag == 'li' or a.get('class') == 'fm-goal-item-status'):
            self.status = (tag, a.get('data-fm-goal-item'), a['data-fm-goal-status'])
            self.text = []
        if tag == 'div' and a.get('id') in ('doel-alpha', 'doel-beta'):
            self.states[a['id']] = a['data-fm-goal-drive']
        if tag == 'form':
            self.key = a.get('data-lavish-question')
            if self.key and self.key.startswith('goal.drive.'):
                assert a['onsubmit'] == f"return mikoSend(event,'{self.key}')"
        if tag == 'input' and a.get('name') == 'a' and self.key and self.key.startswith('goal.drive.'):
            self.answers[self.key] = a['value']

    def handle_data(self, data):
        if self.status:
            self.text.append(data)

    def handle_endtag(self, tag):
        if self.status and self.status[0] == tag:
            _, item, state = self.status
            if tag == 'li':
                self.legend[state] = ''.join(self.text)
            else:
                self.labels.append((tag, item, state, ''.join(self.text)))
            self.status = None
        if tag == 'form':
            self.key = None

switches = Switches()
switches.feed(page)
assert switches.states == {'doel-alpha': 'on', 'doel-beta': 'off'}
assert set(switches.answers.values()) == {'pause alpha', 'resume beta'}
assert switches.legend == {
    'done': 'Klaar 1', 'running': 'Bezig 1', 'startable': 'Kan starten 2',
    'waiting': 'Wacht 4', 'open-captain': 'Aan jou 1', 'dropped': 'Vervallen 1',
}, switches.legend
assert sorted(switches.labels) == [
    (tag, f'alpha/{item}', 'startable', 'Kan starten')
    for tag in ('span', 'text') for item in ('check', 'orphan')
], switches.labels
assert '<strong>10</strong> taken' in page and 'conic-gradient(' in page
# Lavish TOON preserves quoted context JSON with backslash escapes, not doubled quotes.
with open(sys.argv[2], 'w') as result:
    result.write('session:\n  file: /cockpit.html\n  status: feedback\nprompts[2]{tag,text,prompt}:\n')
    writer = csv.writer(result, quoting=csv.QUOTE_ALL, escapechar='\\', doublequote=False, lineterminator='\n')
    for key, answer in switches.answers.items():
        result.write('  ')
        writer.writerow(['choice', answer, 'Context data: ' + json.dumps({'question': key, 'answer': answer})])
PY
cp "$preview" "$TMP_ROOT/goals-before.html"
python3 -I "$TOOLS/goal_drive.py" --goal-home "$GOAL_HOME" --page "$preview" || fail 'standalone rebuild failed'
cmp -s "$preview" "$TMP_ROOT/goals-before.html" || fail 'rebuild duplicated or changed goal controls'
goal apply-drive-answer "$TMP_ROOT/toggles.result" >/dev/null || fail 'apply rejected cockpit answer capture'
goal export | jq -e '([.goals[] | select(.driven) | .id] == ["beta"])' >/dev/null || fail 'both keyed answers were not applied'
pass 'cockpit goal status: six legend counts and shared WBS/rich/mini labels from export, stable rebuild'
pass 'cockpit goal switches: grey off card, 1-of-2 KPI and both keyed answers applied'

# ---- a page can show just one goal from the shared home ----
printf '%s\n' '<h2 id="doelen">Doelen</h2><div id="doel-alpha">Alpha steps</div>' \
  '<span class="fm-goal-item-status" data-fm-goal-item="alpha/check"></span>' \
  '<span class="fm-goal-item-status" data-fm-goal-item="beta/check"></span>' > "$preview"
python3 -I "$TOOLS/goal_drive.py" --goal-home "$GOAL_HOME" --page "$preview" --goal-id alpha || fail 'filtered goal-drive refresh failed'
grep -Fq 'id="doel-alpha" data-fm-goal-drive="off"' "$preview" || fail 'allowed card was not patched'
grep -Fq 'value="resume alpha"' "$preview" || fail 'allowed goal switch was not rendered'
if grep -Eq 'value="(pause|resume) beta"' "$preview"; then
  fail 'excluded goal switch was rendered'
fi
grep -Fq '0 van 1 doelen actief gedreven' "$preview" || fail 'drive KPI included the excluded goal'
grep -Fq '<strong>9</strong> taken' "$preview" || fail 'item KPI included the excluded goal'
grep -Fq 'data-fm-goal-item="alpha/check" data-fm-goal-status="waiting"' "$preview" || fail 'paused item still startable'
grep -Fq 'data-fm-goal-item="beta/check"></span>' "$preview" || fail 'excluded item label was rendered'
pass 'cockpit goal allowlist: excluded goal affects neither KPI nor item labels'
python3 -I "$TOOLS/goal_drive.py" --goal-home "$GOAL_HOME" --page "$preview" --goal-id unknown || fail 'empty selection refresh failed'
grep -Fq '<strong>0</strong> taken' "$preview" || fail 'item KPI did not render zero'
grep -Fq 'data-fm-goal-item="alpha/check"></span>' "$preview" || fail 'stale item label survived new filter'
if grep -Fq 'conic-gradient(' "$preview"; then fail 'empty ring has a segment'; fi
pass 'cockpit empty goal selection: zero total, neutral ring, no stale labels'

# ---- paths come from the environment: no MIKO_WORKTREE is a clear failure, not a stray path ----
if env -i PATH="$FAKEBIN:$PATH" HOME="$TMP_ROOT/home" TMPDIR="$SCRATCH" FM_HOME="$FM_FIX" COCKPIT_DATA_DIR="$DATA" \
  bash "$TOOLS/refresh-cockpit.sh" > "$TMP_ROOT/nowt.out" 2>&1; then
  fail "refresh ran without MIKO_WORKTREE"
fi
grep -q 'MIKO_WORKTREE' "$TMP_ROOT/nowt.out" || fail "missing-worktree message does not name MIKO_WORKTREE: $(cat "$TMP_ROOT/nowt.out")"
pass "refresh-cockpit: refuses to run without MIKO_WORKTREE"

# ---- kanban-from-wbs.py: feeding its output back in changes nothing ----
git -C "$WORK" show origin/main:apps/portal/registers/prod-gate.json > "$TMP_ROOT/prod-gate.json"
git -C "$WORK" show origin/main:apps/portal/registers/portal-states.json > "$TMP_ROOT/portal-states.json"
build_page > "$TMP_ROOT/kb-src.html"
python3 -I "$TOOLS/kanban-from-wbs.py" "$TMP_ROOT/kb-src.html" "$TMP_ROOT/kb-1.html" 08:00 "$TMP_ROOT/prod-gate.json" "$TMP_ROOT/portal-states.json" \
  > "$TMP_ROOT/kb-1.out" 2>&1 || fail "kanban-from-wbs first run failed: $(cat "$TMP_ROOT/kb-1.out")"
python3 -I "$TOOLS/kanban-from-wbs.py" "$TMP_ROOT/kb-1.html" "$TMP_ROOT/kb-2.html" 08:00 "$TMP_ROOT/prod-gate.json" "$TMP_ROOT/portal-states.json" \
  > "$TMP_ROOT/kb-2.out" 2>&1 || fail "kanban-from-wbs second run failed: $(cat "$TMP_ROOT/kb-2.out")"
! cmp -s "$TMP_ROOT/kb-src.html" "$TMP_ROOT/kb-1.html" || fail "kanban-from-wbs left the page unchanged (vacuous run)"
grep -q 'kb-mini' "$TMP_ROOT/kb-1.html" || fail "kanban-from-wbs produced no WBS cards"
cmp -s "$TMP_ROOT/kb-1.html" "$TMP_ROOT/kb-2.html" || fail "kanban-from-wbs second run changed the page"
cmp -s "$TMP_ROOT/kb-1.out" "$TMP_ROOT/kb-2.out" || fail "kanban-from-wbs summary changed on the second run"
pass "kanban-from-wbs: second run changes nothing"

# The existing refresh timer also publishes the opt-in hourly scoreboard.
python3 - "$TMP_ROOT" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = root/'score-source'
for name in ('inbox', 'pending'):
    (source/name).mkdir(parents=True)
transcript = source/'session.jsonl'
transcript.write_text('')
(root/'score-config.json').write_text(json.dumps({
    'read_only_home': str(source), 'transcripts': [str(transcript)],
    'inbox': str(source/'inbox'), 'pending_replies': str(source/'pending'),
    'task_id': 'demo', 'repo': 'demo/repo', 'goal_status': []}))
PY
printf '#!/usr/bin/env bash\nprintf "count\\t0\\n"\n' > "$FAKEBIN/gh-axi"
chmod +x "$FAKEBIN/gh-axi"
run_refresh COCKPIT_SCOREBOARD_CONFIG="$TMP_ROOT/score-config.json" > "$TMP_ROOT/score-refresh.out" 2>&1 \
  || fail "scoreboard refresh failed: $(cat "$TMP_ROOT/score-refresh.out")"
[ -s "$DATA/secondmate-scoreboard.json" ] || fail "scoreboard snapshot missing"
grep -q 'id="secondmate-scoreboard"' "$DATA/cockpit-2.html" || fail "scoreboard table not rendered"
pass "refresh-cockpit: publishes configured hourly scoreboard"

echo "all cockpit-tools tests passed"
