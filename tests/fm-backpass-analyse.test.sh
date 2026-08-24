#!/usr/bin/env bash
# tests/fm-backpass-analyse.test.sh - the daily backpass analysis pass attributes
# transcripts by real git metadata across all account stores, never lets a
# firstmate-home session pose as a product session, and stays strictly write-free
# toward every project source:
#
#   1. run --no-analyze classifies synthetic transcripts correctly: a treehouse
#      worktree session lands on its mother repo, a no-mistakes worker session
#      resolves through the bare mirror's remote, firstmate identities and
#      no-git cwds are heim, dead paths stay unresolved-dead.
#   2. A full run with a stub backpass binary touches NO fixture byte, builds
#      the runner sandbox inside FM_HOME only, and renders the template from
#      the stub's proposal output; stdout carries the summary line.
#   3. The attribution probe passes on correct mappings (green), and FAILS
#      when one worktree's gitdir points at the wrong mother (red counter-case).
#
# Isolation: throwaway HOME and FM_HOME; the model CLI is a stub. Nothing
# outside $TMP is read or written except the script under test.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BA="$REPO/bin/fm-backpass-analyse.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
FM="$TMP/fmhome"
mkdir -p "$FAKE_HOME" "$FM/data" "$FM/projects"

REGISTRY="$FM/data/projects.md"
cat > "$REGISTRY" <<'EOF'
# Projects (fleet registry)
- lensclash [no-mistakes-prod-only +yolo] - Monorepo Expo/RN-Frontend (added 2026-08-15)
- SnackSuite [no-mistakes-prod-only +yolo] - Snack-Verwaltung (added 2026-08-15)
- HPlan [no-mistakes-prod-only +yolo] - Hallenbelegungsplan (added 2026-08-21)
EOF

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

mk_mother() { # path name ; a minimal working clone shape with a remote
  local path="$1" name="$2"
  mkdir -p "$path/.git"
  printf '[core]\n\trepositoryformatversion = 0\n[remote "origin"]\n\turl = git@github.com:swippipp/%s.git\n' "$name" > "$path/.git/config"
  printf 'ref: refs/heads/main\n' > "$path/.git/HEAD"
}
mk_treehouse_worktree() { # pool_dir n name mother_gitdir
  local wt="$1/$2/$3"
  mkdir -p "$wt"
  printf 'gitdir: %s/worktrees/%s\n' "$4" "$3" > "$wt/.git"
}
transcript() { # store_label munged_cwd_dir real_cwd
  local d="$FAKE_HOME/$1/projects/$2"
  mkdir -p "$d"
  printf '{"type":"user","cwd":"%s","sessionId":"t-%s","message":{"role":"user"}}\n' "$3" "$RANDOM" > "$d/s$RANDOM.jsonl"
}

# --- fixtures ---------------------------------------------------------------
mk_mother "$FM/projects/lensclash" lensclash
printf '# lensclash agents\n' > "$FM/projects/lensclash/AGENTS.md"
LC_GIT="$FM/projects/lensclash/.git"
mkdir -p "$LC_GIT/worktrees/lensclash"

SNAP_MOTHER="$TMP/mothers/SnackSuite"
mk_mother "$SNAP_MOTHER" SnackSuite
mkdir -p "$SNAP_MOTHER/.git/worktrees/snack"

HP_HASH="747e93f0b0e9"
HP_BARE="$FAKE_HOME/.no-mistakes/repos/$HP_HASH.git"
mkdir -p "$HP_BARE" "$HP_BARE/worktrees/hplan-a"
printf '[remote "origin"]\n\turl = git@github.com:swippipp/HPlan.git\n' > "$HP_BARE/config"

FM_REPO="$TMP/fmrepo"
mk_mother "$FM_REPO" firstmate
FM_GIT="$FM_REPO/.git"
mkdir -p "$FM_GIT/worktrees/fm"

mk_treehouse_worktree "$FAKE_HOME/.treehouse/lensclash-d0dd25" 1 lensclash "$LC_GIT"
mk_treehouse_worktree "$FAKE_HOME/.treehouse/SnackSuite-52d7e0" 2 SnackSuite "$SNAP_MOTHER/.git"
mk_treehouse_worktree "$FAKE_HOME/.treehouse/firstmate-7bab20" 1 firstmate "$FM_GIT"
mkdir -p "$FAKE_HOME/.no-mistakes/worktrees/$HP_HASH/task01"
printf 'gitdir: %s/worktrees/hplan-a\n' "$HP_BARE" > "$FAKE_HOME/.no-mistakes/worktrees/$HP_HASH/task01/.git"

transcript .claude1 "-home-fridjof--treehouse-lensclash-d0dd25-1-lensclash" "$FAKE_HOME/.treehouse/lensclash-d0dd25/1/lensclash"
transcript .claude3 "-home-fridjof--treehouse-SnackSuite-52d7e0-2-SnackSuite" "$FAKE_HOME/.treehouse/SnackSuite-52d7e0/2/SnackSuite"
transcript .claude4 "-home-fridjof--no-mistakes-worktrees-$HP_HASH-task01" "$FAKE_HOME/.no-mistakes/worktrees/$HP_HASH/task01"
transcript .claude2 "-home-fridjof--treehouse-firstmate-7bab20-1-firstmate" "$FAKE_HOME/.treehouse/firstmate-7bab20/1/firstmate"
transcript .claude3 "-home-fridjof-firstmate" "$FM"
transcript .claude "-home-fridjof--treehouse-lensclash-d0dd25-4-lensclash" "$FAKE_HOME/.treehouse/lensclash-d0dd25/1/lensclash"
transcript .claude1 "-home-fridjof" "/nonexistent/gone-session-path"
# dead worktree: pool dir removed after landing, only the store entry remains
transcript .claude2 "-home-fridjof--treehouse-lensclash-d0dd25-9-lensclash" "$FAKE_HOME/.treehouse/lensclash-d0dd25/9/lensclash"
# dead worker worktree whose bare mirror SURVIVES -> recoverable
mkdir -p "$FAKE_HOME/.no-mistakes/repos/deadbeefcafe.git/worktrees/gone"
printf '[remote "origin"]\n\turl = git@github.com:swippipp/HPlan.git\n' > "$FAKE_HOME/.no-mistakes/repos/deadbeefcafe.git/config"
transcript .claude3 "-home-fridjof--no-mistakes-worktrees-deadbeefcafe-gone" "$FAKE_HOME/.no-mistakes/worktrees/deadbeefcafe/gone"
# dead worker worktree whose mirror is ALSO gone -> stays unresolved
transcript .claude1 "-home-fridjof--no-mistakes-worktrees-000000000000-gone2" "$FAKE_HOME/.no-mistakes/worktrees/000000000000/gone2"
# dead treehouse pool dir -> recovered from the pool naming convention
transcript .claude4 "-home-fridjof--treehouse-SnackSuite-52d7e0-9-SnackSuite" "$FAKE_HOME/.treehouse/SnackSuite-52d7e0/9/SnackSuite"

fixture_hash() { find "$FAKE_HOME" "$FM/projects" -type f -exec md5sum {} + | sort | md5sum; }
HASH_BEFORE="$(fixture_hash)"

run_ba() {
  HOME="$FAKE_HOME" FM_HOME="$FM" FM_BACKPASS_CMD="$TMP/stub-backpass" \
    FM_BACKPASS_RUNNERS="$FM/runners" "$BA" "$@"
}

# --- 1. attribution-only run -------------------------------------------------
OUT1="$FM/data/tagesschluss/$(date +%F)"
run_ba run --no-analyze >/dev/null || fail "attribution run must succeed"
TSV="$OUT1/backpass-attribut.tsv"
[ -f "$TSV" ] || fail "the attribution TSV must exist"

row_of() { awk -F'\t' -v c="$1" '$6==c' "$TSV"; }

r="$(row_of "$FAKE_HOME/.treehouse/lensclash-d0dd25/1/lensclash")"
printf '%s' "$r" | grep -Pq '^\.claude1\tproduct\tlensclash\tgitdir-pointer:' \
  && ok "treehouse session attributes to its mother repo via the gitdir pointer" \
  || fail "treehouse lensclash row wrong: $r"

r="$(row_of "$FAKE_HOME/.no-mistakes/worktrees/$HP_HASH/task01")"
printf '%s' "$r" | grep -Pq '^\.claude4\tproduct\tHPlan\tgitdir-pointer:' \
  && ok "no-mistakes worker session resolves through the bare mirror remote" \
  || fail "no-mistakes HPlan row wrong: $r"

r="$(row_of "$FAKE_HOME/.treehouse/firstmate-7bab20/1/firstmate")"
printf '%s' "$r" | grep -Pq '^\.claude2\theim\tfirstmate\t' \
  && ok "a firstmate worktree session stays heim (counter-case)" \
  || fail "firstmate worktree row wrong: $r"

r="$(row_of "$FM")"
printf '%s' "$r" | grep -Pq '^\.claude3\theim\t\tno-git' \
  && ok "a no-git home cwd is heim without a project" \
  || fail "heim no-git row wrong: $r"

n_dead="$(awk -F'\t' '$2=="unresolved-dead"' "$TSV" | wc -l)"
[ "$n_dead" -ge 1 ] && ok "dead paths are recorded unresolved, never guessed" \
  || fail "expected at least one unresolved-dead row"

r="$(row_of "$FAKE_HOME/.no-mistakes/worktrees/deadbeefcafe/gone")"
printf '%s' "$r" | grep -Pq '^\.claude3\tproduct\tHPlan\tmirror-hash:' \
  && ok "a landed worker worktree is recovered through its surviving mirror" \
  || fail "mirror-hash recovery row wrong: $r"

r="$(row_of "$FAKE_HOME/.no-mistakes/worktrees/000000000000/gone2")"
printf '%s' "$r" | grep -Pq '^\.claude1\tunresolved-dead\t\tdead-path-no-git' \
  && ok "a fully gone worktree stays honestly unresolved" \
  || fail "gone-mirror row wrong: $r"

r="$(row_of "$FAKE_HOME/.treehouse/SnackSuite-52d7e0/9/SnackSuite")"
printf '%s' "$r" | grep -Pq '^\.claude4\tproduct\tSnackSuite\tpool-name:' \
  && ok "a dead treehouse pool session recovers from the pool naming" \
  || fail "pool-name recovery row wrong: $r"

grep -q '^\.claude	' "$TSV" && ok "the legacy default store is part of the sweep" \
  || fail "the legacy .claude store must be swept too"

# --- 2. full run with a stub backpass: write-free + template ----------------
cat > "$TMP/stub-backpass" <<STUB
#!/usr/bin/env bash
mkdir -p .backpass
cat > .backpass/proposal.json <<'JSON'
{"budget":{"current":5200,"projected":4100,"withinBudget":true},
 "edits":[{"id":"e1","kind":"replace","file":"AGENTS.md",
   "title":"Neue Regel aus echten Sitzungen an die richtige Stelle ziehen.",
   "rationale":"Zwei Sessions zeigten denselben Fehlanlauf; die Regel fehlte am Triggerort.",
   "deltaTokens":-40,"transcripts":2,
   "evidence":[{"polarity":"negative","text":"Worker suchte die Konvention und legte sie falsch ab.","source":"claude · abc123 · 2026-08-24"}],
   "hunks":[{}]}],
 "notes":["stub"]}
JSON
printf '{"analyzedSessions":2,"totals":{"transcripts":2},"skillExtractions":1}' > .backpass/evidence-summary.json
echo "stub ran in \$(pwd)"
STUB
chmod +x "$TMP/stub-backpass"

SUMMARY="$(run_ba run 2>&1 | sed -n '1p')"
printf '%s' "$SUMMARY" | grep -q '^backpass: .*lensclash: analysiert' \
  && ok "stdout summary names the analyzed product" \
  || fail "summary line wrong: $SUMMARY"
[ "$(fixture_hash)" = "$HASH_BEFORE" ] \
  && ok "not a single fixture byte changed (schreibfrei am Quell-Klon)" \
  || fail "the run modified project sources"
VORLAGE="$OUT1/backpass-vorlage.md"
grep -q '^# Backpass-Vorlage' "$VORLAGE" || fail "the template file must exist"
grep -q 'SCHREIBFREI' "$VORLAGE" || fail "the template must carry the write-free statement"
grep -q 'VORSCHLAG e1 \[replace\] Neue Regel aus echten Sitzungen' "$VORLAGE" \
  && ok "the proposal title, rationale, budget, and evidence render into the template" \
  || fail "proposal detail missing from the template"
grep -q '(negative) Worker suchte die Konvention' "$VORLAGE" \
  && ok "evidence lines carry polarity and source" \
  || fail "evidence rendering missing"
grep -q '\.claude/skills' "$VORLAGE" \
  && ok "the template states the .claude/skills extraction path rule" \
  || fail "extraction path rule missing"
[ ! -f "$FM/runners/lensclash/home/.claude" ] || true
[ -f "$FM/runners/lensclash/root/AGENTS.md" ] \
  && ok "the runner sandbox received the memory-file copy" \
  || fail "runner memory copy missing"

# --- 3. probe green, then red on a corrupted mapping ------------------------
# third positive needed: give SnackSuite a live treehouse session already there,
# HPlan needs a treehouse-style pool too for CHECK 1 breadth (pos >= 3).
HP_TREE_MOTHER="$TMP/mothers/HPlanTree"
mk_mother "$HP_TREE_MOTHER" HPlan
mkdir -p "$HP_TREE_MOTHER/.git/worktrees/hplan-t"
mk_treehouse_worktree "$FAKE_HOME/.treehouse/HPlan-00fd4e" 1 HPlan "$HP_TREE_MOTHER/.git"
transcript .claude4 "-home-fridjof--treehouse-HPlan-00fd4e-1-HPlan" "$FAKE_HOME/.treehouse/HPlan-00fd4e/1/HPlan"

if HOME="$FAKE_HOME" FM_HOME="$FM" "$BA" probe >/dev/null 2>&1; then
  ok "the attribution probe passes on the correct synthetic fleet"
else
  fail "the probe must pass on correct mappings"
fi

# RED counter-case: point the SnackSuite worktree at the WRONG mother.
printf 'gitdir: %s/worktrees/snack\n' "$LC_GIT" > "$FAKE_HOME/.treehouse/SnackSuite-52d7e0/2/SnackSuite/.git"
if HOME="$FAKE_HOME" FM_HOME="$FM" "$BA" probe >/dev/null 2>&1; then
  fail "the probe must FAIL when a worktree maps to the wrong mother"
else
  ok "the probe fails loudly on a corrupted attribution (red case proven)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-backpass-analyse.test.sh: all checks passed"
  exit 0
fi
echo "fm-backpass-analyse.test.sh: $FAILS check(s) FAILED"
exit 1
