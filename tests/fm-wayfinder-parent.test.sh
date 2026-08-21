#!/usr/bin/env bash
# Behavior tests for Firstmate's parent map-owner check.
#
# Drives bin/fm-wayfinder-parent.sh, bin/fm-spawn.sh, bin/fm-promote.sh, and
# bin/fm-decision-hold.sh through a consuming project's public
# bin/wayfinder-lifecycle-gate. Does not inspect Firstmate source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PARENT="$ROOT/bin/fm-wayfinder-parent.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
DECISION_HOLD="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-wayfinder-parent)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# A compact consuming-project lifecycle command with the public CLI and
# snapshot shape Firstmate must invoke. It refuses local completion as
# resolution and requires a closed child, an evidence pointer, and a named
# gist-and-link map line.
install_project_gate() {  # <project-dir>
  local project=$1
  mkdir -p "$project/bin"
  cat > "$project/bin/wayfinder-lifecycle-gate" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path

URL_RE = re.compile(r"https?://[^\s)>\]]+", re.I)
PATH_RE = re.compile(
    r"(?:^|[\s`(\[])((?:[\w.-]+/)+[\w.-]+\.(?:md|txt|json)|research/[\w./-]+)"
)
DECISIONS_HEADER_RE = re.compile(r"^##[ \t]+Decisions so far[ \t]*$", re.M)
NEXT_HEADER_RE = re.compile(r"^##[ \t]+", re.M)
DECISION_ITEM_RE = re.compile(
    r"^[-*][ \t]+\[([^\]]+)\]\(([^)]+)\):[ \t]+(\S.*)$",
    re.M,
)


def load_state(path):
    raw = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    return json.loads(raw)


def comments(child):
    out = []
    for item in child.get("comments") or []:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict):
            out.append(item.get("body") or "")
    return out


def has_evidence(text):
    return bool(URL_RE.search(text) or PATH_RE.search(text))


def has_answer(text):
    stripped = URL_RE.sub(" ", text)
    stripped = PATH_RE.sub(" ", stripped)
    letters = re.sub(r"[^A-Za-z0-9]+", "", stripped)
    return len(letters) >= 30


def named_pointer(state, child):
    body = ((state.get("map") or {}).get("body")) or ""
    match = DECISIONS_HEADER_RE.search(body)
    if match is None:
        return False
    rest = body[match.end() :]
    nxt = NEXT_HEADER_RE.search(rest)
    section = rest[: nxt.start()] if nxt else rest
    title = child.get("title") or ""
    number = child.get("number")
    for item in DECISION_ITEM_RE.finditer(section):
        if item.group(1).strip() != title:
            continue
        if not item.group(3).strip():
            continue
        url = item.group(2)
        linked = re.search(r"(?:issues/|#)(\d+)\s*$", url)
        if linked and int(linked.group(1)) != number:
            continue
        return True
    return False


def find_child(state, ref):
    for child in state.get("children") or []:
        if str(child.get("number")) == str(ref) or child.get("title") == ref:
            return child
    return None


def local_for(state, number):
    local = (state.get("local") or {}).get("completions") or []
    return [item for item in local if item.get("child") == number]


def evaluate(state, child):
    findings = []
    number = child.get("number")
    closed = str(child.get("state") or "").lower() in {"closed", "close"}
    bodies = comments(child)
    evidence_comment = any(has_answer(body) and has_evidence(body) for body in bodies)
    pointer = named_pointer(state, child)
    local = local_for(state, number)
    if any(item.get("complete") for item in local) and not (
        closed and evidence_comment and pointer
    ):
        findings.append(
            f"FAIL {number} local-completion-is-not-resolution: a Firstmate report, backlog state, archive, or captain-held decision is not Wayfinder resolution"
        )
    if not closed:
        findings.append(f"FAIL {number} open: child is still open on GitHub")
    if not evidence_comment:
        findings.append(
            f"FAIL {number} missing-evidence-pointer: resolution comment is missing a durable evidence pointer"
        )
    if not pointer:
        findings.append(
            f"FAIL {number} missing-named-map-pointer: canonical map Decisions so far has no named gist-and-link entry for this ticket title"
        )
    return findings


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    accept = sub.add_parser("accept-child")
    accept.add_argument("child")
    sub.add_parser("handoff")
    args = parser.parse_args(argv)
    try:
        state = load_state(args.state)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if args.command == "accept-child":
        child = find_child(state, args.child)
        if child is None:
            print(f"error: child {args.child!r} is not in the snapshot", file=sys.stderr)
            return 1
        findings = evaluate(state, child)
        if findings:
            print("\n".join(findings), file=sys.stderr)
            print("gate failed", file=sys.stderr)
            return 2
        print(f"OK {child['number']} resolved: {child['title']}")
        return 0
    findings = []
    for child in state.get("children") or []:
        findings.extend(evaluate(state, child))
    if findings:
        print("\n".join(findings), file=sys.stderr)
        print("gate failed", file=sys.stderr)
        return 2
    title = ((state.get("map") or {}).get("title")) or "map"
    print(f"OK handoff: {title}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
  chmod +x "$project/bin/wayfinder-lifecycle-gate"
}

empty_decisions() {
  cat <<'EOF'
## Destination

A decision-ready plan. It does not implement the product.

## Decisions so far

<!-- Resolved ticket summaries are linked here. -->

## Out of scope

- Production implementation before the planning decisions in this map are resolved.
EOF
}

resolved_decisions() {  # <research-title> <decision-title>
  cat <<EOF
## Destination

A decision-ready plan. It does not implement the product.

## Decisions so far

- [$1](https://github.com/example/shop/issues/5): research answer gist
- [$2](https://github.com/example/shop/issues/3): decision answer gist

## Out of scope

- Production implementation before the planning decisions in this map are resolved.
EOF
}

RESEARCH_TITLE='Research: SMB market and competitor wedge'
DECISION_TITLE='Decision: MVP autonomy boundary and action surface'

write_snapshot() {  # <path> <kind>
  local path=$1 kind=$2 body
  case "$kind" in
    historical)
      body=$(empty_decisions)
      python3 - "$path" "$body" "$RESEARCH_TITLE" "$DECISION_TITLE" <<'PY'
import json, sys
from pathlib import Path
path, body, research, decision = sys.argv[1:]
Path(path).write_text(json.dumps({
    "map": {"number": 2, "title": "Wayfinder: plan", "state": "open", "body": body},
    "children": [
        {
            "number": 5,
            "title": research,
            "state": "open",
            "labels": ["wayfinder:research"],
            "comments": [{"body": "Research complete. Evidence is in the planning report."}],
        },
        {
            "number": 3,
            "title": decision,
            "state": "open",
            "labels": ["wayfinder:grilling"],
            "comments": [{"body": "Captain chose proposed-only changes with one-click accept."}],
        },
    ],
    "local": {"completions": []},
}, indent=2) + "\n", encoding="utf-8")
PY
      ;;
    resolved)
      body=$(resolved_decisions "$RESEARCH_TITLE" "$DECISION_TITLE")
      python3 - "$path" "$body" "$RESEARCH_TITLE" "$DECISION_TITLE" <<'PY'
import json, sys
from pathlib import Path
path, body, research, decision = sys.argv[1:]
Path(path).write_text(json.dumps({
    "map": {"number": 2, "title": "Wayfinder: plan", "state": "open", "body": body},
    "children": [
        {
            "number": 5,
            "title": research,
            "state": "closed",
            "labels": ["wayfinder:research"],
            "comments": [{
                "body": "Research complete. Do not position the MVP as a generic low-price optimizer. Evidence: https://example.test/research/smb-market.md"
            }],
        },
        {
            "number": 3,
            "title": decision,
            "state": "closed",
            "labels": ["wayfinder:grilling"],
            "comments": [{
                "body": "By default all changes are proposed only, with one-click accept, pause, and rollback. Evidence: https://example.test/decisions/autonomy.md"
            }],
        },
    ],
    "local": {"completions": []},
}, indent=2) + "\n", encoding="utf-8")
PY
      ;;
    *) fail "unknown snapshot kind $kind" ;;
  esac
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

make_gated_project() {  # <home> <name>
  local home=$1 name=$2 project
  project="$home/projects/$name"
  mkdir -p "$project"
  fm_git_init_commit "$project"
  install_project_gate "$project"
  printf '%s\n' "$project"
}

run_parent() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PARENT" "$@"
}

run_spawn() {
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_promote() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" "$@" 2>&1
}

write_ship_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf 'You are a crewmate.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
    > "$1/data/$2/brief.md"
}

write_scout_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf 'You are a crewmate.\n\n# Task\nNamed Wayfinder ticket.\n' \
    > "$1/data/$2/brief.md"
}

fakebin_for() {  # <home>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  # Exit 1 so a spawn that clears the Wayfinder check still creates no endpoint.
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/treehouse"
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# Historical failure: named Wayfinder scout has a report and completed
# captain-call inventory while the project command rejects the child.
test_historical_local_completion_is_not_resolution() {
  local home project id snap out rc
  home=$(make_home historical)
  project=$(make_gated_project "$home" shop)
  id=wf-market-wedge
  snap="$TMP_ROOT/historical.json"
  write_snapshot "$snap" historical
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/report.md" <<'EOF'
# Research report

The research question is answered. This local report is not GitHub resolution.
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=scout"

  if [ -n "$TASKS_AXI_BIN" ]; then
    (cd "$home" && tasks-axi add "$id" "Research the market wedge" --kind scout --repo shop --start >/dev/null) \
      || fail "could not create historical scout backlog item"
    out=$(PATH="$(dirname "$TASKS_AXI_BIN"):$PATH" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      "$DECISION_HOLD" complete "$id" --none 2>&1)
    rc=$?
    expect_code 0 "$rc" "complete --none should succeed as local captain-call inventory"$'\n'"$out"
    grep -F 'captain-call inventory reviewed' <<<"$out" >/dev/null \
      || fail "complete --none did not attest local inventory: $out"
  else
    printf 'decisions_reviewed=1\ndecision_keys=\n' >> "$home/state/$id.meta"
  fi

  set +e
  out=$(run_parent "$home" accept-child --project "$project" --state "$snap" \
    --child 5 --task "$id" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "accept-child must refuse a locally completed unresolved child"$'\n'"$out"
  assert_contains "$out" "local-completion-is-not-resolution" \
    "project gate must see the merged local report"
  assert_not_contains "$out" "OK 5 resolved" \
    "Firstmate must not treat the historical child as Wayfinder-resolved"

  set +e
  out=$(run_parent "$home" handoff --project "$project" --state "$snap" --task "$id" --child 5 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "handoff must not take --child"$'\n'"$out"

  set +e
  out=$(run_parent "$home" handoff --project "$project" --state "$snap" --task "$id" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "handoff must refuse while the map is unresolved"$'\n'"$out"
  pass "historical local report plus captain-call completion is not Wayfinder resolution"
}

test_resolved_research_and_decision_children_pass() {
  local home project snap out rc
  home=$(make_home resolved)
  project=$(make_gated_project "$home" shop)
  snap="$TMP_ROOT/resolved.json"
  write_snapshot "$snap" resolved

  out=$(run_parent "$home" accept-child --project "$project" --state "$snap" --child 5)
  rc=$?
  expect_code 0 "$rc" "resolved research child must pass accept-child"$'\n'"$out"
  assert_contains "$out" "OK 5 resolved: $RESEARCH_TITLE" \
    "research accept-child did not report the project command success"

  out=$(run_parent "$home" accept-child --project "$project" --state "$snap" \
    --child "$DECISION_TITLE")
  rc=$?
  expect_code 0 "$rc" "resolved decision child must pass accept-child"$'\n'"$out"
  assert_contains "$out" "OK 3 resolved: $DECISION_TITLE" \
    "decision accept-child did not report the project command success"

  out=$(run_parent "$home" handoff --project "$project" --state "$snap")
  rc=$?
  expect_code 0 "$rc" "resolved map must pass handoff"$'\n'"$out"
  assert_contains "$out" "OK handoff:" "handoff did not report the project command success"
  pass "parent accepts a resolved research child and a resolved decision child through the project command"
}

test_complete_none_alone_remains_insufficient() {
  local home project id snap out rc
  home=$(make_home complete-none)
  project=$(make_gated_project "$home" shop)
  id=wf-shopify-compliance
  snap="$TMP_ROOT/complete-none.json"
  write_snapshot "$snap" historical
  mkdir -p "$home/data/$id"
  printf '# Compliance research\n\nAnswered locally.\n' > "$home/data/$id/report.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "project=$project" \
    "kind=scout"
  [ -n "$TASKS_AXI_BIN" ] || fail "tasks-axi is required to prove complete --none is insufficient"
  (cd "$home" && tasks-axi add "$id" "Research compliance" --kind scout --repo shop --start >/dev/null) \
    || fail "could not create complete --none scout"
  out=$(PATH="$(dirname "$TASKS_AXI_BIN"):$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$DECISION_HOLD" complete "$id" --none 2>&1)
  rc=$?
  expect_code 0 "$rc" "fm-decision-hold.sh complete --none should remain valid local attestation"$'\n'"$out"

  set +e
  out=$(run_parent "$home" accept-child --project "$project" --state "$snap" \
    --child 5 --task "$id" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "complete --none must not satisfy accept-child"$'\n'"$out"
  assert_contains "$out" "local-completion-is-not-resolution" \
    "complete --none still masqueraded as Wayfinder resolution"
  pass "fm-decision-hold.sh complete --none alone remains insufficient"
}

test_map_dependent_spawn_and_promote() {
  local home project fakebin snap_bad snap_good out rc id
  home=$(make_home dispatch)
  project=$(make_gated_project "$home" shop)
  fakebin=$(fakebin_for "$home")
  snap_bad="$TMP_ROOT/dispatch-historical.json"
  snap_good="$TMP_ROOT/dispatch-resolved.json"
  write_snapshot "$snap_bad" historical
  write_snapshot "$snap_good" resolved

  id=ship-wayfinder-mvp
  write_ship_brief "$home" "$id"
  set +e
  out=$(run_spawn "$home" "$fakebin" "$id" "$project" claude --mode no-mistakes --yolo off \
    --wayfinder-state "$snap_bad")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "map-dependent spawn should refuse while handoff rejects"
  assert_contains "$out" "gate failed" "spawn did not surface the project handoff rejection"
  assert_absent "$home/state/$id.meta" "refused map-dependent spawn wrote task metadata"

  set +e
  out=$(run_spawn "$home" "$fakebin" "$id" "$project" claude --mode no-mistakes --yolo off)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "gated ship spawn without --wayfinder-state should refuse"
  assert_contains "$out" "bin/wayfinder-lifecycle-gate" \
    "missing snapshot did not name the project lifecycle command"
  assert_absent "$home/state/$id.meta" "state-less gated spawn wrote task metadata"

  set +e
  out=$(run_spawn "$home" "$fakebin" "$id" "$project" claude --mode no-mistakes --yolo off \
    --wayfinder-state "$snap_good")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "handoff-passing spawn should still stop before creating an endpoint in this fixture"
  assert_not_contains "$out" "gate failed" "passing handoff still refused the project command"
  assert_not_contains "$out" "local-completion-is-not-resolution" \
    "passing handoff still treated the child as unresolved"
  assert_absent "$home/state/$id.meta" "fixture spawn that passed handoff should still fail before metadata"

  id=wf-independent-docs
  write_ship_brief "$home" "$id"
  set +e
  out=$(run_spawn "$home" "$fakebin" "$id" "$project" claude --mode no-mistakes --yolo off \
    --wayfinder-independent)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "independent ship spawn should still stop before creating an endpoint in this fixture"
  assert_not_contains "$out" "gate failed" "map-independent spawn invoked handoff"
  assert_not_contains "$out" "pass --wayfinder-state" "map-independent spawn still required a snapshot"

  id=wf-research-scout
  write_scout_brief "$home" "$id"
  set +e
  out=$(run_spawn "$home" "$fakebin" "$id" "$project" claude --scout)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "scout spawn should still stop before creating an endpoint in this fixture"
  assert_not_contains "$out" "gate failed" "read-only scout spawn invoked handoff"
  assert_not_contains "$out" "pass --wayfinder-state" "scout spawn required a map snapshot"

  id=plain-ship
  write_ship_brief "$home" "$id"
  mkdir -p "$home/projects/plain"
  fm_git_init_commit "$home/projects/plain"
  set +e
  out=$(run_spawn "$home" "$fakebin" "$id" "$home/projects/plain" claude --mode no-mistakes --yolo off)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ungated ship spawn should still stop before creating an endpoint in this fixture"
  assert_not_contains "$out" "wayfinder-lifecycle-gate" \
    "a project without the lifecycle command picked up a Wayfinder handoff"

  id=promote-research
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$project" \
    "project=$project" \
    "harness=codex" \
    "kind=scout"
  set +e
  out=$(run_promote "$home" "$id" --mode no-mistakes --yolo off --wayfinder-state "$snap_bad")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "map-dependent promotion should refuse while handoff rejects"
  assert_contains "$out" "gate failed" "promotion did not surface the project handoff rejection"
  assert_grep "kind=scout" "$home/state/$id.meta" "refused promotion flipped the scout to a ship"

  set +e
  out=$(run_promote "$home" "$id" --mode no-mistakes --yolo off --wayfinder-state "$snap_good")
  rc=$?
  set -e
  expect_code 0 "$rc" "promotion with passing handoff should succeed"$'\n'"$out"
  assert_grep "kind=ship" "$home/state/$id.meta" "passing promotion did not become a ship"
  pass "map-dependent dispatch is refused while handoff rejects and allowed when it passes"
}

test_missing_project_command_is_loud() {
  local home project snap out rc
  home=$(make_home missing-gate)
  project="$home/projects/shop"
  mkdir -p "$project"
  snap="$TMP_ROOT/missing.json"
  write_snapshot "$snap" resolved
  set +e
  out=$(run_parent "$home" accept-child --project "$project" --state "$snap" --child 5 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing project command should be a usage failure"$'\n'"$out"
  assert_contains "$out" "bin/wayfinder-lifecycle-gate" \
    "missing project command did not name the lifecycle command to invoke"
  pass "parent check refuses when the consuming project has no lifecycle command"
}

test_historical_local_completion_is_not_resolution
test_resolved_research_and_decision_children_pass
test_complete_none_alone_remains_insufficient
test_map_dependent_spawn_and_promote
test_missing_project_command_is_loud
