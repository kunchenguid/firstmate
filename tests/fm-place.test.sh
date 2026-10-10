#!/usr/bin/env bash
# Behavior tests for bin/fm-place.sh.
#
# Drives the public argv and environment interface against fixture homes:
# a placing home with config/lane-placement.json and a secondmate registry,
# two remote secondmate homes reached through the real fm-on.sh and
# fm-remote-file.sh behind a fake ssh (FM_SSH_BIN) that runs the requested
# command locally, and one local secondmate home read directly. Each home's
# state/lane-capacity.json is an fm-lane-capacity.v1 fixture. FM_PLACE_NOW pins
# the clock so the worked examples are recomputed exactly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLACE="$ROOT/bin/fm-place.sh"
TMP_ROOT=$(fm_test_tmproot fm-place)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
# Runs the fm-on.sh request locally: decodes the remote root, home, and argv,
# then executes that tracked command with FM_HOME set to the remote home.
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
root=$(decode "$4")
home=$(decode "$5")
printf '%s\n' "$1" >> "${FM_SSH_LOG:-/dev/null}"
if [ -f "$home/.unreachable" ]; then
  cat "$home/.unreachable" >&2
  exit 255
fi
[ ! -f "$home/.stall" ] || sleep 30
argv=()
while IFS= read -r -d '' a; do argv+=("$a"); done < <(decode "$6")
FM_HOME="$home" "$root/bin/${argv[0]}" "${argv[@]:1}"
SH
chmod +x "$FAKEBIN/fake-ssh"

# make_world <name>: a placing home (main), remote pc-lanes and scholar-lanes,
# and a local writeide-ux, with the Proposal's example config. Prints the dir.
make_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/main/config" "$w/main/state" "$w/main/data" "$w/pc/state" "$w/scholar/state" "$w/writeide/state"
  cat > "$w/main/data/secondmates.md" <<MD
# Secondmates
- pc-lanes - the PC lanes (host: fm-lanes; root: $ROOT; home: $w/pc; scope: engine-heavy work; projects: field-commander; added 2026-10-01)
- scholar-lanes - the scholar lanes (host: fm-scholar; root: $ROOT; home: $w/scholar; scope: engine-heavy work; projects: field-commander; added 2026-10-01)
- writeide-ux - WriteIDE UX (home: $w/writeide; scope: WriteIDE author-path UX; projects: writeide; added 2026-10-01)
MD
  cat > "$w/main/config/lane-placement.json" <<'JSON'
{
  "schema": "fm-lane-placement.v1",
  "mode": "advise",
  "homes": {
    "main":          {"rank": 3, "captain_machine": true, "tags": ["macos", "macos-signing", "webkit"]},
    "writeide-ux":   {"rank": 4, "captain_machine": true, "tags": ["macos"]},
    "pc-lanes":      {"rank": 2, "tags": ["windows-host", "gpu-nvidia"]},
    "scholar-lanes": {"rank": 1, "tags": ["windows-host", "gpu-nvidia", "laptop"]}
  },
  "profiles": {
    "default":      {"footprint_gb": 1.0},
    "engine-heavy": {"footprint_gb": 1.5},
    "macos-app":    {"footprint_gb": 2.0, "requires": ["macos"]},
    "docs":         {"footprint_gb": 0.5}
  },
  "reserve_gb": 2,
  "facts_max_age_s": 120,
  "facts_budget_s": 5,
  "min_uptime_s": 1800,
  "unstable_window_s": 21600,
  "pending_ttl_s": 600
}
JSON
  printf '%s\n' "$w"
}

# mk <home-dir> <home-id> <machine> <now> <age> <lanes> <cap> <level> <why-json>
#    <avail> <total> <runq> <uptime> <captain> <reserve-label> <min-avail> <boots-json> [jq-overlay]
# Writes that home's fm-lane-capacity.v1 document; lanes are <home>-lane-<n>.
mk() {
  jq -n --arg home "$2" --arg machine "$3" --argjson ge "$(( $4 - $5 ))" --argjson lanes "$6" --argjson cap "$7" \
    --arg level "$8" --argjson why "$9" --argjson avail "${10}" --argjson total "${11}" --argjson runq "${12}" \
    --argjson up "${13}" --arg captain "${14}" --arg reserve "${15}" --argjson minav "${16}" --argjson boots "${17}" '
  {schema: "fm-lane-capacity.v1", generated_epoch: $ge, home: $home, machine: $machine,
   lanes: {count: $lanes, pr_ready: 0, ids: [range(0; $lanes) | "\($home)-lane-\(. + 1)"]},
   cap: {target: $cap, status: "ok"}, projects: ["field-commander", "writeide"],
   pressure: {level: $level, why: $why, basis: "beat", beat_age_s: 3, avail_gb: $avail, total_gb: $total,
     runq_per_core: $runq, swap_rate_pps_1m: 0, mem_stall_pct: 0, load1: 2, on_battery: false, disks: []},
   uptime_s: $up, boot_id: "b", boots: $boots, watcher_beat_age_s: 10,
   reserve: {flag: (if $reserve == "" then "absent" else "present" end), label: (if $reserve == "" then null else $reserve end)},
   captain: $captain, quota: null, limits: {min_avail_gb: $minav, min_disk_gb: null, max_load1: null},
   verdict: {admit: ($lanes < $cap and $level == "ok" and $reserve == ""), free_lanes: ([$cap - $lanes, 0] | max),
     reasons: ([if $lanes >= $cap then "full: \($lanes) of \($cap) lanes" else empty end,
                if $level != "ok" then "pressure \($level)" else empty end,
                if $reserve != "" then "captain reserve: \($reserve)" else empty end])}}
  | '"${18:-.}" > "$1/state/lane-capacity.json"
}

# place <world> <now> [args...]: run fm-place.sh from the placing home.
place() {
  local w=$1 now=$2
  shift 2
  FM_HOME="$w/main" FM_PLACE_NOW="$now" FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_SSH_LOG="$w/ssh.log" "$PLACE" "$@" 2>"$w/stderr"
}
ROUTE=(--project field-commander --delivery no-mistakes --fitting 'pc-lanes,scholar-lanes' --fallback main)

PC_BOOTS='[1791519060,1791546360,1791555720,1791558300,1791558840]'
OLD='[1791100000]'

test_worked_examples() {
  local w out rc T
  w=$(make_world worked)

  # Example A (s1): the Mac at critical pressure, two quiet Windows homes tie.
  T=1791493200
  mk "$w/main" main maccommand $T 9 9 10 critical '["swapping 410 pages/s","memory 6% available"]' 1.0 16 5.9 400000 present "" 4 "$OLD"
  mk "$w/pc" pc-lanes homecommand-wsl $T 12 3 10 ok '[]' 22.0 31.3 0.2 260000 not-configured "" 6 "$OLD"
  mk "$w/scholar" scholar-lanes scholar-wsl $T 7 2 12 ok '[]' 18.0 25.2 0.3 90000 not-configured "" 5 "$OLD"
  out=$(place "$w" $T --task fc-castle-siege-r1 "${ROUTE[@]}" --profile engine-heavy); rc=$?
  expect_code 0 "$rc" "s1"
  assert_contains "$out" 'status: clear   mode: advise   task: fc-castle-siege-r1   project: field-commander (no-mistakes)   profile: engine-heavy 1.5 GB' "s1 header"
  assert_contains "$out" 'candidate: pc-lanes -> eligible score 74: mem 37/40 cpu 23/25 room 14/20  [lanes 3/10, 22 GB free, runq 0.2/core, facts 12 s]' "s1 pc-lanes"
  assert_contains "$out" 'candidate: scholar-lanes -> eligible score 74: mem 36/40 cpu 22/25 room 16/20  [lanes 2/12, 18 GB free, runq 0.3/core, facts 7 s]' "s1 scholar-lanes"
  assert_contains "$out" 'candidate: main (fallback) -> not eligible: pressure critical: swapping 410 pages/s; memory 6% available; no room for a 1.5 GB lane: 1 GB available, 4 GB kept' "s1 main"
  assert_contains "$out" 'note: tie at 74 broken by the fixed rank in config/lane-placement (scholar-lanes rank 1, pc-lanes rank 2)' "s1 tie"
  assert_contains "$out" 'place: scholar-lanes' "s1 place"
  assert_contains "$out" 'log: 1791493200-fc-castle-siege-r1' "s1 log id"
  cp "$w/main/config/lane-placement.json" "$w/policy.saved"
  jq '.homes["pc-lanes"].rank = 1' "$w/policy.saved" > "$w/main/config/lane-placement.json"
  out=$(place "$w" $T --task fc-castle-siege-r1b "${ROUTE[@]}" --profile engine-heavy)
  assert_contains "$out" 'note: tie at 74 broken by the home id (pc-lanes and scholar-lanes both rank 1)' "s1 equal-rank tie"
  assert_contains "$out" 'place: pc-lanes' "s1 equal-rank tie goes to the lower home id"
  cp "$w/policy.saved" "$w/main/config/lane-placement.json"

  # Example B (s2a-s2d): the PC's WSL rebooting with its real boot times.
  T=1791558810
  mk "$w/main" main maccommand $T 6 10 10 ok '[]' 4.5 16 1.1 400000 present "" 4 "$OLD"
  echo "ssh: connect to host fm-lanes port 22: Connection timed out" > "$w/pc/.unreachable"
  mk "$w/scholar" scholar-lanes scholar-wsl $T 4 12 12 ok '[]' 13.11 25.2 0.94 86599 not-configured "" 5 "$OLD"
  out=$(place "$w" $T --task fc-commander-rank-r2 "${ROUTE[@]}" --profile engine-heavy)
  assert_contains "$out" 'status: ambiguous' "s2a status"
  assert_contains "$out" 'candidate: pc-lanes -> unknown: facts unreachable (exit 255)' "s2a pc unreachable"
  assert_contains "$(cat "$w/stderr")" 'fm-place: pc-lanes: fm-on.sh exit 255: ssh: connect to host fm-lanes port 22: Connection timed out' "s2a ssh detail on stderr"
  assert_not_contains "$(cat "$w/main/state/lane-placement.jsonl")" 'fm-lanes port 22' "s2a ssh detail never logged"
  assert_contains "$out" 'candidate: scholar-lanes -> not eligible: full: 12 of 12 lanes' "s2a scholar full"
  assert_contains "$out" 'candidate: main (fallback) -> not eligible: full: 10 of 10 lanes; no room for a 1.5 GB lane: 4.5 GB available, 4 GB kept' "s2a main"
  assert_contains "$out" 'reason: no home is rankable on known facts (pc-lanes: facts unreachable (exit 255)); every other home is refused; decide as today' "s2a reason names each unknown home"
  assert_not_contains "$out" 'place:  ' "s2a has no place"
  rm -f "$w/pc/.unreachable"

  T=1791559516
  mk "$w/main" main maccommand $T 6 10 10 ok '[]' 4.5 16 1.1 400000 present "" 4 "$OLD"
  mk "$w/pc" pc-lanes homecommand-wsl $T 3 0 10 ok '[]' 27.5 31.3 0.1 676 not-configured "" 6 "$PC_BOOTS"
  mk "$w/scholar" scholar-lanes scholar-wsl $T 4 10 12 ok '[]' 13.11 25.2 0.94 86599 not-configured "" 5 "$OLD"
  out=$(place "$w" $T --task fc-commander-rank-r3 "${ROUTE[@]}" --profile engine-heavy)
  assert_contains "$out" 'candidate: pc-lanes -> not eligible: booted 11 min ago (warming); unstable: restarted 4 times in 6 h' "s2b pc warming and unstable"
  assert_contains "$out" 'candidate: scholar-lanes -> eligible score 40: mem 20/40 cpu 17/25 room 3/20  [lanes 10/12, 13.11 GB free, runq 0.94/core, facts 4 s]' "s2b scholar"
  assert_contains "$out" 'place: scholar-lanes' "s2b place"

  T=1791567000
  mk "$w/main" main maccommand $T 6 10 10 ok '[]' 4.5 16 1.1 400000 present "" 4 "$OLD"
  mk "$w/pc" pc-lanes homecommand-wsl $T 3 2 10 ok '[]' 25.0 31.3 0.3 8160 not-configured "" 6 "$PC_BOOTS"
  mk "$w/scholar" scholar-lanes scholar-wsl $T 4 9 12 ok '[]' 13.11 25.2 0.94 86599 not-configured "" 5 "$OLD"
  out=$(place "$w" $T --task fc-rts-8p-seats-r2 "${ROUTE[@]}" --profile engine-heavy)
  assert_contains "$out" 'candidate: pc-lanes -> not eligible: unstable: restarted 4 times in 6 h' "s2c pc unstable"
  assert_contains "$out" 'candidate: scholar-lanes -> eligible score 42: mem 20/40 cpu 17/25 room 5/20  [lanes 9/12, 13.11 GB free, runq 0.94/core, facts 4 s]' "s2c scholar"
  assert_contains "$out" 'place: scholar-lanes' "s2c place"

  T=1791581400
  mk "$w/main" main maccommand $T 6 10 10 ok '[]' 4.5 16 1.1 400000 present "" 4 "$OLD"
  mk "$w/pc" pc-lanes homecommand-wsl $T 3 2 10 ok '[]' 25.0 31.3 0.3 22560 not-configured "" 6 "$PC_BOOTS"
  mk "$w/scholar" scholar-lanes scholar-wsl $T 4 9 12 ok '[]' 13.11 25.2 0.94 86599 not-configured "" 5 "$OLD"
  out=$(place "$w" $T --task fc-rts-8p-seats-r3 "${ROUTE[@]}" --profile engine-heavy)
  assert_contains "$out" 'candidate: pc-lanes -> eligible score 78: mem 40/40 cpu 22/25 room 16/20  [lanes 2/10, 25 GB free, runq 0.3/core, facts 3 s]' "s2d pc after six quiet hours"
  assert_contains "$out" 'place: pc-lanes' "s2d place"

  # Example C (s3a, s3b): the captain at the Mac, the tower reserved, scholar full.
  T=1791599400
  mk "$w/main" main maccommand $T 5 4 10 ok '[]' 5.5 16 0.6 400000 present "" 4 "$OLD"
  mk "$w/pc" pc-lanes homecommand-wsl $T 3 0 10 ok '[]' 28.0 31.3 0.1 60000 not-configured "tower reserved by the captain" 6 "$PC_BOOTS"
  mk "$w/scholar" scholar-lanes scholar-wsl $T 4 12 12 ok '[]' 9.8 25.2 1.2 120000 not-configured "" 5 "$OLD"
  out=$(place "$w" $T --task writeide-docs-r1 "${ROUTE[@]}" --profile docs)
  assert_contains "$out" 'candidate: pc-lanes -> not eligible: captain-reserve' "s3a pc reserved"
  assert_not_contains "$(cat "$w/main/state/lane-placement.jsonl")" 'tower reserved' "s3a reserve label never logged"
  assert_contains "$out" 'candidate: main (fallback) -> eligible score 22: mem 5/40 cpu 20/25 room 12/20 captain -15  [lanes 4/10, 5.5 GB free, runq 0.6/core, facts 5 s]' "s3a main with the captain term"
  assert_contains "$out" 'note: every fitting home is blocked (pc-lanes: captain-reserve; scholar-lanes: full: 12 of 12 lanes); main is the fallback' "s3a fallback note"
  assert_contains "$out" 'place: main' "s3a place"

  mk "$w/main" main maccommand $T 5 4 10 ok '[]' 4.8 16 0.6 400000 present "" 4 "$OLD"
  out=$(place "$w" $T --task writeide-docs-r2 "${ROUTE[@]}" --profile engine-heavy)
  assert_contains "$out" 'status: full' "s3b status"
  assert_contains "$out" 'candidate: main (fallback) -> not eligible: no room for a 1.5 GB lane: 4.8 GB available, 4 GB kept' "s3b main no room"
  assert_contains "$out" 'reason: every in-scope home is full, under pressure or reserved; keep the item queued and re-evaluate at the next teardown or heartbeat' "s3b reason"

  out=$(place "$w" $T --task writeide-docs-r3 "${ROUTE[@]}" --profile engine-heavy --captain scholar-lanes)
  assert_contains "$out" 'status: captain' "captain status"
  assert_contains "$out" 'note: facts for the captain'"'"'s choice, for the record only: full: 12 of 12 lanes' "captain facts note"
  assert_contains "$out" 'place: scholar-lanes' "captain place"

  # Edge cases (6.5) on the s3a facts.
  mk "$w/main" main maccommand $T 5 4 10 ok '[]' 5.5 16 0.6 400000 present "" 4 "$OLD"
  out=$(place "$w" $T --task fleet-notes-r1 --project field-commander --delivery no-mistakes --fitting scholar-lanes --fallback main --profile docs --requires macos)
  assert_contains "$out" 'candidate: scholar-lanes -> not eligible: lacks macos; full: 12 of 12 lanes' "requires tag"
  assert_contains "$out" 'place: main' "requires tag place"
  out=$(place "$w" $T --task main-lane-2 --project field-commander --delivery no-mistakes --fitting scholar-lanes --fallback main --profile docs)
  assert_contains "$out" 'status: error' "already running status"
  assert_contains "$out" 'candidate: main (fallback) -> error: task main-lane-2 already runs here: placement is for new lanes only' "already running candidate"
  out=$(place "$w" $T --task notes-sweep --project field-commander --delivery local-only --fitting scholar-lanes --fallback main --profile docs)
  assert_contains "$out" 'candidate: scholar-lanes -> not eligible: local-only work stays in the main home' "local-only refusal"
  assert_contains "$out" 'note: local-only work stays in the main home' "local-only note"
  assert_contains "$out" 'place: main' "local-only place"
  pass "the Proposal's worked examples recompute to the same placements"
}

test_off_and_kill_switches() {
  local w out rc
  w=$(make_world off)
  out=$(FM_PLACE=off place "$w" 1791493200 --task t1 "${ROUTE[@]}"); rc=$?
  expect_code 0 "$rc" "FM_PLACE=off"
  assert_equals "" "$out" "FM_PLACE=off prints nothing on stdout"
  assert_grep 'place: off (FM_PLACE=off)' "$w/stderr" "FM_PLACE=off line"
  jq '.mode = "off"' "$w/main/config/lane-placement.json" > "$w/p" && mv "$w/p" "$w/main/config/lane-placement.json"
  out=$(place "$w" 1791493200 --task t1 "${ROUTE[@]}"); rc=$?
  expect_code 0 "$rc" "mode off"
  assert_equals "" "$out" "mode off prints nothing on stdout"
  assert_grep 'place: off (mode off in config/lane-placement.json)' "$w/stderr" "mode off line"
  rm -f "$w/main/config/lane-placement.json"
  out=$(place "$w" 1791493200 --task t1 "${ROUTE[@]}"); rc=$?
  expect_code 0 "$rc" "absent config"
  assert_equals "" "$out" "absent config prints nothing on stdout"
  assert_grep 'place: off (config/lane-placement.json absent)' "$w/stderr" "absent config line"
  assert_absent "$w/main/state/lane-placement.jsonl" "off writes no decision log"
  assert_absent "$w/ssh.log" "off reads no remote home"
  pass "off, FM_PLACE=off, and an absent config print one stderr line and read nothing"
}

test_usage_and_config_errors() {
  local w rc cfg base nojq
  w=$(make_world errors)
  cfg="$w/main/config/lane-placement.json"
  base=$(cat "$cfg")
  expect_err() {  # <label> <expected stderr fragment> <args...>
    local label=$1 fragment=$2 out rc
    shift 2
    out=$(place "$w" 1791493200 "$@"); rc=$?
    expect_code 2 "$rc" "$label"
    assert_equals "" "$out" "$label prints nothing on stdout"
    assert_grep "$fragment" "$w/stderr" "$label names the problem"
  }
  expect_err "unknown flag" "unknown argument --bogus" --task t1 "${ROUTE[@]}" --bogus
  expect_err "unregistered home" "unknown home 'nowhere'" --task t1 --project field-commander --delivery no-mistakes --fitting nowhere
  expect_err "bad delivery" "--delivery must be" --task t1 --project field-commander --delivery yolo --fitting pc-lanes
  expect_err "unknown profile" "profile 'huge' is not declared" --task t1 "${ROUTE[@]}" --profile huge
  expect_err "missing task" "--task is required" "${ROUTE[@]}"
  expect_err "empty home" "--fitting holds an empty home" --task t1 --project field-commander --delivery no-mistakes --fitting pc-lanes,,scholar-lanes
  printf '%s' "$base" | jq 'del(.homes["writeide-ux"])' > "$cfg"
  expect_err "home not declared" "home 'writeide-ux' is not declared in config/lane-placement.json" \
    --task t1 --project field-commander --delivery no-mistakes --fitting writeide-ux
  printf '{not json' > "$cfg"
  expect_err "malformed config" "config/lane-placement.json is not valid JSON" --task t1 "${ROUTE[@]}"
  printf '%s' "$base" | jq '.weights = {}' > "$cfg"
  expect_err "unknown member" "unknown member weights" --task t1 "${ROUTE[@]}"
  printf '%s' "$base" | jq '.mode = "enforce"' > "$cfg"
  expect_err "enforce mode" "mode enforce is not available in this version" --task t1 "${ROUTE[@]}"
  printf '%s' "$base" | jq '.homes.main.rank = "first"' > "$cfg"
  expect_err "bad rank" "rank must be a non-negative integer" --task t1 "${ROUTE[@]}"
  printf '%s' "$base" | jq '.pending_ttl_s = 0' > "$cfg"
  expect_err "bad number" "must be positive integers" --task t1 "${ROUTE[@]}"
  printf '%s' "$base" > "$cfg"
  nojq="$TMP_ROOT/no-jq-bin"
  mkdir -p "$nojq"
  for c in bash date dirname cat; do ln -sf "$(command -v "$c")" "$nojq/$c"; done
  FM_HOME="$w/main" FM_PLACE_NOW=1791493200 PATH="$nojq" "$PLACE" --task t1 "${ROUTE[@]}" >/dev/null 2>"$w/stderr"; rc=$?
  expect_code 2 "$rc" "missing jq"
  assert_grep 'jq required' "$w/stderr" "missing jq is named"
  pass "usage and configuration errors exit 2 and are never selected around"
}

# base_facts <world> <now>: three quiet homes with room.
base_facts() {
  mk "$1/main" main maccommand "$2" 5 2 10 ok '[]' 10 16 0.5 400000 idle "" 4 "$OLD"
  mk "$1/pc" pc-lanes homecommand-wsl "$2" 5 2 10 ok '[]' 20 31.3 0.3 260000 not-configured "" 6 "$OLD"
  mk "$1/scholar" scholar-lanes scholar-wsl "$2" 5 2 12 ok '[]' 18 25.2 0.3 90000 not-configured "" 5 "$OLD"
}

test_filters() {
  local w out T=1791600000
  w=$(make_world filters)
  base_facts "$w" $T
  check() {  # <label> <home-dir> <home-id> <overlay> <expected candidate text> [extra args]
    local label=$1 dir=$2 id=$3 overlay=$4 expected=$5 out
    shift 5
    cp "$w/$dir/state/lane-capacity.json" "$w/saved.json"
    jq "$overlay" "$w/saved.json" > "$w/$dir/state/lane-capacity.json"
    out=$(place "$w" $T --task f-$RANDOM --project field-commander --delivery no-mistakes --fitting "$id" "$@")
    assert_contains "$out" "candidate: $id -> $expected" "$label"
    cp "$w/saved.json" "$w/$dir/state/lane-capacity.json"
  }
  check "no clone" pc pc-lanes '.projects = ["writeide"]' 'not eligible: no field-commander clone in this home'
  check "on battery" pc pc-lanes '.pressure.on_battery = true' 'not eligible: on battery'
  check "invalid cap" pc pc-lanes '.cap = {target: null, status: "invalid"}' 'not eligible: its config/lane-capacity is unreadable'
  check "quota exhausted" pc pc-lanes '.quota = {provider: "claude", runway: "exhausted_now"}' 'not eligible: quota exhausted now'
  check "quota tight" pc pc-lanes '.quota = {provider: "claude", runway: "projected_exhaustion"}' 'eligible score 61: mem 33/40 cpu 22/25 room 16/20 quota -10'
  check "warn pressure" pc pc-lanes '.pressure.level = "warn" | .pressure.why = ["memory stall 12%"]' 'not eligible: pressure warn: memory stall 12%'
  check "own verdict" pc pc-lanes '.verdict = {admit: false, free_lanes: 0, reasons: ["load: 24.7 over its max-load1 20"]}' 'not eligible: its own verdict: load: 24.7 over its max-load1 20'
  check "one restart" pc pc-lanes '.boots = [.generated_epoch - 7200]' 'eligible score 61: mem 33/40 cpu 22/25 room 16/20 unstable -10'
  check "stale facts" pc pc-lanes '.generated_epoch -= 600' 'unknown: facts 605 s old (home not publishing)'
  check "clock skew" pc pc-lanes '.generated_epoch += 300' 'unknown: facts dated 295 s in the future: clock skew'
  check "watcher down" pc pc-lanes '.watcher_beat_age_s = 900' 'unknown: watcher beat 900 s old (home not supervising)'
  check "foreign home" pc pc-lanes '.home = "scholar-lanes"' 'unknown: facts name home scholar-lanes, not pc-lanes'
  check "foreign schema" pc pc-lanes '.schema = "lookout.beat"' 'unknown: facts unreadable: not an fm-lane-capacity.v1 document'
  check "unknown pressure" pc pc-lanes '.pressure.level = "unknown" | .pressure.basis = "none"' 'eligible, unranked: pressure unknown (none)'
  check "no cap" pc pc-lanes '.cap = {target: null, status: "none"}' 'eligible, unranked: no lane cap declared'
  check "captain idle" main main '.' 'eligible score 56: mem 25/40 cpu 20/25 room 16/20 captain -5'

  printf '{"schema":' > "$w/pc/state/lane-capacity.json"
  out=$(place "$w" $T --task f-malformed --project field-commander --delivery no-mistakes --fitting pc-lanes)
  assert_contains "$out" 'candidate: pc-lanes -> unknown: facts unreadable: not JSON' "malformed facts"
  rm -f "$w/pc/state/lane-capacity.json"
  out=$(place "$w" $T --task f-missing --project field-commander --delivery no-mistakes --fitting pc-lanes)
  assert_contains "$out" 'candidate: pc-lanes -> unknown: no published facts: missing (exit 1)' "remote home not publishing"
  assert_contains "$out" 'status: ambiguous' "only an unknown home is ambiguous"
  base_facts "$w" $T

  # The local secondmate is read from its registered home, never over ssh.
  : > "$w/ssh.log"
  mk "$w/writeide" writeide-ux maccommand $T 5 1 2 ok '[]' 10 16 0.5 400000 idle "" 4 "$OLD"
  out=$(place "$w" $T --task f-local --project writeide --delivery no-mistakes --fitting writeide-ux)
  assert_contains "$out" 'candidate: writeide-ux -> eligible score 50: mem 25/40 cpu 20/25 room 10/20 captain -5' "local secondmate facts"
  assert_equals "" "$(cat "$w/ssh.log")" "a local secondmate is never read over ssh"

  # Permanent refusals everywhere escalate; an unranked fitting home is ambiguous.
  out=$(place "$w" $T --task f-esc --project field-commander --delivery no-mistakes --fitting pc-lanes,scholar-lanes --requires macos)
  assert_contains "$out" 'status: escalate' "permanent refusals escalate"
  assert_contains "$out" 'reason: no in-scope home can run this lane' "escalate reason"
  jq '.pressure.level = "unknown" | .pressure.basis = "none"' "$w/scholar/state/lane-capacity.json" > "$w/s.json" && mv "$w/s.json" "$w/scholar/state/lane-capacity.json"
  out=$(place "$w" $T --task f-amb "${ROUTE[@]}")
  assert_contains "$out" 'place: pc-lanes' "an eligible fitting home wins over an unranked one"
  out=$(place "$w" $T --task f-amb2 --project field-commander --delivery no-mistakes --fitting scholar-lanes --fallback main)
  assert_contains "$out" 'status: ambiguous' "an unranked fitting home is not skipped for the fallback"
  assert_contains "$out" 'reason: a fitting home is not rankable on known facts (scholar-lanes: pressure unknown (none)); decide as today' "unranked reason"
  pass "every filter refuses, discloses, or ranks with its plain reason"
}

test_pending_and_outcome() {
  local w out rc T=1791600000
  w=$(make_world pending)
  base_facts "$w" $T
  mk "$w/pc" pc-lanes homecommand-wsl $T 5 9 10 ok '[]' 20 31.3 0.3 260000 not-configured "" 6 "$OLD"
  out=$(place "$w" $T --task p1 --project field-commander --delivery no-mistakes --fitting pc-lanes)
  assert_contains "$out" 'place: pc-lanes' "pc-lanes has one place left"
  out=$(FM_HOME="$w/main" FM_PLACE_NOW=$((T + 10)) "$PLACE" outcome p1 pc-lanes); rc=$?
  expect_code 0 "$rc" "outcome recorded"
  assert_contains "$out" 'place-outcome: recorded p1 -> pc-lanes by firstmate (followed: yes)' "outcome followed"
  printf '{"v":1,"ts":\n' >> "$w/main/state/lane-placement.jsonl"
  out=$(place "$w" $((T + 20)) --task p2 --project field-commander --delivery no-mistakes --fitting pc-lanes)
  assert_contains "$out" 'candidate: pc-lanes -> not eligible: full: 9+1 pending of 10 lanes' "a recent outcome holds a pending lane past a torn log line"
  assert_contains "$out" 'status: full' "the pending lane fills the home"
  jq '.lanes.count = 10 | .lanes.ids += ["p1"]' "$w/pc/state/lane-capacity.json" > "$w/p.json" && mv "$w/p.json" "$w/pc/state/lane-capacity.json"
  out=$(place "$w" $((T + 30)) --task p3 --project field-commander --delivery no-mistakes --fitting pc-lanes)
  assert_contains "$out" 'not eligible: full: 10 of 10 lanes' "a started lane is counted once, not as pending too"
  mk "$w/pc" pc-lanes homecommand-wsl $((T + 700)) 5 9 10 ok '[]' 20 31.3 0.3 260000 not-configured "" 6 "$OLD"
  out=$(place "$w" $((T + 700)) --task p4 --project field-commander --delivery no-mistakes --fitting pc-lanes)
  assert_contains "$out" 'place: pc-lanes' "a pending lane expires after pending_ttl_s"

  out=$(FM_HOME="$w/main" FM_PLACE_NOW=$((T + 710)) "$PLACE" outcome p4 scholar-lanes --by captain --reason 'the captain wants it on scholar')
  assert_contains "$out" 'recorded p4 -> scholar-lanes by captain (followed: no)' "an override is recorded"
  out=$(FM_HOME="$w/main" FM_PLACE_NOW=$((T + 720)) "$PLACE" outcome unadvised main)
  assert_contains "$out" '(followed: no advice)' "an outcome with no advice"
  tail -n 1 "$w/main/state/lane-placement.jsonl" | jq -e '.event == "place.outcome" and .followed == null and .id == null' >/dev/null \
    || fail "an unadvised outcome must log followed and id as null"
  FM_HOME="$w/main" "$PLACE" outcome p4 nowhere >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "outcome for an unknown home"
  FM_HOME="$w/main" "$PLACE" outcome p4 main --by robot >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "outcome with a bad --by"
  pass "outcomes record the choice, and recent ones hold pending lanes"
}

test_unreachable_budget_and_log() {
  local w out rc T=1791600000 mode
  w=$(make_world reach)
  base_facts "$w" $T
  jq '.facts_budget_s = 1' "$w/main/config/lane-placement.json" > "$w/c" && mv "$w/c" "$w/main/config/lane-placement.json"
  touch "$w/scholar/.stall"
  out=$(place "$w" $T --task r1 "${ROUTE[@]}"); rc=$?
  expect_code 0 "$rc" "a stalled home"
  assert_contains "$out" 'candidate: scholar-lanes -> unknown: facts unreachable: timeout after 1 s (exit 124)' "the budget bounds a stalled read"
  assert_contains "$out" 'candidate: pc-lanes -> eligible score 71' "a stalled home does not block the others"
  rm -f "$w/scholar/.stall"
  out=$(place "$w" $((T + 60)) --task r2 --project field-commander --delivery no-mistakes --fitting scholar-lanes)
  assert_contains "$out" 'room 16/20 unstable -10' "a read that ran out of budget counts as a failed read"
  echo "ssh: connect to host fm-scholar port 22: No route to host" > "$w/scholar/.unreachable"
  place "$w" $((T + 120)) --task r3 --project field-commander --delivery no-mistakes --fitting scholar-lanes >/dev/null
  rm -f "$w/scholar/.unreachable"
  mk "$w/scholar" scholar-lanes scholar-wsl $((T + 180)) 5 2 12 ok '[]' 18 25.2 0.3 90000 not-configured "" 5 "$OLD"
  out=$(place "$w" $((T + 180)) --task r4 --project field-commander --delivery no-mistakes --fitting scholar-lanes)
  assert_contains "$out" 'candidate: scholar-lanes -> eligible score 66: mem 38/40 cpu 22/25 room 16/20 unstable -10' "a recent failed read costs 10"
  mk "$w/scholar" scholar-lanes scholar-wsl $((T + 180 + 21600)) 5 2 12 ok '[]' 18 25.2 0.3 90000 not-configured "" 5 "$OLD"
  out=$(place "$w" $((T + 180 + 21600)) --task r4b --project field-commander --delivery no-mistakes --fitting scholar-lanes 2>/dev/null)
  assert_not_contains "$out" 'unstable' "failed reads older than unstable_window_s are forgotten"

  base_facts "$w" $((T + 180))
  out=$(place "$w" $((T + 180)) --task r5 "${ROUTE[@]}" --json)
  printf '%s' "$out" | jq -e '.event == "place.advice" and .status == "clear" and (.candidates | length) == 3 and (.facts_ms | type) == "number"' >/dev/null \
    || fail "--json must print the advice object: $out"
  assert_equals "$out" "$(tail -n 1 "$w/main/state/lane-placement.jsonl")" "--json prints exactly the logged line"
  mode=$(stat -c %a "$w/main/state/lane-placement.jsonl" 2>/dev/null || stat -f %Lp "$w/main/state/lane-placement.jsonl")
  assert_equals 600 "$mode" "the decision log is private"

  head -c 5300000 /dev/zero | tr '\0' 'x' > "$w/main/state/lane-placement.jsonl"
  place "$w" $((T + 190)) --task r6 "${ROUTE[@]}" >/dev/null
  assert_present "$w/main/state/lane-placement.jsonl.1" "a log past 5 MB is rotated"
  assert_equals 1 "$(wc -l < "$w/main/state/lane-placement.jsonl" | tr -d ' ')" "a rotated log starts fresh"

  mv "$w/main/state/lane-placement.jsonl" "$w/real.jsonl"
  ln -s "$w/real.jsonl" "$w/main/state/lane-placement.jsonl"
  out=$(place "$w" $((T + 200)) --task r7 "${ROUTE[@]}"); rc=$?
  expect_code 0 "$rc" "an unwritable log"
  assert_contains "$out" 'log: unwritten (the log is a symlink)' "the advice still prints without a log"
  assert_contains "$out" 'place: scholar-lanes' "the advice is unchanged without a log"
  pass "unreachable and stalled homes are unknown, and the log is private, rotated, and optional"
}

test_review() {
  local w out rc T=1791600000
  w=$(make_world review)
  FM_HOME="$w/main" FM_PLACE_NOW=$T "$PLACE" review >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "review with no log"
  base_facts "$w" $T
  place "$w" $T --task v1 "${ROUTE[@]}" >/dev/null
  FM_HOME="$w/main" FM_PLACE_NOW=$((T + 5)) "$PLACE" outcome v1 scholar-lanes >/dev/null
  mk "$w/pc" pc-lanes homecommand-wsl $((T + 10)) 5 10 10 ok '[]' 20 31.3 0.3 260000 not-configured "" 6 "$OLD"
  place "$w" $((T + 10)) --task v2 "${ROUTE[@]}" >/dev/null
  FM_HOME="$w/main" FM_PLACE_NOW=$((T + 15)) "$PLACE" outcome v2 pc-lanes --reason 'kept with its sibling lane' >/dev/null
  out=$(FM_HOME="$w/main" FM_PLACE_NOW=$((T + 20)) "$PLACE" review); rc=$?
  expect_code 0 "$rc" "review"
  assert_contains "$out" 'span: 14 d   advice: 2   outcomes: 2' "review counts"
  assert_contains "$out" 'status: clear 2' "review status counts"
  assert_contains "$out" 'agreement: 1 of 2 followed (50%)' "review agreement"
  assert_contains "$out" 'override: v2 advised scholar-lanes chose pc-lanes by firstmate' "review override"
  assert_not_contains "$(cat "$w/main/state/lane-placement.jsonl")" 'sibling lane' "outcome reason text never logged"
  tail -n 1 "$w/main/state/lane-placement.jsonl" | jq -e '.outcome == "override" and (has("reason") | not)' >/dev/null \
    || fail "an override outcome must log the fixed code only"
  assert_contains "$out" 'home: pc-lanes   advised 0   chosen 1   listed 2   unknown 0 (unreachable 0)   refused: full 1' "review per home"
  out=$(FM_HOME="$w/main" FM_PLACE_NOW=$((T + 20)) "$PLACE" review --json)
  printf '%s' "$out" | jq -e '.advice == 2 and .agreement.followed == 1 and (.overrides | length) == 1' >/dev/null \
    || fail "review --json must carry the same report: $out"
  out=$(FM_HOME="$w/main" FM_PLACE_NOW=$((T + 30 * 86400)) "$PLACE" review --since 7d)
  assert_contains "$out" 'advice: 0   outcomes: 0' "the span excludes old lines"
  FM_HOME="$w/main" "$PLACE" review --since soon >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "review with a bad span"
  pass "review reports agreement, overrides, and per-home refusals over its span"
}

test_worked_examples
test_off_and_kill_switches
test_usage_and_config_errors
test_filters
test_pending_and_outcome
test_unreachable_budget_and_log
test_review
echo "# all fm-place tests passed"
