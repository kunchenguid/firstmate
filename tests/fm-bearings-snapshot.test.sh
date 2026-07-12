#!/usr/bin/env bash
# Behavior tests for the bearings projection wrapper over fm-fleet-snapshot.sh.
# Covers the output/token bound, TOON/JSON parity, the local-only default (zero
# GitHub/network calls), the --include-prs opt-in path, graceful degradation on a
# partial PR-fetch failure, end-to-end unresolved-decision durability, and current
# report pointers.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fakebin that stubs the local tools the canonical snapshot may reach for, plus a
# gh/gh-axi that RECORDS every call to $NET_LOG so a test can prove the default path
# makes no network call. gh returns one fixture open PR keyed to the ship task.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) case "$*" in *dead-*) exit 1 ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "${FAKE_GH_SLEEP:-0}" = 1 ]; then sleep 30; fi
if [ "${FAKE_GH_MANY:-0}" = 1 ]; then
  cat <<'JSON'
[{"number":1,"title":"One","url":"https://github.com/acme/repo/pull/1","headRefName":"fm/one","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":2,"title":"Two","url":"https://github.com/acme/repo/pull/2","headRefName":"fm/two","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":3,"title":"Three","url":"https://github.com/acme/repo/pull/3","headRefName":"fm/three","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]
JSON
  exit 0
fi
cat <<'JSON'
[{"number":9,"title":"Ship the thing","url":"https://github.com/kunchenguid/firstmate/pull/9","headRefName":"fm/ship-task","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]
JSON
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$home/secondmate-home"
  printf '%s\n' "$home"
}

# Standard fixture: a ship task with a recorded PR, a scout task with a report, a
# secondmate with a MASKED open decision (needs-decision then a later unrelated
# done), and a backlog with a superseded queued item.
write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/ship-wt" "$home/data/scout-x"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] scout-x - Investigate the thing data/scout-x/report.md (repo: firstmate) (kind: scout) (since 2026-07-11)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: firstmate) (kind: ship)
- [ ] dead-gate - Old conditional work (repo: firstmate) (kind: scout)
  NOT REQUIRED - superseded 2026-07-11; kept as reference only.

## Done
- [x] done-a - Landed thing https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF
  printf '# Scout X\n' > "$home/data/scout-x/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'working: building the thing\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-x.meta" \
    "window=firstmate:fm-scout-x" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report ready\n' > "$home/state/scout-x.status"
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=firstmate"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$home/state/mate.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/mate.status"
  fm_write_meta "$home/state/external-wait.meta" \
    "window=firstmate:fm-external-wait" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'paused: declared external-wait for upstream release\n' > "$home/state/external-wait.status"
  # The secondmate's OWN home backlog records a merge it managed. This lands in the
  # secondmate home, never the main backlog, so landed-work views only see it via the
  # bounded cross-home Done roll-up.
  mkdir -p "$home/secondmate-home/data"
  cat > "$home/secondmate-home/data/backlog.md" <<'EOF'
## Done
- [x] mate-landed - Secondmate-managed fix https://github.com/kunchenguid/firstmate/pull/50 (repo: firstmate) (kind: ship) (merged 2026-07-11)
EOF
}

run() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" "$BEARINGS" "$@"
}

test_default_is_bounded_and_local_only() {
  local home fakebin toon json
  home=$(make_home bounded); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Bound: well under the ~50 KB tool-display limit.
  [ "${#toon}" -lt 50000 ] || fail "default TOON must stay under the display bound, got ${#toon}"
  # TOON is materially smaller than the canonical snapshot it projects.
  local canon; canon=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  [ "${#toon}" -lt "${#canon}" ] || fail "projection must be smaller than the canonical snapshot"
  # Local-only: no GitHub/network call on the default path.
  [ ! -s "$home/net.log" ] || fail "default run must make no gh/gh-axi call, got: $(cat "$home/net.log")"
  # Definitive not-requested PR state, never a silent omission.
  assert_contains "$toon" 'prs: "not_requested' "default must state PR checks were not requested"
  assert_contains "$toon" "live PR discovery + checks,\"--include-prs\"" "omitted must mark the dropped live-PR surface"
  # Valid JSON, correct schema.
  printf '%s' "$json" | jq -e '.schema == "fm-bearings.v1"' >/dev/null || fail "json schema wrong"
  pass "default output is bounded, local-only, and marks omitted surfaces"
}

test_toon_json_parity() {
  local home fakebin toon json keys k
  home=$(make_home parity); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Same top-level keys in both representations.
  keys=$(printf '%s' "$json" | jq -r 'keys_unsorted[]')
  for k in $keys; do
    if printf '%s' "$json" | jq -e --arg k "$k" '.[$k] | type == "array"' >/dev/null; then
      local n hdr
      n=$(printf '%s' "$json" | jq --arg k "$k" '.[$k] | length')
      if [ "$n" = 0 ]; then
        assert_contains "$toon" "$k: []" "empty array $k must render as 'key: []'"
      else
        # Header must declare the same count and the same field set.
        hdr=$(printf '%s' "$toon" | grep -E "^$k\[[0-9]+\]\{" || true)
        [ -n "$hdr" ] || fail "TOON missing tabular header for $k"
        assert_contains "$hdr" "[$n]" "TOON $k row count must equal JSON length $n"
        local jfields tfields
        jfields=$(printf '%s' "$json" | jq -r --arg k "$k" '.[$k][0] | keys_unsorted | join(",")')
        tfields=$(printf '%s' "$hdr" | sed -E 's/^[^{]*\{//; s/\}:.*$//; s/"//g')
        [ "$jfields" = "$tfields" ] || fail "TOON $k fields ($tfields) must equal JSON fields ($jfields)"
      fi
    else
      # Scalar: the key must appear as a "key: value" line.
      assert_contains "$toon" "$k: " "TOON must carry scalar field $k"
    fi
  done
  pass "TOON and JSON are parity representations of the same model"
}

test_open_decision_surfaces_end_to_end() {
  local home fakebin json
  home=$(make_home e2e-decision); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.[]; .id == "mate" and .key == "race" and .verb == "needs-decision")
  ' >/dev/null || fail "a still-open decision masked by a later done must surface in decisions_open: $json"
  pass "an open decision masked by a later event surfaces end-to-end"
}

test_report_pointers_surface() {
  local home fakebin json
  home=$(make_home reports); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e --arg p "$home/data/scout-x/report.md" '
    .reports | any(.[]; .id == "scout-x" and .path == $p)
  ' >/dev/null || fail "current scout report pointer must surface: $json"
  pass "current report pointers surface"
}

test_superseded_queued_item_dropped_by_default() {
  local home fakebin json
  home=$(make_home superseded); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.gates | any(.[]; .id == "live-gate")) and (.gates | any(.[]; .id == "dead-gate") | not)
  ' >/dev/null || fail "default gates must include live and drop superseded: $json"
  json=$(run "$home" "$fakebin" --json --all-queued)
  printf '%s' "$json" | jq -e '.gates | any(.[]; .id == "dead-gate")' >/dev/null \
    || fail "--all-queued must restore the superseded item"
  pass "superseded queued items are dropped by default and restored with --all-queued"
}

test_include_prs_is_the_only_fetch_path() {
  local home fakebin json
  home=$(make_home prs); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(run "$home" "$fakebin" --include-prs --json)
  # Now gh WAS called, exactly for pr list.
  grep -q '^gh pr list ' "$home/net.log" || fail "--include-prs must call gh pr list"
  printf '%s' "$json" | jq -e '
    .prs | startswith("checked")
  ' >/dev/null || fail "--include-prs must report checked PR state"
  printf '%s' "$json" | jq -e '
    .candidate_prs | any(.[]; .num == "9" and .task == "ship-task" and .checks == "passing" and .review == "APPROVED")
  ' >/dev/null || fail "candidate_prs must carry the fetched PR cross-referenced to its task: $json"
  pass "--include-prs is the only path that fetches, and it enriches correctly"
}

test_partial_github_failure_degrades() {
  local home fakebin json rc
  home=$(make_home partial); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FAKE_GH_FAIL=1 run "$home" "$fakebin" --include-prs --json); rc=$?
  expect_code 0 "$rc" "a PR-fetch failure must not crash the view"
  printf '%s' "$json" | jq -e '
    .schema == "fm-bearings.v1"
      and (.candidate_prs | length) == 0
      and (.prs | test("unavailable"))
      and (.in_flight | length) > 0
  ' >/dev/null || fail "on gh failure the view must still emit, with an unavailable note: $json"
  pass "a partial GitHub failure degrades gracefully"
}

test_perl_fallback_bounds_github_call() {
  local home fakebin toolbin cmd json started elapsed
  home=$(make_home perl-timeout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toolbin="$home/toolbin"
  mkdir -p "$toolbin"
  for cmd in bash dirname basename jq date sed git grep tail cut tr head sort wc perl sleep cat find; do
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  started=$(date +%s)
  json=$(PATH="$fakebin:$toolbin" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z \
    FM_BEARINGS_PR_TIMEOUT=1 NET_LOG="$home/net.log" FAKE_GH_SLEEP=1 "$BEARINGS" --include-prs --json)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] || fail "Perl fallback did not bound a stalled gh call (${elapsed}s)"
  printf '%s' "$json" | jq -e '.prs | test("unavailable")' >/dev/null \
    || fail "timed-out gh call did not fail soft: $json"
  pass "Perl fallback bounds stalled GitHub calls without coreutils timeout"
}

write_large_fixture() {  # <home> <count>
  local home=$1 count=$2 i id
  : > "$home/data/backlog.md"
  printf '## Queued\n' >> "$home/data/backlog.md"
  i=1
  while [ "$i" -le "$count" ]; do
    id="dead-$i"
    mkdir -p "$home/projects/$id" "$home/data/$id"
    printf '# Report\n' > "$home/data/$id/report.md"
    printf -- '- [ ] gate-%s - Gate %s blocked-by: task-%s (repo: repo-%s) (kind: ship)\n' "$i" "$i" "$i" "$i" >> "$home/data/backlog.md"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id" \
      "project=repo-$i" \
      "harness=codex" \
      "kind=scout" \
      "mode=scout" \
      "pr=https://github.com/acme/repo-$i/pull/$i"
    printf 'needs-decision [key=q%s]: choose %s\n' "$i" "$i" > "$home/state/$id.status"
    i=$((i + 1))
  done
}

test_section_caps_and_expansion_flags() {
  local home fakebin json expanded
  home=$(make_home caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight|length) == 2 and (.decisions_open|length) == 2 and (.gates|length) == 2
    and (.reports|length) == 2 and (.recorded_prs|length) == 2 and (.unhealthy_endpoints|length) == 2
    and ([.omitted[].surface] | index("in_flight showing 2 of 5") != null)
    and ([.omitted[].surface] | index("decisions_open showing 2 of 5") != null)
    and ([.omitted[].surface] | index("gates showing 2 of 5") != null)
    and ([.omitted[].surface] | index("reports showing 2 of 5") != null)
    and ([.omitted[].surface] | index("recorded_prs showing 2 of 5") != null)
    and ([.omitted[].surface] | index("unhealthy_endpoints showing 2 of 5") != null)
  ' >/dev/null || fail "section caps or counted omissions are wrong: $json"
  expanded=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json --all-in-flight --all-decisions --all-queued \
      --all-reports --all-recorded-prs --all-unhealthy)
  printf '%s' "$expanded" | jq -e '
    (.in_flight|length) == 5 and (.decisions_open|length) == 5 and (.gates|length) == 5
    and (.reports|length) == 5 and (.recorded_prs|length) == 5 and (.unhealthy_endpoints|length) == 5
  ' >/dev/null || fail "section expansion flags did not reveal full sets: $expanded"
  pass "all fleet-sized sections are capped with counted opt-in expansion"
}

test_pr_repository_cap_and_expansion() {
  local home fakebin json expanded
  home=$(make_home repo-caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 2 ] || fail "default PR repository cap was not enforced"
  printf '%s' "$json" | jq -e '
    [.omitted[] | select(.surface == "PR repositories showing 2 of 5" and .reveal == "--all-pr-repos")] | length == 1
  ' >/dev/null || fail "PR repository truncation was not recorded: $json"
  : > "$home/net.log"
  expanded=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --all-pr-repos --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 5 ] || fail "--all-pr-repos did not reveal every repository"
  printf '%s' "$expanded" | jq -e '.candidate_prs | length == 5' >/dev/null \
    || fail "expanded PR repository set did not enrich every repository: $expanded"
  pass "live PR enrichment caps repositories with counted expansion"
}

test_per_repository_pr_cap_is_disclosed() {
  local home fakebin json toon
  home=$(make_home pr-row-cap); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs --json)
  toon=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs)
  printf '%s' "$json" | jq -e '
    (.candidate_prs | length) == 2
    and (.prs | test("2 shown, at least 3 open; capped in 1 repo"))
    and ([.omitted[] | select(.surface == "candidate_prs showing 2 of at least 3; capped in 1 repo(s)" and .reveal == "raise FM_BEARINGS_PR_LIMIT")] | length) == 1
  ' >/dev/null || fail "per-repository PR truncation was not disclosed: $json"
  assert_contains "$toon" 'candidate_prs showing 2 of at least 3' "TOON did not preserve PR truncation disclosure"
  pass "per-repository open-PR caps are disclosed with an expansion knob"
}

install_failing_jq() {  # <fakebin> <model|toon>
  local fakebin=$1 phase=$2 real
  real=$(command -v jq)
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'def trunc'*) [ "$phase" = model ] && exit 9 ;;
  *'def q:'*) [ "$phase" = toon ] && exit 9 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/jq"
}

test_projection_and_toon_fail_closed() {
  local home fakebin out err rc
  home=$(make_home fail-closed); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  install_failing_jq "$fakebin" model
  err="$home/model.err"
  out=$(run "$home" "$fakebin" --json 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "projection failure exited successfully"
  [ -z "$out" ] || fail "projection failure emitted output"
  grep -F 'projection failed' "$err" >/dev/null || fail "projection failure lacked a diagnostic"
  install_failing_jq "$fakebin" toon
  err="$home/toon.err"
  out=$(run "$home" "$fakebin" 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "TOON rendering failure exited successfully"
  [ -z "$out" ] || fail "TOON rendering failure emitted output"
  grep -F 'TOON rendering failed' "$err" >/dev/null || fail "TOON failure lacked a diagnostic"
  pass "projection and TOON rendering failures exit nonzero with diagnostics"
}

# The Lavish-103 defect, end to end: a COMPLETED scout that raised a decision and
# then finished (done), whose report body reads like that decision, must surface as
# a report POINTER only - never in decisions_open. Report prose must never open or
# reopen a pending decision; only the keyed durable state does.
test_completed_scout_report_not_pending() {
  local home fakebin json
  home=$(make_home completed-scout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/lav-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/lav-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B; this needs a captain decision.\n' > "$home/data/lavish-103/report.md"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "lavish-103") | not)
      and (.reports | any(.[]; .id == "lavish-103"))
  ' >/dev/null || fail "completed scout must be a report pointer, never a pending decision: $json"
  pass "a completed scout with decision-like report prose is a pointer, not pending"
}

# Recently Landed must include merges a secondmate managed. Those completion records
# live in the secondmate home's OWN backlog, not the main one, so the projection must
# roll them up. Local, deterministic, no GitHub call.
test_landed_includes_secondmate_home_merges() {
  local home fakebin json
  home=$(make_home mate-landed); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.landed | any(.[]; .id == "mate-landed" and (.artifact | test("/pull/50"))))
      and (.landed | any(.[]; .id == "done-a"))
  ' >/dev/null || fail "landed must merge secondmate-home Done with main-home Done: $json"
  # Still zero network on this default path.
  [ ! -s "$home/net.log" ] || fail "landed roll-up must make no gh/gh-axi call, got: $(cat "$home/net.log")"
  pass "landed includes secondmate-managed merges alongside main-home merges"
}

# The roll-up stays bounded: a per-home cap and an overall cap, both disclosed in
# omitted[], with --all-landed as the counted expansion knob. This also covers the
# previously-silent main-home landed truncation.
test_landed_bounded_and_disclosed() {
  local home fakebin json i expected actual
  home=$(make_home mate-landed-caps); write_fixture "$home"
  : > "$home/secondmate-home/data/backlog.md"
  printf '## Done\n' >> "$home/secondmate-home/data/backlog.md"
  i=1
  while [ "$i" -le 12 ]; do
    printf -- '- [x] mate-landed-%02d - Secondmate fix %02d (repo: firstmate) (kind: ship) (merged 2026-06-%02d)\n' \
      "$i" "$i" "$((13 - i))" >> "$home/secondmate-home/data/backlog.md"
    i=$((i + 1))
  done
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_LANDED=20 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.landed[].id | select(startswith("mate-landed-"))] | length) == 10
      and ([.omitted[].surface] | any(test("snapshot layer")))
  ' >/dev/null || fail "default landed path must retain and disclose the snapshot per-home cap: $json"
  json=$(FM_BEARINGS_LANDED=1 run "$home" "$fakebin" --json --all-landed)
  expected=done-a
  i=1
  while [ "$i" -le 12 ]; do
    expected="$expected
$(printf 'mate-landed-%02d' "$i")"
    i=$((i + 1))
  done
  expected=$(printf '%s\n' "$expected" | LC_ALL=C sort)
  actual=$(printf '%s' "$json" | jq -r '.landed[].id' | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || fail "--all-landed returned wrong identities: $actual"
  printf '%s' "$json" | jq -e '
    (.landed | length) == 13
      and ([.omitted[].surface] | any(test("landed|snapshot layer")) | not)
  ' >/dev/null || fail "--all-landed must reveal the exact full landed set: $json"
  pass "landed stays bounded with per-home + overall caps and omitted[] disclosure"
}

# Captain's Call is populated only from the durable keyed open-decision set. The
# anti-leak guard: action-free highlights - a working task, a completed scout,
# queued/gated items, landed work - must never surface as an open decision, so they
# cannot leak into Captain's Call. The standard fixture has exactly one genuine open
# decision (the secondmate's masked needs-decision).
test_captains_call_anti_leak() {
  local home fakebin json canonical
  home=$(make_home anti-leak); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  jq -n -e --argjson bearings "$json" --argjson canonical "$canonical" '
    (([$bearings.decisions_open[].id]
      + [$canonical.tasks[] | select(.hints.pending_decision or .hints.blocked_event) | .id]) | unique) == ["mate"]
      and ([$bearings.decisions_open[].id] | index("ship-task") | not)
      and ([$bearings.decisions_open[].id] | index("scout-x") | not)
      and ([$bearings.decisions_open[].id] | index("external-wait") | not)
      and ([$bearings.decisions_open[].id] | index("done-a") | not)
      and ([$bearings.decisions_open[].id] | index("mate-landed") | not)
      and ([$bearings.decisions_open[].id] | index("live-gate") | not)
      and ([$bearings.decisions_open[].id] | index("dead-gate") | not)
  ' >/dev/null || fail "only genuine open decisions may feed Captain's Call: $json"
  pass "action-free items (working/done/queued/landed) do not leak into Captain's Call"
}

# The /bearings skill is the one owner of the four-section chat-response contract.
# Assert it states exactly the four fixed sections in order, each with its explicit
# empty-state sentence, documents the At Anchor exclusion, and mandates a chat that is
# materially shorter than and links to the report file.
test_chat_contract_four_sections() {
  local skill body headings expected
  skill="$ROOT/.agents/skills/bearings/SKILL.md"
  [ -f "$skill" ] || fail "bearings SKILL.md missing at $skill"
  body=$(awk '/^## Chat-response contract$/{capture=1; next} capture && /^## /{exit} capture' "$skill")
  headings=$(printf '%s\n' "$body" | sed -nE "s/^[0-9]+\. \*\*([^*]+)\*\*.*/\1/p")
  expected=$(printf '%s\n' "Captain's Call" "Recently Landed" "Underway" "Charted Next")
  [ "$headings" = "$expected" ] || fail "chat contract must contain exactly four numbered sections in fixed order, got: $headings"
  assert_contains "$body" "Nothing needs your action right now" "Captain's Call empty-state sentence"
  assert_contains "$body" "Nothing has landed since your last report" "Recently Landed empty-state sentence"
  assert_contains "$body" "Nothing is underway" "Underway empty-state sentence"
  assert_contains "$body" "Nothing is queued" "Charted Next empty-state sentence"
  assert_contains "$body" "no At Anchor section" "the At Anchor exclusion must be documented"
  assert_contains "$body" "materially shorter" "the chat must be materially shorter than the report file"
  assert_contains "$body" "links to" "the chat must link to the report file"
  pass "the /bearings skill states the four-section chat contract in order, with empty-states and the At Anchor exclusion"
}

test_default_is_bounded_and_local_only
test_toon_json_parity
test_landed_includes_secondmate_home_merges
test_landed_bounded_and_disclosed
test_captains_call_anti_leak
test_chat_contract_four_sections
test_completed_scout_report_not_pending
test_open_decision_surfaces_end_to_end
test_report_pointers_surface
test_superseded_queued_item_dropped_by_default
test_include_prs_is_the_only_fetch_path
test_partial_github_failure_degrades
test_perl_fallback_bounds_github_call
test_section_caps_and_expansion_flags
test_pr_repository_cap_and_expansion
test_per_repository_pr_cap_is_disclosed
test_projection_and_toon_fail_closed
