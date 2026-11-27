#!/usr/bin/env python3
"""Non-interactive real-status pass for the Miko cockpit (cockpit-2.html; cockpit.html was the first session until 17-11).
Read-only on GitHub (one GraphQL query) and on git (fetch origin main). Reads lane status files.
Updates the rich kanban cards (labels, border colours, PR notes, simple column moves),
colours their WBS boxes the same, regenerates the kanban from the WBS, re-embeds card-data.json,
stamps 'stand HH:MM', and installs atomically (cp to .tmp, then mv), which makes the open Lavish
page reload the new revision. No secrets are read or printed.

Paths come from the environment (see tools/cockpit/README.md):
  FM_HOME            firstmate home whose state/*.status lane files are read (default ~/.firstmate)
  COCKPIT_DATA_DIR   directory holding cockpit-2.html, card-data.json and .refresh.lock
                     (default $FM_HOME/data/miko-all-in-one-lavish)
  MIKO_WORKTREE      git worktree of the Miko repo with an origin remote; required, no default
  COCKPIT_OUT        optional: write the page here instead of replacing cockpit-2.html in place
  COCKPIT_GOAL_HOME  optional: read the goals from this Firstmate home instead of FM_HOME
  COCKPIT_SCOPE      optional: override this wrapper's miko-systems/miko scope

Every run starts with cockpit-sync.py (goal home COCKPIT_GOAL_HOME, else FM_HOME; its --help owns the
other COCKPIT_* scope variables). The truth JSON lands in $COCKPIT_TRUTH or the shared scoped default
(COCKPIT_OUT.truth.json for a preview). A failed run puts a banner on the installed page and
exits non-zero."""
import os,re,sys,json,html,subprocess,time,fcntl,tempfile,collections
# Isolated mode omits the script directory, including the shared goal-view renderer.
sys.path.append(os.path.dirname(os.path.realpath(__file__)))
from goal_drive import base_page, render_captain_steps, render_truth, truth_path

FM=os.environ.get('FM_HOME') or os.path.expanduser('~/.firstmate')
D=os.environ.get('COCKPIT_DATA_DIR') or os.path.join(FM,'data','miko-all-in-one-lavish')
PAGE=os.path.join(D,'cockpit-2.html'); CARD=os.path.join(D,'card-data.json')
W=os.environ.get('MIKO_WORKTREE')
if not W: sys.exit('refresh-cockpit: set MIKO_WORKTREE to a git worktree of the Miko repo (see tools/cockpit/README.md)')
BIN=os.path.dirname(os.path.abspath(__file__)); TMP=tempfile.mkdtemp(prefix='cockpit-refresh-')
TE,BL,YE,GN,OR,RE='#2dd4bf','#60a5fa','#ffcc66','#7fe0a5','#ffa94d','#ff4d4d'
LAB={'niet':('· nog niet aan de beurt','#9aa4b2'),'later':('· later','#6f6880'),'auto':('⟳ gaat vanzelf door',TE),'fm':('⏸ wacht op firstmate',BL),'werk':('⚙ werker bezig',YE),'vast':('⚠ vast',OR),'klaar':('✓ klaar',GN)}
def run(cmd,**k): return subprocess.run(cmd,check=True,capture_output=True,text=True,**k).stdout
def sync(args):
    return subprocess.run([sys.executable,'-I',os.path.join(BIN,'cockpit-sync.py'),*args]).returncode
def main():
    lock=open(os.path.join(D,'.refresh.lock'),'w'); fcntl.flock(lock,fcntl.LOCK_EX)
    truth_path=verify()
    try: refresh(truth_path)
    except BaseException as e:
        if not os.environ.get('COCKPIT_OUT') and os.path.exists(PAGE): sync(['--banner-only','%s: %s'%(type(e).__name__,e),'--page',PAGE])
        raise
def verify():
    # reality first: nothing is rendered from marks that were not checked
    preview=os.environ.get('COCKPIT_OUT')
    home=os.environ.get('COCKPIT_GOAL_HOME') or FM
    scope=[s.strip() for s in os.environ.get('COCKPIT_SCOPE','').split(',') if s.strip()] or ['miko-systems/miko']
    target=os.environ.get('COCKPIT_TRUTH') or (preview+'.truth.json' if preview else str(truth_path(home,scope)))
    sys.stdout.flush()
    selectors=[part for name in scope for part in ('--scope',name)]
    if sync(['--goal-home',home,'--out',target]+selectors+([] if preview else ['--page',PAGE])):
        sys.exit('refresh-cockpit: the cockpit sync failed; the page was not refreshed')
    return target
def refresh(truth_path):
    preview=os.environ.get('COCKPIT_OUT')
    truth=json.load(open(truth_path))
    now=time.strftime('%H:%M',time.localtime())
    os.environ['TZ']='Europe/Amsterdam'; time.tzset(); now=time.strftime('%H:%M')
    run(['git','-C',W,'fetch','-q','origin','main'])
    for f in ['prod-gate.json','portal-states.json']:
        open(os.path.join(TMP,f),'w').write(run(['git','-C',W,'show','origin/main:apps/portal/registers/'+f]))
    q='query{repository(owner:"miko-systems",name:"miko"){open:pullRequests(states:OPEN,first:60){nodes{number mergeable isInMergeQueue mergeQueueEntry{position} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}} merged:pullRequests(states:MERGED,first:60,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number mergedAt}}}}'
    r=json.loads(run(['gh','api','graphql','-f','query='+q],cwd=W))['data']['repository']
    OPEN={n['number']:n for n in r['open']['nodes']}; MERGED={n['number'] for n in r['merged']['nodes']}
    MERGEDAT={n['number']:n.get('mergedAt') for n in r['merged']['nodes']}
    lanes={}
    for fn in os.listdir(os.path.join(FM,'state')):
        if fn.endswith('.status'):
            try: ls_=open(os.path.join(FM,'state',fn)).read().strip().splitlines()
            except Exception: continue
            st=''
            for line in reversed(ls_):
                w0=line.split()[0] if line.split() else ''
                if w0 in ('working','milestone','ready','done','paused','captain-held','needs-decision','blocked','stopped'):
                    st=w0
                    # paused while its own check run or CI is going is busy work; paused waiting on firstmate is not
                    if w0=='paused' and re.search(r'no-mistakes|waiting for CI|ci auto-fix|validating|re-running|resumes? (?:on|at|when)|running ',line) and not re.search(r'waiting for firstmate',line): st='paused-run'
                    break
            # a lane whose status file has not moved for 24 hours is not running, whatever its last word says
            if st in ('working','milestone','ready','needs-decision','blocked','paused-run') and time.time()-os.path.getmtime(os.path.join(FM,'state',fn))>86400: st='stale'
            lanes[fn[:-7]]=st
    data=json.load(open(CARD)); s=base_page(open(PAGE).read())
    # live states on main: a screen whose register ids are all live belongs in column 8
    # live means deployed: the portal-deploy job of the newest main 'vercel' run says which main commit production serves
    # ("deployed: <sha> serves production" or "held: <sha> not deployed, production stays on <sha>"); a green job can be a hold
    DEPLOYED=''; DEPLOY_NOTE=''
    try:
        runs=json.loads(run(['gh','api','repos/miko-systems/miko/actions/runs?branch=main&event=push&per_page=15'],cwd=W)).get('workflow_runs',[])
        for wr in [x for x in runs if x.get('name')=='vercel' and x.get('status')=='completed'][:4]:
            jobs=json.loads(run(['gh','api','repos/miko-systems/miko/actions/runs/%s/jobs'%wr['id']],cwd=W)).get('jobs',[])
            pj=[j for j in jobs if j.get('name')=='portal-deploy']
            if not pj: continue
            lg=re.sub(r'\x1b\[[0-9;]*m','',run(['gh','api','--allow-escape-sequences','repos/miko-systems/miko/actions/jobs/%s/logs'%pj[0]['id']],cwd=W))
            m1=re.search(r'deployed: ([0-9a-f]{7,40}) serves production',lg)
            m2=re.search(r'held: ([0-9a-f]{7,40}) not deployed, production stays on ([0-9a-f]{7,40})',lg)
            if m1: DEPLOYED=m1.group(1); DEPLOY_NOTE='uitgerold'; break
            if m2: DEPLOYED=m2.group(2); DEPLOY_NOTE='uitrol van '+m2.group(1)[:8]+' vastgehouden (wacht op de migraties in de cel)'; break
    except Exception: DEPLOYED=''
    try: REG={c['id']:c.get('state') for c in json.loads(run(['git','-C',W,'show',DEPLOYED+':apps/portal/registers/portal-states.json'])).get('components',[])} if DEPLOYED else None
    except Exception: REG=None
    if REG is None: REG={c['id']:c.get('state') for c in json.load(open(os.path.join(TMP,'portal-states.json'))).get('components',[])}
    # --- every active worker belongs on the board; popups carry the worker's latest word ---
    BANDY={'I1':(44,214),'I2':(264,214),'I3':(484,214),'I4':(704,76),'I5':(786,76),'I6':(868,76),'I7':(950,76),'I8':(1032,76),'F8':(1114,214),'CI':(1334,76)}
    def lane_last(ln):
        p=os.path.join(FM,'state',ln+'.status')
        try: L=[l for l in open(p).read().splitlines() if l.split() and l.split()[0] in ('working','milestone','ready','done','paused','captain-held','needs-decision','blocked','stopped')]
        except Exception: return None,None
        if not L: return None,None
        t=re.sub(r'^\S+\s*(?:\[[^\]]*\]\s*)*:?\s*','',L[-1]); return t[:220], time.strftime('%H:%M',time.localtime(os.path.getmtime(p)))
    for k,v in data.items():
        if isinstance(v,dict) and v.get('lane'):
            t,tm=lane_last(v['lane'])
            if t: v['stand']=t; v['stand_tijd']=tm
    def band_for(ln):
        l=ln.lower()
        for pat,b in ((r'fabric|f10|f5|controller|anchor|issuer|core|w1\d|w2\d|f8',"F8"),(r'i5|report|rapport',"I5"),(r'i6|apps',"I6"),(r'i7|copy|kopie',"I7"),(r'agents|skills|i8',"I8"),(r'chat|i4|answers',"I4"),(r'ci-|queue|gate|ruleset|split',"CI"),(r'i3|kennis|knowledge|koppel',"I3"),(r'infra|cell|backup|monitor|grafana|cost|aws',"I1")):
            if re.search(pat,l): return b
        return 'I2'
    def free_slot(b):
        y0,h=BANDY[b]; occ=[]
        for bm in re.finditer(r'<g data-id="[^"]+"([^>]*)>(.*?)</g>',s,re.S):
            r_=re.search(r'<rect x="([\d.]+)" y="([\d.]+)" width="128"',bm.group(2))
            if not r_: continue
            x,y=float(r_.group(1)),float(r_.group(2)); tr=re.search(r'translate\(([-\d.]+),([-\d.]+)\)',bm.group(1))
            if tr: x+=float(tr.group(1)); y+=float(tr.group(2))
            if y0<=y<y0+h and x<2200: occ.append((x,y))
        for ry in sorted(set(y for x,y in occ)) or [y0+20]:
            for x in range(100,2101,150):
                if all(abs(x-ox)>=140 for ox,oy in occ if oy==ry): return x,int(ry)
        return None
    shown=set(v.get('lane') for v in data.values() if isinstance(v,dict) and v.get('lane'))
    for v in data.values():
        if isinstance(v,dict): shown.update(v.get('lanes_extra',[]))
    shown.update(data.get('_ignore_lanes',[]))
    plain=html.unescape(s); added=[]
    for ln,st in sorted(lanes.items()):
        if not ln.startswith('miko-') or ln=='miko-all-in-one-lavish' or ln in shown or ln in plain: continue
        if st not in ('working','milestone','ready','paused-run','needs-decision','blocked','paused'): continue
        # dormant lanes (no word for 3 hours and not working, blocked or asking) are not current work
        if st not in ('working','paused-run','needs-decision','blocked') and time.time()-os.path.getmtime(os.path.join(FM,'state',ln+'.status'))>3*3600: continue
        try: kind=(re.search(r'^kind=(\S+)',open(os.path.join(FM,'state',ln+'.meta')).read(),re.M) or [0,''])[1]
        except Exception: kind=''
        if kind not in ('ship','scout'): continue
        title=(data.get('_lane_names') or {}).get(ln)
        def human(l):
            x=l[5:]
            for p_,q_ in (('build-','Bouwen: '),('live3-','Live: '),('live2-','Live: '),('fix-','Reparatie: '),('g3-review-','Review: '),('controller-','Controller: '),('design-','Ontwerp: ')):
                if x.startswith(p_): return q_+x[len(p_):].replace('-',' ')
            return x.replace('-',' ')
        if not title: title=human(ln)
        title=html.unescape(title)[:70]
        if title in data: title=title+' ('+ln+')'
        b=band_for(ln); slot=free_slot(b) if b in BANDY else None
        did=b+':AUTO-'+ln[5:].upper()[:40]
        t,tm=lane_last(ln)
        data[title]={'eta':'onbekend (automatisch toegevoegd)','bron':'automatisch: werker '+ln,'klaar':['Wat de werker '+ln+' moet opleveren staat op main','Daarna de volgende stap naar live'],'lane':ln,'stand':t or '','stand_tijd':tm or '','auto':True}
        card=('<div class="kb-card" data-wbs="'+did+'" style="border:1.6px solid #9aa4b2;border-radius:7px;padding:4px 6px;margin:0 0 5px;background:#181b22;font-size:12.5px;min-width:0;overflow-wrap:anywhere"><b>'+html.escape(title,quote=False)+'</b><br><span class="mute" style="font-size:11.5px">nieuw op het bord (automatisch), werker '+ln+'</span>'
              '<br><span class="kb-next" style="display:inline-block;margin:2px 0 0;font-size:10.5px;font-weight:700;color:#9aa4b2;border:1px solid #9aa4b2;border-radius:9px;padding:0 5px">· nog in te delen</span>'
              '<span style="display:flex;gap:2px;margin:3px 0 0" title="acht stappen: 2 van 8">'+''.join('<i style="flex:1;height:4px;border-radius:1px;background:%s"></i>'%('#3fa36b' if i<1 else '#9aa4b2' if i==1 else '#353b47') for i in range(8))+'</span></div>')
        km=re.search(r'<p style="margin:0;font-size:12\.5px"><b>2 [^<]*</b>.*?</p><p class="small mute" style="margin:0 0 5px;font-size:11px">[^<]*</p>',s,re.S)
        if km: s=s[:km.end()]+card+s[km.end():]
        if slot:
            x,y=slot; tip=title+'\nStatus: nieuw op het bord · werker '+ln+'\nWerker: '+ln+'\nAcht stappen: 1 opdracht klaar · 2 code open · 3 PR en review open · 4 in main open · 5 proef open · 6 G1-G10 + review open · 7 live-PR en uitrol open · 8 live bewezen open'
            short=title if len(title)<=22 else title[:21]+'…'
            gx=('<g data-id="'+did+'" data-tip="'+html.escape(tip,quote=True).replace('\n','&#10;')+'"><title>'+html.escape(tip,quote=False)+'</title><rect x="%d" y="%d" width="128" height="40" rx="6" fill="#0f1218" stroke="#9aa4b2" stroke-width="1.5"/>'%(x,y)+
                '<text x="%d" y="%d" font-size="10.5" font-weight="700" fill="#f1f3f6">%s</text><text x="%d" y="%d" font-size="9.5" fill="#9aa4b2">nieuw</text>'%(x+7,y+16,html.escape(short,quote=False),x+7,y+30)+
                ''.join('<rect x="%.1f" y="%.1f" width="13.5" height="3.5" rx="1" fill="%s"/>'%(x+5+14.8*i,y+35,'#3fa36b' if i<1 else '#9aa4b2' if i==1 else '#353b47') for i in range(8))+'</g>')
            se=s.index('</svg>',s.index('<svg',s.index('id="wbs-zoom"'))); s=s[:se]+gx+s[se:]
        added.append(ln+(' (geen plek in '+b+')' if not slot else ''))
    if added: print('LANES-ADDED: '+', '.join(added))
    def pr_state(n):
        if n in OPEN:
            o=OPEN[n]; st=((o['commits']['nodes'] or [{}])[0].get('commit') or {}).get('statusCheckRollup') or {}
            st=st.get('state','')
            if o['isInMergeQueue']: return ('queue',(o.get('mergeQueueEntry') or {}).get('position'))
            if o.get('mergeable')=='CONFLICTING': return ('conflict',None)
            if st in ('FAILURE','ERROR'): return ('fail',None)
            if st=='SUCCESS': return ('ready',None)
            return ('checks',None)
        if n in MERGED: return ('merged',None)
        return ('unknown',None)
    moves=[]; changed=0
    def card_sub(m):
        nonlocal changed
        c=m.group(0)
        if 'kb-mini' in c: return c
        t=re.search(r'<b>([^<]*)</b>',c); title=html.unescape(t.group(1)) if t else ''
        lab=re.search(r'class="kb-next"[^>]*>([^<]*)</span>',c); cur=lab.group(1) if lab else ''
        # a screen card marked done whose parts are not live in the commit production serves goes back to 'uitrol wacht'
        _reg=(data.get(title) or {}).get('register')
        if 'klaar' in cur and _reg and not all(REG.get(x)=='live' for x in _reg):
            l_,col_=LAB['fm']
            chip_='<br><span class="kb-next" style="display:inline-block;margin:2px 0 0;font-size:10.5px;font-weight:700;color:'+col_+';border:1px solid '+col_+';border-radius:9px;padding:0 5px">'+l_+'</span> <span style="font-size:10.5px;color:#c9ced6">'+html.escape('live op main, '+(DEPLOY_NOTE or 'nog niet uitgerold'))+'</span>'
            c2_=re.sub(r'<br><span class="kb-next".*?</span>(?: <span style="font-size:10\.5px;color:#c9ced6">[^<]*</span>)?',chip_,c,1,flags=re.S)
            c2_=re.sub(r'border:(?:1\.6|2)px solid #[0-9a-f]{6}','border:1.6px solid '+col_,c2_,1)
            moves.append((title,7)); changed+=1
            return c2_
        if ('op jou' in cur or 'klaar' in cur) and (data.get(title) or {}).get('staat') not in ('niet','later','fm'): return c
        vast=(data.get(title) or {}).get('staat')
        if vast=='fm':
            _cd=(data.get(title) or {}); _ls=[_cd.get('lane')]+_cd.get('lanes_extra',[])
            if any(lanes.get(x,'') in ('working','milestone','ready','needs-decision','blocked','paused-run') for x in _ls if x): vast=None
        if vast in ('niet','later','fm'):
            kind=vast; extra=(data.get(title) or {}).get('staat_waarom','')
            l,col=LAB[kind]
            chip='<br><span class="kb-next" style="display:inline-block;margin:2px 0 0;font-size:10.5px;font-weight:700;color:'+col+';border:1px solid '+col+';border-radius:9px;padding:0 5px">'+l+'</span>'+(' <span style="font-size:10.5px;color:#c9ced6">'+html.escape(extra)+'</span>' if extra else '')
            c2=re.sub(r'<br><span class="kb-next".*?</span>(?: <span style="font-size:10\.5px;color:#c9ced6">[^<]*</span>)?',chip,c,1,flags=re.S)
            c2=re.sub(r'border:(?:1\.6|2)px solid #[0-9a-f]{6}','border:1.6px solid '+col,c2,1)
            if c2!=c: changed+=1
            return c2
        note=re.search(r'<br><span class="mute" style="font-size:11\.5px">([^<]*)</span>',c); nt=html.unescape(note.group(1)) if note else ''
        prs=[int(x) for x in re.findall(r'\bPR\'?s? (\d{3,4})',nt)]+[int(x) for x in re.findall(r'(?:,| en ) ?(\d{3,4})\b',nt) if re.search(r'PR',nt)]
        prs=sorted(set(p for p in prs if 300<p<5000))
        lane=(data.get(title) or {}).get('lane'); ls=lanes.get(lane,'') if lane else ''
        running=bool(lane and ls in ('working','milestone','ready','needs-decision','blocked','paused-run'))
        if not running and any(lanes.get(x,'') in ('working','milestone','ready','needs-decision','blocked','paused-run') for x in (data.get(title) or {}).get('lanes_extra',[])): running=True
        # firstmate said a worker is being dispatched: trust that for 2 hours, then only the real lane state counts
        if not running and time.time()-((data.get(title) or {}).get('bezig_sinds') or 0)<7200: running=True
        kind=None; extra=''
        states={p:pr_state(p) for p in prs}
        q=[(p,v[1]) for p,v in states.items() if v[0]=='queue']; f=[p for p,v in states.items() if v[0]=='fail']; cf=[p for p,v in states.items() if v[0]=='conflict']; ch=[p for p,v in states.items() if v[0]=='checks']; rd=[p for p,v in states.items() if v[0]=='ready']; mg=[p for p,v in states.items() if v[0]=='merged']
        if q: kind='auto'; extra='; '.join('PR %d: plek %s in de wachtrij'%(p,pos) for p,pos in q)
        elif f or cf: kind='vast'; extra='; '.join(['PR %d: een controle faalt'%p for p in f]+['PR %d botst met main'%p for p in cf])
        elif ch: kind='auto'; extra='; '.join('PR %d in de controle'%p for p in ch)
        elif rd: kind='fm'; extra='; '.join('PR %d groen, wacht op de wachtrij'%p for p in rd)
        elif prs and len(mg)==len(prs):
            screen='title="nodig nu: 8 controles' in c
            extra='PR '+', '.join(map(str,mg))+' op main'
            if running: kind='werk'
            elif (data.get(title) or {}).get('nog_open'): kind='fm'
            elif ls in ('done','') and not screen: kind='klaar'; moves.append((title,8))
            else: kind='fm'
            colm=re.search(r'title="acht stappen: (\d) van 8"',c)
            if kind!='klaar' and colm and int(colm.group(1)) in (2,3): moves.append((title,4))
        elif running: kind='werk'; extra=lane
        elif ls in ('done','paused','resolved','captain-held','stale','') and 'werker bezig' in cur: kind='fm'
        reg=(data.get(title) or {}).get('register')
        if reg and all(REG.get(x)=='live' for x in reg):
            colm=re.search(r'title="acht stappen: (\d) van 8"',c)
            if not (colm and colm.group(1)=='8'): moves.append((title,8))
            if kind in (None,'fm','werk') : kind='klaar'; extra='live op miko-os.ai (uitrol '+(DEPLOYED[:8] if DEPLOYED else 'main')+')'
        if not kind: return c
        l,col=LAB[kind]
        chip='<br><span class="kb-next" style="display:inline-block;margin:2px 0 0;font-size:10.5px;font-weight:700;color:'+col+';border:1px solid '+col+';border-radius:9px;padding:0 5px">'+l+'</span>'+(' <span style="font-size:10.5px;color:#c9ced6">'+html.escape(extra)+'</span>' if extra else '')
        c2=re.sub(r'<br><span class="kb-next".*?</span>(?: <span style="font-size:10\.5px;color:#c9ced6">[^<]*</span>)?',chip,c,1,flags=re.S)
        if 'border:1.6px solid #ffa94d' not in c or kind!='auto':
            c2=re.sub(r'border:(?:1\.6|2)px solid #[0-9a-f]{6}','border:1.6px solid '+col,c2,1)
        if c2!=c: changed+=1
        return c2
    s=re.sub(r'<div class="kb-card".*?</div>',card_sub,s,flags=re.S)
    # --- linked WBS boxes say what their card says; card and box agree on the step ---
    def colsync(s):
        k0=s.find('id="kanban"'); w0=s.find('id="wbs-blok"')
        kp=s[k0:w0]; kc=[(m_.start(),m_.group(1)) for m_ in re.finditer(r'<p style="margin:0;font-size:12\.5px"><b>(\d) [^<]*</b>',kp)]
        todo=[]
        for cm in re.finditer(r'<div class="kb-card"(?:(?!kb-mini)[^>])*data-wbs="([^"]+)"[^>]*>(.*?)</div>',kp,re.S):
            here=[x for p,x in kc if p<cm.start()]
            if not here: continue
            body=cm.group(2); tt=re.search(r'<b>([^<]*)',body); title=html.unescape(tt.group(1)) if tt else ''
            lab=(re.search(r'class="kb-next"[^>]*>([^<]*)',body) or [0,''])[1]
            note=html.unescape((re.search(r'font-size:11\.5px">([^<]*)',body) or [0,''])[1])
            extra=html.unescape((re.search(r'color:#c9ced6">([^<]*)',body) or [0,''])[1])
            todo.append((cm.group(1),int(here[-1]),title,lab,note,extra))
        sync=0
        for did,ccol,title,lab,note,extra in todo:
            bx=re.search(r'<g data-id="'+re.escape(did)+r'"[^>]*>(.*?)</g>',s,re.S)
            if not bx: continue
            g=bx.group(0); fl=re.findall(r'width="13\.5" height="3\.5" rx="1" fill="([^"]+)"',g)
            bcol=next((i+1 for i,f in enumerate(fl) if f!='#3fa36b'),8) if len(fl)==8 else ccol
            pinned=(data.get(title) or {}).get('staat') in ('niet','later','fm')
            klaar='klaar' in lab
            target=8 if klaar else (ccol if pinned else max(ccol,bcol))
            _rg=(data.get(title) or {}).get('register')
            if _rg and not all(REG.get(x)=='live' for x in _rg): target=min(target,7)
            lane=(data.get(title) or {}).get('lane')
            label=re.sub(r'^[^\w·]*\s*','',lab).lstrip('· ').strip()
            stl='Status: '+label+(' · '+note if note else '')+(' · '+extra if extra and extra not in note else '')
            g2=re.sub(r'Status: (?:(?!&#10;)[^"<\n])*',lambda m_:html.escape(stl,quote=True),g)
            if lane:
                if re.search(r'Werker: ',g2): g2=re.sub(r'Werker: (?:(?!&#10;)[^"<\n])*','Werker: '+lane,g2)
                else: g2=re.sub(r'(data-tip="[^"]*?)(&#10;Acht stappen|")',lambda m_:m_.group(1)+'&#10;Werker: '+lane+m_.group(2),g2,1)
            if target!=bcol and len(fl)==8:
                cur=re.search(r'<rect [^>]*width="128"[^>]*stroke="(#[0-9a-f]{6})"',g2); cur=cur.group(1) if cur else '#9aa4b2'
                if cur in ('#3fa36b','#7fe0a5') and target<8: cur='#9aa4b2'
                i_=[0]
                def f_(m_):
                    k_=i_[0]; i_[0]+=1
                    return m_.group(1)+('#3fa36b' if (k_<target-1 or target==8) else cur if k_==target-1 else '#353b47')+m_.group(2)
                g2=re.sub(r'(width="13\.5" height="3\.5" rx="1" fill=")#[0-9a-f]{6}(")',f_,g2)
            if g2!=g: s=s.replace(g,g2,1); sync+=1
            if target!=ccol: moves.append((title,target))
        return s,sync
    s,boxsync=colsync(s)
    # simple moves: cards whose PRs are all merged go from column 2/3 to column 4
    for title,tcol in moves:
        m=re.search(r'<div class="kb-card"(?:(?!kb-mini)[^>])*><b>'+re.escape(html.escape(title,quote=False))+r'</b>.*?</div>',s,re.S)
        if not m: continue
        c=m.group(0); s=s[:m.start()]+s[m.end():]
        c=re.sub(r'<span style="display:flex;gap:2px;margin:3px 0 0" title="acht stappen: \d van 8">.*?</span>',lambda x:'<span style="display:flex;gap:2px;margin:3px 0 0" title="acht stappen: '+str(tcol)+' van 8">'+''.join('<i style="flex:1;height:4px;border-radius:1px;background:'+('#3fa36b' if i<tcol-1 or tcol==8 else ('#2dd4bf' if i==tcol-1 else '#353b47'))+'"></i>' for i in range(8))+'</span>',c,1,flags=re.S)
        k=re.search(r'<p style="margin:0;font-size:12\.5px"><b>'+str(tcol)+r' [^<]*</b>.*?</p><p class="small mute" style="margin:0 0 5px;font-size:11px">[^<]*</p>',s,re.S)
        s=s[:k.end()]+c+s[k.end():]
    # WBS boxes follow their rich card colour
    a=s.find('<section id="wbs-blok"'); e=s.find('</section>',a); w=s[a:e]
    pairs=[(m.group(1),m.group(2),html.unescape((re.search(r'<b>([^<]*)</b>',s[m.end():m.end()+400]) or [None,''])[1])) for m in re.finditer(r'<div class="kb-card"[^>]*data-wbs="([^"]+)"[^>]*style="border:(?:1\.6|2)px solid (#[0-9a-f]{6})',s[:a])]
    extra=[]
    for did,col,title in pairs:
        for x in (data.get(title) or {}).get('wbs_extra',[]): extra.append((x,col,title))
    for did,col,title in pairs+extra:
        gm=re.search(r'<g data-id="'+re.escape(did)+r'"[^>]*>.*?</g>',w,re.S)
        if gm:
            g=re.sub(r'(<rect [^>]*width="128"[^>]*stroke=")#[0-9a-f]{6}(")',r'\g<1>'+col+r'\2',gm.group(0),1)
            w=w[:gm.start()]+g+w[gm.end():]
    # reconcile EVERY other WBS box from real state (lanes named in its text, PRs named in its text)
    rich=set(re.findall(r'<div class="kb-card"(?![^>]*kb-mini)[^>]*data-wbs="([^"]+)"',s[:a]))
    for v in data.values():
        if isinstance(v,dict): rich.update(v.get('wbs_extra',[]))
    boxstat={'queue':0,'fail':0,'checks':0,'run':0,'held':0,'reset':0}
    def rec(m):
        did,g=m.group(1),m.group(0)
        if did in rich or did.startswith('DONE:'): return g
        tip=html.unescape((re.search(r'data-tip="([^"]*)"',g) or [None,''])[1])
        cur=(re.search(r'<rect [^>]*width="128"[^>]*stroke="(#[0-9a-f]{6})"',g) or [None,''])[1]
        if not cur: return g
        # a box explicitly set to later / nog niet keeps that status; workers named in its text do not recolour it
        stl=[x for x in tip.split('\n') if x.startswith('Status')]
        if stl and re.match(r'Status: (later|nog niet)',stl[0]): return g
        ln=set(re.findall(r'\b(miko-[a-z0-9-]+)',tip))&set(lanes)
        prs=sorted(set(int(x) for x in re.findall(r'\bPR\'?s? (\d{3,4})',tip)))
        st=[pr_state(p)[0] for p in prs]
        new=None
        if 'queue' in st or 'checks' in st: new=TE; boxstat['queue']+=1
        elif 'fail' in st: new=OR; boxstat['fail']+=1
        elif 'ready' in st: new=BL; boxstat.setdefault('ready',0); boxstat['ready']+=1
        elif any(lanes[l] in ('working','milestone','ready','needs-decision','blocked','paused-run') for l in ln): new=YE; boxstat['run']+=1
        elif any(lanes[l]=='captain-held' for l in ln): new=RE; boxstat['held']+=1
        elif cur in (YE,TE,'#e0b23a'): new='#9aa4b2'; boxstat['reset']+=1
        if not new or new==cur: return g
        g=re.sub(r'(<rect [^>]*width="128"[^>]*stroke=")#[0-9a-f]{6}(")',r'\g<1>'+new+r'\2',g,1)
        if new=='#9aa4b2': g=g.replace('fill="#e0b23a"','fill="#9aa4b2"').replace('fill="#2dd4bf"','fill="#9aa4b2"')
        return g
    w=re.sub(r'<g data-id="([^"]+)"[^>]*>.*?</g>',rec,w,flags=re.S)
    # dependencies: the arrows data-f -> data-t; recompute "Kan starten" from the real state of what comes first
    deps=collections.defaultdict(list)
    for pm in re.finditer(r'<path data-f="([^"]+)" data-t="([^"]+)"',w): deps[pm.group(2)].append(pm.group(1))
    box={}
    for bm in re.finditer(r'<g data-id="([^"]+)"[^>]*>(.*?)</g>',w,re.S):
        g=bm.group(2); st=re.search(r'<rect [^>]*width="128"[^>]*stroke="(#[0-9a-f]{6})"',g)
        fills=re.findall(r'width="13\.5" height="3\.5" rx="1" fill="([^"]+)"',g)
        lab=re.findall(r'<text [^>]*font-weight="700"[^>]*>([^<]*)</text>',g)
        done=bm.group(1).startswith('DONE:') or (st and st.group(1) in (GN,'#3fa36b')) or (len(fills)==8 and all(f=='#3fa36b' for f in fills))
        box[bm.group(1)]=(bool(done),html.unescape(lab[0]) if lab else bm.group(1),st.group(1) if st else '')
    depaudit=[]; depchanged=0
    def dep(bm):
        nonlocal depchanged
        did,g=bm.group(1),bm.group(0)
        pre=[p for p in deps.get(did,[]) if p in box]
        if not pre or box.get(did,(False,))[0]: return g
        open_=[box[p][1] for p in pre if not box[p][0]]
        line='Kan starten: ja, alles ervoor is klaar' if not open_ else 'Kan starten: nee, eerst: '+', '.join(open_[:3])+(' en meer' if len(open_)>3 else '')
        if open_ and box[did][2] in (YE,TE): depaudit.append(did)
        g2=re.sub(r'Kan starten: (?:(?!&#10;)[^"<\n])*',lambda m:html.escape(line,quote=True),g)
        if 'Kan starten:' not in g2:
            g2=re.sub(r'(data-tip="[^"]*?)(&#10;Acht stappen|")',lambda m:m.group(1)+'&#10;'+html.escape(line,quote=True)+m.group(2),g2,1)
        if g2!=g: depchanged+=1
        return g2
    w=re.sub(r'<g data-id="([^"]+)"[^>]*>.*?</g>',dep,w,flags=re.S)
    if depaudit: print('DEP-AUDIT (running while something before it is open): '+', '.join(depaudit))
    boxstat['deps']=depchanged
    s=s[:a]+w+s[e:]
    js=json.dumps(data,ensure_ascii=False).replace('</','<\\/')
    s=re.sub(r'(<script type="application/json" id="card-data">).*?(</script>)',lambda m:m.group(1)+js+m.group(2),s,flags=re.S)
    p1=os.path.join(TMP,'a.html'); p2=os.path.join(TMP,'b.html'); open(p1,'w').write(s)
    run([sys.executable,'-I',os.path.join(BIN,'kanban-from-wbs.py'),p1,p2,now,os.path.join(TMP,'prod-gate.json'),os.path.join(TMP,'portal-states.json')])
    s=open(p2).read()
    def fix(m):
        b=m.group(2)
        b=re.sub(r'background:repeating-linear-gradient\(45deg,#262b35 0 2px,#3a404c 2px 4px\);border:1px dashed #5a606c;opacity:\.7','background:#9aa4b2;border:1px solid #9aa4b2',b)
        b=b.replace('background:#262b35;border:1px solid #3a404c','background:transparent;border:1.5px solid #c9ced6').replace('background:#3fa36b;border:1px solid #3a404c','background:#2fd27a;border:1px solid #2fd27a').replace('height:6px','height:9px')
        return m.group(1)+b+m.group(3)
    s=re.sub(r'(<span style="display:flex;gap:2px;align-items:center;margin:2px 0 0" title="nodig nu: 8 controles[^"]*">)(.*?)(<b )',fix,s,flags=re.S)
    s=re.sub(r'(2\. Kanban <span class="small mute">\(stand )\d\d:\d\d',r'\g<1>'+now,s)
    # G1-G10 strips on the rich screen cards come from prod-gate.json on main, every run
    PG=json.load(open(os.path.join(TMP,'prod-gate.json'))).get('components',{})
    GI=['G1','G2','G3','G4','G5','G6','G7','G8','G9','G10']
    gfix=0
    def gstrip_card(cm):
        nonlocal gfix
        c=cm.group(0)
        tt=re.search(r'<b>([^<]*)</b>',c); title=html.unescape(tt.group(1)) if tt else ''
        comps=(data.get(title) or {}).get('register')
        sp=re.search(r'<span style="display:flex;gap:2px;align-items:center;margin:([23])px 0 0" title="nodig nu: 8 controles[^"]*">(.*?)<b [^>]*>[^<]*</b></span>',c,re.S)
        if not comps or not sp: return c
        old_titles=[ (re.search(r'title="([^"]*)"',x) or [0,None])[1] for x in re.findall(r'<i [^>]*></i>',sp.group(2))]
        cells=[];n=0
        for i_,g_ in enumerate(GI):
            ok=all(PG.get(cp,{}).get(g_) for cp in comps)
            if g_ in ('G8','G9'): st_='background:#9aa4b2;border:1px solid #9aa4b2'
            elif ok: st_='background:#2fd27a;border:1px solid #2fd27a'; n+=1
            else: st_='background:transparent;border:1.5px solid #c9ced6'
            t_=old_titles[i_] if i_<len(old_titles) and old_titles[i_] and not ok else None
            cells.append('<i style="flex:1;height:9px;border-radius:1px;'+st_+'"'+(' title="'+t_+'"' if t_ else '')+'></i>')
        new='<span style="display:flex;gap:2px;align-items:center;margin:'+sp.group(1)+'px 0 0" title="nodig nu: 8 controles (G8 en G9 later); met bewijs op main: '+str(n)+' van 8">'+''.join(cells)+'<b style="font-size:10px;margin-left:3px">'+str(n)+'/8</b></span>'
        c2=c[:sp.start()]+new+c[sp.end():]
        if c2!=c: gfix+=1
        return c2
    s=re.sub(r'<div class="kb-card"(?:(?!kb-mini)[^>])*>.*?</div>',gstrip_card,s,flags=re.S)
    boxstat['gstrips']=gfix
    s=re.sub(r'bijgewerkt (?:[a-z]{2} )?\d\d-\d\d-\d{4} \d\d:\d\d CET(?: \((?:automatisch, elke 5 minuten|automatisch elk uur, en als je op ververs tikt)\))?','bijgewerkt '+time.strftime('%d-%m-%Y %H:%M')+' CET (automatisch elk uur, en als je op ververs tikt)',s,count=1)
    # column 8: keep what is still moving or went live in the last 2 days; fold older done cards and the archive groups
    def collapse8(s):
        s=re.sub(r'<details class="kb-oud"[^>]*><summary[^>]*>.*?</summary>(.*?)</details><!--/kb-oud-->',lambda m:m.group(1),s,flags=re.S)
        k=s.find('<p style="margin:0;font-size:12.5px"><b>8 ')
        if k<0: return s,0
        st=s.rfind('<div',0,k); d=0
        for m in re.finditer(r'<div\b|</div>',s[st:]):
            d+=1 if m.group(0)=='<div' else -1
            if d==0: en=st+m.end(); break
        col=s[st:en]
        col=re.sub(r'(<details)\s+open(?=[\s>])',r'\1',col)
        cutoff=time.time()-2*86400
        def recent(card):
            for p in re.findall(r'\b(\d{3,4})\b',re.sub(r'<[^>]+>',' ',card)):
                at=MERGEDAT.get(int(p))
                if at and time.mktime(time.strptime(at,'%Y-%m-%dT%H:%M:%SZ'))-time.timezone>cutoff: return True
            return False
        old=[]
        def take(m):
            c=m.group(0)
            if 'kb-mini' in c or '✓ klaar' not in c or recent(c): return c
            old.append(c); return ''
        col=re.sub(r'<div class="kb-card"(?:(?!kb-mini)[^>])*>.*?</div>',take,col,flags=re.S)
        if old:
            head=re.search(r'<p class="small mute" style="margin:0 0 5px;font-size:11px">[^<]*</p>',col)
            pos=col.find('<details',head.end())
            if pos<0: pos=len(col)-6
            blk='<details class="kb-oud" style="margin:4px 0"><summary class="small" style="cursor:pointer;color:#9aa4b2">Eerder klaar, langer dan 2 dagen ('+str(len(old))+')</summary>'+''.join(old)+'</details><!--/kb-oud-->'
            col=col[:pos]+blk+col[pos:]
        return s[:st]+col+s[en:],len(old)
    s,n8=collapse8(s)
    ids=re.findall(r'\sid="([^"]+)"',s)
    assert len(ids)==len(set(ids)),'duplicate ids'
    assert 'id="kanban"' in s and 'id="wbs-blok"' in s and 'id="captain-door"' in s
    s=render_captain_steps(render_truth(s,truth['goals']),truth)
    staged=os.path.join(TMP,'verify.html')
    with open(staged,'w',encoding='utf-8') as f: f.write(s)
    if sync(['--verify-page',staged,'--out',truth_path]):
        raise ValueError('built cockpit did not pass verification')
    # status audit: a coloured box whose own status text says it is not happening now
    audit=[]
    for m in re.finditer(r'<g data-id="([^"]+)" data-tip="([^"]*)"[^>]*>(.*?)</g>',s,re.S):
        if m.group(1).startswith('DONE:'): continue
        cc=re.search(r'<rect [^>]*width="128"[^>]*stroke="(#[0-9a-f]{6})"',m.group(3))
        if not cc or cc.group(1) not in (YE,TE,BL,RE,OR): continue
        st=[x for x in html.unescape(m.group(2)).split('\n') if x.startswith('Status')]
        if st and re.search(r'Status: (later|nog niet)|geen werker|nog geen werker',st[0].split(' · eerder:')[0]): audit.append(m.group(1))
    if audit: print('STATUS-AUDIT (coloured but text says not now): '+', '.join(audit))
    # column audit: a rich card linked to a WBS box should sit in the column of the box's first open step
    colaudit=[]
    kk=s.find('id="kanban"'); ww=s.find('id="wbs-blok"'); kpart=s[kk:ww]
    kcols=[(cm.start(),cm.group(1)) for cm in re.finditer(r'<p style="margin:0;font-size:12\.5px"><b>(\d) [^<]*</b>',kpart)]
    for cm in re.finditer(r'<div class="kb-card"(?:(?!kb-mini)[^>])*data-wbs="([^"]+)"[^>]*>(.*?)</div>',kpart,re.S):
        here=[x for p,x in kcols if p<cm.start()]
        if not here: continue
        bx=re.search(r'<g data-id="'+re.escape(cm.group(1))+r'"[^>]*>(.*?)</g>',s,re.S)
        if not bx: continue
        fl=re.findall(r'width="13\.5" height="3\.5" rx="1" fill="([^"]+)"',bx.group(1))
        if len(fl)!=8: continue
        want=str(next((i+1 for i,f in enumerate(fl) if f!='#3fa36b'),8))
        if want!=here[-1] and '✓ klaar' not in cm.group(2): colaudit.append('%s (kolom %s, WBS zegt %s)'%(re.search(r'<b>([^<]*)',cm.group(2)).group(1) if re.search(r'<b>([^<]*)',cm.group(2)) else cm.group(1),here[-1],want))
    if colaudit: print('COLUMN-AUDIT: '+'; '.join(colaudit))
    # --- more checks so a refresh catches everything that can go stale ---
    extra_probs=['%s: %s'%(m['key'],m['text']) for m in truth['mismatches']]; arch_note=''
    # notes and WBS status lines that still say a merged PR is waiting
    for cm in re.finditer(r'<div class="kb-card"(?:(?!kb-mini)[^>])*>(.*?)</div>',s,re.S):
        body=cm.group(1); note=html.unescape((re.search(r'font-size:11\.5px">([^<]*)',body) or [0,''])[1])
        for pn in re.findall(r'PR (\d{3,4})',note):
            if int(pn) in MERGED and re.search(r'PR '+pn+r'[^;.]*?(wachtrij|controle|samenvoegen|open)',note):
                tt=re.search(r'<b>([^<]*)',body); extra_probs.append('kaarttekst %s: PR %s staat al op main'%(html.unescape(tt.group(1)) if tt else '?',pn))
    for bm in re.finditer(r'<g data-id="([^"]+)" data-tip="([^"]*)"',s):
        st_=[x for x in html.unescape(bm.group(2)).split('\n') if x.startswith('Status')]
        if not st_ or bm.group(1).startswith('DONE:'): continue
        for pn in re.findall(r'PR (\d{3,4})',st_[0]):
            if int(pn) in MERGED and re.search(r'PR '+pn+r'[^;.·]*?(in de wachtrij|in de controle|wacht op samenvoegen)',st_[0]):
                extra_probs.append('WBS %s: PR %s staat al op main'%(bm.group(1),pn))
    # captain cards whose question is no longer held
    for fk in re.findall(r'data-lavish-question="([^"]+)"',s[s.find('id="captain-door"'):s.find('id="kanban"')]):
        if fk.startswith('goal.drive.'): continue  # board action, not a task hold
        try:
            out=subprocess.run(['tasks-axi','show',fk],cwd=FM,env=dict(os.environ,FM_HOME=FM),capture_output=True,text=True,timeout=20).stdout
        except Exception: continue
        if re.search(r'^\s*id: ',out,re.M) and re.search(r'^\s*held: no',out,re.M): extra_probs.append('kaart bovenaan %s: de vraag staat niet meer open'%fk)
    # architecture drawing older than its source on main
    try:
        src=run(['git','-C',W,'log','-1','--format=%cs','origin/main','--','docs/project/architecture.md']).strip()
        mm=re.search(r'Hoofdtekening: stand [a-z]{2} (\d\d)-(\d\d)-(\d{4})',s)
        arch_note=('bron op main laatst gewijzigd op %s; deze tekening is van %s-%s-%s, nalopen aangevraagd'%(src,mm.group(1),mm.group(2),mm.group(3))) if (src and mm and src>'%s-%s-%s'%(mm.group(3),mm.group(2),mm.group(1))) else ('bron op main ongewijzigd sinds deze tekening' if src and mm else '')
    except Exception: pass
    if extra_probs: print('CONTENT-AUDIT: '+'; '.join(extra_probs))
    # show the audit result on the board itself, so a missed fix is visible to the captain
    probs=len(audit)+len(colaudit)+len(depaudit)+len(extra_probs)
    ctl=('<span id="bordcontrole" class="small" style="margin-left:6px;color:'+('#7fe0a5' if not probs else '#ffa94d')+'">'
         +('bordcontrole '+now+': alles klopt (werkers, PR\'s, live op main, afhankelijkheden, kolommen)' if not probs else 'bordcontrole '+now+': '+str(probs)+' afwijking(en), wordt rechtgezet')+'</span>')
    tgt=os.environ.get('COCKPIT_OUT') or PAGE
    pg=s
    pg=re.sub(r'\((?:nagekeken|bijgewerkt) [a-z]{2} \d\d-\d\d(?: \d\d:\d\d)?\)','(bijgewerkt '+['ma','di','wo','do','vr','za','zo'][time.localtime().tm_wday]+' '+time.strftime('%d-%m %H:%M')+')',pg,1)
    if 'id="bordcontrole"' in pg: pg=re.sub(r'<span id="bordcontrole"[^>]*>[^<]*</span>',lambda m_:ctl,pg,1)
    else: pg=re.sub(r'(2\. Kanban <span class="small mute">\(stand [^)]*\)</span>)',lambda m_:m_.group(1)+ctl,pg,1)
    if arch_note:
        an='<span id="archcheck" class="small" style="color:#ffa94d;margin-left:6px">('+arch_note+')</span>'
        if 'id="archcheck"' in pg: pg=re.sub(r'<span id="archcheck"[^>]*>[^<]*</span>',lambda m_:an,pg,1)
        else: pg=re.sub(r'(Hoofdtekening: stand [^(]*\([^)]*\))',lambda m_:m_.group(1)+an,pg,1)
    if not preview:
        tmpc=CARD+'.tmp'; json.dump(data,open(tmpc,'w'),ensure_ascii=False,indent=1); os.replace(tmpc,CARD)
    tmp2=tgt+'.tmp2'; open(tmp2,'w').write(pg); os.replace(tmp2,tgt)
    scoreboard_config=os.environ.get('COCKPIT_SCOREBOARD_CONFIG')
    if scoreboard_config:
        run([sys.executable, '-I', os.path.join(BIN, '../../bin/fm-secondmate-scoreboard.py'),
             '--config', scoreboard_config, '--output', (tgt+'.scoreboard.json' if os.environ.get('COCKPIT_OUT') else os.path.join(D, 'secondmate-scoreboard.json')),
             '--page', tgt])
    print('production serves %s %s'%(DEPLOYED[:8] or 'unknown (main used)',DEPLOY_NOTE)); print('cockpit refreshed %s: %d cards updated, %d moved, %d boxes synced to their card, %d open PRs, %d in queue; WBS boxes: %s'%(now,changed,len(moves),boxsync,len(OPEN),sum(1 for o in OPEN.values() if o['isInMergeQueue']),boxstat))
if __name__=='__main__': main()
