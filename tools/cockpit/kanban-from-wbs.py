import sys,re,html,json,collections
src,out,now,pg,ps=sys.argv[1:6]
s=open(src).read(); gate=json.load(open(pg))['components']; states={c['id']:c['state'] for c in json.load(open(ps))['components']}
E=lambda t: html.escape(t,quote=False)
k0=s.find('<section id="kanban"'); k1=s.find('</section>',k0)
kan=s[k0:k1]
gs=kan.find('<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,128px),1fr));gap:5px">')
sc=kan.find('<script>',gs)
if sc<0:
    nk=kan.find('<p class="small mute" style="margin:6px 0 0">Alles uit de WBS',gs); assert nk>0
    sc=kan.find('</p>',nk)+4
assert gs>0 and sc>gs
gridpart=kan[gs:sc]
# curated cards per column
cols=re.split(r'(?=<div style="border:1px solid #2b3140;border-radius:8px;padding:5px;background:#141821;min-width:0"><p style="margin:0;font-size:12.5px"><b>\d )',gridpart)
cur={}
heads={}
for c in cols:
    m=re.match(r'<div style="border:1px solid #2b3140;border-radius:8px;padding:5px;background:#141821;min-width:0"><p style="margin:0;font-size:12.5px"><b>(\d) ([^<]*)</b>.*?<p class="small mute" style="margin:0 0 5px;font-size:11px">([^<]*)</p>',c,re.S)
    if not m: continue
    n=int(m.group(1)); heads[n]=(m.group(1)+' '+m.group(2),m.group(3))
    cur[n]=[x for x in re.findall(r'<div class="kb-card".*?</div>',c,re.S) if 'kb-mini' not in x]
assert len(heads)==8,heads.keys()
curated_ids={re.search(r'data-wbs="([^"]+)"',c).group(1) for n in cur for c in cur[n] if 'data-wbs=' in c}
# WBS boxes
a=s.find('<section id="wbs-blok"'); b=s.find('</section>',a); w=s[a:b]
BANDS=[('I1','I1 cloud-infra'),('I2','I2 portaal en rechten'),('I3','I3 koppeling en kennis'),('I4','I4 chat'),('I5','I5 rapporten'),('I6','I6 apps'),('I7','I7 transformaties'),('I8','I8 agents'),('F8','F8 Geris-test'),('CI','CI'),('OV','Overig'),('WR','Wachtrij: vervolgtaken')]
def band(d):
    d=d[5:] if d.startswith('DONE:') else d
    for k,_ in BANDS:
        if d.startswith(k): return k
    return 'OV'
GMAP={'I3:DATAMODEL':['datamodel'],'I3:KENNISLIVE':['kennisbank'],'I3:KEURENLIVE':['keuren'],'I2:GEBRUIK':['gebruik'],'I3:KOPPLIVE':['koppelingen'],'I2:HOLDINGCTL':['holding-access-review'],'I2:ORGANISATIE':['organisatie'],'I2:RECHTEN':['rechten']}
GI=['G1','G2','G3','G4','G5','G6','G7','G8','G9','G10']
def gstrip(comps):
    done=[all(gate.get(c,{}).get(g) for c in comps) for g in GI]; need=[i for i in range(10) if i not in (7,8)]; n=sum(done[i] for i in need)
    out=''.join(('<i style="flex:1;height:6px;border-radius:1px;background:repeating-linear-gradient(45deg,#262b35 0 2px,#3a404c 2px 4px);border:1px dashed #5a606c;opacity:.7"></i>' if i in (7,8) else '<i style="flex:1;height:6px;border-radius:1px;background:'+('#3fa36b' if done[i] else '#262b35')+';border:1px solid #3a404c"></i>') for i in range(10))
    return '<span style="display:flex;gap:2px;align-items:center;margin:2px 0 0" title="nodig nu: 8 controles; met bewijs op main: '+str(n)+' van 8">'+out+'<b style="font-size:10px;margin-left:3px">'+str(n)+'/8</b></span>'
gen=collections.defaultdict(lambda: collections.defaultdict(list))
for m in re.finditer(r'<g data-id="([^"]+)"[^>]*>(.*?)</g>',w,re.S):
    d,g=m.group(1),m.group(2)
    if d in curated_ids or d=='I4:FASE': continue
    fills=re.findall(r'width="13\.5" height="3\.5" rx="1" fill="([^"]+)"',g)
    if len(fills)!=8: continue
    col=next((i+1 for i,f in enumerate(fills) if f!='#3fa36b'),8)
    t=re.search(r'<title>(.*?)</title>',g,re.S); full=html.unescape(t.group(1)) if t else d
    name=re.split(r'\n|&#10;',full)[0]
    estm='(geschat uit de status)' in full
    lab=re.findall(r'<text [^>]*font-weight="700"[^>]*>([^<]*)</text>',g); short=html.unescape(lab[0]) if lab else name[:40]
    stroke=re.search(r'<rect [^>]*width="128"[^>]*stroke="([^"]+)"',g); c=stroke.group(1) if stroke else '#9aa4b2'
    c={'#8ab4ff':'#9aa4b2','#8fd3ff':'#9aa4b2','#ff8a80':'#ff4d4d','#e8eaef':'#e8eaef'}.get(c,c)
    dashed='stroke-dasharray' in g[:g.find('<text')]
    strip='<span style="display:flex;gap:2px;margin:2px 0 0'+(';opacity:.6' if estm else '')+'">'+''.join('<i style="flex:1;height:3px;border-radius:1px;background:'+('#3fa36b' if f=='#3fa36b' else (f if f!='#353b47' else '#353b47'))+'"></i>' for f in fills)+'</span>'
    extra=gstrip(GMAP[d]) if d in GMAP else ''
    if estm: short=short+' ≈'
    chip=('<div class="kb-card kb-mini" data-wbs="'+E(d)+'" tabindex="0" role="button" title="'+html.escape(full,quote=True)+'" style="border:1px solid '+c+';border-radius:6px;padding:2px 5px;margin:0 0 3px;background:#181b22;font-size:11.5px;min-width:0;overflow-wrap:anywhere;cursor:pointer">'+E(short)+strip+extra+'</div>')
    gen[col][band(d)].append(chip)
def column(n):
    h,sub=heads[n]; ng=sum(len(v) for v in gen[n].values()); tot=len(cur.get(n,[]))+ng
    body=''.join(cur.get(n,[]))
    for k,lbl in BANDS:
        L=gen[n].get(k,[])
        if not L: continue
        op='' if (k=='WR' or len(L)>25) else ' open'
        body+='<details'+op+' style="margin:4px 0 2px"><summary class="small" style="font-size:11px;color:#c9ced6"><b>'+E(lbl)+'</b> ('+str(len(L))+')</summary>'+''.join(L)+'</details>'
    return ('<div style="border:1px solid #2b3140;border-radius:8px;padding:5px;background:#141821;min-width:0"><p style="margin:0;font-size:12.5px"><b>'+E(h)+'</b> <span class="mute">('+str(tot)+')</span></p><p class="small mute" style="margin:0 0 5px;font-size:11px">'+E(sub)+'</p>'+body+'</div>')
grid='<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,128px),1fr));gap:5px">'+''.join(column(n) for n in range(1,9))+'</div>'
note=('<p class="small mute" style="margin:6px 0 0">Alles uit de WBS staat hier ('+str(sum(len(v) for c in gen.values() for v in c.values())+sum(len(v) for v in cur.values()))+' kaarten): de grote kaarten zijn het werk van nu, de kleine zijn dezelfde blokken als in de WBS, per fase gegroepeerd; een fase met veel kaarten is ingeklapt (klik om te openen). Groene kleine kaarten met ✓ zijn klaar. ≈ = stap geschat uit de status (oudere blokken).</p>')
kan=kan[:gs]+grid+note+kan[sc:]
s=s[:k0]+kan+s[k1:]
s=re.sub(r'(<h2 style="margin:0 0 4px">2\. Kanban <span class="small mute">\(stand )\d\d:\d\d',r'\g<1>'+now,s)
s=re.sub(r'bijgewerkt ma 16-11-2026 \d\d:\d\d CET','bijgewerkt ma 16-11-2026 '+now+' CET',s)
open(out,'w').write(s)
print('curated',{n:len(v) for n,v in cur.items()},'gen',{n:sum(len(x) for x in v.values()) for n,v in sorted(gen.items())})
print('nog-niet removed', 'Nog niet in deze ronde' not in s)
