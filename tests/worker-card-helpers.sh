#!/usr/bin/env bash
# Assert the public launch's emitted Claude hook against saved on-disk state.
assert_worker_card() { # SETTINGS NOTES LABEL
  local settings=$1 notes=$2 label=$3 hook card source
  [ -s "$notes" ] || fail "$label: launch did not initialize planning state"
  hook=$(jq -r '.hooks.SessionStart[] | select(.matcher == "startup|resume|compact") | .hooks[].command' "$settings")
  [ -n "$hook" ] || fail "$label: launch did not install saved-state replay"
  printf 'decision: %s preserve current revision\nnext: finish proof\n' "$label" > "$notes"
  for source in startup resume compact; do
    card=$(printf '{"source":"%s"}' "$source" | bash -c "$hook") || fail "$label: $source replay failed"
    assert_contains "$card" "decision: $label preserve current revision" "$label: $source lost saved decisions"
    assert_contains "$card" 'next: finish proof' "$label: $source lost next steps"
    assert_contains "$card" 'refresh at every milestone' "$label: refresh instruction missing"
    assert_contains "$card" 'Read back the saved planning state' "$label: read-back instruction missing"
  done
  pass "$label: initialized card, milestone refresh contract, startup/resume/compact read-back"
}
