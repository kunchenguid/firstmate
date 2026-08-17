#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only ordinary mirror updates plus
# verified installation of an intentional prompt overlay on a newer upstream.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

new_overlay_world() { # <name> <safe|owned|conflict>
  local w mode=$2 base
  w=$(new_world "$1")
  base=$(git -C "$w/main" rev-parse HEAD)
  cp "$ROOT/bin/fm-prompt-overlay.py" "$w/main/bin/fm-prompt-overlay.py"
  cp "$ROOT/bin/fm-prompt-semantic-refresh.py" "$w/main/bin/fm-prompt-semantic-refresh.py"
  cat > "$w/main/bin/fm-operation-disclosure.py" <<'PY'
#!/usr/bin/env python3
import sys
if sys.argv[1] == "disclose":
    print("FM_DISCLOSURE_TOKEN=" + "0" * 64)
PY
  chmod +x "$w/main/bin/fm-operation-disclosure.py"
  printf 'optimized\n' > "$w/main/AGENTS.md"
  python3 - "$w/main/docs/verification/prompt-lineage.json" "$base" "$mode" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1]); path.parent.mkdir(parents=True, exist_ok=True)
value = {"schema_version": 4, "generations": [{"generation": 0}, {"generation": 1, "kind": "live-overlay", "upstream_commit": sys.argv[2]}], "overlay_paths": ["AGENTS.md", "bin/fm-operation-disclosure.py", "bin/fm-prompt-overlay.py", "bin/fm-prompt-semantic-refresh.py", "docs/verification/prompt-lineage.json"]}
if sys.argv[3] == "owned":
    value["live_authority_sha256"] = {"AGENTS.md": __import__("hashlib").sha256(path.parents[2].joinpath("AGENTS.md").read_bytes()).hexdigest()}
path.write_text(json.dumps(value) + "\n")
PY
  git -C "$w/main" add -A && git -C "$w/main" commit -qm 'installed optimized overlay'
  git -C "$w/main" update-ref refs/firstmate/overlays/live "$base"
  if [ "$mode" = conflict ] || [ "$mode" = owned ]; then
    printf 'upstream conflict\n' > "$w/seed/AGENTS.md"
  else
    printf 'new upstream\n' >> "$w/seed/README.md"
  fi
  git -C "$w/seed" add -A && git -C "$w/seed" commit -qm "new-upstream-$mode"
  git -C "$w/seed" push -q origin main
  printf '%s\n' "$w"
}

test_verified_overlay_requires_explicit_install_approval() {
  local w out approval installed candidate ref plan token
  w=$(new_overlay_world t12 safe)
  installed=$(git -C "$w/main" rev-parse HEAD)
  out=$(run_update "$w")
  assert_contains "$out" "overlay-install: approval-required" "overlay update reaches explicit approval"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$installed" ] || fail "main moved while overlay only ready"
  [ "$(git -C "$w/main" rev-parse refs/firstmate/overlays/live)" != "$installed" ] || fail "stale live ref unexpectedly changed before approval"
  approval=$(printf '%s\n' "$out" | grep '^overlay-install: approval-required')
  candidate=$(printf '%s\n' "$approval" | sed -n 's/.* candidate=\([^ ]*\).*/\1/p')
  ref=$(printf '%s\n' "$approval" | sed -n 's/.* ref=\([^ ]*\).*/\1/p')
  plan=$(printf '%s\n' "$approval" | sed -n 's/.* plan=\([^ ]*\).*/\1/p')
  token=$(printf '%s\n' "$approval" | sed -n 's/.* token=\([^ ]*\).*/\1/p')
  if FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" --install-overlay --plan "$plan" --candidate-ref "$ref" --token "$token" --approve-candidate deadbeef >/dev/null 2>&1; then
    fail "wrong candidate approval installed overlay"
  fi
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$installed" ] || fail "main moved after wrong approval"
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" --install-overlay --plan "$plan" --candidate-ref "$ref" --token "$token" --approve-candidate "$candidate" >/dev/null
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$candidate" ] || fail "approved candidate was not installed"
  [ "$(git -C "$w/main" rev-parse refs/firstmate/overlays/live)" = "$candidate" ] || fail "live ref does not name installed candidate"
  [ "$(git -C "$w/main" rev-parse refs/firstmate/overlays/previous)" = "$installed" ] || fail "rollback ref does not name prior installed overlay"
  [ -z "$(git -C "$w/main" status --porcelain)" ] || fail "approved overlay installation left a dirty tree"
  pass "T12 compatible installed overlay is verified before exact approval and atomic installation"
}

new_semantic_overlay_world() {
  local w base update_mode=${2:-semantic} path
  w=$(new_world "$1")
  cat > "$w/seed/AGENTS.md" <<'EOF'
# Firstmate
Always loaded.
## Deferred detail
Existing deferred rule.
EOF
  mkdir -p "$w/seed/.agents/skills/demo"
  cat > "$w/seed/.agents/skills/demo/SKILL.md" <<'EOF'
---
name: demo
description: A deliberately verbose upstream discovery description for the demo skill.
---
# Demo
Old body rule.
EOF
  for path in \
    .claude/settings.json .codex/hooks.json bin/fm-brief.sh \
    bin/fm-classify-lib.sh bin/fm-harness.sh bin/fm-marker-lib.sh \
    bin/fm-operational-input.sh bin/fm-supervision-instructions.sh \
    docs/supervision-protocols/claude.md docs/supervision-protocols/codex.md \
    docs/supervision-protocols/cursor.md docs/supervision-protocols/grok.md \
    docs/supervision-protocols/opencode.md docs/supervision-protocols/pi.md \
    docs/supervision-protocols/unknown.md; do
    mkdir -p "$w/seed/$(dirname "$path")"
    printf 'parity fixture: %s\n' "$path" > "$w/seed/$path"
  done
  mkdir -p "$w/seed/docs/verification/prompt-preservation/upstream"
  printf 'initial parity artifact\n' > "$w/seed/docs/verification/prompt-preservation/upstream/generated-parity.tar.gz.b64"
  git -C "$w/seed" add -A && git -C "$w/seed" commit -qm semantic-base
  git -C "$w/seed" push -q origin main
  git -C "$w/main" pull -q --ff-only
  base=$(git -C "$w/main" rev-parse HEAD)
  cp "$ROOT/bin/fm-prompt-overlay.py" "$w/main/bin/fm-prompt-overlay.py"
  cp "$ROOT/bin/fm-prompt-semantic-refresh.py" "$w/main/bin/fm-prompt-semantic-refresh.py"
  cat > "$w/main/bin/fm-operation-disclosure.py" <<'PY'
#!/usr/bin/env python3
import sys
if sys.argv[1] == "disclose": print("FM_DISCLOSURE_TOKEN=" + "0" * 64)
PY
  chmod +x "$w/main/bin/fm-operation-disclosure.py"
  cat > "$w/main/AGENTS.md" <<'EOF'
# Firstmate
Always loaded.
Load deferred detail when needed.
EOF
  printf '# Deferred detail\nExisting deferred rule.\n' > "$w/main/FIRSTMATE_DETAIL.md"
  python3 - "$w/main/.agents/skills/demo/SKILL.md" <<'PY'
from pathlib import Path
p=Path(__import__('sys').argv[1]); s=p.read_text(); p.write_text(s.replace('A deliberately verbose upstream discovery description for the demo skill.', 'Load for demo work.'))
PY
  python3 - "$w/main/docs/verification/prompt-lineage.json" "$base" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]); root=p.parents[2]
owners=['AGENTS.md','FIRSTMATE_DETAIL.md','.agents/skills/demo/SKILL.md']
artifact='docs/verification/prompt-preservation/upstream/generated-parity.tar.gz.b64'
encoded=(root/artifact).read_bytes()
live={'generation':1,'kind':'live-overlay','upstream_commit':sys.argv[2],
      'generated_parity_artifact':artifact,
      'generated_parity_artifact_sha256':hashlib.sha256(encoded).hexdigest(),
      'generated_parity_archive_sha256':hashlib.sha256(encoded).hexdigest()}
v={'schema_version':4,'generations':[{'generation':0},live],
   'overlay_paths':owners+[artifact,'bin/fm-operation-disclosure.py','bin/fm-prompt-overlay.py','bin/fm-prompt-semantic-refresh.py','docs/verification/prompt-lineage.json'],
   'live_authority_sha256':{x:hashlib.sha256((root/x).read_bytes()).hexdigest() for x in owners}}
p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(v)+'\n')
PY
  git -C "$w/main" add -A && git -C "$w/main" commit -qm optimized-overlay
  git -C "$w/main" update-ref refs/firstmate/overlays/live HEAD
  if [ "$update_mode" = semantic ]; then
    printf 'New upstream semantic rule.\n' >> "$w/seed/AGENTS.md"
    printf 'New body rule.\n' >> "$w/seed/.agents/skills/demo/SKILL.md"
  else
    mkdir -p "$w/seed/.github/workflows"
    printf 'name: unrelated\n' > "$w/seed/.github/workflows/ci.yml"
  fi
  git -C "$w/seed" add -A && git -C "$w/seed" commit -qm "$update_mode-upstream"
  git -C "$w/seed" push -q origin main
  printf '%s\n' "$w"
}

test_semantic_forward_port_reaches_optimized_owners() {
  local w out approval candidate count
  w=$(new_semantic_overlay_world t-semantic)
  out=$(run_update "$w")
  assert_contains "$out" "overlay-install: approval-required" "mapped semantic refresh reaches readiness"
  approval=$(printf '%s\n' "$out" | grep '^overlay-install: approval-required')
  candidate=$(printf '%s\n' "$approval" | sed -n 's/.* candidate=\([^ ]*\).*/\1/p')
  count=$(git -C "$w/main" grep -F 'New upstream semantic rule.' "$candidate" -- AGENTS.md 'FIRSTMATE_*.md' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "upstream AGENTS addition was not represented exactly once"
  git -C "$w/main" show "$candidate:FIRSTMATE_DETAIL.md" | grep -qF 'New upstream semantic rule.' || fail "AGENTS addition missed deferred owner"
  git -C "$w/main" show "$candidate:.agents/skills/demo/SKILL.md" | grep -qF 'New body rule.' || fail "skill body change was omitted"
  git -C "$w/main" show "$candidate:.agents/skills/demo/SKILL.md" | grep -qF 'description: Load for demo work.' || fail "compact skill discovery description was lost"
  pass "T13 mapped AGENTS and skill semantics forward-port through optimized owners"
}

test_unrelated_update_refreshes_exact_lineage_bindings() {
  local w out approval candidate upstream installed
  w=$(new_semantic_overlay_world t-unrelated unrelated)
  installed=$(git -C "$w/main" rev-parse HEAD)
  out=$(run_update "$w")
  upstream=$(git -C "$w/main" rev-parse origin/main)
  assert_contains "$out" "overlay-install: approval-required" "unrelated update reaches overlay readiness"
  approval=$(printf '%s\n' "$out" | grep '^overlay-install: approval-required')
  candidate=$(printf '%s\n' "$approval" | sed -n 's/.* candidate=\([^ ]*\).*/\1/p')
  python3 - "$w/main" "$candidate" "$upstream" "$installed" <<'PY'
import base64, hashlib, json, subprocess, sys
from pathlib import Path
repo, candidate, upstream, installed = Path(sys.argv[1]), *sys.argv[2:]
def git(*args):
    return subprocess.check_output(('git', *args), cwd=repo).strip()
assert git('show', '-s', '--format=%P', candidate).decode() == upstream
assert git('rev-parse', f'{candidate}:.github/workflows/ci.yml') == git('rev-parse', f'{upstream}:.github/workflows/ci.yml')
for path in ('AGENTS.md', '.agents/skills/demo/SKILL.md'):
    assert git('rev-parse', f'{candidate}:{path}') == git('rev-parse', f'{installed}:{path}')
lineage = json.loads(git('show', f'{candidate}:docs/verification/prompt-lineage.json'))
live = next(item for item in lineage['generations'] if item.get('kind') == 'live-overlay')
assert live['upstream_commit'] == upstream
refresh = lineage['semantic_refresh']
assert refresh['previous_upstream'] != upstream
assert refresh['upstream'] == upstream
assert refresh['changes'] == []
artifact = subprocess.check_output(('git', 'show', f"{candidate}:{live['generated_parity_artifact']}"), cwd=repo)
archive = base64.b64decode(artifact.strip(), validate=True)
assert hashlib.sha256(artifact).hexdigest() == live['generated_parity_artifact_sha256']
assert hashlib.sha256(archive).hexdigest() == live['generated_parity_archive_sha256']
PY
  [ $? -eq 0 ] || fail "unrelated candidate lineage bindings are stale"
  pass "T14 unrelated upstream updates refresh exact lineage and parity bindings"
}

test_hash_bound_overlay_cannot_mask_unmapped_semantics() {
  local w out installed live
  w=$(new_overlay_world t13 owned)
  installed=$(git -C "$w/main" rev-parse HEAD)
  live=$(git -C "$w/main" rev-parse refs/firstmate/overlays/live)
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1)
  assert_contains "$out" "unmapped" "hash-bound semantic owner reports its unresolved mapping"
  assert_not_contains "$out" "overlay-install: approval-required" "unmapped semantic change is not ready"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$installed" ] || fail "unmapped overlay preparation moved main"
  [ "$(git -C "$w/main" rev-parse refs/firstmate/overlays/live)" = "$live" ] || fail "unmapped overlay preparation moved live ref"
  pass "T13 hash-bound overlay cannot mask an unmapped upstream semantic change"
}

test_ambiguous_overlay_refuses_without_ref_moves() {
  local w out installed live
  w=$(new_overlay_world t14 conflict)
  installed=$(git -C "$w/main" rev-parse HEAD)
  live=$(git -C "$w/main" rev-parse refs/firstmate/overlays/live)
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1)
  assert_contains "$out" "unmapped" "semantic-owner conflict is visible"
  assert_not_contains "$out" "overlay-install: approval-required" "ambiguous overlay is not ready"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$installed" ] || fail "ambiguous overlay moved main"
  [ "$(git -C "$w/main" rev-parse refs/firstmate/overlays/live)" = "$live" ] || fail "ambiguous overlay moved live ref"
  pass "T14 unbound overlapping overlay/upstream change refuses before any installed refs move"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_verified_overlay_requires_explicit_install_approval
test_semantic_forward_port_reaches_optimized_owners
test_unrelated_update_refreshes_exact_lineage_bindings
test_hash_bound_overlay_cannot_mask_unmapped_semantics
test_ambiguous_overlay_refuses_without_ref_moves

echo "# all fm-update tests passed"
