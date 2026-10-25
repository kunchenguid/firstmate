#!/usr/bin/env bash
# Same-lane follow-up PR may reuse its own earlier frames; cross-task reuse must still fail.
# Task identity comes from lane meta / data/<task>, not the PR branch tip name.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
LINT=$ROOT/merge-on-green/fm-checks-lint.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/fm/state" "$d/fm/data/lane-alpha" "$d/fm/data/lane-beta" "$d/bin"
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d PATH="$d/bin:$PATH" FM_HOME=$d/fm
mkdir -p "$HOME" "$XDG_DATA_HOME"

printf 'frame-alpha\n' > "$d/fm/data/lane-alpha/shot.png"
printf 'frame-beta-other\n' > "$d/fm/data/lane-beta/other.png"
# First claim: local report under the lane folder records hashes as lane-alpha.
cat > "$d/fm/data/lane-alpha/report.md" <<'EOF'
## Checks
outcome: lane recorded its own frame
repro: n/a: no bug
proof: no verify skill - bash fixture
evidence: shot.png
EOF
"$LINT" "$d/fm/data/lane-alpha/report.md" "$d/fm/data/lane-alpha" >/dev/null
grep -Eq ' lane-alpha$' "$d/fm/data/checks-gate.hashes" || {
  echo "FAIL: expected hash owner lane-alpha; got: $(cat "$d/fm/data/checks-gate.hashes")" >&2
  exit 1
}

# Follow-up PR from the same lane: branch tip name differs from the lane folder.
cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view'*)
    case "$3" in
      *pull/2) name=lane-alpha-pr2 ;;
      *pull/3) name=totally-other-branch ;;
      *) echo "unexpected pr: $3" >&2; exit 2 ;;
    esac
    printf '%s\n' "{\"author\":{\"login\":\"umer\"},\"body\":\"## Checks\\noutcome: follow-up reuses lane frames\\nrepro: n/a: no bug\\nproof: no verify skill - bash fixture\\nevidence: shot.png\\n\",\"title\":\"feat: follow-up\",\"files\":[{\"path\":\"a.txt\",\"additions\":1}],\"headRefOid\":\"abc\",\"headRefName\":\"fm/$name\",\"baseRefOid\":\"base\"}"
    ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$d/bin/gh"
printf 'pr=https://github.com/owner/repo/pull/2\nbranch=fm/lane-alpha-pr2\n' > "$d/fm/state/lane-alpha.meta"

set +e
same=$(FM_HOME=$d/fm "$LINT" 'https://github.com/owner/repo/pull/2' "$d/fm/data/lane-alpha" 2>&1)
same_rc=$?
set -e
[ "$same_rc" -eq 0 ] && [[ "$same" == *'checks-lint: PASS:'* ]] || {
  echo "FAIL same-lane follow-up should PASS: rc=$same_rc ($same)" >&2
  exit 1
}
echo "PASS same-lane follow-up reuses its own frames"

# True cross-task reuse: another lane cites the same bytes.
cp "$d/fm/data/lane-alpha/shot.png" "$d/fm/data/lane-beta/shot.png"
printf 'pr=https://github.com/owner/repo/pull/3\n' > "$d/fm/state/lane-beta.meta"
cat > "$d/fm/data/lane-beta/report.md" <<'EOF'
## Checks
outcome: other lane steals the frame
repro: n/a: no bug
proof: no verify skill - bash fixture
evidence: shot.png
EOF
set +e
cross=$(FM_HOME=$d/fm "$LINT" 'https://github.com/owner/repo/pull/3' "$d/fm/data/lane-beta" 2>&1)
cross_rc=$?
set -e
[ "$cross_rc" -ne 0 ] && [[ "$cross" == *'every evidence file was already used by another PR'* ]] || {
  echo "FAIL cross-task reuse should FAIL: rc=$cross_rc ($cross)" >&2
  exit 1
}
echo "PASS cross-task reuse still fails"
echo 'PASS: lane-task frame-reuse identity'
