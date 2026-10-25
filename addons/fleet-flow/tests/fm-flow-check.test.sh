#!/usr/bin/env bash
# Integration test for fleet-flow/bin/fm-flow-check.sh over a fixture Main home and one muxr home.
# Stub fm-tasks-axi.sh and fm-crew-state.sh in the fixture Main's bin/ stand in for the fork.
# Proves: parked lanes (lane-cap park resumes, unnamed park is STALLED); a 5 h external-wait lane (paused or failed) stops counting toward the cap, a 3 h one,
# a working one, a captain-held one and a 5 h one that has resumed still count; paused lanes and long
# blocked or failed waits are probed; --can-start frees the slot; --summary prints dry=1 and dry=0.
# A paused lane whose crew-state run is working (its own no-mistakes run) is busy: --summary and --can-start count it.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
CHECK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/fm-flow-check.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
main=$d/main home=$d/pool/8/firstmate now=$(date +%s)
mkdir -p "$main/bin" "$main/config" "$main/state" "$home/state" "$home/data" "$home/crew"
cat > "$main/bin/fm-tasks-axi.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = ready ] || exit 2
n=$(cat "$FM_HOME/ready-count"); echo "ready[$n]{id,state}:"
for i in $(seq 1 "$n"); do echo "  item-$i,queued"; done
EOF
cat > "$main/bin/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$FM_HOME/probed"
echo "state: $(cat "$FM_HOME/crew/$1") · source: status-log · fixture"
EOF
chmod +x "$main/bin/"*.sh
lane() {  # <task> <status line> [crew state]
  printf 'kind=ship\n' > "$home/state/$1.meta"
  printf '%s\n' "$2" > "$home/state/$1.status"
  [ -z "${3:-}" ] || echo "$3" > "$home/crew/$1"
}
h=3600
lane ext5 "paused [at=$((now - 5 * h))]: waiting on byokit publish" paused
lane fail5 "failed [at=$((now - 6 * h))]: kept open for unlanded work" failed
lane ext3 "paused [at=$((now - 3 * h))]: waiting on quota reset" paused
lane work "working [at=$((now - 1 * h))]: building"
lane held5 "blocked [key=captain-hold-x] [at=$((now - 5 * h))]: captain decides the name" blocked
lane resumed5 "blocked [at=$((now - 5 * h))]: waiting on desklink release" working
fail=0
expect() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: want [$2] got [$3]"; fail=1; fi
}
run() { FM_MAIN_HOME=$main python3 "$CHECK" "$home" "$@"; }

# Cap 4, hard cap 6: six open lanes, but the two long external waits free their slots.
printf 'muxr 4\n' > "$main/config/lane-caps"
echo 2 > "$home/ready-count"
row=$(run --summary)
expect 'open lanes stay listed' 6 "$(cut -f2 <<<"$row")"
expect 'counted excludes only the 5 h paused and failed waits' 4 "$(cut -f8 <<<"$row")"
expect 'dry=0 while ready work waits' 0 "$(cut -f9 <<<"$row")"
expect 'paused lanes at any age and long blocked or failed waits are probed' 'ext3 ext5 fail5 resumed5' "$(sort -u "$home/probed" | paste -sd ' ')"
expect 'captain-held and working lanes are never probed' '' "$(grep -xE 'held5|work' "$home/probed" || true)"
rc=0; out=$(run --can-start) || rc=$?
expect '--can-start passes with freed slots' '0 ' "$rc $out"

# --target reads landed lanes only: it must not spend the 15 s probe deadline inside the watcher's 30 s window.
rm -f "$home/probed"
out=$(run --target)
expect '--target probes no lanes' '' "$(cat "$home/probed" 2>/dev/null || true)"
expect '--target still prints the percentile line' 'muxr landed lanes 14d n=0 too few for P50/P85; red line uses 24h' "$out"

# Cap 4, nothing ready: the two long waits freed their slots and nothing refills them —
# dry even though 4 lanes still count (working = 1 is what the dry predicate reads).
printf 'muxr 4\n' > "$main/config/lane-caps"
echo 0 > "$home/ready-count"
expect 'dry=1 with no ready work and working < cap' 1 "$(run --summary | cut -f9)"

# A sixth counting lane fills the hard cap again: the rule frees waits, not the cap itself.
printf 'muxr 4\n' > "$main/config/lane-caps"
lane ext4 "paused [at=$((now - 4 * h + 60))]: waiting on quota reset" paused
lane work2 "working [at=$now]: building"
rc=0; out=$(run --can-start) || rc=$?
expect '--can-start refuses at the hard cap of counting lanes' '1 6 open lanes, hard cap 6: land or close a waiting lane first' "$rc $out"

# A lane held for the captain only through its backlog item (fm-captain-hold.sh hold) is captain-held, not red:
# both lanes are 30 h old past the 24 h red limit, and only the unheld control lane goes red.
bhome=$d/bl/8/firstmate
mkdir -p "$bhome/state" "$bhome/data"
for t in bl-held bl-open; do
  printf 'kind=ship\n' > "$bhome/state/$t.meta"
  printf 'working [at=%s]: building\n' "$((now - 30 * h))" > "$bhome/state/$t.status"
  touch -d "@$((now - 30 * h))" "$bhome/state/$t.meta" "$bhome/state/$t.status"
done
printf '%s\n' '- [ ] bl-held - held for the captain (kind: ship) (hold: fm-hold-v1:eA==) (hold-kind: captain)' \
  '- [ ] bl-open - not held (kind: ship)' > "$bhome/data/backlog.md"
bout=$(FM_MAIN_HOME=$main python3 "$CHECK" "$bhome")
expect 'backlog captain hold raises no red line' '' "$(grep -F 'bl-held' <<<"$bout" || true)"
expect 'control lane without a hold still reads red' 1 "$(grep -cE 'bl-open lead .* red \(limit' <<<"$bout")"

# Done lanes are still counted by --summary, but captain-held lanes must not get a land action.
for t in bl-done-held bl-done-open; do
  printf 'kind=ship\n' > "$bhome/state/$t.meta"
  printf 'done [at=%s]: PR ready\n' "$((now - 2 * h))" > "$bhome/state/$t.status"
done
printf '%s\n' '- [ ] bl-done-held - waiting (hold: fm-hold-v1:eA==) (hold-kind: captain)' \
  '- [ ] bl-done-open - not held' > "$bhome/data/backlog.md"
bout=$(FM_MAIN_HOME=$main python3 "$CHECK" "$bhome")
expect 'backlog-held done lane raises no land line' '' "$(grep -F 'bl-done-held lead' <<<"$bout" || true)"
expect 'unheld done lane still raises land line' 1 "$(grep -cF 'bl-done-open lead' <<<"$bout")"

# Real muxr shape (2026-10-18): a lane whose own no-mistakes run is executing keeps a paused: stamp, and crew-state reads
# that run-step as working, so it is busy. A short external wait is not busy, and a working lane still is.
home=$d/own/8/firstmate
mkdir -p "$home/state" "$home/data" "$home/crew"
echo 3 > "$home/ready-count"
lane own-run "paused [at=$((now - 600))]: own run: no-mistakes fix round executing on fm/own-run" working
lane quota-wait "paused [at=$((now - 600))]: waiting on quota reset" paused
lane writer "working [at=$((now - 60))]: building"
printf 'muxr 2\n' > "$main/config/lane-caps"
expect 'paused own-run and working lanes count as busy, a short external wait does not' 2 "$(run --summary | cut -f3)"
rc=0; out=$(run --can-start) || rc=$?
expect '--can-start sees the busy lanes at cap 2' '1 2 working lanes, cap 2: finish one first' "$rc $out"

# Parked lanes (retro fix 3): they leave the open count and the cap; a lane-cap park is ready work that the next free
# slot resumes with no steer (--resume, oldest first, one per free slot); any other park without a named resume
# condition is STALLED; one that names a date, a PR or the captain is not.
home=$d/park/8/firstmate
mkdir -p "$home/state" "$home/data" "$home/crew"
echo 0 > "$home/ready-count"
printf 'muxr 2\n' > "$main/config/lane-caps"
lane writer1 "working [at=$((now - 60))]: building"
lane cap-old "parked [key=lane-cap] [at=$((now - 5 * h))]: lane cap full, branch fm/cap-old pushed"
lane cap-new "parked [key=lane-cap] [at=$((now - 1 * h))]: lane cap full, branch fm/cap-new pushed"
lane p-date "parked [at=$((now - 20 * h))]: waiting on quota (resume-on: 2026-11-01)"
lane p-pr "parked [at=$((now - 20 * h))]: waiting on merge (resume-on: https://github.com/acme/app/pull/7)"
lane p-captain "parked [at=$((now - 20 * h))]: waiting (resume-on: captain)"
lane p-bare "parked [at=$((now - 20 * h))]: waiting until Main says"
row=$(run --summary)
expect 'parked lanes leave the open count' 1 "$(cut -f2 <<<"$row")"
expect 'lane-cap parked lanes count as ready work' '2 0' "$(cut -f4,9 <<<"$row" | tr '\t' ' ')"
expect 'pulse counts 6 parked, 1 stalled' '6 1' "$(cut -f10,11 <<<"$row" | tr '\t' ' ')"
expect 'one free slot resumes the oldest lane-cap park' 'cap-old' "$(run --resume)"
lane writer2 "working [at=$((now - 60))]: building"
expect 'no free slot resumes nothing' '' "$(run --resume)"
rm -f "$home/state/writer2".*
expect '--can-start sends the free slot to the parked lane first' '1 cap-old is parked for the lane cap and takes the free slot: resume it first' "$(rc=0; o=$(run --can-start) || rc=$?; echo "$rc $o")"
out=$(run)
expect 'only the park with no resume condition is STALLED' '1' "$(grep -c 'STALLED' <<<"$out")"
expect 'the stalled line names it' 1 "$(grep -cE '^flow: p-bare parked 20\.0h STALLED' <<<"$out")"
expect 'parked lanes raise no wait line' '' "$(grep -E 'past its clock' <<<"$out" || true)"

[ "$fail" -eq 0 ] && echo "PASS: fm-flow-check lane slots" || { echo "FAIL: fm-flow-check lane slots"; exit 1; }
