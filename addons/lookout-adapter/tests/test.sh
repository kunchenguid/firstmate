#!/usr/bin/env bash
# Fixture-home test for lookout-firstmate: builds a throwaway FM_HOME with the dashboard builder's output files, then checks the
# document (every list, no secret from a lane's .meta), the Lookout contract check when LOOKOUT_DIR holds a lookout clone, and the
# HTTP source. Usage: lookout-adapter/tests/test.sh
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"; trap 'kill "${srv:-}" 2>/dev/null || true; rm -rf -- "$t"' EXIT
mkdir -p "$t/home/state/dashboard" "$t/home/data" "$t/main2/state" "$t/proc"
now=1792852545
printf 'MemTotal: 1000 kB\nMemAvailable: 400 kB\n' > "$t/proc/meminfo"; echo '0.50 0.4 0.3 1/2 3' > "$t/proc/loadavg"
echo "- alpha - Owns alpha. (home: $t/main2; scope: x)" > "$t/home/data/secondmates.md"
printf 'model=claude-sonnet-5-5\nharness=claude\naccount=pa_fixture\napi_key=SECRET-VALUE-123\n' > "$t/main2/state/a-one.meta"
cat > "$t/home/state/dashboard/data.json" <<J
{"cutoff":$now,"build_time":"2026-10-24T18:35:45+04:00","machine":{"pressure":50},"machine_limits":{"memory_pressure":40,"emulators":2,"gradle":2},
 "metrics":{"emulators":{"value":1},"gradle_builds":{"value":0}},
 "homes":[{"home":"main","plan":4,"lead_state":"","summary_generated_epoch":$((now-60))},{"home":"alpha","plan":2,"lead_state":"Lead is working","summary_generated_epoch":$((now-2000))}],
 "agents":[{"role":"worker","home":"alpha","name":"a-one","status":"working"},{"role":"worker","home":"alpha","name":"a-two","status":"done"},{"role":"lead","home":"alpha","name":"alpha","status":"idle"}],
 "quota_accounts":[{"name":"Codex","windows":[{"label":"week","used":60,"reset":"2026-10-29T21:59:59+04:00","runout":"2026-10-25T11:03:03+04:00"}]}],
 "claude_accounts":[{"name":"acct-b","five_hour":{"left":59,"resets_at":"2026-10-24T18:30:00+00:00"},"seven_day":{"left":15,"resets_at":"2026-10-29T07:00:00+00:00"}}],
 "lane_history":[{"at":$((now-3600)),"lanes":5,"stuck":1}],"devices":[{"name":"Phone X1","tone":"ok","holder":null},{"name":"Emulator e1","tone":"ok","holder":"alpha"}]}
J
cat > "$t/home/state/dashboard/board.json" <<J
{"homes":[{"id":"alpha","name":"Alpha"}],"tickets":[{"id":"alpha/a-one","project":"alpha-app"}],
 "cards":[{"id":"alpha/a-one","home":"alpha","title":"First lane\n... (truncated)","stage":"ci","state":"waiting","since":$((now-100)),"started":$((now-900)),"pr":"https://github.com/o/r/pull/1","wait":"CI"},
          {"id":"alpha/a-two","home":"alpha","title":"Second","stage":"building","state":"blocked","since":$((now-50)),"started":null,"pr":null,"wait":null},
          {"id":"alpha/finished","home":"alpha","title":"Awaiting merge","stage":"merge","state":"finished","since":$now,"pr":null},
          {"id":"alpha/backlog-item","home":"alpha","title":"Ready item","stage":"queued","state":"queued","since":$now,"pr":null},
          {"id":"ghost/x","home":"ghost","title":"Unknown home","stage":"queued","state":"queued","since":$now,"pr":null}],
 "flow":{"lanes":[{"home":"alpha","task":"a-one","display_title":"Merged one","pr":"https://github.com/o/r/pull/1","times":{"merged":$((now-7200)),"dispatched":$((now-9000))}},
                  {"home":"alpha","task":"old","pr":"https://github.com/o/r/pull/0","times":{"merged":$((now-40*86400))}}]}}
J
out="$t/fleet.json"
"$here/lookout-firstmate" --home "$t/home" --no-build --proc "$t/proc" > "$out"
python3 - "$out" <<'P'
import json, sys
d = json.load(open(sys.argv[1])); raw = open(sys.argv[1]).read()
assert 'SECRET' not in raw, 'a .meta secret reached the document'
assert d['schema'] == 'lookout.fleet.v1'
h = d['hosts'][0]; assert h['mem_pct'] == 60.0 and h['gate'] == {'state': 'closed', 'limit_pct': 40} and h['jobs'][0] == {'kind': 'emulator', 'running': 1, 'limit': 2}, h
assert [x['supervision']['state'] for x in d['homes']] == ['ok', 'stale'], d['homes']
assert [l['stage'] for l in d['lanes']] == ['review', 'working', 'done'] and [l['stuck'] for l in d['lanes']] == [False, True, False], d['lanes']  # a finished lane holds no worker
assert d['lanes'][0]['title'] == 'First lane' and d['lanes'][0]['project'] == 'alpha-app' and d['lanes'][0]['waiting_on'] == 'CI'
w = d['workers']; assert len(w) == 2 and w[0]['account'] == 'pa_fixture' and w[0]['agent'] == 'claude' and w[1]['state'] == 'exited', w
assert {(q['account'], q['window']) for q in d['quota']} == {('Codex', 'week'), ('acct-b', '5h'), ('acct-b', 'week')}
assert [m['title'] for m in d['merges']] == ['Merged one'] and d['merges'][0]['lane'] == 'alpha/a-one', d['merges']
assert len(d['history']) == 1 and [x['state'] for x in d['devices']] == ['free', 'busy'], d['devices']
P
if [ -n "${LOOKOUT_DIR:-}" ] && command -v node >/dev/null; then
  node --input-type=module -e "import { validateFleet } from '$LOOKOUT_DIR/lib/contract.js'; import fs from 'node:fs'; const p = validateFleet(JSON.parse(fs.readFileSync('$out', 'utf8'))); if (p.length) { console.error(p.join('\n')); process.exit(1) }"
  echo "contract: valid"
else echo "contract: skipped (set LOOKOUT_DIR to a lookout clone)"; fi
"$here/lookout-firstmate" --home "$t/home" --no-build --proc "$t/proc" --serve --port 0 --every 1 > "$t/serve.log" & srv=$!
for _ in $(seq 50); do grep -q serving "$t/serve.log" && break; sleep 0.1; done
url="$(sed 's/.*serving //' "$t/serve.log")"
first="$(curl -fsS "$url")"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["name"] == "Firstmate fleet"' "$first"
rm "$t/home/state/dashboard/data.json"; sleep 2.5  # the rebuild fails now: the last good snapshot is still served, at once, unchanged
[ "$(curl -fsS -m 2 "$url")" = "$first" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' "${url%fleet.json}nope")" = 404 ]
echo "lookout-firstmate: PASS"
