#!/usr/bin/env bash
# E2E: the 1,000-line gate measures a PR past gh's 100-file view cap and its 300-file diff cap.
# gh pr view still lists only 100 files and gh pr diff still refuses >300 files here; the gate must read
# every pull-files page and learn the diff from the compare API, never from a refusal (no network).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
LINT=$ROOT/merge-on-green/fm-checks-lint.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/bin" "$d/home" "$d/xdg" "$d/fm/state" "$d/fm/data/evidence"
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d PATH="$d/bin:$PATH" FM_HOME=$d/fm BIGPR_LOG=$d/gh.log
printf '## Checks\noutcome: big import fixture\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: not proven: fixture\n' > "$d/body.txt"
printf '%s\n' '## Checks' 'outcome: big import fixture' 'repro: n/a: no bug' 'proof: no verify skill - bash fixture' 'evidence: not proven: fixture' '' 'moved-from: owner/src@ref1 addons/=' > "$d/body-move.txt"

cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env python3
# Stub gh for a 305-file PR: the view list is capped at 100, the compare diff carries 1,500 added lines
# of which 1,300 byte-match the mapped source repo. Anything else is an unexpected call.
import json, os, sys
a = sys.argv[1:]
case = os.environ['BIGPR_CASE']
open(os.environ['BIGPR_LOG'], 'a').write(' '.join(a) + '\n')
files = [{'path': 'other/f%d.txt' % i, 'additions': 7} for i in range(300)] + \
        [{'path': 'addons/a%d.txt' % i, 'additions': 7} for i in range(5)]
def body():
    return open(os.environ['BIGPR_BODY']).read()
if a[:2] == ['pr', 'view']:
    print(json.dumps({'author': {'login': 'umer'}, 'body': body(), 'title': 'feat: import',
                      'files': files[:100], 'headRefOid': 'head1', 'headRefName': 'fm/import',
                      'baseRefOid': 'base1'}))
elif a[:2] == ['pr', 'diff']:
    sys.exit(1)  # HTTP 406 above 300 files
elif a[0] == 'api' and '/files?' in a[1]:
    page = int(a[1].rsplit('page=', 1)[1])
    # The pull-files API names the path `filename`; gh pr view names it `path`.
    print(json.dumps([{'filename': f['path'], 'additions': f['additions']} for f in files[(page - 1) * 100:page * 100]]))
elif a[0] == 'api' and 'Accept: application/vnd.github.diff' in a:
    if case == 'files':
        sys.exit(1)  # compare unavailable: the full file-list count must stand
    def section(path, new, old=None):
        out = ['diff --git a/%s b/%s' % (path, path)]
        if old is None:
            out += ['new file mode 100644', '--- /dev/null', '+++ b/%s' % path, '@@ -0,0 +1,%d @@' % len(new)]
            return out + ['+' + l for l in new]
        out += ['--- a/%s' % path, '+++ b/%s' % path, '@@ -1,%d +1,%d @@' % (len(old), len(new))]
        return out + ['-' + l for l in old] + ['+' + l for l in new]
    print('\n'.join(section('addons/a0.txt', ['imported-%d' % i for i in range(1300)]) +
                    section('addons/a1.txt', ['binary-neighbour']) +
                    section('authored/new.txt', ['authored-%d' % i for i in range(199)])))
elif a[0] == 'api' and 'Accept: application/vnd.github.raw' in a:
    # Whole contents of the one mapped source file; a binary sibling must not crash the count.
    if 'a0.txt' in a[-1]:
        print('\n'.join('imported-%d' % i for i in range(1300)))
    elif 'a1.txt' in a[-1]:
        sys.stdout.buffer.write(b'\x89PNG\r\n\x1a\n')
    else:
        print('')
elif a[0] == 'api' and a[1] == 'repos/owner/repo':
    pass  # not a fork: no parent repo
else:
    sys.stderr.write('unexpected gh call: %s\n' % ' '.join(a))
    sys.exit(2)
EOF
chmod +x "$d/bin/gh"
export BIGPR_BODY=$d/body.txt
URL=https://github.com/owner/repo/pull/9

run() { set +e; out=$(BIGPR_CASE=$1 "$LINT" "$URL" "$d/fm/data/evidence" 2>&1); rc=$?; set -e; }

# 1. Compare and git both unavailable: every file page still counts (305 x 7 = 2,135; the truncated first
#    page alone would be 700 and would wrongly pass).
run files
[ "$rc" -ne 0 ] && [[ "$out" == *'2135 added non-generated lines'* ]] || { echo "FAIL file list past 100: rc=$rc ($out)"; exit 1; }
for page in 2 3 4; do grep -Fq "/files?per_page=100&page=$page" "$BIGPR_LOG" || { echo "FAIL page $page was never read"; exit 1; }; done
grep -Fq 'pr diff' "$BIGPR_LOG" && { echo 'FAIL the 406-capped pr diff was still used'; exit 1; }
echo 'PASS full file list past 100 keeps the count when no diff is reachable'

# 2. Compare diff reachable: the size comes from it (1,500), not from the file list, and is refused.
: > "$BIGPR_LOG"
run diff
[ "$rc" -ne 0 ] && [[ "$out" == *'1500 added non-generated lines'* ]] || { echo "FAIL compare diff size: rc=$rc ($out)"; exit 1; }
grep -Fq 'compare/base1...head1' "$BIGPR_LOG" || { echo 'FAIL compare API was not asked for the diff'; exit 1; }
echo 'PASS >300-file PR with 1,500 authored lines is refused'

# 3. Same PR with the supported move exclusion: the 1,300 imported lines are the same file moved, the 200
#    authored lines (199 in the diff plus the binary neighbour with no previous content) remain.
export BIGPR_BODY=$d/body-move.txt
run move
[ "$rc" -eq 0 ] && [[ "$out" == *'checks-lint: PASS:'* ]] || { echo "FAIL moved-from exclusion: rc=$rc ($out)"; exit 1; }
echo 'PASS moved-from byte match clears the import and keeps the 1,000-line rule'
echo 'PASS: size gate measures a PR above the 100-file and 300-file API caps'
