#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || { printf 'skip - tasks-axi absent\n'; exit 0; }
home=$(fm_test_tmproot fm-ask-user-intake)
mkdir -p "$home/data/ship-one" "$home/config" "$home/state"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
backlog() { FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
intake() { FM_HOME="$home" "$ROOT/bin/fm-ask-user-intake.sh" "$@"; }
backlog add ship-one 'A ship' --kind ship --repo sample >/dev/null
snapshot="$home/data/ship-one/nm-run-findings.txt"
printf 'id: f-one\nauthority: ask-user\ndescription: Decide scope.\n' > "$snapshot"
first=$(intake ensure ship-one nm-run-review "$snapshot")
second=$(intake ensure ship-one nm-run-review "$snapshot")
id=${first#held: }; id=${id%% *}
[ "$second" = "existing: $id owner=firstmate" ] || fail "ensure was not idempotent: $second"
row=$(backlog show "$id" --full)
printf '%s\n' "$row" | grep -q 'hold_kind: parked' || fail 'finding did not become a Firstmate-owned hold'
count=$(backlog list --fields body | grep -c 'Review ask-user finding for ship-one' || true)
[ "$count" -eq 1 ] || fail "duplicate ask-user rows: $count"
if intake promote ship-one nm-run-review model-routing 'choose model' > /dev/null 2>&1; then
  fail 'routine routing was promoted to a captain call'
fi
intake resolve ship-one nm-run-review >/dev/null
intake resolve ship-one nm-run-review | grep -q '^resolved:' || fail 'resolve was not idempotent'
row=$(backlog show "$id" --full)
printf '%s\n' "$row" | grep -q 'state: done' || fail 'Firstmate resolution did not close hold'
captain_row=$(intake ensure ship-one nm-run-security "$snapshot")
captain_id=${captain_row#held: }; captain_id=${captain_id%% *}
intake promote ship-one nm-run-security security 'Choose privacy policy' | grep -q 'owner=captain' \
  || fail 'genuine security choice did not transfer to captain ownership'
row=$(backlog show "$captain_id" --full)
printf '%s\n' "$row" | grep -q 'hold_kind: captain' || fail 'promoted finding was not captain-held'
if intake resolve ship-one nm-run-security >/dev/null 2>&1; then fail 'Firstmate closed a captain-owned finding'; fi
printf 'ok - ask-user intake is durable and idempotent\n'
