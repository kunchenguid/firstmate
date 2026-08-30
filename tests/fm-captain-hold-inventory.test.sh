#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

home=$(fm_test_tmproot fm-captain-hold-inventory)
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"

run_captain() {
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

(cd "$home" && tasks-axi add held-work "Held work" --kind ship --repo sample >/dev/null) \
  || fail "could not create the held-work fixture"
run_captain hold held-work --reason "captain approval needed" >/dev/null \
  || fail "could not hold the work fixture"
printf 'Proceed.\n' > "$home/decision.txt"
run_captain answer held-work --decision-file "$home/decision.txt" --release >/dev/null \
  || fail "could not release the work fixture"
run_captain hold held-work --reason "captain approval reopened" >/dev/null \
  || fail "could not re-hold the work fixture"
printf 'window=firstmate:fm-origin\nkind=ship\nmode=no-mistakes\ndecisions_reviewed=1\ndecision_keys=held-work\n' \
  > "$home/state/origin.meta"

state=$(run_captain inventory-state origin) || fail "could not read the captain inventory"
[ "$state" = $'open\theld-work' ] || fail "a current hold yielded to its historical answer: $state"
pass "current captain holds take precedence over historical answers"
