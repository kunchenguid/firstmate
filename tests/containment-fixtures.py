#!/usr/bin/env python3
"""Create real Git histories for the teardown containment regression matrix.

Arguments: isolated case directory produced by make_case, then scenario name.
Only fixture-local repositories are modified; no network forge is used.
"""

from pathlib import Path
import subprocess,sys,json
c=Path(sys.argv[1]); scenario=sys.argv[2]; project=c/'project'; wt=c/'wt'
def git(repo,*args):return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
def change(repo,files,msg):
 for path,content in files.items():(repo/path).write_text(content)
 git(repo,'--literal-pathspecs','add','--all');git(repo,'commit','-qm',msg)
 return git(repo,'rev-parse','HEAD')
def lines(first='zero',last='zero'):return '\n'.join([first]+[f'context-{n}' for n in range(2,100)]+[last])+'\n'
initial_shared=''.join(f'line-{n}\n' for n in range(1,5001)) if scenario.startswith('large-') else lines()
base=change(project,{'f.txt':'keep\nremove\ntail\n','shared.txt':initial_shared,'feature.txt':'zero\n','g.txt':'zero\n','h.txt':'zero\n'},'baseline')
git(project,'push','-q','origin','main');git(wt,'merge','--ff-only','-q',base)
missing=None
if scenario in ('unlanded-delete','landed-delete','unlanded-replace'):
 local=change(wt,{'f.txt':'keep\ntail\n' if scenario!='unlanded-replace' else 'keep\nnew\ntail\n'},'local edit')
 if scenario=='landed-delete':change(project,{'f.txt':'keep\ntail\n'},'landed deletion')
elif scenario=='same-file-restoration':
 change(wt,{'shared.txt':lines('one','one')},'local two hunks')
 change(project,{'shared.txt':lines('one','one')},'landed two hunks')
 local=change(wt,{'shared.txt':lines('one','zero')},'unlanded restoration')
elif scenario in ('literal-path','ordinary-path'):
 change(wt,{'feature.txt':'one\n'},'local feature');change(project,{'feature.txt':'one\n'},'landed feature')
 name=':(literal)feature.txt' if scenario=='literal-path' else 'local-feature.txt'
 local=change(wt,{name:'private local content\n'},'unlanded added file')
elif scenario in ('successive-upstream','one-upstream'):
 change(wt,{'shared.txt':lines('one')},'first local edit')
 final='one'
 if scenario=='successive-upstream':change(wt,{'shared.txt':lines('two')},'superseding local edit');final='two'
 local=git(wt,'rev-parse','HEAD')
 change(project,{'shared.txt':lines(final,'upstream')},'rewritten merged task plus unrelated hunk')
elif scenario in ('large-rebased-upstream','large-rebased-unlanded'):
 local_lines=initial_shared.splitlines(keepends=True);local_lines[0]='local edit\n'
 local=change(wt,{'shared.txt':''.join(local_lines)},'local line 1')
 upstream_lines=initial_shared.splitlines(keepends=True);upstream_lines[-1]='upstream edit\n'
 change(project,{'shared.txt':''.join(upstream_lines)},'upstream line 5000')
 pipeline=c/'pipeline'
 git(project,'worktree','add','--detach',str(pipeline),local)
 git(pipeline,'rebase','main')
 git(project,'merge','--squash',git(pipeline,'rev-parse','HEAD'))
 git(project,'commit','-qm','squash rebased local edit')
 if scenario=='large-rebased-unlanded':
  local_lines[2499]='unmerged later edit\n'
  local=change(wt,{'shared.txt':''.join(local_lines)},'unmerged line 2500')
elif scenario=='large-alignment-bound':
 local_lines=[f'rewrite-{n}\n' for n in range(1,4501)]+initial_shared.splitlines(keepends=True)[4500:]
 local=change(wt,{'shared.txt':''.join(local_lines)},'large local rewrite')
 merged_lines=list(local_lines);merged_lines[-1]='upstream edit\n'
 change(project,{'shared.txt':''.join(merged_lines)},'landed rewrite with unrelated upstream hunk')
elif scenario=='partial-two-file':
 local=change(wt,{'g.txt':'one\n','h.txt':'one\n'},'two local edits')
 change(project,{'g.txt':'one\n'},'only one edit landed')
elif scenario=='whole-file-restoration':
 change(wt,{'g.txt':'one\n'},'local change');change(project,{'g.txt':'one\n'},'landed change')
 local=change(wt,{'g.txt':'zero\n'},'unlanded restoration')
elif scenario in ('missing-intermediate-tree','complete-enumeration'):
 change(wt,{'feature.txt':'one\n'},'landed local feature')
 intermediate=change(wt,{'g.txt':'one\n'},'unlanded g')
 tree=git(wt,'rev-parse',intermediate+'^{tree}')
 local=change(wt,{'h.txt':'one\n'},'unlanded h')
 change(project,{'feature.txt':'one\n'},'landed feature')
 object_dir=Path(git(project,'rev-parse','--absolute-git-dir'))/'objects'
 if scenario=='missing-intermediate-tree':missing=object_dir/tree[:2]/tree[2:]
else:raise SystemExit('unknown scenario')
git(project,'push','-q','origin','main')
merged=git(project,'rev-parse','HEAD')
# Persist every object except one deliberate, reversible fixture-only omission.
if missing:
 saved=c/'preserved-intermediate-tree';missing.rename(saved)
(c/'input.json').write_text(json.dumps({'scenario':scenario,'base':base,'local_head':local,'merged_head':merged,'missing_tree_object':str(missing) if missing else None},indent=2)+'\n')
(c/'merged-sha').write_text(merged+'\n')
