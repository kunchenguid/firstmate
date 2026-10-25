#!/usr/bin/env python3
# Merge gate for worker claims (flow playbook R4, captain 5 Oct: artifacts, not claims).
# Usage: FM_HOME=<home> fm-checks-lint.sh <PR URL | local report file> <evidence folder>
#        then, after reading PASS, merge in a later separate call (bin/fm-pr-merge.sh).
# Needs under "## Checks": outcome:, repro:, proof:, evidence:. proof names a command or path; repro is
# not n/a on a fix PR; evidence files exist, are non-empty, are newer than the lane's first launch
# (data/<task>/ birth), and at least one has a hash no other PR used, and no two are identical. "evidence: not proven: <cause>"
# passes (file the proof gap as a task). proof names the repo's verify-<app> skill (or "no verify skill" when
# the repo has none); a real repro names systematic-debugging (captain 6 Oct). Bot PRs pass. 1,000+ added non-generated lines fail (deletions, moved lines and a fork PR's merged-in upstream lines do not count;
# a cross-repo move names its source in the PR body: "moved-from: <owner>/<repo>@<ref> <dst-prefix>=<src-prefix>", same owner only).
# One gh call per run (up to five when the size check needs the diffs to exclude moved and upstream lines, plus one per cross-repo moved file). Each run appends a row to $FM_HOME/data/checks-gate.log. A FAIL for a task of this home
# also publishes a FAIL completion receipt (receipts/bin/fm-run-receipt.sh in firstmate-addons), so bin/fm-pr-merge.sh and fm-merge-local.sh
# refuse the merge (bin/fm-dod-lib.sh fm_dod_receipt_accept) until the worker re-lints to PASS and republishes PASS.
import os, re, sys, json, time, hashlib, subprocess, tempfile

if len(sys.argv) < 3 or not os.environ.get('FM_HOME'):
    sys.exit('usage: FM_HOME=<home> fm-checks-lint.sh <PR URL | report file> <evidence folder>')
src, ev = sys.argv[1], sys.argv[2]
home = os.environ['FM_HOME']; LOG = f'{home}/data/checks-gate.log'; HASHES = f'{home}/data/checks-gate.hashes'
GEN = re.compile(r'(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|go\.sum|[^/]*\.lock)$'+ r'|(^|/)packages/accounts/src/pi/|(^|/)packages/accounts/src/routes\.json$|(^|/)vendor/|(^|/)dist/|(^|/)(LICENSE|LICENSES|NOTICE|COPYING)[^/]*$')  # third-party, legal text and committed build output (dist/) are not reviewable code

task, ROOT = '', os.path.dirname(os.path.dirname(os.path.realpath(__file__)))  # task is set below

def lane_task(home, src, ev, fallback=''):
    """Lane id from state/<task>.meta (pr=) or $FM_HOME/data/<task>, not the PR branch name."""
    if isinstance(src, str) and src.startswith('http') and os.path.isdir(f'{home}/state'):
        for name in sorted(os.listdir(f'{home}/state')):
            if not name.endswith('.meta'):
                continue
            try:
                for line in open(f'{home}/state/{name}', errors='replace'):
                    if line.startswith('pr=') and line[3:].strip() == src:
                        return name[:-5]
            except OSError:
                continue
    try:
        ev_abs, data = os.path.abspath(ev), os.path.abspath(f'{home}/data')
    except OSError:
        return fallback
    if ev_abs.startswith(data + os.sep):
        rel = ev_abs[len(data) + 1:]
        if rel and os.sep not in rel:
            return rel
    return fallback

def done(ok, why, head='-'):
    with open(LOG, 'a') as f:
        f.write(f'{time.strftime("%FT%TZ", time.gmtime())}\t{src}\t{head}\t{"pass" if ok else "fail"}\t{why}\n')
    print(f'checks-lint: {"PASS" if ok else "FAIL"}: {why}')
    meta = f'{home}/state/{task}.meta'
    if not ok and task and os.path.isfile(meta):  # revoke the merge key (header)
        wt = ([l[9:].strip() for l in open(meta) if l.startswith('worktree=')] or [''])[-1]
        with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as t:
            t.write(f'checks-lint FAIL {src} head {head}: {why}\n')
        try:
            r = subprocess.run([f"{os.environ.get('FM_ADDONS_DIR') or ROOT}/receipts/bin/fm-run-receipt.sh", task, 'FAIL', t.name, wt if os.path.isdir(wt) else home],
                               env={**os.environ, 'FM_HOME': home}, capture_output=True, text=True, timeout=60)
            print('checks-lint: receipt FAIL published: merge refused until a new PASS receipt' if r.returncode == 0
                  else 'checks-lint: receipt not revoked: ' + (r.stderr.strip() or '?')[-160:])
        except subprocess.TimeoutExpired:
            print('checks-lint: receipt not revoked: fm-run-receipt.sh timed out')
        finally:
            os.unlink(t.name)
    sys.exit(0 if ok else 1)

if os.path.isfile(src):  # local-only lane: the report file its done line names
    body, title, head, task, author, files = open(src, errors='replace').read(), '', '-', os.path.basename(os.path.dirname(os.path.abspath(src))), '', []
    task = lane_task(home, src, ev, task)
else:
    r = subprocess.run(['gh', 'pr', 'view', src, '--json', 'author,body,title,files,headRefOid,headRefName,baseRefOid'],
                       capture_output=True, text=True, timeout=60)
    if r.returncode: done(False, 'gh pr view failed: ' + (r.stderr.strip().splitlines() or ['?'])[-1][:160])
    pr = json.loads(r.stdout)
    body, title, head = pr.get('body') or '', pr.get('title') or '', pr.get('headRefOid', '-')
    author, files = (pr.get('author') or {}).get('login', ''), pr.get('files') or []
    task = lane_task(home, src, ev, pr.get('headRefName', '').rsplit('/', 1)[-1])
    if re.match(r'(dependabot|renovate)(\[bot\])?$', author) or author in ('app/dependabot', 'app/renovate'):
        done(True, 'bot', head)
    # Added lines only: deletions are cheap to review and 'delete before you add' must not be penalised.
    size = sum(f.get('additions', 0) for f in files if not GEN.search(f.get('path', '')))
    if size >= 1000:  # moved lines are not new code (7 Oct, PR 18 helper move): an added line that matches a deleted one cancels
        d = subprocess.run(['gh', 'pr', 'diff', src], capture_output=True, text=True, timeout=60)
        if d.returncode == 0:
            from collections import Counter
            def net(diff):  # added minus deleted non-generated lines of a unified diff
                add, rm, gen = Counter(), Counter(), False
                for l in diff.splitlines():
                    if l.startswith('+++ '): gen = bool(GEN.search(l[6:] if l.startswith('+++ b/') else l[4:])); continue
                    if l.startswith('--- ') or gen or not l[1:].strip(): continue
                    if l[0] == '+': add[l[1:].strip()] += 1
                    elif l[0] == '-': rm[l[1:].strip()] += 1
                return add - rm
            n = net(d.stdout); size = sum(n.values())
            # Upstream catch-up (15 Oct, fork PR 74): lines the fork's parent repo already shipped are not authored
            # here, so subtract the upstream delta the PR merges in (PR base ... merged upstream tip). A plain fork PR
            # merges no new upstream commit, so its delta is empty. Any API failure keeps the full count.
            gh = lambda *a: subprocess.run(['gh', 'api', *a], capture_output=True, text=True, timeout=60)
            nwo = re.match(r'https://github\.com/([^/]+/[^/]+)/pull/', src)
            p = gh(f'repos/{nwo[1]}', '--jq', '.parent | select(.) | .owner.login + ":" + .default_branch') if size >= 1000 and nwo else None
            u = gh(f'repos/{nwo[1]}/compare/{p.stdout.strip()}...{head}', '--jq', '.merge_base_commit.sha') if p and p.returncode == 0 and p.stdout.strip() else None
            dl = gh('-H', 'Accept: application/vnd.github.diff', f'repos/{nwo[1]}/compare/{pr.get("baseRefOid")}...{u.stdout.strip()}') if u and u.returncode == 0 and u.stdout.strip() else None
            if dl and dl.returncode == 0: n -= net(dl.stdout); size = sum(n.values())
            # Cross-repo move (16 Oct, add-ons PR 9): a body line "moved-from: <owner>/<repo>@<ref> <dst-prefix>=<src-prefix>..."
            # cancels added lines that byte-match the mapped source files in a repo of the PR's own owner; authored lines still count.
            mv = re.search(r'^\s*moved-from\s*:\s*([\w.-]+)/([\w.-]+)@(\S+)\s+(.+)$', body, re.M) if size >= 1000 and nwo else None
            rules = [r.split('=', 1) for r in mv[4].split() if '=' in r] if mv and mv[1] == nwo[1].split('/')[0] else []
            for f in files if rules else []:
                for dst, sp in rules:
                    if f.get('path', '').startswith(dst) and not GEN.search(f['path']):
                        c = gh('-H', 'Accept: application/vnd.github.raw', f'repos/{mv[1]}/{mv[2]}/contents/{sp}{f["path"][len(dst):]}?ref={mv[3]}')
                        if c.returncode == 0: n -= Counter(l.strip() for l in c.stdout.splitlines() if l.strip())
                        break
            if rules: size = sum(n.values())
    if size >= 1000: done(False, f'{size} added non-generated lines (moved and upstream lines excluded): split it (limit 1000)', head)

m = ([None] + list(re.finditer(r'^##\s*Checks\s*$(.*?)(?=^##\s|\Z)', body, re.M | re.S)))[-1]  # newest block: workers append, never replace
if not m: done(False, 'no "## Checks" block', head)
block = re.sub(r'```\w*', '', m.group(1))
F = {k: v.strip() for k, v in re.findall(r'^\s*(outcome|repro|proof|evidence)\s*:\s*(.*)$', block, re.M)}
miss = [k for k in ('outcome', 'repro', 'proof', 'evidence') if not F.get(k)]
if miss: done(False, 'missing or empty Checks line: ' + ', '.join(miss), head)
if not re.search(r'[/`]|\.\w{2,4}\b|\b(npm|pnpm|yarn|npx|bash|sh|python3?|node|cargo|go|gradle|make|adb|xcrun|bin/)\b', F['proof']):
    done(False, 'proof: names no command or path', head)
repo = re.search(r'github\.com/[^/]+/([^/]+)/pull/', src)
vdir = f'{home}/projects/{repo.group(1)}/.agents/skills' if repo else ''
has_verify = bool(vdir) and os.path.isdir(vdir) and any(d.startswith('verify-') for d in os.listdir(vdir))
if 'verify-' not in F['proof'] and (has_verify or not re.search(r'no verify skill', F['proof'], re.I)):
    done(False, 'proof: does not name the verify-<app> skill run' + ('' if has_verify else ' (or "no verify skill")'), head)
if not re.match(r'n/?a\b', F['repro'], re.I) and 'systematic-debugging' not in F['repro']:
    done(False, 'repro: a real repro must say "systematic-debugging used" (brief step 2)', head)
if re.match(r'(fix|bugfix|hotfix)\b', title, re.I) and re.match(r'n/?a\b', F['repro'], re.I):
    done(False, 'repro: is n/a on a fix PR', head)
if re.match(r'not proven\s*:\s*\S', F['evidence'], re.I):
    done(True, 'not-proven: ' + F['evidence'][:120], head)

names = [n.strip(' `"\'') for n in re.split(r'[,\s]+', F['evidence']) if re.search(r'\.\w{1,10}$', n.strip(' `"\''))]  # .stdout etc. (8 Oct, ownvoice PR 175)
if not names: done(False, 'evidence: names no files (or write "not proven: <cause>")', head)
born = 0
if os.path.isdir(f'{home}/data/{task}'):
    out = subprocess.run(['stat', '-c', '%W', f'{home}/data/{task}'], capture_output=True, text=True).stdout.strip()
    born = int(out) if out.isdigit() else 0
seen = {}
if os.path.exists(HASHES):
    for l in open(HASHES):
        p = l.split()
        if len(p) == 2: seen[p[0]] = p[1]
fresh, mine = False, []
for n in names:
    p = n if os.path.isabs(n) else os.path.join(ev, n)
    if not os.path.isfile(p) or os.path.getsize(p) == 0: done(False, f'evidence file missing or empty: {p}', head)
    if born and os.path.getmtime(p) < born: done(False, f'evidence file older than the lane launch: {p}', head)
    hsh = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    mine.append(hsh)
    o = seen.get(hsh)  # same task's earlier lint (local body or PR) is not reuse
    if o is None or o in (src, task) or (task and f'/{task}/' in o): fresh = True
if not fresh: done(False, 'every evidence file was already used by another PR', head)
if len(set(mine)) < len(mine): done(False, 'two evidence files are byte-identical: capture each claimed state separately, or write "not proven: <cause>"', head)
with open(HASHES, 'a') as f:
    for hsh in mine:
        if hsh not in seen: f.write(f'{hsh} {task or src}\n')
done(True, f'{len(names)} evidence files', head)
