#!/usr/bin/env bash
# E2E: a file git resolves as a rename at 50% similarity or more counts as moved, not added, so a
# history-preserving import lands; added lines past that similarity budget still count as new code
# (no network: stub gh answers the PR, its pages, its diff and the moved file's previous content).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
LINT=$ROOT/merge-on-green/fm-checks-lint.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/bin" "$d/home" "$d/xdg" "$d/fm/state" "$d/fm/data/evidence"
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d PATH="$d/bin:$PATH" FM_HOME=$d/fm
printf '## Checks\noutcome: move fixture\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: not proven: fixture\n' > "$d/body.txt"
printf '%s\n' '## Checks' 'outcome: move fixture' 'repro: n/a: no bug' 'proof: no verify skill - bash fixture' 'evidence: not proven: fixture' '' 'moved-from: owner/src@ref1 addons/=' > "$d/body-move.txt"

cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env python3
# Stub gh: one PR per case, each at or over the 1,000-line limit.
import json, os, re, sys
a = sys.argv[1:]
case = os.environ['CASE']

def lines(prefix, n):
    return ['%s-%d' % (prefix, i) for i in range(n)]

# new path -> content at the PR head, and (repo, previous path, previous ref) -> content before the move
PR = {
    # A 400-line file moved with 20 rewritten lines: 95% similar, so all 400 lines stay inside the budget.
    'moved': {'new': {'addons/moved.txt': lines('line', 380) + lines('path', 20)},
              'old': {('owner/src', 'moved.txt', 'ref1'): lines('line', 380) + lines('old', 20)},
              'added': 900, 'rename': False},
    # 340 of 400 lines carried over: 85% similar, so the 60 rewritten lines past the budget are new code.
    'grown': {'new': {'addons/grown.txt': lines('line', 340) + lines('path', 60)},
              'old': {('owner/src', 'grown.txt', 'ref1'): lines('line', 340) + lines('old', 20)},
              'added': 950, 'rename': False},
    # Only 100 of 400 lines carried over: 25% similar, below the rename threshold, so nothing is moved.
    'rewritten': {'new': {'addons/rewritten.txt': lines('line', 100) + lines('path', 300)},
                  'old': {('owner/src', 'rewritten.txt', 'ref1'): lines('line', 100) + lines('old', 300)},
                  'added': 950, 'rename': False},
    # Same repo: the pull-files API resolves old/y.txt -> new/y.txt as a rename at 90% similarity.
    'renamed': {'new': {'new/y.txt': lines('line', 360) + lines('path', 40)},
                'old': {('owner/repo', 'old/y.txt', 'base1'): lines('line', 360) + lines('old', 40)},
                'added': 900, 'rename': True},
}

def section(path, new):
    return ['diff --git a/%s b/%s' % (path, path), 'new file mode 100644', '--- /dev/null',
            '+++ b/%s' % path, '@@ -0,0 +1,%d @@' % len(new)] + ['+' + l for l in new]

def files():
    f = PR[case]
    out = [{'path': p, 'additions': len(c), 'status': 'renamed' if f['rename'] else 'added',
            'previous_filename': 'old/y.txt' if f['rename'] else None} for p, c in f['new'].items()]
    return out + [{'path': 'authored/new.txt', 'additions': f['added'], 'status': 'added', 'previous_filename': None}]

if a[:2] == ['pr', 'view']:
    print(json.dumps({'author': {'login': 'umer'}, 'body': open(os.environ['CASE_BODY']).read(),
                      'title': 'feat: import', 'headRefOid': 'head1', 'headRefName': 'fm/import',
                      'baseRefOid': 'base1', 'files': [{'path': f['path'], 'additions': f['additions']} for f in files()]}))
elif a[0] == 'api' and '/files?' in a[1]:
    page = int(a[1].rsplit('page=', 1)[1])
    print(json.dumps(files()[(page - 1) * 100:page * 100]))
elif a[0] == 'api' and 'Accept: application/vnd.github.diff' in a:
    f, out = PR[case], []
    for p, c in list(f['new'].items()) + [('authored/new.txt', lines('authored', f['added']))]:
        out += section(p, c)
    print('\n'.join(out))
elif a[0] == 'api' and 'Accept: application/vnd.github.raw' in a:
    m = re.match(r'repos/([^/]+/[^/]+)/contents/(.+)\?ref=(\S+)$', a[-1])
    for (repo, path, ref), content in PR[case]['old'].items():
        if (m.group(1), m.group(2), m.group(3)) == (repo, path, ref):
            print('\n'.join(content)); break
    else:
        for p, content in PR[case]['new'].items():
            if m.group(2) == p:
                print('\n'.join(content)); break
        else:
            print('')
elif a[0] == 'api' and a[1] == 'repos/owner/repo':
    pass  # not a fork: no upstream delta
else:
    sys.stderr.write('unexpected gh call: %s\n' % ' '.join(a)); sys.exit(2)
EOF
chmod +x "$d/bin/gh"
URL=https://github.com/owner/repo/pull/7

run() { set +e; out=$(CASE=$1 CASE_BODY=$2 "$LINT" "$URL" "$d/fm/data/evidence" 2>&1); rc=$?; set -e; }

# 1. The moved file keeps its 20 rewritten lines inside the similarity budget: 900 authored lines pass.
run moved "$d/body-move.txt"
[ "$rc" -eq 0 ] && [[ "$out" == *'checks-lint: PASS:'* ]] || { echo "FAIL moved with rewrites: rc=$rc ($out)"; exit 1; }
echo 'PASS a moved file with rewritten paths is not counted as new code'

# 2. Lines beyond the budget still count: 60 rewritten + 950 authored = 1,010.
run grown "$d/body-move.txt"
[ "$rc" -ne 0 ] && [[ "$out" == *'1010 added non-generated lines'* ]] || { echo "FAIL over-budget rewrite: rc=$rc ($out)"; exit 1; }
echo 'PASS added lines past the similarity budget still count as new code'

# 3. Below the 50% threshold nothing is moved: 400 rewritten + 950 authored = 1,350.
run rewritten "$d/body-move.txt"
[ "$rc" -ne 0 ] && [[ "$out" == *'1350 added non-generated lines'* ]] || { echo "FAIL rewrite below threshold: rc=$rc ($out)"; exit 1; }
echo 'PASS a rewrite below 50% similarity counts in full'

# 4. Same repo: the API rename with previous_filename resolves the previous content too (1,300 -> 940).
run renamed "$d/body.txt"
[ "$rc" -eq 0 ] && [[ "$out" == *'checks-lint: PASS:'* ]] || { echo "FAIL renamed file: rc=$rc ($out)"; exit 1; }
echo 'PASS the pull-files rename with previous_filename counts as moved'
echo 'PASS: moved-with-rewrites counts as moved and genuinely new lines still fail the gate'
