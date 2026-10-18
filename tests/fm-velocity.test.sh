#!/usr/bin/env bash
# Behavior tests for bin/fm-velocity.sh - the velocity metrics collector.
#
# Covers the executable contract through throwaway fixtures with a fake gh:
# help output, collection of commits and lines from git history, PR counts
# from the forge, no-mistakes run counts from the state database, dashboard
# rendering with a multi-select project variable, and read-only clones.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VEL="$ROOT/bin/fm-velocity.sh"

make_repo() {
  local dir=$1 file_lines=$2
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.name "Test Agent"
  git -C "$dir" config user.email "agent@example.com"
  seq 1 "$file_lines" > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm "first"
  echo "extra" >> "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm "second"
}

make_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh: emit two PR lines for repo-a, one for anything else.
repo=""
for a in "$@"; do
  case "$a" in
    repos/*) repo="$a" ;;
  esac
done
case "$repo" in
  *repo-a*) printf '1 alice false\n2 bob false\n' ;;
  *) printf '7 alice false\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
}

make_state_db() {
  local home=$1 url=$2
  mkdir -p "$home/.no-mistakes"
  sqlite3 "$home/.no-mistakes/state.sqlite" <<SQL
CREATE TABLE repos(id TEXT PRIMARY KEY, working_path TEXT, upstream_url TEXT, default_branch TEXT DEFAULT 'main', created_at INTEGER);
CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, head_sha TEXT, base_sha TEXT, status TEXT DEFAULT 'pending', created_at INTEGER, updated_at INTEGER);
INSERT INTO repos(id, working_path, upstream_url, created_at) VALUES('r1', '/tmp/x', '$url', 1700000000);
INSERT INTO runs(id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES('run1', 'r1', 'b1', 'h1', 'b0', 'completed', 1700000001, 1700000002);
INSERT INTO runs(id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at) VALUES('run2', 'r1', 'b2', 'h2', 'b0', 'completed', 1700000003, 1700000004);
SQL
}

test_help() {
  "$VEL" --help >/tmp/vel-help.txt 2>&1
  assert_equals "0" "$?" "help exits zero"
  assert_contains "$(cat /tmp/vel-help.txt)" "Usage" "help shows usage"
}

test_collect_two_projects() {
  local root
  root=$(fm_test_tmproot)
  mkdir -p "$root/projects"
  printf -- "- repo-a [no-mistakes +yolo] - a (added 2026-01-01)\n- repo-b [no-mistakes +yolo] - b (added 2026-01-01)\n" > "$root/projects.md"
  make_repo "$root/projects/repo-a" 5
  make_repo "$root/projects/repo-b" 3
  git -C "$root/projects/repo-a" remote add origin git@github.com:owner/repo-a.git
  git -C "$root/projects/repo-b" remote add origin git@github.com:owner/repo-b.git
  local fakebin
  fakebin=$(fm_fakebin "$root/fake-collect")
  make_fake_gh "$fakebin"
  local fakehome="$root/home"
  mkdir -p "$fakehome"
  make_state_db "$fakehome" "git@github.com:owner/repo-a.git"
  HOME="$fakehome" PATH="$fakebin:$PATH" "$VEL" \
    --projects-file "$root/projects.md" --projects-dir "$root/projects" \
    --store "$root/velocity.json" --dashboard "$root/dashboard.json" >/tmp/vel-out.txt 2>&1
  assert_equals "0" "$?" "collect exits zero"
  python3 - "$root/velocity.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = d["projects"]["repo-a"]
b = d["projects"]["repo-b"]
assert a["prs"]["total"] == 2, a["prs"]
assert b["prs"]["total"] == 1, b["prs"]
assert a["prs"]["by_author"]["alice"] == 1, a["prs"]
assert a["commits"]["total"] == 2, a["commits"]
assert a["commits"]["added"] > 0, a["commits"]
assert a["no_mistakes_runs"]["total"] == 2, a["no_mistakes_runs"]
assert b["no_mistakes_runs"]["total"] == 0, b["no_mistakes_runs"]
print("store ok")
PY
  assert_equals "0" "$?" "store contents correct"
  python3 - "$root/dashboard.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["uid"] == "firstmate-velocity", d.get("uid")
v = d["templating"]["list"][0]
assert v["name"] == "project", v
assert v["multi"] is True and v["includeAll"] is True, v
names = [o["text"] for o in v["options"]]
assert "repo-a" in names and "repo-b" in names, names
assert len(d["panels"]) == 8, len(d["panels"])
titles = [p["title"] for p in d["panels"]]
assert "Per agent" in titles, titles
for p in d["panels"]:
    assert p["datasource"]["type"] == "grafana-testdata-datasource", p
    assert "$project" in json.dumps(p.get("transformations", [])), p["title"]
print("dashboard ok")
PY
  assert_equals "0" "$?" "dashboard contents correct"
}

test_clones_untouched() {
  local root
  root=$(fm_test_tmproot)
  mkdir -p "$root/projects"
  printf -- "- repo-a [no-mistakes +yolo] - a (added 2026-01-01)\n" > "$root/projects.md"
  make_repo "$root/projects/repo-a" 4
  git -C "$root/projects/repo-a" remote add origin git@github.com:owner/repo-a.git
  local before
  before=$(git -C "$root/projects/repo-a" status --porcelain=v1)
  local fakebin
  fakebin=$(fm_fakebin "$root/fake-clean")
  make_fake_gh "$fakebin"
  HOME="$root/home" PATH="$fakebin:$PATH" "$VEL" \
    --projects-file "$root/projects.md" --projects-dir "$root/projects" \
    --store "$root/v.json" --dashboard "$root/d.json" >/dev/null 2>&1
  local after
  after=$(git -C "$root/projects/repo-a" status --porcelain=v1)
  assert_equals "$before" "$after" "clone stays clean"
}

test_render_only() {
  local root
  root=$(fm_test_tmproot)
  cat > "$root/velocity.json" <<'JSON'
{"generated_at": "2026-01-01T00:00:00+00:00",
 "projects": {"solo": {"prs": {"total": 1, "by_author": {"alice": 1}},
  "commits": {"total": 2, "by_author": {"alice": 2}, "added": 10, "removed": 3,
   "added_by": {"alice": 10}, "removed_by": {"alice": 3}},
  "no_mistakes_runs": {"total": 4}}}}
JSON
  "$VEL" --render-only --store "$root/velocity.json" \
    --dashboard "$root/d.json" --projects-file "$root/velocity.json" >/dev/null 2>&1
  assert_equals "0" "$?" "render-only exits zero"
  python3 - "$root/d.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["templating"]["list"][0]["options"][1]["text"] == "solo"
print("render ok")
PY
  assert_equals "0" "$?" "render-only dashboard correct"
}

test_help
test_collect_two_projects
test_clones_untouched
test_render_only
pass "fm-velocity"
