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
# A file git resolves as a rename at 50% similarity or more (the pull-files API's renamed + previous_filename, or
# that body mapping) is counted as moved: its added lines are excused up to the lines it still shares with its
# previous content, and only the added lines past that budget stay new code (a 408-file import keeps its path rewrites).
# A PR over gh's 100-file view cap and over its 300-file diff cap is still measured: every page of the
# pull-files API counts the added lines, and the diff comes from the compare API (else a local checkout).
# An API or diff failure keeps the full count, so it can never turn a big PR into a PASS.
# One gh call per run (plus one per 100 files past the 100-file view cap, the compare/upstream diffs and one or two per moved file). Each run appends a row to $FM_HOME/data/checks-gate.log. A FAIL for a task of this home
# also publishes a FAIL completion receipt (receipts/bin/fm-run-receipt.sh in firstmate-addons), so bin/fm-pr-merge.sh and fm-merge-local.sh
# refuse the merge (bin/fm-dod-lib.sh fm_dod_receipt_accept) until the worker re-lints to PASS and republishes PASS.
import os, re, sys, json, time, hashlib, subprocess, tempfile
from collections import Counter

if len(sys.argv) < 3 or not os.environ.get('FM_HOME'):
    sys.exit('usage: FM_HOME=<home> fm-checks-lint.sh <PR URL | report file> <evidence folder>')
src, ev = sys.argv[1], sys.argv[2]
home = os.environ['FM_HOME']; LOG = f'{home}/data/checks-gate.log'; HASHES = f'{home}/data/checks-gate.hashes'
GEN = re.compile(r'(^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|go\.sum|[^/]*\.lock)$'+ r'|(^|/)packages/accounts/src/pi/|(^|/)packages/accounts/src/routes\.json$|(^|/)vendor/|(^|/)dist/|(^|/)(LICENSE|LICENSES|NOTICE|COPYING)[^/]*$')  # third-party, legal text and committed build output (dist/) are not reviewable code

task, ROOT = '', os.path.dirname(os.path.dirname(os.path.realpath(__file__)))  # task is set below

def gh_api(*a):  # errors=replace: the move rule also fetches binary files, which must not crash the count
    return subprocess.run(['gh', 'api', *a], capture_output=True, text=True, errors='replace', timeout=60)

def all_files(nwo):
    """Every changed file of a PR whose gh-pr-view list (100 max) is full: paginated pull-files API, else None."""
    out, page = [], 1
    while True:
        r = gh_api(f'repos/{nwo[1]}/pulls/{nwo[2]}/files?per_page=100&page={page}')
        try:
            batch = json.loads(r.stdout) if r.returncode == 0 else None
        except ValueError:
            batch = None
        if not isinstance(batch, list):
            return None
        out += [{'path': f.get('path') or f.get('filename', ''), 'additions': f.get('additions', 0),
                 'status': f.get('status', ''), 'previous_filename': f.get('previous_filename')} for f in batch]
        if len(batch) < 100 or len(out) >= 3000:  # short page, or GitHub's own 3000-file cap
            return out
        page += 1

def diff_entries(diff):
    """Added and deleted non-generated lines per path of a unified diff; '' holds lines before any file header."""
    ents = {'': {'add': Counter(), 'rm': Counter(), 'whole': False}}
    cur, gen = ents[''], False
    for l in diff.splitlines():
        if l.startswith('+++ '):
            path = l[6:] if l.startswith('+++ b/') else l[4:]
            gen = bool(GEN.search(path))
            cur = ents.setdefault(path, {'add': Counter(), 'rm': Counter(), 'whole': False})
        elif gen or l.startswith('--- '):
            continue
        elif l.startswith('@@'):
            cur['whole'] = cur['whole'] or l.startswith('@@ -0,0 ')  # whole file added: the new content is right here
        elif len(l) > 1 and l[0] in '+-' and l[1:].strip():
            cur['add' if l[0] == '+' else 'rm'][l[1:].strip()] += 1
    return ents

def net(ents):  # added minus deleted non-generated lines of a parsed diff
    add, rm = Counter(), Counter()
    for e in ents.values():
        add += e['add']; rm += e['rm']
    return add - rm

def contents(repo, path, ref):
    """One file's text, or '' when the API cannot serve it (a binary sibling must not crash the count)."""
    r = gh_api('-H', 'Accept: application/vnd.github.raw', f'repos/{repo}/contents/{path}?ref={ref}')
    return r.stdout if r.returncode == 0 else ''

def moved_pairs(nwo, files, body, base, head):
    """Files git resolves as renames: path -> (repo, previous path, previous ref, new ref). Same owner only."""
    if not nwo:
        return {}
    mv = re.search(r'^\s*moved-from\s*:\s*([\w.-]+)/([\w.-]+)@(\S+)\s+(.+)$', body, re.M)
    rules = [r.split('=', 1) for r in mv[4].split() if '=' in r] if mv and mv[1] == nwo[1].split('/')[0] else []
    named = files if any('status' in f for f in files) else (all_files(nwo) or [])  # gh pr view carries no rename
    pairs = {}
    for f in named:
        p = f.get('path') or ''
        if not p or GEN.search(p):
            continue
        if f.get('status') == 'renamed' and f.get('previous_filename'):  # same repo: git already says it is a move
            pairs[p] = (nwo[1], f['previous_filename'], base, head)
        else:
            for dst, sp in rules:  # cross-repo move: the body names the source file
                if p.startswith(dst):
                    pairs[p] = (f'{mv[1]}/{mv[2]}', sp + p[len(dst):], mv[3], head)
                    break
    return pairs

def cancel_moved(n, ents, pairs):
    """A moved file's added lines are moved, not new code: cancel up to the lines it still shares with its
    previous content (the similarity budget) and keep counting whatever the rewrite added past that budget."""
    for path, (repo, prev, ref, newref) in pairs.items():
        e = ents.get(path) or {}
        if not e.get('add'):
            continue
        old = Counter(l.strip() for l in contents(repo, prev, ref).splitlines() if l.strip())
        new = e['add'] if e['whole'] else Counter(l.strip() for l in contents(repo, path, newref).splitlines() if l.strip())
        matched = sum((old & new).values())
        if not matched or 100 * matched // max(sum(old.values()), sum(new.values())) < 50:
            continue  # no previous content, or below the 50% rename threshold: this is a rewrite, not a move
        budget = matched
        for line, c in e['add'].items():
            take = min(n.get(line, 0), c, budget)
            n[line] -= take; budget -= take
    return n

def pr_diff(nwo, base, head, dirs):
    """Whole-PR diff: compare API (gh pr diff refuses above 300 files), else a checkout holding both commits."""
    if nwo and base and head not in ('', '-'):
        r = gh_api('-H', 'Accept: application/vnd.github.diff', f'repos/{nwo[1]}/compare/{base}...{head}')
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout
        for d in dirs:
            g = subprocess.run(['git', '-C', d, 'diff', '--no-color', f'{base}...{head}'], capture_output=True, text=True, timeout=120)
            if g.returncode == 0 and g.stdout.strip():
                return g.stdout
    return ''

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
    nwo = re.match(r'https://github\.com/([^/]+/[^/]+)/pull/(\d+)', src)
    if nwo and len(files) >= 100:  # view list is capped at 100, so a bigger PR needs every page (Juggernaut PR 133: 408 files)
        files = all_files(nwo) or files
    # Added lines only: deletions are cheap to review and 'delete before you add' must not be penalised.
    size = sum(f.get('additions', 0) for f in files if not GEN.search(f.get('path', '')))
    if size >= 1000:  # moved lines are not new code (7 Oct, PR 18 helper move): an added line that matches a deleted one cancels
        meta = f'{home}/state/{task}.meta'
        wt = ([l[9:].strip() for l in open(meta) if l.startswith('worktree=')] or [''])[-1] if task and os.path.isfile(meta) else ''
        diff = pr_diff(nwo, pr.get('baseRefOid'), head, [d for d in (wt, os.getcwd()) if os.path.isdir(d)])
        if diff:  # no diff from any source keeps the full count: a failure never lowers it
            ents = diff_entries(diff)
            n = net(ents); size = sum(n.values())
            # Upstream catch-up (15 Oct, fork PR 74): lines the fork's parent repo already shipped are not authored
            # here, so subtract the upstream delta the PR merges in (PR base ... merged upstream tip). A plain fork PR
            # merges no new upstream commit, so its delta is empty. Any API failure keeps the full count.
            p = gh_api(f'repos/{nwo[1]}', '--jq', '.parent | select(.) | .owner.login + ":" + .default_branch') if size >= 1000 and nwo else None
            u = gh_api(f'repos/{nwo[1]}/compare/{p.stdout.strip()}...{head}', '--jq', '.merge_base_commit.sha') if p and p.returncode == 0 and p.stdout.strip() else None
            dl = gh_api('-H', 'Accept: application/vnd.github.diff', f'repos/{nwo[1]}/compare/{pr.get("baseRefOid")}...{u.stdout.strip()}') if u and u.returncode == 0 and u.stdout.strip() else None
            if dl and dl.returncode == 0: n -= net(diff_entries(dl.stdout)); size = sum(n.values())
            # Moved files (cross-repo move 16 Oct, add-ons PR 9; rename with rewrites): cancel only the added lines
            # of the moved file itself, up to its similarity budget, so a path rewrite rides along with its file
            # and every authored line still counts.
            pairs = moved_pairs(nwo, files, body, pr.get('baseRefOid'), head) if size >= 1000 else {}
            if pairs: size = sum(cancel_moved(n, ents, pairs).values())
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
